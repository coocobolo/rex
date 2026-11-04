//! Pure terminal color union (default, indexed, rgb).

const std = @import("std");

/// A terminal color value stored in 4 bytes.
///
/// Three representations are supported:
///   .default    use the terminal's configured foreground/background
///               color. The tag is preserved in cell storage so that
///               theme changes recolor existing content without a
///               full redraw.
///
///   .indexed    one of the 256 ANSI/xterm palette entries (0 to 255).
///               Entries 0 to 15 are the standard 16 colors; 16 to 231 are the
///               6×6×6 color cube; 232 to 255 are the grayscale ramp.
///
///   .rgb        24-bit true color (r, g, b each 0 to 255).
///               Used for SGR 38;2;r;g;b and 48;2;r;g;b sequences.
///
/// Layout (Zig union(enum), tag = u8, max payload = 3 bytes)
pub const Color = union(enum) {
    /// Use the terminal's default foreground or background color.
    default,
    /// ANSI/xterm 256-color palette index.
    indexed: u8,
    /// 24-bit true color.
    rgb: Rgb,

    pub const Rgb = @import("Rgb.zig");

    pub fn fromRgb(r: u8, g: u8, b: u8) Color {
        return .{ .rgb = .{ .r = r, .g = g, .b = b } };
    }
};

comptime {
    std.debug.assert(4 == @sizeOf(Color));
}

test "Color: fromRgb and sizeOf" {
    const c = Color.fromRgb(10, 20, 30);
    try std.testing.expectEqual(Color{ .rgb = .{ .r = 10, .g = 20, .b = 30 } }, c);
    try std.testing.expectEqual(4, @sizeOf(Color));
}
