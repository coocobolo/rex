const std = @import("std");

const color = @import("color.zig");
const Color = color.Color;

test "Color: fromRgb and sizeOf" {
    const c = Color.fromRgb(10, 20, 30);
    try std.testing.expectEqual(Color{ .rgb = .{ .r = 10, .g = 20, .b = 30 } }, c);
    try std.testing.expectEqual(4, @sizeOf(Color));
}
