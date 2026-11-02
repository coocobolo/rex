//! Cross-platform application directory resolver.
//!
//! Linux: XDG Base Directory Specification (with env var overrides).
//! macOS: ~/Libarary/* conventions.
//! Windows: %APPDATA% / %LOCALAPPDATA%.

const std = @import("std");
const builtin = @import("builtin");
const native_os = builtin.os.tag;

const fs = std.fs;
const posix = std.posix;
const testing = std.testing;

const Environ = std.process.Environ;
const Allocator = std.mem.Allocator;

pub const xdg = @import("xdg.zig");
pub const windows = @import("windows.zig");
pub const macos = @import("macos.zig");

test {
    testing.refAllDecls(@This());
}

/// Store flats set of all resolved paths for an public application directories, cross-platforms.
/// Used for the callers actually want to use top open files, for their platform specific files.
/// Caller owns memory, call deinit() when done.
pub const Application = struct {
    config: []const u8,
    data: []const u8,
    cache: []const u8,
    state: []const u8,
    log: []const u8,
    /// runtime.len == 0 means not available on this platform/not set
    runtime: []const u8,

    pub fn deinit(self: *Application, gpa: Allocator) void {
        gpa.free(self.config);
        gpa.free(self.data);
        gpa.free(self.cache);
        gpa.free(self.state);
        gpa.free(self.log);
        if (self.runtime.len > 0) gpa.free(self.runtime);
        self.* = undefined;
    }

    pub fn resolve(gpa: Allocator, prefix: []const u8, home: []const u8, map: *Environ.Map) !Application {
        return switch (native_os) {
            .linux, .freebsd, .netbsd, .dragonfly, .openbsd, .illumos, .serenity => blk: {
                try xdg.normalize(gpa, home, map, .{ .policy = .fallback });
                const user = xdg.userDirs(map);
                break :blk try fromXdg(gpa, prefix, &user);
            },

            .macos, .maccatalyst => blk: {
                var domain = try macos.userDomain(gpa, home);
                defer domain.deinit(gpa);
                break :blk try fromMacos(gpa, prefix, &domain);
            },

            .windows => blk: {
                var win = try windows.userDirs(gpa);
                defer win.deinit(gpa);
                break :blk try fromWindows(gpa, prefix, &win);
            },

            else => @compileError("unsupported platform"),
        };
    }

    /// Flatten xdg.UserDirs into AppDir's fixed field set.
    /// Does not read env var or touch environ_map, pure field mapping.
    fn fromXdg(gpa: Allocator, prefix: []const u8, user: *const xdg.UserDirs) !Application {
        var dirs: Application = undefined;
        dirs.cache = try fs.path.join(gpa, &.{ user.cache_home, prefix });
        errdefer gpa.free(dirs.cache);

        dirs.config = try fs.path.join(gpa, &.{ user.config_home, prefix });
        errdefer gpa.free(dirs.config);

        dirs.data = try fs.path.join(gpa, &.{ user.data_home, prefix });
        errdefer gpa.free(dirs.data);

        dirs.log = try fs.path.join(gpa, &.{ user.state_home, prefix, "log" });
        errdefer gpa.free(dirs.log);

        dirs.state = try fs.path.join(gpa, &.{ user.state_home, prefix });
        errdefer gpa.free(dirs.state);

        dirs.runtime = if (user.runtime_dir.len > 0) try fs.path.join(gpa, &.{ user.runtime_dir, prefix }) else "";
        return dirs;
    }

    /// Flatten macos.UserDomain into Dirs. macOS collapses config/data/state
    /// into one Application Support tree, see prior discussion in this thread.
    fn fromMacos(gpa: Allocator, prefix: []const u8, dom: *const macos.UserDomain) !Application {
        var dirs: Application = undefined;
        dirs.config = try fs.path.join(gpa, &.{ dom.application_support, prefix });
        errdefer gpa.free(dirs.config);

        dirs.data = try fs.path.join(gpa, &.{ dom.application_support, prefix });
        errdefer gpa.free(dirs.data);

        dirs.cache = try fs.path.join(gpa, &.{ dom.caches, prefix });
        errdefer gpa.free(dirs.cache);

        dirs.state = try fs.path.join(gpa, &.{ dom.application_support, prefix });
        errdefer gpa.free(dirs.state);

        dirs.log = try fs.path.join(gpa, &.{ dom.logs, prefix });
        errdefer gpa.free(dirs.log);

        dirs.runtime = "";
        return dirs;
    }

    /// Flatten windows.UserDirs into Dirs. Roaming -> config (syncs across a
    /// domain), Local -> data/cache/state (machine-specific).
    fn fromWindows(gpa: Allocator, prefix: []const u8, win: *const windows.UserDirs) !Application {
        var dirs: Application = undefined;
        dirs.config = try fs.path.join(gpa, &.{ win.roaming, prefix });
        errdefer gpa.free(dirs.config);

        dirs.data = try fs.path.join(gpa, &.{ win.local, prefix });
        errdefer gpa.free(dirs.data);

        dirs.cache = try fs.path.join(gpa, &.{ win.local, prefix, "cache" });
        errdefer gpa.free(dirs.cache);

        dirs.state = try fs.path.join(gpa, &.{ win.local, prefix });
        errdefer gpa.free(dirs.state);

        dirs.log = try fs.path.join(gpa, &.{ win.local, prefix, "log" });
        errdefer gpa.free(dirs.log);

        dirs.runtime = "";
        return dirs;
    }

    pub fn format(self: *const Application, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("config=\"{s}\"\n", .{self.config});
        try writer.print("data=\"{s}\"\n", .{self.data});
        try writer.print("cache=\"{s}\"\n", .{self.cache});
        try writer.print("state=\"{s}\"\n", .{self.state});
        try writer.print("log=\"{s}\"\n", .{self.log});
        try writer.print("runtime=\"{s}\"\n", .{self.runtime});
    }
};

test "fromXdg: joins all fields under prefix" {
    const gpa = testing.allocator;
    const user: xdg.UserDirs = .{
        .data_home = "/home/alice/.local/share",
        .config_home = "/home/alice/.config",
        .state_home = "/home/alice/.local/state",
        .cache_home = "/home/alice/.cache",
        .runtime_dir = "/run/user/1000",
    };

    var dirs = try Application.fromXdg(gpa, "zig.app", &user);
    defer dirs.deinit(gpa);

    try testing.expectEqualStrings("/home/alice/.cache/zig.app", dirs.cache);
    try testing.expectEqualStrings("/home/alice/.config/zig.app", dirs.config);
    try testing.expectEqualStrings("/home/alice/.local/share/zig.app", dirs.data);
    try testing.expectEqualStrings("/home/alice/.local/state/zig.app", dirs.state);
    try testing.expectEqualStrings("/home/alice/.local/state/zig.app/log", dirs.log);
    try testing.expectEqualStrings("/run/user/1000/zig.app", dirs.runtime);
}

test "fromMacos: config/data/state collapse into application_support" {
    const gpa = testing.allocator;
    const domain = macos.UserDomain{
        .application_support = "/Users/alice/Library/Application Support",
        .caches = "/Users/alice/Library/Caches",
        .logs = "/Users/alice/Library/Logs",
    };

    var dirs = try Application.fromMacos(gpa, "zig.app", &domain);
    defer dirs.deinit(gpa);

    try testing.expectEqualStrings("/Users/alice/Library/Application Support/zig.app", dirs.config);
    try testing.expectEqualStrings("/Users/alice/Library/Application Support/zig.app", dirs.data);
    try testing.expectEqualStrings("/Users/alice/Library/Application Support/zig.app", dirs.state);
    try testing.expectEqualStrings("/Users/alice/Library/Caches/zig.app", dirs.cache);
    try testing.expectEqualStrings("/Users/alice/Library/Logs/zig.app", dirs.log);
    try testing.expectEqual(@as(usize, 0), dirs.runtime.len);
}

test "fromWindows: from roaming (config, local) -> data/cache/state/log" {
    const gpa = testing.allocator;
    const win = windows.UserDirs{
        .roaming = "C:\\Users\\alice\\AppData\\Roaming",
        .local = "C:\\Users\\alice\\AppData\\Local",
    };

    var dirs = try Application.fromWindows(gpa, "myapp", &win);
    defer dirs.deinit(gpa);

    const expected_config = try fs.path.join(gpa, &.{ win.roaming, "myapp" });
    defer gpa.free(expected_config);
    try testing.expectEqualStrings(expected_config, dirs.config);

    const expected_data = try fs.path.join(gpa, &.{ win.local, "myapp" });
    defer gpa.free(expected_data);
    try testing.expectEqualStrings(expected_data, dirs.data);

    const expected_cache = try fs.path.join(gpa, &.{ win.local, "myapp", "cache" });
    defer gpa.free(expected_cache);
    try testing.expectEqualStrings(expected_cache, dirs.cache);

    const expected_state = try fs.path.join(gpa, &.{ win.local, "myapp" });
    defer gpa.free(expected_state);
    try testing.expectEqualStrings(expected_state, dirs.state);

    const expected_log = try fs.path.join(gpa, &.{ win.local, "myapp", "log" });
    defer gpa.free(expected_log);
    try testing.expectEqualStrings(expected_log, dirs.log);

    try testing.expectEqual(@as(usize, 0), dirs.runtime.len);
}

test "Application.deinit: runtime='' is not double-freed" {
    // Regression test for the `if (self.runtime.len > 0) gpa.free(...)` guard —
    // without it, freeing a zero-length string literal would corrupt the allocator.
    const gpa = testing.allocator;
    var dirs: Application = .{
        .config = try gpa.dupe(u8, "x"),
        .data = try gpa.dupe(u8, "x"),
        .cache = try gpa.dupe(u8, "x"),
        .state = try gpa.dupe(u8, "x"),
        .log = try gpa.dupe(u8, "x"),
        .runtime = "",
    };
    dirs.deinit(gpa);
}

test "resolve: builds flat struct for the current native platform" {
    const gpa = testing.allocator;

    var map: Environ.Map = .init(gpa);
    defer map.deinit();

    const home = switch (native_os) {
        .windows => "C:\\Users\\test",
        else => "/home/test",
    };

    switch (native_os) {
        .windows => {
            try map.put("APPDATA", "C:\\Users\\test\\AppData\\Roaming");
            try map.put("LOCALAPPDATA", "C:\\Users\\test\\AppData\\Local");
        },
        else => {},
    }

    var dirs = try Application.resolve(gpa, "zig.app", home, &map);
    defer dirs.deinit(gpa);

    // Only structural assertions, the exact base dir depends on fromMap's
    // defaults/env overrides, already covered by xdg's own tests.
    try testing.expect(dirs.config.len > 0);
    try testing.expect(dirs.data.len > 0);
    try testing.expect(dirs.cache.len > 0);
    try testing.expect(dirs.state.len > 0);
    try testing.expect(dirs.log.len > 0);
}

test {
    @import("std").testing.refAllDecls(@This());
}
