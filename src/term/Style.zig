//! The colors of a cell: foreground, background and underline (SGR 58),
//! interned per screen in a `Table` (ADR 0005). Attribute flags stay in
//! the cell.
//!
//! Each color is stored as a `Key`, the same encoding `Palette` uses, so a
//! style is 12 bytes with no padding and can be hashed and compared as
//! bytes. Indexed colors stay indexed and resolve through the palette when
//! drawn, so OSC 4 and theme changes still apply.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Color = @import("../color/color.zig").Color;

pub const Style = @This();

fg: Key = default_key,
bg: Key = default_key,
underline: Key = default_key,

/// An encoded `Color`: bits 24-31 are the kind (0 default, 1 indexed,
/// 2 RGB); below them the index, or the RGB value as 0xRRGGBB.
pub const Key = u32;
pub const default_key: Key = 0;

pub const default: Style = .{};

/// The handle a cell will hold; 0 is the default style. See `Table`.
pub const Id = u16;

comptime {
    std.debug.assert(@sizeOf(Style) == 12);
    std.debug.assert(@alignOf(Style) == 4);
}

/// Encodes foreground, background, and underline colors into a `Style`.
pub fn init(fg: Color, bg: Color, underline: Color) Style {
    return .{ .fg = encode(fg), .bg = encode(bg), .underline = encode(underline) };
}

/// True when all three color keys match `other`.
pub fn eql(self: Style, other: Style) bool {
    return self.fg == other.fg and self.bg == other.bg and self.underline == other.underline;
}

/// True when all three colors use their terminal defaults.
pub fn isDefault(self: Style) bool {
    return self.eql(default);
}

/// Encodes a `Color` into its 32-bit packed `Key` representation.
pub fn encode(color: Color) Key {
    return switch (color) {
        .default => default_key,
        .indexed => |n| @as(Key, 0x0100_0000) | n,
        .rgb => |c| 0x0200_0000 | (@as(Key, c.r) << 16) | (@as(Key, c.g) << 8) | c.b,
    };
}

/// Inverse of `encode`. A key with an unknown kind byte is a bug.
pub fn decode(key: Key) Color {
    return switch (key >> 24) {
        0 => .default,
        1 => .{ .indexed = @truncate(key) },
        2 => .{ .rgb = .{ .r = @truncate(key >> 16), .g = @truncate(key >> 8), .b = @truncate(key) } },
        else => unreachable,
    };
}

/// Squared RGB distance summed over the three colors. Two non-RGB keys
/// are 0 apart when equal and as far apart as possible otherwise.
fn distance(a: Style, b: Style) u64 {
    return keyDistance(a.fg, b.fg) + keyDistance(a.bg, b.bg) + keyDistance(a.underline, b.underline);
}

fn keyDistance(a: Key, b: Key) u64 {
    if (a == b) return 0;
    const rgb_kind = 2;
    if (a >> 24 != rgb_kind or b >> 24 != rgb_kind) return 3 * 255 * 255 + 1;
    var sum: u64 = 0;
    inline for (.{ 16, 8, 0 }) |shift| {
        const x: i64 = @as(u8, @truncate(a >> shift));
        const y: i64 = @as(u8, @truncate(b >> shift));
        sum += @intCast((x - y) * (x - y));
    }
    return sum;
}

/// Per-screen table of interned styles.
///
/// A cell will hold an `Id` into this table instead of two palette
/// indexes. An ID referenced by a cell, the pen or the saved cursor keeps
/// its style: IDs are only reclaimed by `sweep`, which the owner calls with
/// the set of IDs its holders still use. Nothing on the cell-write path
/// touches the table.
///
/// Capacity is fixed and allocated once by `init`, so `intern` never
/// allocates. When the table is full, the owner may sweep (see
/// `sweepDue`); if nothing can be freed, `nearest` gives a new style the
/// closest live one, so text already drawn never changes color.
///
/// Memory: `entries` 192 KiB, `index` 64 KiB, `free` 32 KiB, owned by the
/// table and freed by `deinit`.
pub const Table = struct {
    /// Styles per screen, ID 0 (the default style) included. ADR 0005.
    pub const capacity = 16384;
    /// The default style. Never stored, never swept.
    pub const default_id: Id = 0;
    /// IDs still referenced by a screen's holders, passed to `sweep`.
    pub const InUse = std.StaticBitSet(capacity);

    /// Hash index slots: a power of two at least twice the capacity, so
    /// the load factor stays at or below one half.
    const index_len = capacity * 2;
    /// Misses (`intern` returning null) to wait between two sweeps of a
    /// full table, so a flood of new styles costs one sweep per
    /// `sweep_gap` styles.
    const sweep_gap = capacity / 8;
    /// Live entries `nearest` compares at most.
    const nearest_samples = 256;

    comptime {
        std.debug.assert(std.math.isPowerOfTwo(index_len));
        std.debug.assert(capacity - 1 <= std.math.maxInt(Id));
    }

    /// Styles by ID. Slots at or above `high`, or not in `live`, are unused.
    entries: *[capacity]Style,
    /// Open-addressing index with linear probing: holds IDs, 0 marks an
    /// empty slot (ID 0 is never stored). Rebuilt by `sweep`, so it has
    /// no tombstones.
    index: *[index_len]Id,
    /// Reclaimed IDs, used once `high` reaches `capacity`.
    free: *[capacity]Id,
    free_len: u16 = 0,
    /// Lowest ID never handed out.
    high: u16 = 1,
    /// IDs holding a style.
    live: InUse = .initEmpty(),
    /// Misses since the last sweep; starts at `sweep_gap` so the first
    /// full table sweeps at once.
    misses: u32 = sweep_gap,
    /// Changes whenever an ID gets a new style (`intern` adding one,
    /// `reset`). A copy of the table made at the same generation is still
    /// exact. `sweep` only frees IDs, which nothing drawn refers to, so it
    /// does not change it. Wraps.
    generation: u32 = 0,

    /// Allocates the style entry table, hash index, and free list. Release with `deinit`.
    pub fn init(gpa: Allocator) Allocator.Error!Table {
        const entries = try gpa.create([capacity]Style);
        errdefer gpa.destroy(entries);
        const index = try gpa.create([index_len]Id);
        errdefer gpa.destroy(index);
        const free = try gpa.create([capacity]Id);
        entries[default_id] = .default;
        @memset(index, 0);
        return .{ .entries = entries, .index = index, .free = free };
    }

    /// Frees the entry table, hash index, and free list allocated by `init`.
    pub fn deinit(self: *Table, gpa: Allocator) void {
        gpa.destroy(self.entries);
        gpa.destroy(self.index);
        gpa.destroy(self.free);
        self.* = undefined;
    }

    /// The style stored under `id`.
    pub fn get(self: *const Table, id: Id) Style {
        std.debug.assert(id == default_id or self.live.isSet(id));
        return self.entries[id];
    }

    /// Number of live styles, the default excluded.
    pub fn count(self: *const Table) usize {
        return self.live.count();
    }

    /// The ID of `style`, adding it when new. Null when the table is
    /// full; the caller then sweeps (`sweepDue`) or takes `nearest`.
    pub fn intern(self: *Table, style: Style) ?Id {
        if (style.isDefault()) return default_id;
        var slot = slotOf(style);
        while (self.index[slot] != 0) : (slot = (slot + 1) & (index_len - 1)) {
            const id = self.index[slot];
            if (self.entries[id].eql(style)) return id;
        }
        const id = self.takeId() orelse {
            self.misses +|= 1;
            return null;
        };
        self.entries[id] = style;
        self.index[slot] = id;
        self.live.set(id);
        self.generation +%= 1;
        return id;
    }

    /// Empties the table, keeping its memory. Only valid when nothing
    /// holds an ID other than `default_id` (RIS, entering the alternate
    /// screen).
    pub fn reset(self: *Table) void {
        // The index holds exactly the live IDs, so clearing their slots
        // empties it. That is far cheaper than clearing all 64 KiB when few
        // styles are live: entering the alternate screen resets its table
        // every time (`bench-term` htop, ADR 0005).
        if (self.live.count() > capacity / 16) {
            @memset(self.index, 0);
        } else {
            var it = self.live.iterator(.{});
            while (it.next()) |id| {
                var slot = slotOf(self.entries[id]);
                // Earlier IDs' slots are already zero; skip over them.
                while (self.index[slot] != id) slot = (slot + 1) & (index_len - 1);
                self.index[slot] = 0;
            }
        }
        self.free_len = 0;
        self.high = 1;
        self.live = .initEmpty();
        self.misses = sweep_gap;
        self.generation +%= 1;
    }

    /// Makes the next full-table miss sweep at once instead of waiting
    /// for `sweep_gap` misses. For the owner to call after dropping
    /// content (erase display, clearing scrollback).
    pub fn requestSweep(self: *Table) void {
        self.misses = @max(self.misses, sweep_gap);
    }

    /// Whether a full table should be swept now: true once `sweep_gap`
    /// misses have accumulated since the last sweep.
    pub fn sweepDue(self: *const Table) bool {
        return self.misses >= sweep_gap;
    }

    /// Frees every ID not set in `in_use` and rebuilds the index from the
    /// rest. IDs set in `in_use` keep their styles. Returns how many IDs
    /// were freed. O(capacity); the caller's marking pass over its cells
    /// dominates.
    pub fn sweep(self: *Table, in_use: *const InUse) usize {
        @memset(self.index, 0);
        self.free_len = 0;
        var freed: usize = 0;
        var id: Id = 1;
        while (id < self.high) : (id += 1) {
            if (self.live.isSet(id) and in_use.isSet(id)) {
                var slot = slotOf(self.entries[id]);
                while (self.index[slot] != 0) slot = (slot + 1) & (index_len - 1);
                self.index[slot] = id;
            } else {
                if (self.live.isSet(id)) freed += 1;
                self.live.unset(id);
                self.free[self.free_len] = id;
                self.free_len += 1;
            }
        }
        self.misses = 0;
        return freed;
    }

    /// A live style close to `style`, for when the table is full. Compares
    /// at most `nearest_samples` live entries spread over the table, so a
    /// miss costs a bounded amount. Returns the default style if none is
    /// live.
    pub fn nearest(self: *const Table, style: Style) Id {
        const live_count = self.live.count();
        if (live_count == 0) return default_id;
        const stride = @max(1, live_count / nearest_samples);
        var best: Id = default_id;
        var best_distance: u64 = distance(style, default);
        var seen: usize = 0;
        var it = self.live.iterator(.{});
        while (it.next()) |i| : (seen += 1) {
            if (seen % stride != 0) continue;
            const d = distance(style, self.entries[i]);
            if (d < best_distance) {
                best_distance = d;
                best = @intCast(i);
            }
        }
        return best;
    }

    fn takeId(self: *Table) ?Id {
        if (self.high < capacity) {
            const id = self.high;
            self.high += 1;
            return id;
        }
        if (self.free_len == 0) return null;
        self.free_len -= 1;
        return self.free[self.free_len];
    }

    fn slotOf(style: Style) usize {
        const h = std.hash.Wyhash.hash(0, std.mem.asBytes(&style));
        return @intCast(h & (index_len - 1));
    }
};
