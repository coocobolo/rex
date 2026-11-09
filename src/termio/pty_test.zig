//! Tests for pty.zig: spawning, spawn failures, the foreground process
//! group, and which descriptors reach the child.

const std = @import("std");
const testing = std.testing;
const posix = std.posix;
const system = posix.system;

const Posix = @import("pty.zig").Posix;
const SpawnFailure = @import("pty.zig").SpawnFailure;
const foregroundGroup = @import("pty.zig").foregroundGroup;

test "Posix: inactive" {
    var pty: Posix = .inactive;

    defer pty.close(testing.io);

    try testing.expectEqual(-1, pty.master);
    try testing.expectEqual(-1, pty.pid);
    try testing.expectEqual(-1, pty.stdout_read_fd);
    try testing.expectEqual(-1, pty.error_read_fd);
}

test "Posix: spawn, default no stdout capture" {
    var pty: Posix = try Posix.spawn(.{});
    defer pty.close(testing.io);
    // Wait for the exec so close()'s SIGHUP reaches the child's session
    // instead of racing setsid() and waiting out the full grace period.
    try pty.waitForSpawn();

    try testing.expect(pty.master > 0);
    try testing.expect(pty.stdout_read_fd == -1);
    try testing.expect(pty.pid > 0);
}

test "Posix: spawn, with stdout capture" {
    var pty: Posix = try Posix.spawn(.{ .capture_stdout = true });
    defer pty.close(testing.io);
    // Wait for the exec so close()'s SIGHUP reaches the child's session
    // instead of racing setsid() and waiting out the full grace period.
    try pty.waitForSpawn();

    try testing.expect(pty.master > 0);
    try testing.expect(pty.stdout_read_fd >= 0);
    try testing.expect(pty.pid > 0);
}

test "Posix: a program that can't be executed is a spawn failure" {
    const argv = [_:null]?[*:0]const u8{ "/nonexistent/rex-test-program", null };
    var pty: Posix = try Posix.spawn(.{ .argv = &argv });
    defer pty.close(testing.io);
    try testing.expectError(error.SpawnFailed, pty.waitForSpawn());
    try testing.expectEqual(SpawnFailure{ .stage = .execve, .errno = .NOENT }, pty.failure.?);
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("cannot run the program (NOENT)", try std.fmt.bufPrint(&buf, "{f}", .{pty.failure.?}));
}

test "Posix: a working directory that doesn't exist is a spawn failure" {
    var pty: Posix = try Posix.spawn(.{ .cwd = "/nonexistent/rex-test-dir" });
    defer pty.close(testing.io);
    try testing.expectError(error.SpawnFailed, pty.waitForSpawn());
    try testing.expectEqual(SpawnFailure{ .stage = .chdir, .errno = .NOENT }, pty.failure.?);
}

test "foregroundGroup: the shell at its prompt, then a program it started" {
    // An interactive shell on a pty does job control: a command it runs
    // gets its own process group and becomes the foreground.
    const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-i", null };
    const envp = [_:null]?[*:0]const u8{ "PS1=$ ", null };
    var pty: Posix = try Posix.spawn(.{ .argv = &argv, .envp = &envp });
    defer pty.close(testing.io);
    try pty.waitForSpawn();

    // The shell becomes the foreground once it has set up job control.
    try testing.expect(waitForForeground(pty.master, pty.pid, true));

    const command = "sleep 5\n";
    try testing.expectEqual(@as(isize, command.len), system.write(pty.master, command, command.len));
    try testing.expect(waitForForeground(pty.master, pty.pid, false));

    try testing.expectEqual(null, foregroundGroup(-1));
}

/// Polls up to ~2 s until the foreground group is (or is not) `pid`.
fn waitForForeground(master: posix.fd_t, pid: posix.pid_t, is_pid: bool) bool {
    var rounds: usize = 0;
    while (rounds < 200) : (rounds += 1) {
        if (foregroundGroup(master)) |group| {
            if ((group == pid) == is_pid) return true;
        }
        std.Io.sleep(testing.io, .fromMilliseconds(10), .awake) catch {};
    }
    return false;
}

test "Posix: the master is close-on-exec in the parent" {
    var pty: Posix = try Posix.spawn(.{});
    defer pty.close(testing.io);
    try pty.waitForSpawn();

    const flags = system.fcntl(pty.master, posix.F.GETFD, @as(usize, 0));
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

    // `ls` runs as a child of the shell and lists the shell's descriptors.
    const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", "ls /proc/$$/fd", null };
    var pty: Posix = try Posix.spawn(.{ .argv = &argv, .capture_stdout = true });
    defer pty.close(testing.io);
    try pty.waitForSpawn();

    var out: [256]u8 = undefined;
    var len: usize = 0;
    var rounds: usize = 0;
    while (rounds < 5000) : (rounds += 1) { // up to ~5 s
        const n = system.read(pty.stdout_read_fd, out[len..].ptr, out.len - len);
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
    var pty: Posix = .inactive;
    try testing.expectError(error.PtyClosed, pty.resize(24, 80, 0, 0));
}

test "Posix: resizing something that is not a tty is ResizeFailed" {
    // /dev/null as the master: TIOCSWINSZ fails with ENOTTY, which resize
    // logs (a warning) and reports.
    const fd = system.open("/dev/null", .{ .ACCMODE = .RDONLY }, @as(posix.mode_t, 0));
    try testing.expectEqual(posix.E.SUCCESS, posix.errno(fd));
    defer _ = system.close(@intCast(fd));
    var pty: Posix = .inactive;
    pty.master = @intCast(fd);
    try testing.expectError(error.ResizeFailed, pty.resize(24, 80, 0, 0));
}
