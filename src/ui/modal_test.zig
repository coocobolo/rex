const std = @import("std");

const Modal = @import("Modal.zig");
const Action = Modal.Action;
const HitResult = Modal.HitResult;
const Option = Modal.Option;
const Request = Modal.Request;
const computeLayout = Modal.computeLayout;
const hitTest = Modal.hitTest;
const hitTestLayout = Modal.hitTestLayout;

test "Modal: computeLayout and hitTest on centered confirmation dialog" {
    const testing = std.testing;

    const actions = [_]Action{
        .{ .shortcut = "Enter / Y", .label = "Quit terminal" },
        .{ .shortcut = "Esc / N", .label = "Cancel and stay" },
    };
    const req: Request = .{
        .title = "QUIT TERMINAL?",
        .line1 = "Active terminal session is still running.",
        .line2 = "Close this window and terminate the session?",
        .actions = &actions,
    };

    const layout = computeLayout(req, 80, 24).?;
    try testing.expectEqual(@as(u16, 46), layout.width);
    try testing.expectEqual(@as(u16, 9), layout.height);
    try testing.expectEqual(@as(u16, 17), layout.col);
    try testing.expectEqual(@as(u16, 7), layout.row);
    try testing.expectEqual(@as(u16, 13), layout.actions_start_row);
    try testing.expectEqual(@as(u8, 2), layout.action_count);

    // Click outside modal bounds
    try testing.expectEqual(HitResult.outside, hitTestLayout(layout, 2, 2));

    // Click inside modal header/body
    try testing.expectEqual(HitResult.body, hitTestLayout(layout, 25, 9));

    // Click first action row (Quit terminal)
    try testing.expectEqual(HitResult{ .action = 0 }, hitTestLayout(layout, 25, 13));

    // Click second action row (Cancel and stay)
    try testing.expectEqual(HitResult{ .action = 1 }, hitTestLayout(layout, 25, 14));
}

test "Modal: backdropAlpha round-trips bytes and clamps" {
    try std.testing.expectEqual(180, (Option{}).backdropAlpha());
    try std.testing.expectEqual(10, (Option{ .backdrop_opacity = 10.0 / 255.0 }).backdropAlpha());
    try std.testing.expectEqual(255, (Option{ .backdrop_opacity = 2 }).backdropAlpha());
    try std.testing.expectEqual(0, (Option{ .backdrop_opacity = -1 }).backdropAlpha());
    try std.testing.expectEqual(0, (Option{ .backdrop_opacity = std.math.nan(f32) }).backdropAlpha());
}
