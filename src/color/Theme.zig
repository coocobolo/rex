//! Terminal color themes and palette presets (ANSI 16 colors, fg, bg, selection).

const std = @import("std");
const Rgb = @import("Rgb.zig");

pub const Theme = @This();

/// Basic ANSI 16 colors.
ansi: [16]Rgb,
selection_foreground: Rgb,
selection_background: Rgb,
background: Rgb,
foreground: Rgb,
/// Interactive accent color for UI highlights, prompt markers, and focus rings.
accent: Rgb = default_accent,
/// Reserved flags and attributes keeping Theme exactly 64 bytes (1 CPU cache line).
flags: u8 = 0,

pub const default_accent: Rgb = .{ .r = 163, .g = 157, .b = 143 };

comptime {
    std.debug.assert(@sizeOf(Theme) == 64);
}

pub const default: Theme = .{
    .background = .black,
    .foreground = .white,
    .selection_background = .black,
    .selection_foreground = .white,
    .ansi = default_ansi,
    .accent = default_accent,
    .flags = 0,
};

pub const default_ansi: [16]Rgb = .{
    .{ .r = 0x1A, .g = 0x1A, .b = 0x1A }, // 0 black
    .{ .r = 0xBE, .g = 0x77, .b = 0x73 }, // 1 red
    .{ .r = 0x7B, .g = 0xA5, .b = 0x8B }, // 2 green
    .{ .r = 0xBE, .g = 0x9E, .b = 0x6F }, // 3 yellow
    .{ .r = 0x82, .g = 0x97, .b = 0xAC }, // 4 blue
    .{ .r = 0xA0, .g = 0x7E, .b = 0x98 }, // 5 magenta
    .{ .r = 0x5E, .g = 0x8F, .b = 0x8A }, // 6 cyan
    .{ .r = 0xE8, .g = 0xE6, .b = 0xE1 }, // 7 white
    .{ .r = 0x70, .g = 0x6E, .b = 0x6A }, // 8 bright black
    .{ .r = 0xD8, .g = 0xAD, .b = 0xAB }, // 9 bright red
    .{ .r = 0xAF, .g = 0xC9, .b = 0xB9 }, // 10 bright green
    .{ .r = 0xD8, .g = 0xC4, .b = 0xA8 }, // 11 bright yellow
    .{ .r = 0xA9, .g = 0xC0, .b = 0xD6 }, // 12 bright blue
    .{ .r = 0xC6, .g = 0xB1, .b = 0xC1 }, // 13 bright magenta
    .{ .r = 0x9E, .g = 0xBB, .b = 0xB8 }, // 14 bright cyan
    .{ .r = 0xFF, .g = 0xFF, .b = 0xFF }, // 15 bright white
};
