//! A bordered `theme.card` container panel and its composable slots
//! (`openHeader`, `title`, `description`, `openAction`, `openContent`,
//! `openFooter`).
//!
//! Stateless view functions; the caller closes any box opened with `open*`
//! via `card.close` or `Tree.close`.

const Theme = @import("Theme.zig");
const text = @import("text.zig");
const Tree = @import("Tree.zig");
const Id = Tree.Id;
const Index = Tree.Index;

pub const default_padding: u8 = 16;
pub const default_gap: u8 = 12;
pub const header_gap: u8 = 4;

pub const node_max = 1;

pub const Options = struct {
    id: Id = .none,
    axis: Tree.Axis = .column,
    width: Tree.Size = .fill,
    height: Tree.Size = .fit,
    padding: Tree.Edges = .all(default_padding),
    gap: u8 = default_gap,
    main: Tree.Align = .start,
    cross: Tree.Align = .start,
    radius: u8 = Theme.radius,
    overflow: Tree.Overflow = .visible,
    presence: f32 = 1.0,
};

pub const HeaderOptions = struct {
    axis: Tree.Axis = .column,
    padding: Tree.Edges = .zero,
    gap: u8 = header_gap,
    main: Tree.Align = .start,
    cross: Tree.Align = .start,
};

pub const TitleOptions = struct {
    style: text.Style = .sm_medium,
    color: ?Theme.Color = null,
    width: Tree.Size = .fit,
    wrap: Tree.Text.Wrap = .word,
    presence: f32 = 1.0,
};

pub const DescriptionOptions = struct {
    style: text.Style = .xs,
    width: Tree.Size = .fill,
    wrap: Tree.Text.Wrap = .word,
    presence: f32 = 1.0,
};

pub const SectionOptions = struct {
    axis: Tree.Axis = .column,
    padding: Tree.Edges = .zero,
    gap: u8 = default_gap,
    main: Tree.Align = .start,
    cross: Tree.Align = .start,
};

/// Returns the `Tree.Box` specification for a card container.
pub fn box(theme: *const Theme, options: Options) Tree.Box {
    return .{
        .id = options.id,
        .axis = options.axis,
        .width = options.width,
        .height = options.height,
        .padding = options.padding,
        .gap = options.gap,
        .main = options.main,
        .cross = options.cross,
        .overflow = options.overflow,
        .fill = theme.card.fade(options.presence),
        .border = theme.border.fade(options.presence),
        .border_width = Theme.border_width,
        .radius = options.radius,
    };
}

/// Opens a card container box; close it with `close`.
pub fn open(tree: *Tree, theme: *const Theme, options: Options) Tree.Error!Index {
    return tree.open(box(theme, options));
}

pub fn close(tree: *Tree, index: Index) void {
    tree.close(index);
}

/// Opens a card header slot (`column` by default, or `row` when pairing a title with `openAction`).
pub fn openHeader(tree: *Tree, options: HeaderOptions) Tree.Error!Index {
    return tree.open(.{
        .axis = options.axis,
        .width = .fill,
        .padding = options.padding,
        .gap = options.gap,
        .main = options.main,
        .cross = options.cross,
    });
}

/// Writes a card title text node.
pub fn title(tree: *Tree, theme: *const Theme, bytes: []const u8, options: TitleOptions) Tree.Error!void {
    const color = (options.color orelse theme.foreground).fade(options.presence);
    _ = try tree.text(bytes, .{
        .color = color,
        .style = options.style,
        .width = options.width,
        .wrap = options.wrap,
    });
}

/// Writes a muted card description text node.
pub fn description(tree: *Tree, theme: *const Theme, bytes: []const u8, options: DescriptionOptions) Tree.Error!void {
    _ = try tree.text(bytes, .{
        .color = theme.muted_foreground.fade(options.presence),
        .style = options.style,
        .width = options.width,
        .wrap = options.wrap,
    });
}

/// Opens a non-shrinking trailing action slot inside a row header.
pub fn openAction(tree: *Tree) Tree.Error!Index {
    return tree.open(.{
        .axis = .row,
        .gap = 8,
        .cross = .center,
        .shrink = false,
    });
}

/// Opens a card body content slot.
pub fn openContent(tree: *Tree, options: SectionOptions) Tree.Error!Index {
    return tree.open(.{
        .axis = options.axis,
        .width = .fill,
        .padding = options.padding,
        .gap = options.gap,
        .main = options.main,
        .cross = options.cross,
    });
}

/// Opens a card footer slot (`row` by default).
pub fn openFooter(tree: *Tree, options: SectionOptions) Tree.Error!Index {
    return tree.open(.{
        .axis = options.axis,
        .width = .fill,
        .padding = options.padding,
        .gap = options.gap,
        .main = options.main,
        .cross = options.cross,
    });
}
