const testing = @import("std").testing;

const Theme = @import("Theme.zig");
const layout = @import("layout.zig");
const text = @import("text.zig");
const tooltip = @import("tooltip.zig");
const Tree = @import("Tree.zig");
const Rect = Tree.Rect;
const Id = Tree.Id;

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
    nodes: [24]Tree.Node = undefined,
    lines: [8]text.Line = undefined,
    tree: Tree = undefined,
    card: Tree.Index = 0,

    fn build(self: *Fixture, x: u8, y: u8, width: f32, height: f32) !void {
        try self.buildWith(x, y, 40, 36, width, height, .{ .anchor = bar_id });
    }

    fn buildWith(self: *Fixture, x: u8, y: u8, anchor_w: f32, anchor_h: f32, width: f32, height: f32, options: tooltip.Options) !void {
        const theme = &Theme.dark;
        self.tree = .init(&self.nodes, &self.lines);
        const page = try self.tree.open(.{ .id = page_id, .width = .fill, .height = .fill, .padding = .{ .left = x, .top = y } });
        _ = try self.tree.leaf(.{ .id = bar_id, .width = .{ .fixed = anchor_w }, .height = .{ .fixed = anchor_h } });
        self.tree.close(page);
        self.card = try tooltip.open(&self.tree, theme, options);
        try tooltip.line(&self.tree, theme, .{ .name = "Focus", .value = "2h", .swatch = theme.primary });
        tooltip.close(&self.tree, self.card);
        try self.tree.layout(measurer(), width, height);
    }
};

test "tooltip: the card sits below its anchor and is as wide as its text" {
    var fixture: Fixture = .{};
    try fixture.build(40, 100, 800, 600);
    // Swatch 8, gaps 8, "Focus" 35, "2h" 14, padding 12 on each side: 97.
    // The anchor is 40 wide, so the text wins. One line of 16 inside 8 of padding: 32.
    try testing.expectEqual(Rect{ .x = 40, .y = 140, .w = 97, .h = 32 }, fixture.tree.nodes[fixture.card].rect);
    try testing.expectEqual(tooltip.nodes(1), fixture.tree.len - 2);
    try testing.expectEqual(Theme.dark.popover, fixture.tree.nodes[fixture.card].box.fill);
    try testing.expectEqual(Theme.dark.border, fixture.tree.nodes[fixture.card].box.border);
    try testing.expectEqual(Id.none, fixture.tree.nodes[fixture.card].box.id);
}

test "tooltip: the card goes above when there is more room there" {
    var fixture: Fixture = .{};
    try fixture.build(40, 250, 800, 300);
    // Below would start at 290 with 2 left; the card is 32 tall, so it goes above.
    try testing.expectEqual(@as(f32, 250 - layout.anchor_gap - 32), fixture.tree.nodes[fixture.card].rect.y);
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
    var nodes: [Tree.anchor_max + 1]Tree.Node = undefined;
    var lines: [1]text.Line = undefined;
    var tree = Tree.init(&nodes, &lines);
    for (0..Tree.anchor_max) |_| {
        tooltip.close(&tree, try tooltip.open(&tree, &Theme.dark, .{ .anchor = bar_id }));
    }
    try testing.expectError(error.OutOfAnchors, tooltip.open(&tree, &Theme.dark, .{ .anchor = bar_id }));
}

test "tooltip: hugs its content below a wide anchor and supports four-side placement" {
    var fixture: Fixture = .{};
    // Trigger is 240 wide, tooltip is 97 wide: must keep 97 instead of stretching to 240.
    try fixture.buildWith(40, 100, 240, 36, 800, 600, .{ .anchor = bar_id });
    try testing.expectEqual(Rect{ .x = 40, .y = 140, .w = 97, .h = 32 }, fixture.tree.nodes[fixture.card].rect);

    // Explicit side = .right / .above / .left, plus .auto falling back to .right in a short viewport.
    try fixture.buildWith(40, 100, 40, 36, 800, 600, .{ .anchor = bar_id, .side = .right, .alignment = .center });
    try testing.expectEqual(Rect{ .x = 84, .y = 102, .w = 97, .h = 32 }, fixture.tree.nodes[fixture.card].rect);

    try fixture.buildWith(40, 100, 40, 36, 800, 600, .{ .anchor = bar_id, .side = .above });
    try testing.expectEqual(Rect{ .x = 40, .y = 64, .w = 97, .h = 32 }, fixture.tree.nodes[fixture.card].rect);

    try fixture.buildWith(150, 100, 40, 36, 800, 600, .{ .anchor = bar_id, .side = .left });
    try testing.expectEqual(Rect{ .x = 49, .y = 100, .w = 97, .h = 32 }, fixture.tree.nodes[fixture.card].rect);

    // Short 80px viewport leaves neither above nor below open for a 40px-tall anchor -> auto picks right.
    try fixture.buildWith(20, 20, 40, 40, 800, 80, .{ .anchor = bar_id, .side = .auto });
    try testing.expect(fixture.tree.nodes[fixture.card].rect.x >= 20 + 40 + layout.anchor_gap);
}
