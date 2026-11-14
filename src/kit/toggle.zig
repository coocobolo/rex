//! A two-state toggle chip for multi-select option groups (e.g. toggle-group
//! flags). Stateless view function; the surface owns `pressed`, `hovered`,
//! `focused`, and `disabled`.

const Theme = @import("Theme.zig");
const icons = @import("icons.zig");
const tree_zig = @import("tree.zig");
const Tree = tree_zig.Tree;
const Id = tree_zig.Id;

/// Focus ring wrapper, face, optional check icon, and label.
pub const node_max = 4;

pub const Options = struct {
    id: Id,
    /// Borrowed until the view is rebuilt.
    label: []const u8,
    pressed: bool = false,
    hovered: bool = false,
    focused: bool = false,
    disabled: bool = false,
};

pub fn view(tree: *Tree, theme: *const Theme, options: Options) tree_zig.Error!void {
    const presence: f32 = if (options.disabled) 0.5 else 1.0;
    const ring_color = if (options.focused and !options.disabled)
        theme.ring.alpha(Theme.ring_opacity)
    else
        Theme.Color.transparent;

    const ring = try tree.open(.{
        .id = options.id,
        .pointer = if (options.disabled) .arrow else .hand,
        .padding = .all(Theme.ring_width),
        .border = ring_color,
        .border_width = Theme.ring_width,
        .radius = Theme.radius_md + Theme.ring_width,
    });

    const fill = if (options.pressed)
        theme.accent.fade(presence)
    else if (options.hovered and !options.disabled)
        theme.muted
    else
        theme.background.fade(presence);

    const border = if (options.pressed)
        theme.primary.fade(0.6 * presence)
    else
        theme.input.fade(presence);

    const face = try tree.open(.{
        .axis = .row,
        .height = .{ .fixed = Theme.control_sm },
        .padding = .symmetric(10, 0),
        .gap = 6,
        .cross = .center,
        .fill = fill,
        .border = border,
        .border_width = Theme.border_width,
        .radius = Theme.radius_md,
    });

    if (options.pressed) {
        _ = try tree.icon(.{
            .codepoint = icons.check,
            .color = theme.primary.fade(presence),
            .size = 13,
        });
    }

    _ = try tree.text(options.label, .{
        .color = (if (options.pressed) theme.foreground else theme.muted_foreground).fade(presence),
        .style = if (options.pressed) .sm_medium else .sm,
    });

    tree.close(face);
    tree.close(ring);
}
