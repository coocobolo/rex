//! What the rasterizer needs to load a font: the faces and the size in device
//! pixels. The user's settings, in logical pixels, are `config.Config.Font`;
//! the app turns them into this with `pixelSize`.

const Config = @This();

const std = @import("std");

faces: Faces,

/// Font height in device pixels. FreeType derives the width from it.
height: u32,

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

pub const Style = enum { regular, bold, italic, bold_italic };

pub const Family = union(enum) {
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
};

pub const Face = struct {
    path: [*:0]const u8,

    /// Variable-font "wght" axis value CSS-style format (400 = Regular, 700 = Bold).
    /// Ignored if the font at `path` is not a variable font.
    weight_axis: ?f64 = null,

    /// Face index within a font collection such as TTC/OTC.
    /// Zero selects the first face.
    index: u32 = 0,

    pub fn static(path: [*:0]const u8) Face {
        return .{ .path = path };
    }

    pub fn variable(path: [*:0]const u8, weight: f64) Face {
        return .{ .path = path, .weight_axis = weight };
    }

    pub fn eql(a: Face, b: Face) bool {
        return pathEql(a.path, b.path) and a.weight_axis == b.weight_axis and a.index == b.index;
    }
};

/// Paths compare by content: two configs keep them in different arenas.
fn pathEql(a: [*:0]const u8, b: [*:0]const u8) bool {
    return std.mem.orderZ(u8, a, b) == .eq;
}

fn optionalPathEql(a: ?[*:0]const u8, b: ?[*:0]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return pathEql(a.?, b.?);
}

pub const Faces = struct {
    /// Primary typeface used for normal text.
    family: Family,

    /// Optional font face used for emoji glyphs.
    emoji: ?Face = null,

    /// Ordered font faces searched when the primary family does not contain a requested glyph.
    // FIXME! missing script-aware fallback, also the fallback algorithm is naive, eventually
    // we want font fallback happens around shaping, not merely around individual Unicode
    // codepoints.
    fallbacks: []const Face = &.{},

    /// No font chosen: an empty variable-font path, which the user must set
    /// (`[font] file`) until Rex has a default font (#20).
    pub const default: Faces = .{ .family = .{ .variable = .{ .upright = "" } } };

    /// Whether `a` and `b` load the same fonts the same way, so a
    /// rasterizer built for one serves the other.
    pub fn eql(a: Faces, b: Faces) bool {
        const family = switch (a.family) {
            .variable => |av| switch (b.family) {
                .variable => |bv| pathEql(av.upright, bv.upright) and optionalPathEql(av.italic, bv.italic) and
                    av.regular_weight == bv.regular_weight and av.bold_weight == bv.bold_weight,
                .static => false,
            },
            .static => |as| switch (b.family) {
                .static => |bs| pathEql(as.regular, bs.regular) and pathEql(as.bold, bs.bold) and
                    pathEql(as.italic, bs.italic) and pathEql(as.bold_italic, bs.bold_italic),
                .variable => false,
            },
        };
        if (!family) return false;
        if (a.emoji == null or b.emoji == null) {
            if (a.emoji != null or b.emoji != null) return false;
        } else if (!a.emoji.?.eql(b.emoji.?)) return false;
        if (a.fallbacks.len != b.fallbacks.len) return false;
        for (a.fallbacks, b.fallbacks) |x, y| if (!x.eql(y)) return false;
        return true;
    }
};
