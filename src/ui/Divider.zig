//! Atomic visual divider and separator rule primitive.
//!
//! Renders horizontal or vertical boundary rules using either cell-grid box-drawing
//! characters or GPU-instanced Signed Distance Field hairlines, with optional centered
//! section titles.

const std = @import("std");
const Tokens = @import("../color/Tokens.zig").Tokens;
const Card = @import("../renderer/Card.zig");
const Text = @import("Text.zig");
const Icon = @import("Icon.zig");
const Label = @import("Label.zig");

pub const Divider = @This();

pub const Mode = enum {
    glyph,
    sdf,
};

pub const Option = struct {
    mode: Mode = .glyph,
    inset_cols: u16 = 2,
    role: Label.Role = .muted,
    color: ?[3]u8 = null,
    alpha: u8 = 255,
    glyph_style: Icon.IconStyle = .unicode,
    thickness_px: f32 = 1.0,
};

pub fn renderHorizontal(
    col: u16,
    row: u16,
    width: u16,
    title: ?[]const u8,
    opt: Option,
    tokens: Tokens,
    card_buffer: ?*std.ArrayListUnmanaged(Card.Instance),
    drawer: Text.Drawer,
) void {
    if (width <= opt.inset_cols * 2) return;
    const start_c = col + opt.inset_cols;
    const end_c = col + width - opt.inset_cols;
    const color = if (opt.color) |c| c else Label.resolveColor(.{ .role = opt.role }, tokens);

    switch (opt.mode) {
        .sdf => {
            if (card_buffer) |cb| {
                if (title) |t| {
                    const t_w = Text.measure(t);
                    if (end_c > start_c + t_w + 4) {
                        const mid_c = start_c + (end_c - start_c - t_w) / 2;
                        if (mid_c > start_c + 1) {
                            cb.append(drawer.allocator, .{
                                .col = start_c,
                                .row = row,
                                .width = mid_c - start_c - 1,
                                .height = 1,
                                .bg_color = .{ 0, 0, 0, 0 },
                                .border_color = Tokens.toF32Rgba(color, opt.alpha),
                                .radius = 0.0,
                                .border_width = opt.thickness_px,
                                .kind = .box,
                            }) catch {};
                        }
                        _ = drawer.drawString(mid_c, row, t, color, opt.alpha, end_c);
                        const after_c = mid_c + t_w + 1;
                        if (end_c > after_c) {
                            cb.append(drawer.allocator, .{
                                .col = after_c,
                                .row = row,
                                .width = end_c - after_c,
                                .height = 1,
                                .bg_color = .{ 0, 0, 0, 0 },
                                .border_color = Tokens.toF32Rgba(color, opt.alpha),
                                .radius = 0.0,
                                .border_width = opt.thickness_px,
                                .kind = .box,
                            }) catch {};
                        }
                        return;
                    }
                }

                cb.append(drawer.allocator, .{
                    .col = start_c,
                    .row = row,
                    .width = end_c - start_c,
                    .height = 1,
                    .bg_color = .{ 0, 0, 0, 0 },
                    .border_color = Tokens.toF32Rgba(color, opt.alpha),
                    .radius = 0.0,
                    .border_width = opt.thickness_px,
                    .kind = .box,
                }) catch {};
            }
        },
        .glyph => {
            const horiz: u21 = if (opt.glyph_style == .ascii) '-' else 0x2500;
            if (title) |t| {
                const t_w = Text.measure(t);
                if (end_c > start_c + t_w + 4) {
                    const mid_c = start_c + (end_c - start_c - t_w) / 2;
                    var c = start_c;
                    while (c < mid_c - 1) : (c += 1) {
                        _ = drawer.drawChar(c, row, horiz, color, opt.alpha);
                    }
                    _ = drawer.drawString(mid_c, row, t, color, opt.alpha, end_c);
                    c = mid_c + t_w + 1;
                    while (c < end_c) : (c += 1) {
                        _ = drawer.drawChar(c, row, horiz, color, opt.alpha);
                    }
                    return;
                }
            }

            var c = start_c;
            while (c < end_c) : (c += 1) {
                _ = drawer.drawChar(c, row, horiz, color, opt.alpha);
            }
        },
    }
}

test "Divider: option defaults" {
    const testing = std.testing;
    const opt: Option = .{};

    try testing.expectEqual(Mode.glyph, opt.mode);
    try testing.expectEqual(@as(u16, 2), opt.inset_cols);
    try testing.expectEqual(Label.Role.muted, opt.role);
}
