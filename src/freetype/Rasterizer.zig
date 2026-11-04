const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.rasterizer);

const Config = @import("Config.zig");
const ft = @import("root.zig");
const c = @import("root.zig").c;
const wcwidth = @import("../unicode/wcwidth.zig").wcwidth;

test {
    _ = @import("rasterizer_test.zig");
}

pub const FaceKind = enum(u3) { regular, bold, italic, bold_italic, emoji };
pub const GlyphKind = enum { gray, color };

/// FreeType stores all metrics internally in 26.6 fixed point, the top 26 bits
/// are the integer pixel part, the bottom 6 bits are the fractional part
/// (1/64th pixel precision).
///
/// raw value 2112 (26.6 fixed point)
/// integer   2112 >> 6   = 33 (pixels, truncated)
/// float     2112 / 64.0 = 33.0 (exact, but happens to be whole here)
///
/// raw value 2124 (26.6 fixed point)
/// integer   2124 >> 6   = 33 (pixels, truncated, lost 12/64 = 0.1875 px)
/// float     2124 / 64.0 = 33.1875 (sub-pixel preserved)
///
/// When we compute ascender as i16, means doing "x >> 6" (or equivalent integer
/// division), which truncates the fractional part. The shader receives 33.0 instead
/// of 33.1875.
///
/// The bearing_offset calculation becomes:
/// // u_ascender  = 33.0 (truncated)
/// // a_bearing.y = 28 (integer, from FreeType bitmap metrics)
/// u_ascender - float(a_bearing.y) = 33.0 - 28.0 = 5.0 // glyph top is 5px bellow cell top
///
/// With sub-pixel ascender:
/// u_ascender - float(a_bearing.y) = 33.1875 - 28.0 = 5.1875 // glyph top is 5.1875 bellow cell top
///
/// What the difference looks like visually,
pub const Metrics = struct {
    // Cell dimensions
    cell_width: u16,
    cell_height: u16,

    // Baseline position from top of cell (pixels, positive downward)
    // equals to ascender in cell-local coordinates.
    ascender: i16,

    // Pixels below baseline (positive = downward). Typically 1–4px.
    descender: i16,

    // Underline: y from top of cell (pixels), positive downward
    // = ascender + underline_position (where ul_pos is positive below baseline)
    underline_y: f32,
    underline_thickness: f32,

    // Strikethrough: y from top of cell (pixels), positive downward
    strikethrough_y: f32,
    strikethrough_thickness: f32,

    // Overline: always 0.0 (top of cell) — no font metric for this
    // Derived: overline_y = 0.0, thickness = underline_thickness

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

pub const Glyph = struct {
    /// For .gray glyphs: owned by FreeType, valid until the next rasterize() call on the same face.
    /// For .color glyphs: points into the rasterizer's scratch buffer, valid until the next rasterize() call (any glyph).
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

    /// Row stride in bytes (may differ from width for padded bitmaps).
    /// Always positive (FT_LOAD_RENDER produces top-down bitmaps).
    pitch: u16,

    /// Bitmap format produced by the rasterizer.
    kind: GlyphKind,
};

/// Loads font faces through FreeType and rasterizes glyphs into bitmap data
/// that can be stored in a texture atlas and rendered by the graphics system.
const Rasterizer = @This();

library: c.FT_Library,

face: struct {
    bold: c.FT_Face,
    bold_italic: c.FT_Face,
    emoji: c.FT_Face,
    italic: c.FT_Face,
    regular: c.FT_Face,
},

fallback_faces: []c.FT_Face,

/// Width of a single glyph cell in pixels.
cell_width: u16,

/// Height of a single glyph cell in pixels.
cell_height: u16,

/// Distance from the baseline to the top of the tallest glyph.
ascender: i16,

metrics: Metrics,

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

fn initStyledFace(gpa: Allocator, lib: c.FT_Library, spec: Config.FontSpec, width: u32, height: u32) !c.FT_Face {
    const face = try ft.initFace(lib, spec.path, width, height);
    errdefer ft.doneFace(face) catch {};

    if (spec.weight_axis) |w| {
        if (ft.hasMM(face)) {
            const mm_var = try ft.getMMVar(lib, face);
            defer _ = c.FT_Done_MM_Var(lib, mm_var);
            try ft.setVarAxis(gpa, face, mm_var, .{ 'w', 'g', 'h', 't' }, w);
        }
    }

    return face;
}

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

    self.metrics.cell_height = std.math.cast(u16, metrics.height >> 6) orelse std.math.maxInt(u16);
    self.metrics.ascender = std.math.cast(i16, metrics.descender) orelse std.math.maxInt(i16);

    const scale = metrics.y_scale; // FT_Fixed 16.16
    const ascender_f: f32 = @floatFromInt(self.ascender);

    const descender_px: f32 = ft.fontUnitsToPixels(-regular.descender, scale);
    self.metrics.descender = @intFromFloat(@round(descender_px));

    // Underline from FT_Face
    const ul_pos_px = ft.fontUnitsToPixels(-regular.underline_position, scale);
    const ul_thick_px = ft.fontUnitsToPixels(-regular.underline_thickness, scale);

    if (ul_thick_px > 0) {
        self.metrics.underline_y = ascender_f + ul_pos_px - ul_thick_px * 0.5;
        self.metrics.underline_thickness = @max(1.0, ul_thick_px);
    } else {
        self.metrics.underline_y = ascender_f + 1.0;
        self.metrics.underline_thickness = 1.0;
    }

    // Strikethrough, OS/2 table only
    const os2: ?*c.TT_OS2 = @ptrCast(@alignCast(c.FT_Get_Sfnt_Table(self.face.regular, c.FT_SFNT_OS2)));
    if (os2) |os_2| {
        const st_pos_px = ft.fontUnitsToPixels(os_2.yStrikeoutPosition, scale);
        const st_thick_px = ft.fontUnitsToPixels(os_2.yStrikeoutSize, scale);
        self.metrics.strikethrough_y = ascender_f - st_pos_px - st_thick_px * 0.5;
        self.metrics.strikethrough_thickness = @max(1.0, st_thick_px);
    } else {
        self.metrics.strikethrough_y = ascender_f * 0.6;
        self.metrics.strikethrough_thickness = self.metrics.underline_thickness;
    }

    // NOTE Fallback faces are loaded at the same pixel_height as the primary font,
    // so glyph metrics stay consistent.
    // Load fallback faces (best-effort: skip any that fail to load)
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

    // self.cell_width = @intCast(metrics.max_advance >> 6);
    //
    // About cell_width from max_advance vs glyph advance
    // metrics.max_advance is the maximum advance across all glyphs.
    // For a monospace font this equals every glyph's advance. So it's
    // correct. But if we ever load a proportional fallback font by
    // mistake, max_advance will be larger than the actual width.
    // Using FT_LoadChar(face, 'M', FT_LOAD_DEFAULT) and reading
    // glyph->advance.x >> 6 is more explicit intent, but max_advance
    // is fine for a monospace terminal font ONLY. But the problem is we are not.

    // WTF NOT max_advance value?
    // it includes glyphs like combining marks or special symbols
    // that may have a larger advance than the regular text glyphs.
    // On some fonts it can be 1px wider than the actual character
    // advance, which causes a 1px gap between cells that accumulates
    // visibly across a wide terminal.

    // 'M' vs '0'
    // Both are fine for monospace fonts. Some terminal (xterm, st) use
    // '0' because it's digit and less likely to be affected by font
    // hinting quirks.

    // Derive cell_width from a reference glyph advance.
    // 'M' is the conventional reference (em-width), but any ASCII
    // printable character works for a monospace font.
    if (ft.loadChar(self.face.regular, 'M', c.FT_LOAD_DEFAULT)) {
        self.cell_width = @intCast(self.face.regular.*.glyph.*.advance.x >> 6);
        // In debug builds, assert the font is actually monospace by spot-checking a few characters
        if (builtin.mode == .Debug) {
            const ref_advance = self.face.regular.*.glyph.*.advance.x;

            // The characters iIlW0@ are chosen because they span the extremes,
            // 'i' and 'l' are the narrowest in proportional fonts, 'W' and 'M'
            // are the widest. If they all have the same advance, the font is monospace.

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

/// Rasterizes a codepoint using the requested font face and returns
/// the resulting glyph bitmap and metrics.
///
/// The returned bitmap is owned by FreeType and remains valid only
/// until the next rasterize() call on the same face.
pub fn rasterize(self: *Rasterizer, gpa: Allocator, codepoint: u21, kind: FaceKind) !Glyph {
    const face, const is_color = self.findFace(codepoint, kind);

    // load flags depend on whether this is an emoji face which requires color texture
    //
    // NOTE FT_HAS_COLOR is a C macro defined as ((face)->face_flags & FT_FACE_FLAG_COLOR).
    // Zig may or may not translate it depending on your translate-c setup.
    // If it doesn't compile, use the flag directly
    // const is_color = key.face == .emoji and (face.*.face_flags & c.FT_FACE_FLAG_COLOR) != 0;
    const flags: c.FT_Int32 = if (is_color)
        c.FT_LOAD_COLOR | c.FT_LOAD_RENDER
    else
        // c.FT_LOAD_RENDER | c.FT_LOAD_TARGET_NORMAL;
        c.FT_LOAD_RENDER | c.FT_LOAD_TARGET_LIGHT; // FT_LOAD_DEFAULT is 0, so FT_LOAD_RENDER alone is equivalent.

    try ft.loadChar(face, codepoint, flags);

    const glyph = face.*.glyph;
    const bmp = glyph.*.bitmap;

    // FreeType can produce different pixel modes. FT_LOAD_RENDER normally gives
    // FT_PIXEL_MODE_GRAY, but bitmap fonts can give FT_PIXEL_MODE_MONO (1-bit).
    // Uploading mono data as GL_RED will produce garbage.
    if (!is_color and bmp.pixel_mode != @as(u8, c.FT_PIXEL_MODE_GRAY)) return error.UnsupportedPixelMode;
    if (is_color and bmp.pixel_mode != @as(u8, c.FT_PIXEL_MODE_BGRA)) return error.UnsupportedPixelMode;

    const advance: u16 = std.math.cast(u16, glyph.*.advance.x >> 6) orelse self.cell_width;

    // Zero-size bitmap (space character) bmp.buffer is null for
    // glyphs with no ink/pixels to upload (e.g., space, combining marks).
    // glTexSubImage2D with a null pointer crashes.
    // Still return a valid metric so the caller can advance the cursor correctly.
    if (bmp.width == 0 or bmp.rows == 0) {
        // bearing_x/y are irrelevant when there is no bitmap to draw.
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
    const pitch = std.math.cast(u16, @abs(bmp.pitch)) orelse return error.GlyphTooLarge;

    const bearing_x = std.math.cast(i16, glyph.*.bitmap_left) orelse 0;
    const bearing_y = std.math.cast(i16, glyph.*.bitmap_top) orelse 0;

    if (is_color) {
        // Scale emoji proportionally to fit the terminal cell height.
        // const scale = @as(f32, @floatFromInt(self.cell_height)) / @as(f32, @floatFromInt(bmp_rows));

        const is_wide = wcwidth(codepoint, .narrow) == .wide;
        const max_w: u16 = if (is_wide) self.cell_width * 2 else self.cell_width;
        const max_h: u16 = self.cell_height;

        const scale_by_w = @as(f32, @floatFromInt(max_w)) / @as(f32, @floatFromInt(bmp_width));
        const scale_by_h = @as(f32, @floatFromInt(max_h)) / @as(f32, @floatFromInt(bmp_rows));

        const scale = @min(scale_by_w, scale_by_h);

        const dst_w: u16 = @max(1, @as(u16, @intFromFloat(@round(@as(f32, @floatFromInt(bmp_width)) * scale))));
        const dst_h: u16 = @max(1, @as(u16, @intFromFloat(@round(@as(f32, @floatFromInt(bmp_rows)) * scale))));

        // const dst_w: u16 = if (is_wide) self.cell_width * 2 else self.cell_width;
        // const dst_h: u16 = self.cell_height;

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

/// Returns the best FT_Face for the given codepoint, falling back from
/// the requested kind -> emoji -> regular if the glyph is missing.
/// Also returns whether the chosen face is a color (BGRA) face.
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

    // Fall back to regular renders .notdef tofu, but at least it's the right size
    return .{ self.face.regular, false };
}

pub const SequenceKind = enum {
    /// Base + emoji modifier(s) (Fitzpatrick skin tone) and/or VS15/VS16.
    /// e.g. [WAVING_HAND, SKIN_TONE_MEDIUM]
    modifier_sequence,
    /// Contains at least one ZWJ (U+200D) joining pictographs.
    /// e.g., [WOMAN, ZWJ, COMPUTER]
    zwj_sequence,
    /// Exactly two Regional inidicator codepoints (flag).
    regional_pair,
    /// Anything else that ended up in the multi-codepoint grapheme path
    /// (e.g, base + combining marks that are not emoji related).
    unknown,
};

const zwj: u21 = 0x200D; // zero width joiner
const vs15: u21 = 0xFE0E; // text presentation selector
const vs16: u21 = 0xFE0F; // emoji presentation selector

inline fn isSkinToneModifier(cp: u21) bool {
    // Fitzpatrick types 1-2 .. 6
    return cp >= 0x1F3FB and cp <= 0x1F3FF;
}

fn isRegionalIndicator(cp: u21) bool {
    return cp >= 0x1F1E6 and cp <= 0x1F1FF;
}

/// NOTE! from this design:
/// 1. Order maters: check regional_pair first since its a fixed-shape, fully
/// enumarable case (always exactly 2 codepoints).
/// 2. ZWJ takes priority over modifier when both appear (e.g., 👩🏽‍💻 = WOMAN + SKIN_TONE + ZWJ +
/// COMPUTER is still fundamentally a ZWJ sequence problem, not just "base + modifier").
/// 3. VS15/VS16 are deliberately inert here, they only affect presentation stlye (text
/// vs emoji glyph), not composition, so they should not force a sequence into .zwj_sequence/
/// .modifier_sequence on their own if thats all thats presnt alongside the base.
/// 4. the assert cps.len >= 2 since single-codepoint grapheme entries should never reach
/// rasterizeSequence(), if they can, drop that assert and add a cps.len == 1 => .unknown early
/// return instaead.
pub fn classifySequence(cps: []const u21) SequenceKind {
    std.debug.assert(cps.len >= 2); // single-cp shouldn't reach here

    // Regional indicator flag pair: exactly two RI codepoints, nothing else.
    if (cps.len == 2 and isRegionalIndicator(cps[0]) and isRegionalIndicator(cps[1])) {
        return .regional_pair;
    }

    var has_zwj = false;
    var has_modifier = false;

    for (cps[1..]) |cp| {
        switch (cp) {
            zwj => has_zwj = true,
            vs15, vs16 => {}, // presentation selector: doesn't change classification
            else => if (isSkinToneModifier(cp)) {
                has_modifier = true;
            },
        }
    }

    if (has_zwj) return .zwj_sequence;
    if (has_modifier) return .modifier_sequence;
    return .unknown;
}

/// Rasterizes a ZWJ sequence.
///
/// Without HarfBuzz, falls back to the base codepoint (cps[0]).
/// This renders the first emoji in the sequence rather than the
/// composed form (e.g., 👩‍💻 renders as 👨 instead of the family emoji).
///
/// Full ZWJ rendering requires HarfBuzz shaping (Phase 2).
///
/// FIXME
/// Phase 2: Add HarfBuzz, shape sequences
/// Phase 3: multi-glyph compositing (defer)
pub fn rasterizeSequence(self: *Rasterizer, gpa: Allocator, cps: []const u21, face: FaceKind) !Glyph {
    if (cps.len == 0) return error.EmptySequence;
    return self.rasterize(gpa, cps[0], face);
}

pub fn rasterizeSequenceDraft(self: *Rasterizer, gpa: Allocator, cps: []const u21, face: FaceKind) !Glyph {
    if (cps.len == 0) return error.EmptySequence;
    if (cps.len == 1) return self.rasterize(gpa, cps[0], face);

    // Phase 2 (deferred): try a real GSUB/ligature lookup here first.
    // if (self.tryLigatureLookup(cps, face)) |glyph_id| {
    //     return self.rasterizeGlyphId(gpa, glyph_id, face);
    // }

    return switch (classifySequence(cps)) {
        // Base is still semantically valid without the modifier — degrade
        // gracefully rather than treating this as "unknown."
        .modifier_sequence => self.rasterize(gpa, cps[0], face),

        // Regional indicator pairs: until compositing/ligature lookup lands,
        // fall back to the first flag letter rather than silently claiming
        // it's a country it isn't. Same honesty argument as ZWJ.
        .regional_pair => self.rasterize(gpa, cps[0], face),

        // ZWJ-joined sequence with no font ligature available: rendering
        // just cps[0] silently asserts a wrong meaning (see doc comment
        // above). Composite fallback lands in a follow-up change; for now
        // route through the same explicit function so the call site is
        // ready for it and the intent is documented in one place.
        .zwj_sequence => self.rasterizeUnknownZwjFallback(gpa, cps, face),

        .unknown => self.rasterize(gpa, cps[0], face),
    };

    // return self.rasterize(gpa, cps[0], face);
}

/// Placeholder until Phase 3 (multi-glyph compositing) lands.
/// Currently renders only the base codepoint, same as the old behavior,
/// but isolated here so the "this is a known limitation" fact is
/// localized to one call site instead of being implicit in
/// rasterizeSequence's switch.
fn rasterizeUnknownZwjFallback(self: *Rasterizer, gpa: Allocator, cps: []const u21, face: FaceKind) !Glyph {
    return self.rasterize(gpa, cps[0], face);
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
