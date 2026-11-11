//! High-level driver events, packed event bitsets, and atomic cross-thread transfer mechanisms.
//!
//! Owns the canonical event bit definitions and batch container passed from the driver
//! to the GUI thread on each frame tick. Does not touch terminal rendering or PTY handles.

const std = @import("std");
const term = @import("../term/root.zig");
const IntegerSet = @import("../flag_set.zig").IntegerSet;

/// High-level events accumulated by the driver to notify the GUI thread.
const Events = @This();

/// Strongly typed bit flags for atomic cross-thread driver event signaling.
///
/// Bit 0 through 5 hold terminal emulation protocol events parsed from incoming ANSI streams.
/// Bit 6 and 7 hold host OS process and PTY events. Bit 8 indicates a pending resize payload.
/// Bit 9 says an OSC 52 request is pending. Terminal bits keep the terminal's positions, so
/// `accumulateTerm` copies them as one integer.
pub const Bits = packed struct(u32) {
    // Protocol events (bits 0..5)
    bell: bool = false,
    title: bool = false,
    icon_name: bool = false,
    cursor_color: bool = false,
    selection_reset: bool = false,
    hard_reset: bool = false,

    // Host OS events (bits 6..7)
    child_closed: bool = false,
    had_data: bool = false,

    /// Transport bit indicating a resize payload is queued (bit 8).
    resize: bool = false,
    /// An OSC 52 request is pending; take it with `takeClipboard` (bit 9).
    clipboard: bool = false,

    _pad: u22 = 0,
};

comptime {
    for (@typeInfo(term.term.EventBits).@"struct".fields) |field| {
        if (field.name[0] == '_') continue;
        std.debug.assert(@bitOffsetOf(term.term.EventBits, field.name) == @bitOffsetOf(Bits, field.name));
    }
}

pub const Set = IntegerSet(Bits);
pub const EventBits = Bits;
pub const EventSet = Set;
pub const Field = std.meta.FieldEnum(Bits);

comptime {
    std.debug.assert(@sizeOf(Set) == 4);
}

flags: Set = .empty,
resize: term.Events.Resize = .{ .rows = 0, .cols = 0 },

comptime {
    std.debug.assert(@sizeOf(Events) == 8);
    std.debug.assert(@alignOf(Events) == 4);
}

/// Sets an event flag.
pub inline fn set(self: *Events, comptime field: Field) void {
    self.flags.insert(field);
}

/// True if an event flag is set.
pub inline fn has(self: Events, comptime field: Field) bool {
    return self.flags.has(field);
}

/// Returns the underlying bitfield struct.
pub inline fn bits(self: Events) Bits {
    return self.flags.bits;
}

/// True when any event flag is set.
pub inline fn any(self: Events) bool {
    return self.flags.any();
}

/// Returns the resize payload if the resize flag is set.
pub inline fn getResize(self: Events) ?term.Events.Resize {
    return if (self.has(.resize)) self.resize else null;
}

/// Accumulates terminal events into this driver event batch.
pub inline fn accumulateTerm(self: *Events, src: term.Events) void {
    self.flags = self.flags.unionWith(Set.fromInt(src.flags.toInt()));
    if (src.has(.resize)) self.resize = src.resize;
}

test "driver.events: bit flags, conversions, and accumulateTerm" {
    const testing = std.testing;

    var events = Events{};
    try testing.expect(!events.any());

    events.set(.bell);
    try testing.expect(events.any());
    try testing.expect(events.has(.bell));

    var ev_set = Set.empty;
    ev_set.bits.bell = true;
    ev_set.bits.title = true;
    ev_set.bits.child_closed = true;

    const raw = ev_set.toInt();
    const unpacked = Set.fromInt(raw);
    try testing.expect(unpacked.bits.bell);
    try testing.expect(unpacked.bits.title);
    try testing.expect(!unpacked.bits.icon_name);
    try testing.expect(unpacked.bits.child_closed);

    var batch = Events{};
    var src = term.Events{};
    src.set(.bell);
    src.set(.cursor_color);
    src.set(.resize);
    src.resize = .{ .rows = 40, .cols = 100 };

    batch.accumulateTerm(src);
    try testing.expect(batch.has(.bell));
    try testing.expect(batch.has(.cursor_color));
    try testing.expect(!batch.has(.title));
    try testing.expectEqual(@as(u16, 40), batch.resize.rows);
    try testing.expectEqual(@as(u16, 100), batch.resize.cols);
}
