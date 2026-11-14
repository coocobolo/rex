//! Colors in the terminal pipeline pass through distinct representations, each serving a different layer.
//! The VT parser produces a Color union, either .default, .indexed, or .rgb.
//! Palette maps colors to internal representation for caching and GPU upload.

pub const ansi = @import("ansi.zig");
pub const x11 = @import("x11.zig");
pub const Color = @import("color.zig").Color;
pub const Rgb = @import("Rgb.zig");
pub const Theme = @import("Theme.zig");
pub const xterm256 = ansi.xterm256;

test {
    _ = @import("color_test.zig");
    _ = @import("rgb_test.zig");
    _ = @import("ansi_test.zig");
    _ = @import("x11.zig");
    _ = @import("theme_test.zig");
}
