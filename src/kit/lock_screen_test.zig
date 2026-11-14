const std = @import("std");
const testing = std.testing;

const Theme = @import("Theme.zig");
const text = @import("text.zig");
const tree_zig = @import("tree.zig");
const Tree = tree_zig.Tree;
const layout = @import("layout.zig").layout;
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

    var nodes: [lock_screen.node_max]tree_zig.Node = undefined;
    var lines: [lock_screen.line_max]text.Line = undefined;
    var tree: Tree = .init(&nodes, &lines);
    try lock_screen.view(&state, &tree, &Theme.dark);
    try layout(&tree, measurer, 800, 600);

    const card = tree.find(lock_screen.card_id).?.rect;
    try testing.expectApproxEqAbs(lock_screen.width, card.w, 1);
    const unlock = tree.find(lock_screen.unlock_id).?.rect;
    try testing.expectEqual(lock_screen.Hit.unlock, state.hit(tree.hitTest(unlock.x + unlock.w / 2, unlock.y + unlock.h / 2)));
    try testing.expectEqual(lock_screen.Hit.card, state.hit(tree.hitTest(card.x + 8, card.y + 8)));
    try testing.expectEqual(lock_screen.Hit.scrim, state.hit(tree.hitTest(10, 10)));
}
