//! Linux only: tells a tool window that another process saved one file. A
//! thread blocks in poll(2) on an inotify descriptor for the file's
//! directory and on a pipe that `destroy` writes to. On a save of the named
//! file it sets `changed` and calls `notify` (the host's loop wake); it
//! never touches the tool's state. Heap-allocated because the thread holds
//! a pointer to it while the tool's state moves.
//!
//! When the thread ends on its own (an error, or the directory was removed
//! or moved) it clears `alive` and calls `notify`, so the tool falls back to
//! polling.

const std = @import("std");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;

const pipe = @import("../termio/pipe.zig");

const FileWatch = @This();

const log = std.log.scoped(.tool);

inotify: linux.fd_t,
stop_r: linux.fd_t,
stop_w: linux.fd_t,
thread: std.Thread,
/// Borrowed; must outlive the watch.
name: []const u8,
notify: *const fn () void,
/// Set by the thread before `notify`, cleared by the reader.
changed: std.atomic.Value(bool) = .init(false),
alive: std.atomic.Value(bool) = .init(true),

pub const Error = Allocator.Error || pipe.Error || std.Thread.SpawnError || error{
    NameTooLong,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    SystemResources,
    WatchLimitReached,
    FileNotFound,
    AccessDenied,
    NotDir,
    Unexpected,
};

/// A save is a write that closes (`IN_CLOSE_WRITE`) or a rename into place
/// (`IN_MOVED_TO`). The directory going away ends the watch.
const mask: u32 = linux.IN.CLOSE_WRITE | linux.IN.MOVED_TO | linux.IN.DELETE_SELF | linux.IN.MOVE_SELF | linux.IN.ONLYDIR;

/// Watches `dir` for saves of `name`. `name` is borrowed.
pub fn create(gpa: Allocator, dir: []const u8, name: []const u8, notify: *const fn () void) Error!*FileWatch {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (dir.len >= path_buf.len) return error.NameTooLong;
    @memcpy(path_buf[0..dir.len], dir);
    path_buf[dir.len] = 0;

    var stop_fds: [2]linux.fd_t = undefined;
    try pipe.open(&stop_fds, .{ .CLOEXEC = true });
    errdefer closeFd(stop_fds[0]);
    errdefer closeFd(stop_fds[1]);

    const init_rc = linux.inotify_init1(linux.IN.CLOEXEC);
    switch (linux.errno(init_rc)) {
        .SUCCESS => {},
        .MFILE => return error.ProcessFdQuotaExceeded,
        .NFILE => return error.SystemFdQuotaExceeded,
        .NOMEM => return error.SystemResources,
        else => return error.Unexpected,
    }
    const inotify: linux.fd_t = @intCast(init_rc);
    errdefer closeFd(inotify);

    const watch_rc = linux.inotify_add_watch(inotify, path_buf[0..dir.len :0], mask);
    switch (linux.errno(watch_rc)) {
        .SUCCESS => {},
        .NOSPC => return error.WatchLimitReached,
        .NOENT => return error.FileNotFound,
        .ACCES => return error.AccessDenied,
        .NOTDIR => return error.NotDir,
        .NOMEM => return error.SystemResources,
        else => return error.Unexpected,
    }

    const self = try gpa.create(FileWatch);
    errdefer gpa.destroy(self);
    self.* = .{
        .inotify = inotify,
        .stop_r = stop_fds[0],
        .stop_w = stop_fds[1],
        .thread = undefined,
        .name = name,
        .notify = notify,
    };
    self.thread = try std.Thread.spawn(.{}, loop, .{self});
    return self;
}

/// Stops and joins the thread. If the stop byte cannot be written the
/// thread may still be blocked: it is detached and the watch is leaked
/// rather than freed under it.
pub fn destroy(self: *FileWatch, gpa: Allocator) void {
    const byte = [1]u8{1};
    while (true) {
        const rc = linux.write(self.stop_w, &byte, 1);
        switch (linux.errno(rc)) {
            .SUCCESS => break,
            .INTR => continue,
            else => |e| {
                log.err("cannot stop the file watch ({t}); leaving its thread", .{e});
                self.thread.detach();
                return;
            },
        }
    }
    self.thread.join();
    closeFd(self.inotify);
    closeFd(self.stop_r);
    closeFd(self.stop_w);
    gpa.destroy(self);
}

/// True once since the last call when the file was saved.
pub fn takeChanged(self: *FileWatch) bool {
    return self.changed.swap(false, .acquire);
}

pub fn isAlive(self: *const FileWatch) bool {
    return self.alive.load(.acquire);
}

fn loop(self: *FileWatch) void {
    // Large enough for any one event (header plus NAME_MAX + 1), so read(2)
    // never fails with EINVAL.
    var buf: [4096]u8 align(@alignOf(linux.inotify_event)) = undefined;
    while (true) {
        var fds = [2]linux.pollfd{
            .{ .fd = self.inotify, .events = linux.POLL.IN, .revents = 0 },
            .{ .fd = self.stop_r, .events = linux.POLL.IN, .revents = 0 },
        };
        switch (linux.errno(linux.poll(&fds, fds.len, -1))) {
            .SUCCESS => {},
            .INTR => continue,
            else => |e| return self.end("poll failed", e),
        }
        if (fds[1].revents != 0) return;
        if (fds[0].revents & linux.POLL.IN == 0) return self.end("descriptor error", .IO);

        const rc = linux.read(self.inotify, &buf, buf.len);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .INTR => continue,
            else => |e| return self.end("read failed", e),
        }
        const scan = scanEvents(buf[0..rc], self.name);
        if (scan.saved) {
            self.changed.store(true, .release);
            self.notify();
        }
        if (scan.gone) return self.end("the directory was removed or moved", .SUCCESS);
    }
}

fn end(self: *FileWatch, why: []const u8, e: linux.E) void {
    if (e == .SUCCESS) log.warn("file watch ended: {s}", .{why}) else log.warn("file watch ended: {s} ({t})", .{ why, e });
    self.alive.store(false, .release);
    self.notify();
}

const Scan = struct { saved: bool = false, gone: bool = false };

/// Reads a batch of inotify events: was `name` saved, and did the watch end.
fn scanEvents(bytes: []align(@alignOf(linux.inotify_event)) const u8, name: []const u8) Scan {
    var scan: Scan = .{};
    var offset: usize = 0;
    while (offset + @sizeOf(linux.inotify_event) <= bytes.len) {
        const event: *const linux.inotify_event = @ptrCast(@alignCast(bytes[offset..].ptr));
        const name_start = offset + @sizeOf(linux.inotify_event);
        const name_end = name_start + event.len;
        if (name_end > bytes.len) break;
        // The kernel pads the name with NULs to the record's length.
        const event_name = std.mem.sliceTo(bytes[name_start..name_end], 0);
        if (event.mask & (linux.IN.CLOSE_WRITE | linux.IN.MOVED_TO) != 0 and std.mem.eql(u8, event_name, name)) scan.saved = true;
        if (event.mask & (linux.IN.IGNORED | linux.IN.DELETE_SELF | linux.IN.MOVE_SELF) != 0) scan.gone = true;
        offset = name_end;
    }
    return scan;
}

/// close(2) on Linux releases the descriptor even when it reports an
/// error, and these descriptors were never written to a file, so there is
/// nothing to retry or lose.
fn closeFd(fd: linux.fd_t) void {
    _ = linux.close(fd);
}
