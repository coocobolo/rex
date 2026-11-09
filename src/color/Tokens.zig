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

    // /// Dark theme tokens (near-black background, elevated charcoal cards)
    // pub const dark: Tokens = .{
    //     .bg = .{ 13, 13, 13, 245 }, // #0D0D0D
    //     .card = .{ 37, 37, 37, 255 }, // #252525
    //     .card_opaque = .{ 37, 37, 37 },
    //     .border = .{ 72, 72, 72 }, // #484848
    //     .border_subtle = .{ 56, 56, 56 }, // #383838
    //     .primary = .{ 230, 230, 230 }, // #E6E6E6
    //     .secondary = .{ 146, 146, 146 }, // #929292
    //     .muted = .{ 104, 104, 104 }, // #686868
    //     .accent = .{ 138, 110, 240 }, // #8A6EF0 (Vibrant indigo/violet prompt accent)
    //     .healthy = .{ 69, 201, 149 }, // #45C995
    //     .warning = .{ 229, 173, 82 }, // #E5AD52
    //     .critical = .{ 228, 91, 91 }, // #E45B5B
    //     .info = .{ 71, 137, 232 }, // #4789E8
    // };
    //
    // /// Light theme tokens (paper surface, crisp white cards, high-contrast dark text)
    // pub const light: Tokens = .{
    //     .bg = .{ 246, 247, 249, 255 }, // #F6F7F9
    //     .card = .{ 255, 255, 255, 255 }, // #FFFFFF
    //     .card_opaque = .{ 255, 255, 255 },
    //     .border = .{ 218, 221, 227 }, // #DADDE3
    //     .border_subtle = .{ 233, 235, 239 }, // #E9EBEF
    //     .primary = .{ 35, 38, 45 }, // #23262D
    //     .secondary = .{ 100, 105, 115 }, // #646973
    //     .muted = .{ 145, 150, 160 }, // #9196A0
    //     .accent = .{ 109, 40, 217 }, // #6D28D9 (Deep violet for WCAG AA contrast on light surface)
    //     .healthy = .{ 43, 145, 111 }, // #2B916F
    //     .warning = .{ 175, 123, 42 }, // #AF7B2A
    //     .critical = .{ 196, 75, 75 }, // #C44B4B
    //     .info = .{ 64, 113, 190 }, // #4071BE
    // };

    /// Dark theme Obsidian (warm charcoal, restrained contrast)
    pub const dark: Tokens = .{
        .bg = .{ 18, 18, 19, 245 }, // #121213
        .card = .{ 10, 10, 10, 255 }, // #1E1E20
        .card_opaque = .{ 10, 10, 10 },
        .border = .{ 65, 65, 67 }, // #414143
        .border_subtle = .{ 45, 45, 47 }, // #2D2D2F

        .primary = .{ 232, 230, 225 }, // #E8E6E1
        .secondary = .{ 157, 155, 150 }, // #9D9B96
        .muted = .{ 112, 110, 106 }, // #706E6A

        .accent = .{ 138, 110, 240 }, // #8A6EF0 (Vibrant indigo/violet prompt accent)

        .healthy = .{ 123, 165, 139 }, // #7BA58B
        .warning = .{ 190, 158, 111 }, // #BE9E6F
        .critical = .{ 190, 119, 115 }, // #BE7773
        .info = .{ 130, 151, 172 }, // #8297AC
    };

    /// Light theme Porcelain (soft ivory, clean surfaces, warm typography)
    pub const light: Tokens = .{
        .bg = .{ 247, 246, 243, 255 }, // #F7F6F3
        .card = .{ 255, 255, 253, 255 }, // #FFFFFD
        .card_opaque = .{ 255, 255, 253 },
        .border = .{ 218, 216, 209 }, // #DAD8D1
        .border_subtle = .{ 234, 232, 226 }, // #EAE8E2

        .primary = .{ 40, 40, 39 }, // #282827
        .secondary = .{ 105, 103, 97 }, // #696761
        .muted = .{ 148, 145, 137 }, // #949189

        .accent = .{ 119, 112, 96 }, // #777060 (Warm stone)

        .healthy = .{ 65, 126, 94 }, // #417E5E
        .warning = .{ 153, 111, 52 }, // #996F34
        .critical = .{ 169, 83, 77 }, // #A9534D
        .info = .{ 76, 111, 145 }, // #4C6F91
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

        // Synchronize semantic states from theme ANSI palette if chromatic (avoid graying out semantic UI)
        if (isChromatic(theme.ansi[1])) t.critical = theme.ansi[1].toArray();
        if (isChromatic(theme.ansi[2])) t.healthy = theme.ansi[2].toArray();
        if (isChromatic(theme.ansi[3])) t.warning = theme.ansi[3].toArray();
        if (isChromatic(theme.ansi[4])) t.info = theme.ansi[4].toArray();

        // Synchronize interactive accent if chromatic or explicitly configured
        if (!theme.accent.eql(Theme.default_accent) or isChromatic(theme.accent)) {
            t.accent = theme.accent.toArray();
        }

        return t;
    }

    fn isChromatic(rgb: Rgb) bool {
        const diff_rg = if (rgb.r > rgb.g) rgb.r - rgb.g else rgb.g - rgb.r;
        const diff_gb = if (rgb.g > rgb.b) rgb.g - rgb.b else rgb.b - rgb.g;
        return (diff_rg > 15 or diff_gb > 15);
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
