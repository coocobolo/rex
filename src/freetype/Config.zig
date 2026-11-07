const Config = @This();

const std = @import("std");

font: Font,

/// Font height in pixels. The rasterizer renders this many device pixels;
/// `App.Config` keeps the size in logical pixels here and passes
/// `pixelSize(height, scale)` to the rasterizer.
height: u32,

/// Font width sizes (in pixels)
width: u32 = 0,

/// Largest font size, in logical pixels.
max_size: u32,

/// Smallest font size, in logical pixels.
min_size: u32,

/// Device pixel height of a font `size` logical pixels tall on a display
/// with content `scale` (1.0 at 100%), rounded to whole pixels because
/// terminal cells are whole pixels, and at least 1. A `scale` that isn't
/// a positive finite number counts as 1.0: GLFW reports 0 when it can't
/// tell.
pub fn pixelSize(size: u32, scale: f32) u32 {
    const s: f32 = if (std.math.isFinite(scale) and scale > 0) scale else 1.0;
    const px = @round(@as(f32, @floatFromInt(size)) * s);
    return @max(1, std.math.lossyCast(u32, px));
}

pub const FontStyle = enum { regular, bold, italic, bold_italic };

pub const FontFamily = union(enum) {
    /// A variable font family with an optional dedicated italic face. One or two variable font files.
    /// If .italic is null, italic style is synthesized (skewed) from .upright rather than using a
    /// real italic design.
    variable: struct {
        upright: [*:0]const u8,
        italic: ?[*:0]const u8 = null,
        regular_weight: f64 = 400,
        bold_weight: f64 = 800,
    },

    /// A family composed of four separate static font faces.
    static: struct {
        regular: [*:0]const u8,
        bold: [*:0]const u8,
        italic: [*:0]const u8,
        bold_italic: [*:0]const u8,
    },

    /// Resolves a logical style to the concrete (path, weigth_axis) pair that should actually be
    /// loaded or rasterized for it.
    pub fn resolve(self: FontFamily, style: FontStyle) FontFace {
        return switch (self) {
            .variable => |v| switch (style) {
                .regular => .{ .path = v.upright, .weight_axis = v.regular_weight },
                .bold => .{ .path = v.upright, .weight_axis = v.bold_weight },
                .italic => .{ .path = v.italic orelse v.upright, .weight_axis = v.regular_weight },
                .bold_italic => .{ .path = v.italic orelse v.upright, .weight_axis = v.bold_weight },
            },
            .static => |s| .{
                .path = switch (style) {
                    .regular => s.regular,
                    .bold => s.bold,
                    .italic => s.italic,
                    .bold_italic => s.bold_italic,
                },
                .weight_axis = null,
            },
        };
    }
};

pub const FontFace = struct {
    path: [*:0]const u8,

    /// Variable-font "wght" axis value CSS-style format (400 = Regular, 700 = Bold).
    /// Ignored if the font at `path` is not a variable font.
    weight_axis: ?f64 = null,

    /// Face index within a font collection such as TTC/OTC.
    /// Zero selects the first face.
    index: u32 = 0,

    pub fn static(path: [*:0]const u8) FontFace {
        return .{ .path = path };
    }

    pub fn variable(path: [*:0]const u8, weight: f64) FontFace {
        return .{ .path = path, .weight_axis = weight };
    }
};

pub const Font = struct {
    /// Primary typeface used for normal text.
    family: FontFamily,

    /// Optional font face used for emoji glyphs.
    emoji: ?FontFace = null,

    /// Ordered font faces searched when the primary family does not contain a requested glyph.
    // FIXME! missing script-aware fallback, also the fallback algorithm is naive, eventually
    // we want font fallback happens around shaping, not merely around individual Unicode
    // codepoints.
    fallbacks: []const FontFace = &.{},
};
