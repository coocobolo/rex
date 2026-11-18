//! Layout regression for the X11 backend's shared state. Selection data is
//! buffered at the terminal's OSC 52 limit, so a silent size change would
//! either overflow a fixed slot or waste megabytes.

const std = @import("std");
const testing = std.testing;

const backend = @import("backend.zig");
const X11Window = @import("X11Window.zig");

test "X11 backend state layout" {
    try testing.expectEqual(@as(usize, 3_145_824), @sizeOf(X11Window));
    try testing.expectEqual(@as(usize, 8), @alignOf(X11Window));
    try testing.expectEqual(@as(usize, 32), @offsetOf(X11Window, "cursors"));
    try testing.expectEqual(@as(usize, 92), @offsetOf(X11Window, "clipboard_text"));

    const State = @TypeOf(backend.state);
    try testing.expectEqual(@as(usize, 25_181_536), @sizeOf(State));
    try testing.expectEqual(@as(usize, 8), @alignOf(State));
    try testing.expectEqual(@as(usize, 14_872), @offsetOf(State, "window_slots"));
}
