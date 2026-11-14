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
    try chart.progress(&tree, &Theme.dark, .bar, 0.25, Theme.dark.primary, chart.thickness);
    try lay(&tree);
    try testing.expectEqual(chart.progress_nodes, tree.len);
    try testing.expectEqual(Theme.dark.muted, tree.nodes[0].box.fill);
    try testing.expectEqual(chart.thickness, tree.nodes[0].rect.h);
    try testing.expectEqual(@as(f32, 200), tree.nodes[0].rect.w);
    try testing.expectEqual(@as(f32, 50), tree.nodes[1].rect.w);
    try testing.expectEqual(Theme.dark.primary, tree.nodes[1].box.fill);
}

test "chart: the share strip cuts its width by each part's share" {
    var fixture: Fixture = .{};
    var tree = fixture.tree();
    const parts = [_]chart.Part{
        .{ .label = "Rex", .value = 1, .fill = Theme.dark.primary },
        .{ .label = "Shell", .value = 3, .fill = Theme.dark.info },
    };
    try chart.share(&tree, &Theme.dark, .bar, &parts);
    try lay(&tree);
    try testing.expectEqual(chart.shareNodes(parts.len), tree.len);
    try testing.expectEqual(@as(f32, chart.strip_height), tree.nodes[0].rect.h);
    // Slots are a quarter and three quarters of 200; the first leaves the
    // gap after its segment, the last runs to the end.
    try testing.expectApproxEqAbs(@as(f32, 50), tree.nodes[1].rect.w, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 50 - chart.strip_gap), tree.nodes[2].rect.w, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 150), tree.nodes[4].rect.w, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 200), tree.nodes[4].rect.x + tree.nodes[4].rect.w, 0.01);
    try testing.expectEqual(Theme.dark.primary, tree.nodes[2].box.fill);
    try testing.expectEqual(Theme.dark.info, tree.nodes[4].box.fill);
}

/// Day bars in a box 96 high, as a card gives them their height.
fn dayChart(tree: *Tree, items: []const chart.Day, limit: ?chart.Limit) !void {
    const box = try tree.open(.{ .width = .fill, .height = .{ .fixed = 96 } });
    try chart.days(tree, &Theme.dark, .bar, items, limit);
    tree.close(box);
    try lay(tree);
}

test "chart: day bars share a scale and the limit lines up" {
    var fixture: Fixture = .{};
    var tree = fixture.tree();
    const items = [_]chart.Day{
        .{ .total = 10, .part = 4, .fill = Theme.dark.muted, .part_fill = Theme.dark.primary },
        .{ .total = 20, .part = 30, .fill = Theme.dark.muted, .part_fill = Theme.dark.primary },
    };
    try dayChart(&tree, &items, .{ .value = 10, .label = "6h limit" });
    try testing.expectEqual(1 + chart.dayNodes(items.len), tree.len);

    const group = 1;
    const first = 3;
    const second: usize = tree.nodes[first].end;
    try testing.expectEqual(@as(f32, 96), tree.nodes[first].rect.h);
    try testing.expectEqual(tree.nodes[first].rect.w, tree.nodes[second].rect.w);

    // The scale is the larger of the limit and the tallest day, 20, over
    // the column less its slot padding: 92.
    const inner: f32 = 96 - 2 * chart.slot_pad;
    const bottom = tree.nodes[first].rect.y + tree.nodes[first].rect.h - chart.slot_pad;
    const bar_a = findFill(&tree, first, Theme.dark.muted).?;
    try testing.expectApproxEqAbs(inner / 2, bar_a.rect.h, 0.01);
    try testing.expectApproxEqAbs(bottom, bar_a.rect.y + bar_a.rect.h, 0.01);
    const part_a = findFill(&tree, first, Theme.dark.primary).?;
    try testing.expectApproxEqAbs(inner / 2 * 4 / 10, part_a.rect.h, 0.01);
    try testing.expectApproxEqAbs(bottom, part_a.rect.y + part_a.rect.h, 0.01);
    // A part larger than its total fills the bar and no more.
    try testing.expectApproxEqAbs(inner, findFill(&tree, second, Theme.dark.primary).?.rect.h, 0.01);

    const line = findFill(&tree, group, Theme.dark.border).?;
    try testing.expectEqual(tree.nodes[group].rect.w, line.rect.w);
    try testing.expectEqual(@as(f32, 1), line.rect.h);
    // The hairline's bottom edge is at the limit: 10 of 20, half the bars'
    // height, so it meets the top of the first bar.
    try testing.expectApproxEqAbs(bar_a.rect.y, line.rect.y + 1, 0.01);
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
    try chart.progress(&tree, &Theme.dark, .ring, 0.25, Theme.dark.primary, chart.thickness);
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
    try dayChart(&tree, &items, null);
    try testing.expect(findFill(&tree, 1, Theme.dark.border) == null);
}

fn findFill(tree: *const Tree, column: usize, color: Theme.Color) ?*const tree_zig.Node {
    for (tree.nodes[column + 1 .. tree.nodes[column].end]) |*node| {
        if (node.box.fill == color and node.rect.h > 0) return node;
    }
    return null;
}
