//! Tests for pty.zig: spawning, spawn failures, the foreground process
//! group, and which descriptors reach the child.

const std = @import("std");
const testing = std.testing;
const posix = std.posix;
const system = posix.system;

const pty = @import("pty.zig");
const pipe = @import("pipe.zig");

test "Posix: inactive" {
    var pair: pty.Posix = .inactive;
    defer pair.close(testing.io);

    try testing.expectEqual(-1, pair.master);
    try testing.expectEqual(-1, pair.pid);
    try testing.expectEqual(-1, pair.stdout_read_fd);
    try testing.expectEqual(-1, pair.error_read_fd);
}

test "Posix: spawn, default no stdout capture" {
    var pair: pty.Posix = try pty.Posix.spawn(.{});
    defer pair.close(testing.io);
    // Wait for the exec so close()'s SIGHUP reaches the child's session
    // instead of racing setsid() and waiting out the full grace period.
    try pair.waitForSpawn();

    try testing.expect(pair.master > 0);
    try testing.expect(pair.stdout_read_fd == -1);
    try testing.expect(pair.pid > 0);
}

test "Posix: spawn, with stdout capture" {
    var pair: pty.Posix = try pty.Posix.spawn(.{ .capture_stdout = true });
    defer pair.close(testing.io);
    // Wait for the exec so close()'s SIGHUP reaches the child's session
    // instead of racing setsid() and waiting out the full grace period.
    try pair.waitForSpawn();

    try testing.expect(pair.master > 0);
    try testing.expect(pair.stdout_read_fd >= 0);
    try testing.expect(pair.pid > 0);
}

test "Posix: a program that can't be executed is a spawn failure" {
    const argv = [_:null]?[*:0]const u8{ "/nonexistent/rex-test-program", null };
    var pair: pty.Posix = try pty.Posix.spawn(.{ .argv = &argv });
    defer pair.close(testing.io);
    try testing.expectError(error.SpawnFailed, pair.waitForSpawn());
    try testing.expectEqual(pty.SpawnFailure{ .stage = .execve, .errno = .NOENT }, pair.failure.?);
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("cannot run the program (NOENT)", try std.fmt.bufPrint(&buf, "{f}", .{pair.failure.?}));
}

test "Posix: a working directory that doesn't exist is a spawn failure" {
    var pair: pty.Posix = try pty.Posix.spawn(.{ .cwd = "/nonexistent/rex-test-dir" });
    defer pair.close(testing.io);
    try testing.expectError(error.SpawnFailed, pair.waitForSpawn());
    try testing.expectEqual(pty.SpawnFailure{ .stage = .chdir, .errno = .NOENT }, pair.failure.?);
}

test "foregroundGroup: the shell at its prompt, then a program it started" {
    // An interactive shell on a pty does job control: a command it runs
    // gets its own process group and becomes the foreground.
    const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-i", null };
    const envp = [_:null]?[*:0]const u8{ "PS1=$ ", null };
    var pair: pty.Posix = try pty.Posix.spawn(.{ .argv = &argv, .envp = &envp });
    defer pair.close(testing.io);
    try pair.waitForSpawn();

    // The shell becomes the foreground once it has set up job control.
    try testing.expect(waitForForeground(pair.master, pair.pid, true));

    const command = "sleep 5\n";
    try testing.expectEqual(@as(isize, command.len), system.write(pair.master, command, command.len));
    try testing.expect(waitForForeground(pair.master, pair.pid, false));

    var comm: [32]u8 = undefined;
    const fg_comm = waitForForegroundComm(pair.master, &comm, "sleep") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("sleep", fg_comm);
    try testing.expectEqual(null, pty.foregroundGroup(-1));
    try testing.expectEqual(null, pty.foregroundComm(-1, &comm));

    // An already-known group gives the same name as the master-based lookup,
    // without a second tcgetpgrp. The group is stable during `sleep 5`.
    const group = pty.foregroundGroup(pair.master) orelse return error.TestUnexpectedResult;
    var group_comm: [32]u8 = undefined;
    try testing.expectEqualStrings(
        pty.foregroundComm(pair.master, &comm) orelse return error.TestUnexpectedResult,
        pty.foregroundCommForGroup(group, &group_comm) orelse return error.TestUnexpectedResult,
    );
    try testing.expectEqual(null, pty.foregroundCommForGroup(-1, &group_comm));
}

/// Polls up to ~2 s until the foreground group is (or is not) `pid`.
fn waitForForeground(master: posix.fd_t, pid: posix.pid_t, is_pid: bool) bool {
    var rounds: usize = 0;
    while (rounds < 200) : (rounds += 1) {
        if (pty.foregroundGroup(master)) |group| {
            if ((group == pid) == is_pid) return true;
        }
        std.Io.sleep(testing.io, .fromMilliseconds(10), .awake) catch {};
    }
    return false;
}

/// Polls up to ~2 s until foregroundComm equals `want` (covering the
/// fork -> tcsetpgrp -> execve window), or returns the last observed value.
fn waitForForegroundComm(master: posix.fd_t, out: []u8, want: []const u8) ?[]const u8 {
    var rounds: usize = 0;
    while (rounds < 200) : (rounds += 1) {
        if (pty.foregroundComm(master, out)) |comm| {
            if (std.mem.eql(u8, comm, want)) return comm;
        }
        std.Io.sleep(testing.io, .fromMilliseconds(10), .awake) catch {};
    }
    return pty.foregroundComm(master, out);
}

test "Posix: the master is close-on-exec in the parent" {
    var pair: pty.Posix = try pty.Posix.spawn(.{});
    defer pair.close(testing.io);
    try pair.waitForSpawn();

    const flags = system.fcntl(pair.master, posix.F.GETFD, @as(usize, 0));
    try testing.expectEqual(posix.E.SUCCESS, posix.errno(flags));
    try testing.expect(@as(usize, @intCast(flags)) & posix.FD_CLOEXEC != 0);
}

test "Posix: the child gets only stdin, stdout and stderr" {
    // A descriptor without close-on-exec, as if inherited from whatever
    // started this process. Neither it nor the pty master may reach the
    // child.
    const inherited = system.open("/dev/null", .{ .ACCMODE = .RDONLY }, @as(posix.mode_t, 0));
    try testing.expectEqual(posix.E.SUCCESS, posix.errno(inherited));
    defer _ = system.close(@intCast(inherited));

    // Probe descriptors 0..max_fd in POSIX sh via `/dev/fd/$i` (stat() in
    // the shell itself) rather than `/proc/$$/fd` (absent on macOS) or
    // `ls /dev/fd` (which exposes ls's own opendir descriptor on macOS).
    const max_fd: c_int = @max(@as(c_int, @intCast(inherited)) + 16, 64);
    var cmd_buf: [128]u8 = undefined;
    const cmd = std.fmt.bufPrintZ(
        &cmd_buf,
        "i=0; while [ \"$i\" -le {d} ]; do [ -e \"/dev/fd/$i\" ] && printf '%d\\n' \"$i\"; i=$((i + 1)); done",
        .{max_fd},
    ) catch unreachable;
    const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", cmd.ptr, null };
    var pair: pty.Posix = try pty.Posix.spawn(.{ .argv = &argv, .capture_stdout = true });
    defer pair.close(testing.io);
    try pair.waitForSpawn();

    var out: [256]u8 = undefined;
    var len: usize = 0;
    var rounds: usize = 0;
    while (rounds < 5000) : (rounds += 1) { // up to ~5 s
        const n = system.read(pair.stdout_read_fd, out[len..].ptr, out.len - len);
        switch (posix.errno(n)) {
            .SUCCESS => {
                if (n == 0) break; // EOF: the shell has exited
                len += @intCast(n);
            },
            .AGAIN => std.Io.sleep(testing.io, .fromMilliseconds(1), .awake) catch {},
            else => return error.TestReadFailed,
        }
    }
    try testing.expectEqualStrings("0\n1\n2\n", out[0..len]);
}

test "Posix: resizing a closed pty is PtyClosed" {
    var pair: pty.Posix = .inactive;
    try testing.expectError(error.PtyClosed, pair.resize(24, 80, 0, 0));
}

test "Posix: resizing something that is not a tty is ResizeFailed" {
    // /dev/null as the master: TIOCSWINSZ fails with ENOTTY, which resize
    // logs and reports. That warning is expected here; an unexpected one
    // must still reach the build runner.
    const fd = system.open("/dev/null", .{ .ACCMODE = .RDONLY }, @as(posix.mode_t, 0));
    try testing.expectEqual(posix.E.SUCCESS, posix.errno(fd));
    defer _ = system.close(@intCast(fd));
    var pair: pty.Posix = .inactive;
    pair.master = @intCast(fd);
    const shown = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = shown;
    try testing.expectError(error.ResizeFailed, pair.resize(24, 80, 0, 0));
}

test "Posix: a failed spawn runs none of this process's exit handlers in the child" {
    // The child is a fork of a possibly threaded process, so it must leave
    // with _exit: an exit handler can wait on a thread that only the parent
    // has. The handler below writes to a pipe when it runs in any process
    // but this one; a failed spawn must leave the pipe empty.
    var fds: [2]posix.fd_t = undefined;
    try pipe.open(&fds, .{ .CLOEXEC = true, .NONBLOCK = true });
    defer for (fds) |fd| {
        _ = system.close(fd);
    };

    exit_probe.parent = system.getpid();
    exit_probe.fd = fds[1];
    // Children forked by later tests must not write to a reused descriptor.
    defer exit_probe.fd = -1;
    if (!exit_probe.registered) {
        try testing.expectEqual(0, __cxa_atexit(exit_probe.handler, null, null));
        exit_probe.registered = true;
    }

    const argv = [_:null]?[*:0]const u8{ "/nonexistent/rex-test-program", null };
    var pair: pty.Posix = try pty.Posix.spawn(.{ .argv = &argv });
    defer pair.close(testing.io);
    // Returns once the child has exited.
    try testing.expectError(error.SpawnFailed, pair.waitForSpawn());

    var byte: [1]u8 = undefined;
    try testing.expectEqual(posix.E.AGAIN, posix.errno(system.read(fds[0], &byte, 1)));
}

/// libc's registration behind atexit(3); std has no binding for either.
/// Handlers stay registered for the life of the process.
extern "c" fn __cxa_atexit(func: *const fn (?*anyopaque) callconv(.c) void, arg: ?*anyopaque, dso: ?*anyopaque) c_int;

const exit_probe = struct {
    var parent: posix.pid_t = 0;
    var fd: posix.fd_t = -1;
    var registered = false;

    fn handler(_: ?*anyopaque) callconv(.c) void {
        if (fd == -1 or system.getpid() == parent) return;
        _ = system.write(fd, "x", 1);
    }
};
