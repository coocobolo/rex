//! The window title (OSC 0 and 2), the icon name (OSC 1) and the title
//! stack of xterm's XTWINOPS 22 and 23 (`CSI 22 ; Ps t` pushes,
//! `CSI 23 ; Ps t` pops), as `misc.c` xtermPushTitle and xtermPopTitle do
//! it: a ring of `depth` entries, where a push onto a full stack overwrites
//! the oldest and a pop on an empty one does nothing. An entry holds the
//! title, the icon name, or both; a pop that asks for a part its entry
//! lacks takes it from the nearest older entry that has one.

const std = @import("std");

const utf8 = @import("../unicode/utf8.zig");

const Title = @This();

/// `MAX_SAVED_TITLES` in xterm's `ptyx.h`.
pub const depth = 10;
/// The longest title or icon name kept, in bytes.
pub const max_len = 256;

/// XTWINOPS 22 and 23's second parameter: which parts to push or pop.
pub const Part = enum(u2) {
    both = 0,
    icon_name = 1,
    title = 2,

    pub fn has(self: Part, part: enum { title, icon_name }) bool {
        return switch (part) {
            .title => self != .icon_name,
            .icon_name => self != .title,
        };
    }
};

/// A title or icon name, or none (`len == absent`): a stack entry pushed
/// with one part has no value for the other, which is not the same as
/// empty. The current title and icon name are never absent.
const Text = struct {
    buf: [max_len]u8 = undefined,
    len: u16 = absent,

    const absent = std.math.maxInt(u16);
    const empty: Text = .{ .len = 0 };

    /// Keeps `bytes`, cut to `max_len` on a UTF-8 boundary.
    fn set(self: *Text, bytes: []const u8) void {
        const len = utf8.truncateLen(bytes, max_len);
        @memcpy(self.buf[0..len], bytes[0..len]);
        self.len = @intCast(len);
    }

    fn slice(self: *const Text) []const u8 {
        std.debug.assert(self.len != absent);
        return self.buf[0..self.len];
    }
};

const Entry = struct {
    title: Text = .{},
    icon_name: Text = .{},
};

text: Text = .empty,
icon_name: Text = .empty,
entries: [depth]Entry = @splat(.{}),
/// The slot the next push writes.
top: u8 = 0,
/// Entries a pop can take, at most `depth`.
count: u8 = 0,

/// Sets the title, cut to `max_len` bytes on a UTF-8 boundary.
pub fn set(self: *Title, title: []const u8) void {
    self.text.set(title);
}

/// Sets the icon name, cut to `max_len` bytes on a UTF-8 boundary.
pub fn setIconName(self: *Title, name: []const u8) void {
    self.icon_name.set(name);
}

/// The title. Valid until the next `set`, `pop` or `reset`.
pub fn get(self: *const Title) []const u8 {
    return self.text.slice();
}

/// The icon name. Valid until the next `setIconName`, `pop` or `reset`.
pub fn getIconName(self: *const Title) []const u8 {
    return self.icon_name.slice();
}

/// RIS: empties the title and the icon name and keeps the stack, as xterm
/// does.
pub fn reset(self: *Title) void {
    self.text = .empty;
    self.icon_name = .empty;
}

/// Saves `part` of the title and icon name on the stack.
pub fn push(self: *Title, part: Part) void {
    const entry = &self.entries[self.top];
    entry.* = .{};
    if (part.has(.title)) entry.title.set(self.text.slice());
    if (part.has(.icon_name)) entry.icon_name.set(self.icon_name.slice());
    self.top = (self.top + 1) % depth;
    self.count = @min(self.count + 1, depth);
}

/// The parts a pop put back.
pub const Restored = struct {
    title: bool = false,
    icon_name: bool = false,
};

/// Takes the newest entry off the stack and restores `part` from it. A
/// part is not restored when it was not asked for, when no entry on the
/// stack has it, or when the stack is empty.
pub fn pop(self: *Title, part: Part) Restored {
    if (self.count == 0) return .{};
    self.top = (self.top + depth - 1) % depth;
    self.count -= 1;
    var restored: Restored = .{};
    if (part.has(.title)) {
        if (self.find(.title)) |text| {
            self.text.set(text);
            restored.title = true;
        }
    }
    if (part.has(.icon_name)) {
        if (self.find(.icon_name)) |text| {
            self.icon_name.set(text);
            restored.icon_name = true;
        }
    }
    return restored;
}

/// The part in the entry at `top`, else in the nearest older entry still
/// on the stack.
fn find(self: *const Title, comptime part: enum { title, icon_name }) ?[]const u8 {
    var i: u8 = 0;
    while (i <= self.count) : (i += 1) {
        const text = &@field(self.entries[(self.top + depth - i) % depth], @tagName(part));
        if (text.len != Text.absent) return text.slice();
    }
    return null;
}
