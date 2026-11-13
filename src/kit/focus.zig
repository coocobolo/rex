//! The order the keyboard focus moves in over a row or list of `count`
//! items, numbered from 0. Any value from `count` up stands for "none has
//! the focus".

const std = @import("std");
const assert = std.debug.assert;

pub const Direction = enum(u8) { next, previous };

/// The item the focus moves to from `current`, wrapping at both ends.
/// Coming in from none lands on the first item forwards and on the last
/// backwards.
pub fn move(current: u8, count: u8, direction: Direction) u8 {
    assert(count > 0);
    const none = current >= count;
    return switch (direction) {
        .next => if (none) 0 else (current + 1) % count,
        .previous => if (none or current == 0) count - 1 else current - 1,
    };
}

test move {
    const testing = std.testing;
    const none = 3;
    try testing.expectEqual(0, move(none, 3, .next));
    try testing.expectEqual(2, move(none, 3, .previous));
    try testing.expectEqual(1, move(0, 3, .next));
    try testing.expectEqual(0, move(2, 3, .next));
    try testing.expectEqual(2, move(0, 3, .previous));
    try testing.expectEqual(1, move(2, 3, .previous));
    try testing.expectEqual(0, move(0, 1, .next));
    try testing.expectEqual(0, move(0, 1, .previous));
}
