const std = @import("std");
const testing = std.testing;

const Theme = @import("Theme.zig");
const layout = @import("layout.zig");
const popup = @import("popup.zig");
const text = @import("text.zig");
const tree_zig = @import("tree.zig");
const Rect = tree_zig.Rect;
const Tree = tree_zig.Tree;
const Id = tree_zig.Id;

const trigger_id = Id.of("test.trigger");
const page_id = Id.of("test.page");
const layer_id = Id.of("test.layer");
const labels = [_][]const u8{ "Dark", "Light", "System" };

fn itemId(index: u32) Id {
    return Id.of("test.item").item(index);
}

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
    nodes: [16]tree_zig.Node = undefined,
    lines: [16]text.Line = undefined,
    tree: Tree = undefined,
    card: tree_zig.Index = 0,

    /// A page with a 120 by 36 trigger at `x`, `y`, and the popup against
    /// it with "Dark" selected and "Light" highlighted.
    fn build(self: *Fixture, x: u8, y: u8, width: f32, height: f32) !void {
        const theme = &Theme.dark;
        self.tree = .init(&self.nodes, &self.lines);
        const page = try self.tree.open(.{ .id = page_id, .width = .fill, .height = .fill, .padding = .{ .left = x, .top = y } });
        _ = try self.tree.leaf(.{ .id = trigger_id, .width = .{ .fixed = 120 }, .height = .{ .fixed = 36 } });
        self.tree.close(page);
        self.card = try popup.open(&self.tree, theme, .{ .layer_id = layer_id, .anchor = trigger_id });
        for (labels, 0..) |label, index| {
            try popup.item(&self.tree, theme, .{
                .id = itemId(@intCast(index)),
                .label = label,
                .selected = index == 0,
                .highlighted = index == 1,
            });
        }
        popup.close(&self.tree, self.card);
        try layout.layout(&self.tree, measurer(), width, height);
    }

    fn rectOf(self: *const Fixture, id: Id) Rect {
        return self.tree.find(id).?.rect;
    }
};

test "popup: the card sits below its anchor, at least as wide" {
    var fixture: Fixture = .{};
    try fixture.build(40, 100, 800, 600);
    // Three items of 32 inside 4 of padding; the widest content is
    // "Dark" with its check mark, 68, so the anchor's 120 wins.
    try testing.expectEqual(Rect{ .x = 40, .y = 140, .w = 120, .h = 104 }, fixture.tree.nodes[fixture.card].rect);
    try testing.expectEqual(Rect{ .x = 44, .y = 144, .w = 112, .h = 32 }, fixture.rectOf(itemId(0)));
    try testing.expectEqual(Rect{ .x = 44, .y = 208, .w = 112, .h = 32 }, fixture.rectOf(itemId(2)));
    // The layer covers the window.
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 800, .h = 600 }, fixture.rectOf(layer_id));
}

test "popup: the card goes above when there is more room there" {
    var fixture: Fixture = .{};
    try fixture.build(40, 200, 800, 300);
    // Below would start at 240 with 52 left; above has 84.
    try testing.expectEqual(Rect{ .x = 40, .y = 92, .w = 120, .h = 104 }, fixture.tree.nodes[fixture.card].rect);
}

test "popup: the card stays inside the window's margin" {
    var fixture: Fixture = .{};
    try fixture.build(250, 40, 300, 600);
    try testing.expectEqual(@as(f32, 300 - layout.anchor_margin - 120), fixture.tree.nodes[fixture.card].rect.x);
}

test "popup: the card and the layer take the pointer from the page" {
    var fixture: Fixture = .{};
    try fixture.build(40, 100, 800, 600);
    try testing.expectEqual(itemId(1), fixture.tree.hitTest(60, 190));
    // Over the trigger and over the page, the layer is on top.
    try testing.expectEqual(layer_id, fixture.tree.hitTest(60, 110));
    try testing.expectEqual(layer_id, fixture.tree.hitTest(600, 500));
}

test "popup: the hand shows over items, the arrow over the layer" {
    var fixture: Fixture = .{};
    try fixture.build(40, 100, 800, 600);
    try testing.expectEqual(tree_zig.PointerShape.hand, fixture.tree.hit(60, 190).?.box.pointer);
    // Over the trigger the page would show, the layer's arrow wins.
    try testing.expectEqual(tree_zig.PointerShape.arrow, fixture.tree.hit(60, 110).?.box.pointer);
}

test "popup: highlighted items are filled, the selected one is checked" {
    var fixture: Fixture = .{};
    try fixture.build(40, 100, 800, 600);
    try testing.expectEqual(Theme.Color.transparent, fixture.tree.find(itemId(0)).?.box.fill);
    try testing.expectEqual(Theme.dark.accent, fixture.tree.find(itemId(1)).?.box.fill);
    var icons: u32 = 0;
    for (fixture.tree.items()) |node| {
        if (node.content == .icon) icons += 1;
    }
    try testing.expectEqual(1, icons);
}

test "popup: without its anchor, the card stays at the top left" {
    var nodes: [4]tree_zig.Node = undefined;
    var lines: [4]text.Line = undefined;
    var tree = Tree.init(&nodes, &lines);
    const card = try popup.open(&tree, &Theme.dark, .{ .layer_id = layer_id, .anchor = trigger_id });
    _ = try tree.leaf(.{ .width = .{ .fixed = 50 }, .height = .{ .fixed = 20 } });
    popup.close(&tree, card);
    try layout.layout(&tree, measurer(), 800, 600);
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 58, .h = 28 }, tree.nodes[card].rect);
}

test "popup: a view holds anchor_max popups" {
    var nodes: [2 * (tree_zig.anchor_max + 1)]tree_zig.Node = undefined;
    var lines: [1]text.Line = undefined;
    var tree = Tree.init(&nodes, &lines);
    for (0..tree_zig.anchor_max) |_| {
        popup.close(&tree, try popup.open(&tree, &Theme.dark, .{ .layer_id = layer_id, .anchor = trigger_id }));
    }
    try testing.expectError(error.OutOfAnchors, popup.open(&tree, &Theme.dark, .{ .layer_id = layer_id, .anchor = trigger_id }));
}
