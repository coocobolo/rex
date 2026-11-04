//! Glyph coverage of the whole frame in an offscreen R8 texture, so the
//! decoration pass can skip the underline where descenders and other
//! ink cross it.
//!
//! A frame-sized mask, rather than looking glyphs up per cell in the
//! decoration shader, sees ink wherever it lands: glyphs that overhang
//! into the next cell (italics, wide fallbacks), combining marks, color
//! emoji and every font face alike, with no extra per-cell data. It costs
//! one more draw of the glyph instances, only in frames with underlines.

const std = @import("std");
const log = std.log.scoped(.ink_mask);

const gl = @import("gl.zig");

pub const InkMask = @This();

framebuffer: gl.GLuint,
texture: gl.GLuint,
width: u32 = 0,
height: u32 = 0,

pub fn init() InkMask {
    var self: InkMask = .{ .framebuffer = 0, .texture = 0 };
    gl.genFramebuffers(1, &self.framebuffer);
    gl.genTextures(1, &self.texture);
    gl.bindTexture(gl.TEXTURE_2D, self.texture);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    gl.bindTexture(gl.TEXTURE_2D, 0);
    return self;
}

pub fn deinit(self: *InkMask) void {
    gl.deleteFramebuffers(1, &self.framebuffer);
    gl.deleteTextures(1, &self.texture);
    self.* = undefined;
}

/// Binds the mask as the draw target, sized `width` by `height` pixels
/// like the window framebuffer, and clears it. Returns false, leaving
/// the window framebuffer bound, when the driver rejects the mask.
pub fn begin(self: *InkMask, width: u32, height: u32) bool {
    if (width == 0 or height == 0) return false;
    if (width != self.width or height != self.height) {
        gl.bindTexture(gl.TEXTURE_2D, self.texture);
        gl.texImage2D(gl.TEXTURE_2D, 0, gl.R8, @intCast(width), @intCast(height), 0, gl.RED, gl.UNSIGNED_BYTE, null);
        gl.bindTexture(gl.TEXTURE_2D, 0);
        gl.bindFramebuffer(gl.FRAMEBUFFER, self.framebuffer);
        gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, self.texture, 0);
        self.width = width;
        self.height = height;
    } else {
        gl.bindFramebuffer(gl.FRAMEBUFFER, self.framebuffer);
    }
    if (gl.checkFramebufferStatus(gl.FRAMEBUFFER) != gl.FRAMEBUFFER_COMPLETE) {
        log.warn("ink mask framebuffer incomplete, drawing underlines through ink", .{});
        gl.bindFramebuffer(gl.FRAMEBUFFER, 0);
        return false;
    }
    gl.clearColor(0, 0, 0, 0);
    gl.clear(gl.COLOR_BUFFER_BIT);
    return true;
}

/// Restores the window framebuffer as the draw target.
pub fn end(_: *InkMask) void {
    gl.bindFramebuffer(gl.FRAMEBUFFER, 0);
}

/// Binds the mask texture on `unit` for the decoration shader.
pub fn bind(self: *const InkMask, unit: gl.GLenum) void {
    gl.activeTexture(unit);
    gl.bindTexture(gl.TEXTURE_2D, self.texture);
}
