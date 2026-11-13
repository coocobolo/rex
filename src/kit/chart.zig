//! Bars for the dashboard. Each view takes the numbers and a mark. The
//! mark shipped here is `bar`. A ring, a donut, a line, an area or a
//! radar is another mark on the same numbers, added when the kit can
//! draw it.
//!
//! A bar's length is a `fraction` of its track. The caller chooses the
//! colors. The limit line uses `border`.

const std = @import("std");

const Theme = @import("Theme.zig");
const Color = Theme.Color;
const tree_zig = @import("tree.zig");
const Tree = tree_zig.Tree;
const Id = tree_zig.Id;

/// Thickness of a progress bar and of one share row's bar.
pub const thickness = 8;
/// Height of the day chart.
pub const day_height = 96;

/// How one fraction is drawn.
pub const ProgressMark = enum { bar };
/// How named parts are drawn.
pub const ShareMark = enum { bar };
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
    total: f32,
    /// Drawn inside `total`, from the baseline, and clamped to it.
    part: f32,
    fill: Color,
    part_fill: Color,
};

/// The track and the filled part.
pub const progress_nodes = 2;

/// The column, then each part's group, label, track and filled part.
pub fn shareNodes(count: usize) usize {
    return 1 + count * 4;
}

/// The row, then each day's column and up to five strips inside it.
pub fn dayNodes(count: usize) usize {
    return 1 + count * 6;
}

/// A track and the fraction of it that `fraction` fills. Values outside
/// 0..1 are clamped.
pub fn progress(tree: *Tree, theme: *const Theme, mark: ProgressMark, fraction: f32, fill: Color) tree_zig.Error!void {
    switch (mark) {
        .bar => try fractionBar(tree, theme.muted, fill, fraction),
    }
}

/// One part under the next. The name sits above its bar, so every bar
/// has the same width and is sized to the largest value.
pub fn share(tree: *Tree, theme: *const Theme, mark: ShareMark, parts: []const Part) tree_zig.Error!void {
    switch (mark) {
        .bar => try shareBars(tree, theme, parts),
    }
}

/// One column per day. `part` sits at the bottom of `total`. `limit` is
/// the same unit as `total`; null draws no line. The line is one strip
/// in each column at the same height.
pub fn days(tree: *Tree, theme: *const Theme, mark: DayMark, items: []const Day, limit: ?f32) tree_zig.Error!void {
    switch (mark) {
        .bar => try dayBars(tree, theme, items, limit),
    }
}

fn fractionBar(tree: *Tree, track: Color, fill: Color, fraction: f32) tree_zig.Error!void {
    const bar = try tree.open(.{
        .width = .fill,
        .height = .{ .fixed = thickness },
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

fn shareBars(tree: *Tree, theme: *const Theme, parts: []const Part) tree_zig.Error!void {
    var scale: f32 = 0;
    for (parts) |part| scale = @max(scale, finite(part.value));
    const column = try tree.open(.{ .width = .fill, .gap = Theme.space });
    for (parts) |part| {
        const item = try tree.open(.{
            .id = part.id,
            .width = .fill,
            .gap = Theme.space,
        });
        _ = try tree.text(part.label, .{ .color = theme.foreground, .style = .sm });
        const fraction: f32 = if (scale == 0) 0 else finite(part.value) / scale;
        try fractionBar(tree, theme.muted, part.fill, fraction);
        tree.close(item);
    }
    tree.close(column);
}

fn dayBars(tree: *Tree, theme: *const Theme, items: []const Day, limit: ?f32) tree_zig.Error!void {
    var scale: f32 = if (limit) |lim| finite(lim) else 0;
    for (items) |day| scale = @max(scale, finite(day.total));
    const row = try tree.open(.{
        .axis = .row,
        .width = .fill,
        .height = .{ .fixed = day_height },
        .gap = Theme.space,
    });
    for (items) |day| try dayColumn(tree, theme, day, limit, scale);
    tree.close(row);
}

fn dayColumn(tree: *Tree, theme: *const Theme, day: Day, limit: ?f32, scale: f32) tree_zig.Error!void {
    const column = try tree.open(.{
        .id = day.id,
        .width = .fill,
        .height = .{ .fixed = day_height },
    });
    const height: f32 = day_height;
    const total_h = if (scale == 0) 0 else height * finite(day.total) / scale;
    const part_h = if (scale == 0) 0 else height * @min(finite(day.part), finite(day.total)) / scale;
    const has_line = limit != null;
    const limit_h: f32 = if (limit) |lim| blk: {
        if (scale == 0) break :blk 0;
        break :blk @min(height - 1, height * finite(lim) / scale);
    } else 0;

    var edges = [_]f32{ 0, height, part_h, total_h, 0, 0 };
    var count: usize = 4;
    if (has_line) {
        edges[count] = limit_h;
        edges[count + 1] = @min(height, limit_h + 1);
        count += 2;
    }
    sortEdges(edges[0..count]);
    var unique: usize = 0;
    for (edges[0..count]) |edge| {
        if (unique == 0 or edge != edges[unique - 1]) {
            edges[unique] = edge;
            unique += 1;
        }
    }

    var index = unique;
    while (index > 1) {
        index -= 1;
        const hi = edges[index];
        const lo = edges[index - 1];
        if (hi <= lo) continue;
        const mid = (hi + lo) / 2;
        _ = try tree.leaf(.{
            .width = .fill,
            .height = .{ .fixed = hi - lo },
            .fill = stripColor(mid, part_h, total_h, has_line, limit_h, day, theme),
        });
    }
    tree.close(column);
}

fn stripColor(y: f32, part_h: f32, total_h: f32, has_line: bool, limit_h: f32, day: Day, theme: *const Theme) Color {
    if (has_line and y >= limit_h and y < limit_h + 1) return theme.border;
    if (y < part_h) return day.part_fill;
    if (y < total_h) return day.fill;
    return .transparent;
}

fn finite(value: f32) f32 {
    if (!std.math.isFinite(value) or value < 0) return 0;
    return value;
}

fn sortEdges(edges: []f32) void {
    var i: usize = 1;
    while (i < edges.len) : (i += 1) {
        const key = edges[i];
        var j = i;
        while (j > 0 and edges[j - 1] > key) : (j -= 1) edges[j] = edges[j - 1];
        edges[j] = key;
    }
}
