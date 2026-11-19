const std = @import("std");
const testing = std.testing;
const alloc = testing.allocator;

const gl = @import("gl.zig");
const AsciiOverlay = @import("AsciiOverlay.zig");
const Atlas = @import("Atlas.zig");
const platform = @import("../platform/root.zig");
const Rasterizer = @import("../freetype/Rasterizer.zig");
const test_font = @import("../freetype/test_fixtures.zig").test_font;
const AsciiCanvas = @import("../kit/AsciiCanvas.zig");
const Theme = @import("../kit/Theme.zig");
const Color = Theme.Color;

const testGlContext = platform.testGlContext;

fn pixelAt(pixels: []const u8, width: u32, height: u32, x: u32, y: u32) Color {
    // OpenGL `readPixels` returns rows bottom-to-top.
    const gl_y = height - 1 - y;
    const offset = (@as(usize, gl_y) * @as(usize, width) + @as(usize, x)) * 4;
    return .{
        .r = pixels[offset + 0],
        .g = pixels[offset + 1],
        .b = pixels[offset + 2],
        .a = pixels[offset + 3],
    };
}

test "AsciiOverlay: computeGrid centers square and terminal grids with bottom reserve" {
    const metrics: Rasterizer.Metrics = .{
        .cell_width = 10,
        .cell_height = 20,
        .ascender = 16,
        .descender = 4,
        .underline_y = 18,
        .underline_thickness = 1,
        .strikethrough_y = 10,
        .strikethrough_thickness = 1,
    };

    const sq = AsciiOverlay.computeGrid(800, 600, metrics, .square, 80);
    try testing.expectEqual(@as(f32, 20), sq.cell_w);
    try testing.expectEqual(@as(f32, 20), sq.cell_h);
    try testing.expectEqual(@as(u16, 40), sq.cols);
    try testing.expectEqual(@as(u16, 26), sq.rows); // (600 - 80) / 20 = 26
    try testing.expectEqual(@as(f32, 0), sq.origin_x);
    try testing.expectEqual(@as(f32, 0), sq.origin_y);
    try testing.expect(sq.tile_inset >= 1.0);

    const term = AsciiOverlay.computeGrid(805, 600, metrics, .terminal, 80);
    try testing.expectEqual(@as(f32, 10), term.cell_w);
    try testing.expectEqual(@as(f32, 20), term.cell_h);
    try testing.expectEqual(@as(u16, 80), term.cols);
    try testing.expectEqual(@as(u16, 26), term.rows);
    try testing.expectEqual(@as(f32, 2), term.origin_x); // floor((805 - 800) / 2)
    try testing.expectEqual(@as(f32, 0), term.tile_inset);
}

test "AsciiOverlay: draws backdrop, square block tiles, and atlas glyphs" {
    try testGlContext();

    var rasterizer: Rasterizer = try .init(alloc, test_font);
    defer rasterizer.deinit(alloc);

    var atlas: Atlas = try .init(alloc, .{});
    defer atlas.deinit();

    const overlay = try AsciiOverlay.create(alloc);
    defer overlay.destroy(alloc);

    const width: u32 = 320;
    const height: u32 = 240;

    var target: gl.GLuint = 0;
    gl.genTextures(1, &target);
    defer gl.deleteTextures(1, &target);
    gl.bindTexture(gl.TEXTURE_2D, target);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, @intCast(width), @intCast(height), 0, gl.RGBA, gl.UNSIGNED_BYTE, null);
    gl.bindTexture(gl.TEXTURE_2D, 0);

    var fbo: gl.GLuint = 0;
    gl.genFramebuffers(1, &fbo);
    defer gl.deleteFramebuffers(1, &fbo);
    gl.bindFramebuffer(gl.FRAMEBUFFER, fbo);
    defer gl.bindFramebuffer(gl.FRAMEBUFFER, 0);
    gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, target, 0);
    try testing.expectEqual(@as(gl.GLenum, gl.FRAMEBUFFER_COMPLETE), gl.checkFramebufferStatus(gl.FRAMEBUFFER));

    gl.viewport(0, 0, @intCast(width), @intCast(height));
    // Underlying terminal clear color (distinct blue) to verify backdrop coverage.
    gl.clearColor(0.0, 0.0, 1.0, 1.0);
    gl.clear(gl.COLOR_BUFFER_BIT);

    // Frame with one full block (`█`, rendered as inset tile in `.square`) and ASCII `0`.
    var frames = try AsciiCanvas.Frames.parse(alloc, "█0\n");
    defer frames.deinit(alloc);

    try overlay.prepare(alloc, &atlas, &rasterizer, .{
        .source = .{ .frames = &frames },
        .aspect = .square,
        .time_s = 0,
        .palette = .{
            .fg = .rgb(0xffffff),
            .accent = .rgb(0x40c080),
            .muted = .rgb(0x888888),
        },
        .backdrop = .{ .r = 10, .g = 12, .b = 14, .a = 255 },
        .screen_w = @floatFromInt(width),
        .screen_h = @floatFromInt(height),
    });
    try testing.expectEqual(@as(u32, 1), overlay.tile_len);
    try testing.expectEqual(@as(u32, 1), overlay.glyph_len);

    overlay.draw(&atlas, @floatFromInt(width), @floatFromInt(height));

    const pixels = try alloc.alloc(u8, @as(usize, width) * @as(usize, height) * 4);
    defer alloc.free(pixels);
    gl.readPixels(0, 0, @intCast(width), @intCast(height), gl.RGBA, gl.UNSIGNED_BYTE, pixels.ptr);

    // Top-left corner should show opaque backdrop, completely covering underlying blue.
    const corner = pixelAt(pixels, width, height, 2, 2);
    try testing.expectEqual(@as(u8, 10), corner.r);
    try testing.expectEqual(@as(u8, 12), corner.g);
    try testing.expectEqual(@as(u8, 14), corner.b);

    // Locate the centered tile cell and glyph cell, verify bright white pixels inside both.
    const dst_x0 = (overlay.grid.cols - 2) / 2;
    const dst_y0 = (overlay.grid.rows - 1) / 2;
    const tile_cx: u32 = @intFromFloat(overlay.grid.origin_x + (@as(f32, @floatFromInt(dst_x0)) + 0.5) * overlay.grid.cell_w);
    const tile_cy: u32 = @intFromFloat(overlay.grid.origin_y + (@as(f32, @floatFromInt(dst_y0)) + 0.5) * overlay.grid.cell_h);
    const tile_px = pixelAt(pixels, width, height, tile_cx, tile_cy);
    try testing.expectEqual(@as(u8, 255), tile_px.r);
    try testing.expectEqual(@as(u8, 255), tile_px.g);
    try testing.expectEqual(@as(u8, 255), tile_px.b);

    // Scan the adjacent glyph cell for bright pixels drawn by the `'0'` glyph.
    const gx0: u32 = @intFromFloat(overlay.grid.origin_x + @as(f32, @floatFromInt(dst_x0 + 1)) * overlay.grid.cell_w);
    const gy0: u32 = @intFromFloat(overlay.grid.origin_y + @as(f32, @floatFromInt(dst_y0)) * overlay.grid.cell_h);
    const gw: u32 = @intFromFloat(overlay.grid.cell_w);
    const gh: u32 = @intFromFloat(overlay.grid.cell_h);
    var lit_glyph_pixels: usize = 0;
    for (gy0..@min(height, gy0 + gh)) |py| {
        for (gx0..@min(width, gx0 + gw)) |px| {
            const c = pixelAt(pixels, width, height, @intCast(px), @intCast(py));
            if (c.r > 128 and c.g > 128 and c.b > 128) lit_glyph_pixels += 1;
        }
    }
    try testing.expect(lit_glyph_pixels > 0);
}

test "AsciiOverlay: procedural spin_3d renders cleanly and keeps tile_len zero in terminal aspect" {
    try testGlContext();

    var rasterizer: Rasterizer = try .init(alloc, test_font);
    defer rasterizer.deinit(alloc);

    var atlas: Atlas = try .init(alloc, .{});
    defer atlas.deinit();

    const overlay = try AsciiOverlay.create(alloc);
    defer overlay.destroy(alloc);

    const palette = AsciiCanvas.Palette.fromTheme(&Theme.dark, Theme.dark.success);

    try overlay.prepare(alloc, &atlas, &rasterizer, .{
        .source = .{ .procedural = .spin_3d },
        .aspect = .square,
        .time_s = 0.8,
        .palette = palette,
        .backdrop = .{ .r = 0, .g = 0, .b = 0, .a = 240 },
        .screen_w = 640,
        .screen_h = 480,
        .bottom_reserve_px = 72,
    });
    try testing.expect(overlay.tile_len > 0);
    try testing.expect(overlay.glyph_len > 0);

    try overlay.prepare(alloc, &atlas, &rasterizer, .{
        .source = .{ .procedural = .spin_3d },
        .aspect = .terminal,
        .time_s = 0.8,
        .palette = palette,
        .backdrop = .{ .r = 0, .g = 0, .b = 0, .a = 240 },
        .screen_w = 640,
        .screen_h = 480,
        .bottom_reserve_px = 72,
    });
    try testing.expectEqual(@as(u32, 0), overlay.tile_len);
    try testing.expect(overlay.glyph_len > 0);
}
