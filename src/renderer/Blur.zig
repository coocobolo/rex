//! Dual Kawase framebuffer pipeline for frosted modal backdrop blurring.
//!
//! Provides hardware-accelerated offscreen render target management and downsampled
//! multi-tap bilinear blur passes. Scene rendering is captured into an offscreen
//! framebuffer only when modals are active, filtered through half-resolution Kawase
//! passes in sub-millisecond execution times, and composited under modal cards with
//! zero GPU or memory allocation overhead when modals are inactive.

const Blur = @This();

const std = @import("std");
const gl = @import("gl.zig");
const Shader = @import("Shader.zig");

down_shader: Shader,
up_shader: Shader,
dummy_vao: gl.GLuint = 0,

scene_fbo: gl.GLuint = 0,
scene_tex: gl.GLuint = 0,

ping_fbo: gl.GLuint = 0,
ping_tex: gl.GLuint = 0,

width: u32 = 0,
height: u32 = 0,
down_width: u32 = 0,
down_height: u32 = 0,

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

    var ping_fbo: gl.GLuint = 0;
    var ping_tex: gl.GLuint = 0;
    gl.genFramebuffers(1, &ping_fbo);
    gl.genTextures(1, &ping_tex);

    return .{
        .down_shader = down_shader,
        .up_shader = up_shader,
        .dummy_vao = dummy_vao,
        .scene_fbo = scene_fbo,
        .scene_tex = scene_tex,
        .ping_fbo = ping_fbo,
        .ping_tex = ping_tex,
    };
}

/// Frees all OpenGL shaders, vertex arrays, framebuffers, and texture resources.
pub fn deinit(self: *Blur) void {
    self.down_shader.deinit();
    self.up_shader.deinit();

    if (self.dummy_vao != 0) gl.deleteVertexArrays(1, &self.dummy_vao);
    if (self.scene_fbo != 0) gl.deleteFramebuffers(1, &self.scene_fbo);
    if (self.scene_tex != 0) gl.deleteTextures(1, &self.scene_tex);
    if (self.ping_fbo != 0) gl.deleteFramebuffers(1, &self.ping_fbo);
    if (self.ping_tex != 0) gl.deleteTextures(1, &self.ping_tex);

    self.* = undefined;
}

/// Allocates or resizes offscreen render textures when the viewport dimensions change.
pub fn ensureCapacity(self: *Blur, width: u32, height: u32) void {
    if (width == self.width and height == self.height and self.width > 0) return;

    self.width = @max(1, width);
    self.height = @max(1, height);
    self.down_width = @max(1, self.width / 2);
    self.down_height = @max(1, self.height / 2);

    // Setup full-resolution scene capture texture and framebuffer attachment
    gl.bindTexture(gl.TEXTURE_2D, self.scene_tex);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, @intCast(self.width), @intCast(self.height), 0, gl.RGBA, gl.UNSIGNED_BYTE, null);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);

    gl.bindFramebuffer(gl.FRAMEBUFFER, self.scene_fbo);
    gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, self.scene_tex, 0);

    // Setup half-resolution downsample texture and framebuffer attachment
    gl.bindTexture(gl.TEXTURE_2D, self.ping_tex);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, @intCast(self.down_width), @intCast(self.down_height), 0, gl.RGBA, gl.UNSIGNED_BYTE, null);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);

    gl.bindFramebuffer(gl.FRAMEBUFFER, self.ping_fbo);
    gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, self.ping_tex, 0);

    gl.bindFramebuffer(gl.FRAMEBUFFER, 0);
    gl.bindTexture(gl.TEXTURE_2D, 0);
}

/// Redirects subsequent terminal rendering passes into the offscreen scene framebuffer.
pub fn beginScene(self: *Blur, width: u32, height: u32) void {
    self.ensureCapacity(width, height);
    gl.bindFramebuffer(gl.FRAMEBUFFER, self.scene_fbo);
    gl.viewport(0, 0, @intCast(self.width), @intCast(self.height));
}

/// Performs downsampled Dual Kawase filtering and composites the blurred backdrop onto target framebuffer.
pub fn renderBlur(
    self: *Blur,
    width: u32,
    height: u32,
    blur_radius: u8,
    dim_alpha: u8,
    scrim_rgb: [3]u8,
) void {
    // Pass 1: Downsample full scene texture into ping framebuffer
    gl.bindFramebuffer(gl.FRAMEBUFFER, self.ping_fbo);
    gl.viewport(0, 0, @intCast(self.down_width), @intCast(self.down_height));

    self.down_shader.use();
    self.down_shader.set1i("u_texture", 0);
    const hp_x = 0.5 / @as(f32, @floatFromInt(self.width));
    const hp_y = 0.5 / @as(f32, @floatFromInt(self.height));
    self.down_shader.set2f("u_half_pixel", hp_x, hp_y);

    gl.activeTexture(gl.TEXTURE0);
    gl.bindTexture(gl.TEXTURE_2D, self.scene_tex);

    gl.bindVertexArray(self.dummy_vao);
    gl.drawArrays(gl.TRIANGLES, 0, 3);

    // Pass 2: Upsample filtered texture back to target framebuffer with dim scrim blending
    gl.bindFramebuffer(gl.FRAMEBUFFER, 0);
    gl.viewport(0, 0, @intCast(width), @intCast(height));

    self.up_shader.use();
    self.up_shader.set1i("u_texture", 0);
    const up_hp_x = 0.5 / @as(f32, @floatFromInt(self.down_width));
    const up_hp_y = 0.5 / @as(f32, @floatFromInt(self.down_height));
    self.up_shader.set2f("u_half_pixel", up_hp_x, up_hp_y);

    const offset_factor = 1.0 + @as(f32, @floatFromInt(blur_radius)) * 0.15;
    self.up_shader.set1f("u_offset", offset_factor);
    self.up_shader.set1f("u_dim_alpha", @as(f32, @floatFromInt(dim_alpha)) / 255.0);
    self.up_shader.set3f(
        "u_scrim_color",
        @as(f32, @floatFromInt(scrim_rgb[0])) / 255.0,
        @as(f32, @floatFromInt(scrim_rgb[1])) / 255.0,
        @as(f32, @floatFromInt(scrim_rgb[2])) / 255.0,
    );

    gl.activeTexture(gl.TEXTURE0);
    gl.bindTexture(gl.TEXTURE_2D, self.ping_tex);

    gl.bindVertexArray(self.dummy_vao);
    gl.drawArrays(gl.TRIANGLES, 0, 3);
    gl.bindVertexArray(0);
    gl.useProgram(0);
}
