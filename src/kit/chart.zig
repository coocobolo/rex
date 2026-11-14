//! Charts for the dashboard. Each view takes the numbers and a mark: a
//! progress is a bar or a ring, a share a strip or a donut, days are bars.
//! A line, an area or a radar is another mark on the same numbers, added
//! when the kit can draw it.
//!
//! Lengths are `fraction`s of the parent, so a chart takes the size its
//! parent gives it. The caller chooses the colors. The limit line uses
//! `border`.

const std = @import("std");

const Theme = @import("Theme.zig");
const Color = Theme.Color;
const tree_zig = @import("tree.zig");
const Tree = tree_zig.Tree;
const Id = tree_zig.Id;

/// Thickness of a progress bar unless the caller gives one.
pub const thickness = 8;
/// Height of the share strip, and the room each segment leaves after it.
pub const strip_height = 12;
pub const strip_gap = 2;
/// Outer radius and thickness of the timer ring. The HTML draws a
/// centerline of 112 with a stroke of 6.
pub const ring_radius: f32 = 115;
pub const ring_thickness: f32 = 6;
/// Outer radius and thickness of the program donut. The HTML draws a
/// centerline of 54 with a stroke of 16.
pub const donut_radius: f32 = 62;
pub const donut_thickness: f32 = 16;
/// Gap between donut slices, along the centerline, in logical pixels.
pub const donut_gap: f32 = 2;

/// How one fraction is drawn.
pub const ProgressMark = enum { bar, ring };
/// How named parts are drawn.
pub const ShareMark = enum { bar, donut };
/// How one value per day is drawn.
pub const DayMark = enum { bar };

pub const Part = struct {
    /// On the row, so a tooltip can anchor to it later.
    id: Id = .none,
    /// Borrowed until the view is rebuilt.
    label: []const u8,
    value: f32,
    fill: Color,
};

pub const Day = struct {
    /// On the column, so a tooltip can anchor to it later.
    id: Id = .none,
    /// Behind the column: a hovered or selected day.
    slot: Color = .transparent,
    total: f32,
    /// Drawn inside `total`, from the baseline, and clamped to it.
    part: f32,
    fill: Color,
    part_fill: Color,
};

/// The track and the filled part.
pub const progress_nodes = 2;
/// The square, the track arc and the filled arc.
pub const ring_nodes = 3;

/// The strip, then each part's slot and segment.
pub fn shareNodes(count: usize) usize {
    return 1 + count * 2;
}

/// The row, then each day's column, its bar and the part inside it, and
/// the limit's overlay, line and spacer.
pub fn dayNodes(count: usize) usize {
    return 1 + count * 6;
}

/// The square, then one arc per part.
pub fn donutNodes(count: usize) usize {
    return 1 + count;
}

/// A track and the fraction of it that `fraction` fills. Values outside
/// 0..1 are clamped. `bar_height` is the bar's thickness; a ring keeps its
/// own.
pub fn progress(tree: *Tree, theme: *const Theme, mark: ProgressMark, fraction: f32, fill: Color, bar_height: f32) tree_zig.Error!void {
    switch (mark) {
        .bar => try fractionBar(tree, theme.muted, fill, fraction, bar_height),
        .ring => try ringChart(tree, theme, fraction, fill),
    }
}

/// Each part's share of the sum: one strip cut into segments, or a donut.
/// The names are not drawn; the surface lists them beside the chart.
pub fn share(tree: *Tree, theme: *const Theme, mark: ShareMark, parts: []const Part) tree_zig.Error!void {
    _ = theme;
    switch (mark) {
        .bar => try shareStrip(tree, parts),
        .donut => try donutChart(tree, parts),
    }
}

/// One column per day, as tall as the parent gives the row. `part` sits at
/// the bottom of `total`. `limit` is the same unit as `total`; null draws
/// no line. The line is a hairline in each column at the same height.
pub fn days(tree: *Tree, theme: *const Theme, mark: DayMark, items: []const Day, limit: ?f32) tree_zig.Error!void {
    switch (mark) {
        .bar => try dayBars(tree, theme, items, limit),
    }
}

fn fractionBar(tree: *Tree, track: Color, fill: Color, fraction: f32, height: f32) tree_zig.Error!void {
    const bar = try tree.open(.{
        .width = .fill,
        .height = .{ .fixed = height },
        .fill = track,
        .radius = Theme.radius_sm,
    });
    _ = try tree.leaf(.{
        .width = .{ .fraction = fraction },
        .height = .fill,
        .fill = fill,
        .radius = Theme.radius_sm,
    });
    tree.close(bar);
}

/// Segments in a row, each the part's fraction of the sum wide. The room
/// after each one but the last is padding inside its slot, so the
/// fractions add up to the strip whatever its width. A segment is rounded
/// on its own: a clip would cut the strip's corners square.
fn shareStrip(tree: *Tree, parts: []const Part) tree_zig.Error!void {
    var sum: f32 = 0;
    for (parts) |part| sum += finite(part.value);
    const strip = try tree.open(.{ .axis = .row, .width = .fill, .height = .{ .fixed = strip_height } });
    for (parts, 0..) |part, index| {
        const last = index + 1 == parts.len;
        const slot = try tree.open(.{
            .id = part.id,
            .width = .{ .fraction = if (sum == 0) 0 else finite(part.value) / sum },
            .height = .fill,
            .padding = .{ .right = if (last) 0 else strip_gap },
        });
        _ = try tree.leaf(.{ .width = .fill, .height = .fill, .fill = part.fill, .radius = Theme.radius_sm / 3 });
        tree.close(slot);
    }
    tree.close(strip);
}

/// Radius of a day's bar and of the part inside it.
const day_radius = 6;
/// Room around the bar inside its column, where the slot shows.
pub const slot_pad = 2;

fn dayBars(tree: *Tree, theme: *const Theme, items: []const Day, limit: ?f32) tree_zig.Error!void {
    var scale: f32 = if (limit) |lim| finite(lim) else 0;
    for (items) |day| scale = @max(scale, finite(day.total));
    const row = try tree.open(.{
        .axis = .row,
        .width = .fill,
        .height = .fill,
        .gap = Theme.space,
    });
    for (items) |day| try dayColumn(tree, theme, day, limit, scale);
    tree.close(row);
}

/// A column the row's height. Its bar stands on the baseline at `total`
/// of the scale, the part inside it at `part` of the bar. The limit is an
/// overlay whose hairline sits on a spacer that tall.
fn dayColumn(tree: *Tree, theme: *const Theme, day: Day, limit: ?f32, scale: f32) tree_zig.Error!void {
    const column = try tree.open(.{
        .id = day.id,
        .width = .fill,
        .height = .fill,
        .padding = .all(slot_pad),
        .main = .end,
        .fill = day.slot,
        .radius = day_radius + slot_pad,
    });
    const total = finite(day.total);
    const bar = try tree.open(.{
        .width = .fill,
        .height = .{ .fraction = if (scale == 0) 0 else total / scale },
        .main = .end,
        .fill = day.fill,
        .radius = day_radius,
    });
    _ = try tree.leaf(.{
        .width = .fill,
        .height = .{ .fraction = if (total == 0) 0 else @min(finite(day.part), total) / total },
        .fill = day.part_fill,
        .radius = day_radius,
    });
    tree.close(bar);
    if (limit) |lim| {
        // An overlay covers the padding box; its own padding puts the line
        // on the bars' scale.
        const overlay = try tree.open(.{ .overlay = true, .width = .fill, .height = .fill, .padding = .all(slot_pad), .main = .end });
        _ = try tree.leaf(.{ .width = .fill, .height = .{ .fixed = 1 }, .fill = theme.border });
        _ = try tree.leaf(.{ .width = .fill, .height = .{ .fraction = if (scale == 0) 0 else finite(lim) / scale } });
        tree.close(overlay);
    }
    tree.close(column);
}

const turn = std.math.tau;

fn ringChart(tree: *Tree, theme: *const Theme, fraction: f32, fill: Color) tree_zig.Error!void {
    const side = ring_radius * 2;
    const square = try tree.open(.{
        .width = .{ .fixed = side },
        .height = .{ .fixed = side },
    });
    try segment(tree, .{
        .radius = ring_radius,
        .thickness = ring_thickness,
        .sweep = turn,
        .fill = theme.muted,
    });
    try segment(tree, .{
        .radius = ring_radius,
        .thickness = ring_thickness,
        .sweep = clamp01(fraction) * turn,
        .fill = fill,
        .caps = .round,
    });
    tree.close(square);
}

fn donutChart(tree: *Tree, parts: []const Part) tree_zig.Error!void {
    const side = donut_radius * 2;
    const square = try tree.open(.{
        .width = .{ .fixed = side },
        .height = .{ .fixed = side },
    });
    var sum: f32 = 0;
    for (parts) |part| sum += finite(part.value);
    const count: f32 = @floatFromInt(parts.len);
    const centerline = donut_radius - donut_thickness / 2;
    const gap = if (parts.len > 1 and centerline > 0) donut_gap / centerline else 0;
    const room = @max(0, turn - gap * count);
    var cursor: f32 = 0;
    for (parts) |part| {
        const sweep = if (sum == 0) 0 else finite(part.value) / sum * room;
        try segment(tree, .{
            .radius = donut_radius,
            .thickness = donut_thickness,
            .start = cursor,
            .sweep = sweep,
            .fill = part.fill,
        });
        cursor += sweep + gap;
    }
    tree.close(square);
}

fn segment(tree: *Tree, arc: tree_zig.Arc) tree_zig.Error!void {
    _ = try tree.arc(arc, .{ .overlay = true, .width = .fill, .height = .fill });
}

fn clamp01(value: f32) f32 {
    return @min(1, @max(0, value));
}

fn finite(value: f32) f32 {
    if (!std.math.isFinite(value) or value < 0) return 0;
    return value;
}
