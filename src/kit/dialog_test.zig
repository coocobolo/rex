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
const Outcome = dialog.Outcome;

const byte_width = 7;

fn fixedWidth(_: *anyopaque, bytes: []const u8, _: text.Style) f32 {
    return @floatFromInt(bytes.len * byte_width);
}

/// `fixedWidth` keeps no state.
var no_state: u8 = 0;
const measurer: text.Measurer = .{ .context = &no_state, .widthFn = fixedWidth };

/// The actions of `sample`, by index.
const stay = 0;
const close = 1;

const sample_actions = [_]dialog.Action{
    .{ .label = "Stay", .role = .dismiss, .key_cap = "Esc" },
    .{ .label = "Close", .variant = .destructive },
};

/// A quit prompt: an outline button that dismisses, then a destructive
/// one, which has the focus.
fn sample() dialog.Request {
    return .{ .title = "Close?", .body = "Running", .actions = &sample_actions, .focus = close };
}

const Fixture = struct {
    nodes: [dialog.node_max]tree_zig.Node = undefined,
    lines: [8]text.Line = undefined,

    fn tree(self: *Fixture) Tree {
        return .init(&self.nodes, &self.lines);
    }
};

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

test "dialog: enters, sits, leaves, and is gone" {
    var state: State = .empty;
    try testing.expectEqual(null, state.wakeMs());

    try testing.expectEqual(Outcome.redraw, update(&state, .{ .open = sample() }));
    try testing.expectEqual(dialog.Phase{ .entering = 0 }, state.phase);
    try testing.expectEqual(motion.frame_ms, state.wakeMs());
    // A second open while it is up does nothing.
    try testing.expectEqual(Outcome.quiet, update(&state, .{ .open = sample() }));

    try testing.expectEqual(Outcome.redraw, update(&state, .{ .tick = 100 }));
    try testing.expectEqual(dialog.Phase{ .entering = 100 }, state.phase);
    try testing.expectEqual(Outcome.redraw, update(&state, .{ .tick = 100 }));
    try testing.expectEqual(dialog.Phase.open, state.phase);
    try testing.expectEqual(null, state.wakeMs());
    try testing.expectEqual(Outcome.quiet, update(&state, .{ .tick = 1000 }));

    try testing.expectEqual(Outcome.redraw, update(&state, .dismiss));
    try testing.expectEqual(dialog.Phase{ .leaving = 0 }, state.phase);
    // Nothing is taken while it is leaving.
    try testing.expectEqual(Outcome.quiet, update(&state, .dismiss));
    try testing.expectEqual(Outcome.quiet, update(&state, .activate));
    try testing.expectEqual(Outcome.quiet, update(&state, .{ .take = close }));

    try testing.expectEqual(Outcome.redraw, update(&state, .{ .tick = 199 }));
    try testing.expectEqual(Outcome.closed, update(&state, .{ .tick = 1 }));
    try testing.expectEqual(dialog.Phase.closed, state.phase);
    try testing.expectEqual(null, state.wakeMs());
}

test "dialog: opened again while leaving, it comes back from where it was" {
    var state: State = .empty;
    _ = update(&state, .{ .open = sample() });
    _ = update(&state, .{ .tick = Theme.duration });
    _ = update(&state, .dismiss);
    _ = update(&state, .{ .tick = 50 });
    try testing.expectEqual(dialog.Phase{ .leaving = 50 }, state.phase);

    var again = sample();
    again.title = "Again?";
    again.focus = stay;
    try testing.expectEqual(Outcome.redraw, update(&state, .{ .open = again }));
    try testing.expectEqual(dialog.Phase{ .entering = 150 }, state.phase);
    try testing.expectEqualStrings("Again?", state.title());
    try testing.expectEqual(stay, state.focus);
    // The focused action dismisses, so it leaves from as far as it got.
    try testing.expectEqual(Outcome.redraw, update(&state, .activate));
    try testing.expectEqual(dialog.Phase{ .leaving = 50 }, state.phase);
}

test "dialog: with motion off it opens and closes at the next tick" {
    var state: State = .{ .motion = .none };
    try testing.expectEqual(Outcome.redraw, update(&state, .{ .open = sample() }));
    try testing.expectEqual(Outcome.redraw, update(&state, .{ .tick = 1 }));
    try testing.expectEqual(dialog.Phase.open, state.phase);

    var fixture: Fixture = .{};
    var tree = fixture.tree();
    try testing.expectEqual(Outcome.redraw, update(&state, .dismiss));
    // Leaving with motion off, it is already invisible.
    const scrim = (try dialog.view(&state, &tree, &Theme.dark)).?;
    try testing.expectEqual(0, tree.nodes[scrim].box.fill.a);
    try testing.expectEqual(Outcome.closed, update(&state, .{ .tick = 1 }));
}

test "dialog: choosing closes at once and says which, a dismiss button leaves" {
    var state: State = .empty;
    _ = update(&state, .{ .open = sample() });

    try testing.expectEqual(Outcome.redraw, update(&state, .{ .pointer = close }));
    try testing.expectEqual(Outcome.quiet, update(&state, .{ .pointer = close }));
    try testing.expectEqual(close, state.hover);
    // Off both buttons, and an index no button has.
    try testing.expectEqual(Outcome.redraw, update(&state, .{ .pointer = dialog.no_action }));
    try testing.expectEqual(Outcome.quiet, update(&state, .{ .pointer = 2 }));

    // Taking an action does not depend on the focus: a caller's shortcut,
    // such as the quit prompt's Y, sends this.
    _ = update(&state, .{ .focus = .next });
    try testing.expectEqual(stay, state.focus);
    try testing.expectEqual(Outcome{ .chosen = close }, update(&state, .{ .take = close }));
    try testing.expectEqual(dialog.Phase.closed, state.phase);

    _ = update(&state, .{ .open = sample() });
    try testing.expectEqual(Outcome{ .chosen = close }, update(&state, .activate));

    _ = update(&state, .{ .open = sample() });
    try testing.expectEqual(Outcome.redraw, update(&state, .{ .take = stay }));
    try testing.expect(state.phase == .leaving);
    // An action the dialog does not have.
    _ = update(&state, .{ .tick = Theme.duration });
    _ = update(&state, .{ .open = sample() });
    try testing.expectEqual(Outcome.quiet, update(&state, .{ .take = 2 }));
}

test "dialog: focus walks the row and wraps, and starts where asked" {
    const three = [_]dialog.Action{
        .{ .label = "Discard", .variant = .destructive },
        .{ .label = "Cancel", .role = .dismiss },
        .{ .label = "Save", .variant = .primary },
    };
    var state: State = .empty;
    _ = update(&state, .{ .open = .{ .title = "Save changes?", .actions = &three } });
    try testing.expectEqual(dialog.no_action, state.focus);
    // Nothing is taken until a button has the ring.
    try testing.expectEqual(Outcome.quiet, update(&state, .activate));

    try testing.expectEqual(Outcome.redraw, update(&state, .{ .focus = .next }));
    try testing.expectEqual(0, state.focus);
    _ = update(&state, .{ .focus = .next });
    _ = update(&state, .{ .focus = .next });
    try testing.expectEqual(2, state.focus);
    _ = update(&state, .{ .focus = .next });
    try testing.expectEqual(0, state.focus);
    _ = update(&state, .{ .focus = .previous });
    try testing.expectEqual(2, state.focus);
    try testing.expectEqual(Outcome{ .chosen = 2 }, update(&state, .activate));

    // Backwards into the row lands on its last button.
    _ = update(&state, .{ .open = .{ .title = "Save changes?", .actions = &three } });
    _ = update(&state, .{ .focus = .previous });
    try testing.expectEqual(2, state.focus);

    // One button: the focus has nowhere to go.
    state = .empty;
    _ = update(&state, .{ .open = .{ .title = "Done", .actions = &.{.{ .label = "OK", .variant = .primary }}, .focus = 0 } });
    try testing.expectEqual(Outcome.quiet, update(&state, .{ .focus = .next }));
    try testing.expectEqual(Outcome.quiet, update(&state, .{ .focus = .previous }));
    try testing.expectEqual(Outcome{ .chosen = 0 }, update(&state, .activate));
}

test "dialog: a click off the buttons drops the ring" {
    var state: State = .empty;
    _ = update(&state, .{ .open = sample() });
    _ = update(&state, .{ .tick = Theme.duration });
    try testing.expectEqual(close, state.focus);

    try testing.expectEqual(Outcome.redraw, update(&state, .blur));
    try testing.expectEqual(dialog.no_action, state.focus);
    try testing.expectEqual(dialog.Phase.open, state.phase);
    try testing.expectEqual(Outcome.quiet, update(&state, .blur));
    try testing.expectEqual(Outcome.quiet, update(&state, .activate));

    var fixture: Fixture = .{};
    var tree = fixture.tree();
    _ = try dialog.view(&state, &tree, &Theme.dark);
    const button = nodeById(&tree, dialog.actionId(close)).?;
    try testing.expectEqual(0, tree.nodes[button.parent].box.border.a);
    try testing.expectEqual(0, button.box.border.a);
}

test "dialog: the card is centered, actions run left to right, the ring is on the focus" {
    var state: State = .empty;
    _ = update(&state, .{ .open = sample() });
    // Fully in, so the scrim's alpha is the token's 50%.
    _ = update(&state, .{ .tick = Theme.duration });

    var fixture: Fixture = .{};
    var tree = fixture.tree();
    const scrim = (try dialog.view(&state, &tree, &Theme.dark)).?;
    try layout(&tree, measurer, 1000, 600);
    try testing.expectEqual(128, tree.nodes[scrim].box.fill.a);

    // 24 + 28 + 16 + 20 + 16 + 42 + 24 = 170 high; the key cap sits
    // inside the 36 px button. x = (1000 - 420) / 2, y = (600 - 170) / 2.
    const card = &tree.nodes[scrim + 1];
    try testing.expectEqual(dialog.card_id, card.box.id);
    try testing.expectEqual(tree_zig.Rect{ .x = 290, .y = 215, .w = dialog.width, .h = 170 }, card.rect);

    const stay_button = nodeById(&tree, dialog.actionId(stay)).?;
    const close_button = nodeById(&tree, dialog.actionId(close)).?;
    try testing.expect(close_button.rect.x > stay_button.rect.x);
    try testing.expectEqual(Theme.control, close_button.rect.h);
    try testing.expectEqual(Theme.dark.destructive, close_button.box.fill);
    try testing.expectEqual(Theme.dark.ring, close_button.box.border);
    try testing.expectEqual(Theme.Color.transparent, stay_button.box.fill);
    try testing.expectEqual(Theme.dark.input, stay_button.box.border);

    const esc = textByBytes(&tree, "Esc").?;
    try testing.expect(stay_button.rect.contains(esc.rect.x + 1, esc.rect.y + 1));
    try testing.expectEqual(Theme.dark.muted, tree.nodes[esc.parent].box.fill);
    // Only the button that names a key has a cap: 5 + 5 + 3 nodes.
    try testing.expectEqual(13, tree.len);

    // The ring slot is the button's parent. The focus started on Close.
    try testing.expect(tree.nodes[close_button.parent].box.border.a > 0);
    try testing.expectEqual(0, tree.nodes[stay_button.parent].box.border.a);

    try testing.expectEqual(dialog.Target{ .action = close }, dialog.hit(tree.hitTest(close_button.rect.x + 4, close_button.rect.y + 4)));
    try testing.expectEqual(dialog.Target{ .action = stay }, dialog.hit(tree.hitTest(stay_button.rect.x + 4, stay_button.rect.y + 4)));
    try testing.expectEqual(dialog.Target.card, dialog.hit(tree.hitTest(card.rect.x + 4, card.rect.y + 4)));
    try testing.expectEqual(dialog.Target.scrim, dialog.hit(tree.hitTest(4, 4)));
    try testing.expectEqual(null, dialog.hit(Id.none));
}

test "dialog: a window narrower than the card shrinks it and keeps a margin" {
    var state: State = .empty;
    _ = update(&state, .{ .open = sample() });

    var fixture: Fixture = .{};
    var tree = fixture.tree();
    const scrim = (try dialog.view(&state, &tree, &Theme.dark)).?;
    try layout(&tree, measurer, 360, 600);

    const card = tree.nodes[scrim + 1].rect;
    try testing.expectEqual(dialog.margin, card.x);
    try testing.expectEqual(360 - 2 * dialog.margin, card.w);
}

test "dialog: each variant has its look, and hover changes the fill" {
    const three = [_]dialog.Action{
        .{ .label = "Discard", .variant = .destructive },
        .{ .label = "Cancel", .role = .dismiss },
        .{ .label = "Save", .variant = .primary },
    };
    var state: State = .empty;
    _ = update(&state, .{ .open = .{ .title = "Save changes?", .actions = &three } });
    _ = update(&state, .{ .tick = Theme.duration });
    const theme = &Theme.light;

    var fixture: Fixture = .{};
    var tree = fixture.tree();
    _ = try dialog.view(&state, &tree, theme);
    try testing.expectEqual(theme.destructive, nodeById(&tree, dialog.actionId(0)).?.box.fill);
    try testing.expectEqual(Theme.Color.transparent, nodeById(&tree, dialog.actionId(1)).?.box.fill);
    try testing.expectEqual(theme.primary, nodeById(&tree, dialog.actionId(2)).?.box.fill);
    try testing.expectEqual(theme.primary_foreground, textByBytes(&tree, "Save").?.content.text.color);
    // Three buttons without key caps: 4 nodes before them (no body), 3 each.
    try testing.expectEqual(13, tree.len);

    _ = update(&state, .{ .pointer = 1 });
    tree.reset();
    _ = try dialog.view(&state, &tree, theme);
    try testing.expectEqual(theme.accent, nodeById(&tree, dialog.actionId(1)).?.box.fill);
    _ = update(&state, .{ .pointer = 2 });
    tree.reset();
    _ = try dialog.view(&state, &tree, theme);
    try testing.expectEqual(theme.primary.alpha(90), nodeById(&tree, dialog.actionId(2)).?.box.fill);
    try testing.expectEqual(Theme.Color.transparent, nodeById(&tree, dialog.actionId(1)).?.box.fill);
}

test "dialog: long texts are cut between code points, and its size" {
    var state: State = .empty;
    const long_label = "a" ** 47 ++ "\u{e9}tail";
    _ = update(&state, .{ .open = .{ .title = "t", .actions = &.{.{ .label = long_label, .key_cap = "Backspace" }} } });
    try testing.expectEqualStrings("a" ** 47, state.label(0));
    try testing.expectEqual(1, state.count);

    // Reported in the ticket: three buttons of 60 bytes and 256 of text.
    try testing.expectEqual(60, @sizeOf(@FieldType(State, "buttons")) / dialog.actions_max);
    try testing.expectEqual(446, @sizeOf(State));
}
