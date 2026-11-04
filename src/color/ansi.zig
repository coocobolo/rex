//! Standard ANSI 16 colors and xterm 256-color palette tables.

const std = @import("std");
const Rgb = @import("Rgb.zig");

/// xterm default ANSI 16 colors. Used only to seed indexed_colors[].
/// At runtime, palette entries 1–16 are overridden by applyTheme().
pub const ansi_table = [16]u32{
    0x000000FF, // 0  black
    0xAA0000FF, // 1  red
    0x00AA00FF, // 2  green
    0xAA5500FF, // 3  brown/yellow
    0x0000AAFF, // 4  blue
    0xAA00AAFF, // 5  magenta
    0x00AAAAFF, // 6  cyan
    0xAAAAAAFF, // 7  light grey
    0x555555FF, // 8  dark grey
    0xFF5555FF, // 9  bright red
    0x55FF55FF, // 10 bright green
    0xFFFF55FF, // 11 bright yellow
    0x5555FFFF, // 12 bright blue
    0xFF55FFFF, // 13 bright magenta
    0x55FFFFFF, // 14 bright cyan
    0xFFFFFFFF, // 15 white
};

pub inline fn pack(r: u8, g: u8, b: u8, a: u8) u32 {
    return (@as(u32, r) << 24) | (@as(u32, g) << 16) | (@as(u32, b) << 8) | a;
}

pub const indexed_colors: [256]u32 = blk: {
    var t: [256]u32 = undefined;
    for (0..16) |i| t[i] = ansi_table[i];
    for (16..232) |i| {
        const n = i - 16;
        const r = n / 36;
        const g = (n % 36) / 6;
        const b = n % 6;
        const levels = [6]u8{ 0, 95, 135, 175, 215, 255 };
        t[i] = pack(levels[r], levels[g], levels[b], 0xFF);
    }
    for (232..256) |i| {
        const gray: u8 = 8 + @as(u8, @intCast(i - 232)) * 10;
        t[i] = pack(gray, gray, gray, 0xFF);
    }
    break :blk t;
};

/// Comptime xterm 256-color table as `Rgb` values.
pub const xterm256: [256]Rgb = blk: {
    var t: [256]Rgb = undefined;
    for (0..256) |i| {
        const u = indexed_colors[i];
        t[i] = .{
            .r = @intCast((u >> 24) & 0xFF),
            .g = @intCast((u >> 16) & 0xFF),
            .b = @intCast((u >> 8) & 0xFF),
        };
    }
    break :blk t;
};

pub fn indexed(index: u8) u32 {
    return indexed_colors[index];
}

pub fn indexedRgb(index: u8) Rgb {
    return xterm256[index];
}

test "ansi: table indexing and RGB conversion" {
    try std.testing.expectEqual(256, indexed_colors.len);
    try std.testing.expectEqual(256, xterm256.len);

    // Verify ANSI color 0 (black) and 15 (white)
    try std.testing.expectEqual(Rgb{ .r = 0x00, .g = 0x00, .b = 0x00 }, indexedRgb(0));
    try std.testing.expectEqual(Rgb{ .r = 0xFF, .g = 0xFF, .b = 0xFF }, indexedRgb(15));

    // Verify grayscale ramp entries 232 and 255
    try std.testing.expectEqual(Rgb{ .r = 8, .g = 8, .b = 8 }, indexedRgb(232));
    try std.testing.expectEqual(Rgb{ .r = 238, .g = 238, .b = 238 }, indexedRgb(255));

    // Consistency between indexed(i) and indexedRgb(i)
    for (0..256) |i| {
        const u = indexed(@intCast(i));
        const rgb = indexedRgb(@intCast(i));
        try std.testing.expectEqual(rgb.r, @as(u8, @intCast((u >> 24) & 0xFF)));
        try std.testing.expectEqual(rgb.g, @as(u8, @intCast((u >> 16) & 0xFF)));
        try std.testing.expectEqual(rgb.b, @as(u8, @intCast((u >> 8) & 0xFF)));
    }
}
