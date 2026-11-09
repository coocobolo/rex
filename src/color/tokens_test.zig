const std = @import("std");

const Tokens = @import("Tokens.zig").Tokens;

const Theme = @import("Theme.zig");
const Rgb = @import("Rgb.zig");

test "Tokens: dark and light presets sanity" {
    const dark = Tokens.dark;
    const light = Tokens.light;

    try std.testing.expectEqual(@as(u8, 10), dark.card[0]);
    try std.testing.expectEqual(@as(u8, 255), light.card[0]);

    // Rec. 601 luma tests
    const black = Rgb{ .r = 0, .g = 0, .b = 0 };
    const white = Rgb{ .r = 255, .g = 255, .b = 255 };

    const from_black = Tokens.fromRgb(black);
    const from_white = Tokens.fromRgb(white);

    try std.testing.expectEqual(dark.primary, from_black.primary);
    try std.testing.expectEqual(light.primary, from_white.primary);
}

test "Tokens: fromTheme synchronization and accent override" {
    var theme = Theme.graphite;
    theme.foreground = .{ .r = 240, .g = 240, .b = 240 };
    theme.ansi[1] = .{ .r = 250, .g = 50, .b = 50 }; // red
    theme.ansi[2] = .{ .r = 50, .g = 250, .b = 50 }; // green
    theme.accent = .{ .r = 56, .g = 189, .b = 248 }; // sky blue

    const tokens = Tokens.fromTheme(theme);
    try std.testing.expectEqual([3]u8{ 240, 240, 240 }, tokens.primary);
    try std.testing.expectEqual([3]u8{ 250, 50, 50 }, tokens.critical);
    try std.testing.expectEqual([3]u8{ 50, 250, 50 }, tokens.healthy);
    try std.testing.expectEqual([3]u8{ 56, 189, 248 }, tokens.accent);

    // Custom tokens override
    const from_custom = Tokens.fromThemeWithOverride(theme, Tokens.light);
    try std.testing.expectEqual(Tokens.light.card, from_custom.card);
}
