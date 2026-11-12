//! The UI kit's font: one face per text style of the kit, opened from the
//! font file of that style's weight at that style's size. It gives layout
//! the width of a run of text and gives the painter glyph bitmaps,
//! advances and pair kerning.
//!
//! Text is laid out from glyph advances, left to right, with no shaping
//! (ADR 0009): each code point is one glyph. Kerning is FreeType's simple
//! pair kerning, which reads GPOS when FreeType is built with
//! `TT_CONFIG_OPTION_GPOS_KERNING` (`build.zig`). It only understands plain
//! x-advance pairs, so the files are static faces, one per weight: a
//! variable face keeps its pairs with variation data and gets none.
//!
//! Sizes are the kit's logical pixels times `scale`, so widths come back
//! in logical pixels whatever the display scale is.

const std = @import("std");

const ft = @import("root.zig");
const c = ft.c;
const Rasterizer = @import("Rasterizer.zig");
const text = @import("../kit/text.zig");

const log = std.log.scoped(.kit_font);

const KitFont = @This();

const style_count = @typeInfo(text.Style).@"enum".fields.len;

pub const Kerning = enum {
    /// Advances only.
    off,
    /// Advances plus FreeType's pair kerning.
    pairs,
};

/// One static font file per weight the type scale uses.
pub const Files = struct {
    /// Weight 400.
    regular: [*:0]const u8,
    /// Weight 500.
    medium: [*:0]const u8,
    /// Weight 600.
    semibold: [*:0]const u8,
    /// The icon font: the glyphs of `kit/icons.zig`.
    icons: [*:0]const u8,
    /// The terminal's text face, for code points the UI font lacks (a
    /// title or a path can hold anything). Null for none. A file that
    /// cannot be opened is logged and treated as none.
    fallback: ?[*:0]const u8 = null,

    fn of(self: Files, weight: u16) [*:0]const u8 {
        return switch (weight) {
            400 => self.regular,
            500 => self.medium,
            600 => self.semibold,
            else => unreachable, // `text.Style.metrics` uses these three
        };
    }
};

pub const Options = struct {
    /// Physical pixels per logical pixel: 1.25 at 125%.
    scale: f32 = 1,
    kerning: Kerning = .pairs,
};

/// Owned: closed by `destroy`, with every face.
library: c.FT_Library,
/// Indexed by `text.Style`.
faces: [style_count]c.FT_Face,
/// The fallback file at each style's size, or null without one.
fallback_faces: ?[style_count]c.FT_Face,
/// Sized for each icon as it is rasterized.
icon_face: c.FT_Face,
scale: f32,
kerning: Kerning,
/// Advance of each ASCII code point in physical pixels, per style, so
/// measuring ordinary UI text loads no glyph.
ascii_advance: [style_count][128]f32,
/// Glyph index of each printable ASCII code point, per style.
ascii_glyph: [style_count][printable]c.FT_UInt,
/// Kerning of pairs of printable ASCII in 26.6 physical pixels, per style,
/// indexed by `pairIndex`; `unknown_kern` until a pair is first asked for.
/// Asking FreeType walks the font's GPOS table, and layout measures the
/// same text several times a frame.
ascii_kern: [style_count][printable * printable]i16,
/// Advances of code points outside ASCII, which cost a glyph load each.
/// Direct-mapped: a second code point with the same hash replaces the
/// first.
other_advance: [other_capacity]OtherAdvance,

/// Printable ASCII: U+0020 to U+007E.
const printable = 0x7F - 0x20;
const unknown_kern = std.math.minInt(i16);
const other_capacity = 64;

const OtherAdvance = struct {
    advance: f32,
    /// 0 for an empty slot: U+0000 is ASCII and never stored here.
    codepoint: u21,
    style: text.Style,
};

fn pairIndex(left: u21, right: u21) ?usize {
    if (left < 0x20 or left >= 0x7F or right < 0x20 or right >= 0x7F) return null;
    return @as(usize, left - 0x20) * printable + (right - 0x20);
}

/// Opens a face for every text style.
pub fn create(files: Files, options: Options) ft.FtError!KitFont {
    var self: KitFont = .{
        .library = try ft.initFreeType(),
        .faces = undefined,
        .fallback_faces = null,
        .icon_face = undefined,
        .scale = options.scale,
        .kerning = options.kerning,
        .ascii_advance = undefined,
        .ascii_glyph = undefined,
        .ascii_kern = undefined,
        .other_advance = undefined,
    };
    // Closing the library closes every face it opened (FT_Done_Library).
    errdefer ft.doneFreeType(self.library) catch {};

    for (std.enums.values(text.Style)) |style| {
        const metrics = style.metrics();
        self.faces[@intFromEnum(style)] = try ft.initFace(self.library, files.of(metrics.weight), metrics.size);
    }
    self.icon_face = try ft.initFace(self.library, files.icons, 16);
    if (files.fallback) |path| fallback: {
        var faces: [style_count]c.FT_Face = undefined;
        for (std.enums.values(text.Style)) |style| {
            faces[@intFromEnum(style)] = ft.initFace(self.library, path, style.metrics().size) catch |err| {
                // Faces opened so far are closed with the library.
                log.warn("no fallback for UI text: cannot open {s}: {t}", .{ path, err });
                break :fallback;
            };
        }
        self.fallback_faces = faces;
    }
    try self.setScale(options.scale);
    return self;
}

pub fn destroy(self: *KitFont) void {
    ft.doneFreeType(self.library) catch |err| log.err("closing FreeType: {t}", .{err});
    self.* = undefined;
}

/// Re-sizes every face for a new display scale. Glyphs rasterized before
/// are the wrong size afterwards, so the caller drops its glyph cache.
pub fn setScale(self: *KitFont, scale: f32) ft.FtError!void {
    self.scale = scale;
    for (std.enums.values(text.Style)) |style| {
        const ft_face = self.faceOf(style);
        // 26.6 points at 72 dpi are 26.6 pixels, so fractional sizes
        // (14 px at 125% is 17.5) are exact instead of rounded.
        const size: c.FT_F26Dot6 = @intFromFloat(@round(@as(f32, @floatFromInt(style.metrics().size)) * scale * 64));
        try ft.ftCheck(c.FT_Set_Char_Size(ft_face, 0, size, 72, 72), "FT_Set_Char_Size");
        if (self.fallback_faces) |faces| {
            try ft.ftCheck(c.FT_Set_Char_Size(faces[@intFromEnum(style)], 0, size, 72, 72), "FT_Set_Char_Size");
        }
        for (&self.ascii_advance[@intFromEnum(style)], 0..) |*advance_px, codepoint| {
            advance_px.* = loadAdvance(ft_face, @intCast(codepoint));
        }
        for (&self.ascii_glyph[@intFromEnum(style)], 0x20..) |*glyph, codepoint| {
            glyph.* = c.FT_Get_Char_Index(ft_face, codepoint);
        }
    }
    // Kerning and the other advances are in pixels at the old scale.
    for (&self.ascii_kern) |*table| @memset(table, unknown_kern);
    @memset(&self.other_advance, .{ .advance = 0, .codepoint = 0, .style = .sm });
}

/// FreeType's adjustment between two glyphs in 26.6 pixels, 0 when either
/// is missing or the font does not kern the pair.
fn kernGlyphs(ft_face: c.FT_Face, left: c.FT_UInt, right: c.FT_UInt) c.FT_Pos {
    if (left == 0 or right == 0) return 0;
    var delta: c.FT_Vector = undefined;
    if (c.FT_Get_Kerning(ft_face, left, right, c.FT_KERNING_UNFITTED, &delta) != 0) return 0;
    return delta.x;
}

fn faceOf(self: *const KitFont, style: text.Style) c.FT_Face {
    return self.faces[@intFromEnum(style)];
}

/// The face `codepoint` is drawn from in `style`: the UI font's, or the
/// fallback's when only that one has the glyph. Kerning is the UI font's
/// alone, so a fallback glyph is never kerned.
fn faceFor(self: *const KitFont, style: text.Style, codepoint: u21) c.FT_Face {
    const primary = self.faceOf(style);
    // The UI font has all of ASCII.
    if (codepoint < 0x80) return primary;
    const faces = self.fallback_faces orelse return primary;
    if (c.FT_Get_Char_Index(primary, codepoint) != 0) return primary;
    const fallback = faces[@intFromEnum(style)];
    return if (c.FT_Get_Char_Index(fallback, codepoint) != 0) fallback else primary;
}

/// The unhinted advance of `codepoint` in physical pixels; 0 when the
/// glyph cannot be loaded.
fn loadAdvance(ft_face: c.FT_Face, codepoint: u21) f32 {
    ft.loadChar(ft_face, codepoint, c.FT_LOAD_DEFAULT | c.FT_LOAD_TARGET_LIGHT) catch return 0;
    // 16.16 pixels, before hinting or rounding.
    return @as(f32, @floatFromInt(ft_face.*.glyph.*.linearHoriAdvance)) / 65536.0;
}

/// How far the pen moves after `codepoint`, in physical pixels.
pub fn advance(self: *KitFont, style: text.Style, codepoint: u21) f32 {
    if (codepoint < 128) return self.ascii_advance[@intFromEnum(style)][codepoint];
    const slot = &self.other_advance[(codepoint *% 31 +% @intFromEnum(style)) % other_capacity];
    if (slot.codepoint != codepoint or slot.style != style) {
        slot.* = .{ .advance = loadAdvance(self.faceFor(style, codepoint), codepoint), .codepoint = codepoint, .style = style };
    }
    return slot.advance;
}

/// The adjustment between `left` and `right` in physical pixels, negative
/// to pull them together. 0 with kerning off or for a pair the font does
/// not kern.
pub fn kern(self: *KitFont, style: text.Style, left: u21, right: u21) f32 {
    if (self.kerning == .off) return 0;
    const ft_face = self.faceOf(style);
    if (pairIndex(left, right)) |index| {
        const slot = &self.ascii_kern[@intFromEnum(style)][index];
        if (slot.* == unknown_kern) {
            const glyphs = &self.ascii_glyph[@intFromEnum(style)];
            // Font units never reach the sentinel: a pair kerned by 512
            // pixels does not exist.
            slot.* = std.math.lossyCast(i16, @max(kernGlyphs(ft_face, glyphs[left - 0x20], glyphs[right - 0x20]), unknown_kern + 1));
        }
        return @as(f32, @floatFromInt(slot.*)) / 64.0;
    }
    const delta = kernGlyphs(ft_face, c.FT_Get_Char_Index(ft_face, left), c.FT_Get_Char_Index(ft_face, right));
    return @as(f32, @floatFromInt(delta)) / 64.0;
}

/// Distance from the top of a line box to the baseline in physical
/// pixels, with the font's ascent and descent centered in the style's
/// line height.
pub fn baseline(self: *const KitFont, style: text.Style) f32 {
    const metrics = self.faceOf(style).*.size.*.metrics;
    const ascent = @as(f32, @floatFromInt(metrics.ascender)) / 64.0;
    const descent = -@as(f32, @floatFromInt(metrics.descender)) / 64.0;
    const line_height = @as(f32, @floatFromInt(style.metrics().line_height)) * self.scale;
    return (line_height - (ascent + descent)) / 2 + ascent;
}

/// Width of `bytes` on one line, in logical pixels.
pub fn width(self: *KitFont, bytes: []const u8, style: text.Style) f32 {
    var total: f32 = 0;
    var previous: ?u21 = null;
    var codepoints: text.Codepoints = .init(bytes);
    while (codepoints.next()) |codepoint| {
        if (previous) |left| total += self.kern(style, left, codepoint);
        total += self.advance(style, codepoint);
        previous = codepoint;
    }
    return total / self.scale;
}

fn widthErased(context: *anyopaque, bytes: []const u8, style: text.Style) f32 {
    const self: *KitFont = @ptrCast(@alignCast(context));
    return self.width(bytes, style);
}

/// The kit's view of this font. Valid while the font is alive and not
/// moved.
pub fn measurer(self: *KitFont) text.Measurer {
    return .{ .context = self, .widthFn = widthErased };
}

/// Renders `codepoint` in `style`. The bitmap points into FreeType's
/// glyph slot and is valid until the next call on this font.
pub fn rasterize(self: *KitFont, style: text.Style, codepoint: u21) !Rasterizer.Glyph {
    return render(self.faceFor(style, codepoint), codepoint, c.FT_LOAD_RENDER | c.FT_LOAD_TARGET_LIGHT);
}

/// Renders the icon `codepoint` for a box of `size` logical pixels. The
/// bitmap is valid until the next call on this font. Unhinted: fitting an
/// icon's strokes to the pixel grid bends its shape.
pub fn rasterizeIcon(self: *KitFont, codepoint: u21, size: u8) !Rasterizer.Glyph {
    const pixels: c.FT_F26Dot6 = @intFromFloat(@round(@as(f32, @floatFromInt(size)) * self.scale * 64));
    try ft.ftCheck(c.FT_Set_Char_Size(self.icon_face, 0, pixels, 72, 72), "FT_Set_Char_Size");
    return render(self.icon_face, codepoint, c.FT_LOAD_RENDER | c.FT_LOAD_NO_HINTING);
}

fn render(ft_face: c.FT_Face, codepoint: u21, flags: c.FT_Int32) !Rasterizer.Glyph {
    try ft.loadChar(ft_face, codepoint, flags);
    const glyph = ft_face.*.glyph;
    const bitmap = glyph.*.bitmap;
    const advance_px = std.math.cast(u16, glyph.*.advance.x >> 6) orelse 0;

    if (bitmap.width == 0 or bitmap.rows == 0) {
        return .{ .advance = advance_px, .bitmap = undefined, .bearing_x = 0, .bearing_y = 0, .height = 0, .kind = .gray, .pitch = 0, .width = 0 };
    }
    if (bitmap.pixel_mode != @as(u8, c.FT_PIXEL_MODE_GRAY)) return error.UnsupportedPixelMode;

    return .{
        .advance = advance_px,
        .bitmap = bitmap.buffer,
        .bearing_x = std.math.cast(i16, glyph.*.bitmap_left) orelse 0,
        .bearing_y = std.math.cast(i16, glyph.*.bitmap_top) orelse 0,
        .width = std.math.cast(u16, bitmap.width) orelse return error.GlyphTooLarge,
        .height = std.math.cast(u16, bitmap.rows) orelse return error.GlyphTooLarge,
        .pitch = try Rasterizer.rowPitch(bitmap.pitch),
        .kind = .gray,
    };
}
