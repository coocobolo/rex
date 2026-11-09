const std = @import("std");

const Button = @import("Button.zig");
const Request = Button.Request;
const Style = Button.Style;

test "Button: request initialization" {
    const testing = std.testing;
    const req: Request = .{
        .col = 5,
        .row = 10,
        .width = 20,
        .label = "Confirm",
        .shortcut = "Enter",
        .style = .danger,
        .focused = true,
        .action = .{ .button = 1 },
    };
    try testing.expectEqual(@as(u16, 5), req.col);
    try testing.expectEqual(@as(u16, 10), req.row);
    try testing.expectEqual(@as(u16, 20), req.width);
    try testing.expect(req.focused);
    try testing.expectEqual(Style.danger, req.style);
}
