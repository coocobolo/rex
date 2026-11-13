const std = @import("std");
const testing = std.testing;
const std_tau = std.math.tau;

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

test "chart: an overlay covers its parent and does not grow it" {
    var fixture: Fixture = .{};
    var tree = fixture.tree();
    const parent = try tree.open(.{ .width = .{ .fixed = 100 }, .height = .{ .fixed = 40 } });
    _ = try tree.leaf(.{ .overlay = true, .width = .fill, .height = .fill });
    _ = try tree.leaf(.{ .width = .{ .fixed = 10 }, .height = .{ .fixed = 10 } });
    tree.close(parent);
    try lay(&tree);
    try testing.expectEqual(tree_zig.Rect{ .x = 0, .y = 0, .w = 100, .h = 40 }, tree.nodes[0].rect);
    try testing.expectEqual(tree.nodes[0].rect, tree.nodes[1].rect);
    try testing.expectEqual(tree_zig.Rect{ .x = 0, .y = 0, .w = 10, .h = 10 }, tree.nodes[2].rect);
}

test "chart: an overlay keeps its parent's size beside a fill sibling" {
    var fixture: Fixture = .{};
    var tree = fixture.tree();
    const parent = try tree.open(.{ .axis = .row, .width = .{ .fixed = 100 }, .height = .{ .fixed = 40 } });
    _ = try tree.leaf(.{ .overlay = true, .width = .fill, .height = .fill });
    _ = try tree.leaf(.{ .width = .{ .fixed = 40 }, .height = .{ .fixed = 10 } });
    _ = try tree.leaf(.{ .width = .fill, .height = .{ .fixed = 10 } });
    tree.close(parent);
    try lay(&tree);
    try testing.expectEqual(tree_zig.Rect{ .x = 0, .y = 0, .w = 100, .h = 40 }, tree.nodes[1].rect);
    try testing.expectEqual(tree_zig.Rect{ .x = 0, .y = 0, .w = 40, .h = 10 }, tree.nodes[2].rect);
    try testing.expectEqual(tree_zig.Rect{ .x = 40, .y = 0, .w = 60, .h = 10 }, tree.nodes[3].rect);
}

test "chart: a ring is a full track and a clockwise sweep" {
    var fixture: Fixture = .{};
    var tree = fixture.tree();
    try chart.progress(&tree, &Theme.dark, .ring, 0.25, Theme.dark.primary);
    try lay(&tree);
    try testing.expectEqual(chart.ring_nodes, tree.len);
    const side = chart.ring_radius * 2;
    try testing.expectEqual(tree_zig.Rect{ .x = 0, .y = 0, .w = side, .h = side }, tree.nodes[0].rect);
    try testing.expectEqual(tree.nodes[0].rect, tree.nodes[1].rect);
    const track = tree.nodes[1].content.arc;
    const ink = tree.nodes[2].content.arc;
    try testing.expectApproxEqAbs(std_tau, track.sweep, 0.001);
    try testing.expectEqual(tree_zig.Caps.butt, track.caps);
    try testing.expectEqual(Theme.dark.muted, track.fill);
    try testing.expectApproxEqAbs(@as(f32, std_tau) / 4, ink.sweep, 0.001);
    try testing.expectEqual(tree_zig.Caps.round, ink.caps);
    try testing.expectEqual(Theme.dark.primary, ink.fill);
}

test "chart: donut slices share the square and the gaps" {
    var fixture: Fixture = .{};
    var tree = fixture.tree();
    const parts = [_]chart.Part{
        .{ .label = "Rex", .value = 1, .fill = Theme.dark.primary },
        .{ .label = "Shell", .value = 3, .fill = Theme.dark.info },
    };
    try chart.share(&tree, &Theme.dark, .donut, &parts);
    try lay(&tree);
    try testing.expectEqual(chart.donutNodes(parts.len), tree.len);
    const side = chart.donut_radius * 2;
    try testing.expectEqual(tree_zig.Rect{ .x = 0, .y = 0, .w = side, .h = side }, tree.nodes[0].rect);
    try testing.expectEqual(tree.nodes[0].rect, tree.nodes[1].rect);
    const smaller = tree.nodes[1].content.arc;
    const larger = tree.nodes[2].content.arc;
    try testing.expectApproxEqAbs(smaller.sweep * 3, larger.sweep, 0.001);
    try testing.expectEqual(tree_zig.Caps.butt, smaller.caps);
    try testing.expectApproxEqAbs(smaller.sweep + (chart.donut_gap / (chart.donut_radius - chart.donut_thickness / 2)), larger.start, 0.001);
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
