//! Zero-allocation cell-grid geometry and layout rectangle arithmetic.
//!
//! Provides coordinate manipulation, boundary clamping, inset calculations,
//! centering within viewports, and flex-style column splitting for terminal
//! and overlay GUI components.

const std = @import("std");

pub const Padding = struct {
    top: u16 = 0,
    right: u16 = 0,
    bottom: u16 = 0,
    left: u16 = 0,

    pub inline fn all(v: u16) Padding {
        return .{ .top = v, .right = v, .bottom = v, .left = v };
    }

    pub inline fn symmetric(h: u16, v: u16) Padding {
        return .{ .top = v, .right = h, .bottom = v, .left = h };
    }

    pub inline fn horizontal(h: u16) Padding {
        return .{ .right = h, .left = h };
    }

    pub inline fn vertical(v: u16) Padding {
        return .{ .top = v, .bottom = v };
    }

    pub inline fn horizTotal(self: Padding) u16 {
        return self.left + self.right;
    }

    pub inline fn vertTotal(self: Padding) u16 {
        return self.top + self.bottom;
    }
};

pub const Rect = struct {
    col: u16,
    row: u16,
    width: u16,
    height: u16,

    pub inline fn maxCol(self: Rect) u16 {
        return if (self.width > 0) self.col + self.width - 1 else self.col;
    }

    pub inline fn maxRow(self: Rect) u16 {
        return if (self.height > 0) self.row + self.height - 1 else self.row;
    }

    pub inline fn rightEdge(self: Rect) u16 {
        return self.col + self.width;
    }

    pub inline fn bottomEdge(self: Rect) u16 {
        return self.row + self.height;
    }

    pub fn inset(self: Rect, pad: Padding) Rect {
        const w = if (self.width > pad.horizTotal()) self.width - pad.horizTotal() else 0;
        const h = if (self.height > pad.vertTotal()) self.height - pad.vertTotal() else 0;
        return .{
            .col = self.col + pad.left,
            .row = self.row + pad.top,
            .width = w,
            .height = h,
        };
    }

    pub fn center(outer_cols: u16, outer_rows: u16, width: u16, height: u16) Rect {
        const w = @min(outer_cols, width);
        const h = @min(outer_rows, height);
        const c = if (outer_cols > w) (outer_cols - w) / 2 else 0;
        const r = if (outer_rows > h) (outer_rows - h) / 2 else 0;
        return .{ .col = c, .row = r, .width = w, .height = h };
    }

    pub fn contains(self: Rect, c: u16, r: u16) bool {
        return c >= self.col and c < self.col + self.width and
            r >= self.row and r < self.row + self.height;
    }

    pub fn splitTop(self: Rect, rows: u16) struct { top: Rect, remainder: Rect } {
        const h = @min(self.height, rows);
        return .{
            .top = .{ .col = self.col, .row = self.row, .width = self.width, .height = h },
            .remainder = .{ .col = self.col, .row = self.row + h, .width = self.width, .height = self.height - h },
        };
    }

    pub fn splitBottom(self: Rect, rows: u16) struct { remainder: Rect, bottom: Rect } {
        const h = @min(self.height, rows);
        const rem_h = self.height - h;
        return .{
            .remainder = .{ .col = self.col, .row = self.row, .width = self.width, .height = rem_h },
            .bottom = .{ .col = self.col, .row = self.row + rem_h, .width = self.width, .height = h },
        };
    }

    pub fn columns(self: Rect, total_columns: u16, gap: u16, index: u16) Rect {
        if (total_columns == 0 or index >= total_columns) {
            return .{ .col = self.col, .row = self.row, .width = 0, .height = self.height };
        }
        const total_gaps = (total_columns - 1) * gap;
        const avail_w = if (self.width > total_gaps) self.width - total_gaps else 0;
        const col_w = avail_w / total_columns;
        const extra = avail_w % total_columns;
        const c = self.col + index * (col_w + gap) + @min(index, extra);
        const w = col_w + if (index < extra) @as(u16, 1) else 0;
        return .{ .col = c, .row = self.row, .width = w, .height = self.height };
    }
};

test "Rect: geometry, padding, centering, and hit testing" {
    const testing = std.testing;

    const r = Rect{ .col = 10, .row = 5, .width = 40, .height = 20 };
    try testing.expectEqual(@as(u16, 49), r.maxCol());
    try testing.expectEqual(@as(u16, 24), r.maxRow());
    try testing.expectEqual(@as(u16, 50), r.rightEdge());
    try testing.expectEqual(@as(u16, 25), r.bottomEdge());

    const inner = r.inset(Padding.symmetric(3, 2));
    try testing.expectEqual(@as(u16, 13), inner.col);
    try testing.expectEqual(@as(u16, 7), inner.row);
    try testing.expectEqual(@as(u16, 34), inner.width);
    try testing.expectEqual(@as(u16, 16), inner.height);

    try testing.expect(r.contains(10, 5));
    try testing.expect(r.contains(49, 24));
    try testing.expect(!r.contains(50, 24));
    try testing.expect(!r.contains(9, 5));

    const centered = Rect.center(80, 24, 46, 12);
    try testing.expectEqual(@as(u16, 17), centered.col);
    try testing.expectEqual(@as(u16, 6), centered.row);
    try testing.expectEqual(@as(u16, 46), centered.width);
    try testing.expectEqual(@as(u16, 12), centered.height);

    const split = r.splitTop(4);
    try testing.expectEqual(@as(u16, 4), split.top.height);
    try testing.expectEqual(@as(u16, 16), split.remainder.height);
    try testing.expectEqual(@as(u16, 9), split.remainder.row);

    const col0 = r.columns(3, 2, 0);
    const col1 = r.columns(3, 2, 1);
    const col2 = r.columns(3, 2, 2);
    try testing.expectEqual(@as(u16, 12), col0.width);
    try testing.expectEqual(@as(u16, 12), col1.width);
    try testing.expectEqual(@as(u16, 12), col2.width);
    try testing.expectEqual(@as(u16, 10), col0.col);
    try testing.expectEqual(@as(u16, 24), col1.col);
    try testing.expectEqual(@as(u16, 38), col2.col);
}
