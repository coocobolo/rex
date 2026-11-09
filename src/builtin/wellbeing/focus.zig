const std = @import("std");

const max_u64 = std.math.maxInt(u64);

pub const Phase = enum(u8) {
    idle = 0,
    task = 1,
    short_break = 2,
    long_break = 3,
};

pub const Option = struct {
    display: Display = .{},
    long_break_ms: u64 = 15 * 60_000,
    short_break_ms: u64 = 5 * 60_000,
    task_ms: u64 = 25 * 60_000,
    tasks_before_long_break: u8 = 4,
    time_fields: TimeFields = .initMany(&.{ .minute, .second }),
    timer: Count = .countdown,
    on_phase_end: PhaseEnd = .wait,
    during_task: std.EnumSet(TaskAction) = .initOne(.mute_bell),
    on_break: std.EnumSet(BreakAction) = .initMany(&.{ .prompt, .animation }),
    on_alert: std.EnumSet(AlertAction) = .initOne(.pause),

    /// Whether the timer shows the time left or the time spent.
    pub const Count = enum { countdown, countup };
    pub const PhaseEnd = enum {
        /// Wait for the user to start the next phase.
        wait,
        start_next,
    };
    pub const TaskAction = enum { mute_bell };
    pub const BreakAction = enum {
        /// Show a break suggestion, a different one each break.
        prompt,
        /// Block terminal input for the whole break.
        lock_input,
        /// Animate the screen while the prompt is shown; shows the prompt.
        animation,
    };
    pub const AlertAction = enum {
        /// Pause a running task while a reminder blocks input.
        pause,
    };
    pub const TimeField = enum { hour, minute, second, millisecond };
    pub const TimeFields = std.EnumSet(TimeField);

    pub const Display = struct {
        task_icon: []const u8 = "FOCUS",
        break_icon: []const u8 = "BREAK",
        paused_icon: []const u8 = "PAUSED",
        separator: []const u8 = "  ",
    };

    pub const default: Option = .{};
};

/// How a phase of the shared timer is kept (stored as `storage.Timer.run`).
pub const Run = enum(u8) {
    /// `Timer.ms` is the time left.
    paused = 0,
    /// `Timer.ms` is the wall-clock time, in milliseconds since the epoch,
    /// at which the phase ends.
    running = 1,
    /// The phase ended and waits for the user; `Timer.ms` is unused.
    waiting = 2,
};

/// The focus timer shared by all windows. It holds an absolute end time
/// while running, so every process derives the same time left from its own
/// clock and nothing is written while it runs. Setting the wall clock moves
/// a running phase; suspend counts as elapsed time.
pub const Timer = struct {
    phase: Phase = .idle,
    run: Run = .paused,
    ms: i64 = 0,
    /// Tasks completed since the last long break.
    tasks_in_cycle: u8 = 0,

    pub fn remainingMs(self: Timer, now_ms: i64) u64 {
        return switch (self.run) {
            .paused => std.math.cast(u64, self.ms) orelse 0,
            .running => std.math.cast(u64, self.ms -| now_ms) orelse 0,
            .waiting => 0,
        };
    }
};

/// What a transition adds to the statistics. It is recorded only when the
/// transition wins the write (see `Wellbeing.sync`), so a phase end that
/// several windows notice counts once.
pub const Tally = struct {
    tasks: u32 = 0,
    long_breaks: u32 = 0,
    sessions: u32 = 0,
    focus_ms: u64 = 0,
    break_ms: u64 = 0,

    pub const empty: Tally = .{};

    pub fn add(self: *Tally, other: Tally) void {
        self.tasks +|= other.tasks;
        self.long_breaks +|= other.long_breaks;
        self.sessions +|= other.sessions;
        self.focus_ms +|= other.focus_ms;
        self.break_ms +|= other.break_ms;
    }

    pub fn isEmpty(self: Tally) bool {
        return std.meta.eql(self, empty);
    }
};

pub const Change = struct {
    timer: Timer,
    tally: Tally = .empty,
};

pub fn durationMs(option: Option, phase: Phase) u64 {
    return switch (phase) {
        .task => option.task_ms,
        .short_break => option.short_break_ms,
        .long_break => option.long_break_ms,
        .idle => 0,
    };
}

fn msFrom(now_ms: i64, duration_ms: u64) i64 {
    return now_ms +| (std.math.cast(i64, duration_ms) orelse std.math.maxInt(i64));
}

/// The phase after `timer`'s, starting at `now_ms` (running) or waiting for
/// a resume (paused). A task counts toward the long break.
fn next(timer: Timer, option: Option, now_ms: i64, run: Run) Timer {
    var out = timer;
    switch (timer.phase) {
        .task => {
            out.tasks_in_cycle +|= 1;
            if (out.tasks_in_cycle >= option.tasks_before_long_break) {
                out.tasks_in_cycle = 0;
                out.phase = .long_break;
            } else {
                out.phase = .short_break;
            }
        },
        .short_break, .long_break, .idle => out.phase = .task,
    }
    const duration_ms = durationMs(option, out.phase);
    out.run = run;
    out.ms = if (run == .running) msFrom(now_ms, duration_ms) else std.math.cast(i64, duration_ms) orelse std.math.maxInt(i64);
    return out;
}

/// Time spent in the current phase when it is left early (skip, reset),
/// counted as focus or break time. A waiting phase was counted when it ended.
fn spent(timer: Timer, option: Option, now_ms: i64) Tally {
    if (timer.run == .waiting) return .empty;
    const ms = durationMs(option, timer.phase) -| timer.remainingMs(now_ms);
    return switch (timer.phase) {
        .task => .{ .focus_ms = ms },
        .short_break, .long_break => .{ .break_ms = ms },
        .idle => .empty,
    };
}

/// Start (from idle), pause, resume, or confirm the next phase (waiting).
pub fn toggle(timer: Timer, option: Option, now_ms: i64) Change {
    return switch (timer.phase) {
        .idle => .{
            .timer = .{ .phase = .task, .run = .running, .ms = msFrom(now_ms, option.task_ms) },
            .tally = .{ .sessions = 1 },
        },
        .task, .short_break, .long_break => switch (timer.run) {
            .waiting => .{ .timer = next(timer, option, now_ms, .running) },
            .running => .{ .timer = .{
                .phase = timer.phase,
                .run = .paused,
                .ms = std.math.cast(i64, timer.remainingMs(now_ms)) orelse 0,
                .tasks_in_cycle = timer.tasks_in_cycle,
            } },
            .paused => .{ .timer = .{
                .phase = timer.phase,
                .run = .running,
                .ms = msFrom(now_ms, timer.remainingMs(now_ms)),
                .tasks_in_cycle = timer.tasks_in_cycle,
            } },
        },
    };
}

/// Leaves the current phase for the next one. With `on_phase_end = wait`
/// the next phase starts paused, so a toggle resumes it.
pub fn skip(timer: Timer, option: Option, now_ms: i64) ?Change {
    if (timer.phase == .idle) return null;
    const run: Run = if (option.on_phase_end == .wait) .paused else .running;
    return .{ .timer = next(timer, option, now_ms, run), .tally = spent(timer, option, now_ms) };
}

/// Back to idle; the time spent in the current phase still counts.
pub fn reset(timer: Timer, option: Option, now_ms: i64) Change {
    return .{ .timer = .{}, .tally = spent(timer, option, now_ms) };
}

/// The phase end, once a running phase reaches its end time: counts the
/// whole phase, then waits or starts the next phase per `on_phase_end`.
pub fn endIfDue(timer: Timer, option: Option, now_ms: i64) ?Change {
    if (timer.phase == .idle or timer.run != .running or now_ms < timer.ms) return null;
    const duration_ms = durationMs(option, timer.phase);
    const tally: Tally = switch (timer.phase) {
        .task => .{ .tasks = 1, .focus_ms = duration_ms },
        .short_break => .{ .break_ms = duration_ms },
        .long_break => .{ .long_breaks = 1, .break_ms = duration_ms },
        .idle => unreachable,
    };
    const after: Timer = switch (option.on_phase_end) {
        .wait => .{ .phase = timer.phase, .run = .waiting, .tasks_in_cycle = timer.tasks_in_cycle },
        .start_next => next(timer, option, now_ms, .running),
    };
    return .{ .timer = after, .tally = tally };
}

/// Starts the waiting next phase when phases now start on their own.
pub fn applyPhaseEnd(timer: Timer, option: Option, now_ms: i64) ?Change {
    if (timer.run != .waiting or option.on_phase_end != .start_next) return null;
    return .{ .timer = next(timer, option, now_ms, .running) };
}

/// Moves a running task's end later by `by_ms`, for the time a reminder
/// blocked input (`on_alert = pause`).
pub fn extend(timer: Timer, by_ms: u64) ?Change {
    if (timer.phase != .task or timer.run != .running) return null;
    var out = timer;
    out.ms = msFrom(timer.ms, by_ms);
    return .{ .timer = out };
}

/// What the display shows of the timer at one moment: built from a `Timer`
/// and a time by `view`, never changed on its own.
pub const State = struct {
    option: Option,
    remaining_ms: u64 = 0,
    phase: Phase = .idle,
    paused: bool = false,
    waiting: bool = false,
    /// Resets after each long break; drives the long-break trigger.
    tasks_in_cycle: u8 = 0,

    pub const idle: State = .{
        .phase = .idle,
        .option = .default,
    };

    pub fn view(timer: Timer, option: Option, now_ms: i64) State {
        return .{
            .option = option,
            .remaining_ms = timer.remainingMs(now_ms),
            .phase = timer.phase,
            .paused = timer.phase != .idle and timer.run == .paused,
            .waiting = timer.run == .waiting,
            .tasks_in_cycle = timer.tasks_in_cycle,
        };
    }

    /// Milliseconds until the next tick boundary (for waitEventsTimeout).
    pub fn msUntilTick(self: *const State) u64 {
        if (self.phase == .idle or self.paused or self.waiting) return max_u64;
        // Update title every second
        return (self.remaining_ms % 1000) + 1;
    }

    pub fn getDuration(self: *const State, phase: Phase) u64 {
        return durationMs(self.option, phase);
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

        // Resolve display in milliseconds
        const display_ms: u64 = if (self.waiting)
            self.getDuration(effective_phase)
        else blk: {
            const phase_ms = self.getDuration(self.phase);
            break :blk if (option.timer == .countup) phase_ms - self.remaining_ms else self.remaining_ms;
        };

        const is_transition = display_ms == self.remaining_ms;

        // Resolve icon, paused overrides only when not waiting (waiting implies paused=false)
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

        if (time_fields.contains(.millisecond)) {
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
