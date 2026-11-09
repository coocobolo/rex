const std = @import("std");

const Icon = @import("Icon.zig");
const IconId = Icon.IconId;
const IconStyle = Icon.IconStyle;
const Option = Icon.Option;
const getGlyph = Icon.getGlyph;
const getGlyphWithOption = Icon.getGlyphWithOption;
const glyphWidth = Icon.glyphWidth;
const glyphWidthPolicy = Icon.glyphWidthPolicy;
const resolveStyle = Icon.resolveStyle;

test "Icon: glyph resolution and width calculation" {
    const testing = std.testing;

    // Check style fallback without env vars
    const style = resolveStyle(.unicode);
    try testing.expectEqual(IconStyle.unicode, style);

    // Verify all IconIds produce non-empty strings across all concrete styles
    const styles = [_]IconStyle{ .nerd_font, .unicode, .ascii };
    inline for (std.meta.fields(IconId)) |field| {
        const id: IconId = @enumFromInt(field.value);
        for (styles) |s| {
            const g = getGlyph(id, s);
            try testing.expect(g.len > 0);
            const w = glyphWidth(g);
            try testing.expect(w >= 1);
        }
    }

    // Verify all unicode icons have exactly 1-column footprint under .narrow
    inline for (std.meta.fields(IconId)) |field| {
        const id: IconId = @enumFromInt(field.value);
        const g = getGlyph(id, .unicode);
        try testing.expectEqual(@as(u16, 1), glyphWidth(g));
    }

    // Verify specific ASCII glyphs
    try testing.expectEqualStrings("[#]", getGlyph(.lock, .ascii));
    try testing.expectEqualStrings("[!]", getGlyph(.warning, .ascii));
    try testing.expectEqualStrings("[v]", getGlyph(.success, .ascii));

    // Verify widths
    try testing.expectEqual(@as(u16, 3), glyphWidth("[#]"));
    try testing.expectEqual(@as(u16, 1), glyphWidth("▲"));
    try testing.expectEqual(@as(u16, 1), glyphWidth("⏸"));

    // Verify ambiguous width policy
    try testing.expectEqual(@as(u16, 1), glyphWidthPolicy("▲", .narrow));
    try testing.expectEqual(@as(u16, 2), glyphWidthPolicy("▲", .wide));

    // Verify cluster-aware width promotions
    try testing.expectEqual(@as(u16, 2), glyphWidth("⚠️")); // U+26A0 + U+FE0F
    try testing.expectEqual(@as(u16, 2), glyphWidth("🇦🇺")); // Flag pair
    try testing.expectEqual(@as(u16, 1), glyphWidth("☕︎")); // Demoted with U+FE0E
}

test "Icon: custom glyph overrides" {
    const testing = std.testing;

    const opt: Option = .{
        .style = .ascii,
        .custom = .{
            .lock = "SECURE",
            .coffee = "BREW",
        },
    };

    try testing.expectEqualStrings("SECURE", getGlyphWithOption(.lock, opt));
    try testing.expectEqualStrings("BREW", getGlyphWithOption(.coffee, opt));
    try testing.expectEqualStrings("[!]", getGlyphWithOption(.warning, opt));
}
