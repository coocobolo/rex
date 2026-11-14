const std = @import("std");

const Rgb = @import("Rgb.zig");
const default = @import("Theme.zig").default;

fn luma(c: Rgb) u32 {
    return 2126 * @as(u32, c.r) + 7152 * @as(u32, c.g) + 722 * @as(u32, c.b);
}

fn chromaSpread(c: Rgb) u8 {
    const hi = @max(c.r, @max(c.g, c.b));
    const lo = @min(c.r, @min(c.g, c.b));
    return hi - lo;
}

test "Theme: default preset sanity and palette rules" {
    try std.testing.expectEqual(16, default.ansi.len);
    try std.testing.expectEqual(Rgb.white, default.foreground);
    try std.testing.expectEqual(Rgb.black, default.background);

    // Every bright color is strictly lighter than its normal pair, and
    // bright black stands out clearly from the black background.
    for (0..8) |i| {
        try std.testing.expect(luma(default.ansi[i + 8]) > luma(default.ansi[i]));
    }
    try std.testing.expect(luma(default.ansi[8]) > luma(default.ansi[0]) * 2);

    // Chromatic slots (red..cyan, normal and bright) carry actual hue spread
    // and each normal hue is distinct from its peers.
    for (1..7) |i| {
        try std.testing.expect(chromaSpread(default.ansi[i]) >= 20);
        try std.testing.expect(chromaSpread(default.ansi[i + 8]) >= 20);
        for (i + 1..7) |j| {
            try std.testing.expect(!default.ansi[i].eql(default.ansi[j]));
        }
    }
}
