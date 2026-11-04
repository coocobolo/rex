const std = @import("std");
const testing = std.testing;

const Palette = @import("Palette.zig").Palette;
const Color = @import("cell.zig").Color;
const Rgb = Color.Rgb;
const ansi = @import("../color/ansi.zig");
const Theme = @import("Theme.zig");

test "init: index 0 is default" {
    const p: Palette = .empty;
    try testing.expectEqual(Color.default, p.decode(0));
}

test "init: ANSI colors at indices 1-16" {
    const p: Palette = .empty;
    for (0..16) |n| {
        const idx: u8 = @intCast(n);
        try testing.expectEqual(Color{ .indexed = idx }, p.decode(idx + 1));
    }
}

test "init: xterm 256-color pre-populated at indices 17–255" {
    const p: Palette = .empty;
    // xterm color 16 at slot 17, xterm color 254 at slot 255
    for (16..255) |n| {
        const idx: u8 = @intCast(n);
        try testing.expectEqual(Color{ .indexed = idx }, p.decode(idx + 1));
    }
}

test "init: next starts at dynamic_base" {
    const p: Palette = .empty;
    try testing.expectEqual(Palette.dynamic_base, p.next);
}

test "intern: .default always returns 0" {
    var p: Palette = .empty;
    try testing.expectEqual(0, p.intern(.default));
    try testing.expectEqual(0, p.intern(.default)); // idempotent
}

test "intern: .indexed 0 returns 1 (ansi_base + 0)" {
    var p: Palette = .empty;
    try testing.expectEqual(1, p.intern(.{ .indexed = 0 }));
}

test "intern: .indexed 15 returns 16 (ansi_base + 15)" {
    var p: Palette = .empty;
    try testing.expectEqual(16, p.intern(.{ .indexed = 15 }));
}

test "intern: .indexed 16 returns pre-populated slot 17" {
    var p: Palette = .empty;
    // Slot 17 was pre-populated with xterm color 16 by init().
    try testing.expectEqual(17, p.intern(.{ .indexed = 16 }));
}

test "intern: .indexed 254 returns pre-populated slot 255" {
    var p: Palette = .empty;
    try testing.expectEqual(255, p.intern(.{ .indexed = 254 }));
}

test "intern: .indexed 16 falls bback to internDynamic after slot evicted" {
    var p: Palette = .empty;
    // evict slot 17 by interning an rgb ccolor (next = dynamic base = 17)
    _ = p.intern(.{ .rgb = .{ .r = 1, .g = 2, .b = 3 } });
    // Slot 17 now holds the RGB color; fast-path check fails.
    // internDynamic should find or re-allocate a slot for .indexed = 16
    const idx = p.intern(.{ .indexed = 16 });
    try testing.expectEqual(Color{ .indexed = 16 }, p.decode(idx));
}

test "intern: .rgb allocates a dynamic slots" {
    var p: Palette = .empty;
    const color: Color = .{ .rgb = .{ .r = 100, .g = 150, .b = 200 } };
    const idx = p.intern(color);
    try testing.expect(idx >= Palette.dynamic_base);
    try testing.expectEqual(color, p.decode(idx));
}

test "intern: intern same .rgb twice returns same index" {
    var p: Palette = .empty;
    const color: Color = .{ .rgb = .{ .r = 100, .g = 150, .b = 200 } };
    const idx1 = p.intern(color);
    const idx2 = p.intern(color);
    try testing.expectEqual(idx1, idx2);
}

test "intern: intern .indexed 255 hits slow path" {
    var p: Palette = .empty;
    // .indexed = 255 is not in the pre-populated range (16-254), so it
    // always goes through internDynamic.
    const idx = p.intern(.{ .indexed = 255 });
    try testing.expect(idx >= Palette.dynamic_base);
    try testing.expectEqual(Color{ .indexed = 255 }, p.decode(idx));
}

test "intern: first .rgb intern evics slot dynamic_base" {
    var p: Palette = .empty;
    // After init(), next = dynamic base = 17.
    // First .rgb intern: scan finds no match, evics slot 17.
    const color: Color = .{ .rgb = .{ .r = 255, .g = 0, .b = 0 } };
    const idx = p.intern(color);

    try testing.expectEqual(Palette.dynamic_base, idx);
    try testing.expectEqual(color, p.decode(Palette.dynamic_base));
    try testing.expectEqual(Palette.dynamic_base + 1, p.next);
}

test "intern: advances next after each new allocation" {
    var p: Palette = .empty;
    const before = p.next;

    _ = p.intern(.{ .rgb = .{ .r = 10, .g = 20, .b = 30 } });
    try testing.expectEqual(before + 1, p.next);

    _ = p.intern(.{ .rgb = .{ .r = 11, .g = 21, .b = 31 } });
    try testing.expectEqual(before + 2, p.next);
}

test "intern: round-robin wraps next from 255 back to dynamic_base" {
    var p: Palette = .empty;
    // Intern 238 distinct RGB colors: next goes from 17 to 255.
    for (0..238) |i| {
        _ = p.intern(.{ .rgb = .{ .r = 0, .g = 0, .b = @intCast(i) } });
    }

    // one more, evicts slot 255, wraps next back to dynacmic base.
    _ = p.intern(.{ .rgb = .{ .r = 0, .g = 1, .b = 0 } });
    try testing.expectEqual(Palette.dynamic_base, p.next);
}

test "intern: eviction overwrites oldest slot" {
    var p: Palette = .empty;
    // Fill all 239 dynamic slots with distinct RGB colors.
    // after, next has wrapped back to dynacmic_base.
    for (0..239) |i| {
        _ = p.intern(.{ .rgb = .{ .r = 0, .g = 0, .b = @intCast(i) } });
    }
    try testing.expectEqual(Palette.dynamic_base, p.next);

    // Next intern evicts slot dynamic_base (the oldest).
    const new_color = Color{ .rgb = .{ .r = 200, .g = 200, .b = 200 } };
    const idx = p.intern(new_color);
    try testing.expectEqual(Palette.dynamic_base, idx);
    try testing.expectEqual(new_color, p.decode(Palette.dynamic_base));
}

test "get(intern(.default)) == .default" {
    var p: Palette = .empty;
    try testing.expectEqual(Color.default, p.decode(p.intern(.default)));
}

test "get(intern(.indexed 16-254)) round-trips (pre-populated)" {
    var p: Palette = .empty;
    for (16..255) |n| {
        const color = Color{ .indexed = @intCast(n) };
        try testing.expectEqual(color, p.decode(p.intern(color)));
    }
}

test "get(intern(.rgb)) round-trips" {
    var p: Palette = .empty;
    const color = Color{ .rgb = .{ .r = 12, .g = 34, .b = 56 } };
    try testing.expectEqual(color, p.decode(p.intern(color)));
}

test "reset: restores default index" {
    var p: Palette = .empty;
    p.entries[0] = 0xDEAD_BEEF;
    p.reset();
    try testing.expectEqual(Color.default, p.decode(0));
}

test "reset: restores ANSI colors" {
    var p: Palette = .empty;
    p.entries[1] = 0xDEAD_BEEF;
    p.reset();
    try testing.expectEqual(Color{ .indexed = 0 }, p.decode(1));
}

test "reset: restores next to dynamic_base" {
    var p: Palette = .empty;
    _ = p.intern(.{ .rgb = .{ .r = 1, .g = 2, .b = 3 } });
    _ = p.intern(.{ .rgb = .{ .r = 4, .g = 5, .b = 6 } });
    p.reset();
    try testing.expectEqual(Palette.dynamic_base, p.next);
}

test "reset: restores xterm 256-color pre-population" {
    var p: Palette = .empty;
    // Evict slot 17 (xterm color 16).
    _ = p.intern(.{ .rgb = .{ .r = 99, .g = 99, .b = 99 } });
    p.reset();
    // After reset, slot 17 should hold xterm color 16 again.
    try testing.expectEqual(Color{ .indexed = 16 }, p.decode(17));
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
        const slot = p.intern(.{ .indexed = n });
        try testing.expectEqual(c.toArray(), p.resolveRgb(slot, .foreground));
        try testing.expectEqual(c.toU32(), p.resolve(slot, .background));
    }
}

test "setIndexed: an override of 0-15 applies to text already drawn" {
    var p: Palette = .empty;
    const slot = p.intern(.{ .indexed = 3 });
    const c: Rgb = .{ .r = 7, .g = 8, .b = 9 };
    p.setIndexed(3, c);
    try testing.expectEqual(c.toArray(), p.resolveRgb(slot, .foreground));
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
