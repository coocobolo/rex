//! Tests for the scrollbar thumb geometry in Scrollbar.zig.

const std = @import("std");
const testing = std.testing;

const Scrollbar = @import("Scrollbar.zig");
const Fractions = Scrollbar.Fractions;
const Thumb = Scrollbar.Thumb;

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

test "Fractions: visible share and scroll position" {
    const fracs: Fractions = .of(25, 100, 25);
    try testing.expectEqual(0.2, fracs.height);
    try testing.expectEqual(0.75, fracs.top);
    try testing.expectEqual(1.0, Fractions.of(25, 75, 0).top);
    try testing.expectEqual(0.0, Fractions.of(25, 75, 75).top);
}

test "Fractions: empty scrollback fills the track at the bottom" {
    // A drag after the scrollback is cleared must not divide by zero.
    const fracs: Fractions = .of(24, 0, 10);
    try testing.expectEqual(1.0, fracs.height);
    try testing.expectEqual(1.0, fracs.top);
    try testing.expectEqual(1.0, Fractions.of(0, 0, 0).height);

    const thumb: Thumb = .of(500, fracs.top, fracs.height, 20);
    try testing.expectEqual(0, thumb.travel(500));
    try testing.expectEqual(0, Fractions.viewportOffsetAt(thumb.topFracAt(500, 123), 0));
}

test "Fractions: an offset past the scrollback is clamped" {
    try testing.expectEqual(0.0, Fractions.of(24, 10, 40).top);
}

test "Fractions: viewportOffsetAt inverts top and clamps" {
    try testing.expectEqual(0, Fractions.viewportOffsetAt(1.0, 100));
    try testing.expectEqual(100, Fractions.viewportOffsetAt(0.0, 100));
    try testing.expectEqual(50, Fractions.viewportOffsetAt(0.5, 100));
    try testing.expectEqual(100, Fractions.viewportOffsetAt(-3.0, 100));
    try testing.expectEqual(0, Fractions.viewportOffsetAt(7.0, 100));
}
