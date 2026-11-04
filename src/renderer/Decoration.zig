//! Text decorations: underline, strikethrough and overline.

const Rasterizer = @import("../freetype/root.zig").Rasterizer;
const Shader = @import("Shader.zig");

/// Where each decoration line sits, in pixels down from the top of the
/// cell, as the shaders read it.
pub const Metrics = struct {
    underline_y: f32,
    underline_thickness: f32,
    strikethrough_y: f32,
    strikethrough_thickness: f32,
    overline_y: f32,
    overline_thickness: f32,

    /// Takes the lines from the font. Fonts have no overline metric, so
    /// it sits at the top of the cell, as thick as the underline.
    pub fn fromFont(font: Rasterizer.Metrics) Metrics {
        return .{
            .underline_y = font.underline_y,
            .underline_thickness = font.underline_thickness,
            .strikethrough_y = font.strikethrough_y,
            .strikethrough_thickness = font.strikethrough_thickness,
            .overline_y = 0,
            .overline_thickness = font.underline_thickness,
        };
    }

    /// Sets the `u_underline_*`, `u_strikethrough_*` and `u_overline_*`
    /// uniforms on the bound `shader`.
    pub fn apply(self: Metrics, shader: Shader) void {
        shader.set1f("u_underline_y", self.underline_y);
        shader.set1f("u_underline_thickness", self.underline_thickness);
        shader.set1f("u_strikethrough_y", self.strikethrough_y);
        shader.set1f("u_strikethrough_thickness", self.strikethrough_thickness);
        shader.set1f("u_overline_y", self.overline_y);
        shader.set1f("u_overline_thickness", self.overline_thickness);
    }
};
