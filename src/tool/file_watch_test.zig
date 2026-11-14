const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

const FileWatch = @import("FileWatch.zig");

var notified: std.atomic.Value(u32) = .init(0);

fn countNotify() void {
    _ = notified.fetchAdd(1, .release);
}

/// Waits up to two seconds for the thread to call `notify` `count` times.
fn waitNotified(count: u32) !void {
    var tries: u32 = 0;
    while (notified.load(.acquire) < count) : (tries += 1) {
        if (tries == 200) return error.Timeout;
        try std.Io.sleep(testing.io, .fromMilliseconds(10), .awake);
    }
}

fn tmpPath(tmp: *const testing.TmpDir, buf: []u8) ![]const u8 {
    return std.fmt.bufPrint(buf, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
}

test "file watch: a save of the named file sets changed, others do not" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    notified.store(0, .release);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [128]u8 = undefined;
    const watch = try FileWatch.create(testing.allocator, try tmpPath(&tmp, &buf), "wb.bin", countNotify);
    defer watch.destroy(testing.allocator);

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "other.bin", .data = "x" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "wb.bin", .data = "x" });
    try waitNotified(1);
    try testing.expect(watch.takeChanged());
    try testing.expect(!watch.takeChanged());
    try testing.expect(watch.isAlive());
}

test "file watch: a rename into place counts as a save" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    notified.store(0, .release);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [128]u8 = undefined;
    const watch = try FileWatch.create(testing.allocator, try tmpPath(&tmp, &buf), "wb.bin", countNotify);
    defer watch.destroy(testing.allocator);

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "wb.tmp", .data = "x" });
    try std.Io.Dir.rename(tmp.dir, "wb.tmp", tmp.dir, "wb.bin", testing.io);
    try waitNotified(1);
    try testing.expect(watch.takeChanged());
}

test "file watch: removing the directory ends the watch" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    notified.store(0, .release);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(testing.io, "state", .default_dir);
    var buf: [128]u8 = undefined;
    const base = try tmpPath(&tmp, &buf);
    var dir_buf: [160]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buf, "{s}/state", .{base});
    const watch = try FileWatch.create(testing.allocator, dir, "wb.bin", countNotify);
    defer watch.destroy(testing.allocator);

    // The thread logs a warning when the watch ends.
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;
    try tmp.dir.deleteDir(testing.io, "state");
    try waitNotified(1);
    try testing.expect(!watch.isAlive());
}

test "file watch: a missing directory fails to start" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    try testing.expectError(error.FileNotFound, FileWatch.create(testing.allocator, ".zig-cache/tmp/rex-no-such-dir", "wb.bin", countNotify));
}
