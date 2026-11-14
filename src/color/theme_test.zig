const std = @import("std");

const Rgb = @import("Rgb.zig");
const Theme = @import("Theme.zig");
const presets = @import("presets.zig");
const default = Theme.default;

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

test "presets: every curated scheme matches its dark/light variant with distinct slugs and contrast" {
    try std.testing.expectEqual(@as(usize, 31), presets.entries.len);
    for (presets.entries, 0..) |entry, i| {
        try std.testing.expect(entry.slug.len > 0);
        try std.testing.expect(entry.title.len > 0);
        try std.testing.expect(!std.mem.eql(u8, entry.slug, "default"));
        try std.testing.expect(!std.meta.eql(entry.theme, default));

        const bg_luma = luma(entry.theme.background);
        const fg_luma = luma(entry.theme.foreground);
        switch (entry.variant) {
            .dark => try std.testing.expect(fg_luma > bg_luma),
            .light => try std.testing.expect(bg_luma > fg_luma),
        }
        const diff = @max(fg_luma, bg_luma) - @min(fg_luma, bg_luma);
        try std.testing.expect(diff >= 500_000);

        for (presets.entries[i + 1 ..]) |other| {
            try std.testing.expect(!std.mem.eql(u8, entry.slug, other.slug));
            try std.testing.expect(!std.meta.eql(entry.theme, other.theme));
        }
    }
}
