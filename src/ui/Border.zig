//! Border geometry, styling, color resolution, and rendering primitive.
//!
//! Provides a unified abstraction for UI borders supporting both GPU-instanced
//! Signed Distance Field (SDF) rounded strokes and cell-grid Unicode or ASCII
//! box-drawing character borders.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Tokens = @import("../color/Tokens.zig").Tokens;
const Card = @import("../renderer/Card.zig");
const Rect = @import("Rect.zig").Rect;
const Text = @import("Text.zig");
const Icon = @import("Icon.zig");

pub const Border = @This();

pub const Shape = enum {
    rounded,
    sharp,
    pill,
};

pub const Style = enum {
    none,
    subtle,
    normal,
    semantic,
    focus,
    custom,
};

pub const Mode = enum {
    sdf,
    glyph,
};

pub const Option = struct {
    shape: Shape = .rounded,
    style: Style = .semantic,
    mode: Mode = .sdf,
    radius: f32 = 8.0,
    width: f32 = 1.0,
    focus_width: f32 = 1.5,
    color: ?[3]u8 = null,
    alpha: u8 = 255,
    glyph_style: Icon.IconStyle = .unicode,

    pub inline fn effectiveRadius(self: Option) f32 {
        return switch (self.shape) {
            .rounded => self.radius,
            .sharp => 0.0,
            .pill => 999.0,
        };
    }

    pub inline fn effectiveWidth(self: Option, focused: bool) f32 {
        if (self.style == .none) return 0.0;
        return if (focused) self.focus_width else self.width;
    }

    pub fn resolveColor(self: Option, tokens: Tokens, semantic_accent: ?[3]u8, focused: bool) [3]u8 {
        if (self.color) |c| return c;
        if (focused) return tokens.accent;
        return switch (self.style) {
            .none => tokens.border,
            .subtle => tokens.border_subtle,
            .normal => tokens.border,
            .semantic => semantic_accent orelse tokens.accent,
            .focus => tokens.accent,
            .custom => tokens.border,
        };
    }

    pub fn render(
        self: Option,
        rect: Rect,
        tokens: Tokens,
        semantic_accent: ?[3]u8,
        focused: bool,
        card_buffer: *std.ArrayListUnmanaged(Card.Instance),
        allocator: Allocator,
        drawer: ?Text.Drawer,
    ) void {
        if (self.style == .none or rect.width == 0 or rect.height == 0) return;
        const color = self.resolveColor(tokens, semantic_accent, focused);

        switch (self.mode) {
            .sdf => {
                const w = self.effectiveWidth(focused);
                if (w <= 0.0) return;
                card_buffer.append(allocator, .{
                    .col = rect.col,
                    .row = rect.row,
                    .width = rect.width,
                    .height = rect.height,
                    .bg_color = .{ 0.0, 0.0, 0.0, 0.0 },
                    .border_color = Tokens.toF32Rgba(color, self.alpha),
                    .radius = self.effectiveRadius(),
                    .border_width = w,
                    .progress = 1.0,
                    .kind = .box,
                }) catch {};
            },
            .glyph => {
                if (drawer == null or rect.width < 2 or rect.height < 2) return;
                const d = drawer.?;
                const max_c = rect.rightEdge();

                const is_ascii = self.glyph_style == .ascii;
                const tl: u21 = if (is_ascii) '+' else if (self.shape == .sharp) 0x250C else 0x256D;
                const tr: u21 = if (is_ascii) '+' else if (self.shape == .sharp) 0x2510 else 0x256E;
                const bl: u21 = if (is_ascii) '+' else if (self.shape == .sharp) 0x2514 else 0x2570;
                const br: u21 = if (is_ascii) '+' else if (self.shape == .sharp) 0x2518 else 0x256F;
                const horiz: u21 = if (is_ascii) '-' else 0x2500;
                const vert: u21 = if (is_ascii) '|' else 0x2502;

                _ = d.drawChar(rect.col, rect.row, tl, color, self.alpha);
                var c = rect.col + 1;
                while (c < max_c - 1) : (c += 1) {
                    _ = d.drawChar(c, rect.row, horiz, color, self.alpha);
                }
                _ = d.drawChar(max_c - 1, rect.row, tr, color, self.alpha);

                var r = rect.row + 1;
                while (r < rect.row + rect.height - 1) : (r += 1) {
                    _ = d.drawChar(rect.col, r, vert, color, self.alpha);
                    _ = d.drawChar(max_c - 1, r, vert, color, self.alpha);
                }

                _ = d.drawChar(rect.col, rect.row + rect.height - 1, bl, color, self.alpha);
                c = rect.col + 1;
                while (c < max_c - 1) : (c += 1) {
                    _ = d.drawChar(c, rect.row + rect.height - 1, horiz, color, self.alpha);
                }
                _ = d.drawChar(max_c - 1, rect.row + rect.height - 1, br, color, self.alpha);
            },
        }
    }
};

test "Border: option radius, width, and semantic color resolution" {
    const testing = std.testing;
    const tokens = Tokens.dark;

    const opt_round = Option{ .shape = .rounded, .radius = 6.0 };
    const opt_sharp = Option{ .shape = .sharp, .radius = 6.0 };
    const opt_pill = Option{ .shape = .pill };

    try testing.expectEqual(@as(f32, 6.0), opt_round.effectiveRadius());
    try testing.expectEqual(@as(f32, 0.0), opt_sharp.effectiveRadius());
    try testing.expectEqual(@as(f32, 999.0), opt_pill.effectiveRadius());

    const opt_semantic = Option{ .style = .semantic };
    try testing.expectEqual(tokens.healthy, opt_semantic.resolveColor(tokens, tokens.healthy, false));
    try testing.expectEqual(tokens.accent, opt_semantic.resolveColor(tokens, null, false));
    try testing.expectEqual(tokens.accent, opt_semantic.resolveColor(tokens, tokens.healthy, true));

    const opt_subtle = Option{ .style = .subtle };
    try testing.expectEqual(tokens.border_subtle, opt_subtle.resolveColor(tokens, null, false));
}
