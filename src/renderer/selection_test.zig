//! Verifies Dual Kawase selection backdrop blurring and glass compositing.

const std = @import("std");
const testing = std.testing;

const Background = @import("Background.zig");
const Blur = @import("Blur.zig");
const Selection = @import("Selection.zig");
const gl = @import("gl.zig");
const testGlContext = @import("Window.zig").testGlContext;

test "selection backdrop blur spreads offscreen scene color inside the pill" {
    try testGlContext();

    const width = 64;
    const height = 64;
    const cell: @import("dimension.zig").Dimension(f32) = .{ .width = 8, .height = 16 };
    const frame: @import("dimension.zig").Dimension(f32) = .{ .width = width, .height = height };

    var bg = try Background.init(1, .default);
    defer bg.deinit();

    var blur = try Blur.init();
    defer blur.deinit();

    var sel = try Selection.init(4, .{
        .fill_color = .{ 1, 1, 1, 0 },
        .border_width = 0,
        .radius = 0,
        .blur_radius = 12,
    });
    defer sel.deinit();

    // Capture a black scene with a bright cyan block on row 0 (above the row-1 selection).
    blur.beginScene(width, height);
    gl.enable(gl.BLEND);
    gl.blendFuncSeparate(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA, gl.ONE, gl.ONE_MINUS_SRC_ALPHA);
    gl.clearColor(0, 0, 0, 1);
    gl.clear(gl.COLOR_BUFFER_BIT);

    const bg_instances = [_]Background.Instance{.{
        .col = 1,
        .row = 0,
        .span = 4,
        .r = 0,
        .g = 204,
        .b = 255,
        .a = 255,
    }};
    bg.upload(&bg_instances);
    bg.draw(bg_instances.len, .{ .cell = cell, .frame = frame }, 1.0, 0.0, .{ 1, 1, 1 });

    blur.filterPyramid(12);
    try testing.expect(blur.blurredTexture() != 0);

    // Draw a clear-glass selection over row 1 (y=16..32 top-down, pure black originally).
    var out_fbo: gl.GLuint = 0;
    var out_tex: gl.GLuint = 0;
    gl.genFramebuffers(1, &out_fbo);
    defer gl.deleteFramebuffers(1, &out_fbo);
    gl.genTextures(1, &out_tex);
    defer gl.deleteTextures(1, &out_tex);

    gl.bindTexture(gl.TEXTURE_2D, out_tex);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, width, height, 0, gl.RGBA, gl.UNSIGNED_BYTE, null);
    gl.bindFramebuffer(gl.FRAMEBUFFER, out_fbo);
    gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, out_tex, 0);
    defer gl.bindFramebuffer(gl.FRAMEBUFFER, 0);
    try testing.expectEqual(@as(gl.GLenum, gl.FRAMEBUFFER_COMPLETE), gl.checkFramebufferStatus(gl.FRAMEBUFFER));

    gl.viewport(0, 0, width, height);
    gl.clearColor(0, 0, 0, 1);
    gl.clear(gl.COLOR_BUFFER_BIT);

    const sel_instances = [_]Selection.Instance{.{
        .col = 1,
        .row = 1,
        .span = 4,
        .flags = 0b11,
        .prev_col = 1,
        .prev_span = 4,
        .next_col = 1,
        .next_span = 4,
    }};
    sel.upload(&sel_instances);
    sel.draw(sel_instances.len, null, blur.blurredTexture(), .{ .cell = cell, .frame = frame });

    var pixels: [width * height * 4]u8 = undefined;
    gl.readPixels(0, 0, width, height, gl.RGBA, gl.UNSIGNED_BYTE, &pixels);

    // Row 1 top portion (top-down y=20 -> GL y=43) should receive blurred cyan bloom from row 0.
    const inside_gl_y = 43;
    const inside_x = 20;
    const inside_idx = (inside_gl_y * width + inside_x) * 4;
    try testing.expect(pixels[inside_idx + 2] > 10);

    // Pixel outside the selection pill (x=2, y=10) remains black.
    const outside_idx = (10 * width + 2) * 4;
    try testing.expectEqual(@as(u8, 0), pixels[outside_idx + 0]);
    try testing.expectEqual(@as(u8, 0), pixels[outside_idx + 1]);
    try testing.expectEqual(@as(u8, 0), pixels[outside_idx + 2]);
}
