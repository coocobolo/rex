//! The motion every surface of the kit shares (ADR 0009, point 7): one
//! duration, `Theme.duration`, one curve, and the frame interval a surface
//! asks for while something is moving.

const Theme = @import("Theme.zig");

/// How often an animating surface wants a frame, in milliseconds.
pub const frame_ms = 16;

/// How far an enter or leave that started `elapsed_ms` ago has come, from
/// 0 to 1, eased out (cubic): fast at first, settling at the end.
pub fn progress(elapsed_ms: u16) f32 {
    const rest = 1 - @min(1, @as(f32, @floatFromInt(elapsed_ms)) / Theme.duration);
    return 1 - rest * rest * rest;
}

test progress {
    const testing = @import("std").testing;
    try testing.expectEqual(0, progress(0));
    try testing.expectEqual(0.875, progress(Theme.duration / 2));
    try testing.expectEqual(1, progress(Theme.duration));
    try testing.expectEqual(1, progress(60_000));
}
