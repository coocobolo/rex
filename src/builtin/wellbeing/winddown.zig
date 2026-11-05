const std = @import("std");

pub const WinddownOption = struct {
    enabled: bool = true,
    start_hour: u8 = 21,
    start_minute: u8 = 0,
    end_hour: u8 = 7,
    end_minute: u8 = 0,
    warmth_factor: f32 = 0.85,
    mute_audio_bell: bool = true,
    reduced_bell_volume: u8 = 20,
    prompt: []const u8 = "Wind-down time. Time to wrap up work for today 🌙",
};

pub const WinddownEngine = struct {
    option: WinddownOption,
    is_active: bool = false,
    alerted_today: bool = false,

    pub fn init(option: WinddownOption) WinddownEngine {
        return .{ .option = option };
    }

    pub fn update(self: *WinddownEngine, now_s: i64) struct {
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

        // Compute local time of day in minutes
        // (Using standard day modulo 86400; accounts for UTC/local timestamp)
        const day_seconds = @mod(now_s, std.time.s_per_day);
        const cur_minute = @divFloor(day_seconds, 60);

        const start_min = @as(i64, self.option.start_hour) * 60 + self.option.start_minute;
        const end_min = @as(i64, self.option.end_hour) * 60 + self.option.end_minute;

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
