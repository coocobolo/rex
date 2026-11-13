const std = @import("std");
const testing = std.testing;

const Theme = @import("Theme.zig");
const icons = @import("icons.zig");
const layout = @import("layout.zig");
const sidebar = @import("sidebar.zig");
const text = @import("text.zig");
const tree_zig = @import("tree.zig");
const Rect = tree_zig.Rect;
const Tree = tree_zig.Tree;

const groups = [_]sidebar.Group{
    .{ .label = "General", .items = &.{
        .{ .label = "Appearance", .icon = icons.info },
        .{ .label = "Font" },
    } },
    .{ .items = &.{.{ .label = "About" }} },
};
const count = 3;

/// Seven pixels a byte, whatever the style.
fn measurer() text.Measurer {
    const Fixed = struct {
        var unused: u8 = 0;
        fn width(_: *anyopaque, bytes: []const u8, _: text.Style) f32 {
            return @floatFromInt(bytes.len * 7);
        }
    };
    return .{ .context = &Fixed.unused, .widthFn = Fixed.width };
}

const Fixture = struct {
    nodes: [sidebar.nodeMax(&groups) + 1]tree_zig.Node = undefined,
    lines: [sidebar.lineMax(&groups) + 8]text.Line = undefined,
    tree: Tree = undefined,

    /// Writes the frame with a one-line section, at `width` by 600.
    fn build(self: *Fixture, state: *const sidebar.State, theme: *const Theme, width: f32) !sidebar.Frame {
        self.tree = .init(&self.nodes, &self.lines);
        const frame = try sidebar.begin(&self.tree, theme, &groups, state, .{ .padding = .all(24) });
        _ = try self.tree.text("Section", .{ .color = theme.foreground });
        try sidebar.end(&self.tree, theme, &groups, state, frame);
        try layout.layout(&self.tree, measurer(), width, 600);
        return frame;
    }

    fn node(self: *const Fixture, id: tree_zig.Id) ?*const tree_zig.Node {
        for (self.tree.items()) |*n| {
            if (n.box.id == id) return n;
        }
        return null;
    }
};

test "sidebar: a wide window docks the column beside the pane" {
    var fixture: Fixture = .{};
    var state: sidebar.State = .empty;
    try testing.expect(!state.update(count, .{ .width = 800 }));
    const frame = try fixture.build(&state, &Theme.dark, 800);
    const nodes = fixture.tree.nodes;

    try testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 800, .h = 600 }, nodes[frame.root].rect);
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 256, .h = 600 }, nodes[frame.root + 1].rect);
    try testing.expectEqual(Theme.dark.sidebar, nodes[frame.root + 1].box.fill);
    try testing.expectEqual(Rect{ .x = 256, .y = 0, .w = 1, .h = 600 }, nodes[frame.pane - 1].rect);
    try testing.expectEqual(Rect{ .x = 257, .y = 0, .w = 543, .h = 600 }, nodes[frame.pane].rect);
    // The toggle sits in the pane's top left, inside the header's padding.
    try testing.expectEqual(Rect{ .x = 265, .y = 8, .w = 32, .h = 32 }, fixture.node(sidebar.toggle_id).?.rect);
    try testing.expectEqual(Rect{ .x = 257, .y = 48, .w = 543, .h = 552 }, nodes[frame.section].rect);

    // Group padding 8, then the label row, then one row per item.
    try testing.expectEqual(Rect{ .x = 8, .y = 40, .w = 240, .h = 32 }, fixture.node(sidebar.itemId(0)).?.rect);
    try testing.expectEqual(Rect{ .x = 8, .y = 72, .w = 240, .h = 32 }, fixture.node(sidebar.itemId(1)).?.rect);
    // The second group has no label: its first row starts at its padding.
    try testing.expectEqual(Rect{ .x = 8, .y = 120, .w = 240, .h = 32 }, fixture.node(sidebar.itemId(2)).?.rect);

    try testing.expectEqual(sidebar.Target{ .item = 1 }, sidebar.hit(fixture.tree.hitTest(20, 80), count));
    try testing.expectEqual(sidebar.Target.toggle, sidebar.hit(fixture.tree.hitTest(270, 20), count));
    try testing.expectEqual(sidebar.Target.none, sidebar.hit(fixture.tree.hitTest(400, 80), count));
}

test "sidebar: a narrow window hides the column, and the toggle lays it over the pane" {
    var fixture: Fixture = .{};
    var state: sidebar.State = .empty;
    try testing.expect(state.update(count, .{ .width = 500 }));
    try testing.expect(!state.shown());
    var frame = try fixture.build(&state, &Theme.dark, 500);
    try testing.expect(fixture.node(sidebar.itemId(0)) == null);
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 500, .h = 600 }, fixture.tree.nodes[frame.pane].rect);

    try testing.expect(state.update(count, .toggle));
    try testing.expect(state.shown());
    frame = try fixture.build(&state, &Theme.dark, 500);
    // The pane keeps the whole window; the column is a later root, on top.
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 500, .h = 600 }, fixture.tree.nodes[frame.pane].rect);
    const item = fixture.node(sidebar.itemId(1)).?;
    try testing.expectEqual(Rect{ .x = 8, .y = 72, .w = 240, .h = 32 }, item.rect);
    try testing.expectEqual(sidebar.itemId(1), fixture.tree.hitTest(20, 80));

    try testing.expectEqual(sidebar.Target.scrim, sidebar.hit(fixture.tree.hitTest(400, 80), count));

    // A press beside it puts it away at once.
    try testing.expect(state.update(count, .{ .press = .scrim }));
    try testing.expect(!state.shown());
    try testing.expect(!state.update(count, .release));
    try testing.expect(!state.update(count, .{ .press = .scrim }));

    // Choosing a section puts the column away too.
    try testing.expect(state.update(count, .toggle));
    try testing.expect(state.update(count, .{ .press = .{ .item = 1 } }));
    try testing.expect(state.update(count, .release));
    try testing.expectEqual(1, state.current);
    try testing.expect(!state.shown());
}

test "sidebar: crossing the width hands the choice back to the width" {
    var state: sidebar.State = .empty;
    try testing.expect(state.update(count, .toggle));
    try testing.expect(!state.shown());
    try testing.expect(!state.update(count, .{ .width = 700 }));
    try testing.expect(!state.shown());

    try testing.expect(state.update(count, .{ .width = 599 }));
    try testing.expect(!state.shown());
    try testing.expect(state.update(count, .{ .width = 600 }));
    try testing.expect(state.shown());

    // Toggling twice is back where it started.
    try testing.expect(state.update(count, .toggle));
    try testing.expect(state.update(count, .toggle));
    try testing.expectEqual(sidebar.Panel.auto, state.panel);
}

test "sidebar: the toggle is taken on release, like an item" {
    var state: sidebar.State = .empty;
    try testing.expect(state.update(count, .{ .pointer = .toggle }));
    try testing.expect(state.update(count, .{ .press = .toggle }));
    try testing.expect(state.shown());
    try testing.expect(state.update(count, .release));
    try testing.expect(!state.shown());

    try testing.expect(state.update(count, .{ .press = .toggle }));
    try testing.expect(state.update(count, .{ .pointer = .none }));
    try testing.expect(state.update(count, .release));
    try testing.expect(!state.shown());
}

test "sidebar: the current item is filled, and ringed only with the keyboard focus" {
    var fixture: Fixture = .{};
    const theme = &Theme.light;
    const state: sidebar.State = .{ .current = 1, .hover = .{ .item = 2 }, .focused = true };
    _ = try fixture.build(&state, theme, 800);

    const plain = fixture.node(sidebar.itemId(0)).?.box;
    try testing.expectEqual(Theme.Color.transparent, plain.fill);
    try testing.expectEqual(Theme.Color.transparent, plain.border);
    const current = fixture.node(sidebar.itemId(1)).?.box;
    try testing.expectEqual(theme.accent, current.fill);
    try testing.expectEqual(theme.ring, current.border);
    const hovered = fixture.node(sidebar.itemId(2)).?.box;
    try testing.expectEqual(theme.accent, hovered.fill);
    try testing.expectEqual(Theme.Color.transparent, hovered.border);
}

test "sidebar: the frame fits nodeMax, docked and laid over" {
    var fixture: Fixture = .{};
    var state: sidebar.State = .empty;
    _ = try fixture.build(&state, &Theme.dark, 800);
    // One section text; one group has no label and two items have no icon.
    try testing.expectEqual(sidebar.nodeMax(&groups) + 1 - 2 - 4, fixture.tree.len);
    _ = state.update(count, .{ .width = 500 });
    _ = state.update(count, .toggle);
    _ = try fixture.build(&state, &Theme.dark, 500);
    try testing.expectEqual(sidebar.nodeMax(&groups) + 1 - 4, fixture.tree.len);
}

test "sidebar: an item is taken when the pointer is let go on it" {
    var state: sidebar.State = .empty;
    try testing.expect(state.update(count, .{ .pointer = .{ .item = 2 } }));
    try testing.expect(!state.update(count, .{ .pointer = .{ .item = 2 } }));
    try testing.expect(state.update(count, .{ .press = .{ .item = 2 } }));
    try testing.expectEqual(0, state.current);
    try testing.expect(state.update(count, .release));
    try testing.expectEqual(2, state.current);
    try testing.expectEqual(sidebar.Target.none, state.pressed);

    // Moving off before letting go takes nothing.
    try testing.expect(state.update(count, .{ .press = .{ .item = 0 } }));
    try testing.expect(state.update(count, .{ .pointer = .none }));
    try testing.expect(state.update(count, .release));
    try testing.expectEqual(2, state.current);

    try testing.expect(!state.update(count, .release));
    try testing.expect(!state.update(count, .{ .press = .none }));
    try testing.expect(!state.update(count, .{ .press = .{ .item = count } }));
}

test "sidebar: the keyboard moves the current item, stops at the ends and shows the ring" {
    var state: sidebar.State = .empty;
    try testing.expect(state.update(count, .{ .move = .previous }));
    try testing.expectEqual(0, state.current);
    try testing.expect(state.focused);
    try testing.expect(!state.update(count, .{ .move = .previous }));

    try testing.expect(state.update(count, .{ .move = .next }));
    try testing.expect(state.update(count, .last));
    try testing.expectEqual(2, state.current);
    try testing.expect(!state.update(count, .{ .move = .next }));
    try testing.expect(state.update(count, .first));
    try testing.expectEqual(0, state.current);

    // A press hides the ring again.
    try testing.expect(state.update(count, .{ .press = .{ .item = 1 } }));
    try testing.expect(!state.focused);
    try testing.expect(state.update(count, .focus));
    try testing.expect(state.update(count, .blur));
    try testing.expect(!state.update(count, .blur));
}

test "sidebar: the state is 8 bytes" {
    try testing.expectEqual(2, @sizeOf(sidebar.Target));
    try testing.expectEqual(8, @sizeOf(sidebar.State));
}
