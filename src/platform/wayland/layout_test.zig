//! Layout assertions for the pinned Wayland backend structs.

const std = @import("std");
const testing = std.testing;

const backend = @import("backend.zig");
const seat = @import("seat.zig");
const text_input = @import("text_input.zig");
const WaylandWindow = @import("WaylandWindow.zig");

test "WaylandWindow and backend state layout stay compact and aligned" {
    try testing.expectEqual(@as(usize, 8), @alignOf(WaylandWindow));
    // 10 pointers (80B) + 5x 4-byte scalars (20B) + 6x 1-byte flags/enums (6B) + 6B tail padding = 112B.
    try testing.expectEqual(@as(usize, 112), @sizeOf(WaylandWindow));
    try testing.expectEqual(@as(usize, 0), @offsetOf(WaylandWindow, "wl_surface"));
    try testing.expectEqual(@as(usize, 80), @offsetOf(WaylandWindow, "logical_width"));

    try testing.expectEqual(@as(usize, 8), @alignOf(seat.Seat));
    // 8 pointers (64B) + optional 16B scroll payload (24B) + 40B scalars/flags
    // + 16B key bitset = 144B.
    try testing.expectEqual(@as(usize, 144), @sizeOf(seat.Seat));

    try testing.expectEqual(@as(usize, 8), @alignOf(text_input.TextInput));
    // Two optionals (36B preedit + 130B commit) plus 2 pointers and a flag.
    try testing.expectEqual(@as(usize, 184), @sizeOf(text_input.TextInput));

    const State = @TypeOf(backend.state);
    try testing.expectEqual(@as(usize, 8), @alignOf(State));
    // Selection buffers live separately in .bss so backend.state stays small.
    try testing.expectEqual(@as(usize, 16_312), @sizeOf(State));
}
