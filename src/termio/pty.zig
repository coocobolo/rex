//! A pseudoterminal ("pty") interfaces interface for cross-platform API.
//!
//! PTY is a pair of virtual character devices that provide a bidirec‐tional communication channel.
//! One end of the channel is called the master; the other end is called the slave.

const std = @import("std");
const builtin = @import("builtin");
const native_os = builtin.os.tag;

const posix = std.posix;
const system = posix.system;

const pipe = @import("pipe.zig");

const log = std.log.scoped(.pty);

/// openpty(3): in libc on glibc 2.34 and later and in libSystem on macOS,
/// with the same signature, so no C header is needed (it is `<pty.h>` on
/// Linux and `<util.h>` on macOS).
extern "c" fn openpty(
    master: *posix.fd_t,
    slave: *posix.fd_t,
    name: ?[*]u8,
    termp: ?*const posix.termios,
    winp: ?*const posix.winsize,
) c_int;

/// ioctl(2) with its request as libc declares it, `unsigned long`. std
/// declares `c_int`, which leaves the upper half of the register
/// unspecified on 64-bit macOS, where `TIOCSWINSZ` has bit 31 set.
extern "c" fn ioctl(fd: posix.fd_t, request: c_ulong, ...) c_int;

/// The terminal ioctls Rex sends. std 0.16.0 lacks them for macOS, so
/// they are built there as xnu's `_IO` and `_IOW` build them
/// (bsd/sys/ttycom.h, bsd/sys/ioccom.h).
const tio = switch (native_os) {
    .macos => struct {
        const IOCSCTTY: c_ulong = ioc(0x20000000, 't', 97, 0); // _IO
        const IOCSWINSZ: c_ulong = ioc(0x80000000, 't', 103, @sizeOf(posix.winsize)); // _IOW

        fn ioc(inout: u32, group: u8, num: u8, len: u32) c_ulong {
            return inout | ((len & 0x1fff) << 16) | (@as(u32, group) << 8) | num;
        }
    },
    else => struct {
        const IOCSCTTY: c_ulong = posix.T.IOCSCTTY;
        const IOCSWINSZ: c_ulong = posix.T.IOCSWINSZ;
    },
};

comptime {
    if (native_os == .macos) {
        std.debug.assert(tio.IOCSCTTY == 0x20007461);
        std.debug.assert(tio.IOCSWINSZ == 0x80087467);
    }
}

pub const Pty = blk: {
    switch (native_os) {
        .linux, .freebsd, .macos => break :blk Posix,
        else => @compileError("unsupported termio.pty for current platform target"),
    }
};

pub const SignalTarget = enum { process, session };

/// Errors that can occurs during spawn, before or shortly after forking.
///
/// OpenPtyFailed: openpty() itself failed, no fds or child exist yet.
/// PipeFailed: one of the two pipes (stdout capture or error reporting) could not be opened.
/// SpawnFailed: fork() failed, or a post-fork parent-side setup step (fcntl flags) failed.
///
/// Does not cover child-side setup failures, those are reported later by waitForSpawn().
pub const SpawnErr = error{ OpenPtyFailed, PipeFailed, SpawnFailed } || posix.UnexpectedError;

pub const WaitSpawnErr = error{SpawnFailed} || posix.UnexpectedError;

/// A POSIX pty (pseudo-terminal) plus the child process attached to its slave side.
///
/// Owns the resources of master and slave end fd, child's pid, and additionals
/// pipe read-capture ends (stdout and reporting). All are released together by close().
/// A posix value that has a real fds means its active, inactive when those values set to
/// sentinel fds; so its easier to handle the state exists in between (zombie).
///
/// The reporting approach is the child cannot report as Zig errors directly (cause of its address
/// space is about to be replaced by execute program call). So setup failures between forking and
/// execute a prograrm are sent to the master end as a tiny (stage, errorno) pair through a pipe
/// that closes itself (CLOEXEC) the moment executing program succeeds.
///
/// A zero-byte read therefore only means "the child reached execve()", it says nothing about
/// whether the exec'd program itself will run correctly. That part is tracked separately, later,
/// by calling wait() or isAlive(), not waitForSpawn().
///
/// Sentinels is an fd == (-1) means Closed. A pid <= 0 means that no live child proces.
pub const Posix = struct {
    master: posix.fd_t,

    pid: posix.pid_t,

    /// Read end of stdout capture pipe
    stdout_read_fd: posix.fd_t,

    /// Read end of the  error-reporting pipe.
    /// Consumed and closed by waitForSpawn().
    error_read_fd: posix.fd_t,

    /// The setup step the child reported failing; set when waitForSpawn()
    /// returns error.SpawnFailed, for the caller to report.
    failure: ?SpawnFailure = null,

    /// An inactive pty with no process and no open fds.
    /// Every field holds its "unused" sentinel (-1).
    /// Safe to call close()/isAlive()/wait() on; all become no-ops or report "not alive".
    ///
    /// Never call write() | read() | resize() on this, master still an invalid fd.
    pub const inactive: Posix = .{ .master = -1, .pid = -1, .error_read_fd = -1, .stdout_read_fd = -1 };

    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeAll("PTY [POSIX]\n");
        try writer.print("pid={}\n", .{self.pid});
        try writer.print("master.fd_t={}\n", .{self.master});
        try writer.print("is_alive={}", .{self.isAlive()});
    }

    /// Terminates the child if still alive and closes all owned fds.
    /// Blocks briefly to reap the child so it doesn't become a zombie.
    pub fn close(self: *Posix, io: std.Io) void {
        if (self.master != -1) _ = system.close(self.master);
        if (self.stdout_read_fd != -1) _ = system.close(self.stdout_read_fd);
        if (self.error_read_fd != -1) _ = system.close(self.error_read_fd);

        if (self.pid > 0) {
            // A negative pid argument to kill() targets the whole process group.
            // This matters because the direct child is typically a shell, and the
            // shell may have spawned its own foreground job (e.g. vim, less) that's
            // now the actual process holding the terminal, signaling only the shell's
            // pid leaves those orphaned. This assumes setsid() (which we already call
            // in the child) made the child its own process group leader, so -self.pid
            // correctly targets "the whole session," not some unrelated group.
            self.kill(.HUP, .session) catch {};

            var status: c_int = undefined;
            var reaped = false;

            const max_attempts = 10;
            grace: for (0..max_attempts) |_| {
                const rc = system.waitpid(self.pid, &status, posix.W.NOHANG);
                if (rc == self.pid) {
                    reaped = true;
                    break :grace;
                } else if (rc != 0) {
                    // rc < 0: waitpid itself failed (e.g. ECHILD=already reaped by
                    // someone else, or never was our child). Sleeping longer can't
                    // fix that; stop waiting immediately instead of burning the
                    // full grace period.
                    log.warn("pty close: waitpid failed while waiting for pid={}: errno={}", .{
                        self.pid, posix.errno(rc),
                    });
                    break :grace;
                }

                // rc == 0: still running, keep waiting.
                std.Io.sleep(io, .fromMilliseconds(100), .awake) catch {};
            }

            if (!reaped) {
                self.kill(.KILL, .session) catch {};
                // NOTE the final waitpid(..., 0) after SIGKILL is safe to block on, since SIGKILL
                // cannot be caught, blocked, or ignored, the child (or process group) is guaranteed to terminate.
                _ = system.waitpid(self.pid, &status, 0); // blocking, but SIGKILL is unblockable/uncatchable
            }
        }

        self.* = .inactive;
    }

    /// Sets FD_CLOEXEC, a descriptor flag (F_SETFD). Not to be confused with
    /// `addStatusFlags`: F_SETFL silently ignores O_CLOEXEC on Linux.
    fn setCloseOnExec(fd: posix.fd_t) posix.UnexpectedError!void {
        const rc = system.fcntl(fd, posix.F.GETFD, @as(usize, 0));
        const flags: usize = switch (posix.errno(rc)) {
            .SUCCESS => @intCast(rc),
            else => |err| return posix.unexpectedErrno(err),
        };
        return switch (posix.errno(system.fcntl(fd, posix.F.SETFD, flags | posix.FD_CLOEXEC))) {
            .SUCCESS => {},
            else => |err| posix.unexpectedErrno(err),
        };
    }

    /// Adds file status flags (F_SETFL), such as O_NONBLOCK.
    fn addStatusFlags(fd: posix.fd_t, extra: posix.O) posix.UnexpectedError!void {
        const rc = system.fcntl(fd, posix.F.GETFL, @as(usize, 0));
        var flags: c_int = switch (posix.errno(rc)) {
            .SUCCESS => @intCast(rc),
            else => |err| return posix.unexpectedErrno(err),
        };
        flags |= @bitCast(extra);

        return switch (posix.errno(system.fcntl(fd, posix.F.SETFL, flags))) {
            .SUCCESS => {},
            else => |err| posix.unexpectedErrno(err),
        };
    }

    /// Opens a pty and forks a child that sets up the slave side and execve's option.argv
    /// (or /bin/sh if null). Returns as soon as fork() succeeds, does not wait for the child
    /// to actually reach execve. Caller must call waitForSpawn() afterwards to detect setup
    /// failures reported by the child, and must eventually call close() to reap the child and
    /// release all fds, even if waitForSpawn() itself returns error.SpawnFailed.
    pub fn spawn(option: SpawnOption) SpawnErr!Posix {
        var master: posix.fd_t = undefined;
        var slave: posix.fd_t = undefined;

        const ws = option.winsize();
        if (openpty(&master, &slave, null, null, &ws) == -1) return error.OpenPtyFailed;
        errdefer {
            _ = system.close(master);
            if (slave != -1) _ = system.close(slave);
        }

        // Neither end may reach any program this process starts. The child
        // gets the slave through dup2, which clears the flag on 0, 1 and 2.
        // openpty can't set it atomically, so another thread forking in
        // between would inherit them; Rex spawns before starting threads.
        try setCloseOnExec(master);
        try setCloseOnExec(slave);

        // [0] refers to the read end of the pipe.
        // [1] refers to the write end of the pipe.
        const pipe_flags: posix.O = .{ .CLOEXEC = true };

        var stdout_pipe: [2]posix.fd_t = .{ -1, -1 };
        if (option.capture_stdout) try pipe.open(&stdout_pipe, pipe_flags);
        errdefer {
            if (stdout_pipe[0] != -1) _ = system.close(stdout_pipe[0]);
            if (stdout_pipe[1] != -1) _ = system.close(stdout_pipe[1]);
        }

        // Pipe error reporting for exec on child process
        var err_pipe: [2]posix.fd_t = undefined;
        try pipe.open(&err_pipe, pipe_flags);
        errdefer {
            _ = system.close(err_pipe[0]);
            _ = system.close(err_pipe[1]);
        }

        // On success, the PID of the child process is returned in the parent, and  0 is returned
        // in the child. On failure, -1 is returned in the parent, no child process is created, and
        // errno is set to indicate the error.
        const pid: posix.pid_t = system.fork();
        if (pid == -1) return error.SpawnFailed;
        if (pid == 0) {
            if (stdout_pipe[0] != -1) _ = system.close(stdout_pipe[0]);
            _ = system.close(err_pipe[0]);
            execChild(&option, slave, .{ .stdout_fd = stdout_pipe[1], .error_fd = err_pipe[1] });
        }

        // From here on we are the parent; the child has already been forked and
        // is either running execChild() (noreturn) or has already exited.
        // No further error returns are allowed past this point.
        errdefer comptime unreachable;

        // parent's slave
        _ = system.close(slave);
        _ = system.close(err_pipe[1]); // parent keeps only the read end
        if (stdout_pipe[1] != -1) {
            _ = system.close(stdout_pipe[1]);
        }

        // non blocking reads master fd
        addStatusFlags(master, option.o_flags) catch |err| {
            log.warn("pty: failed to set master non-blocking: {}", .{err});
        };
        // non blocking reads stdout capture end fd
        if (stdout_pipe[0] != -1) {
            addStatusFlags(stdout_pipe[0], .{ .NONBLOCK = true }) catch |err| {
                log.warn("pty: failed to set stdout non-blocking: {}", .{err});
            };
        }

        return .{
            .pid = pid,
            .master = master,
            .stdout_read_fd = stdout_pipe[0],
            .error_read_fd = err_pipe[0],
        };
    }

    fn execChild(
        option: *const SpawnOption,
        slave: posix.fd_t,
        capture: struct { stdout_fd: posix.fd_t, error_fd: posix.fd_t },
    ) noreturn {
        report(capture.error_fd, .setsid, system.setsid());
        report(capture.error_fd, .ioctl_tiocsctty, ioctl(slave, tio.IOCSCTTY, @as(usize, 0)));
        report(capture.error_fd, .dup2_stdin, system.dup2(slave, posix.STDIN_FILENO));

        if (capture.stdout_fd != -1) {
            report(capture.error_fd, .dup2_stdout_pipe, system.dup2(capture.stdout_fd, posix.STDOUT_FILENO));
            if (capture.stdout_fd > posix.STDERR_FILENO) _ = system.close(capture.stdout_fd);
        } else {
            report(capture.error_fd, .dup2_stdout_slave, system.dup2(slave, posix.STDOUT_FILENO));
        }

        report(capture.error_fd, .dup2_stderr, system.dup2(slave, posix.STDERR_FILENO));
        if (slave > posix.STDERR_FILENO) _ = system.close(slave);

        closeOnExecFrom3();

        if (option.cwd) |dir| {
            report(capture.error_fd, .chdir, system.chdir(dir));
        }

        posix.sigaction(.PIPE, &.{
            .handler = .{ .handler = posix.SIG.DFL },
            .mask = posix.sigemptyset(),
            .flags = 0,
        }, null);
        posix.sigprocmask(posix.SIG.SETMASK, &posix.sigemptyset(), null);

        const argv = option.argv orelse @as([*:null]const ?[*:0]const u8, &[_:null]?[*:0]const u8{ "/bin/sh", null });
        const file: [*:0]const u8 = argv[0] orelse "/bin/sh";
        reportChildError(capture.error_fd, .execve, posix.errno(system.execve(file, argv, option.envp)));
    }

    /// Marks every descriptor from 3 up close-on-exec, so the program gets
    /// only stdin, stdout and stderr: not the pty master, and nothing this
    /// process inherited from whatever started it. The error pipe keeps
    /// working until execve, which is when it is meant to close. Runs in
    /// the forked child, so it neither allocates nor logs.
    fn closeOnExecFrom3() void {
        if (native_os == .linux) {
            // Zig 0.16.0's std.os.linux.CLOSE_RANGE has CLOEXEC at bit 1, but
            // the kernel's CLOSE_RANGE_CLOEXEC is 1 << 2 and bit 1 is
            // CLOSE_RANGE_UNSHARE (include/uapi/linux/close_range.h), so the
            // std flags close the descriptors, the error pipe included, and
            // every setup failure looks like a successful exec. Pass the
            // kernel value.
            const close_range_cloexec: usize = 1 << 2;
            const rc = std.os.linux.syscall3(.close_range, 3, std.math.maxInt(posix.fd_t), close_range_cloexec);
            if (posix.errno(rc) == .SUCCESS) return;
            // ENOSYS or EINVAL before Linux 5.11: fall through.
        }
        // One fcntl per possible descriptor, up to the soft limit.
        const limit = posix.getrlimit(.NOFILE) catch return;
        const last: posix.rlim_t = @min(limit.cur, 1 << 20);
        var fd: posix.fd_t = 3;
        while (fd < last) : (fd += 1) {
            _ = system.fcntl(fd, posix.F.SETFD, @as(usize, posix.FD_CLOEXEC));
        }
    }

    fn destroyPipe(fds: [2]posix.fd_t) void {
        if (fds[0] != -1) _ = system.close(fds[0]);
        if (fds[1] != -1) _ = system.close(fds[1]);
    }

    /// Blocks until the child has either successfully exec'd or reported a setup failure via the
    /// CLOEXEC error pipe. Safe to call multiple times; a no-op after the first successful call.
    ///
    /// Limitation: only failures explicitly reported by the child before execve (setsid, ioctl,
    /// dup2, chdir, execve itself) are surfaced as `error.SpawnFailed`. A child that dies from an
    /// unhandled signal before ever reaching the reporting logic (e.g. a bad pointer causing a fault)
    /// produces the same zero-byte EOF as a successful exec, and will not be reported as a spawn failure
    /// by this function, such cases are only observable later via `wait()`/`isAlive()`.
    pub fn waitForSpawn(self: *Posix) WaitSpawnErr!void {
        if (self.error_read_fd == -1) return; // already consumed

        const fd = self.error_read_fd;
        self.error_read_fd = -1;

        var buf: [3]u8 = undefined;
        var total: usize = 0;

        while (total < buf.len) {
            const n = system.read(fd, buf[total..].ptr, buf.len - total);
            if (n < 0) {
                if (posix.errno(n) == .INTR) continue;
                break;
            }
            if (n == 0) break; // EOF
            total += @intCast(n);
        }

        _ = system.close(fd);

        if (total > 0) {
            // explicit report from the child, this is the only thing waitForSpawn should treat
            // as an actual spawn failure.
            const stage: ChildStage = @enumFromInt(buf[0]);
            const err_no: u16 = std.mem.readInt(u16, buf[1..3], .little);
            self.failure = .{ .stage = stage, .errno = @enumFromInt(err_no) };

            var status: c_int = undefined;
            _ = system.waitpid(self.pid, &status, 0);
            self.pid = -1;
            return error.SpawnFailed;
        }

        // EOF with zero bytes: per the CLOEXEC-pipe convention, this means execve() was reached and
        // the exec'd program has replaced the child's image. waitForSpawn's job ends here, it does not
        // attempt to guess whether the resulting program will run successfully, exit quickly, or crash;
        // that is a `wait()`/`isAlive()` concern, not a spawn concern.
        //
        // Known limitation: if the child dies from an unhandled signal before ever reaching execve (e.g.
        // a corrupt cwd pointer faulting inside chdir()), that also produces a zero-byte EOF indistinguishable
        // from a clean exec, and will be misreported as spawn success. This is an inherent limitation of the
        // CLOEXEC-pipe technique, not something this function can reliably detect without an additional explicit
        // signal from the child. If this matters for your threat model, consider optionally logging (not failing)
        // if a WNOHANG waitpid immediately reports the child already gone:
        {
            var status: c_int = undefined;
            const wpid = system.waitpid(self.pid, &status, posix.W.NOHANG);
            if (wpid == self.pid) {
                self.pid = -1;
                if (posix.W.IFSIGNALED(@bitCast(status))) {
                    log.warn("pty child died from signal {} immediately after spawn " ++
                        "(before or after execve, undetermined)", .{posix.W.TERMSIG(@bitCast(status))});
                } else if (posix.W.IFEXITED(@bitCast(status))) {
                    log.info("pty child exited quickly with status {} after spawn", .{posix.W.EXITSTATUS(@bitCast(status))});
                }
            }
        }
    }

    /// Writes all of `iovecs` to the pty master, looping only when the kernel
    /// returns a short write (fewer bytes than the sum of all iovec lengths).
    /// A single writev(2) call can flush multiple logically-separate buffers
    /// (e.g. an escape-sequence prefix + payload) without the caller needing to
    /// concatenate them into one contiguous slice first.
    pub fn writevAll(self: *Posix, iovecs: []posix.iovec_const) !void {
        var i: usize = 0;
        while (i < iovecs.len) {
            const rc = system.writev(self.master, iovecs[i..].ptr, @intCast(iovecs.len - i));
            var written: usize = switch (posix.errno(rc)) {
                .SUCCESS => @intCast(rc),
                .INTR => continue,
                .AGAIN => return error.WouldBlock,
                else => |err| return posix.unexpectedErrno(err),
            };
            // advance past any iovecs that were fully consumed, and trim the first partially-consumed one in place.
            while (written > 0 and i < iovecs.len) {
                if (written < iovecs[i].len) {
                    iovecs[i].base += written;
                    iovecs[i].len -= written;
                    written = 0;
                } else {
                    written -= iovecs[i].len;
                    i += 1;
                }
            }
        }
    }

    /// Sends `sig` to the child. `target = .process` signals only the direct
    /// child (typically the shell) `target = .session` signals the whole
    /// process group (-pid), matching what `close()` does internally to reach
    /// orphaned foreground jobs (e.g. vim, less) started by the shell.
    /// Requires the child to have called setsid() (which spawn()'s child always
    /// does), otherwise `.session` behaves identically to `.process`.
    pub fn kill(self: *const Posix, signal: posix.SIG, comptime target: SignalTarget) !void {
        if (self.pid <= 0) return error.PtyClosed;
        const target_pid: posix.pid_t = switch (target) {
            .process => self.pid,
            .session => -self.pid,
        };

        try posix.kill(target_pid, signal);
    }

    /// Reads from the pty master. Returns 0 both on a real EOF/WouldBlock and on a zero-length
    /// read, callers cannot distinguish "no data right now" from "pty closed" from this return
    /// value alone, use isAlive()/wait() to check whether the child is still running.
    pub fn read(self: *Posix, dest: []u8) posix.ReadError!usize {
        return posix.read(self.master, dest) catch |err| switch (err) {
            // error.WouldBlock => return 0,
            else => return err,
        };
    }

    pub fn readRaw(self: *Posix, dest: []u8) posix.ReadError!usize {
        return try posix.read(self.master, dest);
    }

    /// Issues a single write(2) syscall to the pty master. Per POSIX, this may
    /// write fewer bytes than requested (a "short write"), the pty master has
    /// a limited kernel buffer, and large writes (fast paste, scrollback replay)
    /// are especially likely to be partial. Callers that need all bytes written
    /// must either loop on the returned count themselves, or may use `writeAll`.
    pub fn write(self: *Posix, src: []const u8) !isize {
        while (true) {
            const rc = system.write(self.master, src.ptr, src.len);
            return switch (posix.errno(rc)) {
                .SUCCESS => @intCast(rc),
                .INTR => continue, // interrupted by signal, retry the same call
                .AGAIN => return error.WouldBlock,
                else => |err| posix.unexpectedErrno(err),
            };
        }
    }

    /// Loops calling write(2) until all of src has been written to the pty master, or a real
    /// error occurs. Implemented as a single-buffer writevAll() call.
    pub fn writeAll(self: *Posix, src: []const u8) !void {
        var iov = [_]posix.iovec_const{.{ .base = src.ptr, .len = src.len }};
        return self.writevAll(&iov);
    }

    /// Sets the pty's window size (TIOCSWINSZ). Returns error.PtyClosed if the pty has no
    /// master fd (e.g. after close(), expected once the child exited; not logged), and
    /// error.ResizeFailed for any other ioctl failure, which is logged here with its errno,
    /// so callers need not log it again.
    pub fn resize(self: *Posix, rows: u16, cols: u16, x: u16, y: u16) !void {
        if (self.master <= 0) return error.PtyClosed;

        var ws = posix.winsize{
            .row = rows,
            .col = cols,
            .xpixel = x,
            .ypixel = y,
        };

        const rc = ioctl(self.master, tio.IOCSWINSZ, &ws);
        return switch (posix.errno(rc)) {
            .SUCCESS => {},
            else => |e| {
                log.warn("cannot resize the pty to {d}x{d}: TIOCSWINSZ failed ({t}); the child keeps its old size", .{ cols, rows, e });
                return error.ResizeFailed;
            },
        };
    }

    /// Non-blocking check for child state change (exit, signal death, or a job-control stop since
    /// `WUNTRACED` is passed).
    ///
    /// Returns null if the child is still running (no state change) or on error. On .exited or .signaled,
    /// self.pid is invalidated (set to -1), since the child is gone and its pid may be recycled by the kernel.
    /// On .stopped, self.pid is left untouched, since the child is only suspended, not gone, a subsequent `wait()`
    /// call may later observe it resume-and-later-exit, or the caller may `kill(.CONT, ...)` it.
    pub fn wait(self: *Posix) ?ExitStatus {
        if (self.pid <= 0) return null;

        var status: c_int = undefined;
        const rc = system.waitpid(self.pid, &status, posix.W.NOHANG | posix.W.UNTRACED);
        if (rc == 0) return null; // still running
        if (rc == self.pid) {
            const result = ExitStatus.fromU32(@bitCast(status));
            if (result != .stopped) self.pid = -1;
            return result;
        }
        return null; // error (e.g. ECHILD), nothing more we can report here
    }

    /// Returns whether the child still exists (kill(pid, 0) succeeds).
    /// True for a running or stopped (job-control suspended) child, false once it has
    /// exited or been reaped.
    ///
    /// Does not itself reap the child, use wait() for that.
    pub fn isAlive(self: *const Posix) bool {
        if (self.pid <= 0) return false;
        posix.kill(self.pid, @enumFromInt(0)) catch return false;
        return true;
    }

    fn report(fd: posix.fd_t, stage: ChildStage, rc: anytype) void {
        const err = posix.errno(rc);
        if (err != .SUCCESS) reportChildError(fd, stage, err);
    }

    // If write() fails here (e.g. EPIPE), the parent will observe this as a
    // clean EOF, indistinguishable from a successful exec. This is an accepted
    // limitation: by this point stdout/stderr may already be redirected away
    // from anything visible, so there is nothing more useful we can do.
    //
    // execve() never returns on success, so any return here is a failure report
    // unconditionally rather than gating through report().
    fn reportChildError(fd: posix.fd_t, stage: ChildStage, err: posix.E) noreturn {
        const info: ChildError = .{ .stage = stage, .errno = @intFromEnum(err) };
        const bytes = std.mem.asBytes(&info);

        var written: usize = 0;
        while (written < bytes.len) {
            const n = system.write(fd, bytes[written..].ptr, bytes.len - written);
            if (n < 0) {
                if (posix.errno(n) == .INTR) continue; // retry, don't give up
                break; // real error (EPIPE, EBADF, ...) — nothing more we can do
            }
            if (n == 0) break; // shouldn't happen for a nonzero-length write, defensive
            written += @intCast(n);
        }

        // _exit, not exit: this is the forked child of a possibly threaded
        // process. exit() runs atexit handlers and library destructors,
        // which can wait on locks or threads that exist only in the parent.
        // Under glibc 2.43 the child hung in exit() whenever the parent had
        // a Mesa thread.
        system._exit(1);
    }
};

pub const SpawnOption = struct {
    /// Initial pty window size in rows/cols, passed to openpty() and visible to the
    /// child immediately, before any later resize() call.
    rows: u16 = 24,
    cols: u16 = 24,

    /// argv[0] and beyond, null-terminated. If null, spawn() execve's /bin/sh.
    argv: ?[*:null]const ?[*:0]const u8 = null,

    /// Environment block passed directly to execve. Defaults to an empty environment,
    /// not the caller's own environment, pass one explicitly if you want inheritance.
    envp: [*:null]const ?[*:0]const u8 = &.{null},

    /// Working directory for the child, set via chdir() before execve. Null means
    /// inherit the parent's cwd. See spawn()'s FIXME comment about TOCTOU on this path.
    cwd: [*c]const u8 = null,

    /// Extra O_* flags OR'd onto the master fd after spawn (in addition to whatever
    /// openpty() already set). Commonly used to request O_NONBLOCK.
    o_flags: posix.O = .{},

    /// If true, the child's stdout is redirected to a separate pipe instead of the pty
    /// slave, and Posix.stdout_read_fd is set to that pipe's read end. If false,
    /// stdout goes to the slave like stdin/stderr.
    capture_stdout: bool = false,

    // shell_integration: ?

    /// What Rex's drivers spawn with: like `.{}`, but the master fd is
    /// non-blocking, because the drivers poll it. No argv makes App start
    /// the user's shell (`$SHELL`, then passwd); a null cwd inherits the
    /// parent's.
    pub const default: SpawnOption = .{ .o_flags = .{ .NONBLOCK = true, .ASYNC = false } };

    pub fn format(self: SpawnOption, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("  rows: {}\n", .{self.rows});
        try writer.print("  cols: {}\n", .{self.cols});
        try writer.print("  capture_stdout: {}\n", .{self.capture_stdout});
        try writer.print("  o_flags: {any}\n", .{self.o_flags});

        if (self.cwd == null) {
            try writer.writeAll("  cwd: null\n");
        } else {
            try writer.print("  cwd: {s}\n", .{self.cwd});
        }

        try writer.writeAll("  argv:");
        if (self.argv) |argv| {
            var i: usize = 0;
            while (argv[i]) |arg| : (i += 1) {
                try writer.print(" \"{s}\"", .{arg});
            }
        } else {
            try writer.writeAll(" null");
        }
        try writer.writeByte('\n');

        try writer.writeAll("  envp:");
        var i: usize = 0;
        while (self.envp[i]) |env| : (i += 1) {
            try writer.print(" \"{s}\"", .{env});
        }
    }

    pub fn winsize(self: *const SpawnOption) posix.winsize {
        return .{ .row = self.rows, .col = self.cols, .xpixel = 0, .ypixel = 0 };
    }
};

/// Decoded result of a waitpid() status word.
///
///  exited  : normal termination, value is the process's exit code (WEXITSTATUS).
///  signaled: killed by an uncaught signal, value is the signal number (WTERMSIG).
///  stopped : job-control suspend (e.g. Ctrl-Z / SIGTSTP), value is the stopping signal number (WSTOPSIG).
///            The child is not gone, wait() leaves self.pid intact for this case.
///  unknown : status didn't match any of the above (rare, e.g. WIFCONTINUED on some systems).
pub const ExitStatus = union(enum) {
    exited: u8,
    signaled: u32,
    stopped: u32,
    unknown: u32,

    /// Decodes a raw `waitpid` status word into a `ExitStatus`.
    ///
    /// `.stopped` is reachable because `wait()` passes `WUNTRACED`, so a
    /// job-control stop (e.g. Ctrl-Z / SIGTSTP) is reported here rather than
    /// being invisible to the caller. A `.stopped` result does NOT mean the
    /// child has terminated — `self.pid` remains valid and the child is still
    /// alive, just suspended. Callers must not treat `.stopped` the same as
    /// `.exited`/`.signaled`.
    pub fn fromU32(status: u32) ExitStatus {
        return switch (native_os) {
            .linux, .freebsd => if (posix.W.IFEXITED(status))
                .{ .exited = posix.W.EXITSTATUS(status) }
            else if (posix.W.IFSIGNALED(status))
                .{ .signaled = posix.W.TERMSIG(status) }
            else if (posix.W.IFSTOPPED(status))
                .{ .stopped = posix.W.STOPSIG(status) }
            else
                .{ .unknown = status },

            else => @compileError("unsupported os target"),
        };
    }
};

extern "c" fn tcgetpgrp(fd: c_int) posix.pid_t;

/// The terminal's foreground process group, or null when it can't be read
/// (a closed or not-a-terminal descriptor). Comparing it with the child's
/// pid tells whether the child (the shell) is in the foreground or a
/// program it started is. Read-only, so safe next to the pty's reader.
pub fn foregroundGroup(master: posix.fd_t) ?posix.pid_t {
    if (master < 0) return null;
    const group = tcgetpgrp(master);
    return if (group > 0) group else null;
}

/// The name of the terminal's foreground program: the `comm` of the
/// foreground group's leader, from `/proc/<pid>/comm`, at most 15 bytes
/// (proc_pid_comm(5)). Null when there is no foreground group or the file
/// cannot be read, as when the leader has exited. The result lies in `out`.
pub fn foregroundComm(master: posix.fd_t, out: []u8) ?[]const u8 {
    if (out.len == 0) return null;
    const group = foregroundGroup(master) orelse return null;
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "/proc/{d}/comm", .{group}) catch return null;
    const fd = system.open(path.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, @as(posix.mode_t, 0));
    if (fd < 0) return null;
    defer _ = system.close(fd);
    const n = system.read(fd, out.ptr, out.len);
    if (n <= 0) return null;
    const trimmed = std.mem.trimEnd(u8, out[0..@intCast(n)], "\r\n \x00");
    return if (trimmed.len > 0) trimmed else null;
}

/// A setup step in the child that failed, and its errno.
pub const SpawnFailure = struct {
    stage: ChildStage,
    errno: posix.E,

    /// "cannot run the program (NOENT)", for logs and messages.
    pub fn format(failure: SpawnFailure, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (failure.stage) {
            .chdir => try w.writeAll("cannot change to the working directory"),
            .execve => try w.writeAll("cannot run the program"),
            else => |stage| try w.print("pty setup failed at {t}", .{stage}),
        }
        if (std.enums.tagName(posix.E, failure.errno)) |name|
            try w.print(" ({s})", .{name})
        else
            try w.print(" (errno {d})", .{@intFromEnum(failure.errno)});
    }
};

/// Identifies exactly which setup step failed in the forked child, so the
/// parent can produce a precise diagnostic without guessing from errno alone.
pub const ChildStage = enum(u8) {
    setsid = 1,
    ioctl_tiocsctty = 2,
    dup2_stdin = 3,
    dup2_stdout_pipe = 4,
    dup2_stdout_slave = 5,
    dup2_stderr = 6,
    chdir = 7,
    execve = 8,
};

/// Written by the child (post-fork, pre-exec) to tell the parent exactly
/// which setup stage failed and with what errno. 3 bytes total, well under
/// PIPE_BUF, so the write() is atomic and safe to call without any locking.
const ChildError = packed struct {
    stage: ChildStage,
    errno: u16,
};
