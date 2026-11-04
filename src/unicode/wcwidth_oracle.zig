//! The UCD oracle for wcwidth: what wcwidth_expected.zig says each code
//! point's width is, less the deliberate `exceptions`. Shared by
//! wcwidth_test.zig and the wcwidth fuzz target; test-only.

const std = @import("std");

const expected = @import("wcwidth_expected.zig");
const Property = @import("wcwidth_table.zig").Property;
const lookup = @import("wcwidth.zig").lookup;

/// Code points where wcwidth_table.zig deliberately differs from the
/// UCD oracle in wcwidth_expected.zig. Each entry says why.
const Exception = struct { first: u21, last: u21, why: []const u8 };
pub const exceptions = [_]Exception{
    .{
        .first = 0x00AD,
        .last = 0x00AD,
        .why = "SOFT HYPHEN is General_Category Cf but prints as a visible " ++
            "hyphen; xterm, glibc and musl give it one column.",
    },
    .{
        .first = 0x1F1E6,
        .last = 0x1F1FF,
        .why = "Regional indicators are Emoji_Presentation but East_Asian_Width " ++
            "N. A lone indicator is one column (UAX #11, xterm, glibc); a " ++
            "flag pair is sized as a grapheme cluster, not per code point.",
    },
};

pub fn isException(cp: u21) bool {
    for (exceptions) |e| if (cp >= e.first and cp <= e.last) return true;
    return false;
}

pub fn propertyOf(class: expected.Class) Property {
    return switch (class) {
        .control => .control,
        .zero => .zero,
        .narrow => .narrow,
        .wide => .wide,
        .ambiguous => .ambiguous,
    };
}

/// Checks the table lookup for `cp` against the UCD oracle.
pub fn check(cp: u21) !void {
    if (cp > 0x10FFFF or isException(cp)) return;
    const want = propertyOf(expected.classOf(cp));
    const got = lookup(cp);
    if (want != got) {
        std.debug.print("U+{X:0>4}: oracle {t}, table {t}\n", .{ cp, want, got });
        return error.TestExpectedEqual;
    }
}
