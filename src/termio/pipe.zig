//! Pipes and socket pairs with `O_CLOEXEC` and `O_NONBLOCK` set as asked,
//! on every Unix Rex builds for. macOS lacks pipe2(2) and SOCK_NONBLOCK /
//! SOCK_CLOEXEC on socketpair(2), so there both flags are applied via fcntl(2)
//! after creation; until then a fork in another thread could inherit the ends,
//! which is why Rex creates its fds before it starts threads.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const system = posix.system;

pub const Error = error{PipeFailed};
pub const SocketPairError = error{SocketPairFailed};

/// Opens a pipe into `fds` (`[0]` reads, `[1]` writes). Only the
/// `CLOEXEC` and `NONBLOCK` fields of `flags` are honoured. The caller
/// owns both descriptors; on an error none is open and `fds` is left
/// as it was.
pub fn open(fds: *[2]posix.fd_t, flags: posix.O) Error!void {
    if (comptime builtin.os.tag != .macos) {
        if (system.pipe2(fds, flags) == -1) return error.PipeFailed;
        return;
    }
    var opened: [2]posix.fd_t = undefined;
    if (system.pipe(&opened) == -1) return error.PipeFailed;
    errdefer for (opened) |fd| {
        _ = system.close(fd);
    };
    setFlags(&opened, flags) catch return error.PipeFailed;
    fds.* = opened;
}

/// Opens a connected Unix stream socket pair into `fds`. Only the
/// `CLOEXEC` and `NONBLOCK` fields of `flags` are honoured. The caller
/// owns both descriptors; on an error none is open and `fds` is left
/// as it was.
pub fn openSocketPair(fds: *[2]posix.fd_t, flags: posix.O) SocketPairError!void {
    if (comptime builtin.os.tag != .macos) {
        var kind: u32 = posix.SOCK.STREAM;
        if (flags.NONBLOCK) kind |= posix.SOCK.NONBLOCK;
        if (flags.CLOEXEC) kind |= posix.SOCK.CLOEXEC;
        if (posix.errno(system.socketpair(posix.AF.UNIX, kind, 0, fds)) != .SUCCESS) {
            return error.SocketPairFailed;
        }
        return;
    }
    var opened: [2]posix.fd_t = undefined;
    if (posix.errno(system.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &opened)) != .SUCCESS) {
        return error.SocketPairFailed;
    }
    errdefer for (opened) |fd| {
        _ = system.close(fd);
    };
    setFlags(&opened, flags) catch return error.SocketPairFailed;
    fds.* = opened;
}

fn setFlags(fds: *const [2]posix.fd_t, flags: posix.O) error{SetFlagsFailed}!void {
    for (fds) |fd| {
        if (flags.CLOEXEC) {
            if (posix.errno(system.fcntl(fd, posix.F.SETFD, @as(usize, posix.FD_CLOEXEC))) != .SUCCESS) return error.SetFlagsFailed;
        }
        if (flags.NONBLOCK) {
            const rc = system.fcntl(fd, posix.F.GETFL, @as(usize, 0));
            if (posix.errno(rc) != .SUCCESS) return error.SetFlagsFailed;
            var status: posix.O = @bitCast(@as(u32, @intCast(rc)));
            status.NONBLOCK = true;
            if (posix.errno(system.fcntl(fd, posix.F.SETFL, @as(usize, @as(u32, @bitCast(status))))) != .SUCCESS) return error.SetFlagsFailed;
        }
    }
}
