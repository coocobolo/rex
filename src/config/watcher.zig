//! Non-blocking Linux inotify configuration file watcher.
//!
//! Monitors the configuration directory (~/.config/rex/) for atomic writes,
//! modifications, and moves, signaling the event loop when a reload is needed.

const std = @import("std");
const builtin = @import("builtin");
const is_linux = builtin.os.tag == .linux;

/// File event watcher monitoring directory changes for configuration file modifications.
pub const Watcher = struct {
    fd: ?std.posix.fd_t = null,
    wd: i32 = -1,
    target_filename: [64]u8 = undefined,
    target_len: usize = 0,
    last_reload_time_ms: i64 = 0,

    const IN_MODIFY: u32 = 0x00000002;
    const IN_CLOSE_WRITE: u32 = 0x00000008;
    const IN_MOVED_TO: u32 = 0x00000080;
    const IN_CREATE: u32 = 0x00000100;

    pub fn init(dir_path: []const u8, filename: []const u8) Watcher {
        var self = Watcher{};
        const len = @min(filename.len, self.target_filename.len);
        @memcpy(self.target_filename[0..len], filename[0..len]);
        self.target_len = len;

        if (!is_linux) return self;

        // Initialize non-blocking inotify with close-on-exec
        const fd = std.c.inotify_init1(0x00000800 | 0x00080000); // IN_NONBLOCK | IN_CLOEXEC
        if (fd < 0) return self;
        self.fd = fd;

        var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
        if (dir_path.len >= dir_buf.len) return self;
        @memcpy(dir_buf[0..dir_path.len], dir_path);
        dir_buf[dir_path.len] = 0;

        const mask = IN_CLOSE_WRITE | IN_MOVED_TO | IN_MODIFY | IN_CREATE;
        const wd = std.c.inotify_add_watch(fd, @ptrCast(&dir_buf), mask);
        if (wd < 0) {
            _ = std.posix.system.close(fd);
            self.fd = null;
            return self;
        }
        self.wd = wd;
        return self;
    }

    pub fn deinit(self: *Watcher) void {
        if (!is_linux) return;
        if (self.fd) |fd| {
            if (self.wd >= 0) {
                _ = std.c.inotify_rm_watch(fd, self.wd);
                self.wd = -1;
            }
            _ = std.posix.system.close(fd);
            self.fd = null;
        }
    }

    /// Checks if a modification event targeting the watched configuration file has arrived.
    pub fn checkChanged(self: *Watcher) bool {
        if (!is_linux) return false;
        const fd = self.fd orelse return false;

        var buf: [4096]u8 align(@alignOf(std.os.linux.inotify_event)) = undefined;
        var changed = false;

        while (true) {
            const rc = std.posix.system.read(fd, &buf, buf.len);
            const err = std.posix.errno(rc);
            if (rc <= 0) {
                if (err == .AGAIN) break;
                break;
            }

            const bytes_read: usize = @intCast(rc);
            var offset: usize = 0;
            while (offset + @sizeOf(std.os.linux.inotify_event) <= bytes_read) {
                const event: *const std.os.linux.inotify_event = @ptrCast(@alignCast(&buf[offset]));
                const total_event_len = @sizeOf(std.os.linux.inotify_event) + event.len;

                if (event.len > 0 and offset + total_event_len <= bytes_read) {
                    const name_slice = std.mem.sliceTo(buf[offset + @sizeOf(std.os.linux.inotify_event) .. offset + total_event_len], 0);
                    if (std.mem.eql(u8, name_slice, self.target_filename[0..self.target_len])) {
                        changed = true;
                    }
                }

                offset += total_event_len;
            }
        }

        if (changed) {
            // Debounce: coalesce multi-stage write events within 100 milliseconds
            var ts: std.posix.timespec = undefined;
            _ = std.posix.system.clock_gettime(std.posix.CLOCK.MONOTONIC, &ts);
            const now_ms: i64 = @as(i64, ts.sec) * 1000 + @divTrunc(ts.nsec, 1_000_000);
            if (now_ms - self.last_reload_time_ms < 100) return false;
            self.last_reload_time_ms = now_ms;
            return true;
        }

        return false;
    }
};
