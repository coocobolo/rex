const std = @import("std");

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
