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

test "Metrics.resolve: default patterns fit whole periods into a cell" {
    const m: Decoration.Metrics = .resolve(font, .{});
    // 10 px cell, 1 px underline: 5 dots of 1 px on, 1 px off.
    try testing.expectEqual(1, m.dot_length);
    try testing.expectEqual(1, m.dot_gap);
    // One 5 px dash per cell.
    try testing.expectEqual(5, m.dash_length);
    try testing.expectEqual(5, m.dash_gap);
    // One wave per cell, 1.5 px crests around the underline centre.
    try testing.expectEqual(10, m.curly_wavelength);
    try testing.expectEqual(1.5, m.curly_amplitude);
    try testing.expectEqual(17.5, m.curly_y);
}

test "Metrics.resolve: pattern and wave overrides" {
    const m: Decoration.Metrics = .resolve(font, .{
        .dotted = .{ .length = 2 },
        .dashed = .{ .length = 4, .gap = 1 },
        .curly = .{ .amplitude = 3, .wavelength = 7 },
    });
    try testing.expectEqual(2, m.dot_length);
    try testing.expectEqual(2, m.dot_gap);
    try testing.expectEqual(4, m.dash_length);
    try testing.expectEqual(1, m.dash_gap);
    try testing.expectEqual(3, m.curly_amplitude);
    try testing.expectEqual(7, m.curly_wavelength);
    // Troughs reach 17.5 + 3 + 0.5 = 21 > 20: the centre moves up.
    try testing.expectEqual(16.5, m.curly_y);
}

test "Metrics.resolve: the curly wave never leaves the cell" {
    const m: Decoration.Metrics = .resolve(font, .{ .curly = .{ .amplitude = 100 } });
    try testing.expectEqual(9.5, m.curly_amplitude);
    try testing.expectEqual(10, m.curly_y);
}

test "SkipInk.styleBits: one bit per UnderlineStyle value, none when off" {
    try testing.expectEqual(0b111110, (Decoration.SkipInk{}).styleBits());
    try testing.expectEqual(0, (Decoration.SkipInk{ .enabled = false }).styleBits());
    const only_curly: Decoration.SkipInk = .{ .styles = .{
        .single = false,
        .double = false,
        .dotted = false,
        .dashed = false,
    } };
    try testing.expectEqual(0b1000, only_curly.styleBits());
}

test "Metrics.resolve: ink gap and minimum segment follow the underline" {
    const thick_font = blk: {
        var f = font;
        f.underline_thickness = 2;
        break :blk f;
    };
    const m: Decoration.Metrics = .resolve(thick_font, .{});
    try testing.expectEqual(2, m.ink_gap);
    try testing.expectEqual(4, m.ink_min_segment);

    const custom: Decoration.Metrics = .resolve(font, .{ .skip_ink = .{ .gap = 2.6, .min_segment = 0, .threshold = 0.5 } });
    try testing.expectEqual(3, custom.ink_gap);
    try testing.expectEqual(0, custom.ink_min_segment);

    const huge: Decoration.Metrics = .resolve(font, .{ .skip_ink = .{ .gap = 1000, .min_segment = 1000 } });
    try testing.expectEqual(Decoration.Metrics.max_ink_scan / 2, huge.ink_gap);
    try testing.expectEqual(Decoration.Metrics.max_ink_scan / 2, huge.ink_min_segment);
}

test "anyUnderline: only underlined runs need the ink mask" {
    const plain: Decoration.Instance = .{
        .col = 0,
        .row = 0,
        .span = 1,
        .underline = .{ 0, 0, 0, 255 },
        .strikethrough = .{ 0, 0, 0, 255 },
        .overline = .{ 0, 0, 0, 255 },
        .flags = .{ .strikethrough = true },
    };
    var underlined = plain;
    underlined.flags.underline = .dotted;
    try testing.expect(!Decoration.anyUnderline(&.{plain}));
    try testing.expect(Decoration.anyUnderline(&.{ plain, underlined }));
}
