//! Immediate-mode discrete step and cycle pip indicator primitive.
//!
//! Renders a horizontal sequence of analytic SDF circular pips representing
//! completed, active, and upcoming steps in a multi-stage workflow.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Tokens = @import("../color/Tokens.zig").Tokens;
const Card = @import("../renderer/Card.zig");

pub const StepIndicator = @This();

pub const Request = struct {
    col: u16,
    row: u16,
    max_col: u16,
    total_steps: u8,
    completed_steps: u8,
    active_step: ?u8 = null,
    pip_width: u16 = 2,
    spacing: u16 = 1,
    completed_color: ?[3]u8 = null,
    active_color: ?[3]u8 = null,
    upcoming_color: ?[3]u8 = null,
};

pub fn measureWidth(total_steps: u8, pip_width: u16, spacing: u16) u16 {
    if (total_steps == 0) return 0;
    const n: u16 = total_steps;
    return n * pip_width + (n - 1) * spacing;
}

pub fn render(
    req: Request,
    tokens: Tokens,
    card_buffer: *std.ArrayListUnmanaged(Card.Instance),
    allocator: Allocator,
) u16 {
    if (req.total_steps == 0 or req.pip_width == 0) return 0;

    const done_col = req.completed_color orelse tokens.healthy;
    const act_col = req.active_color orelse tokens.accent;
    const next_col = req.upcoming_color orelse tokens.border;

    var cur_c = req.col;
    var i: u8 = 0;
    while (i < req.total_steps) : (i += 1) {
        if (cur_c + req.pip_width > req.max_col + 1) break;

        const is_done = i < req.completed_steps;
        const is_active = if (req.active_step) |act| act == i else false;

        const stroke_col = if (is_active) act_col else if (is_done) done_col else next_col;
        const inner_col = if (is_active) act_col else if (is_done) done_col else tokens.card_opaque;
        const fill_scale: f32 = if (is_done) 1.0 else if (is_active) 0.55 else 0.0;
        const ring_w: f32 = if (is_active) 2.0 else 1.5;

        card_buffer.append(allocator, .{
            .col = cur_c,
            .row = req.row,
            .width = req.pip_width,
            .height = 1,
            .bg_color = Tokens.toF32Rgba(inner_col, 255),
            .border_color = Tokens.toF32Rgba(stroke_col, 255),
            .radius = 0.0,
            .border_width = ring_w,
            .progress = fill_scale,
            .kind = .pip,
        }) catch {};

        cur_c += req.pip_width;
        if (i + 1 < req.total_steps) cur_c += req.spacing;
    }

    return cur_c - req.col;
}

test "StepIndicator: renders completed, active, and upcoming pips" {
    const testing = std.testing;
    var cards: std.ArrayListUnmanaged(Card.Instance) = .empty;
    defer cards.deinit(testing.allocator);

    try testing.expectEqual(@as(u16, 11), measureWidth(4, 2, 1));

    const w = render(.{
        .col = 5,
        .row = 3,
        .max_col = 40,
        .total_steps = 4,
        .completed_steps = 2,
        .active_step = 2,
        .pip_width = 2,
        .spacing = 1,
    }, Tokens.dark, &cards, testing.allocator);

    try testing.expectEqual(@as(u16, 11), w);
    try testing.expectEqual(@as(usize, 4), cards.items.len);
    try testing.expectEqual(Card.Kind.pip, cards.items[0].kind);
    try testing.expectEqual(@as(f32, 1.0), cards.items[0].progress);
    try testing.expectEqual(@as(f32, 1.0), cards.items[1].progress);
    try testing.expectEqual(@as(f32, 0.55), cards.items[2].progress);
    try testing.expectEqual(@as(f32, 0.0), cards.items[3].progress);
}
