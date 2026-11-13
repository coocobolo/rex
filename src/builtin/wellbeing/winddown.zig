const std = @import("std");
const wellbeing_config = @import("../../config/wellbeing.zig");

pub const TimeOfDay = wellbeing_config.TimeOfDay;

pub const WindowAction = wellbeing_config.WindowAction;

pub const WinddownOption = wellbeing_config.WinddownOption;

pub const WinddownEngine = struct {
    option: WinddownOption,
    is_active: bool = false,

    pub fn init(option: WinddownOption) WinddownEngine {
        return .{ .option = option };
    }

    /// `local_s` is local wall-clock seconds since the epoch (see `Clock`
    /// in localtime.zig), so the window follows the user's time zone.
    pub fn update(self: *WinddownEngine, local_s: i64) struct {
        active: bool,
        just_started: bool,
        color_tint: [3]f32,
    } {
        if (!self.option.enabled) {
            self.is_active = false;
            return .{
                .active = false,
                .just_started = false,
                .color_tint = .{ 1.0, 1.0, 1.0 },
            };
        }

        const day_seconds = @mod(local_s, std.time.s_per_day);
        const cur_minute = @divFloor(day_seconds, 60);

        const start_min: i64 = self.option.start.minutes();
        const end_min: i64 = self.option.end.minutes();

        const in_window = if (start_min <= end_min)
            (cur_minute >= start_min and cur_minute < end_min)
        else
            (cur_minute >= start_min or cur_minute < end_min);

        const was_active = self.is_active;
        self.is_active = in_window;

        var just_started = false;
        if (in_window and !was_active) {
            just_started = true;
        }

        // Color temperature calculation
        // Neutral: (1.0, 1.0, 1.0)
        // Warm Amber: Red stays 1.0, Green ~0.90, Blue attenuated proportional to warmth
        const warmth = std.math.clamp(self.option.warmth_factor, 0.0, 1.0);
        const color_tint: [3]f32 = if (in_window and self.option.during_window.contains(.warm_colors)) .{
            1.0,
            1.0 - (0.12 * warmth),
            1.0 - (0.35 * warmth),
        } else .{
            1.0,
            1.0,
            1.0,
        };

        return .{
            .active = in_window,
            .just_started = just_started,
            .color_tint = color_tint,
        };
    }
};
