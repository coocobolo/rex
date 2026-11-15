//! The order the keyboard focus moves in over a row or list of `count`
//! items, numbered from 0. Any value from `count` up stands for "none has
//! the focus".

const assert = @import("std").debug.assert;

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
