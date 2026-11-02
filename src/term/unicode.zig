const std = @import("std");
const testing = std.testing;

/// Bjoern Hoehrmann DFA table.
/// see [Bjoern Hoehrmann DFA](https://bjoern.hoehrmann.de/utf-8/decoder/dfa/) for details.
const utf8d = [_]u8{
    // The first part of the table maps bytes to character classes that
    // to reduce the size of the transition table and create bitmasks.
    0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,
    0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,
    0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,
    0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,
    1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  9,  9,  9,  9,  9,  9,  9,  9,  9,  9,  9,  9,  9,  9,  9,  9,
    7,  7,  7,  7,  7,  7,  7,  7,  7,  7,  7,  7,  7,  7,  7,  7,  7,  7,  7,  7,  7,  7,  7,  7,  7,  7,  7,  7,  7,  7,  7,  7,
    8,  8,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,
    10, 3,  3,  3,  3,  3,  3,  3,  3,  3,  3,  3,  3,  4,  3,  3,  11, 6,  6,  6,  5,  8,  8,  8,  8,  8,  8,  8,  8,  8,  8,  8,

    // The second part is a transition table that maps a combination
    // of a state of the automaton and a character class to a state.
    0,  12, 24, 36, 60, 96, 84, 12, 12, 12, 48, 72, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 0,  12, 12, 12, 12, 12, 0,
    12, 0,  12, 12, 12, 24, 12, 12, 12, 12, 12, 24, 12, 24, 12, 12, 12, 12, 12, 12, 12, 12, 12, 24, 12, 12, 12, 12, 12, 24, 12, 12,
    12, 12, 12, 12, 12, 24, 12, 12, 12, 12, 12, 12, 12, 12, 12, 36, 12, 36, 12, 12, 12, 36, 12, 12, 12, 12, 12, 36, 12, 36, 12, 12,
    12, 36, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12,
};

pub const Utf8Dfa = struct {
    state: u8,
    codepoint: u32,

    pub const accept = 0;
    pub const reject = 12;
    const base: usize = 256;

    pub const empty: Utf8Dfa = .{
        .codepoint = 0,
        .state = 0,
    };

    pub const Result = union(enum) {
        ok,
        codepoint: u32,
        reject,
    };

    pub fn utf8ValidCodepoint(codep: u32) bool {
        return switch (codep) {
            0xD800...0xDFFF => false, // Surrogates range
            0x110000...0x1FFFFF => false, // Above the maximum codepoint value
            else => true,
        };
    }

    pub fn reset(self: *Utf8Dfa) void {
        self.state = 0;
        self.codepoint = 0;
    }

    pub fn finish(self: *Utf8Dfa) Result {
        if (self.state == accept) {
            return .ok;
        }

        // The stream ended in the middle of a UTF-8 sequence.
        self.reset();
        return .reject;
    }

    pub fn feed(self: *Utf8Dfa, byte: u32) Result {
        const typ = utf8d[byte];
        const cont = (self.codepoint << 6) | (byte & 0x3F);
        const mask = @as(u32, 0xFF) >> @intCast(typ);
        const lead = byte & mask;

        self.codepoint = if (self.state != accept) cont else lead;
        self.state = utf8d[base + self.state + typ];

        return switch (self.state) {
            accept => .{ .codepoint = self.codepoint },
            reject => .reject,
            else => .ok,
        };
    }
};

/// Returns the terminal column width of a Unicode codepoint.
///
/// Returns:
///   2 — East Asian Wide (W) or Fullwidth (F) per Unicode 15.1 EastAsianWidth.txt
///   1 — everything else (Narrow, Halfwidth, Neutral, Ambiguous)
///
/// Ambiguous (A) characters are treated as narrow (1), matching the behaviour
/// of xterm, Alacritty, and WezTerm in non-CJK locales.
///
/// Combining characters (width 0) are NOT handled here. The caller (putChar)
/// must resolve them before calling writeChar.
///
/// Control characters (U+0000–U+001F, U+007F–U+009F) are not handled here;
/// the parser must consume them before calling putChar.
///
/// Regional Indicator Symbols (U+1F1E6–U+1F1FF) are Neutral (N) in
/// EastAsianWidth.txt and are treated as narrow (1). Flag sequences are
/// two-codepoint ZWJ pairs; width resolution for those belongs in the
/// renderer, not here.
///
/// Source: Unicode 15.1 EastAsianWidth.txt
pub fn wcwidth(cp: u21) u2 {
    // Fast path: ASCII (U+0000–U+007F). Printable ASCII is always narrow.
    // Control characters in this range are handled by the parser before
    // reaching putChar, so returning 1 here is safe.
    if (cp < 0x80) return 1;

    return switch (cp) {
        // Hangul Jamo
        0x1100...0x115F, // Leading Consonants (W)

        // Angle Brackets (deprecated Wide)
        0x2329...0x232A,

        // Wide emoji in Misc Symbols / Dingbats / Arrows (U+2300–U+2BFF)
        // Property W in Unicode 15.1 EastAsianWidth.txt.
        // Ambiguous (A) codepoints in this range are intentionally omitted.
        0x231A...0x231B, // Watch, Hourglass Done
        0x23E9...0x23F3, // Fast-forward .. Timer Clock
        0x23F8...0x23FA, // Pause .. Record
        0x2614...0x2615, // Umbrella with Rain, Hot Beverage
        0x2648...0x2653, // Zodiac signs (Aries–Pisces)
        0x267F, // Wheelchair Symbol
        0x2693, // Anchor
        0x26A1, // High Voltage
        0x26AA...0x26AB, // Medium White/Black Circle
        0x26BD...0x26BE, // Soccer Ball, Baseball
        0x26C4...0x26C5, // Snowman Without Snow, Sun Behind Cloud
        0x26CE, // Ophiuchus
        0x26D4, // No Entry
        0x26EA, // Church
        0x26F2...0x26F3, // Fountain, Flag in Hole
        0x26F5, // Sailboat
        0x26FA, // Tent
        0x26FD, // Fuel Pump
        0x2705, // White Heavy Check Mark
        0x2714, // Heavy Check Mark
        0x2716, // Heavy Multiplication X
        0x2728, // Sparkles
        0x274C, // Cross Mark
        0x274E, // Cross Mark (heavy)
        0x2753...0x2755, // Question Mark Ornaments
        0x2757, // Heavy Exclamation Mark Ornament
        0x2764, // Heavy Black Heart (0x2763 is A — omitted)
        0x2795...0x2797, // Heavy Plus/Minus/Division Sign
        0x27B0, // Curly Loop
        0x27BF, // Double Curly Loop
        0x2934...0x2935, // Arrow Pointing Rightward/Leftward Then Curving Down/Up
        0x2B05...0x2B07, // Leftwards/Rightwards/Downwards Black Arrow
        0x2B1B...0x2B1C, // Black/White Large Square
        0x2B50, // White Medium Star
        0x2B55, // Heavy Large Circle

        // ── CJK Radicals, Kangxi, CJK Symbols, Hiragana, Katakana, Bopomofo ──
        // 0x303F (IDEOGRAPHIC HALF FILL SPACE) is N — excluded by ending at 303E.
        // 0x3040 is unassigned but listed W in EastAsianWidth.txt; starting at
        // 3041 is conservative and correct for assigned codepoints.
        0x2E80...0x303E,
        0x3041...0x33FF, // Hiragana .. CJK Compatibility
        0x3400...0x4DBF, // CJK Extension A
        // 0x4E00..0xA4CF merges CJK Unified Ideographs (4E00–9FFF) and
        // Yi Syllables/Radicals (A000–A4CF) — contiguous, all Wide.
        0x4E00...0xA4CF,
        0xA960...0xA97F, // Hangul Jamo Extended-A
        0xAC00...0xD7AF, // Hangul Syllables
        0xD7B0...0xD7C6, // Hangul Jamo Extended-B vowels
        0xD7CB...0xD7FB, // Hangul Jamo Extended-B trailing jamo
        0xF900...0xFAFF, // CJK Compatibility Ideographs
        0xFE10...0xFE1F, // Vertical Forms
        0xFE30...0xFE6F, // CJK Compatibility Forms .. Small Form Variants
        0xFF01...0xFF60, // Fullwidth Latin and Punctuation
        0xFFE0...0xFFE6, // Fullwidth Signs

        // ── Tangut, Khitan, Nushu (Plane 1) ──────────────────────────────────
        0x16FE0...0x16FE4,
        0x16FF0...0x16FF1,
        0x17000...0x187F7, // Tangut
        0x18800...0x18CD5, // Tangut Components
        0x18D00...0x18D08, // Tangut Supplement

        // ── Katakana Phonetic Extensions (Unicode 15.0) ───────────────────────
        0x1AFF0...0x1AFF3,
        0x1AFF5...0x1AFFB,
        0x1AFFD...0x1AFFE,

        // ── Kana Extended, Small Kana, Nushu ─────────────────────────────────
        0x1B000...0x1B122,
        0x1B132,
        0x1B150...0x1B152,
        0x1B155,
        0x1B164...0x1B167,
        0x1B170...0x1B2FB, // Nushu

        // ── Tai Xuan Jing, Counting Rod Numerals ─────────────────────────────
        0x1D300...0x1D356,
        0x1D360...0x1D376,

        // ── Enclosed CJK ─────────────────────────────────────────────────────
        0x1F004, // Mahjong Tile Red Dragon
        0x1F0CF, // Playing Card Black Joker
        0x1F18E, // Negative Squared AB
        0x1F191...0x1F19A,
        0x1F201...0x1F202,
        0x1F21A,
        0x1F22F,
        0x1F232...0x1F23A,
        0x1F250...0x1F251,

        // ── Emoji and Pictographs (W per EastAsianWidth.txt) ──────────────────
        0x1F300...0x1F320,
        0x1F32D...0x1F335,
        0x1F337...0x1F37C,
        0x1F37E...0x1F393,
        0x1F3A0...0x1F3CA,
        0x1F3CF...0x1F3D3,
        0x1F3E0...0x1F3F0,
        0x1F3F4,
        0x1F3F8...0x1F43E,
        0x1F440,
        0x1F442...0x1F4FC,
        0x1F4FF...0x1F53D,
        0x1F54B...0x1F54E,
        0x1F550...0x1F567,
        0x1F57A,
        0x1F595...0x1F596,
        0x1F5A4,
        0x1F5FB...0x1F64F,
        0x1F680...0x1F6C5,
        0x1F6CC,
        0x1F6D0...0x1F6D2,
        0x1F6D5...0x1F6D7,
        0x1F6DC...0x1F6DF,
        0x1F6EB...0x1F6EC,
        0x1F6F4...0x1F6FC,
        0x1F7E0...0x1F7EB,
        0x1F7F0,
        0x1F90C...0x1F93A,
        0x1F93C...0x1F945,
        0x1F947...0x1F9FF,
        0x1FA00...0x1FA53,
        0x1FA60...0x1FA6D,
        0x1FA70...0x1FA7C,
        0x1FA80...0x1FA88,
        0x1FA90...0x1FABD,
        0x1FABF...0x1FAC5,
        0x1FACE...0x1FADB,
        0x1FAE0...0x1FAE8,
        0x1FAF0...0x1FAF8,

        // ── CJK Extensions B–I (Planes 2–3) ──────────────────────────────────
        0x20000...0x2A6DF, // CJK Extension B
        0x2A700...0x2B739, // CJK Extension C (Unicode 15.0 end: 2B739)
        0x2B740...0x2B81D, // CJK Extension D
        0x2B820...0x2CEA1, // CJK Extension E
        0x2CEB0...0x2EBEF, // CJK Extension F (corrected end: 2EBEF)
        0x2EBF0...0x2EE5D, // CJK Extension I (Unicode 15.1)
        0x2F800...0x2FA1F, // CJK Compatibility Ideographs Supplement
        0x30000...0x3134A, // CJK Extension G
        0x31350...0x323AF, // CJK Extension H
        => 2,

        // Zero-width / non-spacing
        0x0300...0x036F, // Combining Diacritical Marks
        0x0483...0x0489,
        0x0591...0x05BD,
        0x05BF,
        0x05C1...0x05C2,
        0x05C4...0x05C5,
        0x05C7,
        0x0610...0x061A,
        0x064B...0x065F,
        0x0670,
        0x06D6...0x06DC,
        0x06DF...0x06E4,
        0x06E7...0x06E8,
        0x06EA...0x06ED,
        // ... (many more combining ranges)

        // Critical for emoji:
        0x200B, // ZERO WIDTH SPACE
        0x200C, // ZERO WIDTH NON-JOINER
        0x200D, // ZERO WIDTH JOINER
        0xFE00...0xFE0F, // VARIATION SELECTORS (FE0F = emoji presentation)
        0xFEFF, // ZERO WIDTH NO-BREAK SPACE
        // 0x1F3FB...0x1F3FF, // EMOJI MODIFIER FITZPATRICK (skin tones)
        0xE0020...0xE007F, // TAGS (used in flag sequences)
        => 0,

        else => 1,
    };
}

comptime {
    std.debug.assert(wcwidth('A') == 1);
    std.debug.assert(wcwidth(0x4E2D) == 2); // 中
    // std.debug.assert(wcwidth(0x1F600) == 2); // 😀
    std.debug.assert(wcwidth(0x231A) == 2); // ⌚ Watch (W, was missing)
    std.debug.assert(wcwidth(0x2B50) == 2); // ⭐ Star (W, was missing)
    std.debug.assert(wcwidth(0xD7B0) == 2); // Hangul Jamo Extended-B (was missing)
    std.debug.assert(wcwidth(0x2B739) == 2); // CJK Extension C last char
    std.debug.assert(wcwidth(0x2CEB0) == 2); // CJK Extension F first char
    std.debug.assert(wcwidth(0x2EBEF) == 2); // CJK Extension F last char
    std.debug.assert(wcwidth(0x1F1E6) == 1); // Regional Indicator A — Neutral
    std.debug.assert(wcwidth(0x25AA) == 1); // Small Black Square — Ambiguous, narrow

    // Wide, one per major range group
    std.debug.assert(wcwidth(0x1100) == 2); // Hangul Jamo
    std.debug.assert(wcwidth(0x3041) == 2); // Hiragana 'あ'
    std.debug.assert(wcwidth(0xAC00) == 2); // Hangul Syllable '가'
    std.debug.assert(wcwidth(0xFF01) == 2); // Fullwidth '！'
    std.debug.assert(wcwidth(0xFFE0) == 2); // Fullwidth Cent Sign
    std.debug.assert(wcwidth(0x20000) == 2); // CJK Extension B
    std.debug.assert(wcwidth(0x30000) == 2); // CJK Extension G

    // Narrow, boundary exclusions
    std.debug.assert(wcwidth(0x7F) == 1); // DEL (else branch)
    std.debug.assert(wcwidth(0x00E9) == 1); // 'é' non-ASCII narrow
    std.debug.assert(wcwidth(0x303F) == 1); // excluded from CJK Radicals range
    std.debug.assert(wcwidth(0x4DC0) == 1); // gap between Ext-A and CJK Unified

}

test {
    _ = @import("unicode_test.zig");
}
