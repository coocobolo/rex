const std = @import("std");

const ft = @cImport({
    @cInclude("freetype/freetype.h");
});

pub const ATLAS_W: usize = 1024;
pub const ATLAS_H: usize = 1024;

const AtlasPos = struct { x: u16, y: u16 };

pub const GlyphKey = struct {
    codepoint: u21,
    size_px: u16,
    // add bold/italic flags later when we support font variants
};

pub const GlyphEntry = struct {
    atlas_x: u16,
    atlas_y: u16,
    width: u16, // 0 for whitespace glyphs (space, tab)
    height: u16,
    bearing_x: i16, // bitmap_left (pixels right of pen origin)
    bearing_y: i16, // bitmap_top (pixels above baseline)
    advance: u16, // horizontal advance in pixels (advance.x >> 6)
};

/// Blend `fg` over `bg` using `alpha` (0 = fully transparent, 255 = fully opaque).
/// Pixel format: 0x00RRGGBB (high byte ignored / zero).
pub fn alphaBlend(fg: u32, bg: u32, alpha: u8) u32 {
    if (alpha == 0) return bg;
    if (alpha == 255) return fg;

    const a: u32 = alpha;
    const ia: u32 = 255 - a;

    const r = ((fg >> 16 & 0xFF) * a + (bg >> 16 & 0xFF) * ia + 127) / 255;
    const g = ((fg >> 8 & 0xFF) * a + (bg >> 8 & 0xFF) * ia + 127) / 255;
    const b = ((fg & 0xFF) * a + (bg & 0xFF) * ia + 127) / 255;

    return (r << 16) | (g << 8) | b;
}

pub const GlyphCache = struct {
    library: ft.FT_Library,
    face: ft.FT_Face,
    size_px: u16,

    // Metrics derived from FT_Size_Metrics after FT_Set_Pixel_Sizes.
    // All values are in pixels (26.6 fixed-point already shifted right by 6).
    /// pixels above baseline  (always >= 0)
    ascender: u16,
    /// pixels below baseline  (abs value; metrics.descender is negative)
    descender: u16,
    /// ascender + descender + line gap  (metrics.height >> 6)
    line_height: u16,
    /// cell width for monospace fonts   (max_advance >> 6)
    advance: u16,

    // Grayscale atlas (1024×1024 = 1 MB), enough for ~10k glyphs at 8×16
    // atlas: [1024][1024]u8 = std.mem.zeroes([1024][1024]u8),
    map: std.AutoHashMap(GlyphKey, GlyphEntry),
    atlas: []u8, // grayscale coverage, 0=transparent

    // Shelf-packing state for the atlas
    pack_x: u16 = 0,
    pack_y: u16 = 0,
    row_h: u16 = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        font_path: [*:0]const u8,
        size_px: u16,
    ) !GlyphCache {
        var library: ft.FT_Library = undefined;
        if (ft.FT_Init_FreeType(&library) != 0) {
            return error.FtInitFailed;
        }
        errdefer _ = ft.FT_Done_FreeType(library);

        var face: ft.FT_Face = undefined;
        if (ft.FT_New_Face(library, font_path, 0, &face) != 0) {
            _ = ft.FT_Done_FreeType(library);
            return error.FtNewFaceFailed;
        }
        errdefer _ = ft.FT_Done_Face(face);

        const atlas = try allocator.alloc(u8, ATLAS_W * ATLAS_H);
        errdefer allocator.free(atlas);
        @memset(atlas, 0);

        var cache: GlyphCache = .{
            .library = library,
            .face = face,
            .size_px = size_px,
            .ascender = 0,
            .descender = 0,
            .line_height = 0,
            .advance = 0,
            .map = std.AutoHashMap(GlyphKey, GlyphEntry).init(allocator),
            .atlas = atlas,
        };

        try cache.applySize(size_px);
        return cache;
    }

    pub fn deinit(self: *GlyphCache, allocator: std.mem.Allocator) void {
        _ = ft.FT_Done_Face(self.face);
        _ = ft.FT_Done_FreeType(self.library);
        self.map.deinit();
        allocator.free(self.atlas);
    }

    // sync changed font size, flush cache
    pub fn resize(self: *GlyphCache, new_size_px: u16) !void {
        self.map.clearRetainingCapacity();
        @memset(self.atlas, 0);
        self.pack_x = 0;
        self.pack_y = 0;
        self.row_h = 0;
        try self.applySize(new_size_px);
    }

    /// set FT size and read back metrics
    fn applySize(self: *GlyphCache, size_px: u16) !void {
        if (ft.FT_Set_Pixel_Sizes(self.face, 0, size_px) != 0) {
            return error.FtSetSizeFailed;
        }

        self.size_px = size_px;
        const m = self.face.*.size.*.metrics;

        // FT_Size_Metrics values are in 26.6 fixed-point; shift right by 6.
        // ascender is positive, descender is negative in FreeType convention.
        self.ascender = @intCast(m.ascender >> 6);
        self.descender = @intCast(-(m.descender >> 6)); // make positive
        self.line_height = @intCast(m.height >> 6);
        self.advance = @intCast(m.max_advance >> 6);
    }

    /// packGlyph
    ///
    /// Atlas Shelf packing: fill left-to-right, start a new shelf when the row is full.
    /// Returns the top-left corner in atlas coordinates.
    ///
    ///  ┌────────────────────────────────────────┐
    ///  │ A  B  C  D  E  F  G  H  I  J  K  L  M  │ <- shelf 0 (row_h = tallest glyph)
    ///  │ N  O  P  Q  R  S  T  U  V  W  X  Y  Z  │ <- shelf 1
    ///  │ ...                               ...  │
    ///  └────────────────────────────────────────┘
    fn packGlyph(self: *GlyphCache, w: u16, h: u16) ?AtlasPos {
        const pad: u16 = 1; // 1-pixel gap between glyphs

        // Advance to next shelf if the glyph doesn't fit on the current one.
        if (@as(usize, self.pack_x) + w + pad > ATLAS_W) {
            self.pack_y += self.row_h + pad;
            self.pack_x = 0;
            self.row_h = 0;
        }

        // Check vertical overflow.
        if (@as(usize, self.pack_y) + h > ATLAS_H) return null;

        const pos = AtlasPos{ .x = self.pack_x, .y = self.pack_y };
        self.pack_x += w + pad;
        if (h > self.row_h) self.row_h = h;
        return pos;
    }

    /// Lookup rasterisation
    /// Returns a cached GlyphEntry, rasterizing on first use.
    /// Whitespace glyphs (space, etc.) have width=0/height=0 and are stored
    /// with atlas_x=atlas_y=0 — callers must check width before blitting.
    pub fn getGlyph(self: *GlyphCache, key: GlyphKey) !GlyphEntry {
        if (self.map.get(key)) |entry| return entry;

        // Rasterise.  FT_Set_Pixel_Sizes is already set to key.size_px via
        // applySize; only call it again if the caller requests a different size
        // (shouldn't happen in normal use, but guard anyway).
        // Slow path: rasterize once
        if (key.size_px != self.size_px) {
            if (ft.FT_Set_Pixel_Sizes(self.face, 0, key.size_px) != 0)
                return error.FtSetSizeFailed;
        }

        const flags = ft.FT_LOAD_RENDER | ft.FT_LOAD_TARGET_NORMAL;
        if (ft.FT_Load_Char(self.face, key.codepoint, flags) != 0) {
            // Unsupported codepoint — return a zero-size sentinel.
            const empty = GlyphEntry{
                .atlas_x = 0,
                .atlas_y = 0,
                .width = 0,
                .height = 0,
                .bearing_x = 0,
                .bearing_y = 0,
                .advance = self.advance,
            };
            try self.map.put(key, empty);
            return empty;
        }

        const slot = self.face.*.glyph;
        const bmp = slot.*.bitmap;
        const w: u16 = @intCast(bmp.width);
        const h: u16 = @intCast(bmp.rows);

        var entry: GlyphEntry = .{
            .atlas_x = 0,
            .atlas_y = 0,
            .width = w,
            .height = h,
            .bearing_x = @intCast(slot.*.bitmap_left),
            .bearing_y = @intCast(slot.*.bitmap_top),
            .advance = @intCast(slot.*.advance.x >> 6),
        };

        if (w > 0 and h > 0) {
            const pos = self.packGlyph(w, h) orelse {
                // Atlas full — clear and retry once.
                self.map.clearRetainingCapacity();
                @memset(self.atlas, 0);
                self.pack_x = 0;
                self.pack_y = 0;
                self.row_h = 0;
                // Re-rasterise (FT_Load_Char result is still valid in slot).
                entry.atlas_x = 0;
                entry.atlas_y = 0;
                const pos2 = self.packGlyph(w, h) orelse return error.AtlasFull;
                entry.atlas_x = pos2.x;
                entry.atlas_y = pos2.y;
                self.copyBitmap(bmp, pos2.x, pos2.y);
                try self.map.put(key, entry);
                return entry;
            };
            entry.atlas_x = pos.x;
            entry.atlas_y = pos.y;
            self.copyBitmap(bmp, pos.x, pos.y);
        }

        try self.map.put(key, entry);
        return entry;
    }

    /// Bitmap copy into atlas
    fn copyBitmap(
        self: *GlyphCache,
        bmp: ft.FT_Bitmap,
        ax: u16,
        ay: u16,
    ) void {
        const w: usize = bmp.width;
        const h: usize = bmp.rows;
        // bmp.pitch may be larger than bmp.width (FreeType row alignment).
        const pitch: usize = @abs(bmp.pitch);

        for (0..h) |row| {
            const src_off = row * pitch;
            const dst_off = (@as(usize, ay) + row) * ATLAS_W + ax;
            @memcpy(
                self.atlas[dst_off..][0..w],
                bmp.buffer[src_off..][0..w],
            );
        }
    }

    /// Blit one terminal cell into `fb` (BGRX u32 framebuffer, row-major).
    /// `fb_w` is the framebuffer stride in pixels (= window pixel width).
    pub fn blitCell(
        self: *GlyphCache,
        cp: u21,
        fb: []u32,
        fb_w: u32,
        cell_x: u32,
        cell_y: u32,
        cell_w: u32,
        cell_h: u32,
        fg: u32,
        bg: u32,
    ) !void {
        // TODO Fill background.
        for (0..cell_h) |r| {
            const off = (cell_y + r) * fb_w + cell_x;
            if (off + cell_w <= fb.len)
                @memset(fb[off..][0..cell_w], bg);
        }

        const g = try self.getGlyph(.{ .codepoint = cp, .size_px = self.size_px });
        if (g.width == 0 or g.height == 0) return;

        // Blit with alpha blend.
        // baseline_y = top of cell + ascender (pixels above baseline).
        const baseline_y: i32 = @as(i32, @intCast(cell_y)) + @as(i32, self.ascender);

        for (0..g.height) |row| {
            for (0..g.width) |col| {
                const coverage = self.atlas[
                    (@as(usize, g.atlas_y) + row) * ATLAS_W + @as(usize, g.atlas_x) + col
                ];
                if (coverage == 0) continue;

                const px_i: i32 =
                    @as(i32, @intCast(cell_x)) +
                    @as(i32, g.bearing_x) +
                    @as(i32, @intCast(col));

                const py_i: i32 =
                    baseline_y -
                    @as(i32, g.bearing_y) +
                    @as(i32, @intCast(row));

                // Skip pixels outside the framebuffer.
                if (px_i < 0 or py_i < 0) continue;

                const px: u32 = @intCast(px_i);
                const py: u32 = @intCast(py_i);
                const idx = py * fb_w + px;
                if (idx < fb.len)
                    fb[idx] = alphaBlend(fg, bg, coverage);
            }
        }
    }
};