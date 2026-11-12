//! The motion every surface of the kit shares (ADR 0009, point 7): one
//! duration, `Theme.duration`, one curve, and the frame interval a surface
//! asks for while something is moving.

const Theme = @import("Theme.zig");

/// How often an animating surface wants a frame, in milliseconds.
pub const frame_ms = 16;

/// Whether surfaces animate (`[ui] motion`). With `none` every change is
/// instant: an enter or leave is over at the next tick and nothing glides.
pub const Mode = enum(u8) { full, none };

/// How long an enter or leave takes, in milliseconds.
pub fn duration(mode: Mode) u16 {
    return switch (mode) {
        .full => Theme.duration,
        .none => 0,
    };
}

/// How far an enter or leave that started `elapsed_ms` ago has come, from
/// 0 to 1, eased out (cubic): fast at first, settling at the end.
pub fn progress(mode: Mode, elapsed_ms: u16) f32 {
    switch (mode) {
        .none => return 1,
        .full => {
            const rest = 1 - @min(1, @as(f32, @floatFromInt(elapsed_ms)) / Theme.duration);
            return 1 - rest * rest * rest;
        },
    }
}

test progress {
    const testing = @import("std").testing;
    try testing.expectEqual(0, progress(.full, 0));
    try testing.expectEqual(0.875, progress(.full, Theme.duration / 2));
    try testing.expectEqual(1, progress(.full, Theme.duration));
    try testing.expectEqual(1, progress(.full, 60_000));
    try testing.expectEqual(1, progress(.none, 0));
    try testing.expectEqual(0, duration(.none));
}
