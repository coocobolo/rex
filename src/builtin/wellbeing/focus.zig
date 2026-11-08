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
    timer_mode: TimerMode = .countdown,
    transition_mode: TransitionMode = .manual,
    mute_notifications_in_task: bool = true,
    rotate_break_prompts: bool = true,
    lock_input_on_break: bool = false,
    show_break_animation: bool = true,
    auto_pause_on_alert: bool = true,

    pub const TimerMode = enum { countup, countdown };
    pub const TransitionMode = enum { auto, manual };
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

pub const State = struct {
    option: Option,
    remaining_ms: u64 = 0,
    phase: Phase = .idle,
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

        // Resolve display in milliseconds
        const display_ms: u64 = if (self.waiting)
            self.getDuration(effective_phase)
        else blk: {
            const phase_ms = self.getDuration(self.phase);
            break :blk if (option.timer_mode == .countup) phase_ms - self.remaining_ms else self.remaining_ms;
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
