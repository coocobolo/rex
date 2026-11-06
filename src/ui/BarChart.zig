//! Immediate-mode vertical column chart and horizontal bar chart primitive.
//!
//! Renders time-series column charts using sub-pixel `.bar_v` SDF instances and
//! categorical ranked bar charts using sub-pixel `.bar_h` SDF instances with
//! in-stream hotspot registration for interactive data inspection.

const std = @import("std");
const Tokens = @import("../color/Tokens.zig").Tokens;
const Card = @import("../renderer/Card.zig");
const Text = @import("Text.zig");
const Table = @import("hotspot.zig").Table;

pub const BarChart = @This();

pub const Column = struct {
    value: f32,
    secondary_value: f32 = 0.0,
    label: []const u8 = "",
    color: ?[3]u8 = null,
};

pub const VerticalRequest = struct {
    col: u16,
    row: u16,
    width: u16,
    height: u16,
    columns: []const Column,
    max_value: f32 = 0.0,
    selected_index: ?u16 = null,
    bar_color: ?[3]u8 = null,
    secondary_color: ?[3]u8 = null,
    show_labels: bool = true,
    corner_radius: f32 = 3.0,
    horizontal_inset_px: f32 = 2.0,
};

pub const HorizontalBar = struct {
    label: []const u8,
    value: f32,
    value_text: []const u8 = "",
    color: ?[3]u8 = null,
};

pub const HorizontalRequest = struct {
    col: u16,
    row: u16,
    width: u16,
    max_rows: u16,
    bars: []const HorizontalBar,
    max_value: f32 = 0.0,
    bar_color: ?[3]u8 = null,
    corner_radius: f32 = 3.0,
    vertical_inset_px: f32 = 5.0,
};

pub fn computeMaxColumnValue(columns: []const Column, explicit_max: f32) f32 {
    if (explicit_max > 0.0) return explicit_max;
    var max_v: f32 = 1.0;
    for (columns) |c| {
        max_v = @max(max_v, @max(c.value, c.secondary_value));
    }
    return max_v;
}

pub fn renderVertical(
    req: VerticalRequest,
    tokens: Tokens,
    card_buffer: *std.ArrayListUnmanaged(Card.Instance),
    drawer: ?Text.Drawer,
    hotspots: ?*Table,
) u16 {
    if (req.columns.len == 0 or req.width < 4 or req.height < 2) return 0;

    const allocator = if (drawer) |d| d.allocator else return 0;
    const label_rows: u16 = if (req.show_labels and req.height >= 3) 1 else 0;
    const plot_h: u16 = req.height - label_rows;
    const count: u16 = @intCast(@min(req.columns.len, req.width));
    const col_stride: u16 = @max(1, req.width / count);
    const bar_cell_w: u16 = @max(1, @min(3, col_stride));
    const max_val = computeMaxColumnValue(req.columns[0..count], req.max_value);

    const default_bar_col = req.bar_color orelse tokens.accent;
    const sec_col = req.secondary_color orelse tokens.border_subtle;

    var i: u16 = 0;
    while (i < count) : (i += 1) {
        const item = req.columns[i];
        const bar_c = req.col + i * col_stride;
        if (bar_c + bar_cell_w > req.col + req.width) break;

        const is_selected = if (req.selected_index) |sel| sel == i else false;
        const primary_frac = std.math.clamp(item.value / max_val, 0.0, 1.0);
        const secondary_frac = std.math.clamp(item.secondary_value / max_val, 0.0, 1.0);

        if (secondary_frac > 0.001) {
            card_buffer.append(allocator, .{
                .col = bar_c,
                .row = req.row,
                .width = bar_cell_w,
                .height = plot_h,
                .bg_color = if (is_selected) Tokens.toF32Rgba(tokens.border_subtle, 90) else .{ 0.0, 0.0, 0.0, 0.0 },
                .border_color = Tokens.toF32Rgba(sec_col, 200),
                .radius = req.corner_radius,
                .border_width = req.horizontal_inset_px,
                .progress = secondary_frac,
                .kind = .bar_v,
            }) catch {};
        }

        const fg_bar_color = if (is_selected)
            tokens.healthy
        else
            item.color orelse default_bar_col;

        const track_rgba = if (secondary_frac <= 0.001)
            Tokens.toF32Rgba(tokens.border_subtle, if (is_selected) 110 else 45)
        else
            [4]f32{ 0.0, 0.0, 0.0, 0.0 };

        card_buffer.append(allocator, .{
            .col = bar_c,
            .row = req.row,
            .width = bar_cell_w,
            .height = plot_h,
            .bg_color = track_rgba,
            .border_color = Tokens.toF32Rgba(fg_bar_color, 255),
            .radius = req.corner_radius,
            .border_width = req.horizontal_inset_px,
            .progress = @max(primary_frac, if (item.value > 0.0) @as(f32, 0.04) else 0.0),
            .kind = .bar_v,
        }) catch {};

        if (hotspots) |ht| {
            ht.add(bar_c, req.row, col_stride, req.height, .{ .chart_select = i });
        }

        if (label_rows > 0 and item.label.len > 0) {
            if (drawer) |d| {
                const lbl_color = if (is_selected) tokens.primary else tokens.muted;
                _ = d.drawString(bar_c, req.row + plot_h, item.label, lbl_color, 255, bar_c + col_stride - 1);
            }
        }
    }

    return count;
}

pub fn renderHorizontal(
    req: HorizontalRequest,
    tokens: Tokens,
    card_buffer: *std.ArrayListUnmanaged(Card.Instance),
    drawer: Text.Drawer,
) u16 {
    if (req.bars.len == 0 or req.width < 12 or req.max_rows == 0) return 0;

    var max_v: f32 = if (req.max_value > 0.0) req.max_value else 1.0;
    if (req.max_value <= 0.0) {
        for (req.bars) |b| max_v = @max(max_v, b.value);
    }

    var max_label_w: u16 = 6;
    var max_val_w: u16 = 0;
    const rows_to_draw: usize = @min(req.bars.len, req.max_rows);
    for (req.bars[0..rows_to_draw]) |b| {
        max_label_w = @max(max_label_w, @min(14, Text.measure(b.label)));
        max_val_w = @max(max_val_w, Text.measure(b.value_text));
    }

    const label_col = req.col;
    const bar_col = req.col + max_label_w + 2;
    const right_reserve = if (max_val_w > 0) max_val_w + 2 else 0;
    const bar_w: u16 = if (req.col + req.width > bar_col + right_reserve)
        (req.col + req.width) - bar_col - right_reserve
    else
        0;

    const fill_default = req.bar_color orelse tokens.accent;
    var r_idx: u16 = 0;
    while (r_idx < rows_to_draw) : (r_idx += 1) {
        const item = req.bars[r_idx];
        const row = req.row + r_idx;

        _ = Text.drawEllipsis(drawer, label_col, row, item.label, tokens.primary, 255, label_col + max_label_w, "…");

        if (bar_w >= 3) {
            const frac = std.math.clamp(item.value / max_v, 0.0, 1.0);
            card_buffer.append(drawer.allocator, .{
                .col = bar_col,
                .row = row,
                .width = bar_w,
                .height = 1,
                .bg_color = Tokens.toF32Rgba(tokens.border_subtle, 255),
                .border_color = Tokens.toF32Rgba(item.color orelse fill_default, 255),
                .radius = req.corner_radius,
                .border_width = req.vertical_inset_px,
                .progress = @max(frac, if (item.value > 0.0) @as(f32, 0.04) else 0.0),
                .kind = .bar_h,
            }) catch {};
        }

        if (item.value_text.len > 0) {
            const val_w = Text.measure(item.value_text);
            const val_col = req.col + req.width - val_w;
            _ = drawer.drawString(val_col, row, item.value_text, tokens.secondary, 255, req.col + req.width);
        }
    }

    return r_idx;
}

test "BarChart: computeMaxColumnValue auto-scales dual series" {
    const testing = std.testing;
    const cols = [_]Column{
        .{ .value = 120.0, .secondary_value = 300.0, .label = "M" },
        .{ .value = 240.0, .secondary_value = 180.0, .label = "T" },
    };
    try testing.expectEqual(@as(f32, 300.0), computeMaxColumnValue(&cols, 0.0));
    try testing.expectEqual(@as(f32, 500.0), computeMaxColumnValue(&cols, 500.0));
}
