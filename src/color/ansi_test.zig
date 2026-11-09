const std = @import("std");

const ansi = @import("ansi.zig");
const indexed = ansi.indexed;
const indexedRgb = ansi.indexedRgb;
const indexed_colors = ansi.indexed_colors;
const xterm256 = ansi.xterm256;

const Rgb = @import("Rgb.zig");

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
