const std = @import("std");
const testing = std.testing;

const dashboard = @import("dashboard.zig");
const focus = @import("../builtin/wellbeing/focus.zig");
const kit = @import("../kit/root.zig");
const Config = @import("../config/Config.zig");
const config_defaults = @import("../config/default.zig");
const WellbeingOption = @import("../config/wellbeing.zig").Wellbeing;

const StateTmp = struct {
    tmp: testing.TmpDir,
    buf: [128]u8 = undefined,

    fn init() StateTmp {
        return .{ .tmp = testing.tmpDir(.{}) };
    }

    fn deinit(t: *StateTmp) void {
        t.tmp.cleanup();
    }

    fn path(t: *StateTmp) ![]const u8 {
        return std.fmt.bufPrint(&t.buf, ".zig-cache/tmp/{s}", .{&t.tmp.sub_path});
    }
};

fn option(dir: []const u8) WellbeingOption {
    return .{
        .screen_time = .{ .idle_threshold_ms = 24 * std.time.ms_per_hour, .track_foreground_apps = false },
        .eyesight = .{ .enabled = false },
        .movement = .{ .enabled = false },
        .winddown = .{ .enabled = false },
        .focus = .{ .task_ms = 60_000, .on_phase_end = .wait },
        .privacy = .{ .state_dir = dir, .state_filename = "wb.bin" },
    };
}

fn noWake() void {}

fn openDashboard(config: *const Config, dir: []const u8) !dashboard.State {
    return dashboard.init(.{
        .gpa = testing.allocator,
        .io = testing.io,
        .config = config,
        .state_dir = dir,
        .wake_loop = noWake,
    });
}

fn configWith(dir: []const u8) Config {
    var config = config_defaults.default;
    config.wellbeing = option(dir);
    return config;
}

test "dashboard: an idle timer does not ask the host to wake" {
    var tmp: StateTmp = .init();
    defer tmp.deinit();
    const dir = try tmp.path();
    const config = configWith(dir);
    var state = try openDashboard(&config, dir);
    defer dashboard.deinit(&state);
    // Without a watch (other systems, or it failed) an idle window polls.
    // With one it sleeps until local midnight, at most a day.
    if (state.watch == null) return error.SkipZigTest;
    try testing.expect(dashboard.wait(&state).? > 1);
    var nodes: [dashboard.node_max]kit.tree.Node = undefined;
    var lines: [dashboard.line_max]kit.text.Line = undefined;
    var tree = kit.tree.Tree.init(&nodes, &lines);
    try dashboard.view(&state, &tree, &kit.Theme.dark);
    // A full task, as the terminal shows an idle timer.
    try testing.expectEqualStrings("01:00", state.clock());
}

test "dashboard: a running timer wakes when the shown second changes" {
    var tmp: StateTmp = .init();
    defer tmp.deinit();
    const dir = try tmp.path();
    const config = configWith(dir);
    var state = try openDashboard(&config, dir);
    defer dashboard.deinit(&state);
    state.wb.toggleFocus(1_000);

    // Just started: a full minute shows until one second has passed.
    dashboard.refreshAt(&state, 1_000);
    try testing.expectEqualStrings("01:00", state.clock());
    dashboard.refreshAt(&state, 1_999);
    try testing.expectEqualStrings("01:00", state.clock());
    dashboard.refreshAt(&state, 2_000);
    try testing.expectEqualStrings("00:59", state.clock());

    // 59.700 s left shows 01:00 for 700 ms more, not a full second.
    try testing.expectApproxEqAbs(@as(f64, 0.701), dashboard.waitAt(&state, 1_300).?, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.001), dashboard.waitAt(&state, 2_000).?, 1e-9);
}

test "dashboard: a pause is visible to a second window" {
    var tmp: StateTmp = .init();
    defer tmp.deinit();
    const dir = try tmp.path();
    const config = configWith(dir);
    var writer = try openDashboard(&config, dir);
    defer dashboard.deinit(&writer);
    var reader = try openDashboard(&config, dir);
    defer dashboard.deinit(&reader);

    const now_ms: i64 = 5_000;
    writer.wb.toggleFocus(now_ms);
    try writer.wb.sync(testing.io, dir, 5, .merge);
    try reader.wb.sync(testing.io, dir, 6, .poll);
    try testing.expectEqual(focus.Run.running, reader.wb.timer().run);

    writer.wb.toggleFocus(now_ms + 1_000);
    try writer.wb.sync(testing.io, dir, 7, .merge);
    try reader.wb.sync(testing.io, dir, 8, .poll);
    try testing.expectEqual(focus.Run.paused, reader.wb.timer().run);
}

fn buildView(state: *const dashboard.State) !void {
    var nodes: [dashboard.node_max]kit.tree.Node = undefined;
    var lines: [dashboard.line_max]kit.text.Line = undefined;
    var tree = kit.tree.Tree.init(&nodes, &lines);
    try dashboard.view(state, &tree, &kit.Theme.dark);
}

fn waitingTask(tasks_in_cycle: u8) @import("../builtin/wellbeing/storage.zig").Timer {
    return .{ .phase = @intFromEnum(focus.Phase.task), .run = @intFromEnum(focus.Run.waiting), .tasks_in_cycle = tasks_in_cycle };
}

test "dashboard: every page fits node_max, with either timer mark and the menu open" {
    var tmp: StateTmp = .init();
    defer tmp.deinit();
    const dir = try tmp.path();
    for ([_]WellbeingOption.TimerChart{ .bar, .ring }) |mark| {
        var config = configWith(dir);
        config.wellbeing.dashboard.timer_chart = mark;
        var state = try openDashboard(&config, dir);
        defer dashboard.deinit(&state);
        // A running timer shows the chip on the other pages.
        state.wb.toggleFocus(1_000);
        dashboard.refreshAt(&state, 2_000);
        for ([_]dashboard.Page{ .today, .focus, .history }) |page| {
            state.page = page;
            try buildView(&state);
        }
        state.page = .focus;
        state.menu = .open;
        try buildView(&state);
    }
}

test "dashboard: a waiting timer shows the next phase in full" {
    var tmp: StateTmp = .init();
    defer tmp.deinit();
    const dir = try tmp.path();
    const config = configWith(dir);
    var state = try openDashboard(&config, dir);
    defer dashboard.deinit(&state);

    // Task 2 of 4 ended: a five-minute short break is next.
    state.wb.data.timer = waitingTask(1);
    dashboard.refreshAt(&state, 10_000);
    try testing.expectEqualStrings("05:00", state.clock());
    try testing.expectEqual(focus.Phase.short_break, state.shown.phase);
    try testing.expectEqualStrings("1 of 4 tasks done", state.taskLine());
    try testing.expectEqual(0, state.shown.fraction);

    // The fourth task ended: the long break is next.
    state.wb.data.timer = waitingTask(3);
    dashboard.refreshAt(&state, 10_000);
    try testing.expectEqual(focus.Phase.long_break, state.shown.phase);
}

test "dashboard: a running phase at its end does not spin" {
    var tmp: StateTmp = .init();
    defer tmp.deinit();
    const dir = try tmp.path();
    const config = configWith(dir);
    var state = try openDashboard(&config, dir);
    defer dashboard.deinit(&state);
    state.wb.toggleFocus(1_000);
    // A minute later the task is over, but only a terminal ends it: no
    // 1 ms tick, but the watch (with the midnight wake) or the poll.
    const wait = dashboard.waitAt(&state, 61_000).?;
    try testing.expect(wait >= 1);
}

test "dashboard: Ctrl+Tab cycles the pages, Escape closes the menu" {
    var tmp: StateTmp = .init();
    defer tmp.deinit();
    const dir = try tmp.path();
    const config = configWith(dir);
    var state = try openDashboard(&config, dir);
    defer dashboard.deinit(&state);

    try testing.expectEqual(dashboard.Page.today, state.page);
    try testing.expect(dashboard.update(&state, .{ .key = .{ .key = .tab, .mods = .{ .ctrl = true } } }));
    try testing.expectEqual(dashboard.Page.focus, state.page);
    try testing.expect(dashboard.update(&state, .{ .key = .{ .key = .tab, .mods = .{ .ctrl = true, .shift = true } } }));
    try testing.expect(dashboard.update(&state, .{ .key = .{ .key = .tab, .mods = .{ .ctrl = true, .shift = true } } }));
    try testing.expectEqual(dashboard.Page.history, state.page);
    // Tab alone does nothing.
    try testing.expect(!dashboard.update(&state, .{ .key = .{ .key = .tab } }));

    state.menu = .open;
    try testing.expect(dashboard.update(&state, .{ .key = .{ .key = .escape } }));
    try testing.expectEqual(.closed, state.menu);
}

test "dashboard: a click on a tab switches to it; the menu opens and closes" {
    var tmp: StateTmp = .init();
    defer tmp.deinit();
    const dir = try tmp.path();
    const config = configWith(dir);
    var state = try openDashboard(&config, dir);
    defer dashboard.deinit(&state);

    const history_tab = kit.tree.Id.of("wellbeing.tab").item(2);
    _ = dashboard.update(&state, .{ .pointer = history_tab });
    _ = dashboard.update(&state, .{ .press = history_tab });
    try testing.expect(dashboard.update(&state, .release));
    try testing.expectEqual(dashboard.Page.history, state.page);

    // A release away from where the press went down does nothing.
    state.page = .focus;
    const more = kit.tree.Id.of("wellbeing.more");
    _ = dashboard.update(&state, .{ .pointer = more });
    _ = dashboard.update(&state, .{ .press = more });
    _ = dashboard.update(&state, .{ .pointer = .none });
    _ = dashboard.update(&state, .release);
    try testing.expectEqual(.closed, state.menu);

    _ = dashboard.update(&state, .{ .pointer = more });
    _ = dashboard.update(&state, .{ .press = more });
    _ = dashboard.update(&state, .release);
    try testing.expectEqual(.open, state.menu);
    try testing.expect(dashboard.update(&state, .{ .press = kit.tree.Id.of("wellbeing.layer") }));
    try testing.expectEqual(.closed, state.menu);
}

test "dashboard: Space starts the timer and the press is saved" {
    var tmp: StateTmp = .init();
    defer tmp.deinit();
    const dir = try tmp.path();
    const config = configWith(dir);
    var state = try openDashboard(&config, dir);
    defer dashboard.deinit(&state);

    try testing.expect(dashboard.update(&state, .{ .key = .{ .key = .space } }));
    try testing.expectEqual(focus.Run.running, state.wb.timer().run);
    const file = try @import("../builtin/wellbeing/storage.zig").load(testing.io, dir, "wb.bin");
    try testing.expectEqual(@intFromEnum(focus.Run.running), file.timer.run);
}

const storage = @import("../builtin/wellbeing/storage.zig");

fn compute(data: *const storage.PersistentData, wb_option: *const WellbeingOption, day: u32) dashboard.Today {
    var today: dashboard.Today = .{};
    dashboard.computeToday(&today, data, wb_option, day);
    return today;
}

test "today: cards read today's record, and the limit sets the note" {
    var data: storage.PersistentData = .{ .current_streak = 1 };
    data.today = .{ .day = 100, .active_screen_s = 7 * 3600, .focus_s = 3600 + 30 * 60, .tasks_completed = 1, .eyesight_breaks = 3, .movement_breaks = 1 };
    var wb_option = option("unused");
    wb_option.screen_time.daily_limit_ms = 6 * std.time.ms_per_hour;
    const today = compute(&data, &wb_option, 100);

    try testing.expectEqualStrings("7h", today.cards[0].value.slice());
    try testing.expect(today.cards[0].over);
    try testing.expectEqualStrings("1h over the 6h limit", today.cards[0].note.slice());
    try testing.expectEqualStrings("1h 30m", today.cards[1].value.slice());
    try testing.expectEqualStrings("21% of screen time", today.cards[1].note.slice());
    try testing.expectEqualStrings("4", today.cards[2].value.slice());
    try testing.expectEqualStrings("Reminders are off", today.cards[2].note.slice());
    try testing.expectEqualStrings("1 day", today.cards[3].value.slice());
    try testing.expectEqualStrings("1 task today", today.cards[3].note.slice());

    wb_option.screen_time.daily_limit_ms = null;
    const unlimited = compute(&data, &wb_option, 100);
    try testing.expect(unlimited.cards[0].fraction < 0);
    try testing.expectEqualStrings("No daily limit", unlimited.cards[0].note.slice());
}

test "today: records are placed on their own day, and a stale today is a past day" {
    var data: storage.PersistentData = .{};
    // No terminal ran on day 104 or since: "today" in the file is day 104.
    data.history[0] = .{ .day = 101, .active_screen_s = 60 };
    data.history_count = 1;
    data.today = .{ .day = 104, .active_screen_s = 120, .focus_s = 60 };
    const today = compute(&data, &option("unused"), 106);

    // The week ends on day 106, a Friday: day 0 and day 105 were Thursdays.
    try testing.expectEqual(5, today.weekday);
    try testing.expectEqual(0, today.week[6].screen_s);
    try testing.expectEqual(120, today.week[4].screen_s);
    try testing.expectEqual(60, today.week[4].focus_s);
    try testing.expectEqual(60, today.week[1].screen_s);
    try testing.expectEqual(0, today.week[0].screen_s);
    // Nothing recorded on day 106 itself.
    try testing.expectEqualStrings("0m", today.cards[0].value.slice());
    try testing.expectEqualStrings("No screen time yet", today.cards[1].note.slice());
}

test "today: programs are sorted, four by name and the rest as Other" {
    var data: storage.PersistentData = .{};
    data.today = .{ .day = 7 };
    const apps = [_]struct { []const u8, u32 }{ .{ "zsh", 600 }, .{ "nvim", 1200 }, .{ "man", 60 }, .{ "htop", 120 }, .{ "cargo", 300 }, .{ "git", 120 } };
    for (apps, 0..) |app, index| {
        data.today.top_apps[index].setName(app[0]);
        data.today.top_apps[index].seconds = app[1];
    }
    const today = compute(&data, &option("unused"), 7);
    try testing.expectEqual(5, today.program_count);
    try testing.expectEqualStrings("nvim", today.programs[0].name.slice());
    try testing.expectEqualStrings("zsh", today.programs[1].name.slice());
    try testing.expectEqualStrings("cargo", today.programs[2].name.slice());
    try testing.expectEqualStrings("Other", today.programs[4].name.slice());
    // The two 120 s programs: one is fourth, the other joins Other.
    try testing.expectEqual(120, today.programs[3].seconds);
    try testing.expectEqual(180, today.programs[4].seconds);
    try testing.expectEqualStrings("20m", today.programs[0].time.slice());
    try testing.expectEqualStrings("50%", today.programs[0].share.slice());
}

test "today: an idle window wakes at the next local midnight" {
    var tmp: StateTmp = .init();
    defer tmp.deinit();
    const dir = try tmp.path();
    const config = configWith(dir);
    var state = try openDashboard(&config, dir);
    defer dashboard.deinit(&state);
    if (state.watch == null) return error.SkipZigTest;
    const now_ms: i64 = 1_800_000_000_000;
    dashboard.refreshAt(&state, now_ms);
    const wait = dashboard.waitAt(&state, now_ms).?;
    try testing.expect(wait >= 1 and wait <= std.time.s_per_day);
}
