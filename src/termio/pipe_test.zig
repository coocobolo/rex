//! Tests for pipe.zig.

const std = @import("std");
const testing = std.testing;
const posix = std.posix;
const system = posix.system;

const pipe = @import("pipe.zig");

test "pipe: both ends get the flags asked for, and only those" {
    var fds: [2]posix.fd_t = undefined;
    try pipe.open(&fds, .{ .CLOEXEC = true, .NONBLOCK = true });
    defer for (fds) |fd| {
        _ = system.close(fd);
    };
    for (fds) |fd| {
        try testing.expect(system.fcntl(fd, posix.F.GETFD, @as(usize, 0)) & posix.FD_CLOEXEC != 0);
        const status: posix.O = @bitCast(@as(u32, @intCast(system.fcntl(fd, posix.F.GETFL, @as(usize, 0)))));
        try testing.expect(status.NONBLOCK);
    }

    var plain: [2]posix.fd_t = undefined;
    try pipe.open(&plain, .{ .CLOEXEC = true });
    defer for (plain) |fd| {
        _ = system.close(fd);
    };
    for (plain) |fd| {
        const status: posix.O = @bitCast(@as(u32, @intCast(system.fcntl(fd, posix.F.GETFL, @as(usize, 0)))));
        try testing.expect(!status.NONBLOCK);
    }
}
