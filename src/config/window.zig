//! What the user sets for the window (`[window]` and the sections drawn
//! in it): background, scrollbar, cursor, text decorations, glyph atlas,
//! selection look, surfaces, platform and size. Plain data that imports
//! nothing but std, so anything that reads the config can import it without
//! the renderer. The renderer's `Option` types are these.

const std = @import("std");

/// The display server to start on (`[window] platform`).
pub const Platform = enum { auto, wayland, x11 };

/// A size in logical pixels.
pub const Size = struct {
    width: u16,
    height: u16,
};

pub const Background = struct {
    /// Global background opacity multiplier (0.0-1.0).
    alpha: f32 = 1.0,

    pub const default: Background = .{};
};

pub const Scrollbar = struct {
    /// normal thumb width (px)
    width: f32 = 5.0,
    /// expanded width on hover
    hover_width: f32 = 8.0,
    /// gap from window right edge
    gap: f32 = 2.0,
    /// minimum thumb height (px)
    min_thumb_height: f32 = 20.0,
    /// corner radius (px)
    radius: f32 = 4.0,
    track_color: [4]f32 = .{ 0.05, 0.05, 0.05, 1.0 },
    thumb_color: [4]f32 = .{ 0.7, 0.7, 0.7, 0.85 },
    thumb_hover_color: [4]f32 = .{ 0.9, 0.9, 0.9, 0.95 },
    /// Animation speed, as the fraction of the gap closed per ms.
    lerp_speed: f32 = 0.009,
    /// hide when at live view
    auto_hide: bool = true,
    /// target alpha when hidden, applied only when auto_hide is enabled
    auto_hide_alpha: f32 = 0.25,

    pub const default: Scrollbar = .{};
};

pub const Cursor = struct {
    /// Corner radius in pixels, clamped to half the cursor's smaller side.
    radius: f32 = 5.0,
    /// Height of the underline cursor, as a fraction of the cell height.
    underline_frac: f32 = 0.16,
    /// Width of the bar (beam) cursor, as a fraction of the cell width.
    bar_frac: f32 = 0.16,
    /// Bottom of the underline cursor, as a fraction of the cell height
    /// down from its top. 1.0 sits on the cell bottom.
    bar_offset_y: f32 = 1.0,
    /// Cursor opacity, 0.0 to 1.0.
    alpha: f32 = 1.0,
    /// Outline width in pixels when the window is unfocused; 0 keeps the
    /// cursor filled.
    hollow_border_width: f32 = 3.0,

    pub const default: Cursor = .{};
};

/// User settings for decorations. The defaults draw every line where
/// the font puts it, in the text color.
pub const Decoration = struct {
    underline: Line = .{},

    /// Gap between the two lines of a double underline, in pixels.
    /// null uses the underline thickness, narrowed down to 1 px when
    /// that keeps the upper line below the baseline, off the glyphs.
    double_gap: ?f32 = null,

    /// Curly underline, a sine wave centred on the underline.
    curly: struct {
        /// Height of a crest above the centre, in pixels. null uses one and
        /// a half underline thicknesses. The wave is kept inside the cell.
        amplitude: ?f32 = null,
        /// Length of one full wave, in pixels. null uses the cell width,
        /// one wave per cell.
        wavelength: ?f32 = null,
    } = .{},

    /// null fields fit whole dots into each cell, each as long as the
    /// space after it.
    dotted: Pattern = .{},

    /// null fields draw one dash per cell, half the cell long and
    /// centred in it.
    dashed: Pattern = .{},

    phase: Phase = .grid,

    skip_ink: SkipInk = .{},

    strikethrough: Line = .{},

    /// Fonts have no overline metric: by default it sits at the top of
    /// the cell, as thick as the resolved underline.
    overline: Line = .{},

    /// Fixed color for each kind of line. null draws it in the text
    /// color, after SGR 7, DECSCNM and the selection text color.
    color: struct {
        underline: ?[3]u8 = null,
        strikethrough: ?[3]u8 = null,
        overline: ?[3]u8 = null,
    } = .{},

    /// Opacity of every line, 0.0 to 1.0, on top of the dim alpha.
    alpha: f32 = 1.0,

    /// Lines of SGR 2 (dim) text are dimmed like the text.
    dim: bool = true,

    /// Lines of SGR 5 and 6 (blink) text blink with the text.
    blink: bool = true,

    order: Order = .over_text,

    /// Adjusts one decoration line. Pixels are measured down from the top
    /// of the cell. Every field left at its default keeps the font's line.
    pub const Line = struct {
        /// Top of the line, replacing the font's position. null keeps the
        /// font's position.
        y: ?f32 = null,

        /// Added to the position after `y`, positive moves the line down.
        /// Unlike `y` it keeps following the font when the size changes.
        offset: f32 = 0,

        /// Thickness, replacing the font's. null keeps the font's.
        thickness: ?f32 = null,

        /// Multiplies the thickness after `thickness`.
        thickness_scale: f32 = 1.0,
    };

    /// On and off lengths of a dotted or dashed underline, in pixels.
    pub const Pattern = struct {
        /// Length of each dot or dash. null derives it from the cell width.
        length: ?f32 = null,
        /// Space after each dot or dash. null derives it from the cell width,
        /// or uses `length` when only that is set.
        gap: ?f32 = null,
    };

    /// Where dotted, dashed and curly patterns start.
    pub const Phase = enum {
        /// From the left edge of the window, so a pattern lines up across
        /// rows and does not move when the run around it changes.
        grid,
        /// From the first cell of each run of decorated cells.
        run,
    };

    /// Breaks the underline where glyph ink crosses it, like the CSS
    /// `text-decoration-skip-ink: auto` browsers apply by default.
    pub const SkipInk = struct {
        enabled: bool = true,

        /// Clearance kept between the ink and the line, in pixels, both
        /// beside and above or below it. null uses the underline thickness.
        gap: ?f32 = null,

        /// Pieces of line shorter than this, in pixels, between two gaps are
        /// dropped too, so no specks are left between descenders. null uses
        /// twice the underline thickness. 0 keeps every piece.
        min_segment: ?f32 = null,

        /// Glyph coverage, 0.0 to 1.0, from which a pixel counts as ink.
        /// Lower values also skip the faint antialiased edges.
        threshold: f32 = 0.25,

        /// Underline styles that skip ink.
        styles: struct {
            single: bool = true,
            double: bool = true,
            curly: bool = true,
            dotted: bool = true,
            dashed: bool = true,
        } = .{},
    };

    /// Whether decorations are drawn over or under the glyphs.
    pub const Order = enum {
        /// Lines cross the glyphs, descenders do not hide the underline.
        over_text,
        /// Glyphs cover the lines, as in the background pass.
        under_text,
    };
};

/// Atlas texture size in pixels, shared by the gray and color
/// textures. It has no effect on rendering quality or window size; it
/// only bounds how many distinct glyphs fit before packing fails with
/// `error.AtlasFull`, and how much GPU memory the atlas takes (5 bytes
/// per pixel for both textures, 20 MiB at 2048x2048).
///
/// 1024x1024 is usually enough for gray glyphs (ASCII plus common
/// Unicode). Color emoji are larger (typically 64x64 or 128x128 per
/// glyph), so the color atlas fills faster. On HiDPI the cell height
/// is 32-40px instead of 16-20px, so both default to 2048x2048.
pub const Atlas = struct {
    /// Default 2048. Clamped to 1 and GL_MAX_TEXTURE_SIZE.
    width: u16 = 2048,
    /// Default 2048. Clamped to 1 and GL_MAX_TEXTURE_SIZE.
    height: u16 = 2048,
};

pub const SelectionStyle = struct {
    /// RGBA fill color, 0.0 to 1.0. The RGB part is replaced by the
    /// selection background color when one is set; `.a` stays the fill
    /// opacity.
    fill_color: [4]f32 = .{ 0.2, 0.2, 0.2, 1.0 },

    /// RGBA border color, 0.0 to 1.0.
    border_color: [4]f32 = .{ 0.4, 0.4, 0.4, 1.0 },

    /// Outline/border width in pixels.
    /// 0.0 = no visible border (fill only). 2.0+ = thick border.
    border_width: f32 = 1.5,

    border_style: BorderStyle = .unified,

    /// Corner radius in pixels applied to the top corners of the first row
    /// and the bottom corners of the last row.
    /// 0.0 = sharp corners.
    radius: f32 = 3.0,

    pub const default: SelectionStyle = .{};

    pub const BorderStyle = enum(u1) {
        /// Each row gets its own full border rectangle.
        per_row = 0,
        /// All rows share a single outer perimeter, with no internal row dividers.
        unified = 1,
    };
};

pub const Surface = struct {
    corner_radius: f32 = 8.0,
    border_width: f32 = 1.0,
    border_shape: BorderShape = .rounded,
    border_style: BorderStyle = .semantic,

    pub fn effectiveRadius(self: Surface) f32 {
        return switch (self.border_shape) {
            .rounded => self.corner_radius,
            .sharp => 0.0,
        };
    }

    pub const BorderShape = enum {
        rounded,
        sharp,
    };

    pub const BorderStyle = enum {
        semantic,
        subtle,
    };
};
