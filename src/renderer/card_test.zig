const std = @import("std");

const Card = @import("Card.zig");
const Instance = Card.Instance;
const Option = Card.Option;

test "Card: Instance layout is 64-byte cache-line sized and Option resolves sharp vs rounded radius" {
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(Instance));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(Instance, "col"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(Instance, "offset_x"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(Instance, "bg_color"));
    try std.testing.expectEqual(@as(usize, 32), @offsetOf(Instance, "border_color"));
    try std.testing.expectEqual(@as(usize, 48), @offsetOf(Instance, "radius"));
    try std.testing.expectEqual(@as(usize, 56), @offsetOf(Instance, "progress"));
    try std.testing.expectEqual(@as(usize, 60), @offsetOf(Instance, "kind"));

    const rounded_opt: Option = .{ .corner_radius = 10.0, .border_shape = .rounded };
    const sharp_opt: Option = .{ .corner_radius = 10.0, .border_shape = .sharp };
    try std.testing.expectEqual(@as(f32, 10.0), rounded_opt.effectiveRadius());
    try std.testing.expectEqual(@as(f32, 0.0), sharp_opt.effectiveRadius());
}
