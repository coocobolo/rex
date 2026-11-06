//! Atomic tag, pill, and status badge primitive.
//!
//! Renders compact highlighted text tags with optional leading icon glyphs,
//! customizable surface background fills, and anti-aliased pill or rounded borders.

const std = @import("std");
const Tokens = @import("../color/Tokens.zig").Tokens;
const Card = @import("../renderer/Card.zig");
const Rect = @import("Rect.zig").Rect;
const Padding = @import("Rect.zig").Padding;
const Border = @import("Border.zig");
const Box = @import("Box.zig");
const Text = @import("Text.zig");
const Label = @import("Label.zig");

pub const Badge = @This();

pub const Option = struct {
    role: Label.Role = .accent,
    surface: Box.Surface = .none,
    border: Border.Option = .{ .radius = 4.0, .width = 1.0, .style = .none },
    padding_h: u16 = 1,
};

pub fn render(
    col: u16,
    row: u16,
    max_col: u16,
    icon: ?[]const u8,
    text: []const u8,
    opt: Option,
    tokens: Tokens,
    card_buffer: ?*std.ArrayListUnmanaged(Card.Instance),
    drawer: Text.Drawer,
) u16 {
    if (col > max_col or (text.len == 0 and (icon == null or icon.?.len == 0))) return 0;

    const icon_str = icon orelse "";
    const icon_w = if (icon_str.len > 0) Text.measure(icon_str) + 1 else 0;
    const text_w = Text.measure(text);
    const content_w = icon_w + text_w;
    const total_w = content_w + opt.padding_h * 2;

    const avail_w = max_col - col + 1;
    const render_w = @min(total_w, avail_w);
    if (render_w == 0) return 0;

    const color = Label.resolveColor(.{ .role = opt.role }, tokens);

    if (card_buffer) |cb| {
        if (opt.surface != .none or opt.border.style != .none) {
            _ = Box.render(
                .{
                    .rect = .{ .col = col, .row = row, .width = render_w, .height = 1 },
                    .option = .{
                        .surface = opt.surface,
                        .border = opt.border,
                        .padding = Padding.horizontal(opt.padding_h),
                    },
                    .semantic_accent = color,
                },
                tokens,
                null,
                cb,
                drawer.allocator,
                null,
                null,
            );
        }
    }

    var c = col + opt.padding_h;
    if (icon_str.len > 0 and c <= max_col) {
        c += drawer.drawString(c, row, icon_str, color, 255, max_col);
        if (c <= max_col) {
            _ = drawer.drawChar(c, row, ' ', color, 255);
            c += 1;
        }
    }

    if (text.len > 0 and c <= max_col) {
        c += drawer.drawString(c, row, text, color, 255, max_col);
    }

    return @min(c - col + opt.padding_h, avail_w);
}

test "Badge: option defaults" {
    const testing = std.testing;
    const opt: Option = .{};

    try testing.expectEqual(Label.Role.accent, opt.role);
    try testing.expectEqual(Box.Surface.none, opt.surface);
    try testing.expectEqual(Border.Style.none, opt.border.style);
    try testing.expectEqual(@as(u16, 1), opt.padding_h);
}
