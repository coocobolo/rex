//! Per-screen table of OSC 8 link URIs (ADR 0012).
//!
//! A `Style` holds a `UrlTable.Id` so a link travels with its text through
//! scroll, reflow and erase. IDs are reclaimed by the screen's mark pass
//! together with unused styles. `Id` 0 means "no link". The allocator is
//! held here because the screen's reset paths do not take one.

const std = @import("std");
const Allocator = std.mem.Allocator;

const UrlTable = @This();

pub const capacity = 1024;
/// Longer URIs are dropped whole, never truncated.
pub const max_len = 1024;
pub const Id = u16;
pub const InUse = std.StaticBitSet(capacity);

gpa: Allocator,
/// Owned URI copies by ID minus one. A null slot is free.
entries: [capacity]?[]u8 = @splat(null),

comptime {
    std.debug.assert(capacity <= std.math.maxInt(Id));
}

pub fn init(gpa: Allocator) UrlTable {
    return .{ .gpa = gpa };
}

/// Frees every URI and clears the table, leaving it usable.
pub fn deinit(self: *UrlTable) void {
    for (&self.entries) |*entry| {
        if (entry.*) |url| self.gpa.free(url);
        entry.* = null;
    }
}

/// Frees every URI. Used by RIS and screen resets.
pub fn reset(self: *UrlTable) void {
    self.deinit();
}

/// The ID of `url`, adding it when new. Null when the table is full.
pub fn intern(self: *UrlTable, url: []const u8) ?Id {
    if (url.len == 0 or url.len > max_len) return null;
    for (self.entries, 0..) |entry, i| {
        if (entry) |existing| {
            if (std.mem.eql(u8, existing, url)) return @intCast(i + 1);
        }
    }
    for (&self.entries, 0..) |*entry, i| {
        if (entry.* == null) {
            const owned = self.gpa.dupe(u8, url) catch return null;
            entry.* = owned;
            return @intCast(i + 1);
        }
    }
    return null;
}

/// The URI stored under `id`, or null for "no link" or an invalid ID.
pub fn get(self: *const UrlTable, id: Id) ?[]const u8 {
    if (id == 0 or id > capacity) return null;
    return self.entries[id - 1];
}

/// Frees every URI whose ID is not in `in_use`. Call with the same mark pass
/// that collects the style IDs in use.
pub fn sweep(self: *UrlTable, in_use: *const InUse) void {
    for (&self.entries, 0..) |*entry, i| {
        if (entry.*) |url| {
            if (!in_use.isSet(i + 1)) {
                self.gpa.free(url);
                entry.* = null;
            }
        }
    }
}
