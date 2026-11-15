//! A 1px hairline rule (`horizontal` or `vertical`) that never shrinks
//! below its 1px thickness when a flex container overflows.
//!
//! Stateless view functions; `theme.border` is used when `color` is null.

const Theme = @import("Theme.zig");
const Color = Theme.Color;
const Tree = @import("Tree.zig");
const Id = Tree.Id;

pub const node_max = 1;

pub const Orientation = enum(u1) {
    horizontal,
    vertical,
};

pub const Options = struct {
    id: Id = .none,
    orientation: Orientation = .horizontal,
    color: ?Color = null,
    presence: f32 = 1.0,
};

/// Writes a 1px divider into the innermost open box.
pub fn view(tree: *Tree, theme: *const Theme, options: Options) Tree.Error!void {
    const fill = (options.color orelse theme.border).fade(options.presence);
    _ = try tree.leaf(.{
        .id = options.id,
        .width = switch (options.orientation) {
            .horizontal => .fill,
            .vertical => .{ .fixed = Theme.border_width },
        },
        .height = switch (options.orientation) {
            .horizontal => .{ .fixed = Theme.border_width },
            .vertical => .fill,
        },
        .fill = fill,
        .shrink = false,
    });
}

/// Writes a full-width 1px horizontal divider using `theme.border`.
pub fn horizontal(tree: *Tree, theme: *const Theme) Tree.Error!void {
    return view(tree, theme, .{ .orientation = .horizontal });
}

/// Writes a full-height 1px vertical divider using `theme.border`.
pub fn vertical(tree: *Tree, theme: *const Theme) Tree.Error!void {
    return view(tree, theme, .{ .orientation = .vertical });
}
