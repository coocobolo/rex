const std = @import("std");
const testing = std.testing;

const KitFont = @import("KitFont.zig");
const ft = @import("root.zig");
const icons = @import("../kit/icons.zig");
const text = @import("../kit/text.zig");

const inter: KitFont.Files = .{
    .regular = "assets/fonts/Inter-Regular.ttf",
    .medium = "assets/fonts/Inter-Medium.ttf",
    .semibold = "assets/fonts/Inter-SemiBold.ttf",
};

test "KitFont: widths are in logical pixels and grow with the text" {
    var font = try KitFont.init(inter, .{});
    defer font.deinit();

    try testing.expectEqual(0, font.width("", .sm, .proportional));
    const one = font.width("Copied", .sm, .proportional);
    const two = font.width("Copied 3 lines", .sm, .proportional);
    try testing.expect(one > 20 and one < 60);
    try testing.expect(two > one);
    // A larger style is wider; a heavier one is at least as wide.
    try testing.expect(font.width("Copied", .lg_semibold, .proportional) > one);
    try testing.expect(font.width("Copied", .sm_medium, .proportional) >= one);
    try testing.expect(font.advance(.sm, ' ') > 0);
}

test "KitFont: the same text has nearly the same logical width at every scale" {
    var widths: [4]f32 = undefined;
    for ([_]f32{ 1, 1.25, 1.5, 2 }, &widths) |scale, *width| {
        var font = try KitFont.init(inter, .{ .scale = scale });
        defer font.deinit();
        width.* = font.width("Selection is on the clipboard.", .sm, .proportional);
    }
    for (widths[1..]) |width| try testing.expectApproxEqRel(widths[0], width, 0.01);
}

test "KitFont: pair kerning comes from GPOS and tightens AV" {
    var kerned = try KitFont.init(inter, .{ .kerning = .pairs });
    defer kerned.deinit();
    var plain = try KitFont.init(inter, .{ .kerning = .off });
    defer plain.deinit();

    try testing.expectEqual(0, plain.kern(.lg_semibold, 'A', 'V'));
    // At 18 px: A,V -1.359 px, T,o -1.406 px, n,n 0 (measured 2026-11-12).
    // The variable face gives 0 for every pair.
    const av = kerned.kern(.lg_semibold, 'A', 'V');
    try testing.expect(av < -1 and av > -2);
    const to = kerned.kern(.lg_semibold, 'T', 'o');
    try testing.expect(to < -1 and to > -2);
    try testing.expectEqual(0, kerned.kern(.lg_semibold, 'n', 'n'));
    try testing.expect(kerned.width("AVATAR", .lg_semibold, .proportional) < plain.width("AVATAR", .lg_semibold, .proportional));
    try testing.expectEqual(plain.width("nnnn", .sm, .proportional), kerned.width("nnnn", .sm, .proportional));
}

test "KitFont: glyphs rasterize, and bad UTF-8 measures as replacement characters" {
    var font = try KitFont.init(inter, .{ .scale = 1.25 });
    defer font.deinit();

    const glyph = try font.rasterize(.sm, 'A');
    try testing.expect(glyph.width > 0 and glyph.height > 0);
    try testing.expectEqual(.gray, glyph.kind);
    const space = try font.rasterize(.sm, ' ');
    try testing.expectEqual(0, space.width);

    try testing.expect(font.baseline(.sm) > 0);
    try testing.expect(font.baseline(.sm) < 20 * 1.25);
    // Two stray bytes are two replacement characters, not a crash.
    try testing.expectEqual(font.width("\u{FFFD}\u{FFFD}", .sm, .proportional), font.width("\xff\xfe", .sm, .proportional));
}

test "KitFont: remembered kerning and advances follow the scale" {
    var font = try KitFont.init(inter, .{});
    defer font.deinit();

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
    var plain = try KitFont.init(inter, .{});
    defer plain.deinit();
    var files = inter;
    files.fallback = "assets/fonts/GoogleSansCode[wght].ttf";
    var font = try KitFont.init(files, .{});
    defer font.deinit();

    // U+2500, a box-drawing line: in Google Sans Code, not in Inter.
    const missing = try plain.rasterize(.sm, 0x2500);
    const missing_width = missing.width;
    const missing_height = missing.height;
    const line = try font.rasterize(.sm, 0x2500);
    // A horizontal line, not the tall box Inter draws for a missing glyph.
    try testing.expect(missing_height > missing_width);
    try testing.expect(line.width > line.height * 2);
    try testing.expect(font.advance(.sm, 0x2500) != plain.advance(.sm, 0x2500));
    try testing.expect(font.width("a\u{2500}b", .sm, .proportional) > font.width("ab", .sm, .proportional));

    // What both have is still Inter's, and what neither has is unchanged.
    try testing.expectEqual(plain.width("Caf\u{e9}", .sm, .proportional), font.width("Caf\u{e9}", .sm, .proportional));
    try testing.expectEqual(plain.advance(.sm, 0x4E2D), font.advance(.sm, 0x4E2D));
}

test "KitFont: tabular ASCII digits share one cell" {
    var font = try KitFont.init(inter, .{});
    defer font.deinit();

    // Inter SemiBold: "1" is narrower than "4" (866 vs 1,364 font units).
    const one = font.step(.xxxl_semibold, .tabular, null, '1');
    const four = font.step(.xxxl_semibold, .tabular, null, '4');
    try testing.expect(one.before > four.before);
    const cell = one.before + one.after;
    try testing.expectEqual(cell, four.before + four.after);
    try testing.expectEqual(@round(cell), cell);
    try testing.expectEqual(font.width("11:11", .xxxl_semibold, .tabular), font.width("44:44", .xxxl_semibold, .tabular));
    try testing.expect(font.width("11:11", .xxxl_semibold, .proportional) < font.width("44:44", .xxxl_semibold, .proportional));
    try testing.expectEqual(font.width("hm", .xl_semibold, .proportional), font.width("hm", .xl_semibold, .tabular));
}

test "KitFont: tracking is one gap between glyphs" {
    var font = try KitFont.init(inter, .{});
    defer font.deinit();

    const digit = font.width("1", .xxxl_semibold, .tabular);
    try testing.expectApproxEqAbs(digit * 2 - 2, font.width("11", .xxxl_semibold, .tabular), 0.01);
    const compact = font.width("1", .xxl_semibold, .tabular);
    try testing.expectApproxEqAbs(compact * 2 - 1, font.width("11", .xxl_semibold, .tabular), 0.01);
}

test "KitFont: a tabular digit keeps its logical width when the scale changes" {
    var font = try KitFont.init(inter, .{});
    defer font.deinit();

    const at_one = font.width("1", .xl_semibold, .tabular);
    try font.setScale(2);
    try testing.expectApproxEqAbs(at_one, font.width("1", .xl_semibold, .tabular), 0.51);
}

test "KitFont: the large semibold styles" {
    try testing.expectEqual(24, text.Style.xl_semibold.metrics().size);
    try testing.expectEqual(32, text.Style.xl_semibold.metrics().line_height);
    try testing.expectEqual(0, text.Style.xl_semibold.metrics().tracking);
    try testing.expectEqual(56, text.Style.xxl_semibold.metrics().size);
    try testing.expectEqual(64, text.Style.xxl_semibold.metrics().line_height);
    try testing.expectEqual(-1, text.Style.xxl_semibold.metrics().tracking);
    try testing.expectEqual(80, text.Style.xxxl_semibold.metrics().size);
    try testing.expectEqual(88, text.Style.xxxl_semibold.metrics().line_height);
    try testing.expectEqual(-2, text.Style.xxxl_semibold.metrics().tracking);

    var font = try KitFont.init(inter, .{});
    defer font.deinit();
    try testing.expect(font.width("18:42", .xxxl_semibold, .proportional) > font.width("18:42", .xxl_semibold, .proportional));
    try testing.expect(font.width("18:42", .xxl_semibold, .proportional) > font.width("18:42", .xl_semibold, .proportional));
    try testing.expect(font.width("18:42", .xl_semibold, .proportional) > font.width("18:42", .lg_semibold, .proportional));
}

test "KitFont: timer digits sit inside the line box" {
    var font = try KitFont.init(inter, .{});
    defer font.deinit();
    const samples = [_]struct { text.Style, u8 }{
        .{ .xxl_semibold, 64 },
        .{ .xxxl_semibold, 88 },
    };
    for (samples) |sample| {
        const style, const line = sample;
        const ink = try font.rasterize(style, '8');
        const baseline = font.baseline(style);
        const top = baseline - @as(f32, @floatFromInt(ink.bearing_y));
        const bottom = top + @as(f32, @floatFromInt(ink.height));
        try testing.expect(top >= 0 and bottom <= @as(f32, @floatFromInt(line)));
    }
}

test "KitFont: its size" {
    // Nearly all of it is the kerning table: eight styles of 95 by 95
    // pairs, two bytes each.
    try testing.expectEqual(152496, @sizeOf(KitFont));
}

test "KitFont: is the kit's measurer" {
    var font = try KitFont.init(inter, .{});
    defer font.deinit();
    const measurer = font.measurer();
    try testing.expectEqual(font.width("Close this window?", .lg_semibold, .proportional), measurer.width("Close this window?", .lg_semibold, .proportional));
}

test "KitFont: embedded icon subset matches lucide.ttf bitmaps" {
    var font = try KitFont.init(inter, .{});
    defer font.deinit();

    const ref_lib = try ft.initFreeType();
    defer ft.doneFreeType(ref_lib) catch {};
    const ref_face = try ft.initFace(ref_lib, "assets/fonts/lucide.ttf", 16);

    inline for (@typeInfo(icons).@"struct".decls) |decl| {
        const cp: u21 = @field(icons, decl.name);
        if (cp == icons.none) continue;

        const got = try font.rasterizeIcon(cp, 16);
        try ft.ftCheck(ft.c.FT_Set_Char_Size(ref_face, 0, 16 * 64, 72, 72), "FT_Set_Char_Size");
        try ft.loadChar(ref_face, cp, ft.c.FT_LOAD_RENDER | ft.c.FT_LOAD_NO_HINTING);
        const slot = ref_face.*.glyph;
        const bmp = slot.*.bitmap;

        try testing.expectEqual(@as(u16, @intCast(slot.*.advance.x >> 6)), got.advance);
        try testing.expectEqual(@as(i16, @intCast(slot.*.bitmap_left)), got.bearing_x);
        try testing.expectEqual(@as(i16, @intCast(slot.*.bitmap_top)), got.bearing_y);
        try testing.expectEqual(@as(u16, @intCast(bmp.width)), got.width);
        try testing.expectEqual(@as(u16, @intCast(bmp.rows)), got.height);
        const rows: usize = got.height;
        const cols: usize = got.width;
        for (0..rows) |r| {
            const ref_row = bmp.buffer[r * @as(usize, @intCast(bmp.pitch)) ..][0..cols];
            const got_row = got.bitmap[r * got.pitch ..][0..cols];
            try testing.expectEqualSlices(u8, ref_row, got_row);
        }
    }
}
