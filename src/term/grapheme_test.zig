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

test "no rule: independent ASCII letters always break" {
    var gb = Breaker.init('a');
    try testing.expect(gb.isBreak('b'));
}
