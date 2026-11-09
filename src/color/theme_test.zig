const std = @import("std");

const Rgb = @import("Rgb.zig");
const graphite = @import("Theme.zig").graphite;

test "Theme: graphite preset sanity" {
    try std.testing.expectEqual(16, graphite.ansi.len);
    try std.testing.expectEqual(Rgb.white, graphite.foreground);
    try std.testing.expectEqual(Rgb.black, graphite.background);
}
