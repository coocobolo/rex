const std = @import("std");
const storage = @import("storage.zig");
const secondsCeil = @import("tracker.zig").secondsCeil;

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

pub const AlertKind = enum {
    none,
    eyesight,
    movement,
    healthy_break,
    screen_limit,
};

pub const Alert = struct {
    kind: AlertKind = .none,
    prompt: []const u8 = "",
    remaining_s: u32 = 0,
    lock_input: bool = false,
    show_animation: bool = false,
    animation: AnimationKind = .none,
};

pub const break_prompts: []const []const u8 = &.{
    "Roll your shoulders backward and release tension in your neck.",
    "Hydrate: drink a cool glass of fresh water.",
    "Box breathing: Inhale 4s, Hold 4s, Exhale 4s, Hold 4s.",
    "Rest your palms, interlace fingers, and gently stretch your wrists.",
    "Blink rapidly for 5 seconds, then close your eyes and relax your eyelids.",
    "Stand up, reach both hands toward the ceiling, and take a deep breath.",
};

pub const RemindersEngine = struct {
    eyesight_opt: EyesightOption,
    movement_opt: MovementOption,

    eyesight_timer_s: u32 = 0,
    eyesight_active_s: u32 = 0,

    movement_timer_s: u32 = 0,
    movement_active_s: u32 = 0,

    break_prompt_idx: usize = 0,
    current_alert: Alert = .{},

    pub fn init(eyesight: EyesightOption, movement: MovementOption) RemindersEngine {
        return .{
            .eyesight_opt = eyesight,
            .movement_opt = movement,
        };
    }

    pub fn tick(
        self: *RemindersEngine,
        dt_s: u32,
        is_idle: bool,
        today: *storage.DayRecord,
    ) ?Alert {
        // Decrement active alert if present
        if (self.current_alert.remaining_s > 0) {
            self.current_alert.remaining_s -|= dt_s;
            if (self.current_alert.remaining_s == 0) {
                self.current_alert.kind = .none;
            }
        }

        // Reminders only accumulate when user is actively using the terminal
        if (is_idle) {
            // Paused while idle: no timer advances and nothing triggers.
            return null;
        }

        // Advance all enabled timers first
        if (self.eyesight_opt.enabled) self.eyesight_timer_s +|= dt_s;
        if (self.movement_opt.enabled) self.movement_timer_s +|= dt_s;

        var triggered: ?Alert = null;

        if (self.eyesight_opt.enabled) {
            const threshold = secondsCeil(self.eyesight_opt.interval_ms);
            if (self.eyesight_timer_s >= threshold) {
                self.eyesight_timer_s = 0;
                today.eyesight_breaks +|= 1;
                triggered = .{
                    .kind = .eyesight,
                    .prompt = self.eyesight_opt.prompt,
                    .remaining_s = remainingSeconds(self.eyesight_opt.duration_ms),
                    .lock_input = self.eyesight_opt.during_reminder.contains(.lock_input),
                    .show_animation = self.eyesight_opt.animation != .none,
                    .animation = self.eyesight_opt.animation,
                };
            }
        }

        if (self.movement_opt.enabled) {
            const threshold = secondsCeil(self.movement_opt.interval_ms);
            if (self.movement_timer_s >= threshold) {
                self.movement_timer_s = 0;
                today.movement_breaks +|= 1;
                triggered = .{
                    .kind = .movement,
                    .prompt = self.movement_opt.prompt,
                    .remaining_s = remainingSeconds(self.movement_opt.duration_ms),
                    .lock_input = self.movement_opt.during_reminder.contains(.lock_input),
                    .show_animation = self.movement_opt.animation != .none,
                    .animation = self.movement_opt.animation,
                };
            }
        }

        if (triggered) |alert| {
            self.current_alert = alert;
            return alert;
        }

        return null;
    }

    pub fn nextBreakPrompt(self: *RemindersEngine) []const u8 {
        const prompt = break_prompts[self.break_prompt_idx % break_prompts.len];
        self.break_prompt_idx += 1;
        return prompt;
    }
};

/// Countdown length in whole seconds for an alert lasting `ms`, saturated to
/// the countdown's type.
fn remainingSeconds(ms: u64) u32 {
    return std.math.cast(u32, secondsCeil(ms)) orelse std.math.maxInt(u32);
}
