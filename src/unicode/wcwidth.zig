//! Terminal cell width of a code point, from the generated
//! wcwidth_table.zig.

const std = @import("std");
const tables = @import("wcwidth_table.zig");

/// Final width classification of a code point, in terminal columns.
pub const Width = enum {
    /// Not printable or not representable as a column-occupying glyph
    /// (musl's -1). Caller must decide: substitute, strip, or error.
    control,
    /// Occupies zero columns but is composable (combining marks, ZWJ,
    /// variation selectors, tag characters), musl's 0.
    zero,
    /// Occupies exactly one column.
    narrow,
    /// Occupies exactly two columns.
    wide,
};

/// Policy for East_Asian_Width="A" (Ambiguous) code points, which POSIX
/// does not mandate a fixed treatment for. musl/glibc default to .narrow;
/// CJK-locale users conventionally want .wide.
pub const AmbiguousWidth = enum { narrow, wide };

/// Looks up the encoded Unicode property for codepoint using a binary search
/// over the generated range table.
///
/// This is the raw table lookup. It does not apply the ASCII fast path,
/// ambiguous-width policy, or other higher-level `wcwidth()` behavior. Use
/// `wcwidth()` as the public entry point.
///
/// Each table entry stores the range start in its upper bits and packs the
/// property and range-length field into its lower 11 bits. The search uses a
/// packed upper-bound key to find the last range whose start is less than or
/// equal to codepoint.
///
/// Returns .narrow when codepoint is not covered by an encoded range.
pub inline fn lookup(codepoint: u21) tables.Property {
    const entries = &tables.entries;
    const needle: u32 = (@as(u32, codepoint) << 11) | 0x7ff;

    var lo: usize = 0;
    var hi: usize = entries.len;

    while (lo < hi) {
        const mid = lo + ((hi - lo) >> 1);

        if (entries[mid] <= needle) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }

    if (lo == 0) {
        return .narrow;
    }

    const entry: u32 = entries[lo - 1];
    const start: u32 = entry >> 11;
    const offset: u32 = @as(u32, codepoint) - start;
    const encoded_size: u32 = (entry >> 3) & 0xff;

    if (offset <= encoded_size) {
        return @enumFromInt(@as(u3, @intCast(entry & 0x7)));
    }

    return .narrow;
}

/// Returns the wcwidth-style terminal classification for a Unicode code point.
///
/// O(1) for ASCII and O(log n) otherwise. Printable ASCII is .narrow;
/// C0 controls, DEL, and invalid u21 values are .control. Ambiguous-width
/// characters follow ambiguous policy. Unlike POSIX/musl, this returns `Width`,
/// exposes ambiguous-width policy, and derives zero-width properties from
/// Unicode data, including U+E007F.
///
/// Reference: musl `wcwidth()` / Markus Kuhn's width algorithm.
/// https://github.com/ziglang/zig/blob/738d2be9d6b6ef3ff3559130c05159ef53336224/lib/libc/musl/src/ctype/wcwidth.c
pub fn wcwidth(codepoint: u21, ambiguous: AmbiguousWidth) Width {
    // Fast path, ASCII, mirroring musl's inline codepoint < 0xff branch.
    // Source: https://github.com/ziglang/zig/blob/738d2be9d6b6ef3ff3559130c05159ef53336224/lib/libc/musl/src/ctype/wcwidth.c#L1-L29

    // A u21 can contain values that are not valid Unicode scalar values.
    // Reject code points above U+10FFFF and UTF-16 surrogate code points.
    if (codepoint > 0x10ffff or (codepoint >= 0xd800 and codepoint <= 0xdfff)) {
        // .control represents a non-printing or invalid code point here.
        return .control;
    }

    // NUL: POSIX wcwidth(3) explicitly special-cases L'\0' to width 0,
    // distinct from the other C0 controls which are non-printable (-1
    // in musl's model, .control here). Must be checked before the
    // general C0-control branch below.
    if (codepoint == 0) return .zero;

    // C0 controls: U+0000..U+001F.
    if (codepoint < 0x20) return .control;
    // Printable ASCII: U+0020..U+007E.
    if (codepoint < 0x7f) return .narrow;
    // DEL: U+007F.
    if (codepoint == 0x7f) return .control;

    return switch (lookup(codepoint)) {
        .control => .control,
        .zero => .zero,
        .narrow => .narrow,
        .wide => .wide,
        .ambiguous => switch (ambiguous) {
            .narrow => .narrow,
            .wide => .wide,
        },
    };
}

/// A convenience total column width of a sequence of code points, treating .control as width 0
/// (caller is expected to have already substituted or stripped control code points upstream; see
/// module-level docs and plan §4 for why .control and .zero are kept distinct at the classification
/// layer but may collapse here).
pub fn stringWidth(cps: []const u21, ambiguous: AmbiguousWidth) usize {
    var total: usize = 0;
    for (cps) |cp| {
        total += switch (wcwidth(cp, ambiguous)) {
            .control, .zero => 0,
            .narrow => 1,
            .wide => 2,
        };
    }
    return total;
}

/// Returns the terminal cell column width (0, 1, or 2) of a single grapheme cluster.
/// Correctly promotes:
///   - Flag pairs (2 Regional Indicators) -> 2 columns
///   - VS16 (U+FE0F) emoji presentation selector -> 2 columns
///   - Enclosing keycaps (U+20E3) -> 2 columns
/// And demotes:
///   - VS15 (U+FE0E) text presentation selector -> 1 column
pub fn clusterWidth(slice: []const u21, ambiguous: AmbiguousWidth) u16 {
    if (slice.len == 0) return 0;
    if (slice.len == 1) {
        return switch (wcwidth(slice[0], ambiguous)) {
            .wide => 2,
            .narrow => 1,
            .zero, .control => 0,
        };
    }

    // Regional Indicator flag pairs (e.g. 🇦🇺 U+1F1E6 U+1F1FA)
    if (slice.len == 2 and
        slice[0] >= 0x1F1E6 and slice[0] <= 0x1F1FF and
        slice[1] >= 0x1F1E6 and slice[1] <= 0x1F1FF)
    {
        return 2;
    }

    // VS15 (Text Presentation Selector U+FE0E) demotion
    for (slice[1..]) |cp| {
        if (cp == 0xFE0E) return 1;
    }

    // VS16 (Emoji Presentation Selector U+FE0F) promotion
    for (slice[1..]) |cp| {
        if (cp == 0xFE0F) return 2;
    }

    // Enclosing Keycap (U+20E3)
    for (slice[1..]) |cp| {
        if (cp == 0x20E3) return 2;
    }

    return switch (wcwidth(slice[0], ambiguous)) {
        .wide => 2,
        .narrow => 1,
        .zero, .control => 0,
    };
}
