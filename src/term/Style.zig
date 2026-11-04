//! Style: a 16-byte resolved or pen style holding colors and attributes.
//! Interned per screen when SGR changes the pen, replacing ExtAttr.

const std = @import("std");
const Color = @import("../color/color.zig").Color;

pub const Style = struct {
    /// Foreground color.
    fg: Color = .default,
    /// Background color.
    bg: Color = .default,
    /// Underline color from SGR 58.
    underline: Color = .default,
    /// Packed SGR attribute flags (bold, italic, underline style, etc.).
    flags: u16 = 0,
    /// Interned OSC 8 hyperlink index (0 = none).
    link: u16 = 0,

    pub const default: Style = .{};

    /// Compares two Style structs for equality across colors and flags.
    pub fn eql(self: Style, other: Style) bool {
        return std.meta.eql(self, other);
    }
};

comptime {
    std.debug.assert(16 == @sizeOf(Style));
}

test "Style: default initialization and 16-byte size" {
    const s = Style{};
    try std.testing.expectEqual(Color.default, s.fg);
    try std.testing.expectEqual(Color.default, s.bg);
    try std.testing.expectEqual(Color.default, s.underline);
    try std.testing.expectEqual(0, s.flags);
    try std.testing.expectEqual(0, s.link);
    try std.testing.expectEqual(16, @sizeOf(Style));
    try std.testing.expect(s.eql(Style.default));

    var s2 = s;
    s2.fg = .{ .indexed = 4 };
    try std.testing.expect(!s.eql(s2));
}
