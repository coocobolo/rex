//! A button: a label, and optionally the cap of the key that does the same,
//! on a face whose look follows its variant and state.
//!
//! It is a view function and keeps nothing. The surface that shows it
//! holds which button is hovered or focused and passes that in; a click is
//! found by the id the surface gave it.

const Theme = @import("Theme.zig");
const Color = Theme.Color;
const kbd = @import("kbd.zig");
const tree_zig = @import("tree.zig");
const Tree = tree_zig.Tree;
const Id = tree_zig.Id;

/// Between two buttons in a row, and between a label and its key cap.
pub const gap = 8;
/// Horizontal padding inside the face.
pub const pad = 16;

pub const Variant = enum(u8) {
    /// Bordered, no fill: an action of no special weight.
    outline,
    /// Filled with `primary`: the action the surface suggests.
    primary,
    /// Filled with `destructive`: an action that cannot be undone.
    destructive,
};

/// What the pointer is doing to the button.
pub const State = enum(u8) { normal, hovered };

pub const Options = struct {
    /// On the whole button, focus ring included, for `Tree.hitTest`.
    id: Id,
    /// Borrowed until the view is rebuilt, like `key_cap`.
    label: []const u8,
    /// Empty for none.
    key_cap: []const u8 = "",
    variant: Variant = .outline,
    state: State = .normal,
    /// Draws the focus ring.
    focused: bool = false,
    /// The opacity of the surface it sits on, 0 to 1.
    presence: f32 = 1,
};

/// Most nodes one button writes: the ring slot, the face, the label and
/// the key cap.
pub const node_max = 3 + kbd.node_max;

const Look = struct { fill: Color, border: Color, label: Color };

/// A filled button is slightly translucent while hovered; an outline
/// button fills. The focused button's border takes the ring color, under
/// the ring drawn around it.
fn look(theme: *const Theme, options: Options) Look {
    const hovered = options.state == .hovered;
    const solid: u8 = if (hovered) 90 else 100;
    var result: Look = switch (options.variant) {
        .outline => .{
            .fill = if (hovered) theme.accent else .transparent,
            .border = theme.input,
            .label = theme.foreground,
        },
        .primary => .{
            .fill = theme.primary.alpha(solid),
            .border = .transparent,
            .label = theme.primary_foreground,
        },
        .destructive => .{
            .fill = theme.destructive.alpha(solid),
            .border = .transparent,
            .label = theme.destructive_foreground,
        },
    };
    if (options.focused) result.border = theme.ring;
    return result;
}

/// Writes the button into the innermost open box.
pub fn view(tree: *Tree, theme: *const Theme, options: Options) tree_zig.Error!void {
    const colors = look(theme, options);
    const presence = options.presence;
    // The face sits in a slot with room for the ring, so a row does not
    // shift when the focus moves. The ring is the slot's border, not its
    // fill, which would show through an outline button. The id is on the
    // slot: a click on the ring is a click on the button.
    const slot = try tree.open(.{
        .id = options.id,
        .padding = .all(Theme.ring_width),
        .border = if (options.focused) theme.ring.alpha(Theme.ring_opacity).fade(presence) else .transparent,
        .border_width = Theme.ring_width,
        .radius = Theme.radius_md + Theme.ring_width,
    });
    const face = try tree.open(.{
        .axis = .row,
        .height = .{ .fixed = Theme.control },
        .padding = .symmetric(pad, 0),
        .gap = gap,
        .main = .center,
        .cross = .center,
        .fill = colors.fill.fade(presence),
        .border = colors.border.fade(presence),
        .border_width = Theme.border_width,
        .radius = Theme.radius_md,
    });
    _ = try tree.text(options.label, .{
        .color = colors.label.fade(presence),
        .style = .sm_medium,
    });
    if (options.key_cap.len > 0) try kbd.view(tree, theme, options.key_cap, presence);
    tree.close(face);
    tree.close(slot);
}
