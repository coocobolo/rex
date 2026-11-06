//! Immediate-mode KPI metric card primitive.
//!
//! Renders an elevated or subtly bordered card displaying a muted metric title,
//! prominent primary value, optional right-aligned badge, and optional bottom
//! sub-pixel progress bar.

const std = @import("std");
const Tokens = @import("../color/Tokens.zig").Tokens;
const Card = @import("../renderer/Card.zig");
const Rect = @import("Rect.zig").Rect;
const Padding = @import("Rect.zig").Padding;
const Border = @import("Border.zig");
const Box = @import("Box.zig");
const Label = @import("Label.zig");
const Badge = @import("Badge.zig");
const Text = @import("Text.zig");
const ProgressBar = @import("ProgressBar.zig");

pub const StatCard = @This();

pub const Request = struct {
    col: u16,
    row: u16,
    width: u16,
    height: u16 = 3,
    title: []const u8,
    value: []const u8,
    badge: []const u8 = "",
    value_color: ?[3]u8 = null,
    badge_color: ?[3]u8 = null,
    border_color: ?[3]u8 = null,
    progress: ?f32 = null,
    progress_mode: ProgressBar.ColorMode = .fixed,
    corner_radius: f32 = 6.0,
    border_width: f32 = 1.0,
};

pub fn render(
    req: Request,
    tokens: Tokens,
    card_buffer: *std.ArrayListUnmanaged(Card.Instance),
    drawer: Text.Drawer,
) void {
    if (req.width < 6 or req.height < 2) return;

    const inner = Box.render(
        .{
            .rect = .{ .col = req.col, .row = req.row, .width = req.width, .height = req.height },
            .option = .{
                .surface = .card,
                .border = .{
                    .shape = .rounded,
                    .radius = req.corner_radius,
                    .width = req.border_width,
                    .color = req.border_color,
                    .style = if (req.border_color != null) .custom else .subtle,
                },
                .padding = Padding.symmetric(2, 0),
            },
        },
        tokens,
        null,
        card_buffer,
        drawer.allocator,
        drawer,
        null,
    );

    if (inner.width == 0) return;
    const max_c = inner.maxCol();

    const title_row = req.row + (if (req.height >= 4) @as(u16, 1) else 0);
    _ = Label.renderAt(inner.col, title_row, max_c, req.title, .{ .role = .muted }, tokens, drawer);

    if (req.badge.len > 0) {
        const badge_w = Text.measure(req.badge);
        if (max_c > inner.col + badge_w + 2) {
            _ = Label.renderAt(
                inner.rightEdge() - badge_w,
                title_row,
                max_c,
                req.badge,
                .{ .role = .secondary, .color = req.badge_color },
                tokens,
                drawer,
            );
        }
    }

    const val_row = title_row + 1;
    if (val_row < req.row + req.height) {
        _ = Label.renderAt(
            inner.col,
            val_row,
            max_c,
            req.value,
            .{ .role = .primary, .color = req.value_color },
            tokens,
            drawer,
        );
    }

    if (req.progress) |prog| {
        const bar_row = if (req.height >= 3) req.row + req.height - 1 else val_row;
        const bar_w = inner.width;
        if (bar_w >= 4 and bar_row > val_row) {
            _ = ProgressBar.render(.{
                .col = inner.col,
                .row = bar_row,
                .width = bar_w,
                .progress = prog,
                .color_mode = req.progress_mode,
                .vertical_inset_px = 6.0,
            }, tokens, card_buffer, drawer.allocator, null);
        }
    }
}

test "StatCard: request defaults" {
    const testing = std.testing;
    const req: Request = .{
        .col = 2,
        .row = 4,
        .width = 20,
        .title = "Focus Today",
        .value = "2h 15m",
        .badge = "4 tasks",
    };
    try testing.expectEqual(@as(u16, 3), req.height);
    try testing.expectEqualStrings("Focus Today", req.title);
}
