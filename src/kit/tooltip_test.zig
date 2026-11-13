const testing = @import("std").testing;

const Theme = @import("Theme.zig");
const layout = @import("layout.zig");
const text = @import("text.zig");
const tooltip = @import("tooltip.zig");
const tree_zig = @import("tree.zig");
const Rect = tree_zig.Rect;
const Tree = tree_zig.Tree;
const Id = tree_zig.Id;

const page_id = Id.of("test.page");
const bar_id = Id.of("test.bar");

fn measurer() text.Measurer {
    const Fixed = struct {
        var unused: u8 = 0;
        fn width(_: *anyopaque, bytes: []const u8, _: text.Style, _: text.Figures) f32 {
            return @floatFromInt(bytes.len * 7);
        }
    };
    return .{ .context = &Fixed.unused, .widthFn = Fixed.width };
}

const Fixture = struct {
    nodes: [24]tree_zig.Node = undefined,
    lines: [8]text.Line = undefined,
    tree: Tree = undefined,
    card: tree_zig.Index = 0,

    fn build(self: *Fixture, x: u8, y: u8, width: f32, height: f32) !void {
        const theme = &Theme.dark;
        self.tree = .init(&self.nodes, &self.lines);
        const page = try self.tree.open(.{ .id = page_id, .width = .fill, .height = .fill, .padding = .{ .left = x, .top = y } });
        _ = try self.tree.leaf(.{ .id = bar_id, .width = .{ .fixed = 40 }, .height = .{ .fixed = 36 } });
        self.tree.close(page);
        self.card = try tooltip.open(&self.tree, theme, bar_id);
        try tooltip.line(&self.tree, theme, .{ .name = "Focus", .value = "2h", .swatch = theme.primary });
        tooltip.close(&self.tree, self.card);
        try layout.layout(&self.tree, measurer(), width, height);
    }
};

test "tooltip: the card sits below its anchor and is as wide as its text" {
    var fixture: Fixture = .{};
    try fixture.build(40, 100, 800, 600);
    // Swatch 8, gaps 8, "Focus" 35, "2h" 14, padding 8 on each side: 89.
    // The anchor is 40 wide, so the text wins. One line of 16 inside 4 of padding.
    try testing.expectEqual(Rect{ .x = 40, .y = 140, .w = 89, .h = 24 }, fixture.tree.nodes[fixture.card].rect);
    try testing.expectEqual(tooltip.nodes(1), fixture.tree.len - 2);
    try testing.expectEqual(Theme.dark.popover, fixture.tree.nodes[fixture.card].box.fill);
    try testing.expectEqual(Theme.dark.border, fixture.tree.nodes[fixture.card].box.border);
    try testing.expectEqual(Id.none, fixture.tree.nodes[fixture.card].box.id);
}

test "tooltip: the card goes above when there is more room there" {
    var fixture: Fixture = .{};
    try fixture.build(40, 250, 800, 300);
    // Below would start at 290 with 2 left; the card is 24 tall, so it goes above.
    try testing.expectEqual(@as(f32, 250 - layout.anchor_gap - 24), fixture.tree.nodes[fixture.card].rect.y);
}

test "tooltip: a hit on the card falls through to the page" {
    var fixture: Fixture = .{};
    try fixture.build(40, 100, 800, 600);
    const card = fixture.tree.nodes[fixture.card].rect;
    try testing.expectEqual(page_id, fixture.tree.hitTest(card.x + 4, card.y + 4));
    try testing.expectEqual(bar_id, fixture.tree.hitTest(44, 110));
    try testing.expectEqual(page_id, fixture.tree.hitTest(600, 500));
}

test "tooltip: a view holds anchor_max tooltips" {
    var nodes: [tree_zig.anchor_max + 1]tree_zig.Node = undefined;
    var lines: [1]text.Line = undefined;
    var tree = Tree.init(&nodes, &lines);
    for (0..tree_zig.anchor_max) |_| {
        tooltip.close(&tree, try tooltip.open(&tree, &Theme.dark, bar_id));
    }
    try testing.expectError(error.OutOfAnchors, tooltip.open(&tree, &Theme.dark, bar_id));
}
