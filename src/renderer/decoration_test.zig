const std = @import("std");
const testing = std.testing;

const Decoration = @import("Decoration.zig");
const Rasterizer = @import("../freetype/root.zig").Rasterizer;

const font: Rasterizer.Metrics = .{
    .cell_width = 10,
    .cell_height = 20,
    .ascender = 15,
    .descender = 4,
    .underline_y = 17,
    .underline_thickness = 1,
    .strikethrough_y = 10,
    .strikethrough_thickness = 2,
};

test "Metrics.resolve: defaults keep the font's lines" {
    const m: Decoration.Metrics = .resolve(font, .{});
    try testing.expectEqual(17, m.underline_y);
    try testing.expectEqual(1, m.underline_thickness);
    try testing.expectEqual(15, m.double_y);
    try testing.expectEqual(10, m.strikethrough_y);
    try testing.expectEqual(2, m.strikethrough_thickness);
    try testing.expectEqual(0, m.overline_y);
    try testing.expectEqual(1, m.overline_thickness);
}

test "Metrics.resolve: overrides, offsets and scales apply in order" {
    const m: Decoration.Metrics = .resolve(font, .{
        .underline = .{ .offset = 1, .thickness_scale = 2 },
        .double_gap = 3,
        .strikethrough = .{ .y = 8, .thickness = 3 },
        .overline = .{ .offset = 2 },
    });
    try testing.expectEqual(18, m.underline_y);
    try testing.expectEqual(2, m.underline_thickness);
    try testing.expectEqual(13, m.double_y);
    try testing.expectEqual(8, m.strikethrough_y);
    try testing.expectEqual(3, m.strikethrough_thickness);
    try testing.expectEqual(2, m.overline_y);
    try testing.expectEqual(2, m.overline_thickness);
}

test "Metrics.resolve: lines pushed out of the cell are clamped back" {
    const m: Decoration.Metrics = .resolve(font, .{
        .underline = .{ .offset = 50, .thickness = 4 },
        .overline = .{ .offset = -5 },
        .double_gap = 100,
    });
    try testing.expectEqual(16, m.underline_y);
    try testing.expectEqual(4, m.underline_thickness);
    try testing.expectEqual(0, m.double_y);
    try testing.expectEqual(0, m.overline_y);
}
