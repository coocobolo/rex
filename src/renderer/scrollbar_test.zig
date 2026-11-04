//! Tests for the scrollbar thumb geometry in Scrollbar.zig.

const std = @import("std");
const testing = std.testing;

const Thumb = @import("Scrollbar.zig").Thumb;

test "Thumb: height is the visible fraction of the track" {
    const thumb: Thumb = .of(1000, 1.0, 0.25, 20);
    try testing.expectEqual(250, thumb.height);
    try testing.expectEqual(750, thumb.top);
}

test "Thumb: never shorter than the minimum height" {
    // 24 rows of 10024: 2.4 px, raised to the 20 px minimum.
    const thumb: Thumb = .of(1000, 0.0, 24.0 / 10024.0, 20);
    try testing.expectEqual(20, thumb.height);
    try testing.expectEqual(0, thumb.top);
    try testing.expectEqual(980, thumb.travel(1000));
}

test "Thumb: never taller than the track" {
    const thumb: Thumb = .of(10, 0.5, 1.0, 20);
    try testing.expectEqual(10, thumb.height);
    try testing.expectEqual(0, thumb.top);
}

test "Thumb: topFracAt inverts the placement and clamps" {
    const thumb: Thumb = .of(1000, 0.5, 0.0, 20);
    try testing.expectEqual(490, thumb.top);
    try testing.expectEqual(0.5, thumb.topFracAt(1000, thumb.top));
    try testing.expectEqual(0.0, thumb.topFracAt(1000, -50));
    try testing.expectEqual(1.0, thumb.topFracAt(1000, 5000));
}

test "Thumb: a thumb that fills the track stays at the bottom" {
    const thumb: Thumb = .of(100, 0.0, 1.0, 20);
    try testing.expectEqual(1.0, thumb.topFracAt(100, 0));
}
