const std = @import("std");
const testing = std.testing;

const alloc = testing.allocator;

const Rasterizer = @import("Rasterizer.zig");
const Config = @import("Config.zig");

const test_font: Config = .{
    .max_size = 72,
    .min_size = 8,
    .font = .{
        .family = .{
            .static = .{
                .regular = "testdata/font/NotoSansMono-Regular.ttf",
                .bold = "testdata/font/NotoSansMono-Bold.ttf",
                .italic = "testdata/font/NotoSans-Italic.ttf",
                .bold_italic = "testdata/font/NotoSans-BoldItalic.ttf",
            },
        },
        .emoji = .static("testdata/font/NotoColorEmoji.ttf"),
    },
    .height = 16,
};

test "rasterizer: cell metrics are set after create" {
    var r = try Rasterizer.create(alloc, test_font);
    defer r.destroy(alloc);

    try testing.expect(r.cell_width > 0);
    try testing.expect(r.cell_height > 0);
    try testing.expect(r.ascender > 0);
}

test "rasterizer: visible glyph has non-zero bitmap" {
    var r = try Rasterizer.create(alloc, test_font);
    defer r.destroy(alloc);

    const g = try r.rasterize(alloc, 'A', .regular, .single);

    try testing.expect(g.width > 0);
    try testing.expect(g.height > 0);
    try testing.expect(g.advance > 0);
    try testing.expectEqual(.gray, g.kind);
}

test "rasterizer: space returns zero-size bitmap with non-zero advance" {
    var r = try Rasterizer.create(alloc, test_font);
    defer r.destroy(alloc);

    const g = try r.rasterize(alloc, 0x20, .regular, .single);
    try testing.expectEqual(0, g.width);
    try testing.expectEqual(0, g.height);
    try testing.expect(g.advance > 0);
}

test "rasterizer: bold and regular produce different bitmaps" {
    var r = try Rasterizer.create(alloc, test_font);
    defer r.destroy(alloc);

    const regular = try r.rasterize(alloc, 'A', .regular, .single);
    const bold = try r.rasterize(alloc, 'A', .bold, .single);
    // same codepoint, different face,  different bitmap dimensions or data
    // at minimum, bold should be at least as wide
    try testing.expect(bold.width >= regular.width);
}

test "rasterizer: color glyph is scaled to its span" {
    var r = try Rasterizer.create(alloc, test_font);
    defer r.destroy(alloc);

    const single = try r.rasterize(alloc, 0x1F600, .emoji, .single);
    try testing.expectEqual(.color, single.kind);
    try testing.expect(single.width <= r.cell_width);

    const double = try r.rasterize(alloc, 0x1F600, .emoji, .double);
    try testing.expectEqual(.color, double.kind);
    try testing.expect(double.width <= r.cell_width * 2);
    try testing.expect(double.width >= single.width);
}

test "rowPitch: keeps a top-down pitch and rejects a bottom-up one" {
    try testing.expectEqual(24, try Rasterizer.rowPitch(24));
    try testing.expectEqual(0, try Rasterizer.rowPitch(0));
    try testing.expectError(error.BottomUpBitmap, Rasterizer.rowPitch(-24));
    try testing.expectError(error.GlyphTooLarge, Rasterizer.rowPitch(70000));
}

test "Line.fit: rounds to whole pixels and keeps the line inside the cell" {
    const Line = Rasterizer.Line;
    try testing.expectEqual(Line{ .y = 13, .thickness = 1 }, Line.fit(12.6, 0.8, 16));
    try testing.expectEqual(Line{ .y = 14, .thickness = 2 }, Line.fit(15.2, 1.6, 16));
    try testing.expectEqual(Line{ .y = 0, .thickness = 1 }, Line.fit(-3.0, 0.2, 16));
    try testing.expectEqual(Line{ .y = 0, .thickness = 4 }, Line.fit(2.0, 9.0, 4));
}

test "rasterizer: line metrics come from the font and fit the cell" {
    var r = try Rasterizer.create(alloc, test_font);
    defer r.destroy(alloc);

    const m = r.metrics;
    const height: f32 = @floatFromInt(m.cell_height);
    const ascender: f32 = @floatFromInt(m.ascender);
    for ([_][2]f32{
        .{ m.underline_y, m.underline_thickness },
        .{ m.strikethrough_y, m.strikethrough_thickness },
    }) |line| {
        try testing.expectEqual(@round(line[0]), line[0]);
        try testing.expectEqual(@round(line[1]), line[1]);
        try testing.expect(line[0] >= 0);
        try testing.expect(line[1] >= 1);
        try testing.expect(line[0] + line[1] <= height);
    }
    // The underline sits below the baseline, the strikethrough above it.
    try testing.expect(m.underline_y >= ascender);
    try testing.expect(m.strikethrough_y < ascender);
}

test "rasterizer: underline thickness scales with the font size" {
    var big_font = test_font;
    big_font.height = 64;
    var r = try Rasterizer.create(alloc, big_font);
    defer r.destroy(alloc);
    // NotoSansMono has a 50 unit underline on a 1000 unit em, about
    // 3 px at 64 px; the old sign bug always fell back to 1 px.
    try testing.expect(r.metrics.underline_thickness > 1);
}
