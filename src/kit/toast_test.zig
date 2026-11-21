const std = @import("std");
const testing = std.testing;

const Theme = @import("Theme.zig");
const text = @import("text.zig");
const Tree = @import("Tree.zig");
const memory = @import("memory.zig");
const toast = @import("toast.zig");
const State = toast.State;
const update = toast.update;

const byte_width = 7;

fn fixedWidth(_: *anyopaque, bytes: []const u8, _: text.Style, _: text.Figures) f32 {
    return @floatFromInt(bytes.len * byte_width);
}

/// `fixedWidth` keeps no state.
var no_state: u8 = 0;
const measurer: text.Measurer = .{ .context = &no_state, .widthFn = fixedWidth };

fn push(state: *State, title: []const u8) bool {
    return update(state, .{ .push = .{ .title = title, .duration_ms = 4000 } });
}

/// Pushes a toast and runs its entrance to the end.
fn show(state: *State, title: []const u8) void {
    _ = push(state, title);
    _ = update(state, .{ .tick = Theme.duration });
}

fn phases(state: *const State, buffer: *[toast.capacity]std.meta.Tag(toast.Phase)) []const std.meta.Tag(toast.Phase) {
    for (state.entries[0..state.len], buffer[0..state.len]) |entry, *tag| tag.* = entry.phase;
    return buffer[0..state.len];
}

fn expectPhases(state: *const State, expected: []const std.meta.Tag(toast.Phase)) !void {
    var buffer: [toast.capacity]std.meta.Tag(toast.Phase) = undefined;
    try testing.expectEqualSlices(std.meta.Tag(toast.Phase), expected, phases(state, &buffer));
}

test "toast: enters, stays for its duration, leaves and is gone" {
    var state: State = .empty;
    try testing.expectEqual(null, state.wakeMs());

    try testing.expect(push(&state, "Copied"));
    try expectPhases(&state, &.{.entering});
    try testing.expectEqual(16, state.wakeMs());

    try testing.expect(update(&state, .{ .tick = 100 }));
    try testing.expectEqual(toast.Phase{ .entering = 100 }, state.entries[0].phase);
    try testing.expect(update(&state, .{ .tick = 100 }));
    try testing.expectEqual(toast.Phase{ .shown = 4000 }, state.entries[0].phase);
    try testing.expectEqual(4000, state.wakeMs());

    // Counting down is not a change to draw.
    try testing.expect(!update(&state, .{ .tick = 1500 }));
    try testing.expectEqual(2500, state.wakeMs());

    try testing.expect(update(&state, .{ .tick = 2500 }));
    try expectPhases(&state, &.{.leaving});
    try testing.expect(update(&state, .{ .tick = 199 }));
    try expectPhases(&state, &.{.leaving});
    try testing.expect(update(&state, .{ .tick = 1 }));
    try testing.expectEqual(0, state.len);
    try testing.expectEqual(null, state.wakeMs());
    try testing.expect(!update(&state, .{ .tick = 1000 }));
}

test "toast: the pointer over the stack holds the timers, not the motion" {
    var state: State = .{ .option = .{ .layout = .expanded } };
    show(&state, "first");
    _ = push(&state, "second");

    try testing.expect(!update(&state, .{ .pointer = .over }));
    // The second one still finishes entering.
    try testing.expectEqual(16, state.wakeMs());
    try testing.expect(update(&state, .{ .tick = Theme.duration }));
    try expectPhases(&state, &.{ .shown, .shown });

    try testing.expectEqual(null, state.wakeMs());
    try testing.expect(!update(&state, .{ .tick = 60_000 }));
    try testing.expectEqual(toast.Phase{ .shown = 4000 }, state.entries[0].phase);

    try testing.expect(!update(&state, .{ .pointer = .away }));
    try testing.expectEqual(4000, state.wakeMs());
    try testing.expect(!update(&state, .{ .tick = 1000 }));
    try testing.expectEqual(3000, state.wakeMs());
}

test "toast: a fourth waits until one of three has left" {
    var state: State = .empty;
    for ([_][]const u8{ "one", "two", "three" }) |title| show(&state, title);
    // Nothing on screen changes when the fourth is pushed.
    try testing.expect(!push(&state, "four"));
    try expectPhases(&state, &.{ .shown, .shown, .shown, .waiting });
    try testing.expectEqual(3, state.visible().len);

    try testing.expect(update(&state, .{ .dismiss = state.entries[1].serial }));
    try expectPhases(&state, &.{ .shown, .leaving, .shown, .waiting });
    try testing.expect(update(&state, .{ .tick = Theme.duration }));
    try expectPhases(&state, &.{ .shown, .shown, .entering });
    try testing.expectEqualStrings("four", state.entries[2].title());
}

test "toast: dismissing" {
    var state: State = .empty;
    for ([_][]const u8{ "one", "two", "three" }) |title| show(&state, title);
    _ = push(&state, "four");
    _ = push(&state, "five");

    // A waiting toast goes without a trace on screen.
    try testing.expect(!update(&state, .{ .dismiss = state.entries[4].serial }));
    try testing.expectEqual(4, state.len);
    // An unknown serial and a toast already leaving change nothing.
    try testing.expect(!update(&state, .{ .dismiss = 999 }));
    try testing.expect(update(&state, .{ .dismiss = state.entries[0].serial }));
    try testing.expect(!update(&state, .{ .dismiss = state.entries[0].serial }));

    try testing.expect(update(&state, .dismiss_all));
    try expectPhases(&state, &.{ .leaving, .leaving, .leaving });
    try testing.expect(!update(&state, .dismiss_all));
    try testing.expect(update(&state, .{ .tick = Theme.duration }));
    try testing.expectEqual(0, state.len);
}

test "toast: dismissed while entering, it leaves from as far as it got" {
    var state: State = .empty;
    _ = push(&state, "brief");
    _ = update(&state, .{ .tick = 50 });
    try testing.expect(update(&state, .{ .dismiss = state.entries[0].serial }));
    try testing.expectEqual(toast.Phase{ .leaving = 150 }, state.entries[0].phase);
}

test "toast: a full stack evicts the oldest" {
    var state: State = .empty;
    for (0..toast.capacity) |_| _ = push(&state, "filler");
    const oldest = state.entries[0].serial;
    try testing.expect(push(&state, "newest"));
    try testing.expectEqual(toast.capacity, state.len);
    try testing.expectEqual(oldest + 1, state.entries[0].serial);
    try testing.expectEqualStrings("newest", state.entries[toast.capacity - 1].title());
    try expectPhases(&state, &.{ .entering, .entering, .entering, .waiting, .waiting, .waiting, .waiting, .waiting });
}

test "toast: long texts are cut between code points" {
    var state: State = .empty;
    // 95 ASCII bytes, then a two-byte "é" that would straddle byte 96.
    const long_title = "a" ** 95 ++ "\u{e9}tail";
    const long_description = "\u{20ac}" ** 60; // 180 bytes of three-byte "€"
    _ = update(&state, .{ .push = .{ .title = long_title, .description = long_description, .duration_ms = 1 } });
    const entry = &state.entries[0];
    try testing.expectEqualStrings("a" ** 95, entry.title());
    try testing.expectEqual(159, entry.description().len);
    try testing.expect(std.unicode.utf8ValidateSlice(entry.description()));
}

const Fixture = struct {
    nodes: [toast.node_max]Tree.Node = undefined,
    lines: [32]text.Line = undefined,
    table: memory.Table = .empty,

    fn tree(self: *Fixture) Tree {
        return .init(&self.nodes, &self.lines);
    }

    /// One frame: view, layout and place, as the app does it.
    fn frame(self: *Fixture, tree_: *Tree, state: *const State, dt_ms: u32) !toast.Motion {
        tree_.reset();
        const stack = try toast.view(state, tree_, &Theme.dark);
        try tree_.layout(measurer, 1000, 700);
        return toast.place(state, tree_, stack, &self.table, dt_ms);
    }
};

fn cardRect(tree: *const Tree, serial: u32) ?Tree.Rect {
    for (tree.items()) |node| {
        if (node.box.id == toast.cardId(serial)) return node.rect;
    }
    return null;
}

test "toast view: an empty stack writes nothing" {
    var fixture: Fixture = .{};
    var tree = fixture.tree();
    const state: State = .empty;
    try testing.expectEqual(null, try toast.view(&state, &tree, &Theme.dark));
    try testing.expectEqual(0, tree.len);
}

test "toast view: cards sit bottom right, the newest lowest, with hit targets" {
    var fixture: Fixture = .{};
    var tree = fixture.tree();
    var state: State = .{ .option = .{ .layout = .expanded } };
    show(&state, "Copied 3 lines");
    _ = update(&state, .{ .push = .{ .title = "Saved", .description = "config written", .kind = .success, .duration_ms = 4000 } });
    _ = update(&state, .{ .tick = Theme.duration });
    const older = state.entries[0].serial;
    const newer = state.entries[1].serial;

    try testing.expectEqual(.settled, try fixture.frame(&tree, &state, 16));
    // Root, a card without icon or description (5 nodes), a full card (8).
    try testing.expectEqual(14, tree.len);

    // One title line plus padding; the newer has a description line too.
    // Right edge at 1000 - 24, bottom edge at 700 - 24, 14 between them.
    try testing.expectEqual(Tree.Rect{ .x = 620, .y = 604, .w = 356, .h = 72 }, cardRect(&tree, newer).?);
    try testing.expectEqual(Tree.Rect{ .x = 620, .y = 538, .w = 356, .h = 52 }, cardRect(&tree, older).?);

    // The close button is the 20 px square at the card's top right.
    try testing.expectEqual(toast.Hit{ .close = older }, state.hit(tree.hitTest(950, 564)));
    try testing.expectEqual(toast.Hit{ .toast = older }, state.hit(tree.hitTest(700, 564)));
    try testing.expectEqual(toast.Hit{ .toast = newer }, state.hit(tree.hitTest(700, 640)));
    try testing.expectEqual(toast.Hit.none, state.hit(tree.hitTest(700, 597))); // the gap
    try testing.expectEqual(toast.Hit.none, state.hit(tree.hitTest(100, 100)));

    // Fully present: the theme's own colors.
    const card = tree.nodes[1];
    try testing.expectEqual(Theme.dark.popover, card.box.fill);
    try testing.expectEqual(Theme.dark.border, card.box.border);
}

test "toast view: a toast fades and rises in" {
    var fixture: Fixture = .{};
    var tree = fixture.tree();
    var state: State = .empty;
    _ = push(&state, "Copied");
    const serial = state.entries[0].serial;

    // Just pushed: invisible, 16 px below its place.
    _ = try fixture.frame(&tree, &state, 0);
    try testing.expectEqual(0, tree.nodes[1].box.fill.a);
    try testing.expectEqual(624 + 16, cardRect(&tree, serial).?.y);

    // Halfway in time is 87.5% of the way with ease-out cubic.
    _ = update(&state, .{ .tick = 100 });
    _ = try fixture.frame(&tree, &state, 100);
    try testing.expectEqual(223, tree.nodes[1].box.fill.a);
    try testing.expectEqual(624 + 2, cardRect(&tree, serial).?.y);
    // The text moved with its card.
    try testing.expectEqual(624 + 2 + 16, tree.nodes[3].rect.y);

    _ = update(&state, .{ .tick = 100 });
    _ = try fixture.frame(&tree, &state, 100);
    try testing.expectEqual(255, tree.nodes[1].box.fill.a);
    try testing.expectEqual(624, cardRect(&tree, serial).?.y);
}

test "toast view: the others glide to their new place when one leaves" {
    var fixture: Fixture = .{};
    var tree = fixture.tree();
    var state: State = .{ .option = .{ .layout = .expanded } };
    show(&state, "older");
    show(&state, "newer");
    const older = state.entries[0].serial;
    _ = try fixture.frame(&tree, &state, 16);
    try testing.expectEqual(558, cardRect(&tree, older).?.y);

    _ = update(&state, .{ .dismiss = state.entries[1].serial });
    _ = update(&state, .{ .tick = Theme.duration });
    try testing.expectEqual(1, state.len);

    // Layout now puts it 66 px lower; it is drawn where it was and closes in.
    try testing.expectEqual(.moving, try fixture.frame(&tree, &state, 0));
    try testing.expectEqual(558, cardRect(&tree, older).?.y);
    try testing.expectEqual(.moving, try fixture.frame(&tree, &state, 40));
    try testing.expectApproxEqAbs(624 - 66 * @exp(-1.0), cardRect(&tree, older).?.y, 0.01);
    try testing.expectEqual(.settled, try fixture.frame(&tree, &state, 400));
    try testing.expectEqual(624, cardRect(&tree, older).?.y);
    // The toast that left is forgotten.
    try testing.expectEqual(1, fixture.table.len);
}

test "toast: with motion off it appears, leaves and moves at once" {
    var fixture: Fixture = .{};
    var tree = fixture.tree();
    var state: State = .{ .motion = .none, .option = .{ .layout = .expanded } };
    _ = push(&state, "older");
    const older = state.entries[0].serial;

    // Fully there in its first frame, in its place.
    _ = try fixture.frame(&tree, &state, 0);
    try testing.expectEqual(255, tree.nodes[1].box.fill.a);
    try testing.expectEqual(624, cardRect(&tree, older).?.y);
    // The next tick ends the entrance, however short it is.
    try testing.expect(update(&state, .{ .tick = 1 }));
    try expectPhases(&state, &.{.shown});

    _ = push(&state, "newer");
    _ = update(&state, .{ .tick = 1 });
    _ = try fixture.frame(&tree, &state, 1);
    try testing.expectEqual(558, cardRect(&tree, older).?.y);

    // Dismissed: gone at the next tick, and the other one does not glide.
    try testing.expect(update(&state, .{ .dismiss = state.entries[1].serial }));
    try testing.expect(update(&state, .{ .tick = 1 }));
    try testing.expectEqual(1, state.len);
    try testing.expectEqual(.settled, try fixture.frame(&tree, &state, 1));
    try testing.expectEqual(624, cardRect(&tree, older).?.y);
}

test "toast view: more nodes than the array holds is an error" {
    var nodes: [toast.node_max - 1]Tree.Node = undefined;
    var lines: [32]text.Line = undefined;
    var tree: Tree = .init(&nodes, &lines);
    var state: State = .empty;
    for (0..3) |_| _ = update(&state, .{ .push = .{ .title = "t", .description = "d", .kind = .err, .duration_ms = 1 } });
    try testing.expectError(error.OutOfNodes, toast.view(&state, &tree, &Theme.dark));
}

test "sizes of the toast surface" {
    // Reported in the ticket; a change here is a layout change to look at.
    try testing.expectEqual(8, @sizeOf(toast.Phase));
    // 19 bytes of fields, 256 of text, 1 of padding.
    try testing.expectEqual(276, @sizeOf(toast.Entry));
    try testing.expectEqual(4, @alignOf(toast.Entry));
    try testing.expectEqual(24, @sizeOf(toast.Option));
    try testing.expectEqual(2244, @sizeOf(State));
    try testing.expectEqual(132, @sizeOf(memory.Table));
}

test "toast view: top_left option anchors at top left, uses custom geometry, and slides downward" {
    var fixture: Fixture = .{};
    var tree = fixture.tree();
    var state: State = .{
        .option = .{
            .width = 280,
            .position = .top_left,
            .layout = .expanded,
            .margin = 12,
            .padding = 8,
            .gap = 6,
        },
    };
    _ = push(&state, "First");
    _ = update(&state, .{ .tick = Theme.duration });
    _ = push(&state, "Second");
    const older = state.entries[0].serial;
    const newer = state.entries[1].serial;

    // Entering newest card starts 16 px above its resting place (slides downward on top_*).
    _ = try fixture.frame(&tree, &state, 0);
    const older_rect = cardRect(&tree, older).?;
    const newer_enter = cardRect(&tree, newer).?;
    try testing.expectEqual(@as(f32, 12), older_rect.x);
    try testing.expectEqual(@as(f32, 12), older_rect.y);
    try testing.expectEqual(@as(f32, 280), older_rect.w);
    try testing.expectEqual(@as(f32, 12 + older_rect.h + 6 - 16), newer_enter.y);

    // Finish entering: rests cleanly with `gap = 6` below `older`.
    _ = update(&state, .{ .tick = Theme.duration });
    _ = try fixture.frame(&tree, &state, Theme.duration);
    const newer_rest = cardRect(&tree, newer).?;
    try testing.expectEqual(older_rect.y + older_rect.h + 6, newer_rest.y);
}

test "toast view: shrinks to fit narrow windows inside margin" {
    var fixture: Fixture = .{};
    var tree = fixture.tree();
    var state: State = .{ .motion = .none };
    _ = update(&state, .{ .push = .{
        .title = "Sample toast notification",
        .description = "Positioned and timed from [toast].",
        .kind = .info,
        .duration_ms = 4000,
    } });
    const serial = state.entries[0].serial;

    const stack = try toast.view(&state, &tree, &Theme.dark);
    try tree.layout(measurer, 360, 400);
    _ = try toast.place(&state, &tree, stack, &fixture.table, 0);

    const card = cardRect(&tree, serial).?;
    try testing.expectEqual(@as(f32, toast.margin), card.x);
    try testing.expectEqual(@as(f32, 360 - 2 * toast.margin), card.w);
    try testing.expect(card.x + card.w <= 360 - toast.margin);
}

fn titleAlpha(tree: *const Tree, serial: u32) ?u8 {
    for (tree.items(), 0..) |node, i| {
        if (node.box.id != toast.cardId(serial)) continue;
        for (tree.nodes[i + 1 .. node.end]) |desc| {
            if (desc.content == .text) return desc.content.text.color.a;
        }
    }
    return null;
}

test "toast view: default stacked layout layers behind cards with peek, shrink, and hidden content" {
    var fixture: Fixture = .{};
    var tree = fixture.tree();
    var state: State = .empty;
    try testing.expectEqual(toast.Layout.stacked, state.option.layout);

    show(&state, "Oldest");
    show(&state, "Middle");
    _ = update(&state, .{ .push = .{ .title = "Front", .description = "Two lines tall", .kind = .success, .duration_ms = 4000 } });
    _ = update(&state, .{ .tick = Theme.duration });
    const oldest = state.entries[0].serial;
    const middle = state.entries[1].serial;
    const front = state.entries[2].serial;

    try testing.expectEqual(.settled, try fixture.frame(&tree, &state, 16));

    // Front toast sits bottom-right at full width and its natural 72 px height.
    const r_front = cardRect(&tree, front).?;
    const r_mid = cardRect(&tree, middle).?;
    const r_old = cardRect(&tree, oldest).?;
    try testing.expectEqual(Tree.Rect{ .x = 620, .y = 604, .w = 356, .h = 72 }, r_front);

    // Depth 1: 95% width centered on front, front height, 12 px peek above front.
    const w1 = 356.0 * 0.95;
    try testing.expectApproxEqAbs(@as(f32, 620.0 + (356.0 - w1) / 2.0), r_mid.x, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 604.0 - 12.0), r_mid.y, 1e-3);
    try testing.expectApproxEqAbs(w1, r_mid.w, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 72.0), r_mid.h, 1e-3);

    // Depth 2: 90% width centered on front, front height, 24 px peek above front.
    const w2 = 356.0 * 0.90;
    try testing.expectApproxEqAbs(@as(f32, 620.0 + (356.0 - w2) / 2.0), r_old.x, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 604.0 - 24.0), r_old.y, 1e-3);
    try testing.expectApproxEqAbs(w2, r_old.w, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 72.0), r_old.h, 1e-3);

    // Front content is opaque; behind cards hide content and disable close buttons while collapsed.
    try testing.expectEqual(@as(?u8, 255), titleAlpha(&tree, front));
    try testing.expectEqual(@as(?u8, 0), titleAlpha(&tree, middle));
    try testing.expectEqual(@as(?u8, 0), titleAlpha(&tree, oldest));
    try testing.expect(tree.find(toast.closeId(front)) != null);
    try testing.expectEqual(@as(?*const Tree.Node, null), tree.find(toast.closeId(middle)));
    try testing.expectEqual(@as(?*const Tree.Node, null), tree.find(toast.closeId(oldest)));

    // Bridge rect stays empty while collapsed, so pixels beside the narrower top rim are misses.
    const bridge = tree.find(toast.stack_id).?;
    try testing.expectEqual(@as(f32, 0), bridge.rect.w);
    try testing.expectEqual(toast.Hit.none, state.hit(tree.hitTest(625, 584)));
}

test "toast view: stacked deck expands on hover, bridges gaps, and collapses on leave" {
    var fixture: Fixture = .{};
    var tree = fixture.tree();
    var state: State = .empty;

    show(&state, "Older");
    _ = update(&state, .{ .push = .{ .title = "Front", .description = "Two lines", .kind = .info, .duration_ms = 4000 } });
    _ = update(&state, .{ .tick = Theme.duration });
    const older = state.entries[0].serial;
    const front = state.entries[1].serial;

    try testing.expectEqual(.settled, try fixture.frame(&tree, &state, 16));
    try testing.expectApproxEqAbs(@as(f32, 592), cardRect(&tree, older).?.y, 1e-3);

    // Hovering a stacked multi-toast deck requests a redraw and begins expanding.
    try testing.expect(update(&state, .{ .pointer = .over }));
    try testing.expect(!update(&state, .{ .pointer = .over }));
    try testing.expectEqual(.moving, try fixture.frame(&tree, &state, 0));
    try testing.expectEqual(.moving, try fixture.frame(&tree, &state, 40));
    // Mid-expansion: behind card is wider than collapsed 95%, narrower than 100%, and partially faded in.
    const mid_rect = cardRect(&tree, older).?;
    try testing.expect(mid_rect.w > 356.0 * 0.95 and mid_rect.w < 356.0);
    const mid_alpha = titleAlpha(&tree, older).?;
    try testing.expect(mid_alpha > 0 and mid_alpha < 255);

    // After enough frames, settles cleanly into full expanded list with gap = 14.
    try testing.expectEqual(.settled, try fixture.frame(&tree, &state, 400));
    try testing.expectEqual(Tree.Rect{ .x = 620, .y = 604, .w = 356, .h = 72 }, cardRect(&tree, front).?);
    try testing.expectEqual(Tree.Rect{ .x = 620, .y = 538, .w = 356, .h = 52 }, cardRect(&tree, older).?);
    try testing.expectEqual(@as(?u8, 255), titleAlpha(&tree, older));
    try testing.expect(tree.find(toast.closeId(older)) != null);

    // Crossing the 14 px gap between expanded cards hits `.stack` so hover does not flicker off.
    try testing.expectEqual(toast.Hit.stack, state.hit(tree.hitTest(700, 597)));
    try testing.expectEqual(toast.Hit{ .close = older }, state.hit(tree.hitTest(950, 564)));

    // Leaving requests a redraw and collapses smoothly back into the deck.
    try testing.expect(update(&state, .{ .pointer = .away }));
    try testing.expectEqual(.moving, try fixture.frame(&tree, &state, 0));
    try testing.expectEqual(.settled, try fixture.frame(&tree, &state, 400));
    try testing.expectApproxEqAbs(@as(f32, 356.0 * 0.95), cardRect(&tree, older).?.w, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 592), cardRect(&tree, older).?.y, 1e-3);
    try testing.expectEqual(@as(?u8, 0), titleAlpha(&tree, older));
    try testing.expectEqual(@as(f32, 0), tree.find(toast.stack_id).?.rect.w);
}

test "toast view: stacked top_left anchors front at top, peeks downward, and expands downward" {
    var fixture: Fixture = .{};
    var tree = fixture.tree();
    var state: State = .{
        .motion = .none,
        .option = .{
            .width = 280,
            .position = .top_left,
            .layout = .stacked,
            .margin = 12,
            .padding = 8,
            .gap = 6,
            .peek = 10,
        },
    };
    show(&state, "Oldest");
    _ = update(&state, .{ .push = .{ .title = "Front", .description = "Desc", .duration_ms = 4000 } });
    _ = update(&state, .{ .tick = 1 });
    const oldest = state.entries[0].serial;
    const front = state.entries[1].serial;

    // Collapsed: front sits at top margin; behind card peeks 10 px downward below it.
    try testing.expectEqual(.settled, try fixture.frame(&tree, &state, 0));
    const r_front = cardRect(&tree, front).?;
    const r_old = cardRect(&tree, oldest).?;
    try testing.expectEqual(@as(f32, 12), r_front.x);
    try testing.expectEqual(@as(f32, 12), r_front.y);
    try testing.expectEqual(@as(f32, 280), r_front.w);
    try testing.expectApproxEqAbs(@as(f32, 22), r_old.y, 1e-3);
    try testing.expectApproxEqAbs(r_front.h, r_old.h, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 280.0 * 0.95), r_old.w, 1e-3);

    // Motion off: hovering snaps immediately to expanded downward below front.
    try testing.expect(update(&state, .{ .pointer = .over }));
    try testing.expectEqual(.settled, try fixture.frame(&tree, &state, 0));
    const exp_front = cardRect(&tree, front).?;
    const exp_old = cardRect(&tree, oldest).?;
    try testing.expectEqual(@as(f32, 12), exp_front.y);
    try testing.expectEqual(exp_front.y + exp_front.h + 6, exp_old.y);
    try testing.expectEqual(@as(f32, 280), exp_old.w);
}
