const std = @import("std");
const testing = std.testing;

const backend = @import("backend.zig");
const seat = @import("seat.zig");
const WaylandWindow = @import("WaylandWindow.zig");

test "WaylandWindow and backend state layout stay compact and aligned" {
    try testing.expectEqual(@as(usize, 8), @alignOf(WaylandWindow));
    // 10 pointers (80B) + 5x 4-byte scalars (20B) + 6x 1-byte flags/enums (6B) + 6B tail padding = 112B.
    try testing.expectEqual(@as(usize, 112), @sizeOf(WaylandWindow));
    try testing.expectEqual(@as(usize, 0), @offsetOf(WaylandWindow, "wl_surface"));
    try testing.expectEqual(@as(usize, 80), @offsetOf(WaylandWindow, "logical_width"));

    try testing.expectEqual(@as(usize, 8), @alignOf(seat.Seat));
    try testing.expect(@sizeOf(seat.Seat) <= 160);

    const State = @TypeOf(backend.state);
    try testing.expectEqual(@as(usize, 8), @alignOf(State));
    // Selection buffers live separately in .bss so backend.state stays small.
    try testing.expect(@sizeOf(State) < 20_000);
}
