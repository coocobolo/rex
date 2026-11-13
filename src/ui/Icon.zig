const std = @import("std");
const wc = @import("../unicode/wcwidth.zig");
const overlay_config = @import("../config/overlay.zig");

pub const IconStyle = overlay_config.IconStyle;

pub const Glyphs = struct {
    lock: ?[]const u8 = null,
    unlock: ?[]const u8 = null,
    coffee: ?[]const u8 = null,
    warning: ?[]const u8 = null,
    error_icon: ?[]const u8 = null,
    success: ?[]const u8 = null,
    info: ?[]const u8 = null,
    pause: ?[]const u8 = null,
    play: ?[]const u8 = null,
    check: ?[]const u8 = null,
    clock: ?[]const u8 = null,
    settings: ?[]const u8 = null,
    eye: ?[]const u8 = null,
    walk: ?[]const u8 = null,
    water: ?[]const u8 = null,
    posture: ?[]const u8 = null,
};

pub const Option = struct {
    style: IconStyle = .auto,
    custom: Glyphs = .{},
};

/// Centralized semantic icon registry.
/// Components reference semantic names rather than hardcoded glyphs or arbitrary emojis.
pub const IconId = enum {
    lock,
    unlock,
    coffee,
    warning,
    error_icon,
    success,
    info,
    pause,
    play,
    check,
    clock,
    settings,
    eye,
    walk,
    water,
    posture,
};

/// Resolves the effective IconStyle when `.auto` is requested, defaulting deterministically to `.unicode`.
pub fn resolveStyle(configured: IconStyle) IconStyle {
    return if (configured == .auto) .unicode else configured;
}

/// Returns the glyph string for the given semantic icon and rendering mode.
/// Glyphs are chosen according to the resolved mode, selecting Nerd Fonts v3 symbols,
/// clean standard Unicode geometric and technical characters, or minimal ASCII fallbacks.
pub fn getGlyph(id: IconId, style: IconStyle) []const u8 {
    const resolved = resolveStyle(style);
    return switch (resolved) {
        .nerd_font => switch (id) {
            .lock => "\u{f023}", // nf-fa-lock (U+F023)
            .unlock => "\u{f09c}", // nf-fa-unlock (U+F09C)
            .coffee => "\u{f0f4}", // nf-fa-coffee (U+F0F4)
            .warning => "\u{ea6c}", // nf-cod-warning (U+EA6C)
            .error_icon => "\u{ea87}", // nf-cod-error (U+EA87)
            .success => "\u{eab2}", // nf-cod-check (U+EAB2)
            .info => "\u{ea74}", // nf-cod-info (U+EA74)
            .pause => "\u{f04c}", // nf-fa-pause (U+F04C)
            .play => "\u{f04b}", // nf-fa-play (U+F04B)
            .check => "\u{eab2}", // nf-cod-check (U+EAB2)
            .clock => "\u{ea85}", // nf-cod-clock (U+EA85)
            .settings => "\u{ea7d}", // nf-cod-settings (U+EA7D)
            .eye => "\u{f06e}", // nf-fa-eye (U+F06E)
            .walk => "\u{f183}", // nf-fa-male (U+F183)
            .water => "\u{f043}", // nf-fa-tint (U+F043)
            .posture => "\u{ea7d}", // nf-cod-organization (U+EA7D)
        },
        .unicode => switch (id) {
            .lock => "■", // U+25A0 BLACK SQUARE
            .unlock => "□", // U+25A1 WHITE SQUARE
            .coffee => "~", // Clean rest indicator
            .warning => "▲", // U+25B2 BLACK UP-POINTING TRIANGLE
            .error_icon => "✕", // U+2715 MULTIPLICATION X
            .success => "✓", // U+2713 CHECK MARK
            .info => "ℹ", // U+2139 INFORMATION SOURCE
            .pause => "⏸", // U+23F8 DOUBLE VERTICAL BAR
            .play => "▶", // U+25B6 BLACK RIGHT-POINTING TRIANGLE
            .check => "✓", // U+2713 CHECK MARK
            .clock => "◷", // U+25F7 WHITE CIRCLE WITH UPPER RIGHT QUADRANT
            .settings => "⚙", // U+2699 GEAR
            .eye => "◎", // U+25CE BULLSEYE
            .walk => "»", // U+00BB RIGHT-POINTING DOUBLE ANGLE QUOTATION MARK
            .water => "◇", // U+25C7 WHITE DIAMOND
            .posture => "□", // U+25A1 WHITE SQUARE
        },
        .ascii => switch (id) {
            .lock => "[#]",
            .unlock => "[ ]",
            .coffee => "[~]",
            .warning => "[!]",
            .error_icon => "[x]",
            .success => "[v]",
            .info => "[i]",
            .pause => "||",
            .play => ">",
            .check => "[v]",
            .clock => "(o)",
            .settings => "[*]",
            .eye => "(o)",
            .walk => ">>",
            .water => "~",
            .posture => "[_]",
        },
        .auto => unreachable,
    };
}

/// Retrieves a user-customized glyph override for the specified semantic icon ID if defined.
pub fn getCustomGlyph(id: IconId, custom: Glyphs) ?[]const u8 {
    return switch (id) {
        .lock => custom.lock,
        .unlock => custom.unlock,
        .coffee => custom.coffee,
        .warning => custom.warning,
        .error_icon => custom.error_icon,
        .success => custom.success,
        .info => custom.info,
        .pause => custom.pause,
        .play => custom.play,
        .check => custom.check,
        .clock => custom.clock,
        .settings => custom.settings,
        .eye => custom.eye,
        .walk => custom.walk,
        .water => custom.water,
        .posture => custom.posture,
    };
}

/// Resolves the effective glyph string for the given semantic icon and user configuration options,
/// honoring custom glyph overrides before falling back to the configured or auto-detected icon style.
pub fn getGlyphWithOption(id: IconId, opt: Option) []const u8 {
    if (getCustomGlyph(id, opt.custom)) |custom| return custom;
    return getGlyph(id, opt.style);
}

/// Measures the display column width of a glyph sequence in terminal cells,
/// using the specified ambiguous-width policy and cluster-awareness.
pub fn glyphWidthPolicy(glyph: []const u8, ambiguous: wc.AmbiguousWidth) u16 {
    var iter = (std.unicode.Utf8View.init(glyph) catch return @intCast(glyph.len)).iterator();
    var w: u16 = 0;
    var prev_cp: ?u21 = null;

    while (iter.nextCodepoint()) |cp| {
        // VS16 emoji promotion: promotes previous narrow cell by +1
        if (cp == 0xFE0F) {
            if (prev_cp) |p| {
                if (wc.wcwidth(p, ambiguous) == .narrow) w += 1;
            }
            prev_cp = cp;
            continue;
        }
        // Enclosing keycap promotion: promotes previous narrow cell by +1
        if (cp == 0x20E3) {
            if (prev_cp) |p| {
                if (wc.wcwidth(p, ambiguous) == .narrow) w += 1;
            }
            prev_cp = cp;
            continue;
        }
        // VS15 text demotion: demotes previous wide cell by -1
        if (cp == 0xFE0E) {
            if (prev_cp) |p| {
                if (wc.wcwidth(p, ambiguous) == .wide and w >= 2) w -= 1;
            }
            prev_cp = cp;
            continue;
        }
        // Regional indicator flag pair: second RI completes the 2-cell flag
        if (cp >= 0x1F1E6 and cp <= 0x1F1FF) {
            if (prev_cp) |p| {
                if (p >= 0x1F1E6 and p <= 0x1F1FF) {
                    w += 1;
                    prev_cp = null;
                    continue;
                }
            }
        }

        const cw = wc.wcwidth(cp, ambiguous);
        w += switch (cw) {
            .wide => 2,
            .narrow => 1,
            .zero, .control => 0,
        };
        prev_cp = cp;
    }
    return w;
}

/// Measures the display column width of a glyph sequence in terminal cells (narrow ambiguous default).
pub fn glyphWidth(glyph: []const u8) u16 {
    return glyphWidthPolicy(glyph, .narrow);
}
