//! Atomic container, surface, and backdrop dimming primitive.
//!
//! Renders elevated or subtle background fills, anti-aliased border strokes,
//! outside backdrop dimming, and hotspot registration for rectangular regions,
//! returning the padded inner content rectangle for nested child layout.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Tokens = @import("../color/Tokens.zig").Tokens;
const Card = @import("../renderer/Card.zig");
const Background = @import("../renderer/Background.zig");
const RectMod = @import("Rect.zig");
const Rect = RectMod.Rect;
const Padding = RectMod.Padding;
const Border = @import("Border.zig");
const Text = @import("Text.zig");
const hotspot_mod = @import("hotspot.zig");
const Table = hotspot_mod.Table;
const Action = hotspot_mod.Action;

pub const Box = @This();

pub const Surface = enum {
    none,
    card,
    elevated,
    subtle,
    dimmed,
    custom,
};

pub const Option = struct {
    surface: Surface = .card,
    bg_color: ?[3]u8 = null,
    bg_alpha: u8 = 255,
    border: Border.Option = .{},
    padding: Padding = Padding.symmetric(2, 1),
    backdrop_dim_alpha: u8 = 0,
};

pub const Request = struct {
    rect: Rect,
    option: Option = .{},
    semantic_accent: ?[3]u8 = null,
    focused: bool = false,
    viewport_cols: u16 = 0,
    viewport_rows: u16 = 0,
    action: ?Action = null,
};

pub fn resolveSurfaceColor(opt: Option, tokens: Tokens) [4]u8 {
    if (opt.bg_color) |c| {
        return .{ c[0], c[1], c[2], opt.bg_alpha };
    }
    return switch (opt.surface) {
        .none => .{ 0, 0, 0, 0 },
        .card => .{ tokens.card_opaque[0], tokens.card_opaque[1], tokens.card_opaque[2], opt.bg_alpha },
        .elevated => .{ tokens.card_opaque[0], tokens.card_opaque[1], tokens.card_opaque[2], opt.bg_alpha },
        .subtle => .{ tokens.border_subtle[0], tokens.border_subtle[1], tokens.border_subtle[2], opt.bg_alpha },
        .dimmed => .{ tokens.bg[0], tokens.bg[1], tokens.bg[2], opt.bg_alpha },
        .custom => .{ tokens.card_opaque[0], tokens.card_opaque[1], tokens.card_opaque[2], opt.bg_alpha },
    };
}

pub fn fillCells(
    allocator: Allocator,
    bg_buffer: *std.ArrayListUnmanaged(Background.Instance),
    rect: Rect,
    color: [4]u8,
) void {
    if (color[3] == 0 or rect.width == 0 or rect.height == 0) return;
    for (0..rect.height) |i| {
        bg_buffer.append(allocator, .{
            .col = rect.col,
            .row = @intCast(rect.row + i),
            .span = rect.width,
            .r = color[0],
            .g = color[1],
            .b = color[2],
            .a = color[3],
        }) catch {};
    }
}

pub fn dimOutside(
    allocator: Allocator,
    bg_buffer: *std.ArrayListUnmanaged(Background.Instance),
    viewport_cols: u16,
    viewport_rows: u16,
    rect: Rect,
    dim_color: [4]u8,
) void {
    if (dim_color[3] == 0 or viewport_cols == 0 or viewport_rows == 0) return;

    if (rect.row > 0) {
        fillCells(allocator, bg_buffer, .{ .col = 0, .row = 0, .width = viewport_cols, .height = rect.row }, dim_color);
    }
    const mid_start = rect.row;
    const mid_end = @min(viewport_rows, rect.bottomEdge());
    if (mid_end > mid_start) {
        const mid_h = mid_end - mid_start;
        if (rect.col > 0) {
            fillCells(allocator, bg_buffer, .{ .col = 0, .row = mid_start, .width = rect.col, .height = mid_h }, dim_color);
        }
        const right_start = rect.rightEdge();
        if (viewport_cols > right_start) {
            fillCells(allocator, bg_buffer, .{ .col = right_start, .row = mid_start, .width = viewport_cols - right_start, .height = mid_h }, dim_color);
        }
    }
    if (viewport_rows > rect.bottomEdge()) {
        fillCells(allocator, bg_buffer, .{ .col = 0, .row = rect.bottomEdge(), .width = viewport_cols, .height = viewport_rows - rect.bottomEdge() }, dim_color);
    }
}

pub fn render(
    req: Request,
    tokens: Tokens,
    bg_buffer: ?*std.ArrayListUnmanaged(Background.Instance),
    card_buffer: *std.ArrayListUnmanaged(Card.Instance),
    allocator: Allocator,
    drawer: ?Text.Drawer,
    hotspots: ?*Table,
) Rect {
    if (req.rect.width == 0 or req.rect.height == 0) return req.rect;

    if (req.option.backdrop_dim_alpha > 0 and bg_buffer != null and req.viewport_cols > 0 and req.viewport_rows > 0) {
        dimOutside(
            allocator,
            bg_buffer.?,
            req.viewport_cols,
            req.viewport_rows,
            req.rect,
            .{ tokens.bg[0], tokens.bg[1], tokens.bg[2], req.option.backdrop_dim_alpha },
        );
    }

    const surface_color = resolveSurfaceColor(req.option, tokens);
    const border_color = req.option.border.resolveColor(tokens, req.semantic_accent, req.focused);

    switch (req.option.border.mode) {
        .sdf => {
            const bg_rgba = [4]f32{
                @as(f32, @floatFromInt(surface_color[0])) / 255.0,
                @as(f32, @floatFromInt(surface_color[1])) / 255.0,
                @as(f32, @floatFromInt(surface_color[2])) / 255.0,
                @as(f32, @floatFromInt(surface_color[3])) / 255.0,
            };
            const border_rgba = Tokens.toF32Rgba(border_color, req.option.border.alpha);
            const border_w = req.option.border.effectiveWidth(req.focused);

            card_buffer.append(allocator, .{
                .col = req.rect.col,
                .row = req.rect.row,
                .width = req.rect.width,
                .height = req.rect.height,
                .bg_color = bg_rgba,
                .border_color = border_rgba,
                .radius = req.option.border.effectiveRadius(),
                .border_width = border_w,
                .progress = 1.0,
                .kind = .box,
            }) catch {};
        },
        .glyph => {
            if (bg_buffer) |bg| {
                if (req.option.surface != .none) {
                    fillCells(allocator, bg, req.rect, surface_color);
                }
            }
            req.option.border.render(req.rect, tokens, req.semantic_accent, req.focused, card_buffer, allocator, drawer);
        },
    }

    if (req.action) |act| {
        if (hotspots) |ht| {
            ht.add(req.rect.col, req.rect.row, req.rect.width, req.rect.height, act);
        }
    }

    return req.rect.inset(req.option.padding);
}

test "Box: render emits card instance and returns padded content rect" {
    const testing = std.testing;
    const tokens = Tokens.dark;

    var cards: std.ArrayListUnmanaged(Card.Instance) = .empty;
    defer cards.deinit(testing.allocator);

    const outer = Rect{ .col = 5, .row = 10, .width = 40, .height = 15 };
    const inner = render(.{
        .rect = outer,
        .option = .{
            .padding = Padding.symmetric(3, 2),
            .border = .{ .radius = 8.0, .width = 1.5 },
        },
    }, tokens, null, &cards, testing.allocator, null, null);

    try testing.expectEqual(@as(usize, 1), cards.items.len);
    try testing.expectEqual(Card.Kind.box, cards.items[0].kind);
    try testing.expectEqual(@as(u16, 5), cards.items[0].col);
    try testing.expectEqual(@as(u16, 10), cards.items[0].row);
    try testing.expectEqual(@as(f32, 8.0), cards.items[0].radius);
    try testing.expectEqual(@as(f32, 1.5), cards.items[0].border_width);

    try testing.expectEqual(@as(u16, 8), inner.col);
    try testing.expectEqual(@as(u16, 12), inner.row);
    try testing.expectEqual(@as(u16, 34), inner.width);
    try testing.expectEqual(@as(u16, 11), inner.height);
}

test "Box: backdrop dimming leaves target panel region untouched" {
    const testing = std.testing;
    var bgs: std.ArrayListUnmanaged(Background.Instance) = .empty;
    defer bgs.deinit(testing.allocator);

    const target = Rect{ .col = 20, .row = 6, .width = 40, .height = 12 };
    dimOutside(testing.allocator, &bgs, 80, 24, target, .{ 10, 10, 10, 180 });

    for (bgs.items) |bg| {
        if (bg.row >= target.row and bg.row < target.bottomEdge()) {
            const q_start = bg.col;
            const q_end = bg.col + bg.span;
            const overlaps = (q_start < target.rightEdge() and q_end > target.col);
            try testing.expect(!overlaps);
        }
    }
}
