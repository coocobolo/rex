//! Dual Kawase framebuffer pipeline for frosted modal backdrop blurring.
//!
//! Provides hardware-accelerated offscreen render target management and a multi-level
//! progressive image pyramid. Scene rendering is captured into an offscreen framebuffer
//! only when modals are active, filtered through progressive downsample and tent-filter
//! upsample passes, and composited under modal cards with zero GPU or memory allocation
//! overhead when modals are inactive.

const Blur = @This();

const std = @import("std");
const gl = @import("gl.zig");
const Shader = @import("Shader.zig");

pub const max_levels = 3;

pub const Level = struct {
    fbo: gl.GLuint = 0,
    tex: gl.GLuint = 0,
    width: u32 = 0,
    height: u32 = 0,
};

down_shader: Shader,
up_shader: Shader,
dummy_vao: gl.GLuint = 0,

scene_fbo: gl.GLuint = 0,
scene_tex: gl.GLuint = 0,

levels: [max_levels]Level = undefined,

width: u32 = 0,
height: u32 = 0,

/// Compiles Dual Kawase GLSL shaders and initializes OpenGL framebuffer handles.
pub fn init() !Blur {
    var down_shader = try Shader.init(
        @embedFile("shaders/fullscreen.vert"),
        @embedFile("shaders/blur_down.frag"),
    );
    errdefer down_shader.deinit();

    var up_shader = try Shader.init(
        @embedFile("shaders/fullscreen.vert"),
        @embedFile("shaders/blur_up.frag"),
    );
    errdefer up_shader.deinit();

    var dummy_vao: gl.GLuint = 0;
    gl.genVertexArrays(1, &dummy_vao);

    var scene_fbo: gl.GLuint = 0;
    var scene_tex: gl.GLuint = 0;
    gl.genFramebuffers(1, &scene_fbo);
    gl.genTextures(1, &scene_tex);

    var levels: [max_levels]Level = undefined;
    for (&levels) |*lvl| {
        lvl.width = 0;
        lvl.height = 0;
        gl.genFramebuffers(1, &lvl.fbo);
        gl.genTextures(1, &lvl.tex);
    }

    return .{
        .down_shader = down_shader,
        .up_shader = up_shader,
        .dummy_vao = dummy_vao,
        .scene_fbo = scene_fbo,
        .scene_tex = scene_tex,
        .levels = levels,
    };
}

/// Frees all OpenGL shaders, vertex arrays, framebuffers, and texture resources.
pub fn deinit(self: *Blur) void {
    self.down_shader.deinit();
    self.up_shader.deinit();

    if (self.dummy_vao != 0) gl.deleteVertexArrays(1, &self.dummy_vao);
    if (self.scene_fbo != 0) gl.deleteFramebuffers(1, &self.scene_fbo);
    if (self.scene_tex != 0) gl.deleteTextures(1, &self.scene_tex);

    for (&self.levels) |*lvl| {
        if (lvl.fbo != 0) gl.deleteFramebuffers(1, &lvl.fbo);
        if (lvl.tex != 0) gl.deleteTextures(1, &lvl.tex);
    }

    self.* = undefined;
}

/// Allocates or resizes offscreen render textures when the viewport dimensions change.
pub fn ensureCapacity(self: *Blur, width: u32, height: u32) void {
    if (width == self.width and height == self.height and self.width > 0) return;

    self.width = @max(1, width);
    self.height = @max(1, height);

    // Setup full-resolution scene capture texture and framebuffer attachment
    gl.bindTexture(gl.TEXTURE_2D, self.scene_tex);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, @intCast(self.width), @intCast(self.height), 0, gl.RGBA, gl.UNSIGNED_BYTE, null);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);

    gl.bindFramebuffer(gl.FRAMEBUFFER, self.scene_fbo);
    gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, self.scene_tex, 0);

    // Setup progressive downsampled pyramid textures and framebuffer attachments
    var cur_w = self.width;
    var cur_h = self.height;
    for (&self.levels) |*lvl| {
        cur_w = @max(1, cur_w / 2);
        cur_h = @max(1, cur_h / 2);
        lvl.width = cur_w;
        lvl.height = cur_h;

        gl.bindTexture(gl.TEXTURE_2D, lvl.tex);
        gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, @intCast(lvl.width), @intCast(lvl.height), 0, gl.RGBA, gl.UNSIGNED_BYTE, null);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);

        gl.bindFramebuffer(gl.FRAMEBUFFER, lvl.fbo);
        gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, lvl.tex, 0);
    }

    gl.bindFramebuffer(gl.FRAMEBUFFER, 0);
    gl.bindTexture(gl.TEXTURE_2D, 0);
}

/// Redirects subsequent terminal rendering passes into the offscreen scene framebuffer.
pub fn beginScene(self: *Blur, width: u32, height: u32) void {
    self.ensureCapacity(width, height);
    gl.bindFramebuffer(gl.FRAMEBUFFER, self.scene_fbo);
    gl.viewport(0, 0, @intCast(self.width), @intCast(self.height));
}

/// Performs progressive Dual Kawase filtering and composites the blurred backdrop onto target framebuffer.
pub fn renderBlur(
    self: *Blur,
    width: u32,
    height: u32,
    blur_radius: u8,
    dim_alpha: u8,
    scrim_rgb: [3]u8,
) void {
    const active_levels: usize = if (blur_radius <= 4)
        1
    else if (blur_radius <= 8)
        2
    else
        max_levels;

    const base_offset: f32 = 1.0 + (@as(f32, @floatFromInt(blur_radius)) / 32.0) * 0.4;

    gl.bindVertexArray(self.dummy_vao);
    gl.activeTexture(gl.TEXTURE0);

    // 1. Progressive Downsample Passes
    self.down_shader.use();
    self.down_shader.set1i("u_texture", 0);
    self.down_shader.set1f("u_offset", base_offset);

    var src_tex = self.scene_tex;
    var src_w = self.width;
    var src_h = self.height;

    for (0..active_levels) |i| {
        const dst = &self.levels[i];
        gl.bindFramebuffer(gl.FRAMEBUFFER, dst.fbo);
        gl.viewport(0, 0, @intCast(dst.width), @intCast(dst.height));

        const hp_x = 1.0 / @as(f32, @floatFromInt(src_w));
        const hp_y = 1.0 / @as(f32, @floatFromInt(src_h));
        self.down_shader.set2f("u_half_pixel", hp_x, hp_y);

        gl.bindTexture(gl.TEXTURE_2D, src_tex);
        gl.drawArrays(gl.TRIANGLES, 0, 3);

        src_tex = dst.tex;
        src_w = dst.width;
        src_h = dst.height;
    }

    // 2. Progressive Upsample Passes
    self.up_shader.use();
    self.up_shader.set1i("u_texture", 0);
    self.up_shader.set1f("u_offset", base_offset);

    self.up_shader.set1f("u_dim_alpha", @as(f32, @floatFromInt(dim_alpha)) / 255.0);
    self.up_shader.set3f(
        "u_scrim_color",
        @as(f32, @floatFromInt(scrim_rgb[0])) / 255.0,
        @as(f32, @floatFromInt(scrim_rgb[1])) / 255.0,
        @as(f32, @floatFromInt(scrim_rgb[2])) / 255.0,
    );

    var cur_idx = active_levels - 1;
    while (cur_idx > 0) : (cur_idx -= 1) {
        const src = &self.levels[cur_idx];
        const dst = &self.levels[cur_idx - 1];

        gl.bindFramebuffer(gl.FRAMEBUFFER, dst.fbo);
        gl.viewport(0, 0, @intCast(dst.width), @intCast(dst.height));

        self.up_shader.set1i("u_is_final", 0);
        const up_hp_x = 0.5 / @as(f32, @floatFromInt(src.width));
        const up_hp_y = 0.5 / @as(f32, @floatFromInt(src.height));
        self.up_shader.set2f("u_half_pixel", up_hp_x, up_hp_y);

        gl.bindTexture(gl.TEXTURE_2D, src.tex);
        gl.drawArrays(gl.TRIANGLES, 0, 3);
    }

    // Final Upsample Pass: Level 0 -> Target Framebuffer (Screen) with Scrim & Dither
    gl.bindFramebuffer(gl.FRAMEBUFFER, 0);
    gl.viewport(0, 0, @intCast(width), @intCast(height));

    self.up_shader.set1i("u_is_final", 1);
    const top_src = &self.levels[0];
    const final_hp_x = 0.5 / @as(f32, @floatFromInt(top_src.width));
    const final_hp_y = 0.5 / @as(f32, @floatFromInt(top_src.height));
    self.up_shader.set2f("u_half_pixel", final_hp_x, final_hp_y);

    gl.bindTexture(gl.TEXTURE_2D, top_src.tex);
    gl.drawArrays(gl.TRIANGLES, 0, 3);

    gl.bindVertexArray(0);
    gl.useProgram(0);
}
