const std = @import("std");
const testing = std.testing;

const Theme = @import("Theme.zig");
const text = @import("text.zig");
const tree_zig = @import("tree.zig");
const Tree = tree_zig.Tree;
const layout = @import("layout.zig").layout;
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
    var state: State = .empty;
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
    nodes: [toast.node_max]tree_zig.Node = undefined,
    lines: [32]text.Line = undefined,
    table: memory.Table = .empty,

    fn tree(self: *Fixture) Tree {
        return .init(&self.nodes, &self.lines);
    }

    /// One frame: view, layout and place, as the app does it.
    fn frame(self: *Fixture, tree_: *Tree, state: *const State, dt_ms: u32) !toast.Motion {
        tree_.reset();
        const stack = try toast.view(state, tree_, &Theme.dark);
        try layout(tree_, measurer, 1000, 700);
        return toast.place(state, tree_, stack, &self.table, dt_ms);
    }
};

fn cardRect(tree: *const Tree, serial: u32) ?tree_zig.Rect {
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
    var state: State = .empty;
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
    try testing.expectEqual(tree_zig.Rect{ .x = 620, .y = 604, .w = 356, .h = 72 }, cardRect(&tree, newer).?);
    try testing.expectEqual(tree_zig.Rect{ .x = 620, .y = 538, .w = 356, .h = 52 }, cardRect(&tree, older).?);

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
    var state: State = .empty;
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
    var state: State = .{ .motion = .none };
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
    var nodes: [toast.node_max - 1]tree_zig.Node = undefined;
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
    try testing.expectEqual(2216, @sizeOf(State));
    try testing.expectEqual(132, @sizeOf(memory.Table));
}
