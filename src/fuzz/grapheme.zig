//! Grapheme fuzz target: code point sequences drawn mostly from the
//! code points each Grapheme_Cluster_Break rule turns on, through the
//! streaming `Breaker`.
//!
//! Invariant: every boundary matches `refIsBreak`, a slow segmenter
//! written straight from the UAX #29 rules (GB3 to GB999, without GB9c
//! as `Breaker` documents) that looks back over the whole sequence
//! instead of keeping state.

const std = @import("std");
const testing = std.testing;

const harness = @import("harness.zig");
const Source = harness.Source;
const Breaker = @import("../term/grapheme.zig").Breaker;
const table = @import("../term/grapheme_table.zig");
const Property = table.Property;

/// A few code points of each property, and a few with none.
const samples = [_]u21{
    '\r', '\n', 0x01, 0x7F, 0x200B, // CR, LF, Control
    0x0301, 0x0308, 0xFE0F, 0x1F3FB, // Extend (incl. VS16, skin tone)
    0x200D, // ZWJ
    0x1F1E6, 0x1F1FA, 0x1F1F8, // Regional_Indicator
    0x0600, 0x0605, 0x110BD, // Prepend
    0x0903, 0x093E, // SpacingMark
    0x1100, 0x115F, // L
    0x1160, 0x11A2, // V
    0x11A8, 0x11FF, // T
    0xAC00, // LV
    0xAC01, // LVT
    0x2764, 0x1F469, 0x1F4BB, 0x1F600, 0x00A9, // Extended_Pictographic
    'a', ' ', 0x4E00, 0xFFFD, 0x0915, // none
};

fn property(cp: u21) Property {
    return table.getProperty(cp) orelse .none;
}

/// Whether UAX #29 puts a boundary before `cps[i]` (i > 0).
fn refIsBreak(cps: []const u21, i: usize) bool {
    const prev = property(cps[i - 1]);
    const next = property(cps[i]);
    if (prev == .cr and next == .lf) return false; // GB3
    if (prev == .control or prev == .cr or prev == .lf) return true; // GB4
    if (next == .control or next == .cr or next == .lf) return true; // GB5
    if (prev == .l and (next == .l or next == .v or next == .lv or next == .lvt)) return false; // GB6
    if ((prev == .lv or prev == .v) and (next == .v or next == .t)) return false; // GB7
    if ((prev == .lvt or prev == .t) and next == .t) return false; // GB8
    if (next == .extend or next == .zwj) return false; // GB9
    if (next == .spacing_mark) return false; // GB9a
    if (prev == .prepend) return false; // GB9b
    // GB11: ExtPict Extend* ZWJ x ExtPict
    if (prev == .zwj and next == .extended_pictographic) {
        var j = i - 1;
        while (j > 0) {
            j -= 1;
            switch (property(cps[j])) {
                .extend => continue,
                .extended_pictographic => return false,
                else => break,
            }
        }
    }
    // GB12, GB13: break between RIs only after an even run of them.
    if (prev == .regional_indicator and next == .regional_indicator) {
        var count: usize = 0;
        var j = i;
        while (j > 0 and property(cps[j - 1]) == .regional_indicator) : (j -= 1) count += 1;
        return count % 2 == 0;
    }
    return true; // GB999
}

fn run(src: *Source) !void {
    // One input byte per code point: most pick a sample, the top
    // sixteen values any code point at all.
    var bytes_buf: [64]u8 = undefined;
    const bytes = src.chunk("code points", &bytes_buf);
    if (bytes.len == 0) return;
    var cps: [64]u21 = undefined;
    const len = bytes.len;
    for (bytes, cps[0..len]) |b, *cp| {
        cp.* = if (b >= 0xF0)
            src.range("any", u21, 0, 0x10FFFF)
        else
            samples[b % samples.len];
    }

    var breaker: Breaker = .init(cps[0]);
    for (1..len) |i| {
        const want = refIsBreak(cps[0..len], i);
        const got = breaker.isBreak(cps[i]);
        if (want != got) {
            std.debug.print("boundary before index {d}: want {}, got {}\n", .{ i, want, got });
            for (cps[0..len], 0..) |cp, j| std.debug.print("  [{d}] U+{X:0>4} {t}\n", .{ j, cp, property(cp) });
            return error.TestUnexpectedResult;
        }
    }
}

/// Byte b picks `samples[b % samples.len]` (b < 0xF0), so each seed
/// spells out one rule's case by sample index.
const seeds = [_][]const u8{
    "\x00\x01\x01\x00\x02", // CR LF LF CR Control
    "\x1f\x05\x06\x07\x08\x09", // a + marks + ZWJ
    "\x1b\x09\x1c\x09\x1d", // ExtPict ZWJ ExtPict ZWJ ExtPict
    "\x1a\x05\x07\x09\x1b", // ExtPict Extend Extend ZWJ ExtPict
    "\x0a\x0b\x0c\x0a\x0b", // RI RI RI RI RI
    "\x0d\x1b\x09\x1c", // Prepend ExtPict ZWJ ExtPict
    "\x0d\x0a\x0b", // Prepend RI RI
    "\x12\x13\x14\x16\x18\x19\x16", // L L V T LV LVT T
    "\x1f\x10\x11\x1f\x07", // a SpacingMark SpacingMark a VS16
    "\xf0\xf1\xf2\xf3\xf4\xf5", // any code points
};

const regressions = [_][]const u8{};

test "fuzz grapheme" {
    try harness.fuzz(run, &seeds, &regressions);
}

test "fuzz grapheme: seeded mutations" {
    try harness.seeded(run, &seeds, 0x6B29_0029);
}
