const std = @import("std");
const testing = std.testing;

const WaylandWindow = @import("WaylandWindow.zig");

test "WaylandWindow layout stays compact and aligned" {
    try testing.expectEqual(@as(usize, 8), @alignOf(WaylandWindow));
    // 8 pointers (64B) + 5x 4-byte scalars (20B) + 6x 1-byte flags/enums (6B) + 6B tail padding = 96B.
    try testing.expectEqual(@as(usize, 96), @sizeOf(WaylandWindow));
    try testing.expectEqual(@as(usize, 0), @offsetOf(WaylandWindow, "wl_surface"));
    try testing.expectEqual(@as(usize, 64), @offsetOf(WaylandWindow, "logical_width"));
}
