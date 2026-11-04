//! 24-bit RGB color representation and conversion routines.

const std = @import("std");
const x11_colors = @import("x11.zig");

pub const Rgb = @This();

r: u8,
g: u8,
b: u8,

comptime {
    std.debug.assert(@sizeOf(Rgb) == 3);
}

pub const white: Rgb = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF };
pub const black: Rgb = .{ .r = 0x00, .g = 0x00, .b = 0x00 };
pub const gray: Rgb = .{ .r = 0x2F, .g = 0x2F, .b = 0x2F };

pub inline fn toArray(self: Rgb) [3]u8 {
    return .{ self.r, self.g, self.b };
}

pub inline fn toRgba(self: Rgb, a: u8) [4]f32 {
    return .{
        @floatFromInt(self.r),
        @floatFromInt(self.g),
        @floatFromInt(self.b),
        @floatFromInt(a),
    };
}

pub inline fn toNormalizedRgba(self: Rgb, a: f32) [4]f32 {
    const scale: f32 = 1.0 / 255.0;

    return .{
        @as(f32, @floatFromInt(self.r)) * scale,
        @as(f32, @floatFromInt(self.g)) * scale,
        @as(f32, @floatFromInt(self.b)) * scale,
        a,
    };
}

/// Pack to the u32 key format used by Palette entries:
/// 0xRRGGBB_FF (tag byte 0xFF in the low byte is not used here,
/// the palette tag is in the high byte of the 32-bit key).
pub fn toU32(self: Rgb) u32 {
    return (@as(u32, self.r) << 24) | (@as(u32, self.g) << 16) | (@as(u32, self.b) << 8) | 0xFF;
}

pub fn fromU32(v: u32) Rgb {
    return .{
        .r = @intCast((v >> 24) & 0xFF),
        .g = @intCast((v >> 16) & 0xFF),
        .b = @intCast((v >> 8) & 0xFF),
    };
}

/// Parse an X11/CSS color specification into an RGB triple.
///
/// Supported formats:
///   Named X11 colors case insensitive
///   #RGB        (4-bit per channel, expanded to 8-bit)
///   #RRGGBB     (8-bit per channel)
///   #RRRRGGGGBBBB (16-bit per channel, truncated to 8-bit)
///   rgb:R/G/B   (X11 format, 1-4 hex digits per channel)
///
/// Returns null on parse failure.
pub fn parseSpec(spec: []const u8) ?Rgb {
    if (spec.len == 0) return null;

    // #RGB / #RRGGBB / #RRRRGGGGBBBB
    if (spec[0] == '#') {
        const hex = spec[1..];
        switch (hex.len) {
            3 => {
                const r4 = std.fmt.parseInt(u8, hex[0..1], 16) catch return null;
                const g4 = std.fmt.parseInt(u8, hex[1..2], 16) catch return null;
                const b4 = std.fmt.parseInt(u8, hex[2..3], 16) catch return null;
                return .{ .r = r4 * 17, .g = g4 * 17, .b = b4 * 17 };
            },
            6 => {
                const r = std.fmt.parseInt(u8, hex[0..2], 16) catch return null;
                const g = std.fmt.parseInt(u8, hex[2..4], 16) catch return null;
                const b = std.fmt.parseInt(u8, hex[4..6], 16) catch return null;
                return .{ .r = r, .g = g, .b = b };
            },
            12 => {
                // 16-bit per channel, take the high byte
                const r = std.fmt.parseInt(u16, hex[0..4], 16) catch return null;
                const g = std.fmt.parseInt(u16, hex[4..8], 16) catch return null;
                const b = std.fmt.parseInt(u16, hex[8..12], 16) catch return null;
                return .{ .r = @intCast(r >> 8), .g = @intCast(g >> 8), .b = @intCast(b >> 8) };
            },
            else => return null,
        }
    }

    // rgb:R/G/B  (X11 format, 1-4 hex digits per channel)
    if (std.mem.startsWith(u8, spec, "rgb:")) {
        const rgb = spec[4..];
        var it = std.mem.splitScalar(u8, rgb, '/');
        const rs = it.next() orelse return null;
        const gs = it.next() orelse return null;
        const bs = it.next() orelse return null;
        if (it.next() != null) return null; // too many components
        const r = parseX11Channel(rs) orelse return null;
        const g = parseX11Channel(gs) orelse return null;
        const b = parseX11Channel(bs) orelse return null;
        return .{ .r = r, .g = g, .b = b };
    }

    // Named X11 colors (case-insensitive)
    // Longest X11 color name is ~20 chars; 64 is a safe upper bound.
    if (spec.len <= 64) {
        if (x11_colors.fromName(spec)) |c| return Rgb{ .r = c.r, .g = c.g, .b = c.b };
    }

    return null;
}

/// Parse a 1-4 hex digit X11 channel value, normalised to 8-bit.
fn parseX11Channel(s: []const u8) ?u8 {
    if (s.len == 0 or s.len > 4) return null;

    const v = std.fmt.parseInt(u16, s, 16) catch return null;
    // Scale to 8-bit: 1 digit (0-F) times 17, 2 digits (00-FF) as-is,
    // 3 digits (000-FFF) shifted right by 4, 4 digits (0000-FFFF) by 8
    return switch (s.len) {
        1 => @intCast(v * 17),
        2 => @intCast(v),
        3 => @intCast(v >> 4),
        4 => @intCast(v >> 8),
        else => unreachable,
    };
}

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
