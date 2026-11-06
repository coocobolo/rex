//! Immediate-mode circular SDF arc and radial ring gauge primitive.
//!
//! Emits a `.ring` SDF card instance and centers optional headline, status badge,
//! and caption typography inside the circular aperture.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Tokens = @import("../color/Tokens.zig").Tokens;
const Card = @import("../renderer/Card.zig");
const Rect = @import("Rect.zig").Rect;
const Label = @import("Label.zig");
const Text = @import("Text.zig");

pub const RingGauge = @This();

pub const Request = struct {
    col: u16,
    row: u16,
    width: u16,
    height: u16,
    progress: f32,
    stroke_width_px: f32 = 6.0,
    fill_color: ?[3]u8 = null,
    track_color: ?[3]u8 = null,
    headline: []const u8 = "",
    headline_color: ?[3]u8 = null,
    badge: []const u8 = "",
    badge_color: ?[3]u8 = null,
    caption: []const u8 = "",
    caption_color: ?[3]u8 = null,
};

pub fn render(
    req: Request,
    tokens: Tokens,
    card_buffer: *std.ArrayListUnmanaged(Card.Instance),
    allocator: Allocator,
    drawer: ?Text.Drawer,
) void {
    if (req.width < 4 or req.height < 3) return;

    const clamped = std.math.clamp(req.progress, 0.0, 1.0);
    const fill = req.fill_color orelse tokens.accent;
    const track = req.track_color orelse tokens.border_subtle;

    card_buffer.append(allocator, .{
        .col = req.col,
        .row = req.row,
        .width = req.width,
        .height = req.height,
        .bg_color = Tokens.toF32Rgba(track, 255),
        .border_color = Tokens.toF32Rgba(fill, 255),
        .radius = 0.0,
        .border_width = req.stroke_width_px,
        .progress = clamped,
        .kind = .ring,
    }) catch {};

    if (drawer) |d| {
        const mid_row = req.row + req.height / 2;
        const has_badge = req.badge.len > 0;
        const has_caption = req.caption.len > 0;

        const headline_row = if (has_badge and req.height >= 5)
            mid_row - 1
        else
            mid_row;

        if (req.headline.len > 0) {
            _ = Label.render(
                .{ .col = req.col, .row = headline_row, .width = req.width, .height = 1 },
                req.headline,
                .{ .align_h = .center, .color = req.headline_color orelse tokens.primary },
                tokens,
                d,
            );
        }
        if (has_badge and headline_row + 1 < req.row + req.height - 1) {
            _ = Label.render(
                .{ .col = req.col, .row = headline_row + 1, .width = req.width, .height = 1 },
                req.badge,
                .{ .align_h = .center, .color = req.badge_color orelse fill },
                tokens,
                d,
            );
        }
        if (has_caption and headline_row + 2 < req.row + req.height - 1) {
            _ = Label.render(
                .{ .col = req.col, .row = headline_row + 2, .width = req.width, .height = 1 },
                req.caption,
                .{ .align_h = .center, .color = req.caption_color orelse tokens.muted },
                tokens,
                d,
            );
        }
    }
}

test "RingGauge: emits ring SDF instance with clamped sweep ratio" {
    const testing = std.testing;
    var cards: std.ArrayListUnmanaged(Card.Instance) = .empty;
    defer cards.deinit(testing.allocator);

    render(.{
        .col = 10,
        .row = 5,
        .width = 16,
        .height = 8,
        .progress = 0.75,
    }, Tokens.dark, &cards, testing.allocator, null);

    try testing.expectEqual(@as(usize, 1), cards.items.len);
    try testing.expectEqual(Card.Kind.ring, cards.items[0].kind);
    try testing.expectApproxEqAbs(@as(f32, 0.75), cards.items[0].progress, 0.001);
}
