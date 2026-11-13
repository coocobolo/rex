//! What the rasterizer needs to load a font: the faces and the size in device
//! pixels. The user's settings, in logical pixels, are `config.Config.Font`;
//! the app turns them into this with `pixelSize`.

const Config = @This();

const std = @import("std");

const font_config = @import("../config/font.zig");

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

pub const Style = font_config.Style;
pub const Face = font_config.Face;
pub const Faces = font_config.Faces;
