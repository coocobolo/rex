//! A button: a label, and optionally the cap of the key that does the same,
//! on a face whose look follows its variant and state.
//!
//! It is a view function and keeps nothing. The surface that shows it
//! holds which button is hovered or focused and passes that in; a click is
//! found by the id the surface gave it.

const std = @import("std");
const assert = std.debug.assert;

const Theme = @import("Theme.zig");
const Color = Theme.Color;
const icons = @import("icons.zig");
const kbd = @import("kbd.zig");
const tree_zig = @import("tree.zig");
const Tree = tree_zig.Tree;
const Id = tree_zig.Id;

/// Between two buttons in a row, and between a label and its key cap.
pub const gap = 8;

pub const Size = enum(u8) {
    default,
    sm,
    lg,

    /// The face's height in logical pixels.
    pub fn height(self: Size) u8 {
        return switch (self) {
            .default => Theme.control,
            .sm => Theme.control_sm,
            .lg => Theme.control_lg,
        };
    }

    /// Horizontal padding inside the face.
    pub fn pad(self: Size) u8 {
        return switch (self) {
            .default => 16,
            .sm => 12,
            .lg => 20,
        };
    }
};

/// Edge length of a button's icon.
pub const icon_size = 16;

pub const Variant = enum(u8) {
    /// Bordered, no fill: an action of no special weight.
    outline,
    /// Filled with `primary`: the action the surface suggests.
    primary,
    /// Neither border nor fill until the pointer is on it: an action that
    /// should not draw the eye.
    ghost,
    /// Filled with `destructive`: an action that cannot be undone.
    destructive,
};

/// What the pointer is doing to the button, or that it takes no input.
pub const State = enum(u8) {
    normal,
    hovered,
    /// The pointer went down on it and is still over it. Letting go takes
    /// the action.
    pressed,
    /// Drawn at half opacity. The surface gives it neither hover nor
    /// focus.
    disabled,
};

pub const Options = struct {
    /// On the whole button, focus ring included, for `Tree.hitTest`.
    id: Id,
    /// Borrowed until the view is rebuilt, like `key_cap`. Empty for an
    /// icon-only button, which is square and needs `icon`.
    label: []const u8,
    /// One of `icons.zig`, before the label; `icons.none` for none.
    icon: u21 = icons.none,
    /// Empty for none.
    key_cap: []const u8 = "",
    variant: Variant = .outline,
    size: Size = .default,
    state: State = .normal,
    /// Draws the focus ring.
    focused: bool = false,
    /// The opacity of the surface it sits on, 0 to 1.
    presence: f32 = 1,
};

/// Most nodes one button writes: the ring slot, the face, the icon, the
/// label and the key cap.
pub const node_max = 4 + kbd.node_max;

const Look = struct { fill: Color, border: Color, label: Color };

/// A filled button is slightly translucent while hovered and more so
/// while pressed; an outline or ghost button fills with `accent` for both.
/// The focused button's border takes the ring color, under the ring drawn
/// around it.
fn look(theme: *const Theme, options: Options) Look {
    const touched = switch (options.state) {
        .hovered, .pressed => true,
        .normal, .disabled => false,
    };
    const solid: u8 = switch (options.state) {
        .normal, .disabled => 100,
        .hovered => 90,
        .pressed => 80,
    };
    var result: Look = switch (options.variant) {
        .outline => .{
            .fill = if (touched) theme.accent else .transparent,
            .border = theme.input,
            .label = theme.foreground,
        },
        .primary => .{
            .fill = theme.primary.alpha(solid),
            .border = .transparent,
            .label = theme.primary_foreground,
        },
        .ghost => .{
            .fill = if (touched) theme.accent else .transparent,
            .border = .transparent,
            .label = theme.foreground,
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

/// How much of its surface's opacity a disabled button keeps.
const disabled_opacity = 0.5;

/// Writes the button into the innermost open box.
pub fn view(tree: *Tree, theme: *const Theme, options: Options) tree_zig.Error!void {
    assert(!(options.focused and options.state == .disabled));
    assert(options.label.len > 0 or options.icon != icons.none);
    const colors = look(theme, options);
    const height: f32 = @floatFromInt(options.size.height());
    const square = options.label.len == 0;
    const presence = switch (options.state) {
        .normal, .hovered, .pressed => options.presence,
        .disabled => options.presence * disabled_opacity,
    };
    // The face sits in a slot with room for the ring, so a row does not
    // shift when the focus moves. The ring is the slot's border, not its
    // fill, which would show through an outline button. The id is on the
    // slot: a click on the ring is a click on the button.
    const slot = try tree.open(.{
        .id = options.id,
        .pointer = if (options.state == .disabled) .arrow else .hand,
        .padding = .all(Theme.ring_width),
        .border = if (options.focused) theme.ring.alpha(Theme.ring_opacity).fade(presence) else .transparent,
        .border_width = Theme.ring_width,
        .radius = Theme.radius_md + Theme.ring_width,
    });
    const face = try tree.open(.{
        .axis = .row,
        .width = if (square) .{ .fixed = height } else .fit,
        .height = .{ .fixed = height },
        .padding = if (square) .zero else .symmetric(options.size.pad(), 0),
        .gap = gap,
        .main = .center,
        .cross = .center,
        .fill = colors.fill.fade(presence),
        .border = colors.border.fade(presence),
        .border_width = Theme.border_width,
        .radius = Theme.radius_md,
    });
    if (options.icon != icons.none) _ = try tree.icon(.{
        .codepoint = options.icon,
        .color = colors.label.fade(presence),
        .size = icon_size,
    });
    if (!square) _ = try tree.text(options.label, .{
        .color = colors.label.fade(presence),
        .style = .sm_medium,
    });
    if (options.key_cap.len > 0) try kbd.view(tree, theme, options.key_cap, presence);
    tree.close(face);
    tree.close(slot);
}
