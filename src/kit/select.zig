//! A select control: a trigger button showing the current choice and a
//! chevron, paired with a `popup` list of choices.
//!
//! Stateless view functions; the surface owns the selected index, whether the
//! list is open, and which item is highlighted.

const Theme = @import("Theme.zig");
const focus = @import("focus.zig");
const icons = @import("icons.zig");
const popup = @import("popup.zig");
const Tree = @import("Tree.zig");
const Id = Tree.Id;
const Index = Tree.Index;

pub const min_width: f32 = 160;
/// Focus ring wrapper, trigger face, value text, and chevron icon.
pub const trigger_node_max = 4;
pub const list_node_max = popup.node_max;
pub const item_node_max = popup.item_node_max;

pub const TriggerOptions = struct {
    /// On the outer focus-ring wrapper, for `Tree.hitTest` and `popup.open(.anchor)`.
    id: Id,
    /// Borrowed until the view is rebuilt.
    value: []const u8,
    width: Tree.Size = .{ .at_least = min_width },
    height: u8 = Theme.control_sm,
    hovered: bool = false,
    open: bool = false,
    focused: bool = false,
    disabled: bool = false,
};

pub fn trigger(tree: *Tree, theme: *const Theme, options: TriggerOptions) Tree.Error!void {
    const presence: f32 = if (options.disabled) 0.5 else 1.0;
    const ring_color = focus.ringColor(theme, .{
        .focused = options.focused,
        .disabled = options.disabled,
    });
    const touched = !options.disabled and (options.hovered or options.open);

    const ring = try focus.openRing(tree, .{
        .id = options.id,
        .width = if (options.width == .fill) .fill else .fit,
        .pointer = if (options.disabled) .arrow else .hand,
        .border = ring_color,
    });

    const face = try tree.open(.{
        .axis = .row,
        .width = options.width,
        .height = .{ .fixed = options.height },
        .padding = .symmetric(12, 0),
        .gap = 8,
        .cross = .center,
        .fill = if (touched) theme.accent else .transparent,
        .border = theme.input.fade(presence),
        .border_width = Theme.border_width,
        .radius = Theme.radius_md,
    });
    _ = try tree.text(options.value, .{
        .color = theme.foreground.fade(presence),
        .width = .fill,
        .wrap = .ellipsis,
    });
    _ = try tree.icon(.{
        .codepoint = icons.chevron_down,
        .color = theme.muted_foreground.fade(presence),
        .size = Theme.icon,
    });
    tree.close(face);
    tree.close(ring);
}

pub fn openList(tree: *Tree, theme: *const Theme, options: popup.Options) Tree.Error!Index {
    return popup.open(tree, theme, options);
}

pub fn item(tree: *Tree, theme: *const Theme, options: popup.ItemOptions) Tree.Error!void {
    return popup.item(tree, theme, options);
}

pub fn closeList(tree: *Tree, card: Index) void {
    popup.close(tree, card);
}
