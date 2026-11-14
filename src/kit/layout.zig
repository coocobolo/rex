//! Lays out a `Tree`: gives every node its rectangle in logical pixels,
//! and converts logical rectangles to physical pixels for painting.
//!
//! The rules are few. A box places its children in a row or a column with
//! padding around them and a gap between them. A size is `fixed`, `fit`
//! (as large as the content), `fill` (a share of what the parent has
//! left), `at_most` (fixed, but giving way to a smaller parent), `at_least`
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
const tree_zig = @import("tree.zig");
const Tree = tree_zig.Tree;
const Node = tree_zig.Node;
const Index = tree_zig.Index;
const Rect = tree_zig.Rect;
const Size = tree_zig.Size;

pub const Error = error{OutOfLines};

/// Sets `rect` on every node of `tree` for a window of `viewport_width` by
/// `viewport_height` logical pixels. Every box must be closed.
///
/// Roots are laid out one after another in drawing order, so an anchored
/// root (`Tree.anchorTo`) finds its anchor already placed.
pub fn layout(tree: *Tree, measurer: text.Measurer, viewport_width: f32, viewport_height: f32) Error!void {
    assert(tree.current == tree_zig.none);
    tree.lines.len = 0;
    const nodes = tree.nodes[0..tree.len];
    var root: Index = 0;
    while (root < nodes.len) {
        const range: Range = .{ .start = root, .end = nodes[root].end };
        const anchor = tree.anchorOf(root);
        const target: ?Rect = if (anchor) |a| if (findBefore(nodes, root, a.target)) |node| node.rect else null else null;

        fit(nodes, range, .horizontal, measurer);
        // At least as wide as its anchor, as a dropdown list is.
        if (target) |rect| switch (nodes[root].box.width) {
            .fit, .at_least => nodes[root].rect.w = @max(nodes[root].rect.w, rect.w),
            .fill, .fixed, .at_most, .fraction => {},
        };
        distribute(nodes, range, .horizontal, viewport_width);
        try wrapTexts(tree, range, measurer);
        fit(nodes, range, .vertical, measurer);
        distribute(nodes, range, .vertical, viewport_height);
        place(nodes, range);
        // Before later roots anchor to nodes inside the region.
        if (tree.scroll_index >= range.start and tree.scroll_index < range.end) scroll(tree, nodes);
        if (target) |rect| {
            const at = anchorPosition(nodes[root].rect, rect, viewport_width, viewport_height);
            tree.translate(root, at.x, at.y);
        }
        root = range.end;
    }
}

/// Between an anchored root and its anchor, in logical pixels.
pub const anchor_gap = 4;
/// The least room an anchored root keeps from the window's edges.
pub const anchor_margin = 8;

/// Where an anchored root of size `own` goes against `target`: below it,
/// left edges aligned; above it when it does not fit below and there is
/// more room above; then moved inside the window's margin.
fn anchorPosition(own: Rect, target: Rect, viewport_width: f32, viewport_height: f32) struct { x: f32, y: f32 } {
    const below = target.y + target.h + anchor_gap;
    const above = target.y - anchor_gap - own.h;
    const room_below = viewport_height - anchor_margin - below;
    const room_above = above - anchor_margin;
    const y = if (own.h <= room_below or room_below >= room_above) below else above;
    return .{
        .x = clamp(target.x, anchor_margin, viewport_width - anchor_margin - own.w),
        .y = clamp(y, anchor_margin, viewport_height - anchor_margin - own.h),
    };
}

/// `value` within `low` and `high`; `low` wins when they cross, so a root
/// larger than the window keeps its top left in view.
fn clamp(value: f32, low: f32, high: f32) f32 {
    return @max(low, @min(value, high));
}

fn findBefore(nodes: []const Node, end: Index, id: tree_zig.Id) ?*const Node {
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

/// What the children of a box need in `dimension`, padding included.
fn contentExtent(nodes: []Node, index: usize, comptime dimension: Dimension) f32 {
    const node = &nodes[index];
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
                .horizontal => measurer.width(t.bytes, t.style, t.figures),
                .vertical => node.rect.h,
            },
            .icon => |icon| @floatFromInt(icon.size),
            .arc => |arc| arc.radius * 2,
            .box => contentExtent(nodes, i, dimension),
        };
        extent(node, dimension).* = switch (size(node, dimension)) {
            .fixed, .at_most => |value| value,
            .at_least => |value| @max(content, value),
            .fraction => 0,
            .fit, .fill => content,
        };
    }
}

/// Top-down: the root takes its extent from the viewport, then every box
/// hands its inner extent out to its children.
fn distribute(nodes: []Node, range: Range, comptime dimension: Dimension, viewport: f32) void {
    const root = &nodes[range.start];
    const own = extent(root, dimension);
    own.* = switch (size(root, dimension)) {
        .fixed => |value| value,
        .fill => viewport,
        .fraction => |value| viewport * clamp01(value),
        .fit, .at_most, .at_least => @min(own.*, viewport),
    };
    for (nodes[range.start..range.end], range.start..) |*node, i| {
        if (node.content != .box) continue;
        const inner = @max(0, extent(node, dimension).* - padding(node, dimension));
        if (isAlong(node, dimension)) {
            distributeAlong(nodes, i, dimension, inner);
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
                    .fit, .at_most, .at_least => @min(child_extent.*, inner),
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
fn distributeAlong(nodes: []Node, index: usize, comptime dimension: Dimension, inner: f32) void {
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
            .fit, .at_most, .at_least => {
                used += extent(child, dimension).*;
                if (largest_fit == null or extent(child, dimension).* > extent(largest_fit.?, dimension).*) {
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
            if (size(child, dimension) == .fill) extent(child, dimension).* = share;
        }
    } else if (used > inner and nodes[index].box.overflow == .visible) {
        if (largest_fit) |child| {
            const child_extent = extent(child, dimension);
            child_extent.* = @max(0, child_extent.* - (used - inner));
        }
    }
}

/// Moves the scroll region's content up by its offset, capped at what the
/// content has beyond the region, and records that cap. The region clips,
/// so the content kept its own height in `distribute`.
fn scroll(tree: *Tree, nodes: []Node) void {
    const index = tree.scroll_index;
    const region = &nodes[index];
    tree.scroll_max = @max(0, contentExtent(nodes, index, .vertical) - region.rect.h);
    const moved = std.math.clamp(tree.scroll_offset, 0, tree.scroll_max);
    // Also false for a NaN offset.
    if (!(moved > 0)) return;
    for (nodes[index + 1 .. region.end]) |*node| node.rect.y -= moved;
}

/// Wraps every text to the width it was given and sets its height.
fn wrapTexts(tree: *Tree, range: Range, measurer: text.Measurer) Error!void {
    for (tree.nodes[range.start..range.end]) |*node| {
        switch (node.content) {
            .text => |*t| {
                t.first_line = tree.lines.len;
                t.line_count = try text.wrap(measurer, t.bytes, t.style, t.figures, node.rect.w, &tree.lines);
                node.rect.h = @floatFromInt(t.line_count * t.style.metrics().line_height);
            },
            .box, .icon, .arc => {},
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
    const free = @max(0, inner_along - (contentExtent(nodes, index, along) - padding(node, along)));

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

fn clamp01(value: f32) f32 {
    return @min(1, @max(0, value));
}

fn offset(alignment: tree_zig.Align, free: f32) f32 {
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
