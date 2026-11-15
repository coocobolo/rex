//! Joined button group sharing an outer focus ring, rounded border, and
//! corner clip, with hairlines between adjacent segments.

const Theme = @import("Theme.zig");
const Color = Theme.Color;
const focus = @import("focus.zig");
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
    axis: Tree.Axis = .row,
    width: Size = .fit,
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
    });
    const ring = try focus.openRing(tree, .{
        .id = options.id,
        .width = if (options.width == .fill) .fill else .fit,
        .border = colors.ring,
    });
    const group = try tree.open(.{
        .axis = options.axis,
        .width = options.width,
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

pub const SegmentOptions = struct {
    id: Id = .none,
    width: Size = .{ .fixed = Theme.control_sm },
    padding: Edges = .zero,
    gap: u8 = 6,
    selected: bool = false,
    hovered: bool = false,
    focused: bool = false,
    disabled: bool = false,
};

pub fn openSegment(tree: *Tree, theme: *const Theme, options: SegmentOptions) Tree.Error!Index {
    const fill: Color = if (options.disabled)
        .transparent
    else if (options.selected)
        theme.accent
    else if (options.hovered or options.focused)
        theme.muted
    else
        .transparent;
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
        .fill = fill,
    });
}

pub fn closeSegment(tree: *Tree, segment: Index) void {
    tree.close(segment);
}

pub fn iconSegment(tree: *Tree, theme: *const Theme, codepoint: u21, options: SegmentOptions) Tree.Error!void {
    const presence: f32 = if (options.disabled) 0.4 else 1.0;
    const active = options.selected or options.hovered or options.focused;
    const seg = try openSegment(tree, theme, options);
    _ = try tree.icon(.{
        .codepoint = codepoint,
        .color = (if (active) theme.foreground else theme.muted_foreground).fade(presence),
        .size = Theme.icon,
    });
    closeSegment(tree, seg);
}

pub fn textSegment(tree: *Tree, theme: *const Theme, label: []const u8, options: SegmentOptions) Tree.Error!void {
    const presence: f32 = if (options.disabled) 0.4 else 1.0;
    const seg = try openSegment(tree, theme, options);
    _ = try tree.text(label, .{
        .color = theme.foreground.fade(presence),
        .style = .sm_medium,
    });
    closeSegment(tree, seg);
}
