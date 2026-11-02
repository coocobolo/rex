const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const max_u64 = std.math.maxInt(u64);
const log = std.log.scoped(.pomodoro);

const Manager = @import("persistance.zig").Manager;

const magic: u32 = 0x504F4D4F;
const version: u32 = 1;

pub const Phase = enum {
    idle,
    task,
    short_break,
    long_break,
};

pub const Option = struct {
    display: Display = .{},
    long_break_ms: u64,
    short_break_ms: u64,
    task_ms: u64,
    tasks_before_long_break: u8,
    time_fields: TimeFields = .initMany(&.{ .minute, .second }),
    timer_mode: TimerMode,
    transition_mode: TransitionMode,

    pub const TimerMode = enum { countup, countdown };
    pub const TransitionMode = enum { auto, manual };
    pub const TimeField = enum { hour, minute, second, milisecond };
    pub const TimeFields = std.EnumSet(TimeField);

    pub const Display = struct {
        task_icon: []const u8 = "🎯",
        break_icon: []const u8 = "☕",
        paused_icon: []const u8 = "▸",
        separator: []const u8 = "  ",
    };

    pub const default: Option = .{
        .timer_mode = .countdown,
        .long_break_ms = 15 * 60_000,
        .short_break_ms = 5 * 60_000,
        .task_ms = 25 * 60_000,
        .tasks_before_long_break = 4,
        .transition_mode = .manual,
    };
};

pub const Stats = struct {
    best_streak: u32,
    /// total time spent in break phases
    break_ms: u64,
    current_streak: u32,
    /// total time spent in task phases
    focus_ms: u64,
    /// days since Unix epoch; 0 = never
    last_task_day: u32,
    long_breaks_taken: u32,
    /// number of times toggle() started from idle
    sessions: u32,
    tasks_completed: u32,

    pub const empty: Stats = .{
        .tasks_completed = 0,
        .long_breaks_taken = 0,
        .focus_ms = 0,
        .break_ms = 0,
        .sessions = 0,
        .best_streak = 0,
        .current_streak = 0,
        .last_task_day = 0,
    };

    pub fn onTaskCompleted(self: *Stats, io: Io) void {
        const now_secs = std.Io.Timestamp.now(io, .real).toSeconds();
        const today: u32 = @intCast(@divFloor(now_secs, std.time.s_per_day));

        if (today == self.last_task_day) {
            // Already completed a task today — streak unchanged
        } else if (today == self.last_task_day + 1) {
            // Consecutive day
            self.current_streak += 1;
        } else {
            // First ever task or A gap between, streak broken
            self.current_streak = 1;
        }

        self.best_streak = @max(self.best_streak, self.current_streak);
        self.tasks_completed += 1;
        self.last_task_day = today;
    }
};

/// Flat binary layout written to persistence, guaranteees stable field order.
const Report = extern struct {
    magic: u32,
    version: u32,

    // Statistic
    tasks_completed: u32,
    long_breaks_taken: u32,
    sessions: u32,
    current_streak: u32,
    best_streak: u32,
    last_task_day: u32,

    // Snapshot (phase == 0 means .idle, nothing to restore)
    // on phase .idle, no active session; remaining_ms = 0 is harmless
    phase: u8,
    tasks_in_cycle: u8,
    _pad: [6]u8 = @splat(0), // align u64 fields to offset 40
    focus_ms: u64,
    break_ms: u64,
    remaining_ms: u64,

    pub const empty: Report = std.mem.zeroInit(Report, .{});

    // .{
    //     .magic = magic,
    //     .version = version,
    //     .tasks_completed = 0,
    //     .long_breaks_taken = 0,
    //     .sessions = 0,
    //     .current_streak = 0,
    //     .best_streak = 0,
    //     .last_task_day = 0,
    //     .phase = 0,
    //     .tasks_in_cycle = 0,
    // };

    pub fn toState(self: *const Report) ?State {
        const phase = std.enums.fromInt(Phase, self.phase) orelse return null;
        return .{
            .option = .default,
            .phase = phase,
            .remaining_ms = self.remaining_ms,
            .tasks_in_cycle = self.tasks_in_cycle,
        };
    }

    pub fn toStats(self: *const Report) Stats {
        return .{
            .break_ms = self.break_ms,
            .focus_ms = self.focus_ms,
            .sessions = self.sessions,
            .best_streak = self.best_streak,
            .last_task_day = self.last_task_day,
            .current_streak = self.current_streak,
            .tasks_completed = self.tasks_completed,
            .long_breaks_taken = self.long_breaks_taken,
        };
    }
};

const report_size = @sizeOf(Report);

pub fn save(
    io: Io,
    stats: *const Stats,
    state: *const State,
    dirs_state: []const u8,
    filename: []const u8,
) !void {
    // Create parent directories if they don't exist
    // const parent_dir = std.Io.Dir.path.dirname(dirs_state) orelse dirs_state;

    const dir = try std.Io.Dir.createDirPathOpen(.cwd(), io, dirs_state, .{});
    defer dir.close(io);

    const report: Report = .{
        .best_streak = stats.best_streak,
        .break_ms = stats.break_ms,
        .current_streak = stats.current_streak,
        .focus_ms = stats.focus_ms,
        .last_task_day = stats.last_task_day,
        .long_breaks_taken = stats.long_breaks_taken,
        .magic = magic,
        .phase = @intFromEnum(state.phase),
        .remaining_ms = state.remaining_ms,
        .sessions = stats.sessions,
        .tasks_completed = stats.tasks_completed,
        .tasks_in_cycle = state.tasks_in_cycle,
        .version = version,
    };

    const file = try dir.createFile(io, filename, .{
        .truncate = true,
    });
    defer file.close(io);

    try file.writePositionalAll(io, std.mem.asBytes(&report), 0);
    log.debug("pomodoro saved ok! {s}/{s} {any}\n", .{ dirs_state, filename, report });
}

pub const Result = struct {
    stats: Stats,

    phase: u8,
    remaining_ms: u64,
    tasks_in_cycle: u8,

    pub const empty: Result = .{
        .stats = .empty,
        .phase = 0,
        .remaining_ms = 0,
        .tasks_in_cycle = 0,
    };
};

pub fn load(
    io: Io,
    state_dir: []const u8,
    filename: []const u8,
) Report {
    log.debug("load report file: {s}/{s}", .{ state_dir, filename });
    const dir = std.Io.Dir.openDir(.cwd(), io, state_dir, .{}) catch {
        return .empty;
    };
    defer dir.close(io);

    const file = dir.openFile(io, filename, .{ .mode = .read_only }) catch {
        return .empty;
    };
    defer file.close(io);

    var report: Report = undefined;
    const n = file.readPositionalAll(io, std.mem.asBytes(&report), 0) catch return .empty;
    if (n != report_size or report.magic != magic or report.version != version) {
        return .empty;
    }

    return report;

    // const phase = std.enums.fromInt(Phase, report.phase) orelse .idle;
    // return .{
    //     .stats = .{
    //         .break_ms = report.break_ms,
    //         .focus_ms = report.focus_ms,
    //         .sessions = report.sessions,
    //         .best_streak = report.best_streak,
    //         .last_task_day = report.last_task_day,
    //         .current_streak = report.current_streak,
    //         .tasks_completed = report.tasks_completed,
    //         .long_breaks_taken = report.long_breaks_taken,
    //     },
    //     .phase = report.phase,
    //     .remaining_ms = report.remaining_ms,
    //     .tasks_in_cycle = report.tasks_in_cycle,
    // };
}

pub const State = struct {
    option: Option,
    remaining_ms: u64 = 0,
    phase: Phase,
    paused: bool = false,
    waiting: bool = false,

    /// resets after each long break; drives long-break trigger
    tasks_in_cycle: u8 = 0,

    pub const idle: State = .{
        .phase = .idle,
        .option = .default,
    };

    pub fn advance(self: *State) void {
        const opt = self.option;
        self.paused = false;
        self.waiting = false;

        switch (self.phase) {
            .task => {
                self.tasks_in_cycle += 1;

                if (self.tasks_in_cycle >= opt.tasks_before_long_break) {
                    self.tasks_in_cycle = 0;
                    self.remaining_ms = opt.long_break_ms;
                    self.phase = .long_break;
                } else {
                    self.remaining_ms = opt.short_break_ms;
                    self.phase = .short_break;
                }
            },
            .short_break, .long_break, .idle => {
                self.phase = .task;
                self.remaining_ms = opt.task_ms;
            },
        }
    }

    pub fn setTransitionMode(self: *State, mode: Option.TransitionMode) void {
        self.option.transition_mode = mode;
        if (self.waiting and mode == .auto) {
            self.waiting = false;
            self.advance();
        }
    }

    /// Start (from idle), pause (running to paused), or resume (paused to running).
    pub fn toggle(self: *State) void {
        const option = self.option;
        switch (self.phase) {
            .idle => {
                self.phase = .task;
                self.paused = false;
                self.remaining_ms = option.task_ms;
            },
            .task, .short_break, .long_break => {
                if (self.waiting)
                    // user confirmed, start next phase
                    self.advance()
                else
                    self.paused = !self.paused;
            },
        }
    }

    /// Skip the current phase and advance to the next one immediately.
    pub fn skip(self: *State) void {
        if (self.phase == .idle) return;
        self.advance();

        // In manual mode: don't auto-start the next phase.
        // Use paused=true so toggle() resumes (not advances) on next press.
        self.paused = self.option.transition_mode == .manual;
    }

    /// Full reset, back to idle, clears session count.
    pub fn reset(self: *State) void {
        const option = self.option;
        self.* = .idle;
        self.option = option;
    }

    /// Tick the timer by dt_ms. Returns true if the phase just ended
    pub fn tick(self: *State, dt_ms: u64) bool {
        if (self.phase == .idle or self.paused or self.waiting) return false;
        // if (self.remaining_ms == self.getDuration(self.phase)) return false;
        if (dt_ms >= self.remaining_ms) {
            self.remaining_ms = 0;
            self.waiting = self.option.transition_mode == .manual;
            return true;
        }
        self.remaining_ms -= dt_ms;
        return false;
    }

    /// Milliseconds until the next tick boundary (for waitEventsTimeout).
    pub fn msUntilTick(self: *const State) u64 {
        if (self.phase == .idle or self.paused or self.waiting) return max_u64;
        // Update title every second
        return (self.remaining_ms % 1000) + 1;
    }

    pub fn getDuration(self: *const State, phase: Phase) u64 {
        return switch (phase) {
            .task => self.option.task_ms,
            .short_break => self.option.short_break_ms,
            .long_break => self.option.long_break_ms,
            .idle => 0,
        };
    }

    fn write2d(buf: []u8, end: *usize, n: u8) void {
        buf[end.*] = '0' + n / 10;
        buf[end.* + 1] = '0' + n % 10;
        end.* += 2;
    }

    fn write3d(buf: []u8, end: *usize, n: u16) void {
        std.debug.assert(n <= 999);

        buf[end.*] = '0' + @as(u8, @intCast(n / 100));
        buf[end.* + 1] = '0' + @as(u8, @intCast((n % 100) / 10));
        buf[end.* + 2] = '0' + @as(u8, @intCast(n % 10));
        end.* += 3;
    }

    /// Format for window title. Returns empty slice when idle.
    pub fn fmt(self: *const State, buf: []u8) []const u8 {
        if (self.phase == .idle) return buf[0..0];

        const option = self.option;
        const display = option.display;
        const time_fields = self.option.time_fields;

        // Resolve the "effective" phase, when waiting, we show the next phase's info
        const effective_phase: Phase = if (self.waiting) switch (self.phase) {
            .idle => unreachable,
            .task => if ((self.tasks_in_cycle + 1) >= option.tasks_before_long_break)
                .long_break
            else
                .short_break,
            .short_break, .long_break => .task,
        } else self.phase;

        // Resolve display in milisecond
        const display_ms: u64 = if (self.waiting)
            self.getDuration(effective_phase)
        else blk: {
            const phase_ms = self.getDuration(self.phase);
            break :blk if (option.timer_mode == .countup) phase_ms - self.remaining_ms else self.remaining_ms;
        };

        const is_transition = display_ms == self.remaining_ms;

        // Resolve icon, paused ovverrides only when not waiting (waiting implies paused=false)
        const icon: []const u8 = if (!self.waiting and self.paused and !is_transition)
            display.paused_icon
        else switch (effective_phase) {
            .idle => unreachable,
            .task => display.task_icon,
            .short_break, .long_break => display.break_icon,
        };

        // Build time string from time_fields
        var time_buf: [32]u8 = undefined;
        var end: usize = 0;

        const h: u8 = @intCast(display_ms / 3_600_000); // 0–99 for any sane duration
        const m: u8 = @intCast((display_ms % 3_600_000) / 60_000); // 0–59
        const s: u8 = @intCast((display_ms % 60_000) / 1_000); // 0–59
        const ms: u16 = @intCast(display_ms % 1_000); // 0–999

        var first = true;
        if (time_fields.contains(.hour)) {
            write2d(&time_buf, &end, h);
            first = false;
        }
        if (time_fields.contains(.minute)) {
            if (!first) {
                time_buf[end] = ':';
                end += 1;
            }
            write2d(&time_buf, &end, m);
            first = false;
        }
        if (time_fields.contains(.second)) {
            if (!first) {
                time_buf[end] = ':';
                end += 1;
            }
            write2d(&time_buf, &end, s);
            first = false;
        }

        if (time_fields.contains(.milisecond)) {
            if (!first) {
                time_buf[end] = '.';
                end += 1;
            }
            write3d(&time_buf, &end, ms);
        }

        const time_str = time_buf[0..end];
        return std.fmt.bufPrint(buf, " {s}{s}{s}", .{ icon, display.separator, time_str }) catch buf[0..0];
    }
};