//! The `[decoration]` section: text-decoration opt-outs (ADR 0014).

const std = @import("std");
const Rgb = @import("../color/Rgb.zig");

/// Where decoration lines are drawn relative to the glyphs.
pub const Order = enum {
    over_text,
    under_text,
};

/// Underline styles that take part in ink skipping. The values match
/// `term.cell.UnderlineStyle` so the renderer can pack them without a switch.
/// Where dotted, dashed and curly patterns start.
pub const Phase = enum {
    /// From the window's left edge, so patterns line up across rows.
    grid,
    /// From the first cell of each decorated run.
    run,
};

pub const SkipInkStyle = enum(u3) {
    single = 1,
    double = 2,
    curly = 3,
    dotted = 4,
    dashed = 5,
};

pub const SkipInkStyleSet = std.EnumSet(SkipInkStyle);

/// All underline styles skip ink by default, matching the current renderer.
pub const default_skip_ink_styles: SkipInkStyleSet = blk: {
    var set: SkipInkStyleSet = .empty;
    set.insert(.single);
    set.insert(.double);
    set.insert(.curly);
    set.insert(.dotted);
    set.insert(.dashed);
    break :blk set;
};

pub const Decoration = struct {
    /// Break decoration lines where a descender crosses them.
    skip_ink: bool = true,
    /// Underline styles that skip ink.
    skip_ink_styles: SkipInkStyleSet = default_skip_ink_styles,
    /// Glyph coverage from which a pixel counts as ink, 0.0 to 1.0.
    skip_ink_threshold: f32 = 0.25,
    /// Extra clearance around ink; none uses the line thickness.
    skip_ink_gap_px: ?f32 = null,
    /// Drop line pieces shorter than this; none uses twice the thickness.
    skip_ink_min_segment_px: ?f32 = null,
    /// Draw lines over the glyphs, or let glyphs cover the lines.
    order: Order = .over_text,
    /// Opacity of every decoration line, 0.0 to 1.0.
    alpha: f32 = 1.0,
    /// SGR 2 dim text also dims its lines.
    dim: bool = true,
    /// SGR 5 and 6 blinking text also blinks its lines.
    blink: bool = true,
    /// Fixed line colors; none uses the text or underline color.
    underline_color: ?Rgb = null,
    strikethrough_color: ?Rgb = null,
    overline_color: ?Rgb = null,

    /// Vertical shift of each line from the font's position, in pixels.
    underline_offset_px: f32 = 0,
    strikethrough_offset_px: f32 = 0,
    overline_offset_px: f32 = 0,
    /// Line thickness overrides in pixels; none uses the font's metric.
    underline_thickness_px: ?f32 = null,
    strikethrough_thickness_px: ?f32 = null,
    overline_thickness_px: ?f32 = null,
    /// Multiplies the resolved underline thickness.
    underline_thickness_scale: f32 = 1.0,
    /// Gap between the two lines of a double underline; none uses thickness.
    double_gap_px: ?f32 = null,
    /// Curly wave height and wavelength; none derives them from the cell.
    curly_amplitude_px: ?f32 = null,
    curly_wavelength_px: ?f32 = null,
    /// Dotted and dashed on/off lengths; none derives them from the cell.
    dot_length_px: ?f32 = null,
    dot_gap_px: ?f32 = null,
    dash_length_px: ?f32 = null,
    dash_gap_px: ?f32 = null,
    /// Whether dash patterns align to the window grid or to each run.
    phase: Phase = .grid,
};
