const std = @import("std");
const testing = std.testing;

const loader = @import("loader.zig");
const Config = @import("Config.zig");
const input = @import("../input.zig");

/// A config with what applying a file reads set; the rest stays undefined.
fn baseConfig() Config {
    var config: Config = undefined;
    config.keymap = &.{};
    config.font.size = 14;
    config.font.min_size = 6;
    config.font.max_size = 196;
    config.font.faces.family = .{ .variable = .{ .upright = "base.ttf" } };
    config.scroll = .{};
    return config;
}

/// Writes `files` into a fresh temporary directory and returns their
/// paths, relative to the working directory the tests run in.
const Files = struct {
    tmp: testing.TmpDir,
    buf: [2][64]u8 = undefined,

    fn init(names: []const []const u8, contents: []const []const u8) !Files {
        var self: Files = .{ .tmp = testing.tmpDir(.{}) };
        for (names, contents) |name, data| {
            try self.tmp.dir.writeFile(testing.io, .{ .sub_path = name, .data = data });
        }
        return self;
    }

    fn path(self: *Files, i: usize, name: []const u8) []const u8 {
        return std.fmt.bufPrint(&self.buf[i], ".zig-cache/tmp/{s}/{s}", .{ &self.tmp.sub_path, name }) catch unreachable;
    }

    fn deinit(self: *Files) void {
        self.tmp.cleanup();
    }
};

test "load without files keeps the base config" {
    const base = baseConfig();
    var loaded = try loader.load(testing.allocator, &base, .{
        .system = ".zig-cache/tmp/rex-no-such-system-config",
        .user = ".zig-cache/tmp/rex-no-such-user-config",
    });
    defer loaded.deinit();

    try testing.expect(!loaded.foundAny());
    try testing.expectEqual(@as(usize, 0), loaded.diagnosticCount());
    try testing.expectEqual(@as(u32, 14), loaded.config.font.size);
}

test "load applies the user file on top of the system file" {
    var files = try Files.init(&.{ "system", "user" }, &.{
        "font_size = 10\n[scroll]\nlines = 7\n",
        "font_size = 12\n",
    });
    defer files.deinit();

    const base = baseConfig();
    var loaded = try loader.load(testing.allocator, &base, .{
        .system = files.path(0, "system"),
        .user = files.path(1, "user"),
    });
    defer loaded.deinit();

    try testing.expect(loaded.system.found);
    try testing.expect(loaded.user.?.found);
    try testing.expectEqual(@as(u32, 12), loaded.config.font.size);
    try testing.expectEqual(@as(u32, 7), loaded.config.scroll.lines);
    try testing.expect(loaded.firstError() == null);
}

test "a user binding replaces a system binding for the same key" {
    var files = try Files.init(&.{ "system", "user" }, &.{
        "[keybinds]\nctrl+shift+c = copy_selection\n",
        "[keybinds]\nctrl+shift+c = paste_clipboard\n",
    });
    defer files.deinit();

    const base = baseConfig();
    var loaded = try loader.load(testing.allocator, &base, .{
        .system = files.path(0, "system"),
        .user = files.path(1, "user"),
    });
    defer loaded.deinit();

    var matches: usize = 0;
    for (loaded.config.keymap) |binding| {
        if (binding.key == input.Key.c) {
            matches += 1;
            try testing.expectEqual(input.Action.paste_clipboard, binding.action);
        }
    }
    try testing.expectEqual(@as(usize, 1), matches);
}

test "an unreadable file is an error, not a missing file" {
    // The read failure is logged as a warning; it's the expected outcome.
    testing.log_level = .err;
    // A directory opens but can't be read.
    var files = try Files.init(&.{}, &.{});
    defer files.deinit();
    try files.tmp.dir.createDir(testing.io, "dir", .default_dir);

    const base = baseConfig();
    var loaded = try loader.load(testing.allocator, &base, .{
        .system = ".zig-cache/tmp/rex-no-such-system-config",
        .user = files.path(0, "dir"),
    });
    defer loaded.deinit();

    try testing.expect(!loaded.foundAny());
    try testing.expect(loaded.firstError() != null);
}

test "parse errors are reported and the rest of the file applies" {
    var files = try Files.init(&.{"user"}, &.{"font_size = 12\nbogus line without equals\n"});
    defer files.deinit();

    const base = baseConfig();
    var loaded = try loader.load(testing.allocator, &base, .{
        .system = ".zig-cache/tmp/rex-no-such-system-config",
        .user = files.path(0, "user"),
    });
    defer loaded.deinit();

    try testing.expectEqual(@as(u32, 12), loaded.config.font.size);
    try testing.expect(loaded.diagnosticCount() > 0);
}
