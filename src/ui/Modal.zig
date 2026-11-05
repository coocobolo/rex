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
const Text = @import("Text.zig");
const Toast = @import("Toast.zig");
const Button = @import("Button.zig");
const HotspotTable = @import("hotspot.zig").HotspotTable;
const UiAction = @import("hotspot.zig").UiAction;
const FocusGroup = @import("focus.zig").FocusGroup;

pub const Modal = @This();

pub const DefaultFocus = enum {
    confirm,
    cancel,
};

pub const Option = struct {
    width: u16 = 46,
    dim_alpha: u8 = 180,
    blur: bool = false,
    blur_radius: u8 = 12,
    close_on_outside_click: bool = true,
    corner_radius: ?f32 = null,
    border_width: ?f32 = null,
    border_style: ?Card.BorderStyle = null,
    default_focus: DefaultFocus = .confirm,
    title: []const u8 = "QUIT TERMINAL?",
    line1: []const u8 = "Active terminal session is still running.",
    line2: []const u8 = "Close this window and terminate the session?",
    confirm_label: []const u8 = "Quit terminal",
    cancel_label: []const u8 = "Cancel and stay",
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
    dim_alpha: u8 = 180,
    corner_radius: f32 = 8.0,
    border_width: f32 = 1.0,
    width: u16 = 46,
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

    const modal_w: u16 = if (total_cols > 6) @min(total_cols - 4, req.width) else total_cols;
    const modal_h: u16 = if (total_rows > desired_h + 2) desired_h else @min(total_rows, desired_h);
    const col: u16 = if (total_cols > modal_w) (total_cols - modal_w) / 2 else 0;
    const row: u16 = if (total_rows > modal_h) (total_rows - modal_h) / 2 else 0;

    const content_col: u16 = if (modal_w > 34) col + 3 else col + 2;
    const max_content_col: u16 = if (modal_w > 2) col + modal_w - 2 else col;

    var cur_r: u16 = row + 2;
    if (req.line1.len > 0 or req.line2.len > 0) {
        cur_r += 1;
        if (req.line1.len > 0) cur_r += 1;
        if (req.line2.len > 0) cur_r += 1;
    }
    const actions_start_row: u16 = if (action_count > 0) cur_r + 1 else cur_r;

    return .{
        .col = col,
        .row = row,
        .width = modal_w,
        .height = modal_h,
        .content_col = content_col,
        .max_content_col = max_content_col,
        .actions_start_row = actions_start_row,
        .action_count = action_count,
    };
}

/// Tests a mouse cell coordinate against a precomputed modal layout.
pub fn hitTestLayout(layout: Layout, mouse_col: u16, mouse_row: u16) HitResult {
    if (mouse_col < layout.col or mouse_col >= layout.col + layout.width or
        mouse_row < layout.row or mouse_row >= layout.row + layout.height)
    {
        return .outside;
    }
    if (layout.action_count > 0 and
        mouse_row >= layout.actions_start_row and
        mouse_row < layout.actions_start_row + @as(u16, layout.action_count))
    {
        return .{ .action = @intCast(mouse_row - layout.actions_start_row) };
    }
    return .body;
}

/// Tests a mouse cell coordinate against the modal request geometry.
pub fn hitTest(req: Request, total_cols: u16, total_rows: u16, mouse_col: u16, mouse_row: u16) ?HitResult {
    const layout = computeLayout(req, total_cols, total_rows) orelse return null;
    return hitTestLayout(layout, mouse_col, mouse_row);
}

fn drawBox(
    allocator: Allocator,
    bg_buffer: *std.ArrayListUnmanaged(Background.Instance),
    col: u16,
    row: u16,
    width: u16,
    height: u16,
    color: [4]u8,
) void {
    for (0..height) |i| {
        bg_buffer.append(allocator, .{
            .col = col,
            .row = @intCast(row + i),
            .span = width,
            .r = color[0],
            .g = color[1],
            .b = color[2],
            .a = color[3],
        }) catch {};
    }
}

/// Emits background dimming spans strictly outside the given panel bounds so the SDF card corners blend cleanly.
pub fn drawDimmingBackdropOutside(
    allocator: Allocator,
    bg_buffer: *std.ArrayListUnmanaged(Background.Instance),
    total_cols: u16,
    total_rows: u16,
    col: u16,
    row: u16,
    width: u16,
    height: u16,
    dim_color: [4]u8,
) void {
    const max_col = col + width;
    const max_row = row + height;

    if (row > 0) {
        drawBox(allocator, bg_buffer, 0, 0, total_cols, row, dim_color);
    }
    const mid_start = row;
    const mid_end = @min(total_rows, max_row);
    if (mid_end > mid_start) {
        const mid_h = mid_end - mid_start;
        if (col > 0) {
            drawBox(allocator, bg_buffer, 0, mid_start, col, mid_h, dim_color);
        }
        if (total_cols > max_col) {
            drawBox(allocator, bg_buffer, max_col, mid_start, total_cols - max_col, mid_h, dim_color);
        }
    }
    if (total_rows > max_row) {
        drawBox(allocator, bg_buffer, 0, max_row, total_cols, total_rows - max_row, dim_color);
    }
}

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
    hotspots: ?*HotspotTable,
) ?Layout {
    const layout = computeLayout(req, total_cols, total_rows) orelse return null;

    const accent: [3]u8 = switch (req.variant) {
        .neutral => tokens.border,
        .info => tokens.info,
        .success => tokens.healthy,
        .warning => tokens.warning,
        .critical => tokens.critical,
    };

    const border_color: [3]u8 = if (req.border_style == .semantic) accent else tokens.border;

    if (req.dim_alpha > 0) {
        drawDimmingBackdropOutside(
            drawer.allocator,
            bg_buffer,
            total_cols,
            total_rows,
            layout.col,
            layout.row,
            layout.width,
            layout.height,
            .{ tokens.bg[0], tokens.bg[1], tokens.bg[2], req.dim_alpha },
        );
    }

    card_buffer.append(drawer.allocator, .{
        .col = layout.col,
        .row = layout.row,
        .width = layout.width,
        .height = layout.height,
        .bg_color = Tokens.toF32Rgba(tokens.card_opaque, 255),
        .border_color = Tokens.toF32Rgba(border_color, 255),
        .radius = req.corner_radius,
        .border_width = req.border_width,
    }) catch {};

    const max_r = layout.row + layout.height - 1;
    var cur_r = layout.row + 1;

    if (cur_r < max_r) {
        _ = drawer.drawString(layout.content_col, cur_r, req.title, accent, 255, layout.max_content_col);
    }
    cur_r += 1;

    if (req.line1.len > 0 or req.line2.len > 0) {
        cur_r += 1;
        if (req.line1.len > 0 and cur_r < max_r) {
            _ = drawer.drawString(layout.content_col, cur_r, req.line1, tokens.primary, 255, layout.max_content_col);
            cur_r += 1;
        }
        if (req.line2.len > 0 and cur_r < max_r) {
            _ = drawer.drawString(layout.content_col, cur_r, req.line2, tokens.secondary, 255, layout.max_content_col);
            cur_r += 1;
        }
    }

    if (layout.action_count > 0) {
        var max_shortcut_w: u16 = 0;
        for (req.actions[0..layout.action_count]) |act| {
            const w = Text.measure(act.shortcut);
            if (w > max_shortcut_w) max_shortcut_w = w;
        }

        var act_r = layout.actions_start_row;
        for (req.actions[0..layout.action_count], 0..) |act, i| {
            if (act_r >= max_r) break;
            const idx: u8 = @intCast(i);
            const is_focused = if (focus) |f| f.isFocused(idx) else false;

            if (hotspots) |ht| {
                const action_kind: UiAction = if (idx == 0) .confirm_quit else if (idx == 1) .cancel_modal else .{ .modal_action = idx };
                ht.add(layout.content_col, act_r, layout.max_content_col - layout.content_col, 1, action_kind);
            }

            var col = layout.content_col;
            if (act.prompt.len > 0) {
                const prompt_color = if (is_focused) tokens.accent else tokens.muted;
                col += drawer.drawString(col, act_r, act.prompt, prompt_color, 255, layout.max_content_col) + 1;
            }
            const shortcut_color = if (is_focused) tokens.accent else tokens.primary;
            _ = drawer.drawString(col, act_r, act.shortcut, shortcut_color, 255, layout.max_content_col);

            const label_col = col + max_shortcut_w + 3;
            if (label_col <= layout.max_content_col) {
                const label_color = if (is_focused) tokens.primary else tokens.muted;
                _ = drawer.drawString(label_col, act_r, act.label, label_color, 255, layout.max_content_col);
            }
            act_r += 1;
        }
    }

    return layout;
}

test "Modal: computeLayout and hitTest on centered confirmation dialog" {
    const testing = std.testing;

    const actions = [_]Action{
        .{ .shortcut = "Enter / Y", .label = "Quit terminal" },
        .{ .shortcut = "Esc / N", .label = "Cancel and stay" },
    };
    const req: Request = .{
        .title = "QUIT TERMINAL?",
        .line1 = "Active terminal session is still running.",
        .line2 = "Close this window and terminate the session?",
        .actions = &actions,
    };

    const layout = computeLayout(req, 80, 24).?;
    try testing.expectEqual(@as(u16, 46), layout.width);
    try testing.expectEqual(@as(u16, 9), layout.height);
    try testing.expectEqual(@as(u16, 17), layout.col);
    try testing.expectEqual(@as(u16, 7), layout.row);
    try testing.expectEqual(@as(u16, 13), layout.actions_start_row);
    try testing.expectEqual(@as(u8, 2), layout.action_count);

    // Click outside modal bounds
    try testing.expectEqual(HitResult.outside, hitTestLayout(layout, 2, 2));

    // Click inside modal header/body
    try testing.expectEqual(HitResult.body, hitTestLayout(layout, 25, 9));

    // Click first action row (Quit terminal)
    try testing.expectEqual(HitResult{ .action = 0 }, hitTestLayout(layout, 25, 13));

    // Click second action row (Cancel and stay)
    try testing.expectEqual(HitResult{ .action = 1 }, hitTestLayout(layout, 25, 14));
}
