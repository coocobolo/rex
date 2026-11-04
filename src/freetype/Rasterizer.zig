//! Loads the font faces through FreeType and rasterizes glyphs into
//! bitmaps for the atlas.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.rasterizer);

const Config = @import("Config.zig");
const ft = @import("root.zig");
const c = @import("root.zig").c;

test {
    _ = @import("rasterizer_test.zig");
}

pub const FaceKind = enum(u3) { regular, bold, italic, bold_italic, emoji };
pub const GlyphKind = enum { gray, color };

/// Number of grid cells a glyph is drawn across, taken from the cell
/// the terminal stored rather than recomputed from the codepoint, so
/// VS16 emoji, clusters and the ambiguous-width option match the grid.
pub const Span = enum(u1) { single, double };

/// Font-wide metrics in pixels, from the regular face. FreeType keeps
/// them in 26.6 fixed point (1/64 px); `ascender` and the cell size are
/// truncated to whole pixels, and the line positions and thicknesses
/// are rounded to whole pixels and kept inside the cell (see `Line.fit`).
pub const Metrics = struct {
    cell_width: u16,
    cell_height: u16,

    /// Baseline, down from the top of the cell.
    ascender: i16,

    /// Distance below the baseline, positive downward.
    descender: i16,

    /// Top of the underline, down from the top of the cell.
    underline_y: f32,
    underline_thickness: f32,

    /// Top of the strikethrough, down from the top of the cell.
    strikethrough_y: f32,
    strikethrough_thickness: f32,

    // No font metric exists for an overline: it sits at the top of the
    // cell, as thick as the underline.

    pub const empty: Metrics = .{
        .cell_width = 0,
        .cell_height = 0,
        .ascender = 0,
        .descender = 0,
        .underline_y = 0,
        .underline_thickness = 0,
        .strikethrough_y = 0,
        .strikethrough_thickness = 0,
    };
};

/// A horizontal line inside a cell, in whole pixels.
pub const Line = struct {
    /// Top of the line, down from the top of the cell.
    y: f32,
    thickness: f32,

    /// Rounds `top` and `thickness` to whole pixels, keeps the line at
    /// least 1 px thick and moves it up or down so it stays inside a
    /// cell `cell_height` pixels tall. A line thicker than the cell is
    /// clamped to the cell.
    pub fn fit(top: f32, thickness: f32, cell_height: u16) Line {
        const height: f32 = @floatFromInt(@max(cell_height, 1));
        const t = std.math.clamp(@round(thickness), 1.0, height);
        const y = std.math.clamp(@round(top), 0.0, height - t);
        return .{ .y = y, .thickness = t };
    }
};

/// One rasterized glyph: its bitmap and FreeType metrics.
pub const Glyph = struct {
    /// Gray glyphs point into FreeType's glyph slot, valid until the next
    /// rasterize on the same face. Color glyphs point into the scratch
    /// buffer, valid until the next rasterize of any glyph. Undefined
    /// when width or height is 0.
    bitmap: [*]const u8,

    /// Width of the bitmap in pixels.
    width: u16,
    /// Height of the bitmap in pixels.
    height: u16,

    /// Horizontal offset from the pen position to the bitmap.
    bearing_x: i16,
    /// Vertical offset from the baseline to the top of the bitmap.
    bearing_y: i16,

    /// Horizontal distance to advance the pen after drawing this glyph.
    advance: u16,

    /// Row stride in bytes, at least width times bytes per pixel. Rows
    /// run top-down: `rowPitch` rejects bottom-up bitmaps.
    pitch: u16,

    /// Bitmap format produced by the rasterizer.
    kind: GlyphKind,
};

const Rasterizer = @This();

library: c.FT_Library,

face: struct {
    bold: c.FT_Face,
    bold_italic: c.FT_Face,
    emoji: c.FT_Face,
    italic: c.FT_Face,
    regular: c.FT_Face,
},

/// Extra faces tried, in order, for code points the styled and emoji
/// faces lack.
fallback_faces: []c.FT_Face,

/// Width of a single glyph cell in pixels.
cell_width: u16,

/// Height of a single glyph cell in pixels.
cell_height: u16,

/// Distance from the baseline to the top of the tallest glyph.
ascender: i16,

metrics: Metrics,

/// Holds the scaled bitmap of the last color glyph.
scratch: std.ArrayListUnmanaged(u8),

pub const empty: Rasterizer = .{
    .ascender = 0,
    .cell_width = 0,
    .cell_height = 0,
    .library = undefined,
    .scratch = .empty,
    .fallback_faces = &.{},
    .metrics = .empty,
    .face = .{
        .bold = undefined,
        .bold_italic = undefined,
        .emoji = undefined,
        .italic = undefined,
        .regular = undefined,
    },
};

const VariableFontOption = struct {
    path: [*:0]const u8,
    width: u32,
    height: u32,
    weight_axis: f64,
};

fn initVariableFace(gpa: Allocator, lib: c.FT_Library, opt: VariableFontOption) !c.FT_Face {
    const face = try ft.initFace(lib, opt.path, opt.width, opt.height);
    errdefer ft.doneFace(face) catch {};

    if (ft.hasMM(face)) {
        const mm_var = try ft.getMMVar(lib, face);
        defer _ = c.FT_Done_MM_Var(lib, mm_var);
        try ft.setVarAxis(gpa, face, mm_var, .{ 'w', 'g', 'h', 't' }, opt.weight_axis);
    }

    return face;
}

/// Creates a Rasterizer and initializes FreeType faces for all font styles.
/// Also configures pixel sizes and computes shared font metrics.
pub fn create(gpa: Allocator, config: Config) !Rasterizer {
    var self: Rasterizer = .empty;

    self.scratch = try .initCapacity(gpa, 256);
    errdefer self.scratch.deinit(gpa);

    self.library = try ft.initFreeType();
    errdefer ft.doneFreeType(self.library) catch {};

    const font = config.font;
    const width = config.width;
    const height = config.height;

    if (font.family == .variable) {
        const variable_font = font.family.variable;
        inline for (std.enums.values(Config.FontStyle)) |style| {
            switch (style) {
                .regular => self.face.regular = try initVariableFace(
                    gpa,
                    self.library,
                    .{
                        .weight_axis = variable_font.regular_weight,
                        .path = variable_font.upright,
                        .width = width,
                        .height = height,
                    },
                ),
                .bold => self.face.bold = try initVariableFace(
                    gpa,
                    self.library,
                    .{
                        .weight_axis = variable_font.bold_weight,
                        .path = variable_font.upright,
                        .width = width,
                        .height = height,
                    },
                ),
                .italic => self.face.italic = try initVariableFace(
                    gpa,
                    self.library,
                    .{
                        .weight_axis = variable_font.regular_weight,
                        .path = variable_font.italic orelse variable_font.upright,
                        .width = width,
                        .height = height,
                    },
                ),
                .bold_italic => self.face.bold_italic = try initVariableFace(
                    gpa,
                    self.library,
                    .{
                        .weight_axis = variable_font.bold_weight,
                        .path = variable_font.italic orelse variable_font.upright,
                        .width = width,
                        .height = height,
                    },
                ),
            }
        }
    } else if (font.family == .static) {
        const static_font = font.family.static;

        self.face.regular = try ft.initFace(self.library, static_font.regular, width, height);
        errdefer ft.doneFace(self.face.regular) catch {};

        self.face.bold = try ft.initFace(self.library, static_font.bold, width, height);
        errdefer ft.doneFace(self.face.bold) catch {};

        self.face.italic = try ft.initFace(self.library, static_font.italic, width, height);
        errdefer ft.doneFace(self.face.italic) catch {};

        self.face.bold_italic = try ft.initFace(self.library, static_font.bold_italic, width, height);
        errdefer ft.doneFace(self.face.bold_italic) catch {};
    }

    if (font.emoji) |emoji| {
        self.face.emoji = try ft.initFace(self.library, emoji.path, width, height);
        errdefer ft.doneFace(self.face.emoji) catch {};
    }

    const regular = self.face.regular.*;
    const metrics = regular.size.*.metrics;

    self.ascender = std.math.cast(i16, metrics.ascender >> 6) orelse std.math.maxInt(i16);
    self.cell_height = std.math.cast(u16, metrics.height >> 6) orelse std.math.maxInt(u16);

    self.metrics.cell_height = self.cell_height;
    self.metrics.ascender = self.ascender;

    const scale = metrics.y_scale; // FT_Fixed 16.16
    const ascender_f: f32 = @floatFromInt(self.ascender);

    const descender_px: f32 = ft.fontUnitsToPixels(-regular.descender, scale);
    self.metrics.descender = @intFromFloat(@round(descender_px));

    // Underline from FT_Face. underline_position is the centre of the
    // line, negative below the baseline; underline_thickness is positive.
    const ul_thick_px = ft.fontUnitsToPixels(regular.underline_thickness, scale);
    const underline: Line = if (ul_thick_px > 0) .fit(
        ascender_f + ft.fontUnitsToPixels(-regular.underline_position, scale) - ul_thick_px * 0.5,
        ul_thick_px,
        self.cell_height,
    ) else .fit(ascender_f + 1.0, 1.0, self.cell_height);
    self.metrics.underline_y = underline.y;
    self.metrics.underline_thickness = underline.thickness;

    // Strikethrough, OS/2 table only. yStrikeoutPosition is the top of
    // the line, positive above the baseline.
    const os2: ?*c.TT_OS2 = @ptrCast(@alignCast(c.FT_Get_Sfnt_Table(self.face.regular, c.FT_SFNT_OS2)));
    const st_thick_px: f32 = if (os2) |os_2| ft.fontUnitsToPixels(os_2.yStrikeoutSize, scale) else 0;
    const strikethrough: Line = if (os2 != null and st_thick_px > 0) .fit(
        ascender_f - ft.fontUnitsToPixels(os2.?.yStrikeoutPosition, scale),
        st_thick_px,
        self.cell_height,
    ) else .fit(ascender_f * 0.6, underline.thickness, self.cell_height);
    self.metrics.strikethrough_y = strikethrough.y;
    self.metrics.strikethrough_thickness = strikethrough.thickness;

    // Fallback faces load at the primary font's size so their glyphs fit
    // the same cells. A fallback that fails to load is skipped.
    var fb_list: std.ArrayListUnmanaged(c.FT_Face) = .empty;
    errdefer {
        for (fb_list.items) |fb| ft.doneFace(fb) catch {};
        fb_list.deinit(gpa);
    }
    for (font.fallbacks) |spec| {
        const fb = ft.initFace(self.library, spec.path, width, height) catch |err| {
            log.warn("fallback font {s} failed to load: {}", .{ spec.path, err });
            continue;
        };
        try fb_list.append(gpa, fb);
    }
    self.fallback_faces = try fb_list.toOwnedSlice(gpa);

    // The cell width is the advance of 'M'. max_advance is not used
    // because it covers every glyph, combining marks and symbols too,
    // and can be a pixel wider than the text glyphs, which leaves gaps
    // that add up across a wide terminal.
    if (ft.loadChar(self.face.regular, 'M', c.FT_LOAD_DEFAULT)) {
        self.cell_width = @intCast(self.face.regular.*.glyph.*.advance.x >> 6);
        // In debug builds, warn when the font is not monospace. These
        // span the narrowest and widest glyphs of a proportional font.
        if (builtin.mode == .Debug) {
            const ref_advance = self.face.regular.*.glyph.*.advance.x;
            for ("iIlW0@") |ch| {
                ft.loadChar(self.face.regular, ch, c.FT_LOAD_DEFAULT) catch continue;
                const adv = self.face.regular.*.glyph.*.advance.x;
                if (adv != ref_advance) {
                    log.warn("font is not monospace: '{c}' advance={} != 'M' advance={}", .{
                        ch, adv >> 6, ref_advance >> 6,
                    });
                }
            }
        }
    } else |_| {
        log.warn("FT_Load_Char('M') failed, falling back to max_advance", .{});
        self.cell_width = @intCast(metrics.max_advance >> 6);
    }
    self.metrics.cell_width = self.cell_width;

    return self;
}

/// Frees all FreeType resources held by the Rasterizer.
pub fn destroy(self: *Rasterizer, gpa: Allocator) void {
    ft.doneFace(self.face.regular) catch {};
    ft.doneFace(self.face.italic) catch {};
    ft.doneFace(self.face.bold) catch {};
    ft.doneFace(self.face.bold_italic) catch {};
    ft.doneFace(self.face.emoji) catch {};

    for (self.fallback_faces) |fb| ft.doneFace(fb) catch {};
    gpa.free(self.fallback_faces);
    self.scratch.deinit(gpa);
    ft.doneFreeType(self.library) catch {};
}

/// Rasterizes `codepoint` in the `kind` face, or the first face that
/// has it, and returns its bitmap and metrics. Color glyphs are scaled
/// to fit `span` cells. See `Glyph.bitmap` for how long the bitmap
/// stays valid.
pub fn rasterize(self: *Rasterizer, gpa: Allocator, codepoint: u21, kind: FaceKind, span: Span) !Glyph {
    const face, const is_color = self.findFace(codepoint, kind);

    // Color faces render BGRA bitmaps; text uses light hinting.
    const flags: c.FT_Int32 = if (is_color)
        c.FT_LOAD_COLOR | c.FT_LOAD_RENDER
    else
        c.FT_LOAD_RENDER | c.FT_LOAD_TARGET_LIGHT;

    try ft.loadChar(face, codepoint, flags);

    const glyph = face.*.glyph;
    const bmp = glyph.*.bitmap;

    // Only 8-bit gray and BGRA can be uploaded. Bitmap fonts can give
    // FT_PIXEL_MODE_MONO (1 bit per pixel), which would upload as garbage.
    if (!is_color and bmp.pixel_mode != @as(u8, c.FT_PIXEL_MODE_GRAY)) return error.UnsupportedPixelMode;
    if (is_color and bmp.pixel_mode != @as(u8, c.FT_PIXEL_MODE_BGRA)) return error.UnsupportedPixelMode;

    const advance: u16 = std.math.cast(u16, glyph.*.advance.x >> 6) orelse self.cell_width;

    // Glyphs with no ink (space, some combining marks) have a null
    // buffer. Return just the advance; there is nothing to upload.
    if (bmp.width == 0 or bmp.rows == 0) {
        return .{
            .advance = advance,
            .bitmap = undefined,
            .bearing_x = 0,
            .bearing_y = 0,
            .height = 0,
            .kind = .gray,
            .pitch = 0,
            .width = 0,
        };
    }

    const bmp_width = std.math.cast(u16, bmp.width) orelse return error.GlyphTooLarge;
    const bmp_rows = std.math.cast(u16, bmp.rows) orelse return error.GlyphTooLarge;
    const pitch = try rowPitch(bmp.pitch);

    const bearing_x = std.math.cast(i16, glyph.*.bitmap_left) orelse 0;
    const bearing_y = std.math.cast(i16, glyph.*.bitmap_top) orelse 0;

    if (is_color) {
        // Scale emoji proportionally to fit the cells it spans.
        const max_w: u16 = switch (span) {
            .single => self.cell_width,
            .double => self.cell_width * 2,
        };
        const max_h: u16 = self.cell_height;

        const scale_by_w = @as(f32, @floatFromInt(max_w)) / @as(f32, @floatFromInt(bmp_width));
        const scale_by_h = @as(f32, @floatFromInt(max_h)) / @as(f32, @floatFromInt(bmp_rows));

        const scale = @min(scale_by_w, scale_by_h);

        const dst_w: u16 = @max(1, @as(u16, @intFromFloat(@round(@as(f32, @floatFromInt(bmp_width)) * scale))));
        const dst_h: u16 = @max(1, @as(u16, @intFromFloat(@round(@as(f32, @floatFromInt(bmp_rows)) * scale))));

        try self.scratch.resize(
            gpa,
            @as(usize, dst_w) * @as(usize, dst_h) * 4,
        );

        const x_pad: i16 = @intCast((max_w - dst_w) / 2);
        const y_pad: i16 = @intCast((max_h - dst_h) / 2);

        scaleDownBgraArea(
            @ptrCast(bmp.buffer),
            self.scratch.items.ptr,
            bmp_width,
            bmp_rows,
            pitch,
            dst_w,
            dst_h,
        );

        return .{
            .advance = dst_w,
            .bearing_x = x_pad,
            .bearing_y = @as(i16, @intCast(self.ascender)) - y_pad,
            .bitmap = self.scratch.items.ptr,
            .width = dst_w,
            .height = dst_h,
            .pitch = dst_w * 4,
            .kind = .color,
        };
    }

    return .{
        .advance = advance,
        .bearing_x = bearing_x,
        .bearing_y = bearing_y,
        .bitmap = @ptrCast(bmp.buffer),
        .height = bmp_rows,
        .kind = .gray,
        .pitch = pitch,
        .width = bmp_width,
    };
}

/// The row stride of a FreeType bitmap whose `FT_Bitmap.pitch` is
/// `ft_pitch`. A negative pitch means the rows run bottom-up, which
/// FT_LOAD_RENDER never produces and the atlas cannot upload, so it is
/// rejected rather than drawn upside down.
pub fn rowPitch(ft_pitch: c_int) error{ BottomUpBitmap, GlyphTooLarge }!u16 {
    if (ft_pitch < 0) return error.BottomUpBitmap;
    return std.math.cast(u16, ft_pitch) orelse error.GlyphTooLarge;
}

/// Returns the first face that has `codepoint`, trying the `kind` face,
/// then the emoji face, then each fallback, and whether it is a color
/// (BGRA) face. Falls back to the regular face, which draws .notdef.
fn findFace(self: *Rasterizer, codepoint: u21, kind: FaceKind) struct { c.FT_Face, bool } {
    const primary = self.faceFromKind(kind);
    if (c.FT_Get_Char_Index(primary, codepoint) != 0) {
        return .{ primary, c.FT_HAS_COLOR(primary) };
    }

    // Try emoji face next (covers most Unicode symbols too)
    if (c.FT_Get_Char_Index(self.face.emoji, codepoint) != 0) {
        return .{ self.face.emoji, c.FT_HAS_COLOR(self.face.emoji) };
    }

    for (self.fallback_faces) |fb| {
        if (c.FT_Get_Char_Index(fb, codepoint) != 0)
            return .{ fb, c.FT_HAS_COLOR(fb) };
    }

    // The regular face's .notdef box at least has the right size.
    return .{ self.face.regular, false };
}

/// Rasterizes a multi-code-point grapheme cluster. Without shaping
/// (HarfBuzz) this draws only the first code point, so a ZWJ sequence
/// such as WOMAN + ZWJ + PERSONAL COMPUTER shows just the woman.
pub fn rasterizeSequence(self: *Rasterizer, gpa: Allocator, cps: []const u21, face: FaceKind, span: Span) !Glyph {
    if (cps.len == 0) return error.EmptySequence;
    return self.rasterize(gpa, cps[0], face, span);
}

fn faceFromKind(self: *Rasterizer, kind: FaceKind) c.FT_Face {
    return switch (kind) {
        .bold_italic => self.face.bold_italic,
        .bold => self.face.bold,
        .emoji => self.face.emoji,
        .italic => self.face.italic,
        .regular => self.face.regular,
    };
}

/// Scales a premultiplied BGRA bitmap down to `dst_w` by `dst_h` with
/// an area average: each destination pixel is the mean of the source
/// pixels it covers, weighted by overlap. `dst` is tightly packed.
fn scaleDownBgraArea(
    // zig fmt: off
    src: [*]const u8,
    dst: [*]u8,
    src_w: u16, src_h: u16, src_pitch: u16,
    dst_w: u16, dst_h: u16,
    // zig fmt: on
) void {
    const sw: f32 = @floatFromInt(src_w);
    const sh: f32 = @floatFromInt(src_h);
    const dw: f32 = @floatFromInt(dst_w);
    const dh: f32 = @floatFromInt(dst_h);

    for (0..@as(usize, dst_h)) |dy| {
        for (0..@as(usize, dst_w)) |dx| {
            // source region this dst pixel covers
            const x0 = @as(f32, @floatFromInt(dx)) * sw / dw;
            const x1 = @as(f32, @floatFromInt(dx + 1)) * sw / dw;
            const y0 = @as(f32, @floatFromInt(dy)) * sh / dh;
            const y1 = @as(f32, @floatFromInt(dy + 1)) * sh / dh;

            var acc: [4]f32 = .{ 0, 0, 0, 0 };
            var weight_sum: f32 = 0;

            const ix0: usize = @intFromFloat(@floor(x0));
            const ix1: usize = @min(@as(usize, src_w), @as(usize, @intFromFloat(@ceil(x1))));
            const iy0: usize = @intFromFloat(@floor(y0));
            const iy1: usize = @min(@as(usize, src_h), @as(usize, @intFromFloat(@ceil(y1))));

            for (iy0..iy1) |sy| {
                const wy = @min(@as(f32, @floatFromInt(sy + 1)), y1) - @max(@as(f32, @floatFromInt(sy)), y0);
                for (ix0..ix1) |sx| {
                    const wx = @min(@as(f32, @floatFromInt(sx + 1)), x1) - @max(@as(f32, @floatFromInt(sx)), x0);
                    const w = wx * wy;
                    const si = sy * @as(usize, src_pitch) + sx * 4;
                    for (0..4) |ch| acc[ch] += @as(f32, @floatFromInt(src[si + ch])) * w;
                    weight_sum += w;
                }
            }

            const di = (dy * @as(usize, dst_w) + dx) * 4;
            for (0..4) |ch| dst[di + ch] = @intFromFloat(@round(acc[ch] / weight_sum));
        }
    }
}
