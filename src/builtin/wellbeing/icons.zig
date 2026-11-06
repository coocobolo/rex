const std = @import("std");
const IconMod = @import("../../ui/Icon.zig");

/// Re-exported general UI Icon system from `rex.ui.Icon`.
pub const Icon = IconMod;
pub const IconStyle = IconMod.IconStyle;
pub const IconId = IconMod.IconId;
pub const resolveStyle = IconMod.resolveStyle;
pub const getGlyph = IconMod.getGlyph;
pub const getCustomGlyph = IconMod.getCustomGlyph;
pub const getGlyphWithOption = IconMod.getGlyphWithOption;
pub const glyphWidth = IconMod.glyphWidth;
pub const glyphWidthPolicy = IconMod.glyphWidthPolicy;

test {
    _ = Icon;
}
