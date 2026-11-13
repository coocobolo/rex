//! A pipe with `O_CLOEXEC` and `O_NONBLOCK` set as asked, on every Unix
//! Rex builds for. macOS has no pipe2(2), so there both flags are set
//! after pipe(2); until then a fork in another thread could inherit the
//! ends, which is why Rex creates its pipes before it starts threads.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const system = posix.system;

pub const Error = error{PipeFailed};

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
    try setFlags(&opened, flags);
    fds.* = opened;
}

fn setFlags(fds: *const [2]posix.fd_t, flags: posix.O) Error!void {
    for (fds) |fd| {
        if (flags.CLOEXEC) {
            if (posix.errno(system.fcntl(fd, posix.F.SETFD, @as(usize, posix.FD_CLOEXEC))) != .SUCCESS) return error.PipeFailed;
        }
        if (flags.NONBLOCK) {
            const rc = system.fcntl(fd, posix.F.GETFL, @as(usize, 0));
            if (posix.errno(rc) != .SUCCESS) return error.PipeFailed;
            var status: posix.O = @bitCast(@as(u32, @intCast(rc)));
            status.NONBLOCK = true;
            if (posix.errno(system.fcntl(fd, posix.F.SETFL, @as(usize, @as(u32, @bitCast(status))))) != .SUCCESS) return error.PipeFailed;
        }
    }
}
