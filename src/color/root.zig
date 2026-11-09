//! Colors in the terminal pipeline pass through distinct representations, each serving a different layer.
//! The VT parser produces a Color union, either .default, .indexed, or .rgb.
//! Palette maps colors to internal representation for caching and GPU upload.

pub const ansi = @import("ansi.zig");
pub const x11 = @import("x11.zig");
pub const Color = @import("color.zig").Color;
pub const Rgb = @import("Rgb.zig");
pub const Theme = @import("Theme.zig");
pub const Tokens = @import("Tokens.zig").Tokens;
pub const xterm256 = ansi.xterm256;

test {
    _ = @import("color.zig");
    _ = @import("Rgb.zig");
    _ = @import("ansi.zig");
    _ = @import("x11.zig");
    _ = @import("theme_test.zig");
    _ = @import("Tokens.zig");
}
