const Config = @This();

font: Font,

/// Font height sizes (in pixels)
height: u32,

/// Font width sizes (in pixels)
width: u32 = 0,

/// maximum font sizes (in pixels)
max_size: u32,

/// minimum font sizes (in pixels)
min_size: u32,

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