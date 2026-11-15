//! A popup: a card drawn above the page, placed against the control that
//! opened it, such as a dropdown's list or a menu. It is two roots written
//! after the page: a transparent layer over the whole window, then the
//! card, anchored to the control (`Tree.anchorTo`). Later roots are drawn
//! on top and hit first, so the card takes the pointer over itself and the
//! layer takes it everywhere else: the page under a popup gets neither
//! hover nor clicks, and a press on the layer is the caller's cue to close.
//!
//! These are view functions and keep nothing. Whether a popup is open and
//! which item is highlighted is state in the surface that shows it.

const std = @import("std");
const assert = std.debug.assert;

const Theme = @import("Theme.zig");
const icons = @import("icons.zig");
const scroll_area = @import("scroll_area.zig");
const Tree = @import("Tree.zig");
const Id = Tree.Id;
const Index = Tree.Index;

/// Padding inside the card, around its items.
pub const padding = 4;
/// The height of an item.
pub const item_height = 32;
/// Default maximum height for a scrollable dropdown list (10 items plus padding).
pub const default_max_height: f32 = 10 * item_height + 2 * padding;

/// The layer and the card.
pub const node_max = 2;
/// The layer, the scrollable card, and its scrollbar thumb.
pub const scrollable_node_max = 1 + scroll_area.node_max;
/// An item's row, label and mark.
pub const item_node_max = 3;

pub const Options = struct {
    /// On the layer outside the card.
    layer_id: Id,
    /// The control the card is placed against.
    anchor: Id,
    /// Optional ID on the card (used for scroll queries when `max_height` is set).
    id: Id = .none,
    /// Caps the card's height and registers it as a vertical `scroll_area`.
    max_height: ?f32 = null,
    /// Vertical scroll offset in logical pixels when `max_height` is set.
    scroll_y: f32 = 0,
};

/// Writes the layer and opens the card, which must be a root: call it
/// after the page is closed. Write the items, then `close` (or `closeScrollable`) the card.
pub fn open(tree: *Tree, theme: *const Theme, options: Options) Tree.Error!Index {
    assert(tree.current == Tree.none);
    _ = try tree.leaf(.{ .id = options.layer_id, .width = .fill, .height = .fill });
    const card = if (options.max_height) |max_h|
        try scroll_area.open(tree, .{
            .id = options.id,
            .offset = .{ .y = options.scroll_y },
            .width = .fit,
            .height = .{ .fit_at_most = max_h },
            .padding = .all(padding),
            .fill = theme.popover,
            .border = theme.border,
            .border_width = Theme.border_width,
            .radius = Theme.radius_md,
        })
    else
        try tree.open(.{
            .id = options.id,
            .padding = .all(padding),
            .overflow = .clip,
            .fill = theme.popover,
            .border = theme.border,
            .border_width = Theme.border_width,
            .radius = Theme.radius_md,
        });
    try tree.anchorTo(card, options.anchor);
    return card;
}

pub fn close(tree: *Tree, card: Index) void {
    tree.close(card);
}

pub fn closeScrollable(tree: *Tree, theme: *const Theme, card: Index) Tree.Error!void {
    try scroll_area.close(tree, theme, card);
}

pub const ItemOptions = struct {
    id: Id,
    /// Borrowed until the view is rebuilt.
    label: []const u8,
    /// Under the pointer or the keyboard: drawn filled.
    highlighted: bool = false,
    /// The value in use: drawn with a check mark.
    selected: bool = false,
};

/// Writes one item into the open card: a row the card's width, with the
/// label on the left and a check mark on the right when selected.
pub fn item(tree: *Tree, theme: *const Theme, options: ItemOptions) Tree.Error!void {
    const row = try tree.open(.{
        .id = options.id,
        .pointer = .hand,
        .axis = .row,
        .width = .fill,
        .height = .{ .fixed = item_height },
        .padding = .symmetric(8, 0),
        .gap = 8,
        .cross = .center,
        .fill = if (options.highlighted) theme.accent else .transparent,
        .radius = Theme.radius_sm,
    });
    _ = try tree.text(options.label, .{ .color = theme.foreground, .width = .fill, .wrap = .ellipsis });
    if (options.selected) {
        _ = try tree.icon(.{ .codepoint = icons.check, .color = theme.foreground, .size = Theme.icon });
    }
    tree.close(row);
}
