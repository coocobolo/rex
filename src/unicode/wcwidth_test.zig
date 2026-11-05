//! Checks wcwidth_table.zig against the generated UCD oracle
//! (wcwidth_expected.zig) through wcwidth_oracle.zig, which lists the
//! known deviations.

const std = @import("std");
const testing = std.testing;
const tables = @import("wcwidth_table.zig");
const expected = @import("wcwidth_expected.zig");
const oracle = @import("wcwidth_oracle.zig");

const wc = @import("wcwidth.zig");

const wcwidth = wc.wcwidth;
const lookup = wc.lookup;
const Width = wc.Width;
const AmbiguousWidth = wc.AmbiguousWidth;

const Property = tables.Property;

fn unpackCodepoint(v: u32) u21 {
    return @intCast(v >> 11);
}

fn unpackSize(v: u32) u32 {
    return ((v >> 3) & 0xff) + 1;
}

fn unpackProperty(v: u32) Property {
    return @enumFromInt(@as(u3, @intCast(v & 0x7)));
}

fn linearLookup(entries: []const u32, cp: u21) Property {
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

test "lookup: private-use code points are ambiguous, not narrow" {
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

test "wcwidth: ascii and C1 controls" {
    try testing.expectEqual(.narrow, wcwidth(' ', .narrow));
    try testing.expectEqual(.narrow, wcwidth('A', .narrow));
    try testing.expectEqual(.narrow, wcwidth('~', .narrow));
    try testing.expectEqual(.control, wcwidth(0x80, .narrow));
    try testing.expectEqual(.control, wcwidth(0x9B, .narrow)); // CSI
    try testing.expectEqual(.control, wcwidth(0x9F, .narrow));
    try testing.expectEqual(.narrow, wcwidth(0xA0, .narrow)); // NBSP
}

test "wcwidth: soft hyphen is one column" {
    try testing.expectEqual(.narrow, wcwidth(0x00AD, .narrow));
    try testing.expectEqual(.narrow, wcwidth(0x00AD, .wide));
    // Its Cf neighbours in other blocks stay zero-width.
    try testing.expectEqual(.zero, wcwidth(0x200B, .narrow)); // ZWSP
    try testing.expectEqual(.zero, wcwidth(0x2060, .narrow)); // word joiner
}

test "wcwidth: combining marks, ZWJ and VS16 are zero" {
    try testing.expectEqual(.zero, wcwidth(0x0301, .narrow)); // combining acute
    try testing.expectEqual(.zero, wcwidth(0x20DD, .narrow)); // enclosing circle (Me)
    try testing.expectEqual(.zero, wcwidth(0x200D, .narrow)); // ZWJ
    try testing.expectEqual(.zero, wcwidth(0xFE0F, .narrow)); // VS16
    try testing.expectEqual(.zero, wcwidth(0x1160, .narrow)); // Hangul jungseong filler
    try testing.expectEqual(.zero, wcwidth(0xE007F, .narrow)); // cancel tag
}

test "wcwidth: CJK and emoji are wide" {
    try testing.expectEqual(.wide, wcwidth(0x3000, .narrow)); // ideographic space
    try testing.expectEqual(.wide, wcwidth(0x4E00, .narrow));
    try testing.expectEqual(.wide, wcwidth(0xAC00, .narrow)); // Hangul syllable
    try testing.expectEqual(.wide, wcwidth(0xFF21, .narrow)); // fullwidth A
    try testing.expectEqual(.wide, wcwidth(0x20000, .narrow)); // plane 2
    try testing.expectEqual(.wide, wcwidth(0x1F600, .narrow)); // grinning face
    try testing.expectEqual(.wide, wcwidth(0x231A, .narrow)); // watch (Emoji_Presentation)
}

test "wcwidth: ambiguous follows the policy" {
    for ([_]u21{ 0x00A1, 0x00B1, 0x2460, 0x03B1 }) |cp| {
        try testing.expectEqual(.narrow, wcwidth(cp, .narrow));
        try testing.expectEqual(.wide, wcwidth(cp, .wide));
    }
    // Non-ambiguous classes ignore the policy.
    try testing.expectEqual(.zero, wcwidth(0x0301, .wide));
    try testing.expectEqual(.narrow, wcwidth('A', .wide));
}

test "wcwidth: surrogates and out-of-range are control" {
    try testing.expectEqual(.control, wcwidth(0xD800, .narrow));
    try testing.expectEqual(.control, wcwidth(0xDFFF, .narrow));
    try testing.expectEqual(.control, wcwidth(0x110000, .narrow));
}

test "lookup: oracle ranges match at every boundary" {
    for (expected.ranges) |r| {
        try oracle.check(r.first);
        try oracle.check(r.last);
    }
}

test "lookup(exhaustive): every code point matches the UCD oracle" {
    // About 1 s in Debug; run with -Dslow.
    if (!@import("test_options").slow) return error.SkipZigTest;
    // Report every disagreeing range, not just the first code point.
    var failed = false;
    var run_start: ?u21 = null;
    var cp: u32 = 0;
    while (cp <= 0x110000) : (cp += 1) {
        const bad = cp <= 0x10FFFF and !oracle.isException(@intCast(cp)) and
            oracle.propertyOf(expected.classOf(@intCast(cp))) != lookup(@intCast(cp));
        if (bad and run_start == null) run_start = @intCast(cp);
        if (!bad) if (run_start) |first| {
            const last: u21 = @intCast(cp - 1);
            std.debug.print("U+{X:0>4}..U+{X:0>4}: oracle {t}, table {t}\n", .{
                first, last, oracle.propertyOf(expected.classOf(first)), lookup(first),
            });
            failed = true;
            run_start = null;
        };
    }
    if (failed) return error.TestExpectedEqual;
}

test "clusterWidth: flags, variation selectors, keycaps, and combiners" {
    // Lone Regional Indicator vs Flag Pair
    try testing.expectEqual(@as(u16, 1), wc.clusterWidth(&.{0x1F1E6}, .narrow));
    try testing.expectEqual(@as(u16, 2), wc.clusterWidth(&.{ 0x1F1E6, 0x1F1FA }, .narrow)); // 🇦🇺

    // VS16 emoji promotion
    try testing.expectEqual(@as(u16, 1), wc.clusterWidth(&.{0x26A0}, .narrow)); // ⚠️ base without VS16
    try testing.expectEqual(@as(u16, 2), wc.clusterWidth(&.{ 0x26A0, 0xFE0F }, .narrow)); // ⚠️ with VS16
    try testing.expectEqual(@as(u16, 2), wc.clusterWidth(&.{ 0x2139, 0xFE0F }, .narrow)); // ℹ️ with VS16

    // VS15 text demotion
    try testing.expectEqual(@as(u16, 2), wc.clusterWidth(&.{0x2615}, .narrow)); // ☕ base is wide
    try testing.expectEqual(@as(u16, 1), wc.clusterWidth(&.{ 0x2615, 0xFE0E }, .narrow)); // ☕︎ with VS15 demoted to text

    // Keycaps
    try testing.expectEqual(@as(u16, 2), wc.clusterWidth(&.{ '1', 0xFE0F, 0x20E3 }, .narrow)); // 1️⃣
    try testing.expectEqual(@as(u16, 2), wc.clusterWidth(&.{ '#', 0x20E3 }, .narrow)); // #️⃣

    // Standard combining mark on narrow character
    try testing.expectEqual(@as(u16, 1), wc.clusterWidth(&.{ 'e', 0x0301 }, .narrow)); // é

    // Combining mark on wide character
    try testing.expectEqual(@as(u16, 2), wc.clusterWidth(&.{ 0x4E00, 0x0301 }, .narrow)); // 中 + mark

    // Empty cluster
    try testing.expectEqual(@as(u16, 0), wc.clusterWidth(&.{}, .narrow));
}
