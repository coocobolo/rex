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
const focus = @import("focus.zig");
const icons = @import("icons.zig");
const kbd = @import("kbd.zig");
const Tree = @import("Tree.zig");
const Id = Tree.Id;

/// Between two buttons in a row, and between a label and its key cap.
pub const gap = 8;

pub const Size = enum(u8) {
    default,
    xs,
    sm,
    lg,

    /// The face's height in logical pixels.
    pub fn height(self: Size) u8 {
        return switch (self) {
            .default => Theme.control,
            .xs => Theme.control_xs,
            .sm => Theme.control_sm,
            .lg => Theme.control_lg,
        };
    }

    /// Horizontal padding inside the face.
    pub fn pad(self: Size) u8 {
        return switch (self) {
            .default => 16,
            .xs => 8,
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
    /// Filled with `secondary`: an action of middle weight.
    secondary,
    /// A label in `primary` with no face: an action inside a sentence.
    link,
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
    /// Stretch the button to fill its parent's width (e.g., stacked dialog buttons).
    fill_width: bool = false,
    /// The opacity of the surface it sits on, 0 to 1.
    presence: f32 = 1,
};

/// Most nodes one button writes: the ring slot, the face, the icon, the
/// label and the key cap.
pub const node_max = 4 + kbd.node_max;

const Look = struct { fill: Color, border: Color, label: Color };

/// A filled button is slightly translucent while hovered and more so
/// while pressed; an outline or ghost button fills with `accent` for both,
/// and a ghost button's label brightens from `ghost_foreground`.
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
            .label = if (touched) theme.foreground else theme.ghost_foreground,
        },
        .destructive => blk: {
            const base: u8 = if (theme.isDark()) 20 else 10;
            const tint: u8 = switch (options.state) {
                .normal, .disabled => base,
                .hovered => base + 10,
                .pressed => base + 20,
            };
            break :blk .{
                .fill = theme.destructive.alpha(tint),
                .border = if (options.focused) theme.destructive.alpha(40) else .transparent,
                .label = theme.destructive,
            };
        },
        .secondary => .{
            .fill = theme.secondary.alpha(solid),
            .border = .transparent,
            .label = theme.foreground,
        },
        .link => .{
            .fill = .transparent,
            .border = .transparent,
            .label = if (touched) theme.foreground else theme.primary,
        },
    };
    if (options.focused and options.variant != .destructive) result.border = theme.ring;
    return result;
}

/// How much of its surface's opacity a disabled button keeps.
const disabled_opacity = 0.5;

/// Writes the button into the innermost open box.
pub fn view(tree: *Tree, theme: *const Theme, options: Options) Tree.Error!void {
    assert(!(options.focused and options.state == .disabled));
    assert(options.label.len > 0 or options.icon != icons.none);
    const colors = look(theme, options);
    const height: f32 = @floatFromInt(options.size.height());
    const square = options.label.len == 0;
    const presence = switch (options.state) {
        .normal, .hovered, .pressed => options.presence,
        .disabled => options.presence * disabled_opacity,
    };
    const ring_color = if (options.focused and options.variant == .destructive)
        theme.destructive.alpha(if (theme.isDark()) 40 else 20).fade(presence)
    else
        focus.ringColor(theme, .{
            .focused = options.focused,
            .disabled = options.state == .disabled,
            .presence = presence,
        });
    // The face sits in a slot with room for the ring, so a row does not
    // shift when the focus moves. The ring is the slot's border, not its
    // fill, which would show through an outline button. The id is on the
    // slot: a click on the ring is a click on the button.
    const slot = try focus.openRing(tree, theme, .{
        .id = options.id,
        .width = if (options.fill_width and !square) .fill else .fit,
        .pointer = if (options.state == .disabled) .arrow else .hand,
        .border = ring_color,
        .shrink = false,
    });
    const face = try tree.open(.{
        .axis = .row,
        .width = if (square) .{ .fixed = height } else if (options.fill_width) .fill else .fit,
        .height = if (square) .{ .fixed = height } else .{ .at_least = height },
        .padding = if (square) .zero else if (options.size == .xs)
            .symmetric(options.size.pad(), 4)
        else
            .symmetric(options.size.pad(), 6),
        .gap = gap,
        .main = .center,
        .cross = .center,
        .fill = colors.fill.fade(presence),
        .border = colors.border.fade(presence),
        .border_width = Theme.border_width,
        .radius = Theme.radius_md,
        .shrink = false,
    });
    if (options.icon != icons.none) _ = try tree.icon(.{
        .codepoint = options.icon,
        .color = colors.label.fade(presence),
        .size = icon_size,
    });
    if (!square) _ = try tree.text(options.label, .{
        .color = colors.label.fade(presence),
        .style = if (options.size == .xs) .xs else .sm_medium,
        .wrap = if (options.fill_width) .ellipsis else .none,
    });
    if (options.key_cap.len > 0) try kbd.view(tree, theme, options.key_cap, presence);
    tree.close(face);
    tree.close(slot);
}
