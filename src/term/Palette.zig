const std = @import("std");
const testing = std.testing;

const Color = @import("cell.zig").Color;
const Rgb = Color.Rgb;
const ansi = @import("../color/ansi.zig");
const Theme = @import("Theme.zig");

/// Per-screen color palette.
///
/// Maps u8 indices (stored in Cell on field .fg / .bg) to Color values.
/// 0        = default,
/// 1..16    = ANSI color (0-15),
/// 17..255  = dynamic slots (RGB / indexed > 15), pre-populated with
///           xterm 256-color, evictable by RGB colors (round-robin).
///
/// Dynamic slots use a simple round-robin eviction policy.
/// When all 239 dynamic slots are full, the oldest slot is overwritten.
/// Cells referencing an evicted index will show the replacement color
/// until they are redrawn, (looks like acceptable for a terminal emulator).
pub const Palette = @This();

pub const default_base: u8 = 0;
pub const ansi_base: u8 = 1; // ANSI color n (slot n+1)
pub const dynamic_base: u8 = 17; // first evictable slot

/// The Palette entries layer stores encoded color keys via colorKey(). This is not a raw RGBA value.
/// Its an encoding that preserves the color type + value for fast lookup and eviction detection.
// Hot, accessed every call render.
entries: [256]u32,

/// Encoded color keys (same format as entries[]) used as reset target for OSC 104.
/// Never used for rendering directly.
// Warm, accessed on OSC 104.
theme_ansi: [16]u32,

/// Next dynamic slot for round-robin eviction (wraps in [dynamic_base..255]).
// Warm, accessed on every intern()
next: u8,

// Colds

foreground: ?Rgb,
background: ?Rgb,

builtin_foreground: Rgb = .white,
builtin_background: Rgb = .black,

const default_entries: [256]u32 = blk: {
    var e: [256]u32 = undefined;
    e[0] = 0; // default slot sentinel
    for (0..16) |n| {
        e[ansi_base + n] = encode(.{ .indexed = @intCast(n) });
    }
    for (16..255) |n| {
        e[n + 1] = encode(.{ .indexed = @intCast(n) });
    }
    break :blk e;
};

const default_theme_ansi: [16]u32 = blk: {
    var t: [16]u32 = undefined;
    for (0..16) |n| {
        t[n] = encode(.{ .indexed = @intCast(n) });
    }
    break :blk t;
};

/// Returns a Palette with reserved slots pre-populated.
pub const empty: Palette = .{
    .background = null,
    .foreground = null,
    .builtin_background = .black,
    .builtin_foreground = .white,
    .entries = default_entries,
    .theme_ansi = default_theme_ansi,
    .next = dynamic_base,
};

pub const GroundTarget = enum { foreground, background };

/// Resets the palette to its initial state.
pub fn reset(self: *Palette) void {
    const saved_theme_ansi = self.theme_ansi;
    // Don't touch builtin_foreground/builtin_background — they survive reset
    self.* = .empty;
    self.foreground = null;
    self.background = null;
    self.entries = default_entries;
    self.theme_ansi = saved_theme_ansi;
    self.entries[ansi_base..][0..16].* = saved_theme_ansi;
    self.next = dynamic_base;
}

/// Apply a theme, Called once at startup.
/// OSC overrides (4/1011) can still override on top.
pub fn setTheme(self: *Palette, theme: Theme) void {
    self.builtin_background = theme.background;
    self.builtin_foreground = theme.foreground;
    for (theme.ansi, 0..) |color, index| {
        self.entries[index + 1] = encode(.{ .rgb = color });
        self.theme_ansi[index] = encode(.{ .rgb = color });
    }
}

/// Returns the decode Color stored at index.
pub fn decode(self: *const Palette, index: u8) Color {
    const key = self.entries[index];
    return switch (key >> 24) {
        0x00 => .default,
        0x01 => .{ .indexed = @intCast(key & 0xFF) },
        0x02 => .{
            .rgb = .{
                .r = @intCast((key >> 16) & 0xFF),
                .g = @intCast((key >> 8) & 0xFF),
                .b = @intCast(key & 0xFF),
            },
        },
        else => unreachable,
    };
}

/// Encode a Color as a u32 for fast equality comparison.
fn encode(color: Color) u32 {
    return switch (color) {
        .default => 0x0000_0000,
        .indexed => |n| @as(u32, 0x0100_0000) | n,
        .rgb => |c| 0x0200_0000 | (@as(u32, c.r) << 16) | (@as(u32, c.g) << 8) | c.b,
    };
}

/// Returns the palette index for Color, inserting it if necessary.
///
/// Fast path: performs no scan O(1)
///  .default          = slot 0.
///  .indexed(0..15)   = slots 1..16 (basic ANSI 16, fixed).
///  .indexed(16..254) = slots (n+1) if still pre-populated (cold).
///
/// Slow path: linear scan and round-robin eviction
///  .indexed(16..254) = after eviction by an RGB color (unlikely).
///  .indexed(255)     = always (no fixed slot).
///  .rgb(r,g,b)       = always.
pub fn intern(self: *Palette, color: Color) u8 {
    const key = encode(color);
    return switch (color) {
        .default => default_base,
        .indexed => |index| switch (index) {
            0...15 => ansi_base + index,
            16...254 => blk: {
                // Fast path, slot (n+1) was pre-populated at init.
                // One comparison to verify it hasn't been evicted.
                const slot: u8 = index + 1;
                if (self.entries[slot] == key) break :blk slot;
                break :blk self.internDynamic(key);
            },
            255 => self.internDynamic(key),
        },
        .rgb => self.internDynamic(key),
    };
}

fn internDynamic(self: *Palette, key: u32) u8 {
    // Linear scan over dynamic slots.
    for (self.entries[dynamic_base..], 0..) |entry, offset| {
        if (entry == key) return dynamic_base + @as(u8, @intCast(offset));
    }

    // Not found; allocate next slot via round-robin eviction.
    const index = self.next;
    self.entries[index] = key;
    self.next = if (self.next == 255) dynamic_base else self.next + 1;
    return index;
}

pub fn resolve(self: *const Palette, index: u8, comptime target: GroundTarget) u32 {
    const key = self.entries[index];
    return switch (key >> 24) {
        0x00 => blk: {
            const c = self.get(target);
            break :blk (@as(u32, c.r) << 24) | (@as(u32, c.g) << 16) | (@as(u32, c.b) << 8) | 0xFF;
        },
        0x01 => ansi.indexed(@intCast(key & 0xFF)),
        0x02 => ((key & 0x00FF_FFFF) << 8) | 0xFF, // shift RGB bits up, append alpha
        else => unreachable,
    };
}

pub fn resolveRgb(self: *const Palette, index: u8, comptime target: GroundTarget) [3]u8 {
    const key = self.entries[index];
    return switch (key >> 24) {
        0x00 => blk: {
            const c = self.get(target);
            break :blk .{ c.r, c.g, c.b };
        },
        0x01 => blk: {
            const rgba = ansi.indexed(@intCast(key & 0xFF));
            break :blk .{ @truncate(rgba >> 24), @truncate(rgba >> 16), @truncate(rgba >> 8) };
        },
        0x02 => .{ @truncate(key >> 16), @truncate(key >> 8), @truncate(key) },
        else => unreachable,
    };
}

/// Override ANSI color `index` (0-15) with a custom RGB (OSC 4).
pub fn setIndexed(self: *Palette, index: u8, rgb: Rgb) void {
    self.entries[ansi_base + index] = encode(.{ .rgb = rgb });
}

/// Return the current RGB for ANSI color `index` (0-15).
/// If the slot was overridden via `setIndexed` returns the override.
/// Otherwise resolves the built-in xterm ANSI color.
pub fn getIndexed(self: *const Palette, index: u8) Rgb {
    const entry = self.entries[ansi_base + index];
    return switch (entry >> 24) {
        0x01 => blk: {
            // Still the default .indexed entry, resolve via built-in table.
            const n: u8 = @intCast(entry & 0xFF);
            const rgba = ansi.indexed(n); // u32: r<<24|g<<16|b<<8|0xFF
            break :blk Rgb.fromU32(rgba);
        },
        0x02 => Rgb.fromColorKey(entry),
        else => unreachable, // ANSI slots are never .default
    };
}

/// Restore ANSI color `index` (0–15) to its built-in default (OSC 104 ; n).
pub fn resetIndexed(self: *Palette, index: u8) void {
    self.entries[ansi_base + index] = self.theme_ansi[index];
}

/// Restore all 16 ANSI colors to their built-in defaults (OSC 104 with no arg).
pub fn resetAllIndexed(self: *Palette) void {
    self.entries[ansi_base..][0..16].* = self.theme_ansi;
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
