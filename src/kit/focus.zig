//! Focus-ring and control-border helpers (`ringColor`, `controlColors`,
//! `openRing`), plus the order keyboard focus moves in over a row or list of
//! `count` items (`move`), where values from `count` up mean "none has focus".

const assert = @import("std").debug.assert;

const Theme = @import("Theme.zig");
const Tree = @import("Tree.zig");
const Color = Theme.Color;

pub const Direction = enum(u8) { next, previous };

pub const RingState = struct {
    focused: bool = false,
    disabled: bool = false,
    invalid: bool = false,
    show_invalid_ring: bool = false,
    presence: f32 = 1.0,
};

pub const ControlState = struct {
    focused: bool = false,
    hovered: bool = false,
    invalid: bool = false,
    disabled: bool = false,
    show_invalid_ring: bool = false,
};

pub const ControlColors = struct {
    ring: Color,
    border: Color,
};

pub const RingOptions = struct {
    id: Tree.Id = .none,
    pointer: Tree.PointerShape = .arrow,
    width: Tree.Size = .fit,
    height: Tree.Size = .fit,
    main: Tree.Align = .start,
    cross: Tree.Align = .start,
    border: Color,
    inner_radius: u8 = Theme.radius_md,
    shrink: bool = true,
};

/// Resolves the focus or error halo color for a control slot.
pub fn ringColor(theme: *const Theme, options: RingState) Color {
    const active = options.focused and !options.disabled;
    const base: Color = if (options.invalid and (active or options.show_invalid_ring))
        theme.destructive.alpha(Theme.ring_opacity)
    else if (active)
        theme.ring.alpha(Theme.ring_opacity)
    else
        .transparent;
    return if (options.presence < 1.0) base.fade(options.presence) else base;
}

/// Resolves ring and border colors for text inputs and compound groups.
pub fn controlColors(theme: *const Theme, options: ControlState) ControlColors {
    const presence: f32 = if (options.disabled) 0.5 else 1.0;
    const active = options.focused and !options.disabled;
    const border: Color = if (options.invalid)
        theme.destructive.fade(presence)
    else if (active)
        theme.ring.fade(presence)
    else if (options.hovered and !options.disabled)
        theme.foreground.fade(0.35)
    else
        theme.input.fade(presence);
    return .{
        .ring = ringColor(theme, .{
            .focused = options.focused,
            .disabled = options.disabled,
            .invalid = options.invalid,
            .show_invalid_ring = options.show_invalid_ring,
        }),
        .border = border,
    };
}

/// Opens the outer focus-ring slot reserving `Theme.ring_width` around a control.
pub fn openRing(tree: *Tree, options: RingOptions) Tree.Error!Tree.Index {
    return tree.open(.{
        .id = options.id,
        .pointer = options.pointer,
        .width = options.width,
        .height = options.height,
        .main = options.main,
        .cross = options.cross,
        .padding = .all(Theme.ring_width),
        .border = options.border,
        .border_width = Theme.ring_width,
        .radius = @min(255, @as(u16, options.inner_radius) + Theme.ring_width),
        .shrink = options.shrink,
    });
}

/// The item the focus moves to from `current`, wrapping at both ends.
/// Coming in from none lands on the first item forwards and on the last
/// backwards.
pub fn move(current: u8, count: u8, direction: Direction) u8 {
    assert(count > 0);
    const none = current >= count;
    return switch (direction) {
        .next => if (none) 0 else (current + 1) % count,
        .previous => if (none or current == 0) count - 1 else current - 1,
    };
}
