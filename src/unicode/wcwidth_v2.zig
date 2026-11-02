const std = @import("std");
const tables = @import("wcwidth_table.zig");

test {
    _ = @import("wcwidth_v2_test.zig");
}

/// Final width classification returned as column column-occupying glyph width.
pub const Width = enum {
    /// Not printable or not representable as a column-occupying glyph
    /// (musl's -1). Caller must decide: substitute, strip, or error.
    control,
    /// Occupies zero column bubt is composable (combining marks, ZWJ,
    /// variation selectors, tag characters), musl's 0.
    zero,
    /// Occupies exactly one column.
    narrow,
    /// Occupies exactly two column.
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

    // std.debug.print("lookup cp=0x{x} fallback to .narrow\n", .{codepoint});
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