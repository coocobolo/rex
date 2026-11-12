//! Per-widget memory (ADR 0009, point 2): one number per node id that
//! outlives a rebuild of the node array, such as where a toast was drawn
//! last frame, so it can glide to where layout puts it now.
//!
//! A surface owns one `Table`. Each frame it reads and writes the ids it
//! draws, then calls `sweep`, which forgets every id that was not written
//! since the last sweep: memory lives exactly as long as its widget is in
//! the view. Nothing allocates; a full table is `error.OutOfSlots`.

const std = @import("std");
const assert = std.debug.assert;

const Id = @import("tree.zig").Id;

pub const capacity = 16;

pub const Error = error{OutOfSlots};

pub const Table = struct {
    /// `ids[0..len]` are in use and distinct.
    ids: [capacity]Id = undefined,
    values: [capacity]f32 = undefined,
    /// Bit `i` is set when slot `i` was written since the last `sweep`.
    written: std.bit_set.IntegerBitSet(capacity) = .empty,
    len: u8 = 0,

    pub const empty: Table = .{};

    fn find(self: *const Table, id: Id) ?usize {
        return std.mem.indexOfScalar(Id, self.ids[0..self.len], id);
    }

    /// What was last stored for `id`, or null if it has no memory.
    pub fn get(self: *const Table, id: Id) ?f32 {
        const slot = self.find(id) orelse return null;
        return self.values[slot];
    }

    /// Stores `value` for `id` and keeps it through the next `sweep`.
    pub fn set(self: *Table, id: Id, value: f32) Error!void {
        assert(id != .none);
        const slot = self.find(id) orelse slot: {
            if (self.len == capacity) return error.OutOfSlots;
            self.ids[self.len] = id;
            self.len += 1;
            break :slot self.len - 1;
        };
        self.values[slot] = value;
        self.written.set(slot);
    }

    /// Forgets every id not written since the last sweep.
    pub fn sweep(self: *Table) void {
        var kept: u8 = 0;
        for (0..self.len) |slot| {
            if (!self.written.isSet(slot)) continue;
            self.ids[kept] = self.ids[slot];
            self.values[kept] = self.values[slot];
            kept += 1;
        }
        self.len = kept;
        self.written = .empty;
    }
};
