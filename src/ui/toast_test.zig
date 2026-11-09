const std = @import("std");

const Toast = @import("Toast.zig");
const HitPart = Toast.HitPart;
const Queue = Toast.Queue;
const ToastQueue = Toast.ToastQueue;
const computeLayout = Toast.computeLayout;

test "ToastQueue: push, vertical stacking, countdown tick, expiration, and hit testing" {
    const testing = std.testing;

    var queue: Queue = .{};
    try testing.expect(!queue.isActive());

    const id1 = queue.push(.{
        .title = "Copied to clipboard",
        .description = "128 bytes copied.",
        .variant = .success,
    }, 3000);
    try testing.expect(queue.isActive());
    try testing.expectEqual(@as(usize, 1), queue.count);
    try testing.expect(queue.tick(0)); // consumes dirty flag

    const id2 = queue.push(.{
        .title = "Font size: 14pt",
        .action_shortcut = "Ctrl+0",
        .action_label = "Reset",
        .countdown_s = 5,
        .variant = .info,
    }, 5000);
    try testing.expectEqual(@as(usize, 2), queue.count);
    // Newest toast is at index 0
    try testing.expectEqual(id2, queue.entries[0].id);
    try testing.expectEqual(id1, queue.entries[1].id);

    // Hit test top toast (id2) on a 100x40 grid
    const layout0 = computeLayout(queue.entries[0].toRequest(), 100, 40, 0);
    const hit_dismiss = queue.hitTest(layout0.dismiss_col, layout0.dismiss_row, 100, 40, 0);
    try testing.expect(hit_dismiss != null);
    try testing.expectEqual(id2, hit_dismiss.?.id);
    try testing.expectEqual(HitPart.dismiss, hit_dismiss.?.part);

    const hit_action = queue.hitTest(layout0.action_col, layout0.action_row, 100, 40, 0);
    try testing.expect(hit_action != null);
    try testing.expectEqual(id2, hit_action.?.id);
    try testing.expectEqual(HitPart.action, hit_action.?.part);

    // Hit test second stacked toast (id1) below first toast
    const layout1 = computeLayout(queue.entries[1].toRequest(), 100, 40, layout0.height + 1);
    const hit_second = queue.hitTest(layout1.col + 1, layout1.row + 1, 100, 40, 0);
    try testing.expect(hit_second != null);
    try testing.expectEqual(id1, hit_second.?.id);
    try testing.expectEqual(HitPart.body, hit_second.?.part);

    // Advance 3000ms: id1 (3000ms) expires, id2 (5000ms -> 2000ms) remains
    try testing.expect(queue.tick(3000));
    try testing.expectEqual(@as(usize, 1), queue.count);
    try testing.expectEqual(id2, queue.entries[0].id);
    try testing.expectEqual(@as(?u32, 2), queue.entries[0].toRequest().countdown_s);

    // Dismiss id2 explicitly
    try testing.expect(queue.dismiss(id2));
    try testing.expect(!queue.isActive());

    // Push beyond max_active (rapid font zoom scenario) without integer overflow
    for (0..8) |_| {
        _ = queue.push(.{ .title = "Font: 12pt" }, 3000);
    }
    try testing.expectEqual(Queue.max_active, queue.count);
}
