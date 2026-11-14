//! What the user sets for wellbeing (`[wellbeing]` and its subsections):
//! screen time, eyesight and movement reminders, the focus timer and
//! wind-down. Plain data that imports nothing but std, so anything that
//! reads the config can import it without the wellbeing code. The
//! wellbeing modules' option types are these.

const std = @import("std");

pub const Wellbeing = struct {
    enabled: bool = true,

    privacy: struct {
        state_dir: ?[]const u8 = null,
        state_filename: []const u8 = "wellbeing.bin",
    } = .{},

    screen_time: TrackerOption = .{},
    eyesight: EyesightOption = .{},
    movement: MovementOption = .{},
    focus: Focus = .default,
    winddown: WinddownOption = .{},

    // Domain-specific UI behaviors
    lock_screen: struct {
        enabled: bool = true,
        dim_strength: f32 = 0.50,
    } = .{},

    dashboard: struct {
        modal_enabled: bool = true,
        /// How the wellbeing window draws the focus timer's progress.
        timer_chart: TimerChart = .bar,
        /// How the wellbeing window draws the share of each program.
        program_chart: ProgramChart = .bar,
    } = .{},

    pub const default: Wellbeing = .{};
    pub const TimerChart = enum { bar, ring };
    pub const ProgramChart = enum { bar, donut };
};

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

pub const AnimationKind = enum {
    none,
    pulse_dim,
    grayscale_wave,
    warm_glow,
};

pub const ReminderAction = enum {
    /// Block terminal input while the reminder is shown.
    lock_input,
};

pub const EyesightOption = struct {
    enabled: bool = true,
    interval_ms: u64 = 20 * std.time.ms_per_min,
    duration_ms: u64 = 20 * std.time.ms_per_s,
    during_reminder: std.EnumSet(ReminderAction) = .empty,
    /// `none`: no animation.
    animation: AnimationKind = .pulse_dim,
    prompt: []const u8 = "Look at an object 20 feet away for 20 seconds.",
};

pub const MovementOption = struct {
    enabled: bool = true,
    interval_ms: u64 = 50 * std.time.ms_per_min,
    duration_ms: u64 = 60 * std.time.ms_per_s,
    during_reminder: std.EnumSet(ReminderAction) = .empty,
    /// `none`: no animation.
    animation: AnimationKind = .grayscale_wave,
    prompt: []const u8 = "Time to stand up, stretch your back, and move.",
};

pub const Focus = struct {
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

    pub const default: Focus = .{};
};

/// A time of day on the 24-hour clock.
pub const TimeOfDay = struct {
    /// 0 to 23.
    hour: u5,
    /// 0 to 59.
    minute: u6,

    /// Minutes since midnight.
    pub fn minutes(self: TimeOfDay) u11 {
        std.debug.assert(self.hour < 24 and self.minute < 60);
        return @as(u11, self.hour) * 60 + self.minute;
    }
};

pub const WindowAction = enum {
    /// Warm the screen colors by `warmth_factor`.
    warm_colors,
    mute_bell,
};

pub const WinddownOption = struct {
    /// Off by default: it tints the screen and mutes the bell every evening,
    /// which only someone who asked for it expects.
    enabled: bool = false,
    /// The window starts at `start` and ends at `end`; it crosses midnight
    /// when `end` is earlier than `start`.
    start: TimeOfDay = .{ .hour = 21, .minute = 0 },
    end: TimeOfDay = .{ .hour = 7, .minute = 0 },
    during_window: std.EnumSet(WindowAction) = .initMany(&.{ .warm_colors, .mute_bell }),
    /// How warm `warm_colors` makes the screen, from 0 to 1.
    warmth_factor: f32 = 0.85,
    prompt: []const u8 = "Wind-down time. Time to wrap up work for today 🌙",
};
