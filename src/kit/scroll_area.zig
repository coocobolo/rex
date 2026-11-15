//! A clipping scroll viewport paired with an overlay scrollbar thumb that
//! `layout` sizes and positions in the same pass when content overflows.

const Theme = @import("Theme.zig");
const Color = Theme.Color;
const Tree = @import("Tree.zig");
const Align = Tree.Align;
const Box = Tree.Box;
const Id = Tree.Id;
const Index = Tree.Index;
const Size = Tree.Size;
const Edges = Tree.Edges;

/// The viewport box and its overlay scrollbar thumb leaf.
pub const node_max = 2;

pub const thumb_radius: u8 = 2;
pub const thumb_opacity: f32 = 0.35;

pub const Options = struct {
    id: Id = .none,
    offset: Tree.Scroll.Offset = .{},
    axis: Tree.Axis = .column,
    width: Size = .fill,
    height: Size = .fill,
    padding: Edges = .zero,
    gap: u8 = 0,
    main: Align = .start,
    cross: Align = .start,
    fill: Color = .transparent,
    border: Color = .transparent,
    border_width: u8 = 0,
    radius: u8 = 0,
};

pub fn box(options: Options) Box {
    return .{
        .id = options.id,
        .axis = options.axis,
        .width = options.width,
        .height = options.height,
        .padding = options.padding,
        .gap = options.gap,
        .main = options.main,
        .cross = options.cross,
        .overflow = .clip,
        .fill = options.fill,
        .border = options.border,
        .border_width = options.border_width,
        .radius = options.radius,
    };
}

/// Opens a clipping scroll viewport and registers its scroll region on `tree`.
pub fn open(tree: *Tree, options: Options) Tree.Error!Index {
    const index = try tree.open(box(options));
    try tree.scrollRegion(index, options.offset);
    return index;
}

/// Appends the overlay scrollbar thumb inside `index` and closes the viewport.
pub fn close(tree: *Tree, theme: *const Theme, index: Index) Tree.Error!void {
    const thumb = try tree.leaf(.{
        .overlay = true,
        .fill = theme.muted_foreground.fade(thumb_opacity),
        .radius = thumb_radius,
    });
    tree.scrollThumb(index, thumb);
    tree.close(index);
}
