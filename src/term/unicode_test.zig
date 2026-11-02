const std = @import("std");

const testing = std.testing;

const Utf8Dfa = @import("unicode.zig").Utf8Dfa;
const wcwidth = @import("unicode.zig").wcwidth;

test "Hoehrmann DFA matches std.unicode.utf8View" {
    const input = "hello 世界 😀 café";

    // collect std.unicode decoded codepoints
    var std_result: [256]u32 = undefined;
    var std_len: usize = 0;

    var view = try std.unicode.Utf8View.init(input);
    var iter = view.iterator();

    while (iter.nextCodepoint()) |cp| {
        std_result[std_len] = cp;
        std_len += 1;
    }

    // collect DFA decoded codepoints
    var dfa: Utf8Dfa = .empty;

    var dfa_result: [256]u32 = undefined;
    var dfa_len: usize = 0;

    for (input) |byte| {
        if (dfa.feed(byte)) |cp| {
            dfa_result[dfa_len] = cp;
            dfa_len += 1;
        }

        if (dfa.state == Utf8Dfa.reject) {
            return error.InvalidUtf8;
        }
    }

    // compare lengths
    try testing.expectEqual(std_len, dfa_len);

    // compare every codepoint
    for (dfa_result[0..dfa_len], std_result[0..std_len]) |a, b| {
        try testing.expectEqual(a, b);
    }
}

test "Hoehrmann DFA rejects invalid utf8" {
    // invalid continuation byte sequence
    const input = [_]u8{
        0xE2,
        0x28,
        0xA1,
    };

    var dfa: Utf8Dfa = .empty;

    var rejected = false;

    for (input) |byte| {
        _ = dfa.feed(byte);

        if (dfa.state == Utf8Dfa.reject) {
            rejected = true;
            break;
        }
    }

    try testing.expect(rejected);
}

test "Hoehrmann DFA fuzz compare std.unicode" {
    var prng = std.Random.DefaultPrng.init(0xdeadbeef);
    const random = prng.random();

    var buf: [4096]u8 = undefined;

    for (0..10_000) |_| {
        random.bytes(&buf);

        const std_valid = std.unicode.utf8ValidateSlice(&buf);

        var dfa: Utf8Dfa = .empty;
        var dfa_valid = true;

        for (buf) |byte| {
            _ = dfa.feed(byte);
            if (dfa.state == Utf8Dfa.reject) {
                dfa_valid = false;
                break;
            }
        }

        // unfinished sequence is invalid
        if (dfa.state != 0)
            dfa_valid = false;

        try testing.expectEqual(std_valid, dfa_valid);
    }
}

test "wcwidth: ASCII printable chars return 1" {
    try testing.expectEqual(@as(u2, 1), wcwidth(' ')); // 0x20
    try testing.expectEqual(@as(u2, 1), wcwidth('A')); // 0x41
    try testing.expectEqual(@as(u2, 1), wcwidth('z')); // 0x7A
    try testing.expectEqual(@as(u2, 1), wcwidth('~')); // 0x7E
}

test "wcwidth: DEL (0x7F) returns 1 via else branch" {
    // 0x7F is NOT < 0x7F so value should be 1
    try testing.expectEqual(@as(u2, 1), wcwidth(0x7F));
}

test "wcwidth: control characters return 1 via fast path" {
    // The function does not handle width-0 control chars; they pass through as 1.
    try testing.expectEqual(@as(u2, 1), wcwidth(0x00));
    try testing.expectEqual(@as(u2, 1), wcwidth(0x1B)); // ESC
    try testing.expectEqual(@as(u2, 1), wcwidth(0x1F));
}

test "wcwidth: Latin extended returns 1" {
    try testing.expectEqual(@as(u2, 1), wcwidth('é')); // U+00E9
    try testing.expectEqual(@as(u2, 1), wcwidth('ñ')); // U+00F1
    try testing.expectEqual(@as(u2, 1), wcwidth('ü')); // U+00FC
}

test "wcwidth: arrows and misc symbols return 1" {
    try testing.expectEqual(@as(u2, 1), wcwidth('→')); // U+2192 < 0x2E80
    try testing.expectEqual(@as(u2, 1), wcwidth('★')); // U+2605 < 0x2E80
    try testing.expectEqual(@as(u2, 1), wcwidth('©')); // U+00A9
}

test "wcwidth: 0x1100..0x115F (Hangul Jamo)" {
    try testing.expectEqual(@as(u2, 1), wcwidth(0x10FF)); // one below
    try testing.expectEqual(@as(u2, 2), wcwidth(0x1100)); // start
    try testing.expectEqual(@as(u2, 2), wcwidth(0x1130)); // mid
    try testing.expectEqual(@as(u2, 2), wcwidth(0x115F)); // end
    try testing.expectEqual(@as(u2, 1), wcwidth(0x1160)); // one above
}

test "wcwidth: 0x2E80..0x303E (CJK Radicals)" {
    try testing.expectEqual(@as(u2, 1), wcwidth(0x2E7F)); // one below
    try testing.expectEqual(@as(u2, 2), wcwidth(0x2E80)); // start
    try testing.expectEqual(@as(u2, 2), wcwidth(0x303E)); // end
    try testing.expectEqual(@as(u2, 1), wcwidth(0x303F)); // one above
}

test "wcwidth: 0x3041..0x33FF (Hiragana, Katakana, CJK compat)" {
    try testing.expectEqual(@as(u2, 1), wcwidth(0x3040)); // one below (0x303F and 0x3040 are the gap)
    try testing.expectEqual(@as(u2, 2), wcwidth(0x3041)); // start
    try testing.expectEqual(@as(u2, 2), wcwidth(0x3042)); // 'あ'
    try testing.expectEqual(@as(u2, 2), wcwidth(0x33FF)); // end
    // 0x3400 is the START of the next wide range — do NOT test it as narrow here.
}

test "wcwidth: 0x3400..0x4DBF (CJK Extension A)" {
    // 0x33FF is the END of the previous wide range — no gap before 0x3400.
    try testing.expectEqual(@as(u2, 2), wcwidth(0x3400)); // start
    try testing.expectEqual(@as(u2, 2), wcwidth(0x4DBF)); // end
    try testing.expectEqual(@as(u2, 1), wcwidth(0x4DC0)); // one above (actual gap)
}

test "wcwidth: 0x4E00..0x9FFF (CJK Unified Ideographs)" {
    // 0x4DBF is the END of the previous wide range — no gap before 0x4E00.
    // But there IS a gap: 0x4DC0..0x4DFF is narrow.
    try testing.expectEqual(@as(u2, 1), wcwidth(0x4DC0)); // narrow gap before this range
    try testing.expectEqual(@as(u2, 2), wcwidth(0x4E00)); // start
    try testing.expectEqual(@as(u2, 2), wcwidth(0x4E2D)); // '中'
    try testing.expectEqual(@as(u2, 2), wcwidth(0x9FFF)); // end
    // 0xA000 is the START of the next wide range — do NOT test it as narrow here.
}

test "wcwidth: 0xA000..0xA4CF (Yi syllables)" {
    // 0x9FFF is the END of the previous wide range — no gap before 0xA000.
    try testing.expectEqual(@as(u2, 2), wcwidth(0xA000)); // start
    try testing.expectEqual(@as(u2, 2), wcwidth(0xA4CF)); // end
    try testing.expectEqual(@as(u2, 1), wcwidth(0xA4D0)); // one above (actual gap)
}

test "wcwidth: 0xFF01..0xFF60 (Fullwidth Latin)" {
    try testing.expectEqual(@as(u2, 1), wcwidth(0xFF00)); // one below
    try testing.expectEqual(@as(u2, 2), wcwidth(0xFF01)); // start '！'
    try testing.expectEqual(@as(u2, 2), wcwidth(0xFF21)); // 'Ａ' fullwidth A
    try testing.expectEqual(@as(u2, 2), wcwidth(0xFF60)); // end
    try testing.expectEqual(@as(u2, 1), wcwidth(0xFF61)); // one above
}

test "wcwidth: 0xFFE0..0xFFE6 (Fullwidth signs)" {
    try testing.expectEqual(@as(u2, 1), wcwidth(0xFFDF)); // one below
    try testing.expectEqual(@as(u2, 2), wcwidth(0xFFE0)); // start '￠'
    try testing.expectEqual(@as(u2, 2), wcwidth(0xFFE6)); // end '￦'
    try testing.expectEqual(@as(u2, 1), wcwidth(0xFFE7)); // one above
}

test "wcwidth: 0x1F004 (Mahjong tile) is wide" {
    try testing.expectEqual(@as(u2, 1), wcwidth(0x1F003)); // one below
    try testing.expectEqual(@as(u2, 2), wcwidth(0x1F004)); // '🀄'
    try testing.expectEqual(@as(u2, 1), wcwidth(0x1F005)); // one above
}

test "wcwidth: 0x1F0CF (Joker card) is wide" {
    try testing.expectEqual(@as(u2, 1), wcwidth(0x1F0CE)); // one below
    try testing.expectEqual(@as(u2, 2), wcwidth(0x1F0CF)); // '🃏'
    try testing.expectEqual(@as(u2, 1), wcwidth(0x1F0D0)); // one above
}

test "wcwidth: 0x1F200..0x1F2FF (Enclosed CJK)" {
    try testing.expectEqual(@as(u2, 1), wcwidth(0x1F1FF)); // one below
    try testing.expectEqual(@as(u2, 2), wcwidth(0x1F201)); // first assigned W in block
    try testing.expectEqual(@as(u2, 2), wcwidth(0x1F251)); // last assigned W in block

}

test "wcwidth: 0x1F300..0x1F64F (Misc symbols, emoticons)" {
    // 0x1F2FF is the END of the previous wide range — no gap before 0x1F300.
    try testing.expectEqual(@as(u2, 2), wcwidth(0x1F300)); // start
    try testing.expectEqual(@as(u2, 2), wcwidth(0x1F384)); // '🎄'
    try testing.expectEqual(@as(u2, 2), wcwidth(0x1F600)); // '😀'
    try testing.expectEqual(@as(u2, 2), wcwidth(0x1F64F)); // end
    try testing.expectEqual(@as(u2, 1), wcwidth(0x1F650)); // one above (gap: 0x1F650..0x1F67F)
}

test "wcwidth: 0x1F680..0x1F6FF (Transport and map)" {
    try testing.expectEqual(@as(u2, 1), wcwidth(0x1F67F)); // one below
    try testing.expectEqual(@as(u2, 2), wcwidth(0x1F680)); // start '🚀'
    try testing.expectEqual(@as(u2, 2), wcwidth(0x1F6FC)); // last assigned W
    try testing.expectEqual(@as(u2, 1), wcwidth(0x1F6FD)); // one above (unassigned/narrow)
}

test "wcwidth: 0x1F900..0x1F9FF (Supplemental symbols)" {
    try testing.expectEqual(@as(u2, 1), wcwidth(0x1F8FF)); // one below (narrow gap)
    try testing.expectEqual(@as(u2, 2), wcwidth(0x1F90C)); // first W in block
    try testing.expectEqual(@as(u2, 2), wcwidth(0x1F9FF)); // end
    // 0x1FA00 is the START of Chess Pieces (also wide), not a valid narrow boundary.
    // Use the gap between Chess Pieces (ends 0x1FA53) and Game Pieces (starts 0x1FA60).
    try testing.expectEqual(@as(u2, 1), wcwidth(0x1FA54)); // narrow gap after this block
}
test "wcwidth: CJK Extension B and beyond (Plane 2)" {
    try testing.expectEqual(@as(u2, 2), wcwidth(0x20000)); // Extension B start
    try testing.expectEqual(@as(u2, 2), wcwidth(0x2A6DF)); // Extension B end
    try testing.expectEqual(@as(u2, 2), wcwidth(0x2FA1F)); // CJK Compat Supplement end
    try testing.expectEqual(@as(u2, 1), wcwidth(0x2FA20)); // one above
}

test "wcwidth: CJK Extension G and H (Plane 3)" {
    try testing.expectEqual(@as(u2, 2), wcwidth(0x30000)); // Extension G start
    try testing.expectEqual(@as(u2, 2), wcwidth(0x3134A)); // Extension G end
    try testing.expectEqual(@as(u2, 2), wcwidth(0x31350)); // Extension H start
    try testing.expectEqual(@as(u2, 2), wcwidth(0x323AF)); // Extension H end
    try testing.expectEqual(@as(u2, 1), wcwidth(0x323B0)); // one above
}