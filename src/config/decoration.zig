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
    skip_ink_gap: ?f32 = null,
    /// Drop line pieces shorter than this; none uses twice the thickness.
    skip_ink_min_segment: ?f32 = null,
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
};
