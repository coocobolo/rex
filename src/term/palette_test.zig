const std = @import("std");
const testing = std.testing;

const Palette = @import("Palette.zig").Palette;
const Style = @import("Style.zig");
const Color = @import("cell.zig").Color;
const Rgb = Color.Rgb;
const ansi = @import("../color/ansi.zig");
const Theme = @import("../color/Theme.zig");

fn key(color: Color) Style.Key {
    return Style.encode(color);
}

test "resolveKey: default resolves to the default for its target" {
    var p: Palette = .empty;
    p.setTheme(test_theme);
    try testing.expectEqual(test_theme.foreground.toArray(), p.resolveKeyRgb(Style.default_key, .foreground));
    try testing.expectEqual(test_theme.background.toArray(), p.resolveKeyRgb(Style.default_key, .background));
    try testing.expectEqual(test_theme.background.toU32(), p.resolveKey(Style.default_key, .background));
}

test "resolveKey: indexed colors resolve through the theme and the xterm table" {
    var p: Palette = .empty;
    p.setTheme(test_theme);
    try testing.expectEqual(test_theme.ansi[1].toArray(), p.resolveKeyRgb(key(.{ .indexed = 1 }), .foreground));
    for ([_]u8{ 16, 100, 231, 255 }) |n| {
        try testing.expectEqual(Rgb.fromU32(ansi.indexed(n)).toArray(), p.resolveKeyRgb(key(.{ .indexed = n }), .foreground));
    }
}

test "resolveKey: RGB resolves to itself, as RGB and as RGBA" {
    const p: Palette = .empty;
    const c: Color = .{ .rgb = .{ .r = 1, .g = 2, .b = 3 } };
    try testing.expectEqual([3]u8{ 1, 2, 3 }, p.resolveKeyRgb(key(c), .background));
    try testing.expectEqual(@as(u32, 0x010203FF), p.resolveKey(key(c), .foreground));
}

test "reset: restores the indexed colors and drops OSC 10/11" {
    var p: Palette = .empty;
    p.setIndexed(1, .{ .r = 1, .g = 1, .b = 1 });
    p.setIndexed(200, .{ .r = 1, .g = 1, .b = 1 });
    p.set(.foreground, .{ .r = 3, .g = 3, .b = 3 });
    p.reset();
    try testing.expectEqual(Rgb.fromU32(ansi.indexed(1)), p.getIndexed(1));
    try testing.expectEqual(Rgb.fromU32(ansi.indexed(200)), p.getIndexed(200));
    try testing.expectEqual(p.builtin_foreground, p.get(.foreground));
}

test "setIndexed: index 255 is stored and read back" {
    var p: Palette = .empty;
    const c: Rgb = .{ .r = 1, .g = 2, .b = 3 };
    p.setIndexed(255, c);
    try testing.expectEqual(c, p.getIndexed(255));
}

test "setIndexed: an override of 16-255 applies to text drawn after it" {
    var p: Palette = .empty;
    const c: Rgb = .{ .r = 4, .g = 5, .b = 6 };
    for ([_]u8{ 16, 100, 254, 255 }) |n| {
        p.setIndexed(n, c);
        try testing.expectEqual(c.toArray(), p.resolveKeyRgb(key(.{ .indexed = n }), .foreground));
        try testing.expectEqual(c.toU32(), p.resolveKey(key(.{ .indexed = n }), .background));
    }
}

test "setIndexed: an override of 0-15 applies to text already drawn" {
    var p: Palette = .empty;
    const k = key(.{ .indexed = 3 });
    const c: Rgb = .{ .r = 7, .g = 8, .b = 9 };
    p.setIndexed(3, c);
    try testing.expectEqual(c.toArray(), p.resolveKeyRgb(k, .foreground));
}

test "resetIndexed: restores 16-255 to the xterm 256-color value" {
    var p: Palette = .empty;
    for ([_]u8{ 16, 200, 255 }) |n| {
        p.setIndexed(n, .{ .r = 1, .g = 1, .b = 1 });
        p.resetIndexed(n);
        try testing.expectEqual(Rgb.fromU32(ansi.indexed(n)), p.getIndexed(n));
    }
}

test "resetAllIndexed: restores all 256 indices" {
    var p: Palette = .empty;
    p.setTheme(test_theme);
    for (0..256) |n| p.setIndexed(@intCast(n), .{ .r = 1, .g = 1, .b = 1 });
    p.resetAllIndexed();
    try testing.expectEqual(test_theme.ansi[1], p.getIndexed(1));
    for (16..256) |n| {
        try testing.expectEqual(Rgb.fromU32(ansi.indexed(@intCast(n))), p.getIndexed(@intCast(n)));
    }
}

test "reset: keeps the theme" {
    var p: Palette = .empty;
    p.setTheme(test_theme);
    p.setIndexed(1, .{ .r = 1, .g = 1, .b = 1 });
    p.set(.background, .{ .r = 2, .g = 2, .b = 2 });
    p.reset();
    try testing.expectEqual(test_theme.background, p.get(.background));
    try testing.expectEqual(test_theme.foreground, p.get(.foreground));
    try testing.expectEqual(test_theme.ansi[1], p.getIndexed(1));
}

/// A theme whose colors differ from every built-in default.
const test_theme: Theme = blk: {
    var t = Theme.graphite;
    t.background = .{ .r = 0x10, .g = 0x20, .b = 0x30 };
    t.foreground = .{ .r = 0xE0, .g = 0xD0, .b = 0xC0 };
    for (&t.ansi, 0..) |*c, n| c.* = .{ .r = @intCast(n), .g = 0x42, .b = 0x24 };
    break :blk t;
};
