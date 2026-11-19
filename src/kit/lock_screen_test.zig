const std = @import("std");
const testing = std.testing;

const Theme = @import("Theme.zig");
const text = @import("text.zig");
const Tree = @import("Tree.zig");
const lock_screen = @import("lock_screen.zig");

const byte_width = 7;

fn fixedWidth(_: *anyopaque, bytes: []const u8, _: text.Style, _: text.Figures) f32 {
    return @floatFromInt(bytes.len * byte_width);
}

var no_state: u8 = 0;
const measurer: text.Measurer = .{ .context = &no_state, .widthFn = fixedWidth };

const sample: lock_screen.Request = .{
    .tone = .healthy,
    .title = "Break in progress",
    .subtitle = "Short Rest Break",
    .prompt = "Roll your shoulders backward.",
    .remaining_s = 125,
    .total_s = 300,
    .steps_total = 4,
    .steps_done = 2,
    .scrim_alpha = 128,
};

test "lock_screen: sync opens once, ignores identical updates, unlocks on button release" {
    var state: lock_screen.State = .empty;
    try testing.expectEqual(lock_screen.Outcome.redraw, lock_screen.update(&state, .{ .sync = sample }));
    try testing.expect(state.isShown());
    try testing.expect(state.acceptsInput());
    try testing.expectEqualStrings("02:05", state.timeText());
    try testing.expectEqual(lock_screen.Outcome.redraw, lock_screen.update(&state, .{ .tick = Theme.duration }));
    try testing.expectEqual(null, state.wakeMs());

    // Same snapshot causes no redraw.
    try testing.expectEqual(lock_screen.Outcome.quiet, lock_screen.update(&state, .{ .sync = sample }));

    // Next second updates countdown and asks for redraw.
    var next = sample;
    next.remaining_s = 124;
    try testing.expectEqual(lock_screen.Outcome.redraw, lock_screen.update(&state, .{ .sync = next }));
    try testing.expectEqualStrings("02:04", state.timeText());

    // Pressing and releasing on unlock reports unlocked.
    try testing.expectEqual(lock_screen.Outcome.redraw, lock_screen.update(&state, .press));
    try testing.expectEqual(lock_screen.Outcome.unlocked, lock_screen.update(&state, .{ .release = .unlock }));

    // Closing fades out and immediately stops accepting input.
    try testing.expectEqual(lock_screen.Outcome.redraw, lock_screen.update(&state, .close));
    try testing.expect(state.isShown());
    try testing.expect(!state.acceptsInput());
    try testing.expectEqual(lock_screen.Outcome.redraw, lock_screen.update(&state, .{ .tick = Theme.duration }));
    try testing.expect(!state.isShown());
}

test "lock_screen: view fits nodes, centers card, and hit-tests scrim vs card vs unlock button" {
    var state: lock_screen.State = .empty;
    _ = lock_screen.update(&state, .{ .sync = sample });
    _ = lock_screen.update(&state, .{ .tick = Theme.duration });

    var nodes: [lock_screen.node_max]Tree.Node = undefined;
    var lines: [lock_screen.line_max]text.Line = undefined;
    var tree: Tree = .init(&nodes, &lines);
    try lock_screen.view(&state, &tree, &Theme.dark);
    try tree.layout(measurer, 800, 600);

    const card = tree.find(lock_screen.card_id).?.rect;
    try testing.expectApproxEqAbs(lock_screen.width, card.w, 1);
    const unlock = tree.find(lock_screen.unlock_id).?.rect;
    try testing.expectEqual(lock_screen.Hit.unlock, state.hit(tree.hitTest(unlock.x + unlock.w / 2, unlock.y + unlock.h / 2)));
    try testing.expectEqual(lock_screen.Hit.card, state.hit(tree.hitTest(card.x + 8, card.y + 8)));
    try testing.expectEqual(lock_screen.Hit.scrim, state.hit(tree.hitTest(10, 10)));
}

test "lock_screen: blur drops keyboard activation until focus restores it" {
    var state: lock_screen.State = .empty;
    _ = lock_screen.update(&state, .{ .sync = sample });
    _ = lock_screen.update(&state, .{ .tick = Theme.duration });
    try testing.expect(state.focused);

    try testing.expectEqual(lock_screen.Outcome.redraw, lock_screen.update(&state, .blur));
    try testing.expect(!state.focused);
    try testing.expectEqual(lock_screen.Outcome.quiet, lock_screen.update(&state, .activate));

    try testing.expectEqual(lock_screen.Outcome.redraw, lock_screen.update(&state, .focus));
    try testing.expectEqual(lock_screen.Outcome.quiet, lock_screen.update(&state, .focus));
    try testing.expect(state.focused);
    try testing.expectEqual(lock_screen.Outcome.unlocked, lock_screen.update(&state, .activate));
}

test "lock_screen: hud layout anchors at bottom with transparent scrim and dismiss action" {
    var req = sample;
    req.layout = .hud;
    req.action = .dismiss;

    var state: lock_screen.State = .empty;
    try testing.expectEqual(lock_screen.Outcome.redraw, lock_screen.update(&state, .{ .sync = req }));
    _ = lock_screen.update(&state, .{ .tick = Theme.duration });

    var nodes: [lock_screen.node_max]Tree.Node = undefined;
    var lines: [lock_screen.line_max]text.Line = undefined;
    var tree: Tree = .init(&nodes, &lines);
    try lock_screen.view(&state, &tree, &Theme.dark);
    try tree.layout(measurer, 800, 600);

    const scrim = tree.find(lock_screen.scrim_id).?;
    try testing.expectEqual(@as(u8, 0), scrim.box.fill.a);

    const bar = tree.find(lock_screen.card_id).?.rect;
    // Bottom-anchored HUD sits near the bottom edge leaving the center open.
    try testing.expect(bar.y > 460);
    try testing.expect(bar.w <= lock_screen.hud_max_width + 1);
    const dismiss = tree.find(lock_screen.unlock_id).?.rect;
    try testing.expectEqual(lock_screen.Hit.unlock, state.hit(tree.hitTest(dismiss.x + dismiss.w / 2, dismiss.y + dismiss.h / 2)));
    try testing.expectEqual(lock_screen.Hit.scrim, state.hit(tree.hitTest(400, 200)));

    // On narrow viewports, the HUD stacks vertically and keeps the button inside the bar.
    tree.reset();
    try lock_screen.viewIn(&state, &tree, &Theme.dark, 220);
    try tree.layout(measurer, 220, 600);
    const narrow_bar = tree.find(lock_screen.card_id).?;
    const narrow_btn = tree.find(lock_screen.unlock_id).?.rect;
    try testing.expectEqual(Tree.Axis.column, narrow_bar.box.axis);
    try testing.expect(narrow_btn.x >= narrow_bar.rect.x);
    try testing.expect(narrow_btn.x + narrow_btn.w <= narrow_bar.rect.x + narrow_bar.rect.w + 0.5);
}
