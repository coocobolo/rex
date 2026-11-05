const std = @import("std");
const renderer = @import("../../renderer/root.zig");

/// Re-exported general UI Icon system from `rex.renderer.Icon`.
pub const Icon = renderer.Icon;
pub const IconStyle = renderer.Icon.IconStyle;
pub const IconId = renderer.Icon.IconId;
pub const resolveStyle = renderer.Icon.resolveStyle;
pub const getGlyph = renderer.Icon.getGlyph;
pub const getCustomGlyph = renderer.Icon.getCustomGlyph;
pub const getGlyphWithOption = renderer.Icon.getGlyphWithOption;
pub const glyphWidth = renderer.Icon.glyphWidth;
pub const glyphWidthPolicy = renderer.Icon.glyphWidthPolicy;

test {
    _ = Icon;
}
