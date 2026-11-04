//! Text decorations: underline, strikethrough and overline.

const std = @import("std");

const Rasterizer = @import("../freetype/root.zig").Rasterizer;
const Shader = @import("Shader.zig");

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

    /// Applies the adjustments to the font line `font`, then rounds and
    /// clamps the result into a cell `cell_height` pixels tall.
    pub fn resolve(self: Line, font: Rasterizer.Line, cell_height: u16) Rasterizer.Line {
        const top = (self.y orelse font.y) + self.offset;
        const thickness = (self.thickness orelse font.thickness) * self.thickness_scale;
        return .fit(top, thickness, cell_height);
    }
};

/// User settings for decorations. The defaults draw every line where
/// the font puts it.
pub const Option = struct {
    underline: Line = .{},

    /// Gap between the two lines of a double underline, in pixels.
    /// null uses the underline thickness.
    double_gap: ?f32 = null,

    strikethrough: Line = .{},

    /// Fonts have no overline metric: by default it sits at the top of
    /// the cell, as thick as the resolved underline.
    overline: Line = .{},
};

/// Where each decoration line sits, in whole pixels down from the top
/// of the cell, as the shaders read it.
pub const Metrics = struct {
    underline_y: f32,
    underline_thickness: f32,
    /// Top of the upper line of a double underline. The lower line is
    /// the underline itself.
    double_y: f32,
    strikethrough_y: f32,
    strikethrough_thickness: f32,
    overline_y: f32,
    overline_thickness: f32,

    /// Resolves the font's lines through the user's `option`.
    pub fn resolve(font: Rasterizer.Metrics, option: Option) Metrics {
        const height = font.cell_height;
        const underline = option.underline.resolve(.{
            .y = font.underline_y,
            .thickness = font.underline_thickness,
        }, height);
        const strikethrough = option.strikethrough.resolve(.{
            .y = font.strikethrough_y,
            .thickness = font.strikethrough_thickness,
        }, height);
        const overline = option.overline.resolve(.{
            .y = 0,
            .thickness = underline.thickness,
        }, height);
        const gap = @round(@max(0, option.double_gap orelse underline.thickness));
        return .{
            .underline_y = underline.y,
            .underline_thickness = underline.thickness,
            .double_y = @max(0, underline.y - gap - underline.thickness),
            .strikethrough_y = strikethrough.y,
            .strikethrough_thickness = strikethrough.thickness,
            .overline_y = overline.y,
            .overline_thickness = overline.thickness,
        };
    }

    /// Sets the `u_underline_*`, `u_double_y`, `u_strikethrough_*` and
    /// `u_overline_*` uniforms on the bound `shader`.
    pub fn apply(self: Metrics, shader: Shader) void {
        shader.set1f("u_underline_y", self.underline_y);
        shader.set1f("u_underline_thickness", self.underline_thickness);
        shader.set1f("u_double_y", self.double_y);
        shader.set1f("u_strikethrough_y", self.strikethrough_y);
        shader.set1f("u_strikethrough_thickness", self.strikethrough_thickness);
        shader.set1f("u_overline_y", self.overline_y);
        shader.set1f("u_overline_thickness", self.overline_thickness);
    }
};

test {
    _ = @import("decoration_test.zig");
}
