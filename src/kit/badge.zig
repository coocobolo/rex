//! A compact status or metadata pill (shadcn Badge): a short label and
//! optional leading icon, styled purely from `Variant` and `Size`.
//!
//! It is a read-only view function and holds no state.

const std = @import("std");
const assert = std.debug.assert;

const Theme = @import("Theme.zig");
const Color = Theme.Color;
const icons = @import("icons.zig");
const text = @import("text.zig");
const tree_zig = @import("tree.zig");
const Tree = tree_zig.Tree;
const Id = tree_zig.Id;

pub const Variant = enum(u8) {
    /// Solid `primary` pill with `primary_foreground` text.
    default,
    /// Raised `secondary` surface with `foreground` text.
    secondary,
    /// Quiet `muted` pill with `muted_foreground` text.
    muted,
    /// Bordered transparent pill.
    outline,
    /// Solid `destructive` pill with `destructive_foreground` text.
    destructive,
    /// Subtle `info` tinted pill (`info_text` label).
    info,
    /// Subtle `success` tinted pill (`success` label).
    success,
    /// Subtle `warning` tinted pill (`warning` label).
    warning,
};

pub const Size = enum(u8) {
    /// Inline compact pill (`6×1` padding, `xs` text).
    sm,
    /// Standard shadcn pill (`8×2` padding, `xs` text).
    default,
    /// Hero/card pill (`10×3` padding, `sm_medium` text).
    lg,

    pub fn padding(self: Size) tree_zig.Edges {
        return switch (self) {
            .sm => .symmetric(6, 1),
            .default => .symmetric(8, 2),
            .lg => .symmetric(10, 3),
        };
    }

    pub fn textStyle(self: Size) text.Style {
        return switch (self) {
            .sm, .default => .xs,
            .lg => .sm_medium,
        };
    }

    pub fn iconSize(self: Size) u8 {
        return switch (self) {
            .sm => 10,
            .default => 11,
            .lg => 12,
        };
    }
};

pub const Options = struct {
    id: Id = .none,
    /// Borrowed until the view is rebuilt. Must be non-empty.
    label: []const u8,
    /// Optional leading icon from `icons.zig`; `icons.none` for none.
    icon: u21 = icons.none,
    variant: Variant = .default,
    size: Size = .default,
    /// Opacity of the surface it sits on, 0 to 1.
    presence: f32 = 1,
};

/// Most nodes one badge writes: pill container, optional leading icon, and label.
pub const node_max = 3;

const Look = struct {
    fill: Color,
    border: Color,
    foreground: Color,
};

fn look(theme: *const Theme, variant: Variant) Look {
    return switch (variant) {
        .default => .{
            .fill = theme.primary,
            .border = .transparent,
            .foreground = theme.primary_foreground,
        },
        .secondary => .{
            .fill = theme.secondary,
            .border = .transparent,
            .foreground = theme.foreground,
        },
        .muted => .{
            .fill = theme.muted,
            .border = .transparent,
            .foreground = theme.muted_foreground,
        },
        .outline => .{
            .fill = .transparent,
            .border = theme.border,
            .foreground = theme.foreground,
        },
        .destructive => .{
            .fill = theme.destructive,
            .border = .transparent,
            .foreground = theme.destructive_foreground,
        },
        .info => .{
            .fill = theme.info.alpha(16),
            .border = .transparent,
            .foreground = theme.info_text,
        },
        .success => .{
            .fill = theme.success.alpha(16),
            .border = .transparent,
            .foreground = theme.success,
        },
        .warning => .{
            .fill = theme.warning.alpha(16),
            .border = .transparent,
            .foreground = theme.warning,
        },
    };
}

/// Writes a pill badge into the innermost open box.
pub fn view(tree: *Tree, theme: *const Theme, options: Options) tree_zig.Error!void {
    assert(options.label.len > 0);
    const colors = look(theme, options.variant);
    const pill = try tree.open(.{
        .id = options.id,
        .axis = .row,
        .width = .fit,
        .padding = options.size.padding(),
        .gap = 4,
        .main = .center,
        .cross = .center,
        .fill = colors.fill.fade(options.presence),
        .border = colors.border.fade(options.presence),
        .border_width = Theme.border_width,
        .radius = Theme.radius_sm,
    });
    if (options.icon != icons.none) {
        _ = try tree.icon(.{
            .codepoint = options.icon,
            .color = colors.foreground.fade(options.presence),
            .size = options.size.iconSize(),
        });
    }
    _ = try tree.text(options.label, .{
        .color = colors.foreground.fade(options.presence),
        .style = options.size.textStyle(),
    });
    tree.close(pill);
}
