const std = @import("std");
const testing = std.testing;

const wellbeing = @import("root.zig");
const storage = wellbeing.storage;
const tracker = wellbeing.tracker;
const reminders = wellbeing.reminders;
const winddown = wellbeing.winddown;
const dashboard = wellbeing.dashboard;
const localtime = wellbeing.localtime;

/// A temporary directory with paths relative to the working directory,
/// which is how `storage` opens files.
const StateTmp = struct {
    tmp: testing.TmpDir,
    buf: [128]u8 = undefined,

    fn init() StateTmp {
        return .{ .tmp = testing.tmpDir(.{}) };
    }

    fn deinit(t: *StateTmp) void {
        t.tmp.cleanup();
    }

    /// Valid until the next call.
    fn path(t: *StateTmp, name: []const u8) ![]const u8 {
        return std.fmt.bufPrint(&t.buf, ".zig-cache/tmp/{s}/{s}", .{ &t.tmp.sub_path, name });
    }
};

test "storage: save then load returns the same data" {
    var t: StateTmp = .init();
    defer t.deinit();
    var data: storage.PersistentData = .empty;
    data.current_streak = 5;
    data.today.focus_s = 1234;

    try storage.save(testing.io, &data, try t.path("state"), "wb.bin", .buffered);
    const loaded = try storage.load(testing.io, try t.path("state"), "wb.bin");
    try testing.expectEqual(5, loaded.current_streak);
    try testing.expectEqual(1234, loaded.today.focus_s);

    // A flushed save (file and directory fsync) reads back the same.
    data.current_streak = 6;
    try storage.save(testing.io, &data, try t.path("state"), "wb.bin", .synced);
    try testing.expectEqual(6, (try storage.load(testing.io, try t.path("state"), "wb.bin")).current_streak);
}

test "storage: a missing directory or file loads as empty" {
    var t: StateTmp = .init();
    defer t.deinit();
    const no_dir = try storage.load(testing.io, try t.path("missing"), "wb.bin");
    try testing.expectEqual(storage.magic, no_dir.magic);
    try testing.expectEqual(0, no_dir.current_streak);
    const no_file = try storage.load(testing.io, try t.path(""), "wb.bin");
    try testing.expectEqual(0, no_file.current_streak);
}

test "storage: a short file or a wrong magic is InvalidStateFile" {
    var t: StateTmp = .init();
    defer t.deinit();
    try t.tmp.dir.writeFile(testing.io, .{ .sub_path = "short.bin", .data = "WELL" });
    try testing.expectError(error.InvalidStateFile, storage.load(testing.io, try t.path(""), "short.bin"));

    var data: storage.PersistentData = .empty;
    data.magic = 0;
    try storage.save(testing.io, &data, try t.path(""), "magic.bin", .buffered);
    try testing.expectError(error.InvalidStateFile, storage.load(testing.io, try t.path(""), "magic.bin"));
}

test "storage: the state file has no implicit padding" {
    inline for (.{ storage.Timer, storage.DayRecord, storage.PersistentData }) |T| {
        comptime var sum: usize = 0;
        inline for (std.meta.fields(T)) |f| sum += @sizeOf(f.type);
        try testing.expectEqual(sum, @sizeOf(T));
    }
}

test "storage: a saved waiting phase loads as waiting, not counted twice" {
    var t: StateTmp = .init();
    defer t.deinit();
    var option = quietOption();
    option.focus = .{ .task_ms = 1000, .on_phase_end = .wait };
    option.privacy.state_dir = try t.path("");
    option.privacy.state_filename = "wb.bin";

    var before = wellbeing.Wellbeing.init(option);
    before.toggleFocus(0);
    _ = before.tick(1000, -1, localAt(1000, 12, 0, 0), 1000);
    try testing.expect(before.focus_state.waiting);
    try testing.expectEqual(1, before.data.tasks_completed);
    try before.sync(testing.io, "unused", 0, .merge);

    var after = wellbeing.Wellbeing.init(option);
    try after.loadState(testing.io, "unused");
    try testing.expect(after.focus_state.waiting);
    try testing.expect(!after.focus_state.paused);

    // Confirming starts the break; the task that ended before the restart
    // is not counted again.
    after.toggleFocus(60_000);
    _ = after.tick(1000, -1, localAt(1000, 12, 1, 0), 61_000);
    try testing.expectEqual(wellbeing.focus.Phase.short_break, after.focus_state.phase);
    try testing.expectEqual(1, after.data.tasks_completed);
}

test "storage: decode rejects a wrong size, an older version and a bad history_count" {
    const data: storage.PersistentData = .empty;
    const bytes = std.mem.asBytes(&data);
    try testing.expectError(error.InvalidStateFile, storage.decode(bytes[0 .. bytes.len - 1]));

    var other = data;
    other.version = 1;
    try testing.expectError(error.InvalidStateFile, storage.decode(std.mem.asBytes(&other)));

    var bad = data;
    bad.history_count = storage.max_history_days + 1;
    try testing.expectError(error.InvalidStateFile, storage.decode(std.mem.asBytes(&bad)));
}

test "storage: save replaces the file and leaves no temporary file" {
    var t: StateTmp = .init();
    defer t.deinit();
    var data: storage.PersistentData = .empty;
    try storage.save(testing.io, &data, try t.path(""), "wb.bin", .buffered);
    const first = try storage.stamp(testing.io, try t.path(""), "wb.bin");
    data.current_streak = 7;
    try storage.save(testing.io, &data, try t.path(""), "wb.bin", .buffered);
    const second = try storage.stamp(testing.io, try t.path(""), "wb.bin");

    try testing.expect(!first.eql(second));
    try testing.expectEqual(7, (try storage.load(testing.io, try t.path(""), "wb.bin")).current_streak);
    const dir = try t.tmp.dir.openDir(testing.io, ".", .{ .iterate = true });
    defer dir.close(testing.io);
    var it = dir.iterate();
    var count: usize = 0;
    while (try it.next(testing.io)) |_| count += 1;
    try testing.expectEqual(1, count);
}

test "storage: stamp of a missing file is none" {
    var t: StateTmp = .init();
    defer t.deinit();
    try testing.expect((try storage.stamp(testing.io, try t.path("missing"), "wb.bin")).eql(.none));
    try testing.expect((try storage.stamp(testing.io, try t.path(""), "wb.bin")).eql(.none));
}

// flock locks belong to an open file description, so two opens in one
// process conflict like two processes do (Linux flock(2), macOS flock(2)).
test "storage: the write lock is exclusive until released" {
    var t: StateTmp = .init();
    defer t.deinit();
    const first = (try storage.tryLockWrite(testing.io, try t.path(""), "wb.bin")).?;
    try testing.expectEqual(null, try storage.tryLockWrite(testing.io, try t.path(""), "wb.bin"));
    first.release(testing.io);
    const again = (try storage.tryLockWrite(testing.io, try t.path(""), "wb.bin")).?;
    again.release(testing.io);
}

test "storage: presence tells the first process it is alone" {
    var t: StateTmp = .init();
    defer t.deinit();
    const a = try storage.acquirePresence(testing.io, try t.path(""), "wb.bin");
    try testing.expect(a.alone);
    const b = try storage.acquirePresence(testing.io, try t.path(""), "wb.bin");
    try testing.expect(!b.alone);
    a.presence.release(testing.io);
    const c = try storage.acquirePresence(testing.io, try t.path(""), "wb.bin");
    try testing.expect(!c.alone);
    b.presence.release(testing.io);
    c.presence.release(testing.io);
    const d = try storage.acquirePresence(testing.io, try t.path(""), "wb.bin");
    try testing.expect(d.alone);
    d.presence.release(testing.io);
}

test "storage: save reports an unusable state directory" {
    var t: StateTmp = .init();
    defer t.deinit();
    // A regular file where the directory should be fails even for root,
    // unlike a read-only directory.
    try t.tmp.dir.writeFile(testing.io, .{ .sub_path = "file", .data = "" });
    const data: storage.PersistentData = .empty;
    if (storage.save(testing.io, &data, try t.path("file"), "wb.bin", .buffered)) |_| {
        return error.TestUnexpectedResult;
    } else |_| {}
}

const merge = wellbeing.merge;

/// A state with `today` on `day` and the given active seconds.
fn dataOn(day: u32, active_s: u32) storage.PersistentData {
    var data: storage.PersistentData = .empty;
    data.today = .{ .day = day, .active_screen_s = active_s };
    return data;
}

test "merge: the changes of two processes add up" {
    const base = dataOn(1000, 100);
    var view = base;
    view.today.active_screen_s += 30;
    view.today.tasks_completed += 1;
    view.tasks_completed += 1;
    // Another process merged first and added 50 s.
    var fresh = base;
    fresh.today.active_screen_s += 50;

    const out = merge.rebase(&view, &base, &fresh);
    try testing.expectEqual(180, out.today.active_screen_s);
    try testing.expectEqual(1, out.today.tasks_completed);
    try testing.expectEqual(1, out.tasks_completed);
}

test "merge: a reminder fired in two processes counts once" {
    var base = dataOn(1000, 100);
    base.eyesight_due_s = 1200;
    // Both processes fired the reminder due at 2400 s of active time.
    var view = base;
    view.eyesight_due_s = 2400;
    view.today.eyesight_breaks += 1;
    var fresh = base;
    fresh.eyesight_due_s = 2400;
    fresh.today.eyesight_breaks += 1;

    const out = merge.rebase(&view, &base, &fresh);
    try testing.expectEqual(2400, out.eyesight_due_s);
    try testing.expectEqual(1, out.today.eyesight_breaks);
}

test "merge: a later due point counts one break, an earlier one none" {
    var base = dataOn(1000, 100);
    base.movement_due_s = 3000;
    var view = base;
    view.movement_due_s = 6000;
    view.today.movement_breaks += 1;
    const fresh = base;

    const out = merge.rebase(&view, &base, &fresh);
    try testing.expectEqual(6000, out.movement_due_s);
    try testing.expectEqual(1, out.today.movement_breaks);

    // The file moved past this view's due point: the file wins, and the
    // view's own count is not added on top.
    var newer = base;
    newer.movement_due_s = 9000;
    newer.today.movement_breaks += 2;
    const kept = merge.rebase(&view, &base, &newer);
    try testing.expectEqual(9000, kept.movement_due_s);
    try testing.expectEqual(2, kept.today.movement_breaks);
}

test "merge: starting a reminder from 0 is not a break" {
    const base = dataOn(1000, 100);
    var view = base;
    view.eyesight_due_s = 100;
    const out = merge.rebase(&view, &base, &base);
    try testing.expectEqual(100, out.eyesight_due_s);
    try testing.expectEqual(0, out.today.eyesight_breaks);
}

test "merge: a purge since base drops a reminder due point" {
    var base = dataOn(1000, 100);
    base.eyesight_due_s = 1200;
    var view = base;
    view.eyesight_due_s = 2400;
    view.today.eyesight_breaks += 1;
    var fresh: storage.PersistentData = .empty;
    fresh.generation = base.generation + 1;

    const out = merge.rebase(&view, &base, &fresh);
    try testing.expectEqual(0, out.eyesight_due_s);
    try testing.expectEqual(0, out.today.eyesight_breaks);
}

test "merge: a break fired before midnight and merged after counts on the file's day" {
    var base = dataOn(1000, 100);
    base.eyesight_due_s = 1200;
    var view = base;
    view.eyesight_due_s = 2400;
    view.today.eyesight_breaks += 1;
    _ = merge.rollover(&view, 1001);

    const out = merge.rebase(&view, &base, &base);
    try testing.expectEqual(1001, out.today.day);
    try testing.expectEqual(1, out.today.eyesight_breaks);
    try testing.expectEqual(0, out.history[0].eyesight_breaks);
}

test "storage: the active clock survives a rollover" {
    var data = dataOn(1000, 500);
    data.total_active_screen_s = 7000;
    const before = data.activeClock();
    _ = merge.rollover(&data, 1001);
    try testing.expectEqual(before, data.activeClock());
    try testing.expectEqual(0, data.today.active_screen_s);
}

test "merge: a purge since base drops the changes" {
    const base = dataOn(1000, 100);
    var view = base;
    view.today.active_screen_s += 30;
    var fresh: storage.PersistentData = .empty;
    fresh.generation = base.generation + 1;

    const out = merge.rebase(&view, &base, &fresh);
    try testing.expectEqual(0, out.today.active_screen_s);
    try testing.expectEqual(fresh.generation, out.generation);
}

test "merge: changes across midnight land on their own days" {
    const base = dataOn(1000, 10);
    // This process rolled over: day 1000 ended at 30 s, day 1001 has 5 s.
    var view = base;
    view.today.active_screen_s = 30;
    _ = merge.rollover(&view, 1001);
    view.today.active_screen_s = 5;
    const fresh = base;

    const out = merge.rebase(&view, &base, &fresh);
    try testing.expectEqual(1001, out.today.day);
    try testing.expectEqual(5, out.today.active_screen_s);
    try testing.expectEqual(1, out.history_count);
    try testing.expectEqual(1000, out.history[0].day);
    try testing.expectEqual(30, out.history[0].active_screen_s);
    try testing.expectEqual(30, out.total_active_screen_s);
}

test "merge: changes to a day another process already rolled over reach history and totals" {
    const base = dataOn(1000, 10);
    var view = base;
    view.today.active_screen_s += 20;
    var fresh = base;
    _ = merge.rollover(&fresh, 1001);

    const out = merge.rebase(&view, &base, &fresh);
    try testing.expectEqual(1001, out.today.day);
    try testing.expectEqual(30, out.history[0].active_screen_s);
    try testing.expectEqual(30, out.total_active_screen_s);
}

test "merge: a task on the same day in two processes counts the streak once" {
    var base = dataOn(1000, 0);
    base.last_task_day = 999;
    base.current_streak = 3;
    var a = base;
    merge.recordTaskDay(&a, 1000);
    var b = base;
    merge.recordTaskDay(&b, 1000);

    const after_a = merge.rebase(&a, &base, &base);
    const out = merge.rebase(&b, &base, &after_a);
    try testing.expectEqual(4, out.current_streak);
    try testing.expectEqual(1000, out.last_task_day);
}

test "merge: app seconds add as differences" {
    var base = dataOn(1000, 0);
    base.today.addAppTime("nvim", 100);
    var view = base;
    view.today.addAppTime("nvim", 20);
    view.today.addAppTime("zsh", 5);
    var fresh = base;
    fresh.today.addAppTime("nvim", 40);

    const out = merge.rebase(&view, &base, &fresh);
    try testing.expectEqual(160, out.today.top_apps[0].seconds);
    try testing.expectEqualStrings("zsh", out.today.top_apps[1].getName());
    try testing.expectEqual(5, out.today.top_apps[1].seconds);
}

test "merge: rollover keeps the last max_history_days days" {
    var data = dataOn(1000, 1);
    for (1001..1001 + storage.max_history_days + 2) |day| _ = merge.rollover(&data, @intCast(day));
    try testing.expectEqual(storage.max_history_days, data.history_count);
    try testing.expectEqual(1000 + storage.max_history_days + 2, data.today.day);
    try testing.expectEqual(1002, data.history[0].day);
}

/// A `Wellbeing` sharing `t`'s directory, as one window would, on local
/// day 1000 as its first tick would set.
fn openShared(t: *StateTmp) !wellbeing.Wellbeing {
    var option = quietOption();
    option.privacy.state_dir = try t.path("");
    option.privacy.state_filename = "wb.bin";
    var wb = wellbeing.Wellbeing.init(option);
    try wb.open(testing.io, "unused", 0);
    _ = merge.rollover(&wb.data, 1000);
    return wb;
}

/// Like `openShared`, with a one-minute focus task and phases that wait.
fn openFocus(t: *StateTmp, utc_ms: i64) !wellbeing.Wellbeing {
    var option = quietOption();
    option.focus = .{ .task_ms = 60_000, .short_break_ms = 10_000, .on_phase_end = .wait };
    option.privacy.state_dir = try t.path("");
    option.privacy.state_filename = "wb.bin";
    var wb = wellbeing.Wellbeing.init(option);
    try wb.open(testing.io, "unused", utc_ms);
    return wb;
}

/// Like `openShared`, with a 60 s eyesight reminder and movement off.
fn openReminders(t: *StateTmp) !wellbeing.Wellbeing {
    var option = quietOption();
    option.eyesight = .{
        .enabled = true,
        .interval_ms = 60 * std.time.ms_per_s,
        .duration_ms = 20 * std.time.ms_per_s,
        .animation = .none,
    };
    option.privacy.state_dir = try t.path("");
    option.privacy.state_filename = "wb.bin";
    var wb = wellbeing.Wellbeing.init(option);
    try wb.open(testing.io, "unused", 0);
    _ = merge.rollover(&wb.data, 1000);
    return wb;
}

test "focus: a phase end two windows notice counts once" {
    var t: StateTmp = .init();
    defer t.deinit();
    var a = try openFocus(&t, 1_000_000);
    defer a.close(testing.io);
    var b = try openFocus(&t, 1_000_000);
    defer b.close(testing.io);
    const day_s = localAt(1000, 12, 0, 0);

    a.toggleFocus(1_000_000);
    try a.sync(testing.io, "unused", 1000, .merge);
    try b.sync(testing.io, "unused", 1000, .poll);
    try testing.expectEqual(wellbeing.focus.Run.running, b.timer().run);

    // Both tick while the task runs, then reach the end time and end the
    // phase themselves.
    _ = a.tick(1000, -1, day_s, 1_030_000);
    _ = b.tick(1000, -1, day_s, 1_030_000);
    const res_a = a.tick(1000, -1, day_s, 1_060_000);
    const res_b = b.tick(1000, -1, day_s, 1_060_000);
    try testing.expect(res_a.phase_changed and res_b.phase_changed);
    try testing.expect(res_a.alert != null and res_b.alert != null);
    try a.sync(testing.io, "unused", 1060, .merge);
    try b.sync(testing.io, "unused", 1060, .merge);

    const file = try storage.load(testing.io, try t.path(""), "wb.bin");
    try testing.expectEqual(1, file.tasks_completed);
    try testing.expectEqual(1, file.today.tasks_completed);
    try testing.expectEqual(60, file.today.focus_s);
    try testing.expectEqual(@intFromEnum(wellbeing.focus.Run.waiting), file.timer.run);
    try testing.expect(std.meta.eql(file.timer, b.data.timer));
}

test "focus: a second window joins a running timer" {
    var t: StateTmp = .init();
    defer t.deinit();
    var a = try openFocus(&t, 1_000_000);
    defer a.close(testing.io);
    a.toggleFocus(1_000_000);
    try a.sync(testing.io, "unused", 1000, .merge);

    var b = try openFocus(&t, 1_030_000);
    defer b.close(testing.io);
    try testing.expectEqual(wellbeing.focus.Run.running, b.timer().run);
    try testing.expectEqual(1_060_000, b.timer().ms);
}

test "focus: a restart with no other window brings a running phase back paused" {
    var t: StateTmp = .init();
    defer t.deinit();
    var a = try openFocus(&t, 1_000_000);
    a.toggleFocus(1_000_000);
    try a.sync(testing.io, "unused", 1010, .merge); // last save 50 s before the end
    a.close(testing.io);

    var c = try openFocus(&t, 2_000_000);
    defer c.close(testing.io);
    try testing.expectEqual(wellbeing.focus.Run.paused, c.timer().run);
    try testing.expectEqual(50_000, c.timer().ms);
    const file = try storage.load(testing.io, try t.path(""), "wb.bin");
    try testing.expectEqual(@intFromEnum(wellbeing.focus.Run.paused), file.timer.run);
}

test "focus: a phase that ran out while every window was closed comes back waiting, not counted" {
    var t: StateTmp = .init();
    defer t.deinit();
    var a = try openFocus(&t, 1_000_000);
    a.toggleFocus(1_000_000);
    try a.sync(testing.io, "unused", 1070, .merge); // saved after the end, never ticked
    a.close(testing.io);

    var c = try openFocus(&t, 2_000_000);
    defer c.close(testing.io);
    try testing.expectEqual(wellbeing.focus.Run.waiting, c.timer().run);
    const file = try storage.load(testing.io, try t.path(""), "wb.bin");
    try testing.expectEqual(0, file.tasks_completed);
}

test "screen time: only the focused window counts" {
    var t: StateTmp = .init();
    defer t.deinit();
    var a = try openShared(&t);
    defer a.close(testing.io);
    var b = try openShared(&t);
    defer b.close(testing.io);
    const day_s = localAt(1000, 12, 0, 0);

    b.windowFocusChanged(false);
    for (0..60) |_| {
        a.recordActivity();
        b.recordActivity();
        _ = a.tick(1000, -1, day_s, 0);
        _ = b.tick(1000, -1, day_s, 0);
    }
    try testing.expectEqual(60, a.data.today.active_screen_s);
    try testing.expectEqual(0, b.data.today.active_screen_s);
    try a.sync(testing.io, "unused", 1000, .merge);
    try b.sync(testing.io, "unused", 1000, .merge);
    try testing.expectEqual(60, (try storage.load(testing.io, try t.path(""), "wb.bin")).today.active_screen_s);
}

test "screen time: the daily limit counts every window's time" {
    var t: StateTmp = .init();
    defer t.deinit();
    var a = try openShared(&t);
    defer a.close(testing.io);
    var b = try openShared(&t);
    defer b.close(testing.io);
    a.option.screen_time.daily_limit_ms = 2 * std.time.ms_per_min;
    a.tracker_engine.option = a.option.screen_time;
    b.option.screen_time.daily_limit_ms = 2 * std.time.ms_per_min;
    b.tracker_engine.option = b.option.screen_time;
    const day_s = localAt(1000, 12, 0, 0);

    // 90 s in A, which merges when it loses focus.
    b.windowFocusChanged(false);
    _ = a.tick(90_000, -1, day_s, 0);
    a.windowFocusChanged(false);
    try a.sync(testing.io, "unused", 1000, .merge);

    // B picks that up; 30 s of its own reach the 2-minute limit.
    b.windowFocusChanged(true);
    try b.sync(testing.io, "unused", 1001, .poll);
    try testing.expectEqual(90, b.data.today.active_screen_s);
    const res = b.tick(30_000, -1, day_s, 0);
    try testing.expect(res.alert != null);
    try testing.expectEqual(reminders.AlertKind.screen_limit, res.alert.?.kind);
}

test "screen time: gaining focus counts as activity" {
    var option = quietOption();
    option.screen_time.idle_threshold_ms = std.time.ms_per_min;
    var wb = wellbeing.Wellbeing.init(option);
    _ = wb.tick(60_000, -1, localAt(1000, 12, 0, 0), 0);
    try testing.expect(wb.tracker_engine.is_idle);
    wb.windowFocusChanged(false);
    wb.windowFocusChanged(true);
    try testing.expect(!wb.tracker_engine.is_idle);
}

test "sync: a poll runs once per second unless a merge is due" {
    var t: StateTmp = .init();
    defer t.deinit();
    var a = try openShared(&t);
    defer a.close(testing.io);
    var b = try openShared(&t);
    defer b.close(testing.io);

    try a.sync(testing.io, "unused", 1000, .poll);
    b.data.today.focus_s = 50;
    try b.sync(testing.io, "unused", 1000, .merge);
    try a.sync(testing.io, "unused", 1000, .poll);
    try testing.expectEqual(0, a.data.today.focus_s);
    try a.sync(testing.io, "unused", 1001, .poll);
    try testing.expectEqual(50, a.data.today.focus_s);

    // A timer change is due at once, within the same second.
    a.toggleFocus(1_001_500);
    try a.sync(testing.io, "unused", 1001, .poll);
    const file = try storage.load(testing.io, try t.path(""), "wb.bin");
    try testing.expectEqual(@intFromEnum(wellbeing.focus.Run.running), file.timer.run);
}

test "sync: losing focus makes unmerged screen time due" {
    var t: StateTmp = .init();
    defer t.deinit();
    var a = try openShared(&t);
    defer a.close(testing.io);

    try a.sync(testing.io, "unused", 1000, .poll); // first merge
    _ = a.tick(10_000, -1, localAt(1000, 12, 0, 0), 0);
    try a.sync(testing.io, "unused", 1001, .poll);
    try testing.expectEqual(0, (try storage.load(testing.io, try t.path(""), "wb.bin")).today.active_screen_s);
    a.windowFocusChanged(false);
    try a.sync(testing.io, "unused", 1002, .poll);
    try testing.expectEqual(10, (try storage.load(testing.io, try t.path(""), "wb.bin")).today.active_screen_s);
}

test "sync: nothing happens while wellbeing is disabled" {
    var t: StateTmp = .init();
    defer t.deinit();
    var option = quietOption();
    option.enabled = false;
    option.privacy.state_dir = try t.path("");
    option.privacy.state_filename = "wb.bin";
    var wb = wellbeing.Wellbeing.init(option);
    wb.data.today = .{ .day = 1000, .focus_s = 10 };
    try wb.sync(testing.io, "unused", 1000, .merge);
    try testing.expect((try storage.stamp(testing.io, try t.path(""), "wb.bin")).eql(.none));
    try testing.expectEqual(std.math.maxInt(u64), wb.msUntilSync(1_000_250));
}

test "sync: the event loop waits at most until the next second" {
    const wb = wellbeing.Wellbeing.init(quietOption());
    try testing.expectEqual(750, wb.msUntilSync(1_000_250));
    try testing.expectEqual(1000, wb.msUntilSync(1_000_000));
    try testing.expectEqual(1, wb.msUntilSync(-1));
}

test "sync: two windows' changes both reach the file and each other" {
    var t: StateTmp = .init();
    defer t.deinit();
    var a = try openShared(&t);
    defer a.close(testing.io);
    var b = try openShared(&t);
    defer b.close(testing.io);

    a.data.today.focus_s += 100;
    b.data.today.focus_s += 50;
    try a.sync(testing.io, "unused", 0, .merge);
    try b.sync(testing.io, "unused", 0, .merge);
    try testing.expectEqual(150, (try storage.load(testing.io, try t.path(""), "wb.bin")).today.focus_s);

    // A sees B's save on its next poll, before its next merge is due.
    a.data.today.focus_s += 1;
    try a.sync(testing.io, "unused", 10, .poll);
    try testing.expectEqual(151, a.data.today.focus_s);
    try testing.expectEqual(150, a.base.today.focus_s);
}

test "sync: a purge in one window is not undone by another" {
    var t: StateTmp = .init();
    defer t.deinit();
    var a = try openShared(&t);
    defer a.close(testing.io);
    var b = try openShared(&t);
    defer b.close(testing.io);

    a.data.today.focus_s = 100;
    try a.sync(testing.io, "unused", 0, .merge);
    try b.sync(testing.io, "unused", 0, .merge);
    b.data.today.focus_s += 30;
    try a.purgeHistory(testing.io, "unused", 1);
    try b.sync(testing.io, "unused", 2, .merge);

    const file = try storage.load(testing.io, try t.path(""), "wb.bin");
    try testing.expectEqual(0, file.today.focus_s);
    try testing.expectEqual(1, file.generation);
    try testing.expectEqual(0, b.data.today.focus_s);
}

test "sync: a poll merges only when the interval passed" {
    var t: StateTmp = .init();
    defer t.deinit();
    var a = try openShared(&t);
    defer a.close(testing.io);

    a.data.today.focus_s = 10;
    try a.sync(testing.io, "unused", 1000, .poll); // never merged: due
    a.data.today.focus_s = 20;
    try a.sync(testing.io, "unused", 1000 + 59, .poll);
    try testing.expectEqual(10, (try storage.load(testing.io, try t.path(""), "wb.bin")).today.focus_s);
    try a.sync(testing.io, "unused", 1000 + 60, .poll);
    try testing.expectEqual(20, (try storage.load(testing.io, try t.path(""), "wb.bin")).today.focus_s);
    // A clock set back by the interval is due too.
    a.data.today.focus_s = 30;
    try a.sync(testing.io, "unused", 1000, .poll);
    try testing.expectEqual(30, (try storage.load(testing.io, try t.path(""), "wb.bin")).today.focus_s);
}

test "sync: a held write lock makes a due poll wait instead of blocking" {
    var t: StateTmp = .init();
    defer t.deinit();
    var a = try openShared(&t);
    defer a.close(testing.io);

    const other = (try storage.tryLockWrite(testing.io, try t.path(""), "wb.bin")).?;
    a.data.today.focus_s = 10;
    try a.sync(testing.io, "unused", 1000, .poll);
    try testing.expect((try storage.stamp(testing.io, try t.path(""), "wb.bin")).eql(.none));
    other.release(testing.io);
    try a.sync(testing.io, "unused", 1001, .poll);
    try testing.expectEqual(10, (try storage.load(testing.io, try t.path(""), "wb.bin")).today.focus_s);
}

test "sync: a merge without changes does not rewrite the file" {
    var t: StateTmp = .init();
    defer t.deinit();
    var a = try openShared(&t);
    defer a.close(testing.io);

    a.data.today.focus_s = 10;
    try a.sync(testing.io, "unused", 1000, .merge);
    const before = try storage.stamp(testing.io, try t.path(""), "wb.bin");
    try a.sync(testing.io, "unused", 2000, .merge);
    try testing.expect(before.eql(try storage.stamp(testing.io, try t.path(""), "wb.bin")));
}

test "sync: an unreadable file is replaced by the next merge" {
    var t: StateTmp = .init();
    defer t.deinit();
    try t.tmp.dir.writeFile(testing.io, .{ .sub_path = "wb.bin", .data = "junk" });
    var option = quietOption();
    option.privacy.state_dir = try t.path("");
    option.privacy.state_filename = "wb.bin";
    var a = wellbeing.Wellbeing.init(option);
    try testing.expectError(error.InvalidStateFile, a.open(testing.io, "unused", 0));
    defer a.close(testing.io);
    try testing.expect(a.presence != null);

    _ = merge.rollover(&a.data, 1000);
    a.data.today.focus_s = 10;
    // Replacing the junk file logs a warning. That warning is expected
    // here; an unexpected one must still reach the build runner.
    const shown = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = shown;
    try a.sync(testing.io, "unused", 1000, .merge);
    try testing.expectEqual(10, (try storage.load(testing.io, try t.path(""), "wb.bin")).today.focus_s);
}

test "storage: DayRecord addAppTime accumulates and sorts properly" {
    var record = storage.DayRecord{};

    record.addAppTime("nvim", 120);
    record.addAppTime("nvim", 60);
    record.addAppTime("zsh", 30);
    record.addAppTime("claude", 90);

    try testing.expectEqualStrings("nvim", record.top_apps[0].getName());
    try testing.expectEqual(@as(u32, 180), record.top_apps[0].seconds);

    try testing.expectEqualStrings("zsh", record.top_apps[1].getName());
    try testing.expectEqual(@as(u32, 30), record.top_apps[1].seconds);

    try testing.expectEqualStrings("claude", record.top_apps[2].getName());
    try testing.expectEqual(@as(u32, 90), record.top_apps[2].seconds);
}

test "tracker: idle detection pauses screen time" {
    var tr = tracker.Tracker.init(.{
        .idle_threshold_ms = 60 * std.time.ms_per_s,
        .daily_limit_ms = 60 * std.time.ms_per_min,
        .track_foreground_apps = false,
    });

    var today = storage.DayRecord{};

    // Active for 30s
    _ = tr.tick(30, -1, &today);
    try testing.expect(!tr.is_idle);
    try testing.expectEqual(@as(u32, 30), today.active_screen_s);

    // Another 30s passes without activity -> user becomes idle
    _ = tr.tick(30, -1, &today);
    try testing.expect(tr.is_idle);

    // While idle, active screen time must not increment
    _ = tr.tick(30, -1, &today);
    try testing.expect(tr.is_idle);
    try testing.expectEqual(@as(u32, 60), today.active_screen_s);

    // User activity resumes
    tr.recordActivity();
    try testing.expect(!tr.is_idle);
    _ = tr.tick(10, -1, &today);
    try testing.expectEqual(@as(u32, 70), today.active_screen_s);
}

test "tracker: the grayscale fades in past the daily limit" {
    const option: tracker.TrackerOption = .{
        .daily_limit_ms = 1 * std.time.ms_per_min,
        .grayscale_transition_ms = 10 * std.time.ms_per_s,
    };
    var data: storage.PersistentData = .empty;

    data.today.active_screen_s = 50;
    try testing.expectEqual(@as(f32, 0.0), tracker.grayscale(&option, &data));
    data.today.active_screen_s = 65;
    try testing.expectEqual(@as(f32, 0.5), tracker.grayscale(&option, &data));
    data.today.active_screen_s = 75;
    try testing.expectEqual(@as(f32, 1.0), tracker.grayscale(&option, &data));

    // A dismissal moves the start of the limit later.
    data.limit_quiet_until_s = 70;
    try testing.expectEqual(70, tracker.limitStart(&option, &data).?);
    try testing.expectEqual(@as(f32, 0.5), tracker.grayscale(&option, &data));
    data.limit_quiet_until_s = std.math.maxInt(u32);
    try testing.expectEqual(@as(f32, 0.0), tracker.grayscale(&option, &data));
}

test "tracker: secondsCeil rounds a millisecond threshold up to whole seconds" {
    try testing.expectEqual(0, tracker.secondsCeil(0));
    try testing.expectEqual(1, tracker.secondsCeil(1));
    try testing.expectEqual(1, tracker.secondsCeil(1000));
    try testing.expectEqual(2, tracker.secondsCeil(1001));
    try testing.expectEqual(std.math.maxInt(u64) / 1000 + 1, tracker.secondsCeil(std.math.maxInt(u64)));
}

test "tracker and reminders: limits far beyond a day don't overflow" {
    // Minutes used to be multiplied by 60 in u32, which overflowed (a panic in
    // safe builds) for limits above about 71 million minutes.
    var tr = tracker.Tracker.init(.{
        .daily_limit_ms = std.math.maxInt(u64),
        .track_foreground_apps = false,
    });
    var data: storage.PersistentData = .empty;
    try testing.expectEqual(30, tr.tick(30, -1, &data.today));
    try testing.expectEqual(std.math.maxInt(u32), tracker.limitStart(&tr.option, &data).?);
    try testing.expectEqual(@as(f32, 0.0), tracker.grayscale(&tr.option, &data));
    var rem = reminders.RemindersEngine.init(
        .{ .interval_ms = std.math.maxInt(u64), .duration_ms = std.math.maxInt(u64) },
        .{ .interval_ms = std.math.maxInt(u64) },
    );
    // A due point of 0 anchors at the clock and does not fire.
    try testing.expectEqual(null, rem.tick(&data));
    try testing.expectEqual(30, data.eyesight_due_s);
    try testing.expectEqual(30, data.movement_due_s);
}

test "tracker: turning the limit or the grayscale off clears grayscale" {
    var option: tracker.TrackerOption = .{
        .daily_limit_ms = std.time.ms_per_min,
        .grayscale_transition_ms = std.time.ms_per_s,
    };
    var data: storage.PersistentData = .empty;
    data.today.active_screen_s = 70;
    try testing.expectEqual(@as(f32, 1.0), tracker.grayscale(&option, &data));

    option.on_limit.remove(.grayscale);
    try testing.expectEqual(@as(f32, 0.0), tracker.grayscale(&option, &data));

    option.on_limit.insert(.grayscale);
    try testing.expectEqual(@as(f32, 1.0), tracker.grayscale(&option, &data));

    option.daily_limit_ms = null;
    try testing.expectEqual(null, tracker.limitStart(&option, &data));
    try testing.expectEqual(@as(f32, 0.0), tracker.grayscale(&option, &data));
}

/// A window with a 2-minute daily limit and a 1-second fade.
fn limitOption() wellbeing.Option {
    var option = quietOption();
    option.screen_time.daily_limit_ms = 2 * std.time.ms_per_min;
    option.screen_time.grayscale_transition_ms = std.time.ms_per_s;
    return option;
}

test "limit: a dismissal lifts the grayscale until the next day" {
    var wb = wellbeing.Wellbeing.init(limitOption());
    const day_s = localAt(1000, 12, 0, 0);

    const reached = wb.tick(121_000, -1, day_s, 0);
    try testing.expectEqual(reminders.AlertKind.screen_limit, reached.alert.?.kind);
    try testing.expectEqual(@as(f32, 1.0), reached.grayscale);

    wb.dismissAlert();
    const lifted = wb.tick(1000, -1, day_s, 0);
    try testing.expect(lifted.needs_redraw);
    try testing.expectEqual(@as(f32, 0.0), lifted.grayscale);
    const later = wb.tick(60_000, -1, day_s, 0);
    try testing.expect(later.alert == null);
    try testing.expectEqual(@as(f32, 0.0), later.grayscale);

    // The next day starts with the limit armed again.
    const next_day_s = localAt(1001, 12, 0, 0);
    try testing.expectEqual(@as(f32, 0.0), wb.tick(60_000, -1, next_day_s, 0).grayscale);
    const again = wb.tick(61_000, -1, next_day_s, 0);
    try testing.expectEqual(reminders.AlertKind.screen_limit, again.alert.?.kind);
    try testing.expectEqual(@as(f32, 1.0), again.grayscale);
}

test "limit: a dismissal works after the alert has closed by itself" {
    var wb = wellbeing.Wellbeing.init(limitOption());
    const day_s = localAt(1000, 12, 0, 0);
    _ = wb.tick(121_000, -1, day_s, 0);
    const closed = wb.tick(20_000, -1, day_s, 0);
    try testing.expectEqual(reminders.AlertKind.none, wb.current_alert.kind);
    try testing.expectEqual(@as(f32, 1.0), closed.grayscale);

    wb.dismissAlert();
    try testing.expectEqual(@as(f32, 0.0), wb.tick(1000, -1, day_s, 0).grayscale);
}

test "limit: a dismissal below the limit changes nothing" {
    var wb = wellbeing.Wellbeing.init(limitOption());
    const day_s = localAt(1000, 12, 0, 0);
    _ = wb.tick(60_000, -1, day_s, 0);
    wb.dismissAlert();
    try testing.expectEqual(0, wb.data.limit_quiet_until_s);
    const reached = wb.tick(61_000, -1, day_s, 0);
    try testing.expectEqual(reminders.AlertKind.screen_limit, reached.alert.?.kind);
}

test "limit: one window alerts, every window turns gray and one dismissal lifts all" {
    var t: StateTmp = .init();
    defer t.deinit();
    var a = try openShared(&t);
    defer a.close(testing.io);
    var b = try openShared(&t);
    defer b.close(testing.io);
    for ([_]*wellbeing.Wellbeing{ &a, &b }) |wb| {
        var option = wb.option;
        option.screen_time = limitOption().screen_time;
        wb.applyOption(option);
    }
    const day_s = localAt(1000, 12, 0, 0);

    // A reaches the limit; a poll writes the alert it showed.
    b.windowFocusChanged(false);
    const reached = a.tick(121_000, -1, day_s, 0);
    try testing.expectEqual(reminders.AlertKind.screen_limit, reached.alert.?.kind);
    try a.sync(testing.io, "unused", 1000, .poll);

    // B, unfocused, turns gray from the shared data. Focused and active, it
    // does not show the alert again.
    try b.sync(testing.io, "unused", 1001, .poll);
    try testing.expectEqual(@as(f32, 1.0), b.tick(1000, -1, day_s, 0).grayscale);
    a.windowFocusChanged(false);
    b.windowFocusChanged(true);
    const second = b.tick(1000, -1, day_s, 0);
    try testing.expect(second.alert == null);
    try testing.expectEqual(@as(f32, 1.0), second.grayscale);

    // Dismissed in B, lifted in A within a poll.
    b.dismissAlert();
    try b.sync(testing.io, "unused", 1002, .poll);
    try a.sync(testing.io, "unused", 1003, .poll);
    try testing.expectEqual(@as(f32, 0.0), a.tick(1000, -1, day_s, 0).grayscale);
    try testing.expectEqual(@as(f32, 0.0), b.tick(1000, -1, day_s, 0).grayscale);
}

test "merge: the limit's state does not cross a day change" {
    var base: storage.PersistentData = .empty;
    base.today.day = 10;
    var view = base;
    view.limit_alerted_s = 120;
    view.limit_quiet_until_s = std.math.maxInt(u32);

    // Another window already started the next day.
    var fresh = base;
    _ = merge.rollover(&fresh, 11);
    const out = merge.rebase(&view, &base, &fresh);
    try testing.expectEqual(0, out.limit_alerted_s);
    try testing.expectEqual(0, out.limit_quiet_until_s);

    // On the same day the later value wins.
    fresh = base;
    fresh.limit_alerted_s = 60;
    const same = merge.rebase(&view, &base, &fresh);
    try testing.expectEqual(120, same.limit_alerted_s);
    try testing.expectEqual(std.math.maxInt(u32), same.limit_quiet_until_s);
}

/// Options for reload tests: no idle pause, no reminders, no wind-down,
/// so only the setting under test acts.
fn quietOption() wellbeing.Option {
    return .{
        .screen_time = .{ .idle_threshold_ms = 24 * std.time.ms_per_hour, .track_foreground_apps = false },
        .eyesight = .{ .enabled = false },
        .movement = .{ .enabled = false },
        .winddown = .{ .enabled = false },
    };
}

test "applyOption: reminders keep their due point and use the new interval" {
    var option = quietOption();
    option.eyesight = .{ .enabled = true, .interval_ms = 10 * std.time.ms_per_min };
    var wb = wellbeing.Wellbeing.init(option);
    const now = localAt(1000, 12, 0, 0);

    _ = wb.tick(std.time.ms_per_s, -1, now, 0);
    try testing.expectEqual(@as(u64, 1), wb.data.eyesight_due_s);

    option.eyesight.interval_ms = 4 * std.time.ms_per_min;
    wb.applyOption(option);
    try testing.expectEqual(@as(u64, 1), wb.data.eyesight_due_s);
    const early = wb.tick(3 * std.time.ms_per_min, -1, now, 0);
    try testing.expect(early.alert == null);
    const res = wb.tick(std.time.ms_per_min, -1, now, 0);
    try testing.expectEqual(reminders.AlertKind.eyesight, res.alert.?.kind);
}

test "applyOption: a running focus phase keeps its remaining time" {
    var option = quietOption();
    option.focus = .{ .task_ms = 25 * std.time.ms_per_min, .on_phase_end = .wait };
    var wb = wellbeing.Wellbeing.init(option);
    const now = localAt(1000, 12, 0, 0);

    wb.toggleFocus(0);
    _ = wb.tick(std.time.ms_per_min, -1, now, std.time.ms_per_min);
    try testing.expectEqual(24 * std.time.ms_per_min, wb.focus_state.remaining_ms);

    option.focus.task_ms = 10 * std.time.ms_per_min;
    wb.applyOption(option);
    try testing.expectEqual(wellbeing.focus.Phase.task, wb.focus_state.phase);
    try testing.expectEqual(24 * std.time.ms_per_min, wb.focus_state.remaining_ms);
    try testing.expectEqual(10 * std.time.ms_per_min, wb.focus_state.option.task_ms);
}

test "applyOption: the configured on_phase_end replaces a runtime toggle" {
    var option = quietOption();
    option.focus = .{ .task_ms = 2000, .short_break_ms = 1000, .on_phase_end = .wait };
    var wb = wellbeing.Wellbeing.init(option);
    const now = localAt(1000, 12, 0, 0);

    wb.toggleFocusPhaseEnd();
    try testing.expectEqual(.start_next, wb.focus_state.option.on_phase_end);
    wb.applyOption(option);
    try testing.expectEqual(.wait, wb.focus_state.option.on_phase_end);

    // A phase waiting for confirmation starts on the next tick once the
    // config turns auto on.
    wb.toggleFocus(0);
    _ = wb.tick(2000, -1, now, 2000);
    try testing.expect(wb.focus_state.waiting);
    option.focus.on_phase_end = .start_next;
    wb.applyOption(option);
    _ = wb.tick(10, -1, now, 2010);
    try testing.expect(!wb.focus_state.waiting);
    try testing.expectEqual(wellbeing.focus.Phase.short_break, wb.focus_state.phase);
}

test "applyOption: turning wind-down on applies on the next tick" {
    var option = quietOption();
    var wb = wellbeing.Wellbeing.init(option);
    const night = localAt(1000, 22, 0, 0);

    try testing.expectEqual(@as(f32, 1.0), wb.tick(1000, -1, night, 0).tint[2]);
    option.winddown.enabled = true;
    wb.applyOption(option);
    try testing.expect(wb.tick(1000, -1, night, 0).tint[2] < 1.0);
}

test "reminders: a zero due point anchors without firing, then one interval fires" {
    var rem = reminders.RemindersEngine.init(
        .{ .interval_ms = 60 * std.time.ms_per_s, .duration_ms = 20 * std.time.ms_per_s },
        .{ .enabled = false },
    );
    var data: storage.PersistentData = .empty;
    data.today.active_screen_s = 50;

    try testing.expectEqual(null, rem.tick(&data));
    try testing.expectEqual(50, data.eyesight_due_s);
    try testing.expectEqual(0, data.today.eyesight_breaks);

    data.today.active_screen_s = 110;
    const alert = rem.tick(&data);
    try testing.expectEqual(reminders.AlertKind.eyesight, alert.?.kind);
    try testing.expectEqual(@as(u16, 1), data.today.eyesight_breaks);
    try testing.expectEqual(110, data.eyesight_due_s);
}

test "reminders: missed intervals fire once and snap to the grid" {
    var rem = reminders.RemindersEngine.init(
        .{ .interval_ms = 60 * std.time.ms_per_s },
        .{ .enabled = false },
    );
    var data: storage.PersistentData = .empty;
    data.eyesight_due_s = 10;
    data.today.active_screen_s = 10 + 60 * 5 + 5;

    const alert = rem.tick(&data);
    try testing.expectEqual(reminders.AlertKind.eyesight, alert.?.kind);
    try testing.expectEqual(@as(u16, 1), data.today.eyesight_breaks);
    try testing.expectEqual(310, data.eyesight_due_s);
    try testing.expectEqual(null, rem.tick(&data));
}

test "reminders: a zero due point does not fire on a clock that is already far ahead" {
    var option = quietOption();
    option.eyesight.enabled = true;
    option.movement.enabled = true;
    var wb = wellbeing.Wellbeing.init(option);
    wb.data.total_active_screen_s = 50_000;
    wb.data.today.active_screen_s = 10_000;

    const res = wb.tick(1000, -1, localAt(1000, 12, 0, 0), 0);
    try testing.expect(res.alert == null);
    try testing.expectEqual(0, wb.data.today.eyesight_breaks);
    try testing.expectEqual(0, wb.data.today.movement_breaks);
    const clock = wb.data.activeClock();
    try testing.expectEqual(clock, wb.data.eyesight_due_s);
    try testing.expectEqual(clock, wb.data.movement_due_s);
}

test "reminders: an unfocused window does not fire" {
    var option = quietOption();
    option.eyesight = .{ .enabled = true, .interval_ms = 60 * std.time.ms_per_s, .animation = .none };
    var wb = wellbeing.Wellbeing.init(option);
    wb.data.eyesight_due_s = 10;
    wb.data.today.active_screen_s = 100;
    wb.windowFocusChanged(false);

    const held = wb.tick(60_000, -1, localAt(1000, 12, 0, 0), 0);
    try testing.expect(held.alert == null);
    try testing.expectEqual(10, wb.data.eyesight_due_s);
    try testing.expectEqual(0, wb.data.today.eyesight_breaks);
    try testing.expectEqual(100, wb.data.today.active_screen_s);

    wb.windowFocusChanged(true);
    const fired = wb.tick(0, -1, localAt(1000, 12, 0, 0), 0);
    try testing.expectEqual(reminders.AlertKind.eyesight, fired.alert.?.kind);
}

test "reminders: a reminder due during another alert waits" {
    var option = quietOption();
    option.eyesight = .{ .enabled = true, .interval_ms = 60 * std.time.ms_per_s, .animation = .none };
    var wb = wellbeing.Wellbeing.init(option);
    wb.data.eyesight_due_s = 10;
    wb.data.today.active_screen_s = 100;
    wb.current_alert = .{ .kind = .screen_limit, .remaining_s = 20, .prompt = "limit" };

    const held = wb.tick(0, -1, localAt(1000, 12, 0, 0), 0);
    try testing.expect(held.alert == null);
    try testing.expectEqual(10, wb.data.eyesight_due_s);
    try testing.expectEqual(0, wb.data.today.eyesight_breaks);

    wb.dismissAlert();
    const fired = wb.tick(0, -1, localAt(1000, 12, 0, 0), 0);
    try testing.expectEqual(reminders.AlertKind.eyesight, fired.alert.?.kind);
    try testing.expectEqual(@as(u16, 1), wb.data.today.eyesight_breaks);
}

test "reminders: two reminders due together show one after the other" {
    var option = quietOption();
    option.eyesight = .{
        .enabled = true,
        .interval_ms = 60 * std.time.ms_per_s,
        .duration_ms = 20 * std.time.ms_per_s,
        .animation = .none,
    };
    option.movement = .{
        .enabled = true,
        .interval_ms = 60 * std.time.ms_per_s,
        .duration_ms = 20 * std.time.ms_per_s,
        .animation = .none,
    };
    var wb = wellbeing.Wellbeing.init(option);
    wb.data.eyesight_due_s = 10;
    wb.data.movement_due_s = 10;
    wb.data.today.active_screen_s = 10_000;

    const first = wb.tick(0, -1, localAt(1000, 12, 0, 0), 0);
    try testing.expectEqual(reminders.AlertKind.movement, first.alert.?.kind);
    try testing.expectEqual(@as(u16, 1), wb.data.today.movement_breaks);
    try testing.expectEqual(@as(u16, 0), wb.data.today.eyesight_breaks);
    try testing.expectEqual(10, wb.data.eyesight_due_s);

    const during = wb.tick(1000, -1, localAt(1000, 12, 0, 0), 0);
    try testing.expect(during.alert == null);
    try testing.expectEqual(10, wb.data.eyesight_due_s);
    try testing.expectEqual(reminders.AlertKind.movement, wb.current_alert.kind);

    wb.dismissAlert();
    const second = wb.tick(0, -1, localAt(1000, 12, 0, 0), 0);
    try testing.expectEqual(reminders.AlertKind.eyesight, second.alert.?.kind);
    try testing.expectEqual(@as(u16, 1), wb.data.today.eyesight_breaks);
}

test "reminders: a new day does not restart the clock" {
    var option = quietOption();
    option.eyesight = .{ .enabled = true, .interval_ms = 60 * std.time.ms_per_s, .animation = .none };
    var wb = wellbeing.Wellbeing.init(option);
    const day1 = localAt(1000, 12, 0, 0);
    const day2 = localAt(1001, 12, 0, 0);

    _ = wb.tick(30_000, -1, day1, 0);
    try testing.expectEqual(30, wb.data.eyesight_due_s);
    const clock = wb.data.activeClock();
    const rolled = wb.tick(0, -1, day2, 0);
    try testing.expect(rolled.alert == null);
    try testing.expectEqual(clock, wb.data.activeClock());
    try testing.expectEqual(30, wb.data.eyesight_due_s);

    const fired = wb.tick(60_000, -1, day2, 0);
    try testing.expectEqual(reminders.AlertKind.eyesight, fired.alert.?.kind);
    try testing.expectEqual(@as(u16, 1), wb.data.today.eyesight_breaks);
    try testing.expectEqual(@as(u16, 0), wb.data.history[0].eyesight_breaks);
}

test "reminders: a focus switch just after a due point counts the break once" {
    var t: StateTmp = .init();
    defer t.deinit();
    var a = try openReminders(&t);
    defer a.close(testing.io);
    var b = try openReminders(&t);
    defer b.close(testing.io);
    const day_s = localAt(1000, 12, 0, 0);

    b.windowFocusChanged(false);
    _ = a.tick(1000, -1, day_s, 0);
    try a.sync(testing.io, "unused", 10, .merge);
    try b.sync(testing.io, "unused", 10, .poll);

    const fired = a.tick(60_000, -1, day_s, 0);
    try testing.expectEqual(reminders.AlertKind.eyesight, fired.alert.?.kind);
    a.windowFocusChanged(false);
    try a.sync(testing.io, "unused", 11, .merge);

    b.windowFocusChanged(true);
    try b.sync(testing.io, "unused", 11, .poll);
    const quiet = b.tick(1000, -1, day_s, 0);
    try testing.expect(quiet.alert == null);
    const file = try storage.load(testing.io, try t.path(""), "wb.bin");
    try testing.expectEqual(@as(u16, 1), file.today.eyesight_breaks);
    try testing.expectEqual(@as(u64, 61), file.eyesight_due_s);
}

test "reminders: two windows that cross the same due point count one break" {
    var t: StateTmp = .init();
    defer t.deinit();
    var a = try openReminders(&t);
    defer a.close(testing.io);
    var b = try openReminders(&t);
    defer b.close(testing.io);
    const day_s = localAt(1000, 12, 0, 0);

    b.windowFocusChanged(false);
    _ = a.tick(1000, -1, day_s, 0);
    try a.sync(testing.io, "unused", 10, .merge);
    try b.sync(testing.io, "unused", 10, .poll);

    b.windowFocusChanged(true);
    const from_a = a.tick(60_000, -1, day_s, 0);
    const from_b = b.tick(60_000, -1, day_s, 0);
    try testing.expectEqual(reminders.AlertKind.eyesight, from_a.alert.?.kind);
    try testing.expectEqual(reminders.AlertKind.eyesight, from_b.alert.?.kind);
    try testing.expectEqual(61, a.data.eyesight_due_s);
    try testing.expectEqual(61, b.data.eyesight_due_s);

    try a.sync(testing.io, "unused", 11, .merge);
    try b.sync(testing.io, "unused", 11, .merge);
    const file = try storage.load(testing.io, try t.path(""), "wb.bin");
    try testing.expectEqual(@as(u16, 1), file.today.eyesight_breaks);
    try testing.expectEqual(@as(u64, 61), file.eyesight_due_s);
}

test "winddown: schedule window and color warmth tint" {
    var wd = winddown.WinddownEngine.init(.{
        .enabled = true,
        .start = .{ .hour = 21, .minute = 0 },
        .end = .{ .hour = 7, .minute = 0 },
        .warmth_factor = 0.85,
    });

    // 12:00 PM (43200 seconds into day) -> Daytime, not active
    const day_res = wd.update(43200);
    try testing.expect(!day_res.active);
    try testing.expectEqual(@as(f32, 1.0), day_res.color_tint[0]);
    try testing.expectEqual(@as(f32, 1.0), day_res.color_tint[1]);
    try testing.expectEqual(@as(f32, 1.0), day_res.color_tint[2]);

    // 22:00 (79200 seconds into day) -> Nighttime, active
    const night_res = wd.update(79200);
    try testing.expect(night_res.active);
    try testing.expect(night_res.just_started);
    try testing.expectEqual(@as(f32, 1.0), night_res.color_tint[0]); // Red stays 1.0
    try testing.expect(night_res.color_tint[2] < 0.80); // Blue is attenuated
}

/// Local seconds for `hour:minute` UTC on epoch day `day` in a zone
/// `offset_h` hours east of UTC.
fn localAt(day: i64, hour: i64, minute: i64, offset_h: i64) i64 {
    const utc_s = day * std.time.s_per_day + hour * std.time.s_per_hour + minute * std.time.s_per_min;
    return utc_s + offset_h * std.time.s_per_hour;
}

test "winddown: window follows local time east and west of UTC" {
    var wd = winddown.WinddownEngine.init(.{
        .enabled = true,
        .start = .{ .hour = 21, .minute = 0 },
        .end = .{ .hour = 7, .minute = 0 },
    });

    // 14:30 UTC is 21:30 in UTC+7 and 09:30 in UTC-5.
    try testing.expect(wd.update(localAt(1000, 14, 30, 7)).active);
    try testing.expect(!wd.update(localAt(1000, 14, 30, -5)).active);

    // 03:00 UTC is 10:00 in UTC+7 and 22:00 the day before in UTC-5.
    try testing.expect(!wd.update(localAt(1000, 3, 0, 7)).active);
    try testing.expect(wd.update(localAt(1000, 3, 0, -5)).active);
}

test "winddown: window crossing midnight includes start and excludes end" {
    var wd = winddown.WinddownEngine.init(.{
        .enabled = true,
        .start = .{ .hour = 21, .minute = 0 },
        .end = .{ .hour = 7, .minute = 0 },
    });

    // Local times in UTC-5: 21:00 is 02:00 UTC the next day.
    try testing.expect(!wd.update(localAt(1001, 1, 59, -5)).active); // 20:59
    const start = wd.update(localAt(1001, 2, 0, -5)); // 21:00
    try testing.expect(start.active);
    try testing.expect(start.just_started);
    try testing.expect(wd.update(localAt(1001, 5, 0, -5)).active); // 00:00
    try testing.expect(wd.update(localAt(1001, 11, 59, -5)).active); // 06:59
    try testing.expect(!wd.update(localAt(1001, 12, 0, -5)).active); // 07:00
}

test "winddown: during_window without warm_colors keeps the colors" {
    var wd = winddown.WinddownEngine.init(.{ .enabled = true, .during_window = .initOne(.mute_bell) });
    const res = wd.update(localAt(1000, 22, 0, 0));
    try testing.expect(res.active);
    try testing.expectEqual([3]f32{ 1.0, 1.0, 1.0 }, res.color_tint);
}

test "focus: on_break lock_input alone locks the break without a prompt" {
    var option = quietOption();
    option.focus = .{ .task_ms = 1000, .short_break_ms = 60_000, .on_phase_end = .start_next, .on_break = .initOne(.lock_input) };
    var wb = wellbeing.Wellbeing.init(option);
    wb.toggleFocus(0);
    const res = wb.tick(1000, -1, localAt(1000, 12, 0, 0), 1000);
    try testing.expectEqual(wellbeing.focus.Phase.short_break, wb.focus_state.phase);
    try testing.expect(res.alert == null);
    try testing.expect(res.input_locked);
}

test "Wellbeing service: day rolls over at local midnight" {
    var wb = wellbeing.Wellbeing.init(.{ .winddown = .{ .enabled = false } });

    // In UTC+7, 16:59 UTC is 23:59 local on day 1000.
    _ = wb.tick(1000, -1, localAt(1000, 16, 59, 7), 0);
    try testing.expectEqual(@as(u32, 1000), wb.data.today.day);

    // 17:00 UTC is still UTC day 1000 but local midnight of day 1001.
    _ = wb.tick(1000, -1, localAt(1000, 17, 0, 7), 0);
    try testing.expectEqual(@as(u32, 1001), wb.data.today.day);
    try testing.expectEqual(@as(u32, 1), wb.data.history_count);
    try testing.expectEqual(@as(u32, 1000), wb.data.history[0].day);
}

test "focus: streak counts local days" {
    var wb = wellbeing.Wellbeing.init(.{
        .focus = .{ .task_ms = 1000, .on_phase_end = .wait },
        .winddown = .{ .enabled = false },
    });

    // In UTC-5, both tasks end on UTC day 1001 but on consecutive local days:
    // 04:30 UTC is 23:30 on local day 1000, 05:30 UTC is 00:30 on day 1001.
    wb.toggleFocus(0);
    _ = wb.tick(1000, -1, localAt(1001, 4, 30, -5), 1000);
    try testing.expectEqual(@as(u32, 1000), wb.data.last_task_day);
    try testing.expectEqual(@as(u32, 1), wb.data.current_streak);

    wb.resetFocus(2000);
    wb.toggleFocus(2000);
    _ = wb.tick(1000, -1, localAt(1001, 5, 30, -5), 3000);
    try testing.expectEqual(@as(u32, 1001), wb.data.last_task_day);
    try testing.expectEqual(@as(u32, 2), wb.data.current_streak);
}

test "focus: a task on an earlier local day keeps the streak" {
    var wb = wellbeing.Wellbeing.init(.{
        .focus = .{ .task_ms = 1000, .on_phase_end = .wait },
        .winddown = .{ .enabled = false },
    });
    wb.data.current_streak = 3;
    wb.data.last_task_day = 999;

    // A task on day 1000 in UTC+9, then the zone moves to UTC-8 and the next
    // task lands on local day 999.
    wb.toggleFocus(0);
    _ = wb.tick(1000, -1, localAt(1000, 0, 0, 9), 1000);
    try testing.expectEqual(@as(u32, 1000), wb.data.last_task_day);
    try testing.expectEqual(@as(u32, 4), wb.data.current_streak);

    wb.resetFocus(2000);
    wb.toggleFocus(2000);
    _ = wb.tick(1000, -1, localAt(1000, 1, 0, -8), 3000);
    try testing.expectEqual(@as(u32, 1000), wb.data.last_task_day);
    try testing.expectEqual(@as(u32, 4), wb.data.current_streak);
}

test "Wellbeing service: a clock before 1970 does not track days" {
    var wb = wellbeing.Wellbeing.init(.{
        .focus = .{ .task_ms = 1000, .on_phase_end = .wait },
        .winddown = .{ .enabled = false },
    });

    // 1970-01-01T00:00Z in UTC-5 is local second -18000.
    wb.toggleFocus(0);
    _ = wb.tick(1000, -1, -5 * std.time.s_per_hour, 1000);
    try testing.expectEqual(@as(u32, 0), wb.data.today.day);
    try testing.expectEqual(@as(u32, 0), wb.data.last_task_day);
}

test "localtime: offset of the system zone is plausible and cached" {
    // 2026-01-01T00:00:00Z. The value depends on the host's zone, so only
    // the range is checked (real zones span UTC-12 to UTC+14).
    const utc_s: i64 = 1_767_225_600;
    const offset_s = localtime.utcOffset(utc_s) orelse return error.TestUnexpectedResult;
    try testing.expect(offset_s >= -12 * std.time.s_per_hour);
    try testing.expect(offset_s <= 14 * std.time.s_per_hour);

    var clock: localtime.Clock = .{};
    try testing.expectEqual(utc_s + offset_s, clock.localSeconds(utc_s));
    try testing.expectEqual(utc_s + offset_s, clock.localSeconds(utc_s));
}

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

test "localtime: Clock notices a changed TZ in the next minute" {
    // `TZ` is process-wide; the test runner runs tests one at a time.
    var saved_buf: [256]u8 = undefined;
    const saved: ?[:0]const u8 = if (std.c.getenv("TZ")) |value| blk: {
        const len = std.mem.len(value);
        if (len >= saved_buf.len) return error.SkipZigTest;
        @memcpy(saved_buf[0..len], value[0..len]);
        saved_buf[len] = 0;
        break :blk saved_buf[0..len :0];
    } else null;
    defer {
        if (saved) |value| {
            _ = setenv("TZ", value.ptr, 1);
        } else {
            _ = unsetenv("TZ");
        }
        // A fresh Clock calls tzset on its first conversion, so libc goes
        // back to the host's zone for the tests that follow.
        var restore: localtime.Clock = .{};
        _ = restore.localSeconds(0);
    }

    const utc_s: i64 = 1_767_225_600; // 2026-01-01T00:00:00Z
    try testing.expectEqual(0, setenv("TZ", "UTC0", 1));
    var clock: localtime.Clock = .{};
    try testing.expectEqual(utc_s, clock.localSeconds(utc_s));

    try testing.expectEqual(0, setenv("TZ", "<+05>-5", 1));
    const later_s = utc_s + std.time.s_per_min;
    try testing.expectEqual(later_s + 5 * std.time.s_per_hour, clock.localSeconds(later_s));

    // A wall clock set back an hour is also due for a check.
    try testing.expectEqual(0, setenv("TZ", "UTC0", 1));
    const earlier_s = later_s - std.time.s_per_hour;
    try testing.expectEqual(earlier_s, clock.localSeconds(earlier_s));
}

test "dashboard: renders card output cleanly" {
    var data = storage.PersistentData{};
    data.today.active_screen_s = 7200; // 2 hours
    data.today.focus_s = 3600; // 1 hour
    data.today.break_s = 600; // 10 min
    data.today.tasks_completed = 4;
    data.current_streak = 3;
    data.best_streak = 7;
    data.today.addAppTime("nvim", 4800);
    data.today.addAppTime("claude", 2400);

    var buf: [2048]u8 = undefined;
    const card = dashboard.render(&data, 4 * std.time.ms_per_hour, &buf);
    try testing.expect(card.len > 0);
    try testing.expect(std.mem.indexOf(u8, card, "REX DIGITAL WELLBEING") != null);
    try testing.expect(std.mem.indexOf(u8, card, "nvim") != null);
    try testing.expect(std.mem.indexOf(u8, card, "claude") != null);
}

test "Wellbeing service: day rollover and streaks" {
    var wb = wellbeing.Wellbeing.init(.{});

    // Day 1000
    const day1_s: i64 = 1000 * std.time.s_per_day + 3600;
    _ = wb.tick(1000, -1, day1_s, 0);
    try testing.expectEqual(@as(u32, 1000), wb.data.today.day);

    wb.data.today.tasks_completed = 2;
    wb.data.today.focus_s = 3000;

    // Day 1001 (rollover)
    const day2_s: i64 = 1001 * std.time.s_per_day + 3600;
    _ = wb.tick(1000, -1, day2_s, 0);

    try testing.expectEqual(@as(u32, 1001), wb.data.today.day);
    try testing.expectEqual(@as(u32, 1), wb.data.history_count);
    try testing.expectEqual(@as(u32, 1000), wb.data.history[0].day);
    try testing.expectEqual(@as(u16, 2), wb.data.history[0].tasks_completed);
    try testing.expectEqual(@as(u32, 3000), wb.data.history[0].focus_s);
}

test "focus: session toggle, tick, and break prompt rotation" {
    var wb = wellbeing.Wellbeing.init(.{
        .focus = .{
            .task_ms = 2000,
            .short_break_ms = 1000,
            .long_break_ms = 3000,
            .tasks_before_long_break = 2,
            .on_phase_end = .start_next,
        },
    });

    try testing.expectEqual(wellbeing.focus.Phase.idle, wb.focus_state.phase);
    wb.toggleFocus(0);
    try testing.expectEqual(wellbeing.focus.Phase.task, wb.focus_state.phase);

    const day1_s: i64 = 1000 * std.time.s_per_day + 3600;
    const res = wb.tick(2000, -1, day1_s, 2000);
    try testing.expect(res.phase_changed);
    try testing.expectEqual(wellbeing.focus.Phase.short_break, wb.focus_state.phase);
    try testing.expectEqual(@as(u16, 1), wb.data.today.tasks_completed);
    try testing.expectEqual(@as(u32, 1), wb.data.current_streak);
    try testing.expect(res.alert != null);
    try testing.expectEqual(reminders.AlertKind.healthy_break, res.alert.?.kind);
}

test "reminders: lock_input and animation wave modulation" {
    var wb = wellbeing.Wellbeing.init(.{
        .eyesight = .{
            .enabled = true,
            .interval_ms = 1 * std.time.ms_per_min,
            .duration_ms = 20 * std.time.ms_per_s,
            .during_reminder = .initOne(.lock_input),
            .animation = .pulse_dim,
        },
        .winddown = .{
            .enabled = false,
        },
    });

    const day1_s: i64 = 1000 * std.time.s_per_day + 3600;
    // The first sight of the clock starts the interval and does not fire.
    const started = wb.tick(1000, -1, day1_s, 0);
    try testing.expect(started.alert == null);
    const res1 = wb.tick(60_000, -1, day1_s, 0);
    try testing.expect(res1.alert != null);
    try testing.expect(res1.input_locked);

    // Tick 2000ms (peak of 4000ms cosine wave -> dim factor applied to tint)
    const res2 = wb.tick(2000, -1, day1_s, 0);
    try testing.expect(res2.input_locked);
    try testing.expect(res2.tint[0] < 0.70);

    // Dismiss alert unlocks input and restores normal tint
    wb.dismissAlert();
    const res3 = wb.tick(100, -1, day1_s, 0);
    try testing.expect(!res3.input_locked);
    try testing.expectEqual(@as(f32, 1.0), res3.tint[0]);
}

test "focus: on_alert pause holds the task during a locking reminder and moves its end" {
    var wb = wellbeing.Wellbeing.init(.{
        .focus = .{
            .task_ms = 120_000,
            .short_break_ms = 10_000,
            .on_alert = .initOne(.pause),
        },
        .eyesight = .{
            .enabled = true,
            .interval_ms = 1 * std.time.ms_per_min,
            .duration_ms = 10 * std.time.ms_per_s,
            .during_reminder = .initOne(.lock_input),
            .animation = .none,
        },
        .winddown = .{ .enabled = false },
    });
    const day1_s: i64 = 1000 * std.time.s_per_day + 3600;

    wb.toggleFocus(0);
    try testing.expectEqual(@as(u64, 120_000), wb.focus_state.remaining_ms);
    // 10 s anchors the reminder (a due point of 0 does not fire) and leaves 110 s.
    _ = wb.tick(10_000, -1, day1_s, 10_000);
    try testing.expectEqual(@as(u64, 110_000), wb.focus_state.remaining_ms);

    // One interval later the reminder locks input. The task ends at 120 s
    // and the display holds the 50 s left when the reminder appeared.
    const res_alert = wb.tick(60_000, -1, day1_s, 70_000);
    try testing.expect(res_alert.alert != null);
    try testing.expect(res_alert.input_locked);
    try testing.expect(wb.isFocusPausedByAlert());
    try testing.expectEqual(@as(u64, 50_000), wb.focus_state.remaining_ms);
    _ = wb.tick(5_000, -1, day1_s, 75_000);
    try testing.expectEqual(@as(u64, 50_000), wb.focus_state.remaining_ms);

    // Shown for 10 s: the end moves from 120 s to 130 s, so 50 s are left.
    wb.dismissAlert();
    try testing.expect(!wb.isFocusPausedByAlert());
    _ = wb.tick(5_000, -1, day1_s, 80_000);
    try testing.expectEqual(@as(u64, 50_000), wb.focus_state.remaining_ms);
    try testing.expectEqual(130_000, wb.timer().ms);
}

test "overlay: state flags and active detection" {
    var ov = wellbeing.overlay.Overlay.init();
    defer ov.deinit(testing.allocator);

    try testing.expect(!ov.isActive());

    ov.dashboard_open = true;
    try testing.expect(ov.isActive());
    ov.dashboard_open = false;
    try testing.expect(!ov.isActive());

    ov.toast_active = true;
    try testing.expect(ov.isActive());
    ov.toast_active = false;

    ov.lock_screen_active = true;
    try testing.expect(ov.isActive());
}

test "overlay: box and progress bar arithmetic" {
    var ov = wellbeing.overlay.Overlay.init();
    defer ov.deinit(testing.allocator);

    // drawBox creates 1 Background.Instance per row
    ov.drawBox(testing.allocator, 10, 5, 40, 6, .{ 20, 30, 40, 255 });
    try testing.expectEqual(@as(usize, 6), ov.bg_buffer.items.len);
    for (ov.bg_buffer.items, 0..) |inst, i| {
        try testing.expectEqual(@as(u16, 10), inst.col);
        try testing.expectEqual(@as(u16, @intCast(5 + i)), inst.row);
        try testing.expectEqual(@as(u16, 40), inst.span);
        try testing.expectEqual(@as(u8, 20), inst.r);
        try testing.expectEqual(@as(u8, 30), inst.g);
        try testing.expectEqual(@as(u8, 40), inst.b);
        try testing.expectEqual(@as(u8, 255), inst.a);
    }
}

test "icons: glyph lookup and styles" {
    const ic = wellbeing.icons;

    // Unicode glyphs
    try testing.expectEqualStrings("✓", ic.getGlyph(.check, .unicode));
    try testing.expectEqualStrings("✕", ic.getGlyph(.error_icon, .unicode));
    try testing.expectEqualStrings("▲", ic.getGlyph(.warning, .unicode));
    try testing.expectEqualStrings("ℹ", ic.getGlyph(.info, .unicode));
    try testing.expectEqualStrings("■", ic.getGlyph(.lock, .unicode));

    // ASCII glyphs
    try testing.expectEqualStrings("[v]", ic.getGlyph(.check, .ascii));
    try testing.expectEqualStrings("[x]", ic.getGlyph(.error_icon, .ascii));
    try testing.expectEqualStrings("[!]", ic.getGlyph(.warning, .ascii));
    try testing.expectEqualStrings("[i]", ic.getGlyph(.info, .ascii));
    try testing.expectEqualStrings("[#]", ic.getGlyph(.lock, .ascii));

    // Nerd Font glyphs
    try testing.expectEqualStrings("\u{eab2}", ic.getGlyph(.check, .nerd_font));
    try testing.expectEqualStrings("\u{ea87}", ic.getGlyph(.error_icon, .nerd_font));
    try testing.expectEqualStrings("\u{ea6c}", ic.getGlyph(.warning, .nerd_font));
    try testing.expectEqualStrings("\u{f023}", ic.getGlyph(.lock, .nerd_font));

    // Width
    try testing.expectEqual(@as(u16, 1), ic.glyphWidth("✓"));
    try testing.expectEqual(@as(u16, 3), ic.glyphWidth("[v]"));
}

test "overlay: stringWidth and description word wrap" {
    const ov = wellbeing.overlay;

    // Width of standard ASCII
    try testing.expectEqual(@as(u16, 5), ov.stringWidth("hello"));

    // Width with emojis
    const coffee_w = ov.stringWidth("☕");
    try testing.expect(coffee_w >= 1);

    // Word wrap: short string does not wrap
    const short_desc = "Short notice";
    const split_short = ov.splitDescription(short_desc, 30);
    try testing.expectEqualStrings("Short notice", split_short.line1);
    try testing.expectEqualStrings("", split_short.line2);

    // Word wrap: long string splits cleanly on word boundary
    const long_desc = "Look at an object 20 feet away for 20 seconds to relax your eyes";
    const split_long = ov.splitDescription(long_desc, 34);
    try testing.expect(split_long.line1.len > 0);
    try testing.expect(split_long.line2.len > 0);
    try testing.expect(ov.stringWidth(split_long.line1) <= 34);
}

test "overlay: cleanPromptText removes trailing emojis and symbols" {
    const ov = wellbeing.overlay;

    try testing.expectEqualStrings(
        "Look at an object 20 feet away for 20 seconds",
        ov.cleanPromptText("Look at an object 20 feet away for 20 seconds 👀"),
    );

    try testing.expectEqualStrings(
        "Time to stand up, stretch your back, and move",
        ov.cleanPromptText("Time to stand up, stretch your back, and move 🚶"),
    );

    try testing.expectEqualStrings(
        "Stay hydrated: drink some fresh water",
        ov.cleanPromptText("Stay hydrated: drink some fresh water 💧"),
    );

    try testing.expectEqualStrings(
        "Check posture: roll shoulders back, align neck",
        ov.cleanPromptText("Check posture: roll shoulders back, align neck 🪑"),
    );

    try testing.expectEqualStrings(
        "Daily screen-time limit reached",
        ov.cleanPromptText("Daily screen-time limit reached 🛑"),
    );

    try testing.expectEqualStrings(
        "Hydrate: drink a cool glass of fresh water",
        ov.cleanPromptText("Hydrate: drink a cool glass of fresh water 💧."),
    );

    try testing.expectEqualStrings(
        "Box breathing: Inhale 4s, Hold 4s, Exhale 4s, Hold 4s",
        ov.cleanPromptText("Box breathing: Inhale 4s, Hold 4s, Exhale 4s, Hold 4s 🧘."),
    );

    try testing.expectEqualStrings(
        "Roll your shoulders backward and release tension in your neck.",
        ov.cleanPromptText("Roll your shoulders backward and release tension in your neck."),
    );
}

test "overlay: panel rectangle geometry and bounds" {
    const PanelRect = wellbeing.overlay.PanelRect;
    const rect = PanelRect{ .col = 10, .row = 5, .width = 40, .height = 12 };

    try testing.expectEqual(@as(u16, 50), rect.maxCol());
    try testing.expectEqual(@as(u16, 17), rect.maxRow());
    try testing.expectEqual(@as(u16, 11), rect.innerCol());
    try testing.expectEqual(@as(u16, 6), rect.innerRow());
    try testing.expectEqual(@as(u16, 48), rect.innerMaxCol());
    try testing.expectEqual(@as(u16, 15), rect.innerMaxRow());
    try testing.expectEqual(@as(u16, 38), rect.innerWidth());
    try testing.expectEqual(@as(u16, 10), rect.innerHeight());
}

test "overlay: drawDimmingBackdropOutside leaves panel interior untouched" {
    var ov = wellbeing.overlay.Overlay.init();
    defer ov.deinit(testing.allocator);

    const total_cols: u16 = 80;
    const total_rows: u16 = 24;
    const rect = wellbeing.overlay.PanelRect{ .col = 20, .row = 6, .width = 40, .height = 12 };
    const dim_color: [4]u8 = .{ 13, 13, 13, 180 };

    ov.drawDimmingBackdropOutside(testing.allocator, total_cols, total_rows, rect, dim_color);

    // Verify all generated background quads are strictly OUTSIDE rect
    for (ov.bg_buffer.items) |bg| {
        if (bg.row >= rect.row and bg.row < rect.maxRow()) {
            const quad_start = bg.col;
            const quad_end = bg.col + bg.span;
            const inside_dialog = (quad_start < rect.maxCol() and quad_end > rect.col);
            try testing.expect(!inside_dialog);
        }
    }
}

test "overlay: dashboard layout geometry and symmetric padding" {
    // Verify symmetric padding: 3 columns margin on both left and right
    const rect = wellbeing.overlay.PanelRect{ .col = 7, .row = 2, .width = 66, .height = 15 };
    const content_col = rect.col + 3; // 10
    const max_content_col = rect.col + rect.width - 4; // 69

    try testing.expectEqual(@as(u16, 10), content_col);
    try testing.expectEqual(@as(u16, 69), max_content_col);
    // Left padding: content_col - rect.col = 3
    try testing.expectEqual(@as(u16, 3), content_col - rect.col);
    // Right padding: (rect.col + rect.width - 1) - max_content_col = 72 - 69 = 3
    try testing.expectEqual(@as(u16, 3), (rect.col + rect.width - 1) - max_content_col);
}

test "overlay: dashboard tab navigation and history day selection" {
    var ov = wellbeing.overlay.Overlay.init();
    defer ov.deinit(testing.allocator);

    try testing.expectEqual(wellbeing.overlay.DashboardTab.overview, ov.active_tab);
    ov.nextTab();
    try testing.expectEqual(wellbeing.overlay.DashboardTab.pomodoro, ov.active_tab);
    ov.nextTab();
    try testing.expectEqual(wellbeing.overlay.DashboardTab.activity, ov.active_tab);
    ov.nextTab();
    try testing.expectEqual(wellbeing.overlay.DashboardTab.overview, ov.active_tab);

    ov.selectTab(2);
    try testing.expectEqual(wellbeing.overlay.DashboardTab.activity, ov.active_tab);

    // 3 history days + 1 today = 4 total days (indices 0..3)
    ov.moveSelectedDay(-1, 3);
    try testing.expectEqual(@as(?u16, 2), ov.selected_day_idx);
    ov.moveSelectedDay(-5, 3);
    try testing.expectEqual(@as(?u16, 0), ov.selected_day_idx);
    ov.moveSelectedDay(10, 3);
    try testing.expectEqual(@as(?u16, 3), ov.selected_day_idx);
}
