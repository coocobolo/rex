const std = @import("std");
const testing = std.testing;

const KitFont = @import("KitFont.zig");
const text = @import("../kit/text.zig");

const inter: KitFont.Files = .{
    .regular = "assets/fonts/Inter-Regular.ttf",
    .medium = "assets/fonts/Inter-Medium.ttf",
    .semibold = "assets/fonts/Inter-SemiBold.ttf",
    .icons = "assets/fonts/lucide.ttf",
};

test "KitFont: widths are in logical pixels and grow with the text" {
    var font = try KitFont.create(inter, .{});
    defer font.destroy();

    try testing.expectEqual(0, font.width("", .sm));
    const one = font.width("Copied", .sm);
    const two = font.width("Copied 3 lines", .sm);
    try testing.expect(one > 20 and one < 60);
    try testing.expect(two > one);
    // A larger style is wider; a heavier one is at least as wide.
    try testing.expect(font.width("Copied", .lg_semibold) > one);
    try testing.expect(font.width("Copied", .sm_medium) >= one);
    try testing.expect(font.advance(.sm, ' ') > 0);
}

test "KitFont: the same text has nearly the same logical width at every scale" {
    var widths: [4]f32 = undefined;
    for ([_]f32{ 1, 1.25, 1.5, 2 }, &widths) |scale, *width| {
        var font = try KitFont.create(inter, .{ .scale = scale });
        defer font.destroy();
        width.* = font.width("Selection is on the clipboard.", .sm);
    }
    for (widths[1..]) |width| try testing.expectApproxEqRel(widths[0], width, 0.01);
}

test "KitFont: pair kerning comes from GPOS and tightens AV" {
    var kerned = try KitFont.create(inter, .{ .kerning = .pairs });
    defer kerned.destroy();
    var plain = try KitFont.create(inter, .{ .kerning = .off });
    defer plain.destroy();

    try testing.expectEqual(0, plain.kern(.lg_semibold, 'A', 'V'));
    const av = kerned.kern(.lg_semibold, 'A', 'V');
    std.debug.print("\nInter 18 px semibold: kern(A,V) = {d:.3} px, kern(T,o) = {d:.3} px, kern(n,n) = {d:.3} px\n", .{ av, kerned.kern(.lg_semibold, 'T', 'o'), kerned.kern(.lg_semibold, 'n', 'n') });
    // About -1.4 px at 18 px; the variable face gives 0 here.
    try testing.expect(av < -1 and av > -2);
    try testing.expect(kerned.width("AVATAR", .lg_semibold) < plain.width("AVATAR", .lg_semibold));
    try testing.expectEqual(plain.width("nnnn", .sm), kerned.width("nnnn", .sm));
}

test "KitFont: glyphs rasterize, and bad UTF-8 measures as replacement characters" {
    var font = try KitFont.create(inter, .{ .scale = 1.25 });
    defer font.destroy();

    const glyph = try font.rasterize(.sm, 'A');
    try testing.expect(glyph.width > 0 and glyph.height > 0);
    try testing.expectEqual(.gray, glyph.kind);
    const space = try font.rasterize(.sm, ' ');
    try testing.expectEqual(0, space.width);

    try testing.expect(font.baseline(.sm) > 0);
    try testing.expect(font.baseline(.sm) < 20 * 1.25);
    // Two stray bytes are two replacement characters, not a crash.
    try testing.expectEqual(font.width("\u{FFFD}\u{FFFD}", .sm), font.width("\xff\xfe", .sm));
}

test "KitFont: remembered kerning and advances follow the scale" {
    var font = try KitFont.create(inter, .{});
    defer font.destroy();

    // Asked twice: the second answer comes from the table.
    const pair = font.kern(.lg_semibold, 'A', 'V');
    try testing.expect(pair < -1);
    try testing.expectEqual(pair, font.kern(.lg_semibold, 'A', 'V'));
    try testing.expectEqual(0, font.kern(.lg_semibold, 'n', 'n'));
    // The multiplication sign of a close button, and a pair outside ASCII.
    const times = font.advance(.sm, 0xD7);
    try testing.expect(times > 4);
    try testing.expectEqual(times, font.advance(.sm, 0xD7));
    try testing.expect(font.advance(.lg_semibold, 0xD7) > times);
    try testing.expectEqual(0, font.kern(.sm, 0xD7, 0xD7));

    try font.setScale(2);
    try testing.expectApproxEqAbs(pair * 2, font.kern(.lg_semibold, 'A', 'V'), 0.05);
    try testing.expectApproxEqAbs(times * 2, font.advance(.sm, 0xD7), 0.05);
}

test "KitFont: a code point the UI font lacks comes from the fallback face" {
    var plain = try KitFont.create(inter, .{});
    defer plain.destroy();
    var files = inter;
    files.fallback = "assets/fonts/GoogleSansCode[wght].ttf";
    var font = try KitFont.create(files, .{});
    defer font.destroy();

    // U+2500, a box-drawing line: in Google Sans Code, not in Inter.
    const missing = try plain.rasterize(.sm, 0x2500);
    const missing_width = missing.width;
    const missing_height = missing.height;
    const line = try font.rasterize(.sm, 0x2500);
    // A horizontal line, not the tall box Inter draws for a missing glyph.
    try testing.expect(missing_height > missing_width);
    try testing.expect(line.width > line.height * 2);
    try testing.expect(font.advance(.sm, 0x2500) != plain.advance(.sm, 0x2500));
    try testing.expect(font.width("a\u{2500}b", .sm) > font.width("ab", .sm));

    // What both have is still Inter's, and what neither has is unchanged.
    try testing.expectEqual(plain.width("Caf\u{e9}", .sm), font.width("Caf\u{e9}", .sm));
    try testing.expectEqual(plain.advance(.sm, 0x4E2D), font.advance(.sm, 0x4E2D));
}

test "KitFont: its size" {
    // Nearly all of it is the kerning table: five styles of 95 by 95
    // pairs, two bytes each.
    try testing.expectEqual(95592, @sizeOf(KitFont));
}

test "KitFont: is the kit's measurer" {
    var font = try KitFont.create(inter, .{});
    defer font.destroy();
    const measurer = font.measurer();
    try testing.expectEqual(font.width("Close this window?", .lg_semibold), measurer.width("Close this window?", .lg_semibold));
}
