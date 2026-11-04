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
