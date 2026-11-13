//! Immediate-mode interactive button primitive for GPU-accelerated UI overlays.
//!
//! Emits cache-line-aligned card quads and typography into caller-provided
//! frame buffers, applies focus rings using active theme semantic tokens,
//! and registers mouse hit-test regions into the active hotspot table.

const std = @import("std");

const overlay_config = @import("../config/overlay.zig");
const Tokens = @import("../color/Tokens.zig").Tokens;
const Card = @import("../renderer/Card.zig");
const Table = @import("hotspot.zig").Table;
const Action = @import("hotspot.zig").Action;
const Rect = @import("Rect.zig").Rect;
const Padding = @import("Rect.zig").Padding;
const Border = @import("Border.zig");
const Box = @import("Box.zig");
const Text = @import("Text.zig");
const Label = @import("Label.zig");
const Kbd = @import("Kbd.zig");
const Icon = @import("Icon.zig");

pub const Button = @This();

pub const Style = enum {
    default,
    primary,
    danger,
    ghost,
};

pub const Option = overlay_config.Button;

pub const Request = struct {
    col: u16,
    row: u16,
    width: u16,
    height: u16 = 1,
    label: []const u8,
    shortcut: ?[]const u8 = null,
    style: Style = .default,
    focused: bool = false,
    action: Action,
    icon_style: Icon.IconStyle = .auto,
    corner_radius: f32 = 4.0,
    border_width: f32 = 1.0,
    focus_border_width: f32 = 1.5,
    focus_indicator: []const u8 = ">",
};

pub fn render(
    req: Request,
    tokens: Tokens,
    card_buffer: *std.ArrayListUnmanaged(Card.Instance),
    hotspots: *Table,
    drawer: Text.Drawer,
) void {
    const semantic_accent: ?[3]u8 = switch (req.style) {
        .danger => tokens.critical,
        .primary => tokens.accent,
        else => null,
    };

    const surface: Box.Surface = if (req.style == .ghost) .none else .card;
    const inner = Box.render(
        .{
            .rect = .{ .col = req.col, .row = req.row, .width = req.width, .height = req.height },
            .option = .{
                .surface = surface,
                .border = .{
                    .shape = .rounded,
                    .radius = req.corner_radius,
                    .width = req.border_width,
                    .focus_width = req.focus_border_width,
                    .style = if (req.style == .ghost and !req.focused) .none else .semantic,
                },
                .padding = Padding.horizontal(1),
            },
            .semantic_accent = semantic_accent,
            .focused = req.focused,
            .action = req.action,
        },
        tokens,
        null,
        card_buffer,
        drawer.allocator,
        drawer,
        hotspots,
    );

    if (inner.width == 0) return;
    const max_c = inner.maxCol();
    var text_col = inner.col;

    if (req.focused and req.focus_indicator.len > 0) {
        text_col += Label.renderAt(text_col, inner.row, max_c, req.focus_indicator, .{ .role = .accent }, tokens, drawer);
        if (text_col <= max_c) {
            _ = drawer.drawChar(text_col, inner.row, ' ', tokens.muted, 255);
            text_col += 1;
        }
    }

    const label_role: Label.Role = if (req.focused)
        .primary
    else switch (req.style) {
        .danger => .critical,
        .primary => .accent,
        else => .secondary,
    };

    const label_w = Label.renderAt(text_col, inner.row, max_c, req.label, .{ .role = label_role }, tokens, drawer);

    if (req.shortcut) |sc| {
        // Borderless pill so the keycap does not stack a second stroke on the button's own border.
        const kbd_opt: Kbd.Option = .{ .style = .pill, .focused = req.focused, .connector_pad = 0, .icon_style = req.icon_style };
        const sc_len = Kbd.measureChord(sc, kbd_opt);
        if (inner.width > sc_len + 1) {
            const sc_col = inner.rightEdge() - sc_len;
            if (sc_col > text_col + label_w) {
                _ = Kbd.renderChord(.{ .col = sc_col, .row = inner.row, .max_col = max_c, .chord = sc, .option = kbd_opt }, tokens, card_buffer, drawer, null);
            }
        }
    }
}
