const std = @import("std");
const wellbeing_config = @import("../../config/wellbeing.zig");
const storage = @import("storage.zig");
const secondsCeil = @import("tracker.zig").secondsCeil;

pub const AnimationKind = wellbeing_config.AnimationKind;

pub const ReminderAction = wellbeing_config.ReminderAction;

pub const EyesightOption = wellbeing_config.EyesightOption;

pub const MovementOption = wellbeing_config.MovementOption;

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

/// Fires the eyesight and movement reminders on the person's active time
/// across all windows (`PersistentData.activeClock`). Each reminder's due
/// point lives in the shared state, so whichever window is focused fires
/// it, once; idle time pauses reminders because the clock stops.
pub const RemindersEngine = struct {
    eyesight_opt: EyesightOption,
    movement_opt: MovementOption,
    break_prompt_idx: usize = 0,

    pub fn init(eyesight: EyesightOption, movement: MovementOption) RemindersEngine {
        return .{
            .eyesight_opt = eyesight,
            .movement_opt = movement,
        };
    }

    /// Fires at most one due reminder, movement first, and counts its break
    /// in `data.today`. A reminder that is also due waits for a later call,
    /// so the caller decides when another alert may follow. Call it only
    /// from the focused window.
    pub fn tick(self: *RemindersEngine, data: *storage.PersistentData) ?Alert {
        const clock = data.activeClock();
        if (self.movement_opt.enabled and advance(&data.movement_due_s, clock, self.movement_opt.interval_ms)) {
            data.today.movement_breaks +|= 1;
            return .{
                .kind = .movement,
                .prompt = self.movement_opt.prompt,
                .remaining_s = remainingSeconds(self.movement_opt.duration_ms),
                .lock_input = self.movement_opt.during_reminder.contains(.lock_input),
                .show_animation = self.movement_opt.animation != .none,
                .animation = self.movement_opt.animation,
            };
        }
        if (self.eyesight_opt.enabled and advance(&data.eyesight_due_s, clock, self.eyesight_opt.interval_ms)) {
            data.today.eyesight_breaks +|= 1;
            return .{
                .kind = .eyesight,
                .prompt = self.eyesight_opt.prompt,
                .remaining_s = remainingSeconds(self.eyesight_opt.duration_ms),
                .lock_input = self.eyesight_opt.during_reminder.contains(.lock_input),
                .show_animation = self.eyesight_opt.animation != .none,
                .animation = self.eyesight_opt.animation,
            };
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

/// Moves `due` to the latest point of its interval grid at or before
/// `clock` and returns whether that fires a reminder. A due point of 0 means
/// not started: the grid starts at `clock` without firing, so a reminder
/// never fires on its first sight of the clock (a new or upgraded state
/// file, a purge). After several missed intervals (reminder turned off,
/// clock moved by a merge) it fires once. The grid makes windows that fire
/// the same reminder agree on `due`, which merges count once.
fn advance(due: *u64, clock: u64, interval_ms: u64) bool {
    if (due.* == 0) {
        due.* = clock;
        return false;
    }
    const interval_s = @max(secondsCeil(interval_ms), 1);
    if (clock < due.* +| interval_s) return false;
    due.* += (clock - due.*) / interval_s * interval_s;
    return true;
}
