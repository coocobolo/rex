const std = @import("std");

pub const Flags = packed struct(u8) {};

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

pub const WinddownOption = struct {
    enabled: bool = true,
    /// The window starts at `start` and ends at `end`; it crosses midnight
    /// when `end` is earlier than `start`.
    start: TimeOfDay = .{ .hour = 21, .minute = 0 },
    end: TimeOfDay = .{ .hour = 7, .minute = 0 },
    warmth_factor: f32 = 0.85,
    mute_audio_bell: bool = true,
    prompt: []const u8 = "Wind-down time. Time to wrap up work for today 🌙",
};

pub const WinddownEngine = struct {
    option: WinddownOption,
    is_active: bool = false,
    alerted_today: bool = false,

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
        const color_tint: [3]f32 = if (in_window) .{
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
