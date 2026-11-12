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

pub const LimitAction = enum {
    /// Fade the screen to grayscale over `grayscale_transition_ms`.
    grayscale,
    /// Block terminal input while the limit alert is shown.
    lock_input,
    /// Animate the screen while the limit alert is shown.
    animation,
};

pub const TrackerOption = struct {
    idle_threshold_ms: u64 = 3 * std.time.ms_per_min,
    /// null: no daily limit.
    daily_limit_ms: ?u64 = null,
    proc_sample_interval_ms: u64 = 5 * std.time.ms_per_s,
    /// What happens once the daily limit is reached.
    on_limit: std.EnumSet(LimitAction) = .initOne(.grayscale),
    /// How long `grayscale` takes to fade in fully.
    grayscale_transition_ms: u64 = 30 * std.time.ms_per_s,
    track_foreground_apps: bool = true,
};

pub const Tracker = struct {
    option: TrackerOption,
    idle_timer_s: u32 = 0,
    sample_timer_s: u32 = 0,
    is_idle: bool = false,

    pub fn init(option: TrackerOption) Tracker {
        return .{ .option = option };
    }

    pub fn recordActivity(self: *Tracker) void {
        self.idle_timer_s = 0;
        self.is_idle = false;
    }

    /// Counts `dt_s` up to the idle threshold as screen time and returns the
    /// seconds added to `today`.
    pub fn tick(
        self: *Tracker,
        dt_s: u32,
        pty_fd: posix.fd_t,
        today: *storage.DayRecord,
    ) u32 {
        const idle_threshold_s = secondsCeil(self.option.idle_threshold_ms);
        const active_dt: u32 = if (self.idle_timer_s < idle_threshold_s)
            @intCast(@min(dt_s, idle_threshold_s - self.idle_timer_s))
        else
            0;

        self.idle_timer_s +|= dt_s;
        if (self.idle_timer_s >= idle_threshold_s) {
            self.is_idle = true;
        }

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
        }

        return active_dt;
    }
};

/// Today's screen time, in seconds, from which the daily limit applies: the
/// configured limit, or later while a dismissal keeps it quiet
/// (`PersistentData.limit_quiet_until_s`). null: no limit.
pub fn limitStart(option: *const TrackerOption, data: *const storage.PersistentData) ?u32 {
    const limit_ms = option.daily_limit_ms orelse return null;
    const limit_s = std.math.cast(u32, secondsCeil(limit_ms)) orelse std.math.maxInt(u32);
    return @max(limit_s, data.limit_quiet_until_s);
}

/// How gray the screen is, 0 to 1. It depends only on the settings and the
/// shared data, so every window shows the same, focused or not, and turning
/// the limit or the grayscale off on reload clears it.
pub fn grayscale(option: *const TrackerOption, data: *const storage.PersistentData) f32 {
    if (!option.on_limit.contains(.grayscale)) return 0.0;
    const start = limitStart(option, data) orelse return 0.0;
    if (data.today.active_screen_s < start) return 0.0;
    const excess = data.today.active_screen_s - start;
    const trans = @max(secondsCeil(option.grayscale_transition_ms), 1);
    return @min(@as(f32, @floatFromInt(excess)) / @as(f32, @floatFromInt(trans)), 1.0);
}

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
