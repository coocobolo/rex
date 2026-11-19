//! Charts for the dashboard and focus widget: progress marks (`bar`, `ring`,
//! `border` stadium pill, and `half_rings` concentric corner arcs), part shares
//! (`bar` strip or `donut`), and daily column bars.
//!
//! Lengths are `fraction`s of the parent, so a chart takes the size its
//! parent gives it. The caller chooses the colors; the limit line uses `border`.

const std = @import("std");

const Theme = @import("Theme.zig");
const Color = Theme.Color;
const Tree = @import("Tree.zig");
const Id = Tree.Id;

/// Thickness of a progress bar unless the caller gives one.
pub const thickness = 8;
/// Height of the share strip, and the room each segment leaves after it.
pub const strip_height = 12;
pub const strip_gap = 2;
/// Outer radius and thickness of the timer ring. The HTML draws a
/// centerline of 112 with a stroke of 6.
pub const ring_radius: f32 = 115;
pub const ring_thickness: f32 = 6;
/// Default stadium pill size and border stroke for `.border` focus progress.
pub const border_pill_width: f32 = 280;
pub const border_pill_height: f32 = 140;
pub const border_pill_thickness: u8 = 6;
/// Starting angle (`5π/4`, bottom-left) and clockwise span (`π`, semicircle to top-right)
/// for bottom-right corner `half_rings` gauges.
pub const half_ring_start: f32 = 5.0 * std.math.pi / 4.0;
pub const half_ring_sweep: f32 = std.math.pi;
pub const half_rings_count = 3;
/// Outer radius and thickness of the program donut. The HTML draws a
/// centerline of 54 with a stroke of 16.
pub const donut_radius: f32 = 62;
pub const donut_thickness: f32 = 16;
/// Gap between donut slices, along the centerline, in logical pixels.
pub const donut_gap: f32 = 2;

/// How one focus progress value or cycle state is drawn.
pub const ProgressMark = enum(u8) { bar, ring, border, half_rings };
/// Focus timer phase mapped onto the three concentric `half_rings` arcs.
pub const FocusPhase = enum(u8) { idle, task, short_break, long_break };
/// How named parts are drawn.
pub const ShareMark = enum { bar, donut };
/// How one value per day is drawn.
pub const DayMark = enum { bar };

/// Stadium-rounded border pill configuration for `openBorderPill`.
pub const BorderOptions = struct {
    width: Tree.Size = .fill,
    height: Tree.Size = .{ .fixed = border_pill_height },
    /// Height in logical pixels used to derive the stadium `height / 2` corner radius when `radius` is null.
    pill_height: f32 = border_pill_height,
    border_width: u8 = border_pill_thickness,
    radius: ?u8 = null,
    fill: Color = .transparent,
    track: Color,
    active: Color,
    fraction: f32,
    id: Id = .none,
    pointer: Tree.PointerShape = .arrow,
};

/// Three concentric `.round`-cap arc fractions for the `half_rings` focus mark:
/// outer task progress (`theme.info`), middle cycle progress (`theme.success`),
/// and inner break progress (`theme.warning`).
pub const HalfRings = struct {
    task: f32 = 0,
    cycle: f32 = 0,
    break_phase: f32 = 0,

    /// Concentric ring geometry and track opacity for `halfRings` and `halfRingsArcs`.
    pub const Options = struct {
        outer_radius: f32 = 58,
        thickness: f32 = 6,
        gap: f32 = 5,
        track_alpha: u8 = 24,
    };

    /// Maps the current focus timer phase, phase fraction, and cycle counts onto the three concentric arcs.
    pub fn fromCycle(
        phase: FocusPhase,
        fraction: f32,
        tasks_in_cycle: u8,
        tasks_before_long_break: u8,
    ) HalfRings {
        const clamped = clamp01(fraction);
        const cycle_frac = if (tasks_before_long_break == 0)
            0
        else
            clamp01(@as(f32, @floatFromInt(tasks_in_cycle)) / @as(f32, @floatFromInt(tasks_before_long_break)));
        return switch (phase) {
            .idle => .{ .task = 0, .cycle = cycle_frac, .break_phase = 0 },
            .task => .{ .task = clamped, .cycle = cycle_frac, .break_phase = 0 },
            .short_break, .long_break => .{ .task = 1.0, .cycle = cycle_frac, .break_phase = clamped },
        };
    }
};

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
/// The stadium pill track box and its overlaid `border_sweep` node.
pub const border_nodes = 2;
/// Three concentric track + active arc pairs emitted by `halfRingsArcs`.
pub const half_rings_arc_nodes = half_rings_count * 2;
/// The enclosing square box plus `half_rings_arc_nodes`.
pub const half_rings_nodes = 1 + half_rings_arc_nodes;

/// Stadium-pill corner radius (`ceil(height / 2)` clamped to `u8`) for a pill of `height` logical pixels.
pub fn pillRadius(height: f32) u8 {
    if (!std.math.isFinite(height) or height <= 0) return 0;
    return @intFromFloat(@min(255.0, @ceil(height * 0.5)));
}

/// Converts a `0..1` progress fraction into a `Tree.borderSweep` u16 parameter (`0` when empty, `1..65535` when active).
pub fn borderSweepValue(fraction: f32) u16 {
    const clamped = clamp01(fraction);
    if (clamped <= 0) return 0;
    return @max(1, @as(u16, @intFromFloat(@round(clamped * 65535.0))));
}

/// Opens a stadium-rounded pill box with a muted border track and an immediate overlaid
/// `Tree.borderSweep` child. The caller may append centered text or controls before closing the returned box.
pub fn openBorderPill(tree: *Tree, options: BorderOptions) Tree.Error!Tree.Index {
    const radius = options.radius orelse pillRadius(options.pill_height);
    const pill = try tree.open(.{
        .id = options.id,
        .width = options.width,
        .height = options.height,
        .fill = options.fill,
        .border = options.track,
        .border_width = options.border_width,
        .radius = radius,
        .pointer = options.pointer,
    });
    const sweep = borderSweepValue(options.fraction);
    _ = try tree.borderSweep(if (sweep > 0) sweep else 1, .{
        .overlay = true,
        .width = .fill,
        .height = .fill,
        .border = if (sweep > 0) options.active else .transparent,
        .border_width = options.border_width,
        .radius = radius,
    });
    return pill;
}

/// Appends the three concentric `.round`-cap track and active half-ring arc pairs as
/// `.overlay = true` children of the currently open anchor box.
pub fn halfRingsArcs(
    tree: *Tree,
    theme: *const Theme,
    rings: HalfRings,
    options: HalfRings.Options,
) Tree.Error!void {
    const step = options.thickness + options.gap;
    const specs = [half_rings_count]struct { radius: f32, fraction: f32, color: Color }{
        .{ .radius = options.outer_radius, .fraction = rings.task, .color = theme.info },
        .{ .radius = @max(1, options.outer_radius - step), .fraction = rings.cycle, .color = theme.success },
        .{ .radius = @max(1, options.outer_radius - step * 2), .fraction = rings.break_phase, .color = theme.warning },
    };
    for (specs) |spec| {
        try segment(tree, .{
            .radius = spec.radius,
            .thickness = options.thickness,
            .start = half_ring_start,
            .sweep = half_ring_sweep,
            .fill = spec.color.alpha(options.track_alpha),
            .caps = .round,
        }, .none);
        try segment(tree, .{
            .radius = spec.radius,
            .thickness = options.thickness,
            .start = half_ring_start,
            .sweep = clamp01(spec.fraction) * half_ring_sweep,
            .fill = spec.color,
            .caps = .round,
        }, .none);
    }
}

/// Draws a standalone square box containing the three concentric `half_rings` gauges.
pub fn halfRings(
    tree: *Tree,
    theme: *const Theme,
    rings: HalfRings,
    options: HalfRings.Options,
) Tree.Error!void {
    const side = options.outer_radius * 2;
    const square = try tree.open(.{
        .width = .{ .fixed = side },
        .height = .{ .fixed = side },
    });
    try halfRingsArcs(tree, theme, rings, options);
    tree.close(square);
}

/// The strip, then each part's slot and segment.
pub fn shareNodes(count: usize) usize {
    return 1 + count * 2;
}

/// The group, the row, each day's column (column, bar, part), and the
/// limit overlay (overlay, optional label box and text, hairline, spacer).
pub fn dayNodes(count: usize) usize {
    return 7 + count * 3;
}

pub const Limit = struct {
    value: f32,
    label: []const u8 = "",
};

/// The square, then one arc per part.
pub fn donutNodes(count: usize) usize {
    return 1 + count;
}

/// A track and the fraction of it that `fraction` fills. Values outside
/// 0..1 are clamped. `bar_height` is the bar's thickness; `ring`, `border`,
/// and `half_rings` use their own geometry.
pub fn progress(tree: *Tree, theme: *const Theme, mark: ProgressMark, fraction: f32, fill: Color, bar_height: f32) Tree.Error!void {
    switch (mark) {
        .bar => try fractionBar(tree, theme.muted, fill, fraction, bar_height),
        .ring => try ringChart(tree, theme, fraction, fill),
        .border => {
            const pill = try openBorderPill(tree, .{
                .track = theme.muted,
                .active = fill,
                .fraction = fraction,
            });
            tree.close(pill);
        },
        .half_rings => try halfRings(tree, theme, .{ .task = fraction }, .{}),
    }
}

/// Each part's share of the sum: one strip cut into segments, or a donut.
/// The names are not drawn; the surface lists them beside the chart.
pub fn share(tree: *Tree, theme: *const Theme, mark: ShareMark, parts: []const Part) Tree.Error!void {
    _ = theme;
    switch (mark) {
        .bar => try shareStrip(tree, parts),
        .donut => try donutChart(tree, parts),
    }
}

/// One column per day, as tall as the parent gives the row. `part` sits at
/// the bottom of `total`. `limit` is in the same unit as `total`; null
/// draws no line. The line spans the chart at the limit's height.
pub fn days(tree: *Tree, theme: *const Theme, mark: DayMark, items: []const Day, limit: ?Limit) Tree.Error!void {
    switch (mark) {
        .bar => try dayBars(tree, theme, items, limit),
    }
}

fn fractionBar(tree: *Tree, track: Color, fill: Color, fraction: f32, height: f32) Tree.Error!void {
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
fn shareStrip(tree: *Tree, parts: []const Part) Tree.Error!void {
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

fn dayBars(tree: *Tree, theme: *const Theme, items: []const Day, limit: ?Limit) Tree.Error!void {
    var scale: f32 = if (limit) |lim| finite(lim.value) else 0;
    for (items) |day| scale = @max(scale, finite(day.total));
    const group = try tree.open(.{
        .width = .fill,
        .height = .fill,
    });
    const row = try tree.open(.{
        .axis = .row,
        .width = .fill,
        .height = .fill,
        .gap = Theme.space,
    });
    for (items) |day| try dayColumn(tree, day, scale);
    tree.close(row);
    if (limit) |lim| {
        const overlay = try tree.open(.{
            .overlay = true,
            .width = .fill,
            .height = .fill,
            .padding = .{ .top = slot_pad, .bottom = slot_pad },
            .main = .end,
            .cross = .end,
        });
        if (lim.label.len > 0) {
            const label_box = try tree.open(.{ .padding = .{ .bottom = 4 } });
            _ = try tree.text(lim.label, .{ .color = theme.muted_foreground, .style = .xs });
            tree.close(label_box);
        }
        _ = try tree.dash(.{ .color = theme.border, .step = 3 }, .{ .width = .fill, .height = .{ .fixed = 1 } });
        _ = try tree.leaf(.{ .width = .fill, .height = .{ .fraction = if (scale == 0) 0 else finite(lim.value) / scale } });
        tree.close(overlay);
    }
    tree.close(group);
}

/// A column the row's height. Its bar stands on the baseline at `total`
/// of the scale, the part inside it at `part` of the bar.
fn dayColumn(tree: *Tree, day: Day, scale: f32) Tree.Error!void {
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
    tree.close(column);
}

const turn = std.math.tau;

fn ringChart(tree: *Tree, theme: *const Theme, fraction: f32, fill: Color) Tree.Error!void {
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
    }, .none);
    try segment(tree, .{
        .radius = ring_radius,
        .thickness = ring_thickness,
        .sweep = clamp01(fraction) * turn,
        .fill = fill,
        .caps = .round,
    }, .none);
    tree.close(square);
}

fn donutChart(tree: *Tree, parts: []const Part) Tree.Error!void {
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
        }, part.id);
        cursor += sweep + gap;
    }
    tree.close(square);
}

fn segment(tree: *Tree, arc: Tree.Arc, id: Tree.Id) Tree.Error!void {
    _ = try tree.arc(arc, .{ .id = id, .overlay = true, .width = .fill, .height = .fill });
}

fn clamp01(value: f32) f32 {
    if (!std.math.isFinite(value)) return 0;
    return @min(1, @max(0, value));
}

fn finite(value: f32) f32 {
    if (!std.math.isFinite(value) or value < 0) return 0;
    return value;
}
