//! Form and settings field layout: pairs a label block (title, optional
//! metadata `badge`, and muted description) with a control slot in
//! `.horizontal`, `.vertical`, or `.responsive` orientation, plus an
//! optional validation error message below the row.
//!
//! Stateless view functions; callers open a field with `open`, emit the
//! control widget(s), and finish with `close`.

const Theme = @import("Theme.zig");
const badge = @import("badge.zig");
const Tree = @import("Tree.zig");
const Id = Tree.Id;
const Index = Tree.Index;

pub const horizontal_gap: u8 = 16;
pub const vertical_gap: u8 = 10;
pub const label_gap: u8 = 3;
pub const outer_gap: u8 = 4;

/// Outer column, main row/column, label column, optional title row, label
/// text, optional badge, optional description text, and optional error text.
pub const node_max = 6 + badge.node_max;

pub const Orientation = enum(u8) {
    vertical,
    horizontal,
    /// Uses `.vertical` when `Options.compact` is true and `.horizontal` otherwise.
    responsive,

    pub fn isVertical(self: Orientation, compact: bool) bool {
        return switch (self) {
            .vertical => true,
            .horizontal => false,
            .responsive => compact,
        };
    }
};

pub const Options = struct {
    id: Id = .none,
    /// Field title shown in `.sm_medium`.
    label: []const u8,
    /// Optional muted helper text below `label`.
    description: []const u8 = "",
    /// Optional compact badge next to `label` (e.g. `"Restart required"`).
    badge: []const u8 = "",
    badge_variant: badge.Variant = .muted,
    /// Optional validation error message rendered below the field in `theme.destructive`.
    err: []const u8 = "",
    orientation: Orientation = .horizontal,
    /// Whether the parent pane is narrow (used when `orientation == .responsive`).
    compact: bool = false,
    /// Aligns the label and control to `.start` instead of `.center` in horizontal layout.
    align_top: bool = false,
};

pub const Frame = struct {
    outer: Index,
    row: Index,
    err: []const u8,
};

pub const LabelOptions = struct {
    label: []const u8,
    description: []const u8 = "",
    badge: []const u8 = "",
    badge_variant: badge.Variant = .muted,
};

/// Writes a section legend heading above a card or group of fields.
pub fn legend(tree: *Tree, theme: *const Theme, bytes: []const u8) Tree.Error!void {
    _ = try tree.text(bytes, .{
        .color = theme.foreground,
        .style = .sm_medium,
    });
}

/// Writes the label column (title + optional badge + optional description).
pub fn labelBlock(tree: *Tree, theme: *const Theme, options: LabelOptions) Tree.Error!void {
    const box = try tree.open(.{ .width = .fill, .gap = label_gap });
    if (options.badge.len > 0) {
        const title_row = try tree.open(.{
            .axis = .row,
            .gap = 8,
            .cross = .center,
        });
        _ = try tree.text(options.label, .{
            .color = theme.foreground,
            .style = .sm_medium,
        });
        try badge.view(tree, theme, .{
            .label = options.badge,
            .variant = options.badge_variant,
            .size = .sm,
        });
        tree.close(title_row);
    } else {
        _ = try tree.text(options.label, .{
            .color = theme.foreground,
            .style = .sm_medium,
        });
    }
    if (options.description.len > 0) {
        _ = try tree.text(options.description, .{
            .color = theme.muted_foreground,
            .style = .xs,
            .width = .fill,
        });
    }
    tree.close(box);
}

/// Writes a destructive validation error line.
pub fn errorText(tree: *Tree, theme: *const Theme, bytes: []const u8) Tree.Error!void {
    if (bytes.len == 0) return;
    _ = try tree.text(bytes, .{
        .color = theme.destructive,
        .style = .xs,
        .width = .fill,
    });
}

/// Opens a field container and writes its label block; emit the control
/// next, then call `close`.
pub fn open(tree: *Tree, theme: *const Theme, options: Options) Tree.Error!Frame {
    const vertical = options.orientation.isVertical(options.compact);
    const outer = try tree.open(.{
        .id = options.id,
        .width = .fill,
        .gap = outer_gap,
    });
    const row = try tree.open(.{
        .axis = if (vertical) .column else .row,
        .width = .fill,
        .cross = if (vertical or options.align_top) .start else .center,
        .gap = if (vertical) vertical_gap else horizontal_gap,
    });
    try labelBlock(tree, theme, .{
        .label = options.label,
        .description = options.description,
        .badge = options.badge,
        .badge_variant = options.badge_variant,
    });
    return .{
        .outer = outer,
        .row = row,
        .err = options.err,
    };
}

/// Closes the field's control row, writes `frame.err` when non-empty, and
/// closes the outer field box.
pub fn close(tree: *Tree, theme: *const Theme, frame: Frame) Tree.Error!void {
    tree.close(frame.row);
    try errorText(tree, theme, frame.err);
    tree.close(frame.outer);
}
