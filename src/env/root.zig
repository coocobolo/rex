const std = @import("std");
const builtin = @import("builtin");

const posix = std.posix;
const testing = std.testing;
const native_os = builtin.os.tag;

test "home: key matches platform env var name" {
    switch (native_os) {
        .windows => try testing.expectEqualStrings("USERPROFILE", home.key),
        else => try testing.expectEqualStrings("HOME", home.key),
    }
}

pub const PathVar = struct {
    key: []const u8,
    segments: []const []const u8,
};

pub const PlainVar = struct {
    key: []const u8,
    value: []const u8,
};

/// Obtain the user's home directory. Caller owns returned memory.
/// On POSIX: reads $HOME. On Windows: reads %USERPROFILE%.
pub const home: PathVar = .{
    .key = if (native_os == .windows) "USERPROFILE" else "HOME",
    .segments = &.{},
};
