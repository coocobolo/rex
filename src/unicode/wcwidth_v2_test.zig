const std = @import("std");
const testing = std.testing;
const tables = @import("wcwidth_table.zig");

const wcwidth_mod = @import("wcwidth_v2.zig");

const wcwidth = wcwidth_mod.wcwidth;
const lookup = wcwidth_mod.lookup;
const Width = wcwidth_mod.Width;
const AmbiguousWidth = wcwidth_mod.AmbiguousWidth;

const Property = tables.Property;

const corpus = [_][]const u8{
    @embedFile("testdata/fuzz/wcwidth/crash-630ff0a4f49ee617.bin"),
    @embedFile("testdata/fuzz/wcwidth/crash-8185a9074f803ffc.bin"),
};

const c = @cImport({
    // wcwidth() is specified by X/Open/POSIX.
    @cDefine("_XOPEN_SOURCE", "700");
    @cInclude("locale.h");
    @cInclude("wchar.h");
});

fn useUtf8Locale() !void {
    // C.UTF-8 is normally available on Linux.
    if (c.setlocale(c.LC_CTYPE, "C.UTF-8") == null) {
        return error.SkipZigTest;
    }
}

fn libcWcwidth(codepoint: u21) c_int {
    return c.wcwidth(@as(c.wchar_t, @intCast(codepoint)));
}

fn isScalarValue(codepoint: u21) bool {
    return codepoint <= 0x10ffff and !(codepoint >= 0xd800 and codepoint <= 0xdfff);
}

/// Maps libc's raw wcwidth() return value to our Width enum.
/// Returns null when libc reports "non-printable" (-1), since that's
/// not a direct 1:1 mapping to a single Width value at this layer --
/// the caller decides what -1 means for our model.
fn expectedFromLibc(codepoint: u21, value: c_int) !?Width {
    return switch (value) {
        -1 => null,
        0 => .zero,
        1 => .narrow,
        2 => .wide,
        else => {
            std.debug.print(
                "libc wcwidth(U+{X:0>6}) returned unexpected value {d}\n",
                .{ codepoint, value },
            );
            return error.UnexpectedLibcWidth;
        },
    };
}

fn expectWidth(codepoint: u21, expected: Width, actual: Width) !void {
    if (expected != actual) {
        std.debug.print(
            "width mismatch: U+{X:0>6} | 0x{X} expected={s}, actual={s}\n",
            .{ codepoint, codepoint, @tagName(expected), @tagName(actual) },
        );
    }
    try testing.expectEqual(expected, actual);
}

/// Codepoints where our classification is a documented, deliberate
/// deviation from the *specific* libc oracle bound to this test run.
/// Each entry must cite why (traced to a known libc/UCD discrepancy),
/// per the standard set for the Hangul-jamo and Tags-block overrides.
const known_divergences = std.StaticStringMap(void).initComptime(.{});
// (or a small []const struct{codepoint:u21, why:[]const u8} list --
// a map isn't necessary if the list stays short; the point is it must
// be a reviewable, named list, not an unconditional `return`.)

const KnownDivergence = struct {
    start: u21,
    end: u21, // inclusive
    note: []const u8,
};
const known_divergences_list = [_]KnownDivergence{
    .{
        .start = 0x2637,
        .end = 0x2637,
        .note = "EastAsianWidth.txt marks U+2630..U+2637 (Yijing trigrams) W; " ++
            "glibc's compiled table predates/ignores this and reports 1. " ++
            "We follow the UCD, not glibc, here.",
    },
    // .{
    //     .start = 0x20000,
    //     .end = 0x3FFFD,
    //     .note = "musl's wcwidth unconditionally treats all of Plane 2/3 " ++
    //         "(wc-0x20000U < 0x20000) as width 2, matching EastAsianWidth.txt's " ++
    //         "documented 'unassigned defaults to Wide' rule for these planes. " ++
    //         "glibc instead returns -1 for genuinely unassigned codepoints in " ++
    //         "this range. We follow musl (our §1 compliance target), not the " ++
    //         "ambient glibc oracle. This range subsumes any individual " ++
    //         "unassigned Cn codepoint the fuzzer finds here (e.g. U+356DD); " ++
    //         "do not add per-codepoint entries for this block.",
    // },
    // Hangul jamo (U+1160..U+11FF) and the Tags off-by-one
    // (U+E007F) are resolved at the *table* level (generator overrides),
    // so they should no longer appear as divergences here -- if they do,
    // that's a regression, not a known case.
};

fn findDivergence(codepoint: u21, expected: ?Width, actual: Width) ?KnownDivergence {
    for (known_divergences_list) |d| {
        if (codepoint >= d.start and codepoint <= d.end) return d;
    }

    // Plane 2/3 special case: our table (musl-faithful) always returns
    // .wide here via default_wide_ranges, even for genuinely-unassigned
    // codepoints. glibc instead returns -1 (non-printable) for those.
    // Only swallow the mismatch when it's EXACTLY this shape --
    // expected==null (libc says non-printable) and actual==.wide --
    // so a real bug (e.g. libc disagreeing on an assigned character,
    // or our table producing .narrow/.control/.ambiguous instead of
    // .wide) still fails loudly instead of being masked.
    const in_plane_2_3 = (codepoint >= 0x20000 and codepoint <= 0x3FFFD);
    if (in_plane_2_3 and expected == null and actual == .wide) {
        return .{
            .start = codepoint,
            .end = codepoint,
            .note = "Plane 2/3 unassigned: musl defaults to wide, glibc returns -1",
        };
    }

    return null;
}

fn checkAgainstLibc(codepoint: u21) !void {
    if (!isScalarValue(codepoint)) return; // surrogates/out-of-range: not libc's problem to classify

    const libc_result = libcWcwidth(codepoint);
    const expected = try expectedFromLibc(codepoint, libc_result);

    const actual_narrow = wcwidth(codepoint, .narrow);
    const actual_wide = wcwidth(codepoint, .wide);
    // .ambiguous only changes narrow<->wide; anything else must be
    // identical between the two calls, or the config parameter is
    // leaking into unrelated classifications.
    if (actual_narrow != .narrow and actual_narrow != .wide) {
        try testing.expectEqual(actual_narrow, actual_wide);
    }

    if (findDivergence(codepoint, expected, actual_narrow)) |d| {
        // documented, intentionally skip strict comparison
        std.debug.print("found divergence cp=0x{x} note={s}\n", .{ codepoint, d.note });
        return;
    }

    if (expected == null) {
        // libc considers this non-printable. We must agree it's
        // .control -- NOT silently pass regardless of our answer.
        try expectWidth(codepoint, .control, actual_narrow);
        return;
    }

    try expectWidth(codepoint, expected.?, actual_narrow);
}

fn unpackCodepoint(v: u32) u21 {
    return @intCast(v >> 11);
}

fn unpackSize(v: u32) u32 {
    return ((v >> 3) & 0xff) + 1;
}

fn unpackProperty(v: u32) tables.Property {
    return @enumFromInt(@as(u3, @intCast(v & 0x7)));
}

fn linearLookup(entries: []const u32, cp: u21) tables.Property {
    for (entries) |e| {
        const start = unpackCodepoint(e);
        const size = unpackSize(e);
        if (cp >= start and cp - start < size) return unpackProperty(e);
    }
    return .narrow;
}

test "lookup: codepoint before first table entry is narrow" {
    // U+0000 is handled by wcwidth's fast path, but lookup() itself has
    // no fast path; verify it degrades sanely for codepoints below
    // wherever the generated table actually starts.
    try testing.expectEqual(lookup(0x0041), .narrow);
}

test "lookup: exact lower bound of a known wide range resolves to wide" {
    // U+4E2D (中) falls inside CJK Unified Ideographs, which is
    // unconditionally East_Asian_Width=W.
    try testing.expectEqual(lookup(0x4e2d), .wide);
}

test "lookup: exact upper bound of CJK Unified Ideographs block is wide" {
    // U+9FFF is the last codepoint of the CJK Unified Ideographs block.
    try testing.expectEqual(lookup(0x9fff), .wide);
}

test "lookup: codepoint immediately after a wide range fallsback correctly" {
    // U+A000 (Yi Syllables) is East_Asian_Width=W as well, so this isn't
    // a great "falls back to narrow" example, use a block boundary that
    // actually transitions out of Wide. U+FAFF is the last CJK
    // Compatibility Ideograph (wide); U+FB00 (Latin Ligature ﬀ) is narrow.
    try testing.expectEqual(lookup(0xfaff), .wide);
    try testing.expectEqual(lookup(0xfb00), .narrow);
}

test "lookup: combining mark range boundaries" {
    // U+0300 (combining grave accent) through U+036F (combining latin small letter x)
    // is the full "Combining Diacritical Marks" block, General_Category=Mn for its entirety.
    try testing.expectEqual(lookup(0x0300), .zero);
    try testing.expectEqual(lookup(0x0301), .zero);
    try testing.expectEqual(lookup(0x036f), .zero);

    // U+0370 (Greek capital letter Heta) is the first codepoint after the
    // block and should not leak the .zero classification.
    try testing.expectEqual(lookup(0x0370), .narrow);
}

test "lookup: adjacent/touching ranges resolve to the correct entry" {
    // Variation Selectors Supplement (U+E0100-U+E01EF, Mn) sits right
    // before the end of the generator's musl cross-check ranges; verify
    // the boundary codepoint doesn't bleed into a neighboring entry.
    try testing.expectEqual(lookup(0xe0100), .zero);
    try testing.expectEqual(lookup(0xe01ef), .zero);
}

test "lookup: max valid codepoint does not crash and resolves sanely" {
    // U+10FFFF is the maximum valid Unicode scalar value; assigned or
    // not, lookup() must return without out-of-bounds access.
    _ = lookup(0x10FFFF);
}

test "lookup: unassigned/private-use codepoints default to ambigous, not narrow" {
    // U+E000 (start of Private Use Area) has no East_Asian_Width or
    // General_Category override that would make it non-narrow.
    try testing.expectEqual(lookup(0xe000), .ambiguous);
}

test "lookup: handles codepoint extremes" {
    try testing.expectEqual(lookup(0), .control);
    try testing.expectEqual(lookup(0x10ffff), .control);
}

test "lookup: boundary agreement with linear scan" {
    const entries = tables.entries;
    for (entries) |e| {
        const start = unpackCodepoint(e);
        const size = unpackSize(e);
        const end: u21 = @intCast(start + size - 1);
        for ([_]u21{
            if (start > 0) start - 1 else start,
            start,
            end,
            if (end < 0x10FFFF) end + 1 else end,
        }) |cp| {
            try testing.expectEqual(linearLookup(&entries, cp), lookup(cp));
        }
    }
}

test "lookup(exhaustive): agrees with linear scan over the same table" {
    // About 23 s in Debug; run with -Dslow.
    if (!@import("test_options").slow) return error.SkipZigTest;
    const entries = &tables.entries;
    var cp: u32 = 0;
    while (cp <= 0x10FFFF) : (cp += 1) {
        try testing.expectEqual(linearLookup(entries, @intCast(cp)), lookup(@intCast(cp)));
    }
}

test "wcwidth: NUL is zero-width, not control" {
    try testing.expectEqual(wcwidth(0x0000, .narrow), .zero);
    try testing.expectEqual(wcwidth(0x0000, .wide), .zero);
}

test "wcwidth: other C0 controls remain .control" {
    try testing.expectEqual(wcwidth(0x0001, .narrow), .control);
    try testing.expectEqual(wcwidth(0x001f, .narrow), .control);
    try testing.expectEqual(wcwidth(0x007f, .narrow), .control); // DEL
}

// test "wcwidth: debug 0x13869" {
//     try testing.expectEqual(.control, wcwidth(0x13869, .wide));
// }

test "wcwidth: agrees with libc for selected scalar values" {
    try useUtf8Locale();

    const inputs = [_]u21{
        0x0000, // NUL
        0x0001, // C0 control
        0x0020, // space
        0x0041, // ASCII
        0x007f, // DEL
        0x00a0, // no-break space
        0x0301, // combining acute accent
        0x200d, // zero-width joiner
        0x3000, // ideographic space
        0x4e00, // CJK
        0x1f600, // GRINNING FACE
        0xe007f, // tag character
    };

    for (inputs) |codepoint| {
        try checkAgainstLibc(codepoint);
    }
}

test "wcwidth: fuzzes against libc" {
    try useUtf8Locale();

    const T = struct {
        fn fuzz(_: void, smith: *testing.Smith) !void {
            const codepoint = smith.value(u21);
            try checkAgainstLibc(codepoint);
        }
    };

    // const testdata_dir = try std.Io.Dir.openDir(.cwd(), io, "testdata/fuzz/wcwidth", .{ .iterate = true });
    // defer testdata_dir.close(io);
    // var it = testdata_dir.iterate();
    //
    // while (try it.next(io)) |entry| {
    //     std.debug.print("entry: {any}\n", .{entry});
    // }

    const context: void = {};
    try testing.fuzz(context, T.fuzz, .{
        .corpus = &corpus,
    });
}