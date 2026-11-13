//! What the user sets for the terminal font's files (`[font]`): the faces
//! of each style, their weights, the emoji face and the fallbacks. Plain
//! data that imports nothing but std, so anything that reads the config can
//! import it without FreeType. The rasterizer's `Faces` are these.

const std = @import("std");

pub const Style = enum { regular, bold, italic, bold_italic };

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
    /// The regular face, and the file of any style without its own.
    regular: [*:0]const u8,
    /// Each style's own file; null takes the next one in `face`'s order.
    bold: ?[*:0]const u8 = null,
    italic: ?[*:0]const u8 = null,
    bold_italic: ?[*:0]const u8 = null,
    /// "wght" axis values of the regular and bold styles (CSS-style, 400 is
    /// regular). They apply to faces loaded from variable font files;
    /// static files ignore them.
    regular_weight: f64 = 400,
    bold_weight: f64 = 800,

    /// Optional font face used for emoji glyphs.
    emoji: ?Face = null,

    /// Ordered font faces searched when the styled faces lack a glyph.
    // FIXME! missing script-aware fallback, also the fallback algorithm is naive, eventually
    // we want font fallback happens around shaping, not merely around individual Unicode
    // codepoints.
    fallbacks: []const Face = &.{},

    /// Empty path. Startup fills an omitted `[font] file` from the faces
    /// installed next to the executable.
    pub const default: Faces = .{ .regular = "" };

    /// The file and weight `style` loads: its own file, else bold and
    /// italic take the regular file, and bold italic takes the italic file,
    /// else the regular one. A style without its own file is not
    /// synthesized: a static regular file renders bold text unbolded.
    pub fn face(faces: Faces, style: Style) Face {
        return switch (style) {
            .regular => .variable(faces.regular, faces.regular_weight),
            .bold => .variable(faces.bold orelse faces.regular, faces.bold_weight),
            .italic => .variable(faces.italic orelse faces.regular, faces.regular_weight),
            .bold_italic => .variable(faces.bold_italic orelse faces.italic orelse faces.regular, faces.bold_weight),
        };
    }

    /// Whether `a` and `b` load the same fonts the same way, so a
    /// rasterizer built for one serves the other.
    pub fn eql(a: Faces, b: Faces) bool {
        if (!pathEql(a.regular, b.regular) or !optionalPathEql(a.bold, b.bold) or
            !optionalPathEql(a.italic, b.italic) or !optionalPathEql(a.bold_italic, b.bold_italic) or
            a.regular_weight != b.regular_weight or a.bold_weight != b.bold_weight) return false;
        if (a.emoji == null or b.emoji == null) {
            if (a.emoji != null or b.emoji != null) return false;
        } else if (!a.emoji.?.eql(b.emoji.?)) return false;
        if (a.fallbacks.len != b.fallbacks.len) return false;
        for (a.fallbacks, b.fallbacks) |x, y| if (!x.eql(y)) return false;
        return true;
    }
};
