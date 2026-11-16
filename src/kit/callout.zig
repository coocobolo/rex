//! An in-page notice: a card with an icon, a title and an optional
//! description. There is no state, timer or hit handling here — the surface
//! that shows it decides when and closes the boxes it opens.

const Theme = @import("Theme.zig");
const icons = @import("icons.zig");
const Tree = @import("Tree.zig");
const Index = Tree.Index;

pub const Variant = enum(u8) {
    default,
    destructive,
};

/// Card, icon slot, icon, body, title and description.
pub const node_max = 6;
/// Lines the title and the description can wrap into.
pub const line_max = 16;

pub const Options = struct {
    variant: Variant = .default,
    /// A code point from `icons.zig`, or `icons.none` for no icon.
    icon: u21 = icons.info,
    id: Tree.Id = .none,
    width: Tree.Size = .fill,
};

/// The boxes `view` opens. Pass it to `close` after writing the text slots.
pub const Frame = struct {
    card: Index,
    body: Index,
    variant: Variant,
};

/// Opens the card and its icon slot and body. Write `title` and
/// `description` into the body, then close with `close`.
pub fn view(tree: *Tree, theme: *const Theme, options: Options) Tree.Error!Frame {
    const destructive = options.variant == .destructive;
    const card = try tree.open(.{
        .id = options.id,
        .axis = .row,
        .width = options.width,
        .height = .fit,
        .padding = .all(12),
        .gap = 12,
        .cross = .start,
        .fill = theme.card,
        .border = if (destructive) theme.destructive.alpha(45) else theme.border,
        .border_width = Theme.border_width,
        .radius = Theme.radius,
    });
    if (options.icon != icons.none) {
        const slot = try tree.open(.{ .height = .{ .fixed = Theme.icon } });
        _ = try tree.icon(.{
            .codepoint = options.icon,
            .color = if (destructive) theme.destructive else theme.foreground,
            .size = Theme.icon,
        });
        tree.close(slot);
    }
    const body = try tree.open(.{ .width = .fill, .gap = 2 });
    return .{ .card = card, .body = body, .variant = options.variant };
}

/// The short summary, on the first line of the body.
pub fn title(tree: *Tree, theme: *const Theme, frame: Frame, bytes: []const u8) Tree.Error!void {
    _ = try tree.text(bytes, .{
        .color = if (frame.variant == .destructive) theme.destructive else theme.foreground,
        .style = .sm_medium,
        .width = .fill,
    });
}

/// The longer explanation, below the title. Omit it when there is none.
pub fn description(tree: *Tree, theme: *const Theme, frame: Frame, bytes: []const u8) Tree.Error!void {
    _ = try tree.text(bytes, .{
        .color = if (frame.variant == .destructive)
            theme.destructive.alpha(90)
        else
            theme.muted_foreground,
        .style = .xs,
        .width = .fill,
    });
}

/// Closes the body and the card opened by `view`.
pub fn close(tree: *Tree, frame: Frame) void {
    tree.close(frame.body);
    tree.close(frame.card);
}
