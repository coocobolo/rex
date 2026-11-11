//! The title stack of xterm's XTWINOPS 22 and 23 (`CSI 22 ; Ps t` pushes,
//! `CSI 23 ; Ps t` pops), as `misc.c` xtermPushTitle and xtermPopTitle do
//! it: a ring of `depth` entries, where a push onto a full stack overwrites
//! the oldest and a pop on an empty one does nothing. An entry holds the
//! title, the icon name, or both; a pop that asks for a part its entry
//! lacks takes it from the nearest older entry that has one. RIS leaves the
//! stack alone, as in xterm.

const std = @import("std");

const TitleStack = @This();

/// `MAX_SAVED_TITLES` in xterm's `ptyx.h`.
pub const depth = 10;
/// The longest title or icon name kept, as `Terminal` keeps them.
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

/// A title or icon name, or none (`len == absent`): an entry pushed with
/// one part has no value for the other, which is not the same as empty.
const Text = struct {
    buf: [max_len]u8 = undefined,
    len: u16 = absent,

    const absent = std.math.maxInt(u16);

    fn set(self: *Text, text: []const u8) void {
        std.debug.assert(text.len <= max_len);
        @memcpy(self.buf[0..text.len], text);
        self.len = @intCast(text.len);
    }

    fn get(self: *const Text) ?[]const u8 {
        return if (self.len == absent) null else self.buf[0..self.len];
    }
};

const Entry = struct {
    title: Text = .{},
    icon_name: Text = .{},
};

entries: [depth]Entry = @splat(.{}),
/// The slot the next push writes.
top: u8 = 0,
/// Entries a pop can take, at most `depth`.
count: u8 = 0,

/// Saves `part` of `title` and `icon_name`, each at most `max_len` bytes.
pub fn push(self: *TitleStack, part: Part, title: []const u8, icon_name: []const u8) void {
    const entry = &self.entries[self.top];
    entry.* = .{};
    if (part.has(.title)) entry.title.set(title);
    if (part.has(.icon_name)) entry.icon_name.set(icon_name);
    self.top = (self.top + 1) % depth;
    self.count = @min(self.count + 1, depth);
}

/// What a pop restores; null for a part not asked for or found nowhere.
/// The slices are valid until the next push.
pub const Popped = struct {
    title: ?[]const u8 = null,
    icon_name: ?[]const u8 = null,
};

/// Takes the newest entry. Null when the stack is empty.
pub fn pop(self: *TitleStack, part: Part) ?Popped {
    if (self.count == 0) return null;
    self.top = (self.top + depth - 1) % depth;
    self.count -= 1;
    var popped: Popped = .{};
    if (part.has(.title)) popped.title = self.find(self.top, .title);
    if (part.has(.icon_name)) popped.icon_name = self.find(self.top, .icon_name);
    return popped;
}

/// The part in the entry at `slot`, else in the nearest older entry still
/// on the stack.
fn find(self: *const TitleStack, slot: u8, comptime part: enum { title, icon_name }) ?[]const u8 {
    var i: u8 = 0;
    while (i <= self.count) : (i += 1) {
        const entry = &self.entries[(slot + depth - i) % depth];
        if (@field(entry, @tagName(part)).get()) |text| return text;
    }
    return null;
}
