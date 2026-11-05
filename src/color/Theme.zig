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

pub const default_accent: Rgb = .{ .r = 138, .g = 110, .b = 240 };

comptime {
    std.debug.assert(@sizeOf(Theme) == 64);
}

pub const graphite: Theme = .{
    .background = .black,
    .foreground = .white,
    .selection_background = .black,
    .selection_foreground = .white,
    .ansi = graphite_ansi,
    .accent = default_accent,
    .flags = 0,
};

pub const graphite_ansi: [16]Rgb = .{
    .{ .r = 0x26, .g = 0x26, .b = 0x26 }, // 0 black
    .{ .r = 0x64, .g = 0x64, .b = 0x64 }, // 1 red
    .{ .r = 0x8E, .g = 0x8E, .b = 0x8E }, // 2 green
    .{ .r = 0xB9, .g = 0xB9, .b = 0xB9 }, // 3 yellow
    .{ .r = 0x98, .g = 0x98, .b = 0x98 }, // 4 blue
    .{ .r = 0x74, .g = 0x74, .b = 0x74 }, // 5 magenta
    .{ .r = 0x58, .g = 0x58, .b = 0x58 }, // 6 cyan
    .{ .r = 0x7A, .g = 0x7A, .b = 0x7A }, // 7 white
    .{ .r = 0x26, .g = 0x26, .b = 0x26 }, // 8 bright black
    .{ .r = 0x64, .g = 0x64, .b = 0x64 }, // 9 bright red
    .{ .r = 0x8E, .g = 0x8E, .b = 0x8E }, // 10 bright green
    .{ .r = 0xB9, .g = 0xB9, .b = 0xB9 }, // 11 bright yellow
    .{ .r = 0x98, .g = 0x98, .b = 0x98 }, // 12 bright blue
    .{ .r = 0x74, .g = 0x74, .b = 0x74 }, // 13 bright magenta
    .{ .r = 0x58, .g = 0x58, .b = 0x58 }, // 14 bright cyan
    .{ .r = 0x7A, .g = 0x7A, .b = 0x7A }, // 15 bright white
};

test "Theme: graphite preset sanity" {
    try std.testing.expectEqual(16, graphite.ansi.len);
    try std.testing.expectEqual(Rgb.white, graphite.foreground);
    try std.testing.expectEqual(Rgb.black, graphite.background);
}
