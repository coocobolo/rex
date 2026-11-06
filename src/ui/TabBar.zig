//! Immediate-mode segmented tab bar primitive for multi-view overlays.
//!
//! Renders a horizontal row of interactive tab pills with active selection
//! styling, optional keyboard shortcut hints, and in-stream hotspot registration.

const std = @import("std");
const Tokens = @import("../color/Tokens.zig").Tokens;
const Card = @import("../renderer/Card.zig");
const Rect = @import("Rect.zig").Rect;
const Padding = @import("Rect.zig").Padding;
const Border = @import("Border.zig");
const Box = @import("Box.zig");
const Text = @import("Text.zig");
const Label = @import("Label.zig");
const Kbd = @import("Kbd.zig");
const Icon = @import("Icon.zig");
const Table = @import("hotspot.zig").Table;

pub const TabBar = @This();

pub const Tab = struct {
    label: []const u8,
    shortcut: ?[]const u8 = null,
};

pub const Request = struct {
    col: u16,
    row: u16,
    max_col: u16,
    tabs: []const Tab,
    active_index: u8 = 0,
    icon_style: Icon.IconStyle = .auto,
    corner_radius: f32 = 4.0,
    spacing: u16 = 1,
};

/// Computes the total cell columns required to render `tabs` with the given spacing.
pub fn measureWidth(tabs: []const Tab, spacing: u16, icon_style: Icon.IconStyle) u16 {
    if (tabs.len == 0) return 0;
    var total: u16 = 0;
    for (tabs, 0..) |tab, i| {
        const kbd_opt: Kbd.Option = .{ .style = .pill, .connector_pad = 0, .padding_h = 0, .icon_style = icon_style };
        const sc_w: u16 = if (tab.shortcut) |sc| Kbd.measureChord(sc, kbd_opt) + 1 else 0;
        const label_w: u16 = Text.measure(tab.label);
        total += label_w + sc_w + 2;
        if (i + 1 < tabs.len) total += spacing;
    }
    return total;
}

pub fn render(
    req: Request,
    tokens: Tokens,
    card_buffer: *std.ArrayListUnmanaged(Card.Instance),
    drawer: Text.Drawer,
    hotspots: ?*Table,
) u16 {
    if (req.tabs.len == 0 or req.col >= req.max_col) return 0;

    var cur_c = req.col;
    for (req.tabs, 0..) |tab, idx| {
        const tab_idx: u8 = @intCast(idx);
        const is_active = tab_idx == req.active_index;

        const kbd_opt: Kbd.Option = .{
            .style = if (is_active) .solid else .pill,
            .connector_pad = 0,
            .padding_h = 0,
            .icon_style = req.icon_style,
        };
        const sc_w: u16 = if (tab.shortcut) |sc| Kbd.measureChord(sc, kbd_opt) + 1 else 0;
        const label_w: u16 = Text.measure(tab.label);
        const pill_w: u16 = label_w + sc_w + 2;

        if (cur_c + pill_w > req.max_col + 1) break;

        const inner = Box.render(
            .{
                .rect = .{ .col = cur_c, .row = req.row, .width = pill_w, .height = 1 },
                .option = .{
                    .surface = .card,
                    .border = .{
                        .shape = .rounded,
                        .radius = req.corner_radius,
                        .width = 1.0,
                        .focus_width = 1.5,
                        .style = if (is_active) .focus else .subtle,
                    },
                    .padding = Padding.horizontal(1),
                },
                .focused = is_active,
                .action = .{ .tab_select = tab_idx },
            },
            tokens,
            null,
            card_buffer,
            drawer.allocator,
            drawer,
            hotspots,
        );

        if (inner.width > 0) {
            const max_pill_c = inner.maxCol();
            var text_c = inner.col;

            if (tab.shortcut) |sc| {
                text_c += Kbd.renderChord(.{
                    .col = text_c,
                    .row = req.row,
                    .max_col = max_pill_c,
                    .chord = sc,
                    .option = kbd_opt,
                }, tokens, card_buffer, drawer, null);
                text_c += 1;
            }

            _ = Label.renderAt(
                text_c,
                req.row,
                max_pill_c,
                tab.label,
                .{ .role = if (is_active) .primary else .secondary },
                tokens,
                drawer,
            );
        }

        cur_c += pill_w + req.spacing;
    }

    return if (cur_c > req.col) cur_c - req.col else 0;
}

test "TabBar: request initialization and measurement" {
    const testing = std.testing;
    const tabs = [_]Tab{
        .{ .label = "Overview", .shortcut = "1" },
        .{ .label = "Pomodoro", .shortcut = "2" },
        .{ .label = "Activity", .shortcut = "3" },
    };
    const req: Request = .{
        .col = 4,
        .row = 1,
        .max_col = 60,
        .tabs = &tabs,
        .active_index = 1,
    };
    try testing.expectEqual(@as(usize, 3), req.tabs.len);
    try testing.expectEqual(@as(u8, 1), req.active_index);

    // Each tab: label (8) + shortcut badge (1) + space (1) + padding (2) = 12 cols
    // 3 tabs + 2 gaps of 1 col = 12 * 3 + 2 = 38 cols
    const w = measureWidth(&tabs, 1, .auto);
    try testing.expectEqual(@as(u16, 38), w);
}
