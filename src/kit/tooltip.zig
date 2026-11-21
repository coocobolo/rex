//! A tooltip: a card drawn above the page, placed against the node it
//! describes. It is one root, anchored with `Tree.anchorTo`, and it has
//! no full-window layer, so the page under it still takes hover and
//! clicks. The card carries no id, so a hit on it falls through to
//! whatever is underneath.
//!
//! These are view functions and keep nothing. Whether the tooltip is
//! open is state in the surface that shows it. Write it after the page.

const std = @import("std");
const assert = std.debug.assert;

const Theme = @import("Theme.zig");
const Color = Theme.Color;
const layout = @import("layout.zig");
const Tree = @import("Tree.zig");
const Id = Tree.Id;
const Index = Tree.Index;

/// Card padding and row spacing, owned by the surface that shows the tooltip.
pub const Metrics = struct {
    pad_x: u8 = default_pad_x,
    pad_y: u8 = default_pad_y,
    gap: u8 = default_gap,
};

pub const Options = struct {
    anchor: Id,
    side: Tree.Anchor.Side = .auto,
    alignment: Tree.Anchor.Alignment = .start,
    gap: u8 = layout.anchor_gap,
    margin: u8 = layout.anchor_margin,
    metrics: Metrics = .{},
};

/// The color swatch, a square the shader rounds into a dot.
pub const swatch = 8;
const default_pad_x: u8 = 12;
const default_pad_y: u8 = 8;
const default_gap: u8 = 8;

pub const Line = struct {
    /// Borrowed until the view is rebuilt, like `value`.
    name: []const u8,
    value: []const u8,
    swatch: Color,
    metrics: Metrics = .{},
};

/// The card, then each line's row, swatch, name and value.
pub fn nodes(count: usize) usize {
    return 1 + count * 4;
}

/// Opens the card as a root, anchored to `options.anchor` without stretching to
/// its width. Write the lines, then `close`.
pub fn open(tree: *Tree, theme: *const Theme, options: Options) Tree.Error!Index {
    const card = try openCard(tree, theme, options.metrics);
    try tree.anchorToWith(card, options.anchor, .{
        .side = options.side,
        .alignment = options.alignment,
        .match_anchor_width = false,
        .gap = options.gap,
        .margin = options.margin,
    });
    return card;
}

/// Opens the card as a root, placed near `(x, y)` in logical pixels.
/// Write the lines, then `close`.
pub fn openAt(tree: *Tree, theme: *const Theme, x: f32, y: f32, metrics: Metrics) Tree.Error!Index {
    const card = try openCard(tree, theme, metrics);
    try tree.anchorAt(card, x, y);
    return card;
}

fn openCard(tree: *Tree, theme: *const Theme, metrics: Metrics) Tree.Error!Index {
    assert(tree.current == Tree.none);
    return tree.open(.{
        .padding = .symmetric(metrics.pad_x, metrics.pad_y),
        .gap = metrics.gap,
        .fill = theme.popover,
        .border = theme.border,
        .border_width = Theme.border_width,
        .radius = Theme.radius_md,
    });
}

pub fn close(tree: *Tree, card: Index) void {
    tree.close(card);
}

/// One fact: a swatch, its name and its value.
pub fn line(tree: *Tree, theme: *const Theme, item: Line) Tree.Error!void {
    const row = try tree.open(.{
        .axis = .row,
        .gap = item.metrics.gap,
        .cross = .center,
    });
    _ = try tree.leaf(.{
        .width = .{ .fixed = swatch },
        .height = .{ .fixed = swatch },
        .fill = item.swatch,
        .radius = Theme.radius_sm,
    });
    _ = try tree.text(item.name, .{ .color = theme.muted_foreground, .style = .xs });
    _ = try tree.text(item.value, .{ .color = theme.foreground, .style = .xs });
    tree.close(row);
}
