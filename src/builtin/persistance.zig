const std = @import("std");

const log = std.log.scoped(.persistance);

pub fn Manager(comptime Snapshot: type) type {
    return struct {
        const Self = @This();

        dirty: bool = false,

        pub fn markDirty(self: *Self) void {
            self.dirty = true;
        }

        pub fn takeSnapshot(
            self: *Self,
            snapshot: Snapshot,
        ) ?Snapshot {
            if (!self.dirty) return null;

            self.dirty = false;
            return snapshot;
        }

        pub fn markDirtyAgain(self: *Self) void {
            self.dirty = true;
        }
    };
}