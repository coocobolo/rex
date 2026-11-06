const std = @import("std");
const testing = std.testing;
const alloc = std.testing.allocator;

const Atlas = @import("Atlas.zig");
const window = @import("Window.zig");
const gl = @import("gl.zig");
const ft = @import("../freetype/root.zig");

const FontConfig = ft.FontConfig;
const Rasterizer = ft.Rasterizer;

const testGlContext = window.testGlContext;

const test_font: FontConfig = .{
    .max_size = 64,
    .min_size = 0,
    .width = 0,
    .font = .{
        .family = .{
            .static = .{
                .regular = "testdata/font/NotoSansMono-Regular.ttf",
                .bold = "testdata/font/NotoSansMono-Bold.ttf",
                .italic = "testdata/font/NotoSans-Italic.ttf",
                .bold_italic = "testdata/font/NotoSans-BoldItalic.ttf",
            },
        },
        .emoji = .static("testdata/font/NotoColorEmoji.ttf"),
    },
    .height = 16,
};

/// Returns a fake gray glyph backed by a stack buffer.
/// The caller owns the buffer, keep it alive for the duration of upload().
fn fakeGrayGlyph(buf: []u8, width: u16, height: u16) Rasterizer.Glyph {
    @memset(buf[0 .. @as(usize, width) * height], 0xFF); // fully opaque
    return .{
        .bitmap = buf.ptr,
        .width = width,
        .height = height,
        .pitch = width, // no padding
        .bearing_x = 0,
        .bearing_y = @intCast(height),
        .advance = width,
        .kind = .gray,
    };
}

/// Returns a fake BGRA color glyph backed by a stack buffer.
fn fakeColorGlyph(buf: []u8, w: u16, h: u16) Rasterizer.Glyph {
    // Fill with opaque red in BGRA: B=0 G=0 R=255 A=255
    var i: usize = 0;
    while (i < @as(usize, w) * h * 4) : (i += 4) {
        buf[i + 0] = 0; // B
        buf[i + 1] = 0; // G
        buf[i + 2] = 255; // R
        buf[i + 3] = 255; // A
    }
    return .{
        .bitmap = buf.ptr,
        .width = w,
        .height = h,
        .pitch = @as(u16, w) * 4,
        .bearing_x = 0,
        .bearing_y = @intCast(h),
        .advance = w,
        .kind = .color,
    };
}

test "GL context: core profile at the required version" {
    try testGlContext();
    var major: c_int = 0;
    var minor: c_int = 0;
    var profile: c_int = 0;
    gl.getIntegerv(gl.MAJOR_VERSION, &major);
    gl.getIntegerv(gl.MINOR_VERSION, &minor);
    gl.getIntegerv(gl.CONTEXT_PROFILE_MASK, &profile);
    const want = window.gl_version;
    try testing.expect(major > want.major or (major == want.major and minor >= want.minor));
    try testing.expect(profile & gl.CONTEXT_CORE_PROFILE_BIT != 0);
}

test "upload: gray glyph returns valid metric" {
    try testGlContext();

    var atlas = try Atlas.create(alloc, .{});
    defer atlas.destroy();

    var buf: [8 * 16]u8 = undefined;
    const glyph = fakeGrayGlyph(&buf, 8, 16);

    const m = try atlas.upload(glyph);

    try testing.expectEqual(8, m.width);
    try testing.expectEqual(16, m.height);
    try testing.expectEqual(8, m.advance);
    try testing.expectEqual(.gray, m.kind);

    // packed at origin on first upload
    try testing.expectEqual(0, m.atlas_x);
    try testing.expectEqual(0, m.atlas_y);
}

test "upload: color glyph goes into color atlas" {
    try testGlContext();

    var atlas = try Atlas.create(alloc, .{});
    defer atlas.destroy();

    var buf: [32 * 32 * 4]u8 = undefined;
    const glyph = fakeColorGlyph(&buf, 32, 32);

    const m = try atlas.upload(glyph);

    try testing.expectEqual(32, m.width);
    try testing.expectEqual(32, m.height);
    try testing.expectEqual(32, m.advance);
    try testing.expectEqual(.color, m.kind);

    // color packing state is independent, also starts at origin on first upload
    try testing.expectEqual(0, m.atlas_x);
    try testing.expectEqual(0, m.atlas_y);
}

/// Reads back every byte of `texture` in `format` into `out`.
fn readTexture(texture: gl.GLuint, format: gl.GLenum, out: []u8) void {
    gl.pixelStorei(gl.PACK_ALIGNMENT, 1);
    gl.bindTexture(gl.TEXTURE_2D, texture);
    gl.getTexImage(gl.TEXTURE_2D, 0, format, gl.UNSIGNED_BYTE, out.ptr);
    gl.bindTexture(gl.TEXTURE_2D, 0);
    gl.pixelStorei(gl.PACK_ALIGNMENT, 4);
}

test "invalidate: clears both textures to zero, partial tiles included" {
    try testGlContext();

    // Not a multiple of the clear tile in either direction, so the edge
    // tiles are partial.
    const width = 100;
    const height = 70;
    var atlas = try Atlas.create(alloc, .{ .width = width, .height = height });
    defer atlas.destroy();

    var gray_glyph: [8 * 16]u8 = undefined;
    _ = try atlas.upload(fakeGrayGlyph(&gray_glyph, 8, 16));
    var color_glyph: [8 * 8 * 4]u8 = undefined;
    _ = try atlas.upload(fakeColorGlyph(&color_glyph, 8, 8));

    var gray: [width * height]u8 = undefined;
    var color: [width * height * 4]u8 = undefined;

    // The uploads must be visible first, or the check below proves nothing.
    readTexture(atlas.gray_texture, gl.RED, &gray);
    readTexture(atlas.color_texture, gl.RGBA, &color);
    try testing.expect(!std.mem.allEqual(u8, &gray, 0));
    try testing.expect(!std.mem.allEqual(u8, &color, 0));

    atlas.invalidate();

    readTexture(atlas.gray_texture, gl.RED, &gray);
    readTexture(atlas.color_texture, gl.RGBA, &color);
    try testing.expect(std.mem.allEqual(u8, &gray, 0));
    try testing.expect(std.mem.allEqual(u8, &color, 0));
}

test "upload: zero-size glyph (space) returns zero metrics without GL Upload" {
    try testGlContext();

    var atlas = try Atlas.create(alloc, .{});
    defer atlas.destroy();

    const glyph: Rasterizer.Glyph = .{
        .bitmap = undefined, // must not be accessed
        .width = 0,
        .height = 0,
        .pitch = 0,
        .bearing_x = 0,
        .bearing_y = 0,
        .advance = 8, // space still advances the cursor
        .kind = .gray,
    };
    const m = try atlas.upload(glyph);

    try testing.expectEqual(0, m.width);
    try testing.expectEqual(0, m.height);
    try testing.expectEqual(8, m.advance); // advance preserved
    try testing.expectEqual(.gray, m.kind);

    // packing state must NOT have advanced (no space consumed in atlas)
    try testing.expectEqual(0, atlas.state.gray.next_x);
    try testing.expectEqual(0, atlas.state.gray.next_y);
}

test "upload: gray and color packing states are independent" {
    try testGlContext();

    var atlas = try Atlas.create(alloc, .{});
    defer atlas.destroy();

    var gbuf: [8 * 16]u8 = undefined;
    var cbuf: [32 * 32 * 4]u8 = undefined;

    const mg = try atlas.upload(fakeGrayGlyph(&gbuf, 8, 16));
    const mc = try atlas.upload(fakeColorGlyph(&cbuf, 32, 32));

    // both start at (0,0) in their respective atlases
    try testing.expectEqual(@as(u16, 0), mg.atlas_x);
    try testing.expectEqual(@as(u16, 0), mc.atlas_x);
    // gray cursor advanced, color cursor advanced independently
    try testing.expectEqual(@as(u16, 8), atlas.state.gray.next_x);
    try testing.expectEqual(@as(u16, 32), atlas.state.color.next_x);
}

test "upload: a pitch shorter than a row returns InvalidPitch" {
    try testGlContext();

    var atlas = try Atlas.create(alloc, .{});
    defer atlas.destroy();

    var buf: [8 * 16 * 4]u8 = undefined;
    var gray = fakeGrayGlyph(&buf, 8, 16);
    gray.pitch = 7;
    try testing.expectError(error.InvalidPitch, atlas.upload(gray));

    var color = fakeColorGlyph(&buf, 8, 16);
    color.pitch = 8 * 4 - 2; // not whole pixels
    try testing.expectError(error.InvalidPitch, atlas.upload(color));

    // Nothing was packed.
    try testing.expectEqual(0, atlas.state.gray.next_x);
    try testing.expectEqual(0, atlas.state.color.next_x);
}

test "upload: glyph wider than atlas returns GlyphTooWide" {
    try testGlContext();

    var atlas = try Atlas.create(alloc, .{});
    defer atlas.destroy();

    // width > atlas width
    const glyph: Rasterizer.Glyph = .{
        .bitmap = undefined,
        .width = atlas.width + 1,
        .height = 16,
        .pitch = atlas.width + 1,
        .bearing_x = 0,
        .bearing_y = 16,
        .advance = atlas.width + 1,
        .kind = .gray,
    };

    try testing.expectError(error.GlyphTooWide, atlas.upload(glyph));
    // packing state must be unchanged after the error
    try testing.expectEqual(@as(u16, 0), atlas.state.gray.next_x);
    try testing.expectEqual(@as(u16, 0), atlas.state.gray.next_y);
}

fn testCreateAndPreRasterize() !void {
    var rasterizer = try Rasterizer.create(alloc, test_font);
    defer rasterizer.destroy(alloc);

    var atlas = try Atlas.create(alloc, .{});
    defer atlas.destroy();

    atlas.preRasterize(alloc, &rasterizer, .{ .start = 0x20, .end = 0x7F });

    for (0x20..0x7F) |cp| {
        const m = try atlas.get(alloc, &rasterizer, @intCast(cp), .regular, .single);
        try testing.expect(m.atlas_x < atlas.width);
        try testing.expect(m.atlas_y < atlas.height);
    }
}

fn testCacheHit() !void {
    var rasterizer = try Rasterizer.create(alloc, test_font);
    defer rasterizer.destroy(alloc);

    var atlas = try Atlas.create(alloc, .{});
    defer atlas.destroy();

    const m1 = try atlas.get(alloc, &rasterizer, 'A', .regular, .single);
    const m2 = try atlas.get(alloc, &rasterizer, 'A', .regular, .single);
    try testing.expectEqual(m1, m2);
    const cached = atlas.ascii_lut[@intFromEnum(Rasterizer.FaceKind.regular)][@intFromEnum(Rasterizer.Span.single)]['A'];
    try testing.expect(cached != null);
    try testing.expectEqual(m1, cached.?);
}

fn testBoldVsRegular() !void {
    var rasterizer = try Rasterizer.create(alloc, test_font);
    defer rasterizer.destroy(alloc);

    var atlas = try Atlas.create(alloc, .{});
    defer atlas.destroy();

    const m_reg = try atlas.get(alloc, &rasterizer, 'A', .regular, .single);
    const m_bold = try atlas.get(alloc, &rasterizer, 'A', .bold, .single);
    try testing.expect(m_reg.atlas_x != m_bold.atlas_x or m_reg.atlas_y != m_bold.atlas_y);
}

fn testZeroSizeMetric() !void {
    var rasterizer = try Rasterizer.create(alloc, test_font);
    defer rasterizer.destroy(alloc);

    var atlas = try Atlas.create(alloc, .{});
    defer atlas.destroy();

    const m1 = try atlas.get(alloc, &rasterizer, 0x20, .regular, .single);
    try testing.expectEqual(@as(u16, 0), m1.width);
    try testing.expectEqual(@as(u16, 0), m1.height);
    try testing.expect(m1.advance > 0);

    const m2 = try atlas.get(alloc, &rasterizer, 0x20, .regular, .single);
    try testing.expectEqual(m1, m2);
}

fn testGetSequenceCacheMiss() !void {
    var rasterizer = try Rasterizer.create(alloc, test_font);
    defer rasterizer.destroy(alloc);
    var atlas = try Atlas.create(alloc, .{});
    defer atlas.destroy();

    // rasterizeSequence still falls back to cps[0], so a real ZWJ
    // sequence gives the base code point glyph.
    const cps = [_]u21{ 0x1F468, 0x200D, 0x1F469 }; // 👨‍👩 ZWJ sequence
    const m = try atlas.getSequence(alloc, &rasterizer, &cps, .emoji, .double);

    // Must have been packed somewhere in the color atlas
    try testing.expect(m.atlas_x < atlas.width);
    try testing.expect(m.atlas_y < atlas.height);
    try testing.expectEqual(.color, m.kind);
}

fn testGetSequenceCacheHit() !void {
    var rasterizer = try Rasterizer.create(alloc, test_font);
    defer rasterizer.destroy(alloc);
    var atlas = try Atlas.create(alloc, .{});
    defer atlas.destroy();

    const cps = [_]u21{ 0x1F468, 0x200D, 0x1F469 };
    const m1 = try atlas.getSequence(alloc, &rasterizer, &cps, .emoji, .double);
    const m2 = try atlas.getSequence(alloc, &rasterizer, &cps, .emoji, .double); // cache hit
    try testing.expectEqual(m1, m2);
}

fn testGetSequenceEmptyReturnsError() !void {
    var rasterizer = try Rasterizer.create(alloc, test_font);
    defer rasterizer.destroy(alloc);
    var atlas = try Atlas.create(alloc, .{});
    defer atlas.destroy();

    const cps = [_]u21{};
    try testing.expectError(error.EmptySequence, atlas.getSequence(alloc, &rasterizer, &cps, .emoji, .double));
}

test "atlas integration" {
    try testGlContext();

    try testCreateAndPreRasterize();
    try testCacheHit();
    try testBoldVsRegular();
    try testZeroSizeMetric();
    try testGetSequenceCacheMiss();
    try testGetSequenceCacheHit();
    try testGetSequenceEmptyReturnsError();
}

test "PackingState: first glyph placed at origin" {
    var s: Atlas.PackingState = .init;
    const x, const y = try s.pack(8, 16, 1024, 1024);
    try testing.expectEqual(0, x);
    try testing.expectEqual(0, y);
    try testing.expectEqual(8, s.next_x);
    try testing.expectEqual(16, s.row_h);
}

test "PackingState: glyphs pack left-to-right on same shelf" {
    var s: Atlas.PackingState = .init;
    _ = try s.pack(8, 16, 1024, 1024);
    const x, const y = try s.pack(8, 16, 1024, 1024);
    try testing.expectEqual(8, x);
    try testing.expectEqual(0, y);
}

test "PackingState: shelf advance when row overflows" {
    var s: Atlas.PackingState = .init;
    _ = try s.pack(512, 16, 1024, 1024);
    _ = try s.pack(512, 16, 1024, 1024); // fills shelf exactly
    const x, const y = try s.pack(8, 16, 1024, 1024); // must go to next shelf
    try testing.expectEqual(0, x);
    try testing.expectEqual(16, y); // next_y = row_h of previous shelf
}

test "PackingState: row_height tracks tallest glyph on shelf" {
    var s: Atlas.PackingState = .init;
    _ = try s.pack(8, 10, 1024, 1024);
    _ = try s.pack(8, 20, 1024, 1024); // taller
    _ = try s.pack(8, 5, 1024, 1024);

    try testing.expectEqual(20, s.row_h);
}

test "PackingState: glyph wider than atlas returns GlyphTooWide" {
    var s: Atlas.PackingState = .init;
    try testing.expectError(error.GlyphTooWide, s.pack(1025, 16, 1024, 1024));
    // state must be unchanged after the error
    try testing.expectEqual(@as(u16, 0), s.next_x);
    try testing.expectEqual(@as(u16, 0), s.next_y);
}

test "PackingState: atlas full returns AtlasFull" {
    var s: Atlas.PackingState = .init;
    _ = try s.pack(1024, 512, 1024, 1024); // first shelf, 512px tall
    _ = try s.pack(1024, 512, 1024, 1024); // second shelf, fills atlas
    try testing.expectError(error.AtlasFull, s.pack(8, 16, 1024, 1024));
}

test "hashSequence: same sequence produces same hash" {
    const cps = [_]u21{ 0x1F468, 0x200D, 0x1F469 };
    try testing.expectEqual(Atlas.hashSequence(&cps, .emoji, .single), Atlas.hashSequence(&cps, .emoji, .single));
}

test "hashSequence: order matters" {
    const a = [_]u21{ 0x41, 0x42 }; // A, B
    const b = [_]u21{ 0x42, 0x41 }; // B, A
    try testing.expect(Atlas.hashSequence(&a, .emoji, .single) != Atlas.hashSequence(&b, .emoji, .single));
}

test "hashSequence: different sequences differ" {
    const a = [_]u21{ 0x1F468, 0x200D, 0x1F469 };
    const b = [_]u21{ 0x1F469, 0x200D, 0x1F468 }; // reversed
    try testing.expect(Atlas.hashSequence(&a, .emoji, .single) != Atlas.hashSequence(&b, .emoji, .single));
}

test "hashSequence: single codepoint is stable" {
    const cps = [_]u21{0x1F600}; // 😀
    try testing.expectEqual(Atlas.hashSequence(&cps, .emoji, .single), Atlas.hashSequence(&cps, .emoji, .single));
}

test "hashSequence: length-1 vs length-2 differ" {
    const a = [_]u21{0x41};
    const b = [_]u21{ 0x41, 0x41 };
    try testing.expect(Atlas.hashSequence(&a, .emoji, .single) != Atlas.hashSequence(&b, .emoji, .single));
}

test "hashSequence: span is part of the key" {
    const cps = [_]u21{ 0x2764, 0xFE0F }; // ❤️
    try testing.expect(Atlas.hashSequence(&cps, .emoji, .single) != Atlas.hashSequence(&cps, .emoji, .double));
}

test "clampSize: keeps the size within 1 and the driver limit" {
    try testing.expectEqual(2048, Atlas.clampSize(2048, 16384));
    try testing.expectEqual(1, Atlas.clampSize(0, 16384));
    try testing.expectEqual(4096, Atlas.clampSize(8192, 4096));
    try testing.expectEqual(8192, Atlas.clampSize(8192, 0));
}

test "create: uses the configured size" {
    try testGlContext();

    var atlas = try Atlas.create(alloc, .{ .width = 64, .height = 32 });
    defer atlas.destroy();
    try testing.expectEqual(64, atlas.width);
    try testing.expectEqual(32, atlas.height);

    var buf: [65 * 8]u8 = @splat(0);
    const glyph: Rasterizer.Glyph = .{
        .bitmap = &buf,
        .width = 65,
        .height = 8,
        .pitch = 65,
        .bearing_x = 0,
        .bearing_y = 8,
        .advance = 65,
        .kind = .gray,
    };
    try testing.expectError(error.GlyphTooWide, atlas.upload(glyph));
}
