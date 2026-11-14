const std = @import("std");
const testing = std.testing;

const host = @import("host.zig");

test "host: a wheel notch down scrolls the content one step up" {
    try testing.expectEqual(@as(f32, host.scroll_step), host.scrollDelta(-1));
    try testing.expectEqual(@as(f32, -host.scroll_step), host.scrollDelta(1));
    // A touchpad's fraction of a notch.
    try testing.expectEqual(@as(f32, host.scroll_step) / 4, host.scrollDelta(-0.25));
}
