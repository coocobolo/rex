const std = @import("std");
const builtin = @import("builtin");

const testing = std.testing;
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.atlas);

const ft = @import("../freetype/root.zig");
const Rasterizer = ft.Rasterizer;
const FaceKind = Rasterizer.FaceKind;
const GlyphKind = Rasterizer.GlyphKind;
const Span = Rasterizer.Span;

const gl = @import("gl.zig");

test {
    _ = @import("atlas_test.zig");
}

/// On the modern text rendering, a TrueType font is a collection
/// of character glyphs that not defined by pixels or any other
/// non-scalable solution, but by mathematical equations. By using
/// TrueType fonts we can easily render character glyphs of various
/// sizes without loss of quality.
///
/// Modern text rendering use FreeType to loads these TrueType fonts
/// and, for each of the Glyph, generates a bitmap image and calculates
/// several metrics. So, we can extract these bitmap image for generating
/// textures and position each character Glyph appropriately using the
/// loaded metrics.
///
/// See the metrics for Glyph Metric on https://learnopengl.com/img/in-practice/glyph.png
///
/// So, when we load a character with FreeType, we are not loading a
/// fixed-size box, but only the pixels that are actually needed to
/// draw that specific character. Imagine rendering the characters
/// ('.', 'i', 'A', 'W', 'g') the visible shape of each character
/// occupies different amount of spaces, for '.' is tiny, 'i' is
/// narrow, 'A' is medium-sized, 'W' is wide, 'g' is extends bellow
/// the origin/baseline. With FreeType it gives us two things, the bitmap
/// (the actual pixels to draw) and the metrics (the instruction where and
/// how to place those pixels).
///
/// For the letter 'A', we might get a bitmap that's take 30x40 pixels of space,
/// but for '.' might get a bitmap that's only 5x5 pixels of space. Therefore,
/// if we simply draw each bitmap one after another, the text will look broken
/// because we don't know, where the bitmap should sit vertically, how much space
/// comes before it, how much space comes after it, where the next character should
/// start, thanks to Glyph Metrics for solving these problems.
///
/// We could load a character glyph, retrieve its metrics, and generate a texture
/// each time we want to render to the screen, it would be insufficient to-do this
/// each frame. We'd rater stored on the CPU side, and query it whenever we want to
/// render a character.
pub const Metric = struct {
    // The width and height are the size of the bitmap itself.
    // Simply the dimensions of the generated image.
    width: u16,
    height: u16,

    /// Bearing X (Left Bearing), how far the
    /// bitmap begins from the cursor positions.
    bearing_x: i16,

    /// Bearing Y (Top Bearing), how high the top
    /// of the bitmap above the orign/baseline.
    bearing_y: i16,

    /// The horizontal advance, distance from the origin
    /// to the origin of the next glyph.
    advance: u16,

    /// When rendering a glyph, the GPU samples from the atlas texture.
    /// To do that, it needs UV coordinates, which means it needs to
    /// know where in the atlas the glyph was packed.
    ///
    /// Flow is:
    /// 1. At load time, FreeType rasterizes the glyph into a bitmap.
    /// Then, we copy that bitmap into a free region of the atlas at
    /// some position (atlas_x, atlas_y). Savve those coordinates where
    /// we stored the persistent of the glyphes (e.g., CachedGlyph).
    ///
    /// 2. At draw time, for each cell on screen, we look up the (e.g., CachedGlyphe)
    /// for that codepoint, then compute UV coordinates from atlas_x / atlas_y
    /// to pass to the vertex buffer.
    ///
    /// Usage:
    /// ```
    /// const u0 = @as(f32, @floatFromInt(glyph.atlas_x)) / atlas_width;
    /// const v0 = @as(f32, @floatFromInt(glyph.atlas_y)) / atlas_height;
    /// const u1 = u0 + @as(f32, @floatFromInt(glyph.width)) / atlas_width;
    /// const v1 = v0 + @as(f32, @floatFromInt(glyph.height)) / atlas_height;
    /// ```
    ///
    /// 3. The shader samples texture(atlas, vec2(u,v)) using those
    /// UVs to get the correct glyph pixels.
    ///
    /// So, without atlas_x/atlas_y, we have no way to tell the GPU which region
    /// of the atlas corresponds to which glyph. The atlas is one big texture,
    /// the coordinates are the only thing that distinguishes glyph A from glyph B
    /// inside it.
    ///
    /// Lets say for an atlas texture (1024x1024).
    ///   ----------------------------
    ///  |  atlas texture (1024x1024) |
    ///  |   ---   ---   ----         |
    ///  |  | A | | B | | 😀 |  ...   |
    ///  |   ---   ---   ----         |
    ///  |  ^                         |
    ///  |  atlas_x=2, atlas_y=2      |
    ///   ----------------------------
    ///
    /// atlas_x/atlas_y is the top-left corner of the glyph's region in that
    /// texture. width/height give the extent. Together they define the rectangle
    /// to sample.
    ///
    /// Top-left X of the glyph's region in the atlas texture.
    /// Undefined (do not use) when width == 0 or height == 0.
    atlas_x: u16,
    atlas_y: u16,

    kind: GlyphKind, // NOTE wasted 2 bytes - 1 bit

};

pub const Key = packed struct(u32) {
    codepoint: u21,
    face: FaceKind,
    span: Span,
    _pad: u7 = 0,
};

// Atlas packing cursor state
pub const PackingState = struct {
    /// next free X on the current shelf
    next_x: u16,
    /// The Y of the current shelf's top edge
    next_y: u16,
    /// tallest glyph on the current shelf
    row_h: u16,

    pub const init: PackingState = .{ .next_x = 0, .next_y = 0, .row_h = 0 };

    pub fn pack(self: *PackingState, width: u16, height: u16, atlas_width: u16, atlas_height: u16) !struct { u16, u16 } {
        if (width > atlas_width or height > atlas_height) return error.GlyphTooWide;

        // Only advance shelf when current one is full
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

// Default atlas dimensions set for HiDPI
pub const texture_width: u16 = 2048;
pub const texture_height: u16 = 2048;

const Atlas = @This();

gray_texture: gl.GLuint,
color_texture: gl.GLuint,

state: struct {
    gray: PackingState = .init,
    color: PackingState = .init,
} = .{},

/// Single glyph cache,
/// Keyed by (codepoint, face, span)
/// Value by Glyph Metrics
glyph_cache: std.AutoHashMap(Key, Metric),

sequence_cache: std.AutoHashMap(u64, Metric),

/// Atlas dimensions (in pixels), the size imposes
/// when the atlas is too small to hold all the glyph
/// (LRU cache) or grow the atlas. The atlas sze has
/// no effect on rendering quality or window size, it
/// only affects how many distinct glyphs you can cache
/// before needng to re-upload.
///
/// For terminal emulator, the 1024x1024 is usually sufficient
/// for gray glyphs (ASCII + common Unicode). Color emoji are
/// larger (typically 64x64 or 128x128 per glyph), so a separate
/// 512x512 or 1024x1024 color atlas is reasonable. If we're on
/// HiDPI, the cell height might be 32-40px instead of 16-20px,
/// so glyphs are larger and the atlas fills faster, consider for
/// 2048x2048 for HiDPI.
///
/// NOTE future if we need runtime value for dimension
/// for now keep with comptime default to HiDPI
// dimension: Dimension = .{
//     .width = texture_width,
//     .height = texture_height,
// ,

pub const empty: Atlas = .{
    .color_texture = undefined,
    .gray_texture = undefined,
    .glyph_cache = undefined,
    .sequence_cache = undefined,
};

pub fn create(gpa: Allocator) !Atlas {
    var self: Atlas = .empty;
    self.glyph_cache = .init(gpa);
    errdefer self.glyph_cache.deinit();

    self.sequence_cache = .init(gpa);
    errdefer self.sequence_cache.deinit();

    // Allocate gray atlas texture (GL_R8, single channel)
    gl.genTextures(1, &self.gray_texture);
    errdefer gl.deleteTextures(1, &self.gray_texture);
    gl.bindTexture(gl.TEXTURE_2D, self.gray_texture);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.R8, texture_width, texture_height, 0, gl.RED, gl.UNSIGNED_BYTE, null);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);

    // Gray atlas strategy
    //
    // GL_TEXTURE_SWIZZLE_A is relevant specifically for the gray atlas.
    // because the FreeType's grayscale bitmaps are single-channel (8-bit
    // coverage), but the GPU needs that coverage value in the alpha channel
    // for blending.
    //
    // FreeType produces FT_PIXEL_MODE_GRAY, one byte per pixel, coverage value
    // 0-255, we upload it as GL_R8 in above, without swizzle, sampling gives
    // (coverage, 0, 0, 0), alpha is 0 means invisible.
    const gray_swizzle = [4]gl.GLint{ gl.ONE, gl.ONE, gl.ONE, gl.RED };
    gl.texParameteriv(gl.TEXTURE_2D, gl.TEXTURE_SWIZZLE_RGBA, &gray_swizzle);

    // HACK Color atlas strategy
    //
    // FreeType produces FT_PIXEL_MODE_BGRA, 4 channels, premultiplied, B and R
    // swapped relative to OpenGL's GL_RGBA. Since we already using the GL_BGRA,
    // we dont need to swizzle it explicitly.
    //
    // The alternative option is:
    // const color_swizzle = [4]gl.GLint{ gl.GL_BLUE, gl.GL_GREEN, gl.GL_RED, gl.GL_ALPHA };
    // gl.glTexParameteriv(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_SWIZZLE_RGBA, &color_swizzle);

    // Allocate color atlas texture (GL_RGBA8, four channels for emoji)
    gl.genTextures(1, &self.color_texture);
    errdefer gl.deleteTextures(1, &self.color_texture);
    gl.bindTexture(gl.TEXTURE_2D, self.color_texture);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, texture_width, texture_height, 0, gl.RGBA, gl.UNSIGNED_BYTE, null);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);

    return self;
}

/// Pre-rasterizes and caches glyphs for all font faces in the half-open
/// codepoint range [start, end).
///
/// Note: Zig ranges are end-exclusive. To warm up U+0020 through U+007E
/// inclusive (printable ASCII), pass:
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
    const key: Key = .{ .codepoint = codepoint, .face = face, .span = span };

    // If rasterize succeeds but glyph_cache.put fails (OOM),
    // the glyph was uploaded to the GPU atlas but not cached.
    // Next call to get will try to rasterize again, re-uploading
    // to a different atlas position and wasting space.
    const gop = try self.glyph_cache.getOrPut(key);
    if (gop.found_existing) return gop.value_ptr.*;
    errdefer _ = self.glyph_cache.remove(key);

    const glyph = try rasterizer.rasterize(gpa, codepoint, face, span);
    const metric = try self.upload(glyph);
    // std.debug.print("upload '{u}' face={s} atlas={}x{} size={}x{} pitch={}\n", .{
    //     codepoint,      @tagName(face),
    //     metric.atlas_x, metric.atlas_y,
    //     metric.width,   metric.height,
    //     glyph.pitch,
    // });
    gop.value_ptr.* = metric;
    return gop.value_ptr.*;
}

pub fn upload(self: *Atlas, glyph: Rasterizer.Glyph) !Metric {
    // Zero-size glyphs (space, combining marks) no-op
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

    const atlas_x, const atlas_y = try self.pack(glyph.kind, glyph.width, glyph.height);

    // gl.bindTexture(gl.TEXTURE_2D, texture);
    // gl.texSubImage2D(
    //    gl.TEXTURE_2D, 0,
    //    @intCast(atlas_x), @intCast(atlas_y),
    //    @intCast(bmp.width), @intCast(bmp.rows),
    //    fmt, gl.UNSIGNED_BYTE, bmp.buffer,
    // );

    // Problems: gl.bindTexture during rendering corrupts GL state
    // If get() is ever called on a cache miss during a frame draw (lazy-rasterization),
    // bindTexture will change the currently bound texture mid-render. The option is either:
    // 1. Ensure all rasterization happens before the render loop (warm-up + pre-rasterize
    // covers ASCII; unknown glyphs get rasterized at frame start, no mid-draw), or
    //
    // 2. Use DSA (current approach but might break for OpenGL 3.x compatibility) which
    // doesn't require binding.

    // HACK (futere.me) so the alternative for OpenGL 3.x compatibility is using
    // Two-phase approach (API change required), works:
    // 1. Collect phase, iterate all visible cells, call get for each codepoint (
    // cache hits are free; misses are queued but not uploaded yet).
    // 2. Upload phase, flush all queued rasterizations before any draw call
    // 3. Draw phase, all glyphs are in the atlas, no mid-render uploads
    //
    // The impact of these requires splitting rasterize into rasterizeCpu (FreeType only,
    // no GL) and uploadGlyph (GL upload), and adding a flush step to the render loop.
    // It's more work.

    // NOTE USD approach might break for OpenGL 3.x compatiblity

    // DSA Upload to GPU
    const is_color = glyph.kind == .color;
    const texture = if (is_color) self.color_texture else self.gray_texture;
    const format: gl.GLenum = if (is_color) gl.BGRA else gl.RED;

    const bpp: u32 = if (is_color) 4 else 1;
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

    // FT_Bitmap.pitch is c_int (signed). Negative pitch means bottom-up bitmap.
    // FT_LOAD_RENDER always produces top-down (positive pitch), but the @abs above is a safe guard.

    // gl.pixelStorei(gl.UNPACK_ROW_LENGTH, row_len);
    // gl.textureSubImage2D(
    //     texture,
    //     0,
    //     @intCast(atlas_x),
    //     @intCast(atlas_y),
    //     @intCast(glyph.width),
    //     @intCast(glyph.height),
    //     format,
    //     gl.UNSIGNED_BYTE,
    //     glyph.bitmap,
    // );
    // gl.pixelStorei(gl.UNPACK_ROW_LENGTH, 0); // reset to default

    // gl.pixelStorei(gl.UNPACK_ROW_LENGTH, @intCast(glyph.pitch));
    // gl.texSubImage2D(
    //     texture,
    //     0,
    //     @intCast(atlas_x),
    //     @intCast(atlas_y),
    //     @intCast(glyph.width),
    //     @intCast(glyph.height),
    //     format,
    //     gl.UNSIGNED_BYTE,
    //     glyph.bitmap,
    // );
    // gl.pixelStorei(gl.UNPACK_ROW_LENGTH, 0); // reset to default

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

fn hashSequence(cps: []const u21, face: FaceKind, span: Span) u64 {
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
    return state.pack(w, h, texture_width, texture_height);
}

/// Clears all cached glyph metrics and resets packing state.
/// Call after font size change. Does not free GL textures.
pub fn invalidate(self: *Atlas) void {
    self.glyph_cache.clearRetainingCapacity();
    self.sequence_cache.clearRetainingCapacity();
    self.state.gray = PackingState.init;
    self.state.color = PackingState.init;
    // Optionally clear texture contents to avoid stale pixels:
    gl.clearTexImage(self.gray_texture, 0, gl.RED, gl.UNSIGNED_BYTE, null);
    gl.clearTexImage(self.color_texture, 0, gl.RGBA, gl.UNSIGNED_BYTE, null);
}

test "PackingState: first glyph placed at origin" {
    var s: PackingState = .init;
    const x, const y = try s.pack(8, 16, 1024, 1024);
    try testing.expectEqual(0, x);
    try testing.expectEqual(0, y);
    try testing.expectEqual(8, s.next_x);
    try testing.expectEqual(16, s.row_h);
}

test "PackingState: glyphs pack left-to-right on same shelf" {
    var s: PackingState = .init;
    _ = try s.pack(8, 16, 1024, 1024);
    const x, const y = try s.pack(8, 16, 1024, 1024);
    try testing.expectEqual(8, x);
    try testing.expectEqual(0, y);
}

test "PackingState: shelf advance when row overflows" {
    var s: PackingState = .init;
    _ = try s.pack(512, 16, 1024, 1024);
    _ = try s.pack(512, 16, 1024, 1024); // fills shelf exactly
    const x, const y = try s.pack(8, 16, 1024, 1024); // must go to next shelf
    try testing.expectEqual(0, x);
    try testing.expectEqual(16, y); // next_y = row_h of previous shelf
}

test "PackingState: row_height tracks tallest glyph on shelf" {
    var s: PackingState = .init;
    _ = try s.pack(8, 10, 1024, 1024);
    _ = try s.pack(8, 20, 1024, 1024); // taller
    _ = try s.pack(8, 5, 1024, 1024);

    try testing.expectEqual(20, s.row_h);
}

test "PackingState: glyph wider than atlas returns GlyphTooWide" {
    var s: PackingState = .init;
    try testing.expectError(error.GlyphTooWide, s.pack(1025, 16, 1024, 1024));
    // state must be unchanged after the error
    try testing.expectEqual(@as(u16, 0), s.next_x);
    try testing.expectEqual(@as(u16, 0), s.next_y);
}

test "PackingState: atlas full returns AtlasFull" {
    var s: PackingState = .init;
    _ = try s.pack(1024, 512, 1024, 1024); // first shelf, 512px tall
    _ = try s.pack(1024, 512, 1024, 1024); // second shelf, fills atlas
    try testing.expectError(error.AtlasFull, s.pack(8, 16, 1024, 1024));
}

test "hashSequence: same sequence produces same hash" {
    const cps = [_]u21{ 0x1F468, 0x200D, 0x1F469 };
    try testing.expectEqual(hashSequence(&cps, .emoji, .single), hashSequence(&cps, .emoji, .single));
}

test "hashSequence: order matters" {
    const a = [_]u21{ 0x41, 0x42 }; // A, B
    const b = [_]u21{ 0x42, 0x41 }; // B, A
    try testing.expect(hashSequence(&a, .emoji, .single) != hashSequence(&b, .emoji, .single));
}

test "hashSequence: different sequences differ" {
    const a = [_]u21{ 0x1F468, 0x200D, 0x1F469 };
    const b = [_]u21{ 0x1F469, 0x200D, 0x1F468 }; // reversed
    try testing.expect(hashSequence(&a, .emoji, .single) != hashSequence(&b, .emoji, .single));
}

test "hashSequence: single codepoint is stable" {
    const cps = [_]u21{0x1F600}; // 😀
    try testing.expectEqual(hashSequence(&cps, .emoji, .single), hashSequence(&cps, .emoji, .single));
}

test "hashSequence: length-1 vs length-2 differ" {
    const a = [_]u21{0x41};
    const b = [_]u21{ 0x41, 0x41 };
    try testing.expect(hashSequence(&a, .emoji, .single) != hashSequence(&b, .emoji, .single));
}

test "hashSequence: span is part of the key" {
    const cps = [_]u21{ 0x2764, 0xFE0F }; // ❤️
    try testing.expect(hashSequence(&cps, .emoji, .single) != hashSequence(&cps, .emoji, .double));
}
