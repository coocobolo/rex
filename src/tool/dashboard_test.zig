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
    if (state.watch == null) return error.SkipZigTest;
    try testing.expectEqual(@as(?f64, null), dashboard.wait(&state));
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
