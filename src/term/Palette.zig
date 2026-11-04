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

/// RGB of each xterm color index: the theme for 0-15, the xterm
/// 256-color cube and grays above, then any OSC 4 override. Slots
/// holding `.indexed` keys resolve through this, so an override
/// applies to every cell using that index.
// Hot, read when rendering an indexed color.
indexed: [256]Rgb,

/// What OSC 104 restores `indexed` to: the theme and xterm defaults.
// Warm, accessed on OSC 104.
indexed_default: [256]Rgb,

/// Next dynamic slot for round-robin eviction (wraps in [dynamic_base..255]).
// Warm, accessed on every intern()
next: u8,

// Colds

foreground: ?Rgb,
background: ?Rgb,

builtin_foreground: Rgb = .white,
builtin_background: Rgb = .black,
builtin_selection_foreground: Rgb = .white,
builtin_selection_background: Rgb = .black,

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

const xterm_indexed: [256]Rgb = blk: {
    @setEvalBranchQuota(4096);
    var t: [256]Rgb = undefined;
    for (&t, 0..) |*c, n| c.* = Rgb.fromU32(ansi.indexed(n));
    break :blk t;
};

/// Returns a Palette with reserved slots pre-populated.
pub const empty: Palette = .{
    .background = null,
    .foreground = null,
    .builtin_background = .black,
    .builtin_foreground = .white,
    .entries = default_entries,
    .indexed = xterm_indexed,
    .indexed_default = xterm_indexed,
    .next = dynamic_base,
};

pub const GroundTarget = enum { foreground, background };

/// Resets the palette to its initial state. The theme (builtin colors
/// and `indexed_default`) survives; OSC overrides do not.
pub fn reset(self: *Palette) void {
    self.foreground = null;
    self.background = null;
    self.entries = default_entries;
    self.indexed = self.indexed_default;
    self.next = dynamic_base;
}

/// Applies a theme. Called once at startup; OSC 4/10/11 can still
/// override on top.
pub fn setTheme(self: *Palette, theme: Theme) void {
    self.builtin_background = theme.background;
    self.builtin_foreground = theme.foreground;
    self.builtin_selection_background = theme.selection_background;
    self.builtin_selection_foreground = theme.selection_foreground;
    self.indexed_default[0..16].* = theme.ansi;
    self.indexed[0..16].* = theme.ansi;
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
        0x01 => self.indexed[key & 0xFF].toU32(),
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
        0x01 => self.indexed[key & 0xFF].toArray(),
        0x02 => .{ @truncate(key >> 16), @truncate(key >> 8), @truncate(key) },
        else => unreachable,
    };
}

/// Overrides xterm color `index` (0-255) with `rgb` (OSC 4), for cells
/// already drawn with it and new ones.
pub fn setIndexed(self: *Palette, index: u8, rgb: Rgb) void {
    self.indexed[index] = rgb;
}

/// Returns the current RGB of xterm color `index` (0-255).
pub fn getIndexed(self: *const Palette, index: u8) Rgb {
    return self.indexed[index];
}

/// Restores xterm color `index` to its theme or xterm default (OSC 104 ; n).
pub fn resetIndexed(self: *Palette, index: u8) void {
    self.indexed[index] = self.indexed_default[index];
}

/// Restores all 256 xterm colors (OSC 104 with no argument).
pub fn resetAllIndexed(self: *Palette) void {
    self.indexed = self.indexed_default;
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
