const testing = @import("std").testing;

const Theme = @import("Theme.zig");
const chart = @import("chart.zig");
const text = @import("text.zig");
const tree_zig = @import("tree.zig");
const Tree = tree_zig.Tree;
const layout = @import("layout.zig").layout;

const byte_width = 7;

fn fixedWidth(_: *anyopaque, bytes: []const u8, _: text.Style, _: text.Figures) f32 {
    return @floatFromInt(bytes.len * byte_width);
}

var no_state: u8 = 0;
const measurer: text.Measurer = .{ .context = &no_state, .widthFn = fixedWidth };

const Fixture = struct {
    nodes: [64]tree_zig.Node = undefined,
    lines: [16]text.Line = undefined,

    fn tree(self: *Fixture) Tree {
        return .init(&self.nodes, &self.lines);
    }
};

fn lay(tree: *Tree) !void {
    try layout(tree, measurer, 200, 400);
}

test "chart: a fraction fills that much of its parent" {
    var fixture: Fixture = .{};
    var tree = fixture.tree();
    const track = try tree.open(.{ .width = .{ .fixed = 200 }, .height = .{ .fixed = 20 } });
    _ = try tree.leaf(.{ .width = .{ .fraction = 0.25 }, .height = .fill });
    tree.close(track);
    try lay(&tree);
    try testing.expectEqual(@as(f32, 50), tree.nodes[1].rect.w);
    try testing.expectEqual(@as(f32, 20), tree.nodes[1].rect.h);

    tree = fixture.tree();
    const wide = try tree.open(.{ .width = .{ .fixed = 200 }, .height = .{ .fixed = 20 } });
    _ = try tree.leaf(.{ .width = .{ .fraction = 2 }, .height = .fill });
    tree.close(wide);
    try lay(&tree);
    try testing.expectEqual(@as(f32, 200), tree.nodes[1].rect.w);
}

test "chart: progress fills the fraction of a muted track" {
    var fixture: Fixture = .{};
    var tree = fixture.tree();
    try chart.progress(&tree, &Theme.dark, .bar, 0.25, Theme.dark.primary);
    try lay(&tree);
    try testing.expectEqual(chart.progress_nodes, tree.len);
    try testing.expectEqual(Theme.dark.muted, tree.nodes[0].box.fill);
    try testing.expectEqual(chart.thickness, tree.nodes[0].rect.h);
    try testing.expectEqual(@as(f32, 200), tree.nodes[0].rect.w);
    try testing.expectEqual(@as(f32, 50), tree.nodes[1].rect.w);
    try testing.expectEqual(Theme.dark.primary, tree.nodes[1].box.fill);
}

test "chart: share rows are sized to the largest value" {
    var fixture: Fixture = .{};
    var tree = fixture.tree();
    const parts = [_]chart.Part{
        .{ .label = "Rex", .value = 1, .fill = Theme.dark.primary },
        .{ .label = "Shell", .value = 3, .fill = Theme.dark.info },
    };
    try chart.share(&tree, &Theme.dark, .bar, &parts);
    try lay(&tree);
    try testing.expectEqual(chart.shareNodes(parts.len), tree.len);
    const shorter = tree.nodes[4];
    const longer = tree.nodes[8];
    try testing.expectApproxEqAbs(@as(f32, 200) / 3, shorter.rect.w, 0.01);
    try testing.expectEqual(@as(f32, 200), longer.rect.w);
    try testing.expectEqual(Theme.dark.primary, shorter.box.fill);
    try testing.expectEqual(Theme.dark.info, longer.box.fill);
}

test "chart: day bars share a scale and the limit lines up" {
    var fixture: Fixture = .{};
    var tree = fixture.tree();
    const items = [_]chart.Day{
        .{ .total = 10, .part = 4, .fill = Theme.dark.muted, .part_fill = Theme.dark.primary },
        .{ .total = 20, .part = 30, .fill = Theme.dark.muted, .part_fill = Theme.dark.primary },
    };
    try chart.days(&tree, &Theme.dark, .bar, &items, 10);
    try lay(&tree);
    try testing.expect(tree.len <= chart.dayNodes(items.len));

    const first = 1;
    const second: usize = tree.nodes[first].end;
    try testing.expectEqual(chart.day_height, tree.nodes[first].rect.h);
    try testing.expectEqual(tree.nodes[first].rect.w, tree.nodes[second].rect.w);

    const line_a = findFill(&tree, first, Theme.dark.border).?;
    const line_b = findFill(&tree, second, Theme.dark.border).?;
    try testing.expectEqual(line_a.rect.y, line_b.rect.y);
    try testing.expectEqual(@as(f32, 1), line_a.rect.h);

    const focus = findFill(&tree, first, Theme.dark.primary).?;
    const bottom = tree.nodes[first].rect.y + tree.nodes[first].rect.h;
    try testing.expectApproxEqAbs(bottom, focus.rect.y + focus.rect.h, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 96) * 4 / 20, focus.rect.h, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 95), sumFill(&tree, second, Theme.dark.primary), 0.01);
}

test "chart: a missing limit draws no line" {
    var fixture: Fixture = .{};
    var tree = fixture.tree();
    const items = [_]chart.Day{
        .{ .total = 5, .part = 1, .fill = Theme.dark.muted, .part_fill = Theme.dark.primary },
    };
    try chart.days(&tree, &Theme.dark, .bar, &items, null);
    try lay(&tree);
    try testing.expect(findFill(&tree, 1, Theme.dark.border) == null);
}

fn findFill(tree: *const Tree, column: usize, color: Theme.Color) ?*const tree_zig.Node {
    for (tree.nodes[column + 1 .. tree.nodes[column].end]) |*node| {
        if (node.box.fill == color and node.rect.h > 0) return node;
    }
    return null;
}

fn sumFill(tree: *const Tree, column: usize, color: Theme.Color) f32 {
    var total: f32 = 0;
    for (tree.nodes[column + 1 .. tree.nodes[column].end]) |*node| {
        if (node.box.fill == color) total += node.rect.h;
    }
    return total;
}
