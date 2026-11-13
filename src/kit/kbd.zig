//! A key cap: the name of a key in a small muted box ("Esc"), shown beside
//! the thing the key does, and a group of caps for a chord ("Ctrl" "Shift"
//! "P"). Display only: the caller binds the key.

const Theme = @import("Theme.zig");
const tree_zig = @import("tree.zig");
const Tree = tree_zig.Tree;

/// Nodes one cap writes.
pub const node_max = 2;

/// Between the caps of a group.
pub const gap = 4;

/// Nodes a group of `count` caps writes.
pub fn groupNodes(count: usize) usize {
    return 1 + count * node_max;
}

/// Writes a cap reading `key` into the innermost open box. `presence` is
/// the opacity of the surface it sits on, 0 to 1.
pub fn view(tree: *Tree, theme: *const Theme, key: []const u8, presence: f32) tree_zig.Error!void {
    const cap = try tree.open(.{
        .padding = .symmetric(6, 2),
        .fill = theme.muted.fade(presence),
        .radius = Theme.radius_sm,
        .main = .center,
        .cross = .center,
    });
    _ = try tree.text(key, .{
        .color = theme.muted_foreground.fade(presence),
        .style = .xs,
    });
    tree.close(cap);
}

/// Writes the caps of a chord, in order, as one row.
pub fn group(tree: *Tree, theme: *const Theme, keys: []const []const u8, presence: f32) tree_zig.Error!void {
    const row = try tree.open(.{ .axis = .row, .gap = gap, .cross = .center });
    for (keys) |key| try view(tree, theme, key, presence);
    tree.close(row);
}
