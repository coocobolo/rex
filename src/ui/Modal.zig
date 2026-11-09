//! General UI modal dialog component for centered confirmation prompts and overlays.
//!
//! Renders a centered SDF rounded card with outside backdrop dimming, semantic
//! border styling, primary and secondary description rows, interactive action
//! prompt rows with keyboard focus highlights, and deterministic cell-grid hit-testing.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Tokens = @import("../color/Tokens.zig").Tokens;
const Background = @import("../renderer/Background.zig");
const Card = @import("../renderer/Card.zig");
const Rect = @import("Rect.zig").Rect;
const Padding = @import("Rect.zig").Padding;
const Border = @import("Border.zig");
const Box = @import("Box.zig");
const Label = @import("Label.zig");
const Kbd = @import("Kbd.zig");
const Icon = @import("Icon.zig");
const Text = @import("Text.zig");
const Toast = @import("Toast.zig");
const Button = @import("Button.zig");
const Table = @import("hotspot.zig").Table;
const FocusGroup = @import("focus.zig").FocusGroup;

pub const Modal = @This();

pub const DefaultFocus = enum {
    confirm,
    cancel,
};

/// What a click outside an open dialog does.
pub const OutsideClick = enum { close, ignore };

pub const Option = struct {
    /// Dialog width, in terminal columns.
    cols: u16 = 46,
    /// Opacity of the darkened backdrop behind the dialog, 0 to 1.
    backdrop_opacity: f32 = 180.0 / 255.0,
    blur: bool = false,
    blur_radius: u8 = 12,
    on_outside_click: OutsideClick = .close,
    icon_style: Icon.IconStyle = .auto,
    default_focus: DefaultFocus = .confirm,

    /// `backdrop_opacity` as the alpha byte the renderer uses; out-of-range
    /// and non-finite values are clamped (non-finite counts as 0).
    pub fn backdropAlpha(self: Option) u8 {
        const opacity = if (std.math.isFinite(self.backdrop_opacity)) std.math.clamp(self.backdrop_opacity, 0, 1) else 0;
        return @intFromFloat(@round(opacity * 255));
    }
};

pub const Action = struct {
    prompt: []const u8 = ">",
    shortcut: []const u8,
    label: []const u8,
    style: Button.Style = .default,
};

pub const Request = struct {
    title: []const u8,
    line1: []const u8 = "",
    line2: []const u8 = "",
    actions: []const Action = &.{},
    variant: Toast.Variant = .warning,
    border_style: Card.BorderStyle = .semantic,
    icon_style: Icon.IconStyle = .auto,
    dim_alpha: u8 = 180,
    corner_radius: f32 = 8.0,
    border_width: f32 = 1.0,
    cols: u16 = 46,
};

/// Computed cell-grid geometry and interactive action rows for a centered modal card.
pub const Layout = struct {
    col: u16,
    row: u16,
    width: u16,
    height: u16,
    content_col: u16,
    max_content_col: u16,
    actions_start_row: u16,
    action_count: u8,
};

pub const HitResult = union(enum) {
    outside,
    body,
    action: u8,
};

/// Computes the deterministic cell-grid layout for a modal request without allocating or drawing.
pub fn computeLayout(req: Request, total_cols: u16, total_rows: u16) ?Layout {
    if (total_cols < 20 or total_rows < 5) return null;

    const action_count: u8 = @intCast(@min(req.actions.len, 8));
    var desired_h: u16 = 3;
    if (req.line1.len > 0 or req.line2.len > 0) {
        desired_h += 1;
        if (req.line1.len > 0) desired_h += 1;
        if (req.line2.len > 0) desired_h += 1;
    }
    if (action_count > 0) {
        desired_h += 1 + @as(u16, action_count);
    }

    const modal_w: u16 = if (total_cols > 6) @min(total_cols - 4, req.cols) else total_cols;
    const modal_h: u16 = if (total_rows > desired_h + 2) desired_h else @min(total_rows, desired_h);
    const center_rect = Rect.center(total_cols, total_rows, modal_w, modal_h);

    const content_col: u16 = if (modal_w > 34) center_rect.col + 3 else center_rect.col + 2;
    const max_content_col: u16 = if (modal_w > 2) center_rect.col + modal_w - 2 else center_rect.col;

    var cur_r: u16 = center_rect.row + 2;
    if (req.line1.len > 0 or req.line2.len > 0) {
        cur_r += 1;
        if (req.line1.len > 0) cur_r += 1;
        if (req.line2.len > 0) cur_r += 1;
    }

    const actions_start_row = cur_r + (if (action_count > 0) @as(u16, 1) else 0);

    return .{
        .col = center_rect.col,
        .row = center_rect.row,
        .width = center_rect.width,
        .height = center_rect.height,
        .content_col = content_col,
        .max_content_col = max_content_col,
        .actions_start_row = actions_start_row,
        .action_count = action_count,
    };
}

/// Hit-tests a mouse coordinate `(col, row)` against the computed modal layout.
pub fn hitTestLayout(layout: Layout, col: u16, row: u16) HitResult {
    if (col < layout.col or col >= layout.col + layout.width or
        row < layout.row or row >= layout.row + layout.height)
    {
        return .outside;
    }

    if (layout.action_count > 0 and
        row >= layout.actions_start_row and
        row < layout.actions_start_row + layout.action_count and
        col >= layout.content_col and col <= layout.max_content_col)
    {
        const act_idx: u8 = @intCast(row - layout.actions_start_row);
        return .{ .action = act_idx };
    }

    return .body;
}

/// Hit-tests a mouse coordinate `(col, row)` against the modal request bounds and action rows.
pub fn hitTest(req: Request, total_cols: u16, total_rows: u16, col: u16, row: u16) ?HitResult {
    const layout = computeLayout(req, total_cols, total_rows) orelse return null;
    return hitTestLayout(layout, col, row);
}

pub const drawBox = Box.fillCells;
pub const drawDimmingBackdropOutside = Box.dimOutside;

/// Renders a centered modal card and its backdrop dimming into the provided overlay buffers.
pub fn render(
    req: Request,
    tokens: Tokens,
    total_cols: u16,
    total_rows: u16,
    bg_buffer: *std.ArrayListUnmanaged(Background.Instance),
    card_buffer: *std.ArrayListUnmanaged(Card.Instance),
    drawer: Text.Drawer,
    focus: ?*const FocusGroup,
    hotspots: ?*Table,
) ?Layout {
    const layout = computeLayout(req, total_cols, total_rows) orelse return null;

    const accent: [3]u8 = switch (req.variant) {
        .neutral => tokens.border,
        .info => tokens.info,
        .success => tokens.healthy,
        .warning => tokens.warning,
        .critical => tokens.critical,
    };

    _ = Box.render(
        .{
            .rect = .{ .col = layout.col, .row = layout.row, .width = layout.width, .height = layout.height },
            .option = .{
                .surface = .card,
                .border = .{
                    .shape = .rounded,
                    .radius = req.corner_radius,
                    .width = req.border_width,
                    .style = if (req.border_style == .semantic) .semantic else .normal,
                },
                .backdrop_dim_alpha = req.dim_alpha,
                .padding = Padding.all(0),
            },
            .semantic_accent = accent,
            .viewport_cols = total_cols,
            .viewport_rows = total_rows,
        },
        tokens,
        bg_buffer,
        card_buffer,
        drawer.allocator,
        drawer,
        null,
    );

    const max_r = layout.row + layout.height - 1;
    var cur_r = layout.row + 1;

    if (cur_r < max_r) {
        _ = Label.renderAt(layout.content_col, cur_r, layout.max_content_col, req.title, .{ .color = accent }, tokens, drawer);
    }
    cur_r += 1;

    if (req.line1.len > 0 or req.line2.len > 0) {
        cur_r += 1;
        if (req.line1.len > 0 and cur_r < max_r) {
            _ = Label.renderAt(layout.content_col, cur_r, layout.max_content_col, req.line1, .{ .role = .primary }, tokens, drawer);
            cur_r += 1;
        }
        if (req.line2.len > 0 and cur_r < max_r) {
            _ = Label.renderAt(layout.content_col, cur_r, layout.max_content_col, req.line2, .{ .role = .secondary }, tokens, drawer);
            cur_r += 1;
        }
    }

    if (layout.action_count > 0) {
        const kbd_opt: Kbd.Option = .{ .icon_style = req.icon_style };
        var max_shortcut_w: u16 = 0;
        for (req.actions[0..layout.action_count]) |act| {
            const w = Kbd.measureChord(act.shortcut, kbd_opt);
            if (w > max_shortcut_w) max_shortcut_w = w;
        }

        var act_r = layout.actions_start_row;
        for (req.actions[0..layout.action_count], 0..) |act, i| {
            if (act_r >= max_r) break;
            const idx: u8 = @intCast(i);
            const is_focused = if (focus) |f| f.isFocused(idx) else false;

            if (hotspots) |ht| {
                ht.add(layout.content_col, act_r, layout.max_content_col - layout.content_col, 1, .{ .modal_action = idx });
            }

            var col = layout.content_col;
            if (act.prompt.len > 0) {
                const prompt_role: Label.Role = if (is_focused) .accent else .muted;
                col += Label.renderAt(col, act_r, layout.max_content_col, act.prompt, .{ .role = prompt_role }, tokens, drawer);
                col += 1;
            }
            _ = Kbd.renderChord(.{
                .col = col,
                .row = act_r,
                .max_col = layout.max_content_col,
                .chord = act.shortcut,
                .option = .{ .focused = is_focused, .icon_style = req.icon_style },
            }, tokens, card_buffer, drawer, null);

            const label_col = col + max_shortcut_w + 2;
            if (label_col <= layout.max_content_col) {
                const label_role: Label.Role = if (is_focused) .primary else .muted;
                _ = Label.renderAt(label_col, act_r, layout.max_content_col, act.label, .{ .role = label_role }, tokens, drawer);
            }
            act_r += 1;
        }
    }

    return layout;
}
