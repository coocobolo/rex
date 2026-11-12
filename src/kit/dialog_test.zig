const std = @import("std");
const testing = std.testing;

const Theme = @import("Theme.zig");
const motion = @import("motion.zig");
const text = @import("text.zig");
const tree_zig = @import("tree.zig");
const Tree = tree_zig.Tree;
const Id = tree_zig.Id;
const layout = @import("layout.zig").layout;
const dialog = @import("dialog.zig");
const State = dialog.State;
const update = dialog.update;

const byte_width = 7;

fn fixedWidth(_: *anyopaque, bytes: []const u8, _: text.Style) f32 {
    return @floatFromInt(bytes.len * byte_width);
}

/// `fixedWidth` keeps no state.
var no_state: u8 = 0;
const measurer: text.Measurer = .{ .context = &no_state, .widthFn = fixedWidth };

fn sample() dialog.Request {
    return .{
        .title = "Close?",
        .body = "Running",
        .confirm_label = "Close",
        .cancel_label = "Stay",
    };
}

test "dialog: enters, sits, leaves, and is gone" {
    var state: State = .empty;
    try testing.expectEqual(null, state.wakeMs());

    try testing.expectEqual(.redraw, update(&state, .{ .open = sample() }));
    try testing.expectEqual(dialog.Phase{ .entering = 0 }, state.phase);
    try testing.expectEqual(motion.frame_ms, state.wakeMs());
    // A second open while it is up does nothing.
    try testing.expectEqual(.quiet, update(&state, .{ .open = sample() }));

    try testing.expectEqual(.redraw, update(&state, .{ .tick = 100 }));
    try testing.expectEqual(dialog.Phase{ .entering = 100 }, state.phase);
    try testing.expectEqual(.redraw, update(&state, .{ .tick = 100 }));
    try testing.expectEqual(dialog.Phase.open, state.phase);
    try testing.expectEqual(null, state.wakeMs());
    try testing.expectEqual(.quiet, update(&state, .{ .tick = 1000 }));

    try testing.expectEqual(.redraw, update(&state, .cancel));
    try testing.expectEqual(dialog.Phase{ .leaving = 0 }, state.phase);
    // Keys do nothing while it is leaving.
    try testing.expectEqual(.quiet, update(&state, .cancel));
    try testing.expectEqual(.quiet, update(&state, .activate));
    try testing.expectEqual(.quiet, update(&state, .{ .choose = .confirm }));

    try testing.expectEqual(.redraw, update(&state, .{ .tick = 199 }));
    try testing.expectEqual(.closed, update(&state, .{ .tick = 1 }));
    try testing.expectEqual(dialog.Phase.closed, state.phase);
    try testing.expectEqual(null, state.wakeMs());
}

test "dialog: opened again while leaving, it comes back from where it was" {
    var state: State = .empty;
    _ = update(&state, .{ .open = sample() });
    _ = update(&state, .{ .tick = Theme.duration });
    _ = update(&state, .cancel);
    _ = update(&state, .{ .tick = 50 });
    try testing.expectEqual(dialog.Phase{ .leaving = 50 }, state.phase);

    try testing.expectEqual(.redraw, update(&state, .{ .open = .{
        .title = "Again?",
        .confirm_label = "Close",
        .cancel_label = "Stay",
        .focus = .cancel,
    } }));
    try testing.expectEqual(dialog.Phase{ .entering = 150 }, state.phase);
    try testing.expectEqualStrings("Again?", state.title());
    try testing.expectEqual(dialog.Focus.cancel, state.focus);
    try testing.expectEqual(.redraw, update(&state, .activate));
    try testing.expectEqual(dialog.Phase{ .leaving = 50 }, state.phase);
}

test "dialog: confirm closes at once, focus swaps, hover redraws once" {
    var state: State = .empty;
    _ = update(&state, .{ .open = sample() });

    try testing.expectEqual(.redraw, update(&state, .{ .pointer = .confirm }));
    try testing.expectEqual(.quiet, update(&state, .{ .pointer = .confirm }));
    try testing.expectEqual(dialog.Action.confirm, state.hover.?);

    try testing.expectEqual(dialog.Focus.confirm, state.focus);
    try testing.expectEqual(.redraw, update(&state, .{ .focus = .next }));
    try testing.expectEqual(dialog.Focus.cancel, state.focus);
    try testing.expectEqual(.redraw, update(&state, .{ .focus = .previous }));
    try testing.expectEqual(dialog.Focus.confirm, state.focus);

    // Choosing confirm does not depend on focus. A caller shortcut such as
    // the quit prompt's Y sends this, rather than the kit knowing that key.
    _ = update(&state, .{ .focus = .next });
    try testing.expectEqual(.confirm, update(&state, .{ .choose = .confirm }));
    try testing.expectEqual(dialog.Phase.closed, state.phase);

    _ = update(&state, .{ .open = sample() });
    _ = update(&state, .{ .focus = .next });
    // Enter takes the focused action, which is now cancel, so it leaves.
    try testing.expectEqual(.redraw, update(&state, .activate));
    try testing.expect(state.phase == .leaving);
}

test "dialog: none draws no ring, and tab lands on a button" {
    var state: State = .empty;
    var request = sample();
    request.focus = .none;
    _ = update(&state, .{ .open = request });
    _ = update(&state, .{ .tick = Theme.duration });

    var nodes: [dialog.node_max]tree_zig.Node = undefined;
    var lines: [8]text.Line = undefined;
    var tree = Tree.init(&nodes, &lines);
    _ = try dialog.view(&state, &tree, &Theme.dark);
    const cancel = nodeById(&tree, dialog.Action.cancel.id()).?;
    const confirm = nodeById(&tree, dialog.Action.confirm.id()).?;
    try testing.expectEqual(@as(u8, 0), tree.nodes[cancel.parent].box.border.a);
    try testing.expectEqual(@as(u8, 0), tree.nodes[confirm.parent].box.border.a);
    try testing.expectEqual(@as(u8, 0), confirm.box.border.a);

    // Enter does nothing until a button has the ring.
    try testing.expectEqual(.quiet, update(&state, .activate));
    try testing.expectEqual(dialog.Phase.open, state.phase);

    try testing.expectEqual(.redraw, update(&state, .{ .focus = .next }));
    try testing.expectEqual(dialog.Focus.cancel, state.focus);
    // From a button either direction swaps, so this leaves confirm.
    try testing.expectEqual(.redraw, update(&state, .{ .focus = .previous }));
    try testing.expectEqual(dialog.Focus.confirm, state.focus);

    state = .empty;
    _ = update(&state, .{ .open = request });
    try testing.expectEqual(.redraw, update(&state, .{ .focus = .previous }));
    try testing.expectEqual(dialog.Focus.confirm, state.focus);
}

test "dialog: a click off the buttons drops the ring" {
    var state: State = .empty;
    _ = update(&state, .{ .open = sample() });
    _ = update(&state, .{ .tick = Theme.duration });
    try testing.expectEqual(dialog.Focus.confirm, state.focus);

    try testing.expectEqual(.redraw, update(&state, .blur));
    try testing.expectEqual(dialog.Focus.none, state.focus);
    try testing.expectEqual(dialog.Phase.open, state.phase);
    try testing.expectEqual(.quiet, update(&state, .blur));
    try testing.expectEqual(.quiet, update(&state, .activate));

    var nodes: [dialog.node_max]tree_zig.Node = undefined;
    var lines: [8]text.Line = undefined;
    var tree = Tree.init(&nodes, &lines);
    _ = try dialog.view(&state, &tree, &Theme.dark);
    const confirm = nodeById(&tree, dialog.Action.confirm.id()).?;
    try testing.expectEqual(@as(u8, 0), tree.nodes[confirm.parent].box.border.a);
    try testing.expectEqual(@as(u8, 0), confirm.box.border.a);
}

test "dialog: the card is centered, confirm is last, the ring is on the focus" {
    var state: State = .empty;
    _ = update(&state, .{ .open = sample() });
    // Fully in, so the scrim's alpha is the token's 50%.
    _ = update(&state, .{ .tick = Theme.duration });

    var nodes: [dialog.node_max]tree_zig.Node = undefined;
    var lines: [8]text.Line = undefined;
    var tree = Tree.init(&nodes, &lines);
    const scrim = (try dialog.view(&state, &tree, &Theme.dark)).?;
    try layout(&tree, measurer, 1000, 600);

    // 24+28+16+20+16+42+24 = 170. The Esc cap sits inside the 36px face.
    // x = (1000-420)/2, y = (600-170)/2.
    const card = &tree.nodes[scrim + 1];
    try testing.expectEqual(dialog.card_id, card.box.id);
    try testing.expectEqual(@as(f32, 290), card.rect.x);
    try testing.expectEqual(@as(f32, 215), card.rect.y);
    try testing.expectEqual(@as(f32, dialog.width), card.rect.w);
    try testing.expectEqual(@as(f32, 170), card.rect.h);

    const cancel = nodeById(&tree, dialog.Action.cancel.id()).?;
    const confirm = nodeById(&tree, dialog.Action.confirm.id()).?;
    try testing.expect(confirm.rect.x > cancel.rect.x);
    try testing.expectEqual(@as(f32, Theme.control), confirm.rect.h);
    try testing.expectEqual(Theme.dark.destructive, confirm.box.fill);
    try testing.expectEqual(Theme.dark.ring, confirm.box.border);
    try testing.expectEqual(Theme.Color.transparent, cancel.box.fill);
    try testing.expectEqual(Theme.dark.input, cancel.box.border);

    const esc = textByBytes(&tree, "Esc").?;
    try testing.expect(cancel.rect.contains(esc.rect.x + 1, esc.rect.y + 1));
    try testing.expectEqual(Theme.dark.muted, tree.nodes[esc.parent].box.fill);

    // The ring slot is the button's parent. Focus started on confirm.
    try testing.expect(tree.nodes[confirm.parent].box.border.a > 0);
    try testing.expectEqual(@as(u8, 0), tree.nodes[cancel.parent].box.border.a);

    try testing.expectEqual(dialog.Target.confirm, dialog.hit(tree.hitTest(confirm.rect.x + 4, confirm.rect.y + 4)));
    try testing.expectEqual(dialog.Target.cancel, dialog.hit(tree.hitTest(cancel.rect.x + 4, cancel.rect.y + 4)));
    try testing.expectEqual(dialog.Target.scrim, dialog.hit(tree.hitTest(4, 4)));
    try testing.expectEqual(null, dialog.hit(Id.none));
}

fn nodeById(tree: *const Tree, id: Id) ?*const tree_zig.Node {
    for (tree.items()) |*node| {
        if (node.box.id == id) return node;
    }
    return null;
}

fn textByBytes(tree: *const Tree, bytes: []const u8) ?*const tree_zig.Node {
    for (tree.items()) |*node| {
        switch (node.content) {
            .text => |t| if (std.mem.eql(u8, t.bytes, bytes)) return node,
            else => {},
        }
    }
    return null;
}
