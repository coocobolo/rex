//! Character set state and translation for VT100 / VT220 National Replacement
//! Character sets (NRC) and DEC Special Graphics line-drawing sets.

const std = @import("std");

pub const Charset = enum(u4) {
    ascii = 0, // ISO 646 / US-ASCII (default)
    dec_special = 1, // DEC Special Graphics (box drawing)
    dec_suppl = 2, // DEC Supplemental (VT220)
    uk = 3, // British NRC (# shows as £)
    dutch = 4, // Dutch NRC
    finnish = 5, // Finnish NRC
    french = 6, // French NRC
    french_ca = 7, // French Canadian NRC
    german = 8, // German NRC
    italian = 9, // Italian NRC
    norwegian = 10, // Norwegian/Danish NRC
    spanish = 11, // Spanish NRC
    swedish = 12, // Swedish NRC
    swiss = 13, // Swiss NRC
    iso_latin1 = 14, // ISO Latin-1 (VT220 GR)
    // 15 reserved

    /// Map the final byte of ESC ( X / ESC ) X / ESC * X / ESC + X to a Charset.
    /// Returns null for unrecognized designators.
    /// Fallbacks to ascii if mismatch.
    pub fn charsetFromByte(byte: u8) Charset {
        return switch (byte) {
            '0' => .dec_special,
            '4' => .dutch,
            '5', 'C' => .finnish,
            '6', '`', 'E' => .norwegian,
            '7', 'H' => .swedish,
            '9', 'Q' => .french_ca,
            'A' => .uk,
            'B' => .ascii,
            '<' => .dec_suppl,
            'K' => .german,
            'R', 'f' => .french,
            '=' => .swiss,
            'Y' => .italian,
            'Z' => .spanish,
            else => .ascii,
        };
    }

    /// Map the final byte of ESC - X / ESC . X / ESC / X to a Charset.
    ///
    /// These are 96-character set designations (ECMA-35 §14.3, VT300+).
    /// The final byte space is different from the 94-char table used by
    /// ESC ( ) * +.  Only ISO 8859-1 (Latin-1) is currently implemented;
    /// the remaining ISO 8859 variants fall back to .ascii (pass-through)
    /// until their codepoint tables are added to the enum.
    pub fn charsetFromByte96(final: u8) Charset {
        return switch (final) {
            'A' => .iso_latin1, // ISO 8859-1  Latin-1  (VT220+)
            'B' => .ascii, // ISO 8859-2  Latin-2  (not yet implemented)
            'C' => .ascii, // ISO 8859-3  Latin-3  (not yet implemented)
            'D' => .ascii, // ISO 8859-4  Latin-4  (not yet implemented)
            'F' => .ascii, // ISO 8859-7  Greek    (not yet implemented)
            'H' => .ascii, // ISO 8859-8  Hebrew   (not yet implemented)
            'L' => .ascii, // ISO 8859-5  Cyrillic (not yet implemented)
            'M' => .ascii, // ISO 8859-9  Turkish  (not yet implemented)
            'V' => .ascii, // ISO 8859-10 Nordic   (not yet implemented)
            'Y' => .ascii, // ISO 8859-15 Latin-9  (not yet implemented)
            else => .ascii, // unknown, pass-through
        };
    }
};

comptime {
    std.debug.assert(1 == @sizeOf(Charset));
    std.debug.assert(4 == @bitSizeOf(Charset));
}

/// A single NRC replacement entry: one ASCII byte, one Unicode codepoint.
const NrcEntry = struct { from: u8, to: u21 };

const nrc_dutch: []const NrcEntry = &.{
    .{ .from = '#', .to = 0x00A3 }, // £  pound sign
    .{ .from = '@', .to = 0x00BE }, // ¾  three-quarters
    .{ .from = '[', .to = 0x0133 }, // ij Dutch ij ligature
    .{ .from = '\\', .to = 0x00BD }, // ½  one-half
    .{ .from = '{', .to = 0x00A8 }, // ¨  diaeresis
    .{ .from = '|', .to = 0x0192 }, // ƒ  florin / guilder sign
    .{ .from = '}', .to = 0x00BC }, // ¼  one-quarter
    .{ .from = '~', .to = 0x00B4 }, // ´  acute accent
};

const nrc_finnish: []const NrcEntry = &.{
    .{ .from = '[', .to = 0x00C4 }, // Ä
    .{ .from = '\\', .to = 0x00D6 }, // Ö
    .{ .from = ']', .to = 0x00C5 }, // Å
    .{ .from = '^', .to = 0x00DC }, // Ü
    .{ .from = '`', .to = 0x00E9 }, // é
    .{ .from = '{', .to = 0x00E4 }, // ä
    .{ .from = '|', .to = 0x00F6 }, // ö
    .{ .from = '}', .to = 0x00E5 }, // å
    .{ .from = '~', .to = 0x00FC }, // ü
};

const nrc_french: []const NrcEntry = &.{
    .{ .from = '#', .to = 0x00A3 }, // £
    .{ .from = '@', .to = 0x00E0 }, // à
    .{ .from = '[', .to = 0x00B0 }, // °  degree
    .{ .from = '\\', .to = 0x00E7 }, // ç
    .{ .from = ']', .to = 0x00A7 }, // §  section
    .{ .from = '`', .to = 0x00B5 }, // µ  micro
    .{ .from = '{', .to = 0x00E9 }, // é
    .{ .from = '|', .to = 0x00F9 }, // ù
    .{ .from = '}', .to = 0x00E8 }, // è
    .{ .from = '~', .to = 0x00A8 }, // ¨  diaeresis
};

const nrc_french_ca: []const NrcEntry = &.{
    .{ .from = '@', .to = 0x00E0 }, // à
    .{ .from = '[', .to = 0x00E2 }, // â
    .{ .from = '\\', .to = 0x00E7 }, // ç
    .{ .from = ']', .to = 0x00EA }, // ê
    .{ .from = '^', .to = 0x00EE }, // î
    .{ .from = '`', .to = 0x00F4 }, // ô
    .{ .from = '{', .to = 0x00E9 }, // é
    .{ .from = '|', .to = 0x00F9 }, // ù
    .{ .from = '}', .to = 0x00E8 }, // è
    .{ .from = '~', .to = 0x00FB }, // û
};

const nrc_german: []const NrcEntry = &.{
    .{ .from = '@', .to = 0x00A7 }, // §  section
    .{ .from = '[', .to = 0x00C4 }, // Ä
    .{ .from = '\\', .to = 0x00D6 }, // Ö
    .{ .from = ']', .to = 0x00DC }, // Ü
    .{ .from = '{', .to = 0x00E4 }, // ä
    .{ .from = '|', .to = 0x00F6 }, // ö
    .{ .from = '}', .to = 0x00FC }, // ü
    .{ .from = '~', .to = 0x00DF }, // ß
};

const nrc_italian: []const NrcEntry = &.{
    .{ .from = '#', .to = 0x00A3 }, // £
    .{ .from = '@', .to = 0x00A7 }, // §
    .{ .from = '[', .to = 0x00B0 }, // °
    .{ .from = '\\', .to = 0x00E7 }, // ç
    .{ .from = ']', .to = 0x00E9 }, // é
    .{ .from = '`', .to = 0x00F9 }, // ù
    .{ .from = '{', .to = 0x00E0 }, // à
    .{ .from = '|', .to = 0x00F2 }, // ò
    .{ .from = '}', .to = 0x00E8 }, // è
    .{ .from = '~', .to = 0x00EC }, // ì
};

const nrc_norwegian: []const NrcEntry = &.{
    .{ .from = '[', .to = 0x00C6 }, // Æ
    .{ .from = '\\', .to = 0x00D8 }, // Ø
    .{ .from = ']', .to = 0x00C5 }, // Å
    .{ .from = '{', .to = 0x00E6 }, // æ
    .{ .from = '|', .to = 0x00F8 }, // ø
    .{ .from = '}', .to = 0x00E5 }, // å
};

const nrc_spanish: []const NrcEntry = &.{
    .{ .from = '#', .to = 0x00A3 }, // £
    .{ .from = '@', .to = 0x00A7 }, // §
    .{ .from = '[', .to = 0x00A1 }, // ¡  inverted exclamation
    .{ .from = '\\', .to = 0x00D1 }, // Ñ
    .{ .from = ']', .to = 0x00BF }, // ¿  inverted question
    .{ .from = '{', .to = 0x00B0 }, // °
    .{ .from = '|', .to = 0x00F1 }, // ñ
    .{ .from = '}', .to = 0x00E7 }, // ç
};

const nrc_swedish: []const NrcEntry = &.{
    .{ .from = '@', .to = 0x00C9 }, // É
    .{ .from = '[', .to = 0x00C4 }, // Ä
    .{ .from = '\\', .to = 0x00D6 }, // Ö
    .{ .from = ']', .to = 0x00C5 }, // Å
    .{ .from = '^', .to = 0x00DC }, // Ü
    .{ .from = '`', .to = 0x00E9 }, // é
    .{ .from = '{', .to = 0x00E4 }, // ä
    .{ .from = '|', .to = 0x00F6 }, // ö
    .{ .from = '}', .to = 0x00E5 }, // å
    .{ .from = '~', .to = 0x00FC }, // ü
};

const nrc_swiss: []const NrcEntry = &.{
    .{ .from = '#', .to = 0x00F9 }, // ù
    .{ .from = '@', .to = 0x00E0 }, // à
    .{ .from = '[', .to = 0x00E9 }, // é
    .{ .from = '\\', .to = 0x00E7 }, // ç
    .{ .from = ']', .to = 0x00EA }, // ê
    .{ .from = '^', .to = 0x00EE }, // î
    .{ .from = '`', .to = 0x00F4 }, // ô
    .{ .from = '{', .to = 0x00E4 }, // ä
    .{ .from = '|', .to = 0x00F6 }, // ö
    .{ .from = '}', .to = 0x00FC }, // ü
    .{ .from = '~', .to = 0x00FB }, // û
};

pub const dec_map = [_]u21{
    '◆', // 0x60 `  black diamond
    '▒', // 0x61 a  medium shade
    '␉', // 0x62 b  HT symbol
    '␌', // 0x63 c  FF symbol
    '␍', // 0x64 d  CR symbol
    '␊', // 0x65 e  LF symbol
    '°', // 0x66 f  degree sign
    '±', // 0x67 g  plus-minus
    '␤', // 0x68 h  NL symbol
    '␋', // 0x69 i  VT symbol
    '┘', // 0x6A j  lower-right corner
    '┐', // 0x6B k  upper-right corner
    '┌', // 0x6C l  upper-left corner
    '└', // 0x6D m  lower-left corner
    '┼', // 0x6E n  crossing lines
    '⎺', // 0x6F o  scan line 1
    '⎻', // 0x70 p  scan line 3
    '─', // 0x71 q  horizontal line (scan line 5)
    '⎼', // 0x72 r  scan line 7
    '⎽', // 0x73 s  scan line 9
    '├', // 0x74 t  left tee
    '┤', // 0x75 u  right tee
    '┴', // 0x76 v  bottom tee
    '┬', // 0x77 w  top tee
    '│', // 0x78 x  vertical line
    '≤', // 0x79 y  less-than-or-equal
    '≥', // 0x7A z  greater-than-or-equal
    'π', // 0x7B {  pi
    '≠', // 0x7C |  not-equal
    '£', // 0x7D }  pound sign
    '·', // 0x7E ~  middle dot
};

comptime {
    std.debug.assert(dec_map.len == 0x7E - 0x60 + 1);
}

/// VT100/VT220 character set state, packed into 4 bytes (u32).
///
/// Terminals maintain four charset slots (G0 to G3), each designatable to
/// a named character set via ESC ( X … ESC + X. The GL register selects
/// which slot maps to the 7-bit range; GR selects the 8-bit range.
/// SS2 (ESC N) and SS3 (ESC O) temporarily override GL for one character.
///
/// Bit layout (32 bits total):
/// [3:0]      g0              G0 slot charset (Charset, 4 bits)
/// [7:4]      g1              G1 slot charset (Charset, 4 bits)
/// [11:8]     g2              G2 slot charset (Charset, 4 bits)
/// [15:12]    g3              G3 slot charset (Charset, 4 bits)
/// [17:16]    gl              active GL register (0 to 3 = G0 to G3)
/// [19:18]    gr              active GR register (0 to 3 = G0 to G3)
/// [22:20]    single_shift    0 to 3 = G0 to G3 pending; 4 = none (sentinel)
/// [31:23]    _pad            reserved, must be 0
pub const CharsetState = packed struct(u32) {
    g0: Charset = .ascii,
    g1: Charset = .ascii,
    g2: Charset = .ascii,
    g3: Charset = .ascii,
    // 4×4 = 16 bits used

    gl: u2 = 0, // GL register (0 to 3 = G0 to G3)
    gr: u2 = 2, // GR register (0 to 3 = G0 to G3)

    /// Single-shift override for the next character only (SS2/SS3).
    /// Values 0 to 3 = G0 to G3 pending. Value 4 = no shift pending (sentinel).
    /// Replaces `?u2` (which would cost 4 bytes due to Zig issue #104).
    ss: u3 = no_shift,
    _pad: u9 = 0,
    // 16 + 2 + 2 + 3 + 9 = 32 bits

    pub const no_shift: u3 = 4;

    /// Linear scan through a comptime NRC table.
    /// Tables are tiny (≤12 entries) so a loop is faster than a hash map.
    fn translateNrc(cp: u21, comptime table: []const NrcEntry) u21 {
        inline for (table) |e| if (cp == e.from) return e.to;
        return cp;
    }

    // VT220 NRC tables
    // Source: DEC STD 070 / VT220 Programmer Reference Manual (EK-VT220-RM-002).
    // Only the 12 replaceable positions are listed; all other bytes pass through.
    // Replaceable positions: # @ [ \ ] ^ ` { | } ~

    /// Returns the charset in slot `index` (0 to 3 = G0 to G3).
    pub fn slot(self: CharsetState, index: u2) Charset {
        return switch (index) {
            0 => self.g0,
            1 => self.g1,
            2 => self.g2,
            3 => self.g3,
        };
    }

    /// Sets the charset in slot `index`.
    pub fn setSlot(self: *CharsetState, index: u2, cs: Charset) void {
        switch (index) {
            0 => self.g0 = cs,
            1 => self.g1 = cs,
            2 => self.g2 = cs,
            3 => self.g3 = cs,
        }
    }

    pub fn hasSingleShift(self: CharsetState) bool {
        return self.ss != no_shift;
    }

    pub fn clearSingleShift(self: *CharsetState) void {
        self.ss = no_shift;
    }

    /// DEC Special Graphics (VT100 line-drawing charset).
    ///
    /// Only the 0x60 to 0x7E range is remapped; everything else passes through.
    /// The mapping follows the VT100 User Guide table 3-9.
    pub fn translateDecSpecial(cp: u21) u21 {
        if (cp < 0x60 or cp > 0x7E) return cp;
        return dec_map[cp - 0x60];
    }

    pub fn isIdentity(self: CharsetState) bool {
        // No single-shift pending AND the active GL slot is ASCII
        return self.ss == no_shift and self.slot(self.gl) == .ascii;
    }

    /// Translate a raw codepoint through the active charset mapping.
    ///
    /// Single-shift (SS2/SS3) overrides GL for exactly one character.
    /// After consuming the single-shift, it is cleared automatically.
    ///
    /// Only the 0x20 to 0x7E printable ASCII range is remapped; control
    /// characters and codepoints outside that range pass through unchanged.
    pub fn translate(self: *CharsetState, cp: u21) u21 {
        // Determine which slot to use: single-shift overrides GL.
        const index: u2 = if (self.ss != no_shift) blk: {
            const ss: u2 = @truncate(self.ss);
            self.ss = no_shift;
            break :blk ss;
        } else self.gl;

        const cs = self.slot(index);
        if (cs == .ascii) return cp; // no range check needed for ASCII

        // Only remap printable ASCII range for non-ASCII charsets
        if (cp < 0x20 or cp > 0x7E) return cp;

        return switch (self.slot(index)) {
            .ascii => unreachable, // ascii is fast path, doesn't pay for range check
            .dec_special => translateDecSpecial(cp),
            // dec_suppl and iso_latin1 are GR sets (0xA0 to 0xFF range).
            // When designated as GL they are used via locking shift; the
            // 7-bit printable range passes through unchanged here.
            // Full GR translation requires a separate translateGr() path.
            .dec_suppl, .iso_latin1 => cp,
            .uk => if (cp == '#') 0x00A3 else cp,
            .dutch => translateNrc(cp, nrc_dutch),
            .finnish => translateNrc(cp, nrc_finnish),
            .french => translateNrc(cp, nrc_french),
            .french_ca => translateNrc(cp, nrc_french_ca),
            .german => translateNrc(cp, nrc_german),
            .italian => translateNrc(cp, nrc_italian),
            .norwegian => translateNrc(cp, nrc_norwegian),
            .spanish => translateNrc(cp, nrc_spanish),
            .swedish => translateNrc(cp, nrc_swedish),
            .swiss => translateNrc(cp, nrc_swiss),
        };
    }
};

comptime {
    std.debug.assert(4 == @sizeOf(CharsetState));
}

test "Charset: designator mapping" {
    try std.testing.expectEqual(Charset.dec_special, Charset.charsetFromByte('0'));
    try std.testing.expectEqual(Charset.uk, Charset.charsetFromByte('A'));
    try std.testing.expectEqual(Charset.ascii, Charset.charsetFromByte('B'));
    try std.testing.expectEqual(Charset.iso_latin1, Charset.charsetFromByte96('A'));
}

test "CharsetState: translate DEC special graphics and NRC" {
    var cs: CharsetState = .{};
    try std.testing.expect(cs.isIdentity());

    // Switch GL to G1 and set G1 = dec_special
    cs.gl = 1;
    cs.setSlot(1, .dec_special);
    try std.testing.expectEqual('─', cs.translate('q'));
    try std.testing.expectEqual('┌', cs.translate('l'));
    try std.testing.expectEqual('┘', cs.translate('j'));

    // Switch G1 to UK
    cs.setSlot(1, .uk);
    try std.testing.expectEqual(0x00A3, cs.translate('#'));
    try std.testing.expectEqual('A', cs.translate('A'));
}

test "CharsetState: single-shift override and clear" {
    var cs: CharsetState = .{};
    cs.setSlot(2, .dec_special);
    cs.ss = 2; // single-shift to G2
    try std.testing.expect(cs.hasSingleShift());
    try std.testing.expectEqual('─', cs.translate('q'));
    // SS is one-shot: should clear back to no_shift after one character
    try std.testing.expect(!cs.hasSingleShift());
    try std.testing.expectEqual('q', cs.translate('q'));
}

test "CharsetState: NRC German umlauts" {
    var cs: CharsetState = .{};
    cs.setSlot(0, .german);
    try std.testing.expectEqual(0x00C4, cs.translate('[')); // Ä
    try std.testing.expectEqual(0x00D6, cs.translate('\\')); // Ö
    try std.testing.expectEqual(0x00DC, cs.translate(']')); // Ü
    try std.testing.expectEqual(0x00DF, cs.translate('~')); // ß
}
