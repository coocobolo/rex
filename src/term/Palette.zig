const std = @import("std");

const Color = @import("cell.zig").Color;
const Rgb = Color.Rgb;
const ansi = @import("../color/ansi.zig");
const Theme = @import("../color/Theme.zig");

/// Per-screen color palette: what a `Style.Key` resolves to.
///
/// The 256 xterm colors (`indexed`, the theme for 0-15, OSC 4 overrides on
/// top) and the default foreground and background (theme, OSC 10/11).
/// Cells no longer hold palette slots: they hold style IDs whose keys are
/// either a default, an index into `indexed`, or an RGB value (ADR 0005),
/// so an OSC 4 change applies to every cell drawn with that index.
pub const Palette = @This();

const Style = @import("Style.zig");

/// RGB of each xterm color index: the theme for 0-15, the xterm
/// 256-color cube and grays above, then any OSC 4 override.
// Hot, read when rendering an indexed color.
indexed: [256]Rgb,

/// What OSC 104 restores `indexed` to: the theme and xterm defaults.
// Warm, accessed on OSC 104.
indexed_default: [256]Rgb,

// Colds

foreground: ?Rgb,
background: ?Rgb,

builtin_foreground: Rgb = .white,
builtin_background: Rgb = .black,
builtin_selection_foreground: Rgb = .white,
builtin_selection_background: Rgb = .black,

const xterm_indexed: [256]Rgb = ansi.xterm256;

/// The xterm colors and the built-in defaults, no theme.
pub const empty: Palette = .{
    .background = null,
    .foreground = null,
    .builtin_background = .black,
    .builtin_foreground = .white,
    .indexed = xterm_indexed,
    .indexed_default = xterm_indexed,
};

pub const GroundTarget = enum { foreground, background };

/// Resets the palette to its initial state. The theme (builtin colors
/// and `indexed_default`) survives; OSC overrides do not.
pub fn reset(self: *Palette) void {
    self.foreground = null;
    self.background = null;
    self.indexed = self.indexed_default;
}

/// Applies a theme. Called once at startup; OSC 4/10/11 can still
/// override on top.
pub fn setTheme(self: *Palette, theme: Theme) void {
    self.builtin_background = theme.background;
    self.builtin_foreground = theme.foreground;
    self.builtin_selection_background = theme.selection_background;
    self.builtin_selection_foreground = theme.selection_foreground;
    self.indexed_default[0..16].* = theme.ansi;
    self.indexed[0..16].* = theme.ansi;
}

/// Resolves an encoded color (`Style.Key`) to RGBA packed as 0xRRGGBBAA.
/// `.default` resolves to the default for `target`, indexed colors
/// through `indexed`.
pub fn resolveKey(self: *const Palette, key: Style.Key, comptime target: GroundTarget) u32 {
    return switch (key >> 24) {
        0x00 => blk: {
            const c = self.get(target);
            break :blk (@as(u32, c.r) << 24) | (@as(u32, c.g) << 16) | (@as(u32, c.b) << 8) | 0xFF;
        },
        0x01 => self.indexed[key & 0xFF].toU32(),
        0x02 => ((key & 0x00FF_FFFF) << 8) | 0xFF, // shift RGB bits up, append alpha
        else => unreachable,
    };
}

/// `resolveKey` as an RGB triple.
pub fn resolveKeyRgb(self: *const Palette, key: Style.Key, comptime target: GroundTarget) [3]u8 {
    return switch (key >> 24) {
        0x00 => blk: {
            const c = self.get(target);
            break :blk .{ c.r, c.g, c.b };
        },
        0x01 => self.indexed[key & 0xFF].toArray(),
        0x02 => .{ @truncate(key >> 16), @truncate(key >> 8), @truncate(key) },
        else => unreachable,
    };
}

/// Overrides xterm color `index` (0-255) with `rgb` (OSC 4), for cells
/// already drawn with it and new ones.
pub fn setIndexed(self: *Palette, index: u8, rgb: Rgb) void {
    self.indexed[index] = rgb;
}

/// Returns the current RGB of xterm color `index` (0-255).
pub fn getIndexed(self: *const Palette, index: u8) Rgb {
    return self.indexed[index];
}

/// Restores xterm color `index` to its theme or xterm default (OSC 104 ; n).
pub fn resetIndexed(self: *Palette, index: u8) void {
    self.indexed[index] = self.indexed_default[index];
}

/// Restores all 256 xterm colors (OSC 104 with no argument).
pub fn resetAllIndexed(self: *Palette) void {
    self.indexed = self.indexed_default;
}

/// Return the current default target as RGB.
pub fn get(self: *const Palette, comptime target: GroundTarget) Rgb {
    return switch (target) {
        .background => self.background orelse self.builtin_background,
        .foreground => self.foreground orelse self.builtin_foreground,
    };
}

/// Set the current default target color (OSC 10/11).
pub fn set(self: *Palette, comptime target: GroundTarget, color: ?Rgb) void {
    return switch (target) {
        .background => self.background = color,
        .foreground => self.foreground = color,
    };
}
