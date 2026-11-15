//! Compound input control sharing an outer focus ring, rounded border, and
//! corner clip across a borderless `input` and adjacent addon segments or buttons.

const Theme = @import("Theme.zig");
const focus = @import("focus.zig");
const input = @import("input.zig");
const verticalSeparator = @import("separator.zig").vertical;
const Tree = @import("Tree.zig");
const Id = Tree.Id;
const Index = Tree.Index;
const Size = Tree.Size;
const Edges = Tree.Edges;

/// The outer focus ring and the clipped group container.
pub const node_max = 2;

pub const Frame = struct {
    ring: Index,
    group: Index,
};

pub const Options = struct {
    id: Id = .none,
    width: Size = .fill,
    height: Size = .{ .fixed = Theme.control_sm },
    focused: bool = false,
    hovered: bool = false,
    invalid: bool = false,
    disabled: bool = false,
};

pub fn open(tree: *Tree, theme: *const Theme, options: Options) Tree.Error!Frame {
    const colors = focus.controlColors(theme, .{
        .focused = options.focused,
        .hovered = options.hovered,
        .invalid = options.invalid,
        .disabled = options.disabled,
        .show_invalid_ring = true,
    });
    const ring = try focus.openRing(tree, .{
        .id = options.id,
        .width = options.width,
        .border = colors.ring,
    });
    const group = try tree.open(.{
        .axis = .row,
        .width = .fill,
        .height = options.height,
        .padding = .all(Theme.border_width),
        .cross = .center,
        .overflow = .clip,
        .fill = theme.background,
        .border = colors.border,
        .border_width = Theme.border_width,
        .radius = Theme.radius_md,
    });
    return .{ .ring = ring, .group = group };
}

pub fn close(tree: *Tree, frame: Frame) void {
    tree.close(frame.group);
    tree.close(frame.ring);
}

pub fn separator(tree: *Tree, theme: *const Theme) Tree.Error!void {
    return verticalSeparator(tree, theme);
}

pub fn textInput(tree: *Tree, theme: *const Theme, options: input.Options) Tree.Error!void {
    var inner = options;
    inner.borderless = true;
    return input.view(tree, theme, inner);
}

pub const AddonOptions = struct {
    id: Id = .none,
    width: Size = .fit,
    padding: Edges = .symmetric(10, 0),
    gap: u8 = 6,
    hovered: bool = false,
    disabled: bool = false,
};

pub fn openAddon(tree: *Tree, theme: *const Theme, options: AddonOptions) Tree.Error!Index {
    return tree.open(.{
        .id = options.id,
        .axis = .row,
        .width = options.width,
        .height = .fill,
        .padding = options.padding,
        .gap = options.gap,
        .main = .center,
        .cross = .center,
        .pointer = if (options.disabled) .arrow else .hand,
        .fill = if (!options.disabled and options.hovered) theme.accent else .transparent,
    });
}

pub fn closeAddon(tree: *Tree, addon: Index) void {
    tree.close(addon);
}

pub const ButtonOptions = struct {
    id: Id = .none,
    label: []const u8,
    width: Size = .{ .fixed = Theme.control_sm },
    hovered: bool = false,
    disabled: bool = false,
};

pub fn addonButton(tree: *Tree, theme: *const Theme, options: ButtonOptions) Tree.Error!void {
    const presence: f32 = if (options.disabled) 0.4 else 1.0;
    const cell = try openAddon(tree, theme, .{
        .id = options.id,
        .width = options.width,
        .padding = .zero,
        .gap = 0,
        .hovered = options.hovered,
        .disabled = options.disabled,
    });
    _ = try tree.text(options.label, .{
        .color = theme.foreground.fade(presence),
        .style = .sm_medium,
    });
    closeAddon(tree, cell);
}
