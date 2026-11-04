const std = @import("std");
const testing = std.testing;

const Breaker = @import("grapheme.zig").Breaker;

test "GB11: ZWJ emoji sequence stays joined" {
    var gb = Breaker.init(0x1F469); // WOMAN
    try testing.expect(!gb.isBreak(0x200D)); // ZWJ: no break
    try testing.expect(!gb.isBreak(0x1F4BB)); // COMPUTER: no break
}

test "GB12/13: regional indicator flag pairs" {
    var gb = Breaker.init(0x1F1FA); // RI: U
    try testing.expect(!gb.isBreak(0x1F1F8)); // RI: S | no break (US pair)
    try testing.expect(gb.isBreak(0x1F1EC)); // RI: G | break (new pair starts)
    try testing.expect(!gb.isBreak(0x1F1E7)); // RI: B | no break (GB pair)
}

test "GB12/13: longer run of regional indicators stays paired correctly" {
    var gb = Breaker.init(0x1F1FA);
    try testing.expect(!gb.isBreak(0x1F1F8)); // pair 1 closes
    try testing.expect(gb.isBreak(0x1F1EC)); // pair 2 opens
    try testing.expect(!gb.isBreak(0x1F1E7)); // pair 2 closes
    try testing.expect(gb.isBreak(0x1F1EB)); // pair 3 opens (F)
    try testing.expect(!gb.isBreak(0x1F1F7)); // pair 3 closes (R)
}

test "GB9: base + combining mark stays joined" {
    var gb = Breaker.init('e');
    try testing.expect(!gb.isBreak(0x0301)); // combining acute accent
}

test "GB9b then GB11: prepend before a ZWJ emoji sequence keeps it joined" {
    // Found by the grapheme fuzz target: GB9b returned before the
    // emoji state was entered, so the ZWJ sequence broke.
    var gb = Breaker.init(0x0600); // ARABIC NUMBER SIGN (Prepend)
    try testing.expect(!gb.isBreak(0x1F469)); // WOMAN
    try testing.expect(!gb.isBreak(0x200D)); // ZWJ
    try testing.expect(!gb.isBreak(0x1F4BB)); // COMPUTER: GB11
}

test "GB4 then GB11: a ZWJ emoji sequence after CR stays joined" {
    var gb = Breaker.init('\r');
    try testing.expect(gb.isBreak(0x1F469)); // WOMAN: GB4
    try testing.expect(!gb.isBreak(0x200D)); // ZWJ
    try testing.expect(!gb.isBreak(0x1F4BB)); // COMPUTER: GB11
}

test "GB9b then GB12: prepend before a flag keeps the pair joined" {
    var gb = Breaker.init(0x0600); // Prepend
    try testing.expect(!gb.isBreak(0x1F1FA)); // RI: U
    try testing.expect(!gb.isBreak(0x1F1F8)); // RI: S, pairs with U
    try testing.expect(gb.isBreak(0x1F1EC)); // RI: G starts a new pair
}

test "no rule: independent ASCII letters always break" {
    var gb = Breaker.init('a');
    try testing.expect(gb.isBreak('b'));
}

test "UAX #29: GraphemeBreakTest.txt conformance" {
    const data = @import("ucd_test_data").grapheme_break_test;

    var pass: usize = 0;
    var fail: usize = 0;
    var gb9c: usize = 0;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw| {
        const hash = std.mem.indexOfScalar(u8, raw, '#') orelse raw.len;
        const line = std.mem.trim(u8, raw[0..hash], " \t\r");
        if (line.len == 0) continue;
        // Breaker omits GB9c (Indic conjuncts); the comment names the
        // rule that decided each boundary, and [9.3] is GB9c.
        if (std.mem.indexOf(u8, raw[hash..], "[9.3]") != null) {
            gb9c += 1;
            continue;
        }

        // Alternating marks and code points: "÷ 0020 × 0308 ÷".
        var cps: [32]u21 = undefined;
        var breaks: [32]bool = undefined; // breaks[i]: break before cps[i]
        var n: usize = 0;
        var mark: bool = true;
        var tokens = std.mem.tokenizeAny(u8, line, " \t");
        while (tokens.next()) |tok| {
            if (std.mem.eql(u8, tok, "\u{F7}")) {
                mark = true;
            } else if (std.mem.eql(u8, tok, "\u{D7}")) {
                mark = false;
            } else {
                cps[n] = try std.fmt.parseInt(u21, tok, 16);
                breaks[n] = mark;
                n += 1;
            }
        }

        var gb = Breaker.init(cps[0]);
        const ok = for (1..n) |i| {
            if (gb.isBreak(cps[i]) != breaks[i]) break false;
        } else true;
        if (ok) {
            pass += 1;
        } else {
            fail += 1;
            if (fail <= 20) std.debug.print("UAX #29 mismatch: {s}\n", .{line});
        }
    }
    if (fail != 0) std.debug.print("UAX #29: {d} pass, {d} fail, {d} GB9c skipped\n", .{ pass, fail, gb9c });
    try testing.expectEqual(0, fail);
    try testing.expect(pass > 700); // the file was found and parsed
}
