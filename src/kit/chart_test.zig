const std = @import("std");
const testing = std.testing;
const std_tau = std.math.tau;

const Theme = @import("Theme.zig");
const chart = @import("chart.zig");
const text = @import("text.zig");
const Tree = @import("Tree.zig");

const byte_width = 7;

fn fixedWidth(_: *anyopaque, bytes: []const u8, _: text.Style, _: text.Figures) f32 {
    return @floatFromInt(bytes.len * byte_width);
}

var no_state: u8 = 0;
const measurer: text.Measurer = .{ .context = &no_state, .widthFn = fixedWidth };

const Fixture = struct {
    nodes: [64]Tree.Node = undefined,
    lines: [16]text.Line = undefined,

    fn tree(self: *Fixture) Tree {
        return .init(&self.nodes, &self.lines);
    }
};

fn lay(tree: *Tree) !void {
    try tree.layout(measurer, 200, 400);
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

    const line = findDash(&tree, group, Theme.dark.border).?;
    try testing.expectEqual(@as(u8, 3), line.content.dash.step);
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
    try testing.expectEqual(Tree.Rect{ .x = 0, .y = 0, .w = 100, .h = 40 }, tree.nodes[0].rect);
    try testing.expectEqual(tree.nodes[0].rect, tree.nodes[1].rect);
    try testing.expectEqual(Tree.Rect{ .x = 0, .y = 0, .w = 10, .h = 10 }, tree.nodes[2].rect);
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
    try testing.expectEqual(Tree.Rect{ .x = 0, .y = 0, .w = 100, .h = 40 }, tree.nodes[1].rect);
    try testing.expectEqual(Tree.Rect{ .x = 0, .y = 0, .w = 40, .h = 10 }, tree.nodes[2].rect);
    try testing.expectEqual(Tree.Rect{ .x = 40, .y = 0, .w = 60, .h = 10 }, tree.nodes[3].rect);
}

test "chart: a ring is a full track and a clockwise sweep" {
    var fixture: Fixture = .{};
    var tree = fixture.tree();
    try chart.progress(&tree, &Theme.dark, .ring, 0.25, Theme.dark.primary, chart.thickness);
    try lay(&tree);
    try testing.expectEqual(chart.ring_nodes, tree.len);
    const side = chart.ring_radius * 2;
    try testing.expectEqual(Tree.Rect{ .x = 0, .y = 0, .w = side, .h = side }, tree.nodes[0].rect);
    try testing.expectEqual(tree.nodes[0].rect, tree.nodes[1].rect);
    const track = tree.nodes[1].content.arc;
    const ink = tree.nodes[2].content.arc;
    try testing.expectApproxEqAbs(std_tau, track.sweep, 0.001);
    try testing.expectEqual(Tree.Arc.Caps.butt, track.caps);
    try testing.expectEqual(Theme.dark.muted, track.fill);
    try testing.expectApproxEqAbs(@as(f32, std_tau) / 4, ink.sweep, 0.001);
    try testing.expectEqual(Tree.Arc.Caps.round, ink.caps);
    try testing.expectEqual(Theme.dark.primary, ink.fill);
}

test "chart: a border pill uses stadium radius and clockwise perimeter sweep" {
    var fixture: Fixture = .{};
    var tree = fixture.tree();
    try chart.progress(&tree, &Theme.dark, .border, 0.5, Theme.dark.info, chart.thickness);
    try lay(&tree);
    try testing.expectEqual(chart.border_nodes, tree.len);
    const pill = tree.nodes[0];
    const sweep_node = tree.nodes[1];
    try testing.expectEqual(@as(f32, 200), pill.rect.w);
    try testing.expectEqual(chart.border_pill_height, pill.rect.h);
    try testing.expectEqual(chart.pillRadius(chart.border_pill_height), pill.box.radius);
    try testing.expectEqual(@as(u8, 52), pill.box.radius);
    try testing.expectEqual(Theme.dark.muted, pill.box.border);
    try testing.expectEqual(chart.border_pill_thickness, pill.box.border_width);

    try testing.expectEqual(pill.rect, sweep_node.rect);
    try testing.expectEqual(Theme.dark.info, sweep_node.box.border);
    try testing.expectEqual(@as(u8, 52), sweep_node.box.radius);
    try testing.expectEqual(chart.borderSweepValue(0.5), sweep_node.content.border_sweep);

    // Zero or negative fraction keeps node count stable and sets sweep border transparent.
    tree = fixture.tree();
    try chart.progress(&tree, &Theme.dark, .border, 0, Theme.dark.info, chart.thickness);
    try lay(&tree);
    try testing.expectEqual(chart.border_nodes, tree.len);
    try testing.expectEqual(Theme.Color.transparent, tree.nodes[1].box.border);
}

test "chart: HalfRings.fromCycle maps task, cycle, and break fractions" {
    const idle = chart.HalfRings.fromCycle(.idle, 0.7, 2, 4);
    try testing.expectEqual(@as(f32, 0), idle.task);
    try testing.expectApproxEqAbs(@as(f32, 0.5), idle.cycle, 0.001);
    try testing.expectEqual(@as(f32, 0), idle.break_phase);

    const first_task = chart.HalfRings.fromCycle(.task, 0.2, 0, 4);
    try testing.expectApproxEqAbs(@as(f32, 0.2), first_task.task, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.25), first_task.cycle, 0.001);
    try testing.expectEqual(@as(f32, 0), first_task.break_phase);

    const task = chart.HalfRings.fromCycle(.task, 0.4, 1, 4);
    try testing.expectApproxEqAbs(@as(f32, 0.4), task.task, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.5), task.cycle, 0.001);
    try testing.expectEqual(@as(f32, 0), task.break_phase);

    const short_brk = chart.HalfRings.fromCycle(.short_break, 0.6, 2, 4);
    try testing.expectEqual(@as(f32, 1.0), short_brk.task);
    try testing.expectApproxEqAbs(@as(f32, 0.5), short_brk.cycle, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.6), short_brk.break_phase, 0.001);

    // `focus.zig` resets `tasks_in_cycle` to 0 when transitioning into `long_break`.
    const long_brk = chart.HalfRings.fromCycle(.long_break, 0.8, 0, 4);
    try testing.expectEqual(@as(f32, 1.0), long_brk.task);
    try testing.expectEqual(@as(f32, 1.0), long_brk.cycle);
    try testing.expectApproxEqAbs(@as(f32, 0.8), long_brk.break_phase, 0.001);

    const zero_total = chart.HalfRings.fromCycle(.task, 0.5, 2, 0);
    try testing.expectEqual(@as(f32, 0), zero_total.cycle);
}

test "chart: half_rings builds three concentric round-cap semicircles" {
    var fixture: Fixture = .{};
    var tree = fixture.tree();
    const rings = chart.HalfRings.fromCycle(.short_break, 0.5, 2, 4);
    try chart.halfRings(&tree, &Theme.dark, rings, .{
        .outer_radius = 58,
        .thickness = 6,
        .gap = 5,
    });
    try lay(&tree);
    // Square + outer (2) + 4 discrete cycle segments (2 active + 2 muted) + inner (2) = 9 nodes.
    try testing.expectEqual(@as(usize, 9), tree.len);

    // Outer (info): muted track + full semicircle sweep (1.0 * pi).
    const outer_track = tree.nodes[1].content.arc;
    const outer_active = tree.nodes[2].content.arc;
    try testing.expectEqual(@as(f32, 58), outer_track.radius);
    try testing.expectEqual(Theme.dark.muted, outer_track.fill);
    try testing.expectEqual(Tree.Arc.Caps.round, outer_track.caps);
    try testing.expectApproxEqAbs(chart.half_ring_start, outer_active.start, 0.001);
    try testing.expectApproxEqAbs(chart.half_ring_sweep, outer_active.sweep, 0.001);
    try testing.expectEqual(Theme.dark.info, outer_active.fill);
    try testing.expectEqual(Tree.Arc.Caps.round, outer_active.caps);

    // Middle (success): radius 58 - 11 = 47, split into 4 separated rounded segments (2 active, 2 muted).
    const mid_seg0 = tree.nodes[3].content.arc;
    const mid_seg1 = tree.nodes[4].content.arc;
    const mid_seg2 = tree.nodes[5].content.arc;
    const mid_seg3 = tree.nodes[6].content.arc;
    try testing.expectEqual(@as(f32, 47), mid_seg0.radius);
    try testing.expectEqual(Theme.dark.success, mid_seg0.fill);
    try testing.expectEqual(Theme.dark.success, mid_seg1.fill);
    try testing.expectEqual(Theme.dark.muted, mid_seg2.fill);
    try testing.expectEqual(Theme.dark.muted, mid_seg3.fill);
    try testing.expect(mid_seg1.start > mid_seg0.start + mid_seg0.sweep);

    // Inner (foreground): radius 58 - 22 = 36, sweep 0.5 * pi.
    const inner_active = tree.nodes[8].content.arc;
    try testing.expectEqual(@as(f32, 36), inner_active.radius);
    try testing.expectApproxEqAbs(chart.half_ring_sweep * 0.5, inner_active.sweep, 0.001);
    try testing.expectEqual(Theme.dark.foreground, inner_active.fill);

    // Trimming a wide vertical half-ring keeps each ring's caps within ±clip_half_height.
    var clipped_fixture: Fixture = .{};
    var clipped_tree = clipped_fixture.tree();
    const box = try clipped_tree.open(.{ .width = .{ .fixed = 2 }, .height = .{ .fixed = 132 } });
    try chart.halfRingsArcs(&clipped_tree, &Theme.dark, .{ .task = 0.5, .cycle = 1.0, .break_phase = 0 }, .{
        .outer_radius = 99,
        .thickness = 8,
        .gap = 6.5,
        .start = chart.half_ring_vertical_start,
        .sweep = chart.half_ring_sweep,
        .clip_half_height = 56,
    });
    clipped_tree.close(box);
    const trimmed_track = clipped_tree.nodes[1].content.arc;
    const trimmed_active = clipped_tree.nodes[2].content.arc;
    const expected_trim = std.math.acos(@as(f32, 56.0) / 95.0);
    try testing.expectApproxEqAbs(chart.half_ring_vertical_start + expected_trim, trimmed_track.start, 0.001);
    try testing.expectApproxEqAbs(chart.half_ring_sweep - expected_trim * 2.0, trimmed_track.sweep, 0.001);
    try testing.expectApproxEqAbs(trimmed_track.sweep * 0.5, trimmed_active.sweep, 0.001);
}

test "chart: coil emits a single serpentine progress node with clamped fraction and proportional columns" {
    var fixture: Fixture = .{};
    var tree = fixture.tree();
    try chart.progress(&tree, &Theme.dark, .coil, 0.65, Theme.dark.info, 8);
    try lay(&tree);
    try testing.expectEqual(chart.coil_nodes, tree.len);
    const c = tree.nodes[0].content.coil;
    try testing.expectEqual(Theme.dark.info, c.fill);
    try testing.expectApproxEqAbs(@as(f32, 0.65), c.fraction, 0.001);
    try testing.expectEqual(chart.coil_columns, c.columns);
    try testing.expectEqual(@as(u8, 8), chart.coilColumns(20, 4));
    try testing.expectEqual(@as(u8, 28), chart.coilColumns(500, 4));
}

test "chart: donut slices share the square and the gaps" {
    var fixture: Fixture = .{};
    var tree = fixture.tree();
    const parts = [_]chart.Part{
        .{ .id = Tree.Id.of("part").item(0), .label = "Rex", .value = 1, .fill = Theme.dark.primary },
        .{ .id = Tree.Id.of("part").item(1), .label = "Shell", .value = 3, .fill = Theme.dark.info },
    };
    try chart.share(&tree, &Theme.dark, .donut, &parts);
    try lay(&tree);
    try testing.expectEqual(chart.donutNodes(parts.len), tree.len);
    const side = chart.donut_radius * 2;
    try testing.expectEqual(Tree.Rect{ .x = 0, .y = 0, .w = side, .h = side }, tree.nodes[0].rect);
    try testing.expectEqual(tree.nodes[0].rect, tree.nodes[1].rect);
    const smaller = tree.nodes[1].content.arc;
    const larger = tree.nodes[2].content.arc;
    try testing.expectApproxEqAbs(smaller.sweep * 3, larger.sweep, 0.001);
    try testing.expectEqual(Tree.Arc.Caps.butt, smaller.caps);
    try testing.expectApproxEqAbs(smaller.sweep + (chart.donut_gap / (chart.donut_radius - chart.donut_thickness / 2)), larger.start, 0.001);

    // Hit-testing picks the exact wedge on the ring, and misses the hollow center.
    const center = chart.donut_radius;
    const mid_r = chart.donut_radius - chart.donut_thickness / 2;
    try testing.expect(tree.hit(center, center) == null);
    try testing.expectEqual(parts[0].id, tree.hit(center + mid_r * @sin(@as(f32, 0.4)), center - mid_r * @cos(@as(f32, 0.4))).?.box.id);
    try testing.expectEqual(parts[1].id, tree.hit(center - mid_r, center).?.box.id);
}

test "chart: a missing limit draws no line" {
    var fixture: Fixture = .{};
    var tree = fixture.tree();
    const items = [_]chart.Day{
        .{ .total = 5, .part = 1, .fill = Theme.dark.muted, .part_fill = Theme.dark.primary },
    };
    try dayChart(&tree, &items, null);
    try testing.expect(findDash(&tree, 1, Theme.dark.border) == null);
}

fn findFill(tree: *const Tree, column: usize, color: Theme.Color) ?*const Tree.Node {
    for (tree.nodes[column + 1 .. tree.nodes[column].end]) |*node| {
        if (node.box.fill == color and node.rect.h > 0) return node;
    }
    return null;
}

fn findDash(tree: *const Tree, parent: usize, color: Theme.Color) ?*const Tree.Node {
    for (tree.nodes[parent + 1 .. tree.nodes[parent].end]) |*node| {
        if (node.content == .dash and node.content.dash.color == color and node.rect.h > 0) return node;
    }
    return null;
}
