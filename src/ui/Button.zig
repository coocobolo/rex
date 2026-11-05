//! Immediate-mode interactive button primitive for emulator GUI overlays.
//!
//! Emits cache-line-aligned card quads and typography into caller-provided
//! frame buffers, applies focus rings using active theme semantic tokens,
//! and registers mouse hit-test regions into the active hotspot table.

const std = @import("std");
const Tokens = @import("../color/Tokens.zig").Tokens;
const Card = @import("../renderer/Card.zig");
const HotspotTable = @import("hotspot.zig").HotspotTable;
const UiAction = @import("hotspot.zig").UiAction;
const Text = @import("Text.zig");

pub const Button = @This();

pub const Style = enum {
    default,
    primary,
    danger,
    ghost,
};

pub const Option = struct {
    focus_indicator: []const u8 = ">",
    corner_radius: f32 = 4.0,
    border_width: f32 = 1.0,
    focus_border_width: f32 = 1.5,
};

pub const Request = struct {
    col: u16,
    row: u16,
    width: u16,
    height: u16 = 1,
    label: []const u8,
    shortcut: ?[]const u8 = null,
    style: Style = .default,
    focused: bool = false,
    action: UiAction,
    corner_radius: f32 = 4.0,
    border_width: f32 = 1.0,
    focus_border_width: f32 = 1.5,
    focus_indicator: []const u8 = ">",
};

pub fn render(
    req: Request,
    tokens: Tokens,
    card_buffer: *std.ArrayListUnmanaged(Card.Instance),
    hotspots: *HotspotTable,
    drawer: Text.Drawer,
) void {
    hotspots.add(req.col, req.row, req.width, req.height, req.action);

    const border_color = if (req.focused)
        tokens.accent
    else switch (req.style) {
        .danger => tokens.critical,
        .primary => tokens.accent,
        else => tokens.border,
    };

    const bg_color = tokens.card_opaque;
    const effective_border_w = if (req.focused) req.focus_border_width else req.border_width;

    card_buffer.append(drawer.allocator, .{
        .col = req.col,
        .row = req.row,
        .width = req.width,
        .height = req.height,
        .bg_color = Tokens.toF32Rgba(bg_color, 255),
        .border_color = Tokens.toF32Rgba(border_color, 255),
        .radius = req.corner_radius,
        .border_width = effective_border_w,
    }) catch {};

    const max_col = req.col + req.width;
    var text_col = req.col + 1;
    if (req.focused and req.focus_indicator.len > 0) {
        _ = drawer.drawString(text_col, req.row, req.focus_indicator, tokens.accent, 255, max_col);
        text_col += Text.measure(req.focus_indicator) + 1;
    }

    const fg_color = if (req.focused)
        tokens.primary
    else switch (req.style) {
        .danger => tokens.critical,
        .primary => tokens.accent,
        else => tokens.secondary,
    };

    _ = drawer.drawString(text_col, req.row, req.label, fg_color, 255, max_col);

    if (req.shortcut) |sc| {
        const sc_len: u16 = Text.measure(sc);
        if (req.width > sc_len + 3) {
            const sc_col = req.col + req.width - sc_len - 1;
            if (sc_col > text_col + Text.measure(req.label)) {
                _ = drawer.drawString(sc_col, req.row, sc, tokens.muted, 255, max_col);
            }
        }
    }
}

test "Button: request initialization" {
    const testing = std.testing;
    const req: Request = .{
        .col = 5,
        .row = 10,
        .width = 20,
        .label = "Quit",
        .shortcut = "Ctrl+Q",
        .style = .danger,
        .focused = true,
        .action = .confirm_quit,
    };
    try testing.expectEqual(@as(u16, 5), req.col);
    try testing.expectEqual(@as(u16, 10), req.row);
    try testing.expectEqual(@as(u16, 20), req.width);
    try testing.expect(req.focused);
    try testing.expectEqual(Style.danger, req.style);
}
