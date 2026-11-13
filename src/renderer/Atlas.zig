//! Glyph atlas: two GL textures (gray coverage and color) that hold
//! every rasterized glyph, shelf-packed, plus caches that map a code
//! point or grapheme cluster to where its glyph sits.

const std = @import("std");

const window_config = @import("../config/window.zig");

const Allocator = std.mem.Allocator;

const log = std.log.scoped(.atlas);

const ft = @import("../freetype/root.zig");
const Rasterizer = ft.Rasterizer;
const FaceKind = Rasterizer.FaceKind;
const GlyphKind = Rasterizer.GlyphKind;
const Span = Rasterizer.Span;

const gl = @import("gl.zig");

/// Where one glyph sits in the atlas and how to place it in a cell.
/// The bearings and advance are FreeType's glyph metrics, in pixels.
/// See https://learnopengl.com/img/in-practice/glyph.png
pub const Metric = struct {
    /// Bitmap size in pixels. 0 for glyphs with nothing to draw, such
    /// as space.
    width: u16,
    height: u16,

    /// Distance from the pen position to the bitmap's left edge.
    bearing_x: i16,

    /// Distance from the baseline up to the bitmap's top edge.
    bearing_y: i16,

    /// Distance from this glyph's origin to the next glyph's origin.
    advance: u16,

    /// Top-left X of the glyph's region in its atlas texture; the
    /// shader's UVs are atlas_x / Atlas.width and so on. Meaningless
    /// when width or height is 0.
    atlas_x: u16,
    /// Top-left Y of the glyph's region; same caveat as `atlas_x`.
    atlas_y: u16,

    /// Which texture holds the glyph.
    kind: GlyphKind,
};

/// Key of the single-glyph cache.
pub const Key = packed struct(u32) {
    codepoint: u21,
    face: FaceKind,
    span: Span,
    _pad: u7 = 0,
};

/// Shelf-packing cursor for one atlas texture.
pub const PackingState = struct {
    /// Next free X on the current shelf.
    next_x: u16,
    /// Y of the current shelf's top edge.
    next_y: u16,
    /// Height of the tallest glyph on the current shelf.
    row_h: u16,

    pub const init: PackingState = .{ .next_x = 0, .next_y = 0, .row_h = 0 };

    /// Reserves a `width` by `height` region and returns its top-left
    /// corner. Fails with `error.GlyphTooWide` when the glyph is larger
    /// than the atlas in either direction, and `error.AtlasFull` when no
    /// shelf has room.
    pub fn pack(self: *PackingState, width: u16, height: u16, atlas_width: u16, atlas_height: u16) !struct { u16, u16 } {
        if (width > atlas_width or height > atlas_height) return error.GlyphTooWide;

        // Start a new shelf only when the current one is full.
        if (self.next_x + width > atlas_width) {
            self.next_y += self.row_h;
            self.next_x = 0;
            self.row_h = 0;
        }

        if (self.next_y + height > atlas_height) return error.AtlasFull;

        const x = self.next_x;
        const y = self.next_y;
        self.next_x += width;
        self.row_h = @max(self.row_h, height);
        return .{ x, y };
    }
};

pub const Option = window_config.Atlas;

pub const face_count = @typeInfo(FaceKind).@"enum".fields.len;
pub const span_count = @typeInfo(Span).@"enum".fields.len;
pub const AsciiLut = [face_count][span_count][128]?Metric;

pub fn initAsciiLut() AsciiLut {
    return [1][span_count][128]?Metric{[1][128]?Metric{[1]?Metric{null} ** 128} ** span_count} ** face_count;
}

const Atlas = @This();

/// Texture width in pixels, from Option.width after clamping.
width: u16,
/// Texture height in pixels, from Option.height after clamping.
height: u16,

gray_texture: gl.GLuint,
color_texture: gl.GLuint,

state: struct {
    gray: PackingState = .init,
    color: PackingState = .init,
} = .{},

/// Single-glyph cache, keyed by (codepoint, face, span), holding
/// each glyph's metrics and atlas position.
glyph_cache: std.AutoHashMap(Key, Metric),

/// Grapheme cluster cache, keyed by `hashSequence`.
sequence_cache: std.AutoHashMap(u64, Metric),

/// Flat L1-resident cache table for ASCII codepoints (0..127).
/// Eliminates hash calculation and hash map probing during frame building.
ascii_lut: AsciiLut = initAsciiLut(),

pub const empty: Atlas = .{
    .width = 0,
    .height = 0,
    .color_texture = undefined,
    .gray_texture = undefined,
    .glyph_cache = undefined,
    .sequence_cache = undefined,
    .ascii_lut = initAsciiLut(),
};

/// Creates both textures at the option's size, clamped to what the
/// GL driver allows. Needs a current GL context.
pub fn create(gpa: Allocator, option: Option) !Atlas {
    var self: Atlas = .empty;
    var max_size: gl.GLint = 0;
    gl.getIntegerv(gl.MAX_TEXTURE_SIZE, &max_size);
    self.width = clampSize(option.width, max_size);
    self.height = clampSize(option.height, max_size);
    if (self.width != option.width or self.height != option.height) {
        log.warn("atlas size {d}x{d} clamped to {d}x{d}", .{ option.width, option.height, self.width, self.height });
    }

    self.glyph_cache = .init(gpa);
    errdefer self.glyph_cache.deinit();

    self.sequence_cache = .init(gpa);
    errdefer self.sequence_cache.deinit();

    // Allocate gray atlas texture (GL_R8, single channel)
    gl.genTextures(1, &self.gray_texture);
    errdefer gl.deleteTextures(1, &self.gray_texture);
    gl.bindTexture(gl.TEXTURE_2D, self.gray_texture);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.R8, self.width, self.height, 0, gl.RED, gl.UNSIGNED_BYTE, null);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);

    // FreeType's gray bitmaps are one byte of coverage per pixel,
    // stored as GL_R8. Sampling that gives (coverage, 0, 0, 1), but
    // blending needs coverage in alpha, so swizzle it to (1, 1, 1, R).
    const gray_swizzle = [4]gl.GLint{ gl.ONE, gl.ONE, gl.ONE, gl.RED };
    gl.texParameteriv(gl.TEXTURE_2D, gl.TEXTURE_SWIZZLE_RGBA, &gray_swizzle);

    // Color bitmaps are premultiplied BGRA. upload passes them as
    // GL_BGRA, so GL reorders the channels and no swizzle is needed.

    // Allocate color atlas texture (GL_RGBA8, four channels for emoji)
    gl.genTextures(1, &self.color_texture);
    errdefer gl.deleteTextures(1, &self.color_texture);
    gl.bindTexture(gl.TEXTURE_2D, self.color_texture);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, self.width, self.height, 0, gl.RGBA, gl.UNSIGNED_BYTE, null);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);

    return self;
}

/// Clamps a requested texture side to 1 and the driver's limit. A
/// non-positive limit (no context in tests) leaves only the lower bound.
pub fn clampSize(requested: u16, max_size: gl.GLint) u16 {
    const limit: u16 = if (max_size <= 0) std.math.maxInt(u16) else @intCast(@min(max_size, std.math.maxInt(u16)));
    return std.math.clamp(requested, 1, limit);
}

/// Pre-rasterizes and caches glyphs for all font faces in the half-open
/// codepoint range [start, end).
///
/// To warm up printable ASCII, U+0020 to U+007E, pass:
///
///     .{ .start = 0x20, .end = 0x7F }
///
/// Rasterization failures are logged and do not stop processing.
pub fn preRasterize(self: *Atlas, gpa: Allocator, rasterizer: *Rasterizer, range: struct { start: u21, end: u21 }) void {
    for (range.start..range.end) |cp| {
        for ([_]FaceKind{ .regular, .bold, .italic, .bold_italic }) |face| {
            _ = self.get(gpa, rasterizer, @intCast(cp), face, .single) catch |err| {
                log.warn("warmup: failed to rasterize U+{X} face={t}: {}", .{ cp, face, err });
            };
        }
    }
}

/// Frees the caches and deletes both textures.
pub fn destroy(self: *Atlas) void {
    self.glyph_cache.deinit();
    self.sequence_cache.deinit();

    gl.deleteTextures(1, &self.gray_texture);
    gl.deleteTextures(1, &self.color_texture);

    self.* = undefined;
}

/// Returns the cached metric for `codepoint` drawn across `span` cells,
/// rasterizing and uploading it on a miss.
pub fn get(self: *Atlas, gpa: Allocator, rasterizer: *Rasterizer, codepoint: u21, face: FaceKind, span: Span) !Metric {
    if (codepoint < 128) {
        const f = @intFromEnum(face);
        const s = @intFromEnum(span);
        if (self.ascii_lut[f][s][codepoint]) |m| return m;
    }

    const key: Key = .{ .codepoint = codepoint, .face = face, .span = span };

    // Reserve the slot before uploading, so a glyph that reached the
    // atlas is always cached; a failed rasterize or upload drops it.
    const gop = try self.glyph_cache.getOrPut(key);
    if (gop.found_existing) {
        if (codepoint < 128) {
            self.ascii_lut[@intFromEnum(face)][@intFromEnum(span)][codepoint] = gop.value_ptr.*;
        }
        return gop.value_ptr.*;
    }
    errdefer _ = self.glyph_cache.remove(key);

    const glyph = try rasterizer.rasterize(gpa, codepoint, face, span);
    const metric = try self.upload(glyph);
    gop.value_ptr.* = metric;
    if (codepoint < 128) {
        self.ascii_lut[@intFromEnum(face)][@intFromEnum(span)][codepoint] = metric;
    }
    return gop.value_ptr.*;
}

/// Packs `glyph` into its texture and copies its bitmap there. Fails
/// with `error.InvalidPitch` when the pitch cannot hold a row.
///
/// This binds the texture and leaves texture 0 bound, so it must not
/// run between `bindTextures` and the draw that samples them.
pub fn upload(self: *Atlas, glyph: Rasterizer.Glyph) !Metric {
    // Zero-size glyphs (space, combining marks) take no atlas space.
    if (glyph.width == 0 or glyph.height == 0) {
        return .{
            .advance = glyph.advance,
            .atlas_x = 0,
            .atlas_y = 0,
            .bearing_x = glyph.bearing_x,
            .bearing_y = glyph.bearing_y,
            .height = 0,
            .kind = .gray,
            .width = 0,
        };
    }

    // UNPACK_ROW_LENGTH is in pixels, so the pitch must hold whole
    // pixels and at least one row of them.
    const is_color = glyph.kind == .color;
    const bpp: u32 = if (is_color) 4 else 1;
    if (glyph.pitch % bpp != 0 or glyph.pitch / bpp < glyph.width) return error.InvalidPitch;

    const atlas_x, const atlas_y = try self.pack(glyph.kind, glyph.width, glyph.height);

    const texture = if (is_color) self.color_texture else self.gray_texture;
    const format: gl.GLenum = if (is_color) gl.BGRA else gl.RED;

    gl.pixelStorei(gl.UNPACK_ALIGNMENT, 1);
    gl.pixelStorei(gl.UNPACK_ROW_LENGTH, @intCast(glyph.pitch / bpp));
    gl.bindTexture(gl.TEXTURE_2D, texture);
    gl.texSubImage2D(
        gl.TEXTURE_2D,
        0,
        @intCast(atlas_x),
        @intCast(atlas_y),
        @intCast(glyph.width),
        @intCast(glyph.height),
        format,
        gl.UNSIGNED_BYTE,
        glyph.bitmap,
    );
    gl.pixelStorei(gl.UNPACK_ROW_LENGTH, 0);
    gl.pixelStorei(gl.UNPACK_ALIGNMENT, 4);
    gl.bindTexture(gl.TEXTURE_2D, 0);

    return .{
        .atlas_x = atlas_x,
        .atlas_y = atlas_y,
        .width = glyph.width,
        .height = glyph.height,
        .bearing_x = glyph.bearing_x,
        .bearing_y = glyph.bearing_y,
        .advance = glyph.advance,
        .kind = glyph.kind,
    };
}

/// Binds the gray texture to `gray_unit` and the color one to
/// `color_unit`.
pub fn bindTextures(self: *const Atlas, gray_unit: gl.GLenum, color_unit: gl.GLenum) void {
    gl.activeTexture(gray_unit);
    gl.bindTexture(gl.TEXTURE_2D, self.gray_texture);
    gl.activeTexture(color_unit);
    gl.bindTexture(gl.TEXTURE_2D, self.color_texture);
}

/// Like `get`, for a multi-codepoint grapheme cluster.
pub fn getSequence(self: *Atlas, gpa: Allocator, rasterizer: *Rasterizer, cps: []const u21, face: FaceKind, span: Span) !Metric {
    const key = hashSequence(cps, face, span);
    const gop = try self.sequence_cache.getOrPut(key);
    if (gop.found_existing) return gop.value_ptr.*;
    errdefer _ = self.sequence_cache.remove(key);
    const glyph = try rasterizer.rasterizeSequence(gpa, cps, face, span);
    gop.value_ptr.* = try self.upload(glyph);
    return gop.value_ptr.*;
}

/// Cache key for a grapheme cluster: its code points, face and span.
pub fn hashSequence(cps: []const u21, face: FaceKind, span: Span) u64 {
    var h = std.hash.Wyhash.init(0);
    for (cps) |cp| {
        const v: u32 = cp;
        h.update(std.mem.asBytes(&v));
    }
    h.update(&.{ @intFromEnum(face), @intFromEnum(span) });
    return h.final();
}

fn pack(self: *Atlas, kind: GlyphKind, w: u16, h: u16) !struct { u16, u16 } {
    const state = if (kind == .color) &self.state.color else &self.state.gray;
    return state.pack(w, h, self.width, self.height);
}

/// Drops every cached glyph, resets packing and always clears both
/// textures to zero, so no stale pixels remain. Keeps the textures.
/// Call after a font size change.
pub fn invalidate(self: *Atlas) void {
    self.glyph_cache.clearRetainingCapacity();
    self.sequence_cache.clearRetainingCapacity();
    self.ascii_lut = initAsciiLut();
    self.state.gray = PackingState.init;
    self.state.color = PackingState.init;
    clearTexture(self.gray_texture);
    clearTexture(self.color_texture);
}

/// Sets every pixel of `texture` to zero on the GPU by attaching it to a
/// temporary framebuffer and clearing that (GL 3.0 core; glClearTexImage
/// needs 4.4). Unlike uploading zeros, no pixel data passes through
/// client memory. R8 and RGBA8 must be color-renderable on any 3.3
/// driver, so the framebuffer is complete; if it isn't, the error is
/// logged and the texture keeps its pixels. Restores the framebuffer
/// binding and the clear color.
fn clearTexture(texture: gl.GLuint) void {
    var previous_fbo: gl.GLint = 0;
    gl.getIntegerv(gl.FRAMEBUFFER_BINDING, &previous_fbo);
    var previous_color: [4]gl.GLfloat = undefined;
    gl.getFloatv(gl.COLOR_CLEAR_VALUE, &previous_color);

    var fbo: gl.GLuint = 0;
    gl.genFramebuffers(1, &fbo);
    defer gl.deleteFramebuffers(1, &fbo);
    gl.bindFramebuffer(gl.FRAMEBUFFER, fbo);
    defer gl.bindFramebuffer(gl.FRAMEBUFFER, @intCast(previous_fbo));
    gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, texture, 0);

    const status = gl.checkFramebufferStatus(gl.FRAMEBUFFER);
    if (status != gl.FRAMEBUFFER_COMPLETE) {
        log.err("atlas clear: framebuffer incomplete (status 0x{x}); texture {d} keeps its pixels", .{ status, texture });
        return;
    }

    gl.clearColor(0, 0, 0, 0);
    gl.clear(gl.COLOR_BUFFER_BIT);
    gl.clearColor(previous_color[0], previous_color[1], previous_color[2], previous_color[3]);
}
