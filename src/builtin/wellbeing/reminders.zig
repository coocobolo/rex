const std = @import("std");
const storage = @import("storage.zig");
const secondsCeil = @import("tracker.zig").secondsCeil;

pub const AnimationKind = enum {
    none,
    pulse_dim,
    grayscale_wave,
    warm_glow,
};

pub const EyesightOption = struct {
    enabled: bool = true,
    interval_ms: u64 = 20 * std.time.ms_per_min,
    duration_ms: u64 = 20 * std.time.ms_per_s,
    lock_input: bool = false,
    show_animation: bool = true,
    animation: AnimationKind = .pulse_dim,
    prompt: []const u8 = "Look at an object 20 feet away for 20 seconds.",
};

pub const MovementOption = struct {
    enabled: bool = true,
    interval_ms: u64 = 50 * std.time.ms_per_min,
    duration_ms: u64 = 60 * std.time.ms_per_s,
    lock_input: bool = false,
    show_animation: bool = true,
    animation: AnimationKind = .grayscale_wave,
    prompt: []const u8 = "Time to stand up, stretch your back, and move.",
};

pub const RoutinesOption = struct {
    hydration_interval_ms: ?u64 = 45 * std.time.ms_per_min,
    hydration_prompt: []const u8 = "Stay hydrated: drink some fresh water.",
    posture_interval_ms: ?u64 = 30 * std.time.ms_per_min,
    posture_prompt: []const u8 = "Check posture: roll shoulders back and align neck.",
    custom_name: ?[]const u8 = null,
    custom_interval_ms: ?u64 = null,
    custom_prompt: ?[]const u8 = null,
    lock_input: bool = false,
    show_animation: bool = false,
    animation: AnimationKind = .warm_glow,
};

pub const AlertKind = enum {
    none,
    eyesight,
    movement,
    hydration,
    posture,
    custom,
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
    routines_opt: RoutinesOption,

    eyesight_timer_s: u32 = 0,
    eyesight_active_s: u32 = 0,

    movement_timer_s: u32 = 0,
    movement_active_s: u32 = 0,

    hydration_timer_s: u32 = 0,
    posture_timer_s: u32 = 0,
    custom_timer_s: u32 = 0,

    break_prompt_idx: usize = 0,
    current_alert: Alert = .{},

    pub fn init(
        eyesight: EyesightOption,
        movement: MovementOption,
        routines: RoutinesOption,
    ) RemindersEngine {
        return .{
            .eyesight_opt = eyesight,
            .movement_opt = movement,
            .routines_opt = routines,
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
        if (self.routines_opt.hydration_interval_ms != null) self.hydration_timer_s +|= dt_s;
        if (self.routines_opt.posture_interval_ms != null) self.posture_timer_s +|= dt_s;
        if (self.routines_opt.custom_interval_ms != null) self.custom_timer_s +|= dt_s;

        var triggered: ?Alert = null;

        if (self.routines_opt.custom_interval_ms) |interval| {
            if (self.custom_timer_s >= secondsCeil(interval)) {
                self.custom_timer_s = 0;
                triggered = .{
                    .kind = .custom,
                    .prompt = self.routines_opt.custom_prompt orelse "Custom routine reminder",
                    .remaining_s = 15,
                    .lock_input = self.routines_opt.lock_input,
                    .show_animation = self.routines_opt.show_animation,
                    .animation = self.routines_opt.animation,
                };
            }
        }

        if (self.routines_opt.posture_interval_ms) |interval| {
            if (self.posture_timer_s >= secondsCeil(interval)) {
                self.posture_timer_s = 0;
                triggered = .{
                    .kind = .posture,
                    .prompt = self.routines_opt.posture_prompt,
                    .remaining_s = 10,
                    .lock_input = self.routines_opt.lock_input,
                    .show_animation = self.routines_opt.show_animation,
                    .animation = self.routines_opt.animation,
                };
            }
        }

        if (self.routines_opt.hydration_interval_ms) |interval| {
            if (self.hydration_timer_s >= secondsCeil(interval)) {
                self.hydration_timer_s = 0;
                today.hydration_count +|= 1;
                triggered = .{
                    .kind = .hydration,
                    .prompt = self.routines_opt.hydration_prompt,
                    .remaining_s = 15,
                    .lock_input = self.routines_opt.lock_input,
                    .show_animation = self.routines_opt.show_animation,
                    .animation = self.routines_opt.animation,
                };
            }
        }

        if (self.eyesight_opt.enabled) {
            const threshold = secondsCeil(self.eyesight_opt.interval_ms);
            if (self.eyesight_timer_s >= threshold) {
                self.eyesight_timer_s = 0;
                today.eyesight_breaks +|= 1;
                triggered = .{
                    .kind = .eyesight,
                    .prompt = self.eyesight_opt.prompt,
                    .remaining_s = remainingSeconds(self.eyesight_opt.duration_ms),
                    .lock_input = self.eyesight_opt.lock_input,
                    .show_animation = self.eyesight_opt.show_animation,
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
                    .lock_input = self.movement_opt.lock_input,
                    .show_animation = self.movement_opt.show_animation,
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
