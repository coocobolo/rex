const std = @import("std");

const Rgb = @import("Rgb.zig");
const fromU32 = Rgb.fromU32;
const parseSpec = Rgb.parseSpec;
const toU32 = Rgb.toU32;
const white = Rgb.white;

test "Rgb: conversions and packing" {
    const c = Rgb{ .r = 0x12, .g = 0x34, .b = 0x56 };
    try std.testing.expectEqual([3]u8{ 0x12, 0x34, 0x56 }, c.toArray());
    try std.testing.expectEqual(c, Rgb.fromU32(c.toU32()));

    const rgba = c.toRgba(128);
    try std.testing.expectEqual([4]f32{ 0x12, 0x34, 0x56, 128 }, rgba);

    const norm = (Rgb{ .r = 255, .g = 0, .b = 128 }).toNormalizedRgba(1.0);
    try std.testing.expectApproxEqAbs(1.0, norm[0], 0.001);
    try std.testing.expectApproxEqAbs(0.0, norm[1], 0.001);
    try std.testing.expectApproxEqAbs(128.0 / 255.0, norm[2], 0.001);
    try std.testing.expectApproxEqAbs(1.0, norm[3], 0.001);
}

test "Rgb: parseSpec" {
    try std.testing.expectEqual(Rgb{ .r = 0xFF, .g = 0x00, .b = 0xFF }, Rgb.parseSpec("#f0f").?);
    try std.testing.expectEqual(Rgb{ .r = 0x12, .g = 0x34, .b = 0x56 }, Rgb.parseSpec("#123456").?);
    try std.testing.expectEqual(Rgb{ .r = 0x12, .g = 0x56, .b = 0x9a }, Rgb.parseSpec("#123456789abc").?);
    try std.testing.expectEqual(Rgb{ .r = 0x12, .g = 0x34, .b = 0x56 }, Rgb.parseSpec("rgb:12/34/56").?);
    try std.testing.expectEqual(Rgb{ .r = 0xFF, .g = 0xFF, .b = 0xFF }, Rgb.parseSpec("white").?);
    try std.testing.expectEqual(@as(?Rgb, null), Rgb.parseSpec(""));
    try std.testing.expectEqual(@as(?Rgb, null), Rgb.parseSpec("#12345"));
    try std.testing.expectEqual(@as(?Rgb, null), Rgb.parseSpec("rgb:12/34"));
    try std.testing.expectEqual(@as(?Rgb, null), Rgb.parseSpec("rgb:12/34/56/78"));
    try std.testing.expectEqual(@as(?Rgb, null), Rgb.parseSpec("invalid_color_xyz"));
}

test "Rgb: lerp interpolation" {
    const c1 = Rgb{ .r = 0, .g = 100, .b = 200 };
    const c2 = Rgb{ .r = 100, .g = 200, .b = 0 };

    const mid = Rgb.lerp(c1, c2, 0.5);
    try std.testing.expectEqual(@as(u8, 50), mid.r);
    try std.testing.expectEqual(@as(u8, 150), mid.g);
    try std.testing.expectEqual(@as(u8, 100), mid.b);

    const start = Rgb.lerp(c1, c2, 0.0);
    try std.testing.expectEqual(c1, start);

    const end = Rgb.lerp(c1, c2, 1.0);
    try std.testing.expectEqual(c2, end);
}
