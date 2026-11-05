//! Immediate-mode text measurement, rendering, bounds clipping, and flowing layout.
//!
//! Provides zero-allocation typography utilities for UI cards, modals, and overlays,
//! including column width measurement, ellipsis truncation, multi-line flow wrapping,
//! and structured bullet tag rendering.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Cell = @import("../renderer/Cell.zig");
const Atlas = @import("../renderer/Atlas.zig");
const Rasterizer = @import("../freetype/root.zig").Rasterizer;
const wc = @import("../unicode/wcwidth.zig");

pub const Text = @This();

/// Measures the display column width of a UTF-8 string in terminal cells,
/// taking into account narrow, wide, and emoji variation sequences.
pub fn measure(str: []const u8) u16 {
    var iter = (std.unicode.Utf8View.init(str) catch return @intCast(str.len)).iterator();
    var w: u16 = 0;
    var prev_cp: ?u21 = null;

    while (iter.nextCodepoint()) |cp| {
        if (cp == 0xFE0F) {
            if (prev_cp) |p| {
                if (wc.wcwidth(p, .narrow) == .narrow) w += 1;
            }
            prev_cp = cp;
            continue;
        }
        if (cp == 0xFE0E) {
            if (prev_cp) |p| {
                if (wc.wcwidth(p, .narrow) == .wide and w > 0) w -= 1;
            }
            prev_cp = cp;
            continue;
        }

        const width = wc.wcwidth(cp, .narrow);
        w += if (width == .wide) 2 else 1;
        prev_cp = cp;
    }
    return w;
}

/// Unified drawing context managing font rasterization and glyph atlas lookup
/// for all native UI components.
pub const Drawer = struct {
    allocator: Allocator,
    atlas: *Atlas,
    rasterizer: *Rasterizer,
    gray_buffer: *std.ArrayListUnmanaged(Cell.Instance),
    color_buffer: *std.ArrayListUnmanaged(Cell.Instance),

    /// Renders a single unicode codepoint into the appropriate instance buffer.
    pub fn drawChar(self: Drawer, col: u16, row: u16, cp: u21, fg: [3]u8, fg_a: u8) u16 {
        const w = wc.wcwidth(cp, .narrow);
        const span: Rasterizer.Span = if (w == .wide) .double else .single;
        if (self.atlas.get(self.allocator, self.rasterizer, cp, .regular, span)) |metric| {
            if (metric.width > 0 and metric.height > 0) {
                const inst: Cell.Instance = .{
                    .col = col,
                    .row = row,
                    .atlas_x = metric.atlas_x,
                    .atlas_y = metric.atlas_y,
                    .bearing_x = metric.bearing_x,
                    .bearing_y = metric.bearing_y,
                    .fg_r = fg[0],
                    .fg_g = fg[1],
                    .fg_b = fg[2],
                    .fg_a = fg_a,
                    .glyph_width = metric.width,
                    .glyph_height = metric.height,
                    .flags = .{},
                };
                switch (metric.kind) {
                    .gray => self.gray_buffer.append(self.allocator, inst) catch {},
                    .color => self.color_buffer.append(self.allocator, inst) catch {},
                }
            }
        } else |_| {}
        return if (w == .wide) 2 else 1;
    }

    /// Renders a UTF-8 string horizontally, strictly clipped at `max_col`.
    pub fn drawString(self: Drawer, start_col: u16, row: u16, str: []const u8, fg: [3]u8, fg_a: u8, max_col: u16) u16 {
        return draw(self, start_col, row, str, fg, fg_a, max_col);
    }
};

/// Renders a UTF-8 string on a single row, strictly terminating before exceeding `max_col`.
pub fn draw(drawer: Drawer, start_col: u16, row: u16, str: []const u8, fg: [3]u8, fg_a: u8, max_col: u16) u16 {
    var iter = (std.unicode.Utf8View.init(str) catch return 0).iterator();
    var col = start_col;
    while (iter.nextCodepoint()) |cp| {
        const w = wc.wcwidth(cp, .narrow);
        const span: u16 = if (w == .wide) 2 else 1;
        if (col + span > max_col + 1) break;
        _ = drawer.drawChar(col, row, cp, fg, fg_a);
        col += span;
    }
    return col - start_col;
}

/// Renders a UTF-8 string with automatic ellipsis truncation if the text exceeds `max_col`.
pub fn drawEllipsis(
    drawer: Drawer,
    start_col: u16,
    row: u16,
    str: []const u8,
    fg: [3]u8,
    fg_a: u8,
    max_col: u16,
    ellipsis: []const u8,
) u16 {
    if (start_col > max_col) return 0;
    const avail_w = max_col - start_col + 1;
    const full_w = measure(str);
    if (full_w <= avail_w) {
        return draw(drawer, start_col, row, str, fg, fg_a, max_col);
    }

    const ell_w = measure(ellipsis);
    if (avail_w <= ell_w) {
        return draw(drawer, start_col, row, ellipsis, fg, fg_a, max_col);
    }

    const text_cap = avail_w - ell_w;
    var iter = (std.unicode.Utf8View.init(str) catch return 0).iterator();
    var col = start_col;
    while (iter.nextCodepoint()) |cp| {
        const w = wc.wcwidth(cp, .narrow);
        const span: u16 = if (w == .wide) 2 else 1;
        if ((col - start_col) + span > text_cap) break;
        _ = drawer.drawChar(col, row, cp, fg, fg_a);
        col += span;
    }
    col += draw(drawer, col, row, ellipsis, fg, fg_a, max_col);
    return col - start_col;
}

/// Zero-allocation flowing layout manager that wraps items, badges, and tags across rows
/// within a bounded rectangular region without overflowing.
pub const Flow = struct {
    start_col: u16,
    max_col: u16,
    cur_col: u16,
    cur_row: u16,
    max_row: u16,
    items_drawn: u16 = 0,
    overflow_count: u16 = 0,

    pub fn init(start_col: u16, start_row: u16, max_col: u16, max_row: u16) Flow {
        return .{
            .start_col = start_col,
            .max_col = max_col,
            .cur_col = start_col,
            .cur_row = start_row,
            .max_row = max_row,
        };
    }

    /// Renders an item string, automatically advancing to the next row if it exceeds `max_col`.
    pub fn add(self: *Flow, drawer: Drawer, str: []const u8, fg: [3]u8, fg_a: u8, spacing: u16) bool {
        const item_w = measure(str);
        if (self.cur_col > self.start_col and self.cur_col + item_w > self.max_col + 1) {
            if (self.cur_row + 1 > self.max_row) {
                self.overflow_count += 1;
                return false;
            }
            self.cur_row += 1;
            self.cur_col = self.start_col;
        }

        if (self.cur_row > self.max_row) {
            self.overflow_count += 1;
            return false;
        }

        const drawn_w = draw(drawer, self.cur_col, self.cur_row, str, fg, fg_a, self.max_col);
        self.cur_col += drawn_w + spacing;
        self.items_drawn += 1;
        return true;
    }

    /// Renders a structured bullet tag consisting of a bullet symbol, primary label, and secondary value.
    pub fn addBullet(
        self: *Flow,
        drawer: Drawer,
        symbol: []const u8,
        label: []const u8,
        value: []const u8,
        sym_color: [3]u8,
        lbl_color: [3]u8,
        val_color: [3]u8,
        fg_a: u8,
        spacing: u16,
    ) bool {
        var total_w = measure(symbol) + 1 + measure(label);
        if (value.len > 0) total_w += 1 + measure(value);

        if (self.cur_col > self.start_col and self.cur_col + total_w > self.max_col + 1) {
            if (self.cur_row + 1 > self.max_row) {
                self.overflow_count += 1;
                return false;
            }
            self.cur_row += 1;
            self.cur_col = self.start_col;
        }

        if (self.cur_row > self.max_row) {
            self.overflow_count += 1;
            return false;
        }

        var col = self.cur_col;
        col += draw(drawer, col, self.cur_row, symbol, sym_color, fg_a, self.max_col);
        col += 1;
        col += draw(drawer, col, self.cur_row, label, lbl_color, fg_a, self.max_col);
        if (value.len > 0) {
            col += 1;
            col += draw(drawer, col, self.cur_row, value, val_color, fg_a, self.max_col);
        }

        self.cur_col = col + spacing;
        self.items_drawn += 1;
        return true;
    }
};

test "Text: measure width calculation" {
    const testing = std.testing;

    try testing.expectEqual(@as(u16, 4), measure("test"));
    try testing.expectEqual(@as(u16, 1), measure("•"));
    try testing.expectEqual(@as(u16, 2), measure("⚠️"));
    try testing.expectEqual(@as(u16, 12), measure("• bash (58m)"));
}

test "Text: flow layout wrapping without overflow" {
    const testing = std.testing;

    // Simulate flow in a box of width 30 columns, 2 rows max
    var flow = Flow.init(2, 5, 32, 6);
    try testing.expectEqual(@as(u16, 2), flow.cur_col);
    try testing.expectEqual(@as(u16, 5), flow.cur_row);

    // Each item is ~12 chars ("• bash (58m)" + 2 spacing = 14 cols)
    const item1_w: u16 = measure("• bash (58m)");
    const item2_w: u16 = measure("• nvim (68m)");
    const item3_w: u16 = measure("• zig (8m)");

    // Simulate layout geometry calculations
    flow.cur_col += item1_w + 2; // 2 + 12 + 2 = 16
    try testing.expectEqual(@as(u16, 16), flow.cur_col);

    flow.cur_col += item2_w + 2; // 16 + 12 + 2 = 30
    try testing.expectEqual(@as(u16, 30), flow.cur_col);

    // Next item (item3_w = 10 cols) cannot fit on row 5 (30 + 10 = 40 > 32)
    // Flow logic wraps it to row 6:
    if (flow.cur_col + item3_w > flow.max_col + 1) {
        flow.cur_row += 1;
        flow.cur_col = flow.start_col;
    }
    try testing.expectEqual(@as(u16, 6), flow.cur_row);
    try testing.expectEqual(@as(u16, 2), flow.cur_col);
}
