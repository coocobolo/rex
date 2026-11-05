//! Design system tokens for Rex terminal UI surfaces, cards, and typography.
//! Provides flat, zero-allocation styling primitives with dark and light mode presets,
//! automatic Rec. 601 luminance detection, and general interactive accent colors.

const std = @import("std");
const Theme = @import("Theme.zig");
const Rgb = @import("Rgb.zig");

pub const Tokens = struct {
    // Surfaces
    bg: [4]u8,
    card: [4]u8,
    card_opaque: [3]u8,

    // Borders
    border: [3]u8,
    border_subtle: [3]u8,

    // Typography hierarchy
    primary: [3]u8,
    secondary: [3]u8,
    muted: [3]u8,

    // General UI Accent (interactive highlights, prompt markers `>`, focus borders)
    accent: [3]u8,

    // Semantic accents
    healthy: [3]u8,
    warning: [3]u8,
    critical: [3]u8,
    info: [3]u8,

    // General UI semantic aliases
    pub inline fn success(self: Tokens) [3]u8 {
        return self.healthy;
    }

    pub inline fn err(self: Tokens) [3]u8 {
        return self.critical;
    }

    /// Dark theme tokens (near-black background, elevated charcoal cards)
    pub const dark: Tokens = .{
        .bg = .{ 13, 13, 13, 245 }, // #0D0D0D
        .card = .{ 37, 37, 37, 255 }, // #252525
        .card_opaque = .{ 37, 37, 37 },
        .border = .{ 72, 72, 72 }, // #484848
        .border_subtle = .{ 56, 56, 56 }, // #383838
        .primary = .{ 230, 230, 230 }, // #E6E6E6
        .secondary = .{ 146, 146, 146 }, // #929292
        .muted = .{ 104, 104, 104 }, // #686868
        .accent = .{ 138, 110, 240 }, // #8A6EF0 (Vibrant indigo/violet prompt accent)
        .healthy = .{ 69, 201, 149 }, // #45C995
        .warning = .{ 229, 173, 82 }, // #E5AD52
        .critical = .{ 228, 91, 91 }, // #E45B5B
        .info = .{ 71, 137, 232 }, // #4789E8
    };

    /// Light theme tokens (paper surface, crisp white cards, high-contrast dark text)
    pub const light: Tokens = .{
        .bg = .{ 246, 247, 249, 255 }, // #F6F7F9
        .card = .{ 255, 255, 255, 255 }, // #FFFFFF
        .card_opaque = .{ 255, 255, 255 },
        .border = .{ 218, 221, 227 }, // #DADDE3
        .border_subtle = .{ 233, 235, 239 }, // #E9EBEF
        .primary = .{ 35, 38, 45 }, // #23262D
        .secondary = .{ 100, 105, 115 }, // #646973
        .muted = .{ 145, 150, 160 }, // #9196A0
        .accent = .{ 109, 40, 217 }, // #6D28D9 (Deep violet for WCAG AA contrast on light surface)
        .healthy = .{ 43, 145, 111 }, // #2B916F
        .warning = .{ 175, 123, 42 }, // #AF7B2A
        .critical = .{ 196, 75, 75 }, // #C44B4B
        .info = .{ 64, 113, 190 }, // #4071BE
    };

    pub const default = dark;

    /// Derives tokens from the active terminal Theme.
    /// Synchronizes primary text, semantic state colors (healthy, warning, critical, info),
    /// surface elevation, and interactive accent from the theme palette.
    pub fn fromTheme(theme: Theme) Tokens {
        return fromThemeWithOverride(theme, null);
    }

    /// Derives tokens from the active terminal Theme with an optional custom tokens override.
    pub fn fromThemeWithOverride(theme: Theme, override: ?Tokens) Tokens {
        if (override) |custom| return custom;

        var t = fromRgb(theme.background);

        // Synchronize typography hierarchy from theme foreground
        t.primary = theme.foreground.toArray();
        t.secondary = Rgb.lerp(theme.foreground, theme.background, 0.35).toArray();
        t.muted = Rgb.lerp(theme.foreground, theme.background, 0.60).toArray();

        // Synchronize semantic states from theme ANSI palette
        t.critical = theme.ansi[1].toArray();
        t.healthy = theme.ansi[2].toArray();
        t.warning = theme.ansi[3].toArray();
        t.info = theme.ansi[4].toArray();

        // Synchronize interactive accent
        t.accent = theme.accent.toArray();

        return t;
    }

    /// Derives tokens from any RGB background color using Rec. 601 perceived luminance.
    pub fn fromRgb(bg_rgb: Rgb) Tokens {
        const luma = (@as(u32, bg_rgb.r) * 299 + @as(u32, bg_rgb.g) * 587 + @as(u32, bg_rgb.b) * 114) / 1000;
        return if (luma > 128) light else dark;
    }

    /// Derives tokens from a runtime Palette snapshot (handles OSC 10/11 background overrides).
    pub fn fromPalette(palette: anytype) Tokens {
        return fromRgb(palette.get(.background));
    }

    /// Converts 0-255 [3]u8 RGB + u8 Alpha into normalized 0.0-1.0 [4]f32 RGBA.
    pub inline fn toF32Rgba(rgb: [3]u8, a: u8) [4]f32 {
        const scale: f32 = 1.0 / 255.0;
        return .{
            @as(f32, @floatFromInt(rgb[0])) * scale,
            @as(f32, @floatFromInt(rgb[1])) * scale,
            @as(f32, @floatFromInt(rgb[2])) * scale,
            @as(f32, @floatFromInt(a)) * scale,
        };
    }
};

test "Tokens: dark and light presets sanity" {
    const dark = Tokens.dark;
    const light = Tokens.light;

    try std.testing.expectEqual(@as(u8, 37), dark.card[0]);
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
