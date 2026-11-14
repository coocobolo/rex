const std = @import("std");
const testing = std.testing;

const Theme = @import("Theme.zig");
const text = @import("text.zig");
const tree_zig = @import("tree.zig");
const Tree = tree_zig.Tree;
const layout = @import("layout.zig").layout;
const alert = @import("alert.zig");

const byte_width = 7;

fn fixedWidth(_: *anyopaque, bytes: []const u8, _: text.Style, _: text.Figures) f32 {
    return @floatFromInt(bytes.len * byte_width);
}

var no_state: u8 = 0;
const measurer: text.Measurer = .{ .context = &no_state, .widthFn = fixedWidth };

test "alert: stays open until dismissed, fades in and out with motion" {
    var state: alert.State = .empty;
    try testing.expectEqual(null, state.wakeMs());

    try testing.expect(alert.update(&state, .{ .show = .{
        .kind = .err,
        .title = "Config error (line 4, col 2)",
        .description = "unknown key",
    } }));
    try testing.expect(state.isShown());
    try testing.expectEqual(16, state.wakeMs());

    // Finish entering; stays open with no wakeups needed.
    try testing.expect(alert.update(&state, .{ .tick = Theme.duration }));
    try testing.expectEqual(null, state.wakeMs());
    try testing.expect(state.isShown());

    // Showing the exact same alert again is a no-op.
    try testing.expect(!alert.update(&state, .{ .show = .{
        .kind = .err,
        .title = "Config error (line 4, col 2)",
        .description = "unknown key",
    } }));

    // Updating the description returns true so the new text renders.
    try testing.expect(alert.update(&state, .{ .show = .{
        .kind = .warn,
        .title = "Config warning",
        .description = "deprecated key",
    } }));

    // Dismiss fades out and closes.
    try testing.expect(alert.update(&state, .dismiss));
    try testing.expect(!state.isShown());
    try testing.expectEqual(16, state.wakeMs());
    try testing.expect(alert.update(&state, .{ .tick = Theme.duration }));
    try testing.expectEqual(null, state.wakeMs());
}

test "alert: pointer release on close dismisses; release away keeps open" {
    var state: alert.State = .empty;
    _ = alert.update(&state, .{ .show = .{ .kind = .err, .title = "Error" } });
    _ = alert.update(&state, .{ .tick = Theme.duration });

    try testing.expect(alert.update(&state, .{ .pointer = .close }));
    try testing.expect(alert.update(&state, .press));
    try testing.expect(alert.update(&state, .{ .release = .away }));
    try testing.expect(state.isShown());

    try testing.expect(alert.update(&state, .press));
    try testing.expect(alert.update(&state, .{ .release = .close }));
    try testing.expect(!state.isShown());
}

test "alert: view centers at top, slides during enter, and hit-tests close button" {
    var state: alert.State = .empty;
    _ = alert.update(&state, .{ .show = .{
        .kind = .err,
        .title = "Config error",
        .description = "expected integer",
    } });
    _ = alert.update(&state, .{ .tick = Theme.duration / 2 });

    var nodes: [alert.node_max]tree_zig.Node = undefined;
    var lines: [alert.line_max]text.Line = undefined;
    var tree: Tree = .init(&nodes, &lines);
    const root = (try alert.view(&state, &tree, &Theme.dark)).?;
    try layout(&tree, measurer, 800, 600);
    const before_y = tree.find(alert.card_id).?.rect.y;
    alert.place(&state, &tree, root);
    const after_y = tree.find(alert.card_id).?.rect.y;
    try testing.expect(after_y < before_y);

    const card = tree.find(alert.card_id).?.rect;
    try testing.expect(card.w <= alert.max_width);
    try testing.expectApproxEqAbs((800 - card.w) / 2, card.x, 1);

    const close = tree.find(alert.close_id).?.rect;
    try testing.expectEqual(alert.Hit.close, state.hit(tree.hitTest(close.x + close.w / 2, close.y + close.h / 2)));
    try testing.expectEqual(alert.Hit.card, state.hit(tree.hitTest(card.x + 8, card.y + 8)));
    try testing.expectEqual(alert.Hit.none, state.hit(tree.hitTest(10, 500)));
}

test "alert: with motion none transitions are instant" {
    var state: alert.State = .empty;
    state.motion = .none;
    try testing.expect(alert.update(&state, .{ .show = .{ .kind = .info, .title = "Info" } }));
    try testing.expectEqual(null, state.wakeMs());
    try testing.expect(state.isShown());

    try testing.expect(alert.update(&state, .dismiss));
    try testing.expectEqual(null, state.wakeMs());
    try testing.expect(!state.isShown());
}
