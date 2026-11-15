//! A disclosure panel: a bordered card with an interactive header trigger
//! (title, optional badge, description, optional caller-supplied preview
//! content, and chevron indicator) and a collapsible body separated by a
//! 1px rule when open.
//!
//! Stateless view functions; the owning surface holds `open: bool`, hover,
//! and focus state.

const Theme = @import("Theme.zig");
const badge = @import("badge.zig");
const card = @import("card.zig");
const focus = @import("focus.zig");
const icons = @import("icons.zig");
const separator = @import("separator.zig");
const Tree = @import("Tree.zig");
const Id = Tree.Id;
const Index = Tree.Index;

pub const default_padding_x: u8 = 14;
pub const default_padding_y: u8 = 10;
pub const default_body_padding: u8 = 14;
pub const default_body_gap: u8 = 12;

/// Card box, trigger (`ring_slot`, `header`, `label_box`, `title_row`,
/// `title`, `badge`, `description`, `chevron`), divider, and body box.
pub const trigger_node_max = 6 + badge.node_max;
pub const content_node_max = separator.node_max + 1;
pub const node_max = card.node_max + trigger_node_max + content_node_max;

pub const CardOptions = struct {
    id: Id = .none,
    width: Tree.Size = .fill,
    radius: u8 = Theme.radius_md,
    presence: f32 = 1.0,
};

pub const TriggerOptions = struct {
    id: Id,
    title: []const u8,
    description: []const u8 = "",
    badge: []const u8 = "",
    badge_variant: badge.Variant = .muted,
    open: bool = false,
    hovered: bool = false,
    focused: bool = false,
    disabled: bool = false,
    padding_x: u8 = default_padding_x,
    padding_y: u8 = default_padding_y,
    card_radius: u8 = Theme.radius_md,
};

pub const TriggerFrame = struct {
    ring: Index,
    header: Index,
    open: bool,
    disabled: bool,
};

pub const ContentOptions = struct {
    padding: Tree.Edges = .all(default_body_padding),
    gap: u8 = default_body_gap,
};

/// Opens a zero-padded card container for a collapsible section.
pub fn open(tree: *Tree, theme: *const Theme, options: CardOptions) Tree.Error!Index {
    return card.open(tree, theme, .{
        .id = options.id,
        .width = options.width,
        .padding = .zero,
        .gap = 0,
        .radius = options.radius,
        .presence = options.presence,
    });
}

pub fn close(tree: *Tree, index: Index) void {
    card.close(tree, index);
}

/// Opens the disclosure trigger header and writes its title, optional badge,
/// and optional description. Any nodes emitted before `closeTrigger` appear
/// on the right side of the header before the chevron icon.
pub fn openTrigger(tree: *Tree, theme: *const Theme, options: TriggerOptions) Tree.Error!TriggerFrame {
    const presence: f32 = if (options.disabled) 0.5 else 1.0;
    const active = options.focused and !options.disabled;
    const touched = options.hovered and !options.disabled;

    const ring = try tree.open(.{
        .id = options.id,
        .pointer = if (options.disabled) .arrow else .hand,
        .width = .fill,
        .padding = .all(Theme.ring_width),
        .border = focus.ringColor(theme, .{
            .focused = options.focused,
            .disabled = options.disabled,
            .presence = presence,
        }),
        .border_width = Theme.ring_width,
        .radius = options.card_radius -| Theme.border_width,
    });

    const header = try tree.open(.{
        .axis = .row,
        .width = .fill,
        .padding = .symmetric(
            options.padding_x -| Theme.ring_width,
            options.padding_y -| Theme.ring_width,
        ),
        .gap = 12,
        .cross = .center,
        .fill = if (touched) theme.accent else .transparent,
        .border = if (active) theme.ring.fade(presence) else .transparent,
        .border_width = Theme.border_width,
        .radius = Theme.radius_sm,
    });

    if (options.title.len > 0 or options.description.len > 0) {
        const label_box = try tree.open(.{ .width = .fill, .gap = 2 });
        if (options.badge.len > 0) {
            const title_row = try tree.open(.{
                .axis = .row,
                .gap = 8,
                .cross = .center,
            });
            _ = try tree.text(options.title, .{
                .color = theme.foreground.fade(presence),
                .style = .sm_medium,
            });
            try badge.view(tree, theme, .{
                .label = options.badge,
                .variant = options.badge_variant,
                .size = .sm,
                .presence = presence,
            });
            tree.close(title_row);
        } else if (options.title.len > 0) {
            _ = try tree.text(options.title, .{
                .color = theme.foreground.fade(presence),
                .style = .sm_medium,
            });
        }
        if (options.description.len > 0) {
            _ = try tree.text(options.description, .{
                .color = theme.muted_foreground.fade(presence),
                .style = .xs,
                .width = .fill,
            });
        }
        tree.close(label_box);
    }

    return .{
        .ring = ring,
        .header = header,
        .open = options.open,
        .disabled = options.disabled,
    };
}

/// Emits the trailing chevron icon (`chevron_down` when open, `chevron_right`
/// when collapsed) and closes the trigger header and focus ring.
pub fn closeTrigger(tree: *Tree, theme: *const Theme, frame: TriggerFrame) Tree.Error!void {
    const presence: f32 = if (frame.disabled) 0.5 else 1.0;
    _ = try tree.icon(.{
        .codepoint = if (frame.open) icons.chevron_down else icons.chevron_right,
        .color = theme.muted_foreground.fade(presence),
        .size = Theme.icon,
    });
    tree.close(frame.header);
    tree.close(frame.ring);
}

/// Writes a top 1px horizontal divider and opens the collapsible body box.
pub fn openContent(tree: *Tree, theme: *const Theme, options: ContentOptions) Tree.Error!Index {
    try separator.horizontal(tree, theme);
    return tree.open(.{
        .width = .fill,
        .padding = options.padding,
        .gap = options.gap,
    });
}

pub fn closeContent(tree: *Tree, body: Index) void {
    tree.close(body);
}
