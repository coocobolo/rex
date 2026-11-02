const std = @import("std");

pub fn Tracker(comptime size: usize) type {
    return struct {
        const Self = @This();

        generation: u32,
        rows: std.bit_set.StaticBitSet(size),

        pub const empty: Self = .{
            .generation = 0,
            .rows = .empty,
        };

        /// Mark a single row dirty. Keeps generation and rows in sync.
        pub fn markDirty(self: *Self, index: usize) void {
            self.rows.set(index);
            self.generation +%= 1;
        }

        /// Mark a range of rows with the given value in one shot.
        pub fn markRangeValue(self: *Self, range: std.bit_set.Range, value: bool) void {
            // cheap heuristic: only bump generation if the range wasn't
            // already fully set; exactness doesn't matter for an O(1) gate
            self.rows.setRangeValue(range, value);
            self.generation +%= 1;
        }

        /// Clear a single row.
        pub fn clear(self: *Self, row: usize) void {
            if (self.rows.isSet(row)) {
                self.rows.unset(row);
                self.generation +%= 1;
            }
        }

        /// Clear everything, e.g. after a full redraw.
        pub fn clearAll(self: *Self) void {
            if (self.rows.findFirstSet() != null) {
                self.rows = .empty;
                self.generation +%= 1;
            }
        }

        /// O(1) check: has anything changed since `last_seen`?
        pub fn changedSince(self: Self, last_seen: u32) bool {
            return self.generation != last_seen;
        }

        pub fn getGeneration(self: Self) u32 {
            return self.generation;
        }

        /// "Which rows" query, only call after changedSince() is true.
        pub fn iterator(self: *const Self) std.bit_set.StaticBitSet(size).Iterator(.{}) {
            return self.rows.iterator(.{});
        }
    };
}