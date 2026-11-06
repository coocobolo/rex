//! Immediate-mode sub-pixel horizontal progress bar and quota gauge primitive.
//!
//! Emits a 64-byte cache-line-aligned `.bar_h` SDF card instance with smooth
//! sub-pixel fill interpolation, semantic threshold coloring, and optional
//! inline percentage readouts.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Tokens = @import("../color/Tokens.zig").Tokens;
const Card = @import("../renderer/Card.zig");
const Text = @import("Text.zig");

pub const ProgressBar = @This();

pub const ColorMode = enum {
    fixed,
    semantic_quota,
    semantic_completion,
};

pub const Request = struct {
    col: u16,
    row: u16,
    width: u16,
    height: u16 = 1,
    progress: f32,
    color_mode: ColorMode = .fixed,
    fill_color: ?[3]u8 = null,
    track_color: ?[3]u8 = null,
    corner_radius: f32 = 4.0,
    vertical_inset_px: f32 = 5.0,
    show_percentage: bool = false,
};

pub fn resolveFillColor(req: Request, tokens: Tokens) [3]u8 {
    if (req.fill_color) |c| return c;
    const p = std.math.clamp(req.progress, 0.0, 1.0);
    return switch (req.color_mode) {
        .fixed => tokens.accent,
        .semantic_quota => if (p >= 1.0)
            tokens.critical
        else if (p >= 0.8)
            tokens.warning
        else
            tokens.healthy,
        .semantic_completion => if (p >= 1.0)
            tokens.healthy
        else if (p >= 0.5)
            tokens.accent
        else
            tokens.info,
    };
}

pub fn render(
    req: Request,
    tokens: Tokens,
    card_buffer: *std.ArrayListUnmanaged(Card.Instance),
    allocator: Allocator,
    drawer: ?Text.Drawer,
) u16 {
    if (req.width < 2 or req.height == 0) return 0;

    const clamped = std.math.clamp(req.progress, 0.0, 1.0);
    const pct_reserved: u16 = if (req.show_percentage and drawer != null and req.width > 7) 5 else 0;
    const bar_w: u16 = req.width - pct_reserved;

    const fill = resolveFillColor(req, tokens);
    const track = req.track_color orelse tokens.border_subtle;

    card_buffer.append(allocator, .{
        .col = req.col,
        .row = req.row,
        .width = bar_w,
        .height = req.height,
        .bg_color = Tokens.toF32Rgba(track, 255),
        .border_color = Tokens.toF32Rgba(fill, 255),
        .radius = req.corner_radius,
        .border_width = req.vertical_inset_px,
        .progress = clamped,
        .kind = .bar_h,
    }) catch {};

    if (pct_reserved > 0) {
        if (drawer) |d| {
            var pct_buf: [16]u8 = undefined;
            const pct_val: u32 = @intFromFloat(@round(clamped * 100.0));
            const pct_str = std.fmt.bufPrint(&pct_buf, " {d:>3}%", .{pct_val}) catch "";
            _ = d.drawString(req.col + bar_w, req.row, pct_str, tokens.secondary, 255, req.col + req.width);
        }
    }

    return req.width;
}

test "ProgressBar: semantic color resolution and sub-pixel instance emission" {
    const testing = std.testing;
    const tokens = Tokens.dark;

    const q_low = resolveFillColor(.{ .col = 0, .row = 0, .width = 10, .progress = 0.4, .color_mode = .semantic_quota }, tokens);
    const q_warn = resolveFillColor(.{ .col = 0, .row = 0, .width = 10, .progress = 0.85, .color_mode = .semantic_quota }, tokens);
    const q_crit = resolveFillColor(.{ .col = 0, .row = 0, .width = 10, .progress = 1.0, .color_mode = .semantic_quota }, tokens);

    try testing.expectEqual(tokens.healthy, q_low);
    try testing.expectEqual(tokens.warning, q_warn);
    try testing.expectEqual(tokens.critical, q_crit);

    var cards: std.ArrayListUnmanaged(Card.Instance) = .empty;
    defer cards.deinit(testing.allocator);

    const w = render(.{
        .col = 4,
        .row = 2,
        .width = 20,
        .progress = 0.625,
        .color_mode = .semantic_completion,
    }, tokens, &cards, testing.allocator, null);

    try testing.expectEqual(@as(u16, 20), w);
    try testing.expectEqual(@as(usize, 1), cards.items.len);
    try testing.expectEqual(Card.Kind.bar_h, cards.items[0].kind);
    try testing.expectEqual(@as(f32, 0.625), cards.items[0].progress);
}
