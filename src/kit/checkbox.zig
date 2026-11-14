//! A checkbox with an optional label: a 16x16 px rounded box showing a
//! check mark when checked, plus a focus ring around the box.
//!
//! Stateless view function; the surface owns `checked`, `focused`, and
//! `disabled` and handles clicks by `id`.

const Theme = @import("Theme.zig");
const icons = @import("icons.zig");
const tree_zig = @import("tree.zig");
const Tree = tree_zig.Tree;
const Id = tree_zig.Id;

pub const box_size: f32 = 16;
pub const icon_size: u8 = 12;
pub const gap: u8 = 8;

/// Outer row, focus ring wrapper, check box, optional check icon, optional label.
pub const node_max = 5;

pub const Options = struct {
    /// On the outer row (box + label), for `Tree.hitTest`.
    id: Id,
    checked: bool = false,
    /// Borrowed until the view is rebuilt. Empty for a standalone box.
    label: []const u8 = "",
    focused: bool = false,
    disabled: bool = false,
};

pub fn view(tree: *Tree, theme: *const Theme, options: Options) tree_zig.Error!void {
    const presence: f32 = if (options.disabled) 0.5 else 1.0;
    const ring_color = if (options.focused and !options.disabled)
        theme.ring.alpha(Theme.ring_opacity)
    else
        Theme.Color.transparent;

    const row = try tree.open(.{
        .id = options.id,
        .pointer = if (options.disabled) .arrow else .hand,
        .axis = .row,
        .cross = .center,
        .gap = gap,
    });

    const ring = try tree.open(.{
        .padding = .all(Theme.ring_width),
        .border = ring_color,
        .border_width = Theme.ring_width,
        .radius = Theme.radius_sm + Theme.ring_width,
    });

    const box = try tree.open(.{
        .width = .{ .fixed = box_size },
        .height = .{ .fixed = box_size },
        .main = .center,
        .cross = .center,
        .fill = if (options.checked) theme.primary.fade(presence) else .transparent,
        .border = if (options.checked) .transparent else theme.input.fade(presence),
        .border_width = if (options.checked) 0 else Theme.border_width,
        .radius = Theme.radius_sm,
    });
    if (options.checked) {
        _ = try tree.icon(.{
            .codepoint = icons.check,
            .color = theme.primary_foreground.fade(presence),
            .size = icon_size,
        });
    }
    tree.close(box);
    tree.close(ring);

    if (options.label.len > 0) {
        _ = try tree.text(options.label, .{
            .color = theme.foreground.fade(presence),
            .style = .sm,
        });
    }

    tree.close(row);
}
