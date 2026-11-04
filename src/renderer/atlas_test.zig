const std = @import("std");
const testing = std.testing;
const alloc = std.testing.allocator;

const Atlas = @import("Atlas.zig");
const window = @import("Window.zig");
const ft = @import("../freetype/root.zig");

const FontConfig = ft.FontConfig;
const Rasterizer = ft.Rasterizer;

const c = window.c;
const testGlContext = window.testGlContext;

var gl_win: ?*c.GLFWwindow = null;
fn getOrCreatedGLContext() !*c.GLFWwindow {
    if (gl_win) |win| return win;
    gl_win = try testGlContext();
    return gl_win.?;
}

const test_font: FontConfig = .{
    .max_size = 64,
    .min_size = 0,
    .width = 0,
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

/// Returns a fake gray glyph backed by a stack buffer.
/// The caller owns the buffer, keep it alive for the duration of upload().
fn fakeGrayGlyph(buf: []u8, width: u16, height: u16) Rasterizer.Glyph {
    @memset(buf[0 .. @as(usize, width) * height], 0xFF); // fully opaque
    return .{
        .bitmap = buf.ptr,
        .width = width,
        .height = height,
        .pitch = width, // no padding
        .bearing_x = 0,
        .bearing_y = @intCast(height),
        .advance = width,
        .kind = .gray,
    };
}

/// Returns a fake BGRA color glyph backed by a stack buffer.
fn fakeColorGlyph(buf: []u8, w: u16, h: u16) Rasterizer.Glyph {
    // Fill with opaque red in BGRA: B=0 G=0 R=255 A=255
    var i: usize = 0;
    while (i < @as(usize, w) * h * 4) : (i += 4) {
        buf[i + 0] = 0; // B
        buf[i + 1] = 0; // G
        buf[i + 2] = 255; // R
        buf[i + 3] = 255; // A
    }
    return .{
        .bitmap = buf.ptr,
        .width = w,
        .height = h,
        .pitch = @as(u16, w) * 4,
        .bearing_x = 0,
        .bearing_y = @intCast(h),
        .advance = w,
        .kind = .color,
    };
}

test "upload: gray glyph returns valid metric" {
    const win = try window.testGlContext();
    defer c.glfwDestroyWindow(win);
    defer c.glfwTerminate();

    var atlas = try Atlas.create(alloc);
    defer atlas.destroy();

    var buf: [8 * 16]u8 = undefined;
    const glyph = fakeGrayGlyph(&buf, 8, 16);

    const m = try atlas.upload(glyph);

    try testing.expectEqual(8, m.width);
    try testing.expectEqual(16, m.height);
    try testing.expectEqual(8, m.advance);
    try testing.expectEqual(.gray, m.kind);

    // packed at origin on first upload
    try testing.expectEqual(0, m.atlas_x);
    try testing.expectEqual(0, m.atlas_y);
}

test "upload: color glyph goes into color atlas" {
    const win = try window.testGlContext();
    defer c.glfwDestroyWindow(win);
    defer c.glfwTerminate();

    var atlas = try Atlas.create(alloc);
    defer atlas.destroy();

    var buf: [32 * 32 * 4]u8 = undefined;
    const glyph = fakeColorGlyph(&buf, 32, 32);

    const m = try atlas.upload(glyph);

    try testing.expectEqual(32, m.width);
    try testing.expectEqual(32, m.height);
    try testing.expectEqual(32, m.advance);
    try testing.expectEqual(.color, m.kind);

    // color packing state is independent, also starts at origin on first upload
    try testing.expectEqual(0, m.atlas_x);
    try testing.expectEqual(0, m.atlas_y);
}

test "upload: zero-size glyph (space) returns zero metrics without GL Upload" {
    const win = try window.testGlContext();
    defer c.glfwDestroyWindow(win);
    defer c.glfwTerminate();

    var atlas = try Atlas.create(alloc);
    defer atlas.destroy();

    const glyph: Rasterizer.Glyph = .{
        .bitmap = undefined, // must not be accessed
        .width = 0,
        .height = 0,
        .pitch = 0,
        .bearing_x = 0,
        .bearing_y = 0,
        .advance = 8, // space still advances the cursor
        .kind = .gray,
    };
    const m = try atlas.upload(glyph);

    try testing.expectEqual(0, m.width);
    try testing.expectEqual(0, m.height);
    try testing.expectEqual(8, m.advance); // advance preserved
    try testing.expectEqual(.gray, m.kind);

    // packing state must NOT have advanced (no space consumed in atlas)
    try testing.expectEqual(0, atlas.state.gray.next_x);
    try testing.expectEqual(0, atlas.state.gray.next_y);
}

test "upload: gray and color packing states are independent" {
    const win = try window.testGlContext();
    defer c.glfwDestroyWindow(win);
    defer c.glfwTerminate();

    var atlas = try Atlas.create(alloc);
    defer atlas.destroy();

    var gbuf: [8 * 16]u8 = undefined;
    var cbuf: [32 * 32 * 4]u8 = undefined;

    const mg = try atlas.upload(fakeGrayGlyph(&gbuf, 8, 16));
    const mc = try atlas.upload(fakeColorGlyph(&cbuf, 32, 32));

    // both start at (0,0) in their respective atlases
    try testing.expectEqual(@as(u16, 0), mg.atlas_x);
    try testing.expectEqual(@as(u16, 0), mc.atlas_x);
    // gray cursor advanced, color cursor advanced independently
    try testing.expectEqual(@as(u16, 8), atlas.state.gray.next_x);
    try testing.expectEqual(@as(u16, 32), atlas.state.color.next_x);
}

test "upload: glyph wider than atlas returns GlyphTooWide" {
    const win = try window.testGlContext();
    defer c.glfwDestroyWindow(win);
    defer c.glfwTerminate();

    var atlas = try Atlas.create(alloc);
    defer atlas.destroy();

    // width > texture_width
    const glyph: Rasterizer.Glyph = .{
        .bitmap = undefined,
        .width = Atlas.texture_width + 1,
        .height = 16,
        .pitch = Atlas.texture_width + 1,
        .bearing_x = 0,
        .bearing_y = 16,
        .advance = Atlas.texture_width + 1,
        .kind = .gray,
    };

    try testing.expectError(error.GlyphTooWide, atlas.upload(glyph));
    // packing state must be unchanged after the error
    try testing.expectEqual(@as(u16, 0), atlas.state.gray.next_x);
    try testing.expectEqual(@as(u16, 0), atlas.state.gray.next_y);
}

fn testCreateAndPreRasterize(win: *c.GLFWwindow) !void {
    _ = win;
    var rasterizer = try Rasterizer.create(alloc, test_font);
    defer rasterizer.destroy(alloc);

    var atlas = try Atlas.create(alloc);
    defer atlas.destroy();

    atlas.preRasterize(alloc, &rasterizer, .{ .start = 0x20, .end = 0x7F });

    for (0x20..0x7F) |cp| {
        const m = try atlas.get(alloc, &rasterizer, @intCast(cp), .regular, .single);
        try testing.expect(m.atlas_x < Atlas.texture_width);
        try testing.expect(m.atlas_y < Atlas.texture_height);
    }
}

fn testCacheHit(win: *c.GLFWwindow) !void {
    _ = win;
    var rasterizer = try Rasterizer.create(alloc, test_font);
    defer rasterizer.destroy(alloc);

    var atlas = try Atlas.create(alloc);
    defer atlas.destroy();

    const m1 = try atlas.get(alloc, &rasterizer, 'A', .regular, .single);
    const m2 = try atlas.get(alloc, &rasterizer, 'A', .regular, .single);
    try testing.expectEqual(m1, m2);
}

fn testBoldVsRegular(win: *c.GLFWwindow) !void {
    _ = win;
    var rasterizer = try Rasterizer.create(alloc, test_font);
    defer rasterizer.destroy(alloc);

    var atlas = try Atlas.create(alloc);
    defer atlas.destroy();

    const m_reg = try atlas.get(alloc, &rasterizer, 'A', .regular, .single);
    const m_bold = try atlas.get(alloc, &rasterizer, 'A', .bold, .single);
    try testing.expect(m_reg.atlas_x != m_bold.atlas_x or m_reg.atlas_y != m_bold.atlas_y);
}

fn testZeroSizeMetric(win: *c.GLFWwindow) !void {
    _ = win;
    var rasterizer = try Rasterizer.create(alloc, test_font);
    defer rasterizer.destroy(alloc);

    var atlas = try Atlas.create(alloc);
    defer atlas.destroy();

    const m1 = try atlas.get(alloc, &rasterizer, 0x20, .regular, .single);
    try testing.expectEqual(@as(u16, 0), m1.width);
    try testing.expectEqual(@as(u16, 0), m1.height);
    try testing.expect(m1.advance > 0);

    const m2 = try atlas.get(alloc, &rasterizer, 0x20, .regular, .single);
    try testing.expectEqual(m1, m2);
}

fn testGetSequenceCacheMiss(win: *c.GLFWwindow) !void {
    _ = win;
    var rasterizer = try Rasterizer.create(alloc, test_font);
    defer rasterizer.destroy(alloc);
    var atlas = try Atlas.create(alloc);
    defer atlas.destroy();

    // Phase 1 stub: rasterizeSequence falls back to cps[0].
    // Use a real emoji sequence — the result is the base codepoint glyph.
    const cps = [_]u21{ 0x1F468, 0x200D, 0x1F469 }; // 👨‍👩 ZWJ sequence
    const m = try atlas.getSequence(alloc, &rasterizer, &cps, .emoji, .double);

    // Must have been packed somewhere in the color atlas
    try testing.expect(m.atlas_x < Atlas.texture_width);
    try testing.expect(m.atlas_y < Atlas.texture_height);
    try testing.expectEqual(.color, m.kind);
}

fn testGetSequenceCacheHit(win: *c.GLFWwindow) !void {
    _ = win;
    var rasterizer = try Rasterizer.create(alloc, test_font);
    defer rasterizer.destroy(alloc);
    var atlas = try Atlas.create(alloc);
    defer atlas.destroy();

    const cps = [_]u21{ 0x1F468, 0x200D, 0x1F469 };
    const m1 = try atlas.getSequence(alloc, &rasterizer, &cps, .emoji, .double);
    const m2 = try atlas.getSequence(alloc, &rasterizer, &cps, .emoji, .double); // cache hit
    try testing.expectEqual(m1, m2);
}

fn testGetSequenceEmptyReturnsError(win: *c.GLFWwindow) !void {
    _ = win;
    var rasterizer = try Rasterizer.create(alloc, test_font);
    defer rasterizer.destroy(alloc);
    var atlas = try Atlas.create(alloc);
    defer atlas.destroy();

    const cps = [_]u21{};
    try testing.expectError(error.EmptySequence, atlas.getSequence(alloc, &rasterizer, &cps, .emoji, .double));
}

test "atlas integration" {
    const win = try getOrCreatedGLContext();
    defer c.glfwDestroyWindow(win);
    defer c.glfwTerminate();

    try testCreateAndPreRasterize(win);
    try testCacheHit(win);
    try testBoldVsRegular(win);
    try testZeroSizeMetric(win);
    try testGetSequenceCacheMiss(win);
    try testGetSequenceCacheHit(win);
    try testGetSequenceEmptyReturnsError(win);
}
