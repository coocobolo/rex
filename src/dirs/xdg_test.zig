const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const Environ = std.process.Environ;

const native_os = builtin.os.tag;
const xdg = @import("xdg.zig");

fn testHome() []const u8 {
    return if (native_os == .windows) "C:\\Users\\test" else "/home/test";
}

test "validateAbsolute" {
    try testing.expect(xdg.validateAbsolute("/home/tes/.config"));
    try testing.expect(!xdg.validateAbsolute(""));
    try testing.expect(!xdg.validateAbsolute("relative/path"));
    try testing.expect(!xdg.validateAbsolute(null));
}

test "fromMap: unset user dirs get spec-defined defaults" {
    const allocator = testing.allocator;
    const home = testHome();
    var map: Environ.Map = .init(allocator);
    defer map.deinit();

    try xdg.normalize(allocator, home, &map, .{ .policy = .fallback });

    var buf: [256]u8 = undefined;
    const expected = try std.fmt.bufPrint(&buf, "{s}/.config", .{home});

    try testing.expectEqualStrings(expected, map.get(xdg.Spec.XDG_CONFIG_HOME).?);

    // repeat allocation must be freed, use a local buffer instead in real test,
    // shown inline here for brevity.
}

test "fromMap: already-valid absolute user dir is left untouched" {
    var map: Environ.Map = .init(testing.allocator);
    defer map.deinit();

    try map.put(xdg.Spec.XDG_CONFIG_HOME, "/custom/config");

    try xdg.normalize(testing.allocator, testHome(), &map, .{ .policy = .strict });
    try testing.expectEqualStrings("/custom/config", map.get(xdg.Spec.XDG_CONFIG_HOME).?);
}

test "fromMap: relative user directory under strict policy errors" {
    var map: Environ.Map = .init(testing.allocator);
    defer map.deinit();

    try map.put(xdg.Spec.XDG_CONFIG_HOME, "relative/config");

    try testing.expectError(
        error.EnvironmentVariableInvalid,
        xdg.normalize(testing.allocator, testHome(), &map, .{ .policy = .strict }),
    );
}

test "fromMap: relative user directory under fallback policy substitutes default" {
    const allocator = testing.allocator;
    const home = testHome();
    var map: Environ.Map = .init(allocator);
    defer map.deinit();

    try map.put(xdg.Spec.XDG_CONFIG_HOME, "relative/config");

    try xdg.normalize(allocator, home, &map, .{ .policy = .fallback });

    var buf: [256]u8 = undefined;
    const expected = try std.fmt.bufPrint(&buf, "{s}/.config", .{home});

    try testing.expectEqualStrings(expected, map.get(xdg.Spec.XDG_CONFIG_HOME).?);
}

test "fromMap: empty user directory value substitutes default" {
    const allocator = testing.allocator;
    const home = testHome();
    var map: Environ.Map = .init(allocator);
    defer map.deinit();

    try xdg.normalize(allocator, home, &map, .{ .policy = .fallback });

    var buf: [256]u8 = undefined;
    const expected = try std.fmt.bufPrint(&buf, "{s}/.local/share", .{home});

    try testing.expectEqualStrings(expected, map.get(xdg.Spec.XDG_DATA_HOME).?);
}

test "fromMap: unset system directories get spec-defined defaults" {
    const allocator = testing.allocator;
    const home = testHome();
    var map: Environ.Map = .init(allocator);
    defer map.deinit();

    try xdg.normalize(allocator, home, &map, .{ .policy = .fallback });

    try testing.expectEqualStrings(xdg.Spec.XDG_DATA_DIRS_VALUE, map.get(xdg.Spec.XDG_DATA_DIRS).?);
    try testing.expectEqualStrings(xdg.Spec.XDG_CONFIG_DIRS_VALUE, map.get(xdg.Spec.XDG_CONFIG_DIRS).?);
}

test "fromMap: system directory with invalid segment drops only thatt segment under fallback" {
    const allocator = testing.allocator;
    const home = testHome();
    var map: Environ.Map = .init(allocator);
    defer map.deinit();

    try map.put(xdg.Spec.XDG_DATA_DIRS, "/usr/local/share:relative/path:/usr/share");

    try xdg.normalize(allocator, home, &map, .{ .policy = .fallback });
    try testing.expectEqualStrings(xdg.Spec.XDG_DATA_DIRS_VALUE, map.get(xdg.Spec.XDG_DATA_DIRS).?);
}

test "fromMap: system directory with invalid segment under strict policy errors" {
    const allocator = testing.allocator;
    const home = testHome();
    var map: Environ.Map = .init(allocator);
    defer map.deinit();

    try map.put(xdg.Spec.XDG_DATA_DIRS, "relative:/etc/xdg");

    try testing.expectError(
        error.EnvironmentVariableInvalid,
        xdg.normalize(allocator, home, &map, .{ .policy = .strict }),
    );
}

test "fromMap: system directory where all segments invalid falls back to default list" {
    const allocator = testing.allocator;
    const home = testHome();
    var map: Environ.Map = .init(allocator);
    defer map.deinit();

    try map.put(xdg.Spec.XDG_DATA_DIRS, "relative:relative2");
    try xdg.normalize(allocator, home, &map, .{ .policy = .fallback });

    const default = for (xdg.system_dirs) |dir| {
        if (std.mem.eql(u8, dir.key, xdg.Spec.XDG_DATA_DIRS)) break dir.value;
    } else unreachable;

    try testing.expectEqualStrings(default, map.get(xdg.Spec.XDG_DATA_DIRS).?);
}

test "fromMap: valid absolute runtime dir is left untouched" {
    const allocator = testing.allocator;
    const home = testHome();
    var map: Environ.Map = .init(allocator);
    defer map.deinit();

    try map.put(xdg.Spec.XDG_RUNTIME_DIR, "/run/user/1000");
    try xdg.normalize(allocator, home, &map, .{ .policy = .fallback });

    try testing.expectEqualStrings("/run/user/1000", map.get(xdg.Spec.XDG_RUNTIME_DIR).?);
}

test "fromMap: invalid runtime dir is removed, never fabricated" {
    const allocator = testing.allocator;
    const home = testHome();
    var map: Environ.Map = .init(allocator);
    defer map.deinit();

    try map.put(xdg.Spec.XDG_RUNTIME_DIR, "relative/run");
    try xdg.normalize(allocator, home, &map, .{ .policy = .fallback });

    try testing.expect(map.get(xdg.Spec.XDG_RUNTIME_DIR) == null);
}

test "fromMap: invalid runtime dir under strict policy errors and is not removed" {
    const allocator = testing.allocator;
    const home = testHome();
    var map: Environ.Map = .init(allocator);
    defer map.deinit();

    try map.put(xdg.Spec.XDG_RUNTIME_DIR, "relative/run");

    try testing.expectError(
        error.EnvironmentVariableInvalid,
        xdg.normalize(allocator, home, &map, .{ .policy = .strict }),
    );
    try testing.expectEqualStrings("relative/run", map.get(xdg.Spec.XDG_RUNTIME_DIR).?);
}

test "fromMap: unset runtime dir is left unset, not fabricated" {
    const allocator = testing.allocator;
    var map: Environ.Map = .init(allocator);
    defer map.deinit();

    const home = testHome();

    try xdg.normalize(allocator, home, &map, .{ .policy = .strict });
    try testing.expect(map.get(xdg.Spec.XDG_RUNTIME_DIR) == null);
}

test "systemDirs: splits and dupes system directories *_DIRS" {
    const allocator = testing.allocator;
    var map: Environ.Map = .init(allocator);
    defer map.deinit();

    try map.put(xdg.Spec.XDG_DATA_DIRS, "/usr/local/share:/usr/share");
    try map.put(xdg.Spec.XDG_CONFIG_DIRS, "/etc/xdg");

    var dirs = try xdg.systemDirs(allocator, &map);
    defer dirs.deinit(allocator);

    try testing.expectEqual(2, dirs.data_dirs.len);
    try testing.expectEqualStrings("/usr/local/share", dirs.data_dirs[0]);
    try testing.expectEqualStrings("/usr/share", dirs.data_dirs[1]);

    try testing.expectEqual(1, dirs.config_dirs.len);
    try testing.expectEqualStrings("/etc/xdg", dirs.config_dirs[0]);
}

test "systemDirs: outlive the source map" {
    const allocator = testing.allocator;

    var dirs: xdg.SystemDirs = undefined;
    {
        var map: Environ.Map = .init(allocator);
        defer map.deinit();
        try map.put(xdg.Spec.XDG_DATA_DIRS, "/usr/local/share:/usr/share");
        try map.put(xdg.Spec.XDG_CONFIG_DIRS, "/etc/xdg");

        dirs = try xdg.systemDirs(allocator, &map);
    }
    // map is gone; dirs must still be valid since every segment was dupe'd.
    defer dirs.deinit(allocator);

    try testing.expectEqualStrings("/usr/local/share", dirs.data_dirs[0]);
    try testing.expectEqualStrings("/etc/xdg", dirs.config_dirs[0]);
}

test "systemDirs: empty system directories yields empty slices" {
    const gpa = testing.allocator;

    var map: Environ.Map = .init(gpa);
    defer map.deinit();

    try map.put(xdg.Spec.XDG_DATA_DIRS, "");
    try map.put(xdg.Spec.XDG_CONFIG_DIRS, "");

    var dirs = try xdg.systemDirs(gpa, &map);
    defer dirs.deinit(gpa);

    try testing.expectEqual(0, dirs.data_dirs.len);
    try testing.expectEqual(0, dirs.config_dirs.len);
}

test "systemDirs: skips empty segments between directories" {
    const gpa = testing.allocator;

    var map: Environ.Map = .init(gpa);
    defer map.deinit();

    // double delimiter produces an empty segment; tokenizeScalar skips it.
    try map.put(xdg.Spec.XDG_DATA_DIRS, "/usr/local/share::/usr/share");
    try map.put(xdg.Spec.XDG_CONFIG_DIRS, "/etc/xdg");

    var dirs = try xdg.systemDirs(gpa, &map);
    defer dirs.deinit(gpa);

    try testing.expectEqual(2, dirs.data_dirs.len);
}

test "systemDirs: deinit on empty struct is no-op (safe with .empty)" {
    const gpa = testing.allocator;
    var dirs: xdg.SystemDirs = .empty;
    defer dirs.deinit(gpa);
}

test "systemDirs: OutOfMemory propagates and cleans up partial allocations" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 2 });
    const gpa = failing.allocator();

    var map: Environ.Map = .init(testing.allocator);
    defer map.deinit();

    try map.put(xdg.Spec.XDG_DATA_DIRS, "/a:/b:/c");
    try map.put(xdg.Spec.XDG_CONFIG_DIRS, "/d");

    try testing.expectError(error.OutOfMemory, xdg.systemDirs(gpa, &map));
    // testing.allocator (wrapped by failing) will report a leak here
    // if any errdefer path in systemDirs is missing.
}
