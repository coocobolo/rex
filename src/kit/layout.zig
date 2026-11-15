//! Lays out a `Tree`: gives every node its rectangle in logical pixels,
//! and converts logical rectangles to physical pixels for painting.
//!
//! The rules are few. A box places its children in a row or a column with
//! padding around them and a gap between them. A size is `fixed`, `fit`
//! (as large as the content), `fill` (a share of what the parent has
//! left), `at_most` (fixed, but giving way to a smaller parent),
//! `fit_at_most` (as large as the content, with a maximum), `at_least`
//! (as large as the content, with a minimum) or `fraction` (that much of
//! the parent's inner size). Text wraps to the width it ends up with. Roots are laid out
//! against the viewport, from its top left, and stack in drawing order.
//!
//! Widths are settled before heights, because a text's height depends on
//! the width it wraps to: fit widths bottom-up, share out widths top-down,
//! wrap, then the same two passes for heights, then positions. Each root
//! goes through the passes in turn, in drawing order; each pass is one walk
//! over that root's nodes. Nothing allocates.

const std = @import("std");
const assert = std.debug.assert;

const text = @import("text.zig");
const Tree = @import("Tree.zig");
const Node = Tree.Node;
const Index = Tree.Index;
const Rect = Tree.Rect;
const Size = Tree.Size;

pub const Error = error{OutOfLines};

/// Sets `rect` on every node of `tree` for a window of `viewport_width` by
/// `viewport_height` logical pixels. Every box must be closed.
///
/// Roots are laid out one after another in drawing order, so an anchored
/// root (`Tree.anchorTo`) finds its anchor already placed. Callers usually
/// invoke this via `Tree.layout`.
pub fn run(tree: *Tree, measurer: text.Measurer, viewport_width: f32, viewport_height: f32) Error!void {
    assert(tree.current == Tree.none);
    tree.lines.len = 0;
    const nodes = tree.nodes[0..tree.len];
    var root: Index = 0;
    while (root < nodes.len) {
        const range: Range = .{ .start = root, .end = nodes[root].end };
        const anchor = tree.anchorOf(root);
        const target: ?Rect = if (anchor) |a| switch (a.target()) {
            .node => |id| if (findBefore(nodes, root, id)) |node| node.rect else null,
            .point => null,
        } else null;

        fit(nodes, range, .horizontal, measurer);
        // Optionally match or exceed its anchor's width (e.g. dropdown menus).
        if (target) |rect| if (anchor.?.match_anchor_width) switch (nodes[root].box.width) {
            .fit, .at_least => nodes[root].rect.w = @max(nodes[root].rect.w, rect.w),
            .fit_at_most => |value| nodes[root].rect.w = @min(@max(nodes[root].rect.w, rect.w), @max(0, value)),
            .fill, .fixed, .at_most, .fraction => {},
        };
        distribute(nodes, range, .horizontal, viewport_width, tree);
        try wrapTexts(tree, range, measurer);
        fit(nodes, range, .vertical, measurer);
        distribute(nodes, range, .vertical, viewport_height, tree);
        place(nodes, range);
        // Before later roots anchor to nodes inside any scrolling region.
        scrollRange(tree, nodes, range);
        if (anchor) |a| switch (a.target()) {
            .node => if (target) |rect| {
                const at = placeAnchored(nodes[root].rect, rect, viewport_width, viewport_height, a.options());
                tree.translate(root, at.x, at.y);
            },
            .point => |pt| {
                const at = anchorPointPosition(nodes[root].rect, pt.x, pt.y, viewport_width, viewport_height);
                tree.translate(root, at.x, at.y);
            },
        };
        root = range.end;
    }
}

/// Between an anchored root and its anchor, in logical pixels.
pub const anchor_gap = 4;
/// The least room an anchored root keeps from the window's edges.
pub const anchor_margin = 8;

const point_gap: f32 = 12;

/// Computes top-left viewport coordinates for a rectangle of size `own` placed
/// against `target` according to `options` (`side`, `alignment`, `gap`, `margin`).
pub fn placeAnchored(
    own: Rect,
    target: Rect,
    viewport_width: f32,
    viewport_height: f32,
    options: Tree.Anchor.Options,
) Tree.Anchor.Point {
    const gap: f32 = @floatFromInt(options.gap);
    const margin: f32 = @floatFromInt(options.margin);
    return switch (options.side) {
        .auto => placeAuto(own, target, viewport_width, viewport_height, options.alignment, gap, margin),
        .below, .above => .{
            .x = alignCross(target.x, target.w, own.w, margin, viewport_width, options.alignment),
            .y = placeAxis(target.y - gap, target.y + target.h + gap, own.h, margin, viewport_height, options.side == .above),
        },
        .left, .right => .{
            .x = placeAxis(target.x - gap, target.x + target.w + gap, own.w, margin, viewport_width, options.side == .left),
            .y = alignCross(target.y, target.h, own.h, margin, viewport_height, options.alignment),
        },
    };
}

fn placeAuto(
    own: Rect,
    target: Rect,
    viewport_width: f32,
    viewport_height: f32,
    alignment: Tree.Anchor.Alignment,
    gap: f32,
    margin: f32,
) Tree.Anchor.Point {
    const Candidate = enum { below, above, left, right };
    const room_left = target.x - gap - margin;
    const room_right = viewport_width - margin - (target.x + target.w + gap);
    const order: [4]Candidate = if (room_right >= room_left)
        .{ .below, .above, .right, .left }
    else
        .{ .below, .above, .left, .right };

    const max_x = @max(margin, viewport_width - margin - own.w);
    const max_y = @max(margin, viewport_height - margin - own.h);
    var best_x: f32 = margin;
    var best_y: f32 = margin;
    var best_overlap: f32 = std.math.inf(f32);

    for (order) |side| {
        const raw_x = switch (side) {
            .below, .above => alignCross(target.x, target.w, own.w, margin, viewport_width, alignment),
            .left => target.x - gap - own.w,
            .right => target.x + target.w + gap,
        };
        const raw_y = switch (side) {
            .below => target.y + target.h + gap,
            .above => target.y - gap - own.h,
            .left, .right => alignCross(target.y, target.h, own.h, margin, viewport_height, alignment),
        };
        const x = clamp(raw_x, margin, max_x);
        const y = clamp(raw_y, margin, max_y);
        const fits = switch (side) {
            .below => y >= target.y + target.h + gap and y + own.h <= viewport_height - margin,
            .above => y + own.h <= target.y - gap and y >= margin,
            .left => x + own.w <= target.x - gap and x >= margin,
            .right => x >= target.x + target.w + gap and x + own.w <= viewport_width - margin,
        };
        if (fits) return .{ .x = x, .y = y };
        const overlap = rectOverlapArea(x, y, own.w, own.h, target);
        if (overlap < best_overlap) {
            best_overlap = overlap;
            best_x = x;
            best_y = y;
        }
    }
    return .{ .x = best_x, .y = best_y };
}

fn alignCross(anchor_pos: f32, anchor_span: f32, own_span: f32, margin: f32, viewport: f32, alignment: Tree.Anchor.Alignment) f32 {
    const max_pos = @max(margin, viewport - margin - own_span);
    const pos = switch (alignment) {
        .start => anchor_pos,
        .center => anchor_pos + (anchor_span - own_span) * 0.5,
        .end => anchor_pos + anchor_span - own_span,
        .flush => blk: {
            const centered = anchor_pos + (anchor_span - own_span) * 0.5;
            if (centered < margin) break :blk anchor_pos;
            if (centered + own_span > viewport - margin) break :blk anchor_pos + anchor_span - own_span;
            break :blk centered;
        },
    };
    return clamp(pos, margin, max_pos);
}

fn rectOverlapArea(ax: f32, ay: f32, aw: f32, ah: f32, b: Rect) f32 {
    const ox = @max(0, @min(ax + aw, b.x + b.w) - @max(ax, b.x));
    const oy = @max(0, @min(ay + ah, b.y + b.h) - @max(ay, b.y));
    return ox * oy;
}

fn anchorPointPosition(own: Rect, px: f32, py: f32, viewport_width: f32, viewport_height: f32) Tree.Anchor.Point {
    return .{
        .x = placeAxis(px - point_gap, px + point_gap, own.w, anchor_margin, viewport_width, false),
        .y = placeAxis(py - point_gap, py + point_gap, own.h, anchor_margin, viewport_height, false),
    };
}

fn placeAxis(before_edge: f32, after_edge: f32, span: f32, margin: f32, viewport: f32, prefer_before: bool) f32 {
    const room_before = before_edge - margin;
    const room_after = viewport - margin - after_edge;
    const use_before = if (prefer_before)
        span <= room_before or room_before >= room_after
    else
        !(span <= room_after or room_after >= room_before);
    const pos = if (use_before) before_edge - span else after_edge;
    return clamp(pos, margin, viewport - margin - span);
}

/// `value` within `low` and `high`; `low` wins when they cross, so a root
/// larger than the window keeps its top left in view.
fn clamp(value: f32, low: f32, high: f32) f32 {
    return @max(low, @min(value, high));
}

fn findBefore(nodes: []const Node, end: Index, id: Tree.Id) ?*const Node {
    if (id == .none) return null;
    for (nodes[0..end]) |*node| {
        if (node.box.id == id) return node;
    }
    return null;
}

/// One root and its descendants: `nodes[start..end]`.
const Range = struct { start: Index, end: Index };

const Dimension = enum { horizontal, vertical };

fn extent(node: *Node, comptime dimension: Dimension) *f32 {
    return switch (dimension) {
        .horizontal => &node.rect.w,
        .vertical => &node.rect.h,
    };
}

fn size(node: *const Node, comptime dimension: Dimension) Size {
    return switch (dimension) {
        .horizontal => node.box.width,
        .vertical => node.box.height,
    };
}

fn padding(node: *const Node, comptime dimension: Dimension) f32 {
    const p = node.box.padding;
    return switch (dimension) {
        .horizontal => @floatFromInt(@as(u16, p.left) + p.right),
        .vertical => @floatFromInt(@as(u16, p.top) + p.bottom),
    };
}

/// Whether `dimension` runs along the box's axis (children are summed)
/// or across it (the largest child counts).
fn isAlong(node: *const Node, comptime dimension: Dimension) bool {
    return (node.box.axis == .row) == (dimension == .horizontal);
}

const Children = struct {
    nodes: []Node,
    next_index: Index,
    end: Index,

    fn next(self: *Children) ?*Node {
        if (self.next_index >= self.end) return null;
        const child = &self.nodes[self.next_index];
        self.next_index = child.end;
        return child;
    }
};

fn children(nodes: []Node, parent: usize) Children {
    return .{ .nodes = nodes, .next_index = @intCast(parent + 1), .end = nodes[parent].end };
}

const wrap_epsilon: f32 = 1e-3;

const WrappedLines = struct {
    nodes: []Node,
    next_index: Index,
    end: Index,
    inner_w: f32,
    gap: f32,

    const Slice = struct {
        start: Index,
        end: Index,
        width: f32,
        height: f32,
    };

    fn next(self: *WrappedLines) ?Slice {
        while (self.next_index < self.end and self.nodes[self.next_index].box.overlay) {
            self.next_index = self.nodes[self.next_index].end;
        }
        if (self.next_index >= self.end) return null;

        const line_start = self.next_index;
        var line_w: f32 = 0;
        var line_h: f32 = 0;
        var count: u32 = 0;
        while (self.next_index < self.end) {
            const child = &self.nodes[self.next_index];
            if (child.box.overlay) {
                self.next_index = child.end;
                continue;
            }
            const needed = child.rect.w + if (count > 0) self.gap else 0;
            if (count > 0 and line_w + needed > self.inner_w + wrap_epsilon) break;
            line_w += needed;
            line_h = @max(line_h, child.rect.h);
            count += 1;
            self.next_index = child.end;
        }
        return .{ .start = line_start, .end = self.next_index, .width = line_w, .height = line_h };
    }
};

fn wrappedLines(nodes: []Node, index: usize) WrappedLines {
    const node = &nodes[index];
    return .{
        .nodes = nodes,
        .next_index = @intCast(index + 1),
        .end = node.end,
        .inner_w = @max(0, node.rect.w - padding(node, .horizontal)),
        .gap = @floatFromInt(node.box.gap),
    };
}

/// What the children of a box need in `dimension`, padding included.
fn contentExtent(nodes: []Node, index: usize, comptime dimension: Dimension, comptime allow_wrap: bool) f32 {
    const node = &nodes[index];
    if (allow_wrap and node.box.wrap) {
        var total: f32 = 0;
        var line_count: u32 = 0;
        var lines = wrappedLines(nodes, index);
        while (lines.next()) |line| {
            switch (dimension) {
                .vertical => total += line.height,
                .horizontal => total = @max(total, line.width),
            }
            line_count += 1;
        }
        if (dimension == .vertical and line_count > 1) {
            total += @floatFromInt(@as(u32, node.box.gap) * (line_count - 1));
        }
        return total + padding(node, dimension);
    }
    const along = isAlong(node, dimension);
    var total: f32 = 0;
    var count: u32 = 0;
    var it = children(nodes, index);
    while (it.next()) |child| {
        if (child.box.overlay) continue;
        const child_extent = extent(child, dimension).*;
        total = if (along) total + child_extent else @max(total, child_extent);
        count += 1;
    }
    if (along and count > 1) total += @floatFromInt(@as(u32, node.box.gap) * (count - 1));
    return total + padding(node, dimension);
}

/// Bottom-up: each node's extent becomes its fixed size, or what its
/// content needs. Children come after their parent in the array, so a
/// backward walk sees them first. Wrapped texts already have their height.
fn fit(nodes: []Node, range: Range, comptime dimension: Dimension, measurer: text.Measurer) void {
    var i: usize = range.end;
    while (i > range.start) {
        i -= 1;
        const node = &nodes[i];
        const content: f32 = switch (node.content) {
            .text => |t| switch (dimension) {
                .horizontal => switch (t.wrap) {
                    .word => measurer.width(t.bytes, t.style, t.figures),
                    .none => text.maxLineWidth(measurer, t.bytes, t.style, t.figures),
                    .ellipsis => blk: {
                        const nl = std.mem.indexOfScalar(u8, t.bytes, '\n');
                        const slice_w = measurer.width(t.bytes[0 .. nl orelse t.bytes.len], t.style, t.figures);
                        break :blk if (nl != null) slice_w + measurer.width(text.ellipsis_bytes, t.style, t.figures) else slice_w;
                    },
                },
                .vertical => node.rect.h,
            },
            .icon => |icon| @floatFromInt(icon.size),
            .arc => |arc| arc.radius * 2,
            .box, .dash, .border_sweep => contentExtent(nodes, i, dimension, dimension == .vertical),
        };
        extent(node, dimension).* = switch (size(node, dimension)) {
            .fixed, .at_most => |value| value,
            .fit_at_most => |value| @min(content, @max(0, value)),
            .at_least => |value| @max(content, value),
            .fraction => 0,
            .fit, .fill => content,
        };
    }
}

/// Top-down: the root takes its extent from the viewport, then every box
/// hands its inner extent out to its children.
fn distribute(nodes: []Node, range: Range, comptime dimension: Dimension, viewport: f32, tree: *const Tree) void {
    const root = &nodes[range.start];
    const own = extent(root, dimension);
    own.* = switch (size(root, dimension)) {
        .fixed => |value| value,
        .fill => viewport,
        .fraction => |value| viewport * clamp01(value),
        .fit, .at_most, .fit_at_most, .at_least => @min(own.*, viewport),
    };
    for (nodes[range.start..range.end], range.start..) |*node, i| {
        if (node.content != .box) continue;
        const inner = @max(0, extent(node, dimension).* - padding(node, dimension));
        if (isAlong(node, dimension)) {
            const scrolls = node.box.overflow == .clip and tree.hasScrollRegion(@intCast(i));
            distributeAlong(nodes, i, dimension, inner, scrolls);
        } else {
            var it = children(nodes, i);
            while (it.next()) |child| {
                const child_extent = extent(child, dimension);
                if (child.box.overlay) {
                    child_extent.* = inner;
                    continue;
                }
                child_extent.* = switch (size(child, dimension)) {
                    .fixed => |value| value,
                    .fill => inner,
                    .fraction => |value| inner * clamp01(value),
                    .fit, .at_most, .fit_at_most, .at_least => if (child.box.shrink) @min(child_extent.*, inner) else child_extent.*,
                };
            }
        }
    }
}

/// Along the axis: `fill` children share what the others leave. Without a
/// `fill` child, an overflow is taken from the largest child that is not
/// `fixed`, which is what makes a long text in a row wrap instead of
/// spilling out; a clipping box keeps its children's sizes and cuts them
/// instead.
/// In a scroll region a `fill` child takes at least what its content needs:
/// content that does not fit scrolls rather than being squeezed.
fn distributeAlong(nodes: []Node, index: usize, comptime dimension: Dimension, inner: f32, scrolls: bool) void {
    if (nodes[index].box.wrap) {
        distributeWrapped(nodes, index, dimension, inner, scrolls);
        return;
    }
    var used: f32 = 0;
    var count: u32 = 0;
    var fills: u32 = 0;
    var largest_fit: ?*Node = null;
    var it = children(nodes, index);
    while (it.next()) |child| {
        if (child.box.overlay) {
            extent(child, dimension).* = inner;
            continue;
        }
        count += 1;
        switch (size(child, dimension)) {
            .fill => fills += 1,
            .fixed => used += extent(child, dimension).*,
            .fraction => |value| {
                const taken = inner * clamp01(value);
                extent(child, dimension).* = taken;
                used += taken;
            },
            .fit, .at_most, .fit_at_most, .at_least => {
                used += extent(child, dimension).*;
                if (child.box.shrink and (largest_fit == null or extent(child, dimension).* > extent(largest_fit.?, dimension).*)) {
                    largest_fit = child;
                }
            },
        }
    }
    if (count > 1) used += @floatFromInt(@as(u32, nodes[index].box.gap) * (count - 1));

    if (fills > 0) {
        const share = @max(0, inner - used) / @as(f32, @floatFromInt(fills));
        it = children(nodes, index);
        while (it.next()) |child| {
            if (child.box.overlay) continue;
            if (size(child, dimension) == .fill) {
                const own = extent(child, dimension);
                // `fit` left the content's extent here.
                own.* = if (scrolls) @max(share, own.*) else share;
            }
        }
    } else if (used > inner and nodes[index].box.overflow == .visible) {
        if (largest_fit) |child| {
            const child_extent = extent(child, dimension);
            child_extent.* = @max(0, child_extent.* - (used - inner));
        }
    }
}

fn distributeWrapped(nodes: []Node, index: usize, comptime dimension: Dimension, inner: f32, scrolls: bool) void {
    var it = children(nodes, index);
    while (it.next()) |child| {
        const child_extent = extent(child, dimension);
        if (child.box.overlay) {
            child_extent.* = inner;
            continue;
        }
        child_extent.* = switch (size(child, dimension)) {
            .fixed => |value| value,
            .fill => if (scrolls) @max(inner, child_extent.*) else inner,
            .fraction => |value| inner * clamp01(value),
            .fit, .at_most, .fit_at_most, .at_least => if (child.box.shrink) @min(child_extent.*, inner) else child_extent.*,
        };
    }
}

const thumb_thickness: f32 = 4;
const thumb_inset: f32 = 2;
const thumb_track_pad: f32 = 4;
const thumb_min_len: f32 = 24;

/// Shifts each scroll region's descendants left/up by its clamped offset,
/// records the region's `max.{x,y}` extent beyond its box, and places its
/// optional scrollbar thumb inside its viewport.
fn scrollRange(tree: *Tree, nodes: []Node, range: Range) void {
    for (tree.scrolls[0..tree.scroll_len]) |*region| {
        if (region.node < range.start or region.node >= range.end) continue;
        const index = region.node;
        const box_node = &nodes[index];
        region.max = .{
            .x = @max(0, contentExtent(nodes, index, .horizontal, true) - box_node.rect.w),
            .y = @max(0, contentExtent(nodes, index, .vertical, true) - box_node.rect.h),
        };
        const moved_x = if (std.math.isNan(region.offset.x)) 0 else std.math.clamp(region.offset.x, 0, region.max.x);
        const moved_y = if (std.math.isNan(region.offset.y)) 0 else std.math.clamp(region.offset.y, 0, region.max.y);
        if (moved_x > 0 or moved_y > 0) {
            for (nodes[index + 1 .. box_node.end]) |*child| {
                child.rect.x -= moved_x;
                child.rect.y -= moved_y;
            }
        }
        if (region.thumb != Tree.none) {
            placeScrollThumb(&nodes[region.thumb], box_node.rect, moved_x, moved_y, region.max);
        }
    }
}

fn placeScrollThumb(thumb: *Node, viewport: Rect, moved_x: f32, moved_y: f32, max: Tree.Scroll.Max) void {
    if (max.y > 0 and viewport.w > thumb_thickness + thumb_inset * 2 and viewport.h > thumb_track_pad * 2) {
        const track_h = viewport.h - thumb_track_pad * 2;
        const total_h = viewport.h + max.y;
        const min_h = @min(thumb_min_len, track_h);
        const thumb_h = @max(min_h, track_h * (viewport.h / total_h));
        const travel = @max(0, track_h - thumb_h);
        const ratio = std.math.clamp(moved_y / max.y, 0, 1);
        thumb.rect = .{
            .x = viewport.x + viewport.w - thumb_thickness - thumb_inset,
            .y = viewport.y + thumb_track_pad + travel * ratio,
            .w = thumb_thickness,
            .h = thumb_h,
        };
        return;
    }
    if (max.x > 0 and viewport.h > thumb_thickness + thumb_inset * 2 and viewport.w > thumb_track_pad * 2) {
        const track_w = viewport.w - thumb_track_pad * 2;
        const total_w = viewport.w + max.x;
        const min_w = @min(thumb_min_len, track_w);
        const thumb_w = @max(min_w, track_w * (viewport.w / total_w));
        const travel = @max(0, track_w - thumb_w);
        const ratio = std.math.clamp(moved_x / max.x, 0, 1);
        thumb.rect = .{
            .x = viewport.x + thumb_track_pad + travel * ratio,
            .y = viewport.y + viewport.h - thumb_thickness - thumb_inset,
            .w = thumb_w,
            .h = thumb_thickness,
        };
        return;
    }
    thumb.rect = .{ .x = viewport.x, .y = viewport.y, .w = 0, .h = 0 };
}

/// Fits or wraps every text node's lines to the width it was given and sets its height.
fn wrapTexts(tree: *Tree, range: Range, measurer: text.Measurer) Error!void {
    for (tree.nodes[range.start..range.end]) |*node| {
        switch (node.content) {
            .text => |*t| {
                t.first_line = tree.lines.len;
                t.line_count = switch (t.wrap) {
                    .word => try text.wrap(measurer, t.bytes, t.style, t.figures, node.rect.w, &tree.lines),
                    .none => try text.wrapNone(measurer, t.bytes, t.style, t.figures, &tree.lines),
                    .ellipsis => try text.wrapEllipsis(measurer, t.bytes, t.style, t.figures, node.rect.w, &tree.lines),
                };
                node.rect.h = @floatFromInt(t.line_count * t.style.metrics().line_height);
            },
            .box, .dash, .border_sweep, .icon, .arc => {},
        }
    }
}

/// Top-down: the root sits at the viewport's top left; every box positions
/// its children inside its padding, aligned along and across its axis.
fn place(nodes: []Node, range: Range) void {
    nodes[range.start].rect.x = 0;
    nodes[range.start].rect.y = 0;
    for (nodes[range.start..range.end], range.start..) |*node, i| {
        if (node.content != .box) continue;
        switch (node.box.axis) {
            .row => placeChildren(nodes, i, .horizontal),
            .column => placeChildren(nodes, i, .vertical),
        }
    }
}

fn placeChildren(nodes: []Node, index: usize, comptime along: Dimension) void {
    const across: Dimension = switch (along) {
        .horizontal => .vertical,
        .vertical => .horizontal,
    };
    const node = &nodes[index];
    const box = node.box;
    const origin_x = node.rect.x + @as(f32, @floatFromInt(box.padding.left));
    const origin_y = node.rect.y + @as(f32, @floatFromInt(box.padding.top));
    const inner_along = @max(0, extent(node, along).* - padding(node, along));
    const inner_across = @max(0, extent(node, across).* - padding(node, across));
    if (box.wrap) {
        placeWrappedChildren(nodes, index, origin_x, origin_y, inner_along);
        return;
    }
    const free = if (box.main == .start)
        0
    else
        @max(0, inner_along - (contentExtent(nodes, index, along, false) - padding(node, along)));

    var cursor = offset(box.main, free);
    var it = children(nodes, index);
    while (it.next()) |child| {
        if (child.box.overlay) {
            child.rect.x = origin_x;
            child.rect.y = origin_y;
            continue;
        }
        const across_offset = offset(box.cross, @max(0, inner_across - extent(child, across).*));
        switch (along) {
            .horizontal => {
                child.rect.x = origin_x + cursor;
                child.rect.y = origin_y + across_offset;
            },
            .vertical => {
                child.rect.x = origin_x + across_offset;
                child.rect.y = origin_y + cursor;
            },
        }
        cursor += extent(child, along).* + @as(f32, @floatFromInt(box.gap));
    }
}

fn placeWrappedChildren(nodes: []Node, index: usize, origin_x: f32, origin_y: f32, inner_w: f32) void {
    const box = nodes[index].box;
    var line_y = origin_y;
    var cursor_i: Index = @intCast(index + 1);
    const end = nodes[index].end;
    var lines = wrappedLines(nodes, index);
    while (lines.next()) |line| {
        while (cursor_i < line.start) {
            const skipped = &nodes[cursor_i];
            if (skipped.box.overlay) {
                skipped.rect.x = origin_x;
                skipped.rect.y = origin_y;
            }
            cursor_i = skipped.end;
        }
        var cursor_x = offset(box.main, @max(0, inner_w - line.width));
        while (cursor_i < line.end) {
            const child = &nodes[cursor_i];
            cursor_i = child.end;
            if (child.box.overlay) {
                child.rect.x = origin_x;
                child.rect.y = origin_y;
                continue;
            }
            child.rect.x = origin_x + cursor_x;
            child.rect.y = line_y + offset(box.cross, @max(0, line.height - child.rect.h));
            cursor_x += child.rect.w + @as(f32, @floatFromInt(box.gap));
        }
        line_y += line.height + @as(f32, @floatFromInt(box.gap));
    }
    while (cursor_i < end) {
        const child = &nodes[cursor_i];
        if (child.box.overlay) {
            child.rect.x = origin_x;
            child.rect.y = origin_y;
        }
        cursor_i = child.end;
    }
}

fn clamp01(value: f32) f32 {
    return @min(1, @max(0, value));
}

fn offset(alignment: Tree.Align, free: f32) f32 {
    return switch (alignment) {
        .start => 0,
        .center => free / 2,
        .end => free,
    };
}

/// A rectangle in physical pixels.
pub const PixelRect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
};

/// `rect` in physical pixels at `scale` (1.25 for 125%). Each edge is
/// rounded on its own, so two rectangles that share an edge in logical
/// pixels share it in physical pixels too, with no gap or overlap at a
/// fractional scale.
pub fn snap(rect: Rect, scale: f32) PixelRect {
    const left: i32 = @intFromFloat(@round(rect.x * scale));
    const top: i32 = @intFromFloat(@round(rect.y * scale));
    const right: i32 = @intFromFloat(@round((rect.x + rect.w) * scale));
    const bottom: i32 = @intFromFloat(@round((rect.y + rect.h) * scale));
    return .{ .x = left, .y = top, .w = right - left, .h = bottom - top };
}

/// A stroke of `width` logical pixels in physical pixels: rounded, but
/// never thinner than one pixel, so a hairline survives every scale.
pub fn strokePixels(width: u8, scale: f32) u32 {
    if (width == 0) return 0;
    return @max(1, @as(u32, @intFromFloat(@round(@as(f32, @floatFromInt(width)) * scale))));
}
