//! Tests for the pure color helpers in Frame.zig.

const std = @import("std");
const testing = std.testing;

const Frame = @import("Frame.zig");
const term = @import("../term/root.zig");
const test_option = @import("../term/test_fixtures.zig").test_option;

const Term = term.term.Terminal(test_option);

test "cellColors: SGR 7 and DECSCNM each swap, together they cancel" {
    var t = try Term.create(testing.allocator);
    defer t.destroy(testing.allocator);

    t.feed("\x1b]10;#111111\x07\x1b]11;#222222\x07A\x1b[7mB");
    const screen = t.active();
    const row = screen.row(0);
    const fg: [3]u8 = .{ 0x11, 0x11, 0x11 };
    const bg: [3]u8 = .{ 0x22, 0x22, 0x22 };

    try testing.expectEqual([2][3]u8{ fg, bg }, Frame.cellColors(&screen.palette, row[0], false));
    try testing.expectEqual([2][3]u8{ bg, fg }, Frame.cellColors(&screen.palette, row[1], false));
    try testing.expectEqual([2][3]u8{ bg, fg }, Frame.cellColors(&screen.palette, row[0], true));
    try testing.expectEqual([2][3]u8{ fg, bg }, Frame.cellColors(&screen.palette, row[1], true));
}

test "cursorColor: without OSC 12 the cursor is the default foreground" {
    var t = try Term.create(testing.allocator);
    defer t.destroy(testing.allocator);

    t.feed("\x1b]10;#111111\x07\x1b[31m");
    const screen = t.active();
    try testing.expectEqual([3]u8{ 0x11, 0x11, 0x11 }, Frame.cursorColor(&screen.palette, null));
    try testing.expectEqual([3]u8{ 1, 2, 3 }, Frame.cursorColor(&screen.palette, .{ 1, 2, 3 }));
}
