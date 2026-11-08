const std = @import("std");
const storage = @import("storage.zig");
const posix = std.posix;
const system = posix.system;

extern "c" fn tcgetpgrp(fd: c_int) posix.pid_t;

/// Whole seconds in `ms`, rounded up. The engines tick in whole seconds, so a
/// threshold given in milliseconds is reached at this many seconds, never earlier.
pub fn secondsCeil(ms: u64) u64 {
    return ms / std.time.ms_per_s + @intFromBool(ms % std.time.ms_per_s != 0);
}

pub const TrackerOption = struct {
    idle_threshold_ms: u64 = 3 * std.time.ms_per_min,
    /// null: no daily limit.
    daily_limit_ms: ?u64 = 8 * std.time.ms_per_hour,
    proc_sample_interval_ms: u64 = 5 * std.time.ms_per_s,
    grayscale_on_limit: bool = true,
    grayscale_transition_ms: u64 = 30 * std.time.ms_per_s,
    lock_input_on_limit: bool = false,
    show_limit_animation: bool = false,
    track_foreground_apps: bool = true,
};

pub const Tracker = struct {
    option: TrackerOption,
    idle_timer_s: u32 = 0,
    is_idle: bool = false,
    sample_timer_s: u32 = 0,
    grayscale_factor: f32 = 0.0,
    limit_notified: bool = false,

    pub fn init(option: TrackerOption) Tracker {
        return .{ .option = option };
    }

    pub fn recordActivity(self: *Tracker) void {
        self.idle_timer_s = 0;
        self.is_idle = false;
    }

    pub fn tick(
        self: *Tracker,
        dt_s: u32,
        pty_fd: posix.fd_t,
        today: *storage.DayRecord,
    ) struct { limit_reached: bool } {
        const idle_threshold_s = secondsCeil(self.option.idle_threshold_ms);
        const active_dt: u32 = if (self.idle_timer_s < idle_threshold_s)
            @intCast(@min(dt_s, idle_threshold_s - self.idle_timer_s))
        else
            0;

        self.idle_timer_s +|= dt_s;
        if (self.idle_timer_s >= idle_threshold_s) {
            self.is_idle = true;
        }

        var limit_triggered = false;

        if (active_dt > 0) {
            today.active_screen_s +|= active_dt;

            // Sample foreground app
            if (self.option.track_foreground_apps and pty_fd >= 0) {
                self.sample_timer_s +|= active_dt;
                if (self.sample_timer_s >= secondsCeil(self.option.proc_sample_interval_ms)) {
                    var comm_buf: [storage.max_comm_len]u8 = undefined;
                    if (sampleForegroundApp(pty_fd, &comm_buf)) |comm| {
                        today.addAppTime(comm, self.sample_timer_s);
                    }
                    self.sample_timer_s = 0;
                }
            }

            // Daily screen time limit check. Every path sets grayscale_factor,
            // so turning the limit or the grayscale off on reload clears it.
            if (self.option.daily_limit_ms) |limit_ms| {
                const limit_s = secondsCeil(limit_ms);
                if (today.active_screen_s >= limit_s) {
                    if (!self.limit_notified) {
                        self.limit_notified = true;
                        limit_triggered = true;
                    }

                    if (self.option.grayscale_on_limit) {
                        const excess = today.active_screen_s - limit_s;
                        const trans = @max(secondsCeil(self.option.grayscale_transition_ms), 1);
                        const progress = @min(@as(f32, @floatFromInt(excess)) / @as(f32, @floatFromInt(trans)), 1.0);
                        self.grayscale_factor = progress;
                    } else {
                        self.grayscale_factor = 0.0;
                    }
                } else {
                    self.grayscale_factor = 0.0;
                    self.limit_notified = false;
                }
            } else {
                self.grayscale_factor = 0.0;
                self.limit_notified = false;
            }
        }

        return .{ .limit_reached = limit_triggered };
    }
};

pub fn sampleForegroundApp(pty_fd: posix.fd_t, out_comm: []u8) ?[]const u8 {
    if (pty_fd < 0) return null;
    const pgrp = tcgetpgrp(@intCast(pty_fd));
    if (pgrp <= 0) return null;

    var path_buf: [32]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "/proc/{d}/comm", .{pgrp}) catch return null;

    const fd = system.open(path.ptr, .{ .ACCMODE = .RDONLY }, @as(posix.mode_t, 0));
    if (fd < 0) return null;
    defer _ = system.close(fd);

    const n = system.read(fd, out_comm.ptr, out_comm.len);
    if (n <= 0) return null;
    const n_u: usize = @intCast(n);
    const trimmed = std.mem.trimEnd(u8, out_comm[0..n_u], "\r\n \x00");
    return if (trimmed.len > 0) trimmed else null;
}
