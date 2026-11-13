//! Character-set registers and translation.
//!
//! The maps that are not a handful of replacements live in
//! `charset_pages.zig`, copied from xterm `charsets.h`.

const std = @import("std");
const pages = @import("charset_pages.zig");

pub const Set = enum(u6) {
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
    dec_technical = 15, // ESC ( >
    jis_roman = 16, // ESC ( J
    jis_katakana = 17, // ESC ( I
    portuguese = 18, // ESC ( % 6
    greek_nrc = 19, // ESC ( " >
    turkish_nrc = 20, // ESC ( % 2
    hebrew_nrc = 21, // ESC ( % =
    dec_hebrew = 22, // ESC ( " 4
    dec_greek = 23, // ESC ( " ?
    dec_turkish = 24, // ESC ( % 0
    dec_suppl_graphic = 25, // ESC ( % 5
    dec_cyrillic = 26, // ESC ( & 4
    serbo_croatian = 27, // ESC ( % 3
    dec_russian = 28, // ESC ( & 5
    iso_latin2 = 29, // ESC - B
    iso_greek = 30, // ESC - F
    iso_hebrew = 31, // ESC - H
    iso_cyrillic = 32, // ESC - L
    iso_latin5 = 33, // ESC - M

    /// True for a 96-set, which includes `0x20` and `0x7F`.
    pub fn is96(self: Set) bool {
        return switch (self) {
            .iso_latin1, .iso_latin2, .iso_greek, .iso_hebrew, .iso_cyrillic, .iso_latin5 => true,
            else => false,
        };
    }

    /// The set that `ESC ( F`, `ESC ) F`, `ESC * F` or `ESC + F`
    /// designates at VT `level` (1 to 5), with `intermediates` as parsed
    /// (the slot byte, then `"`, `%` or `&` if any). `nrc` is DECNRCM.
    /// Null means the sequence is ignored and the slot stays: a final
    /// xterm does not parse here, or one its level does not reach. A
    /// parsed final with no set at this level, or an NRC set without
    /// DECNRCM, designates ASCII. Follows xterm `xtermDecodeSCS`.
    pub fn designation94(intermediates: []const u8, final: u8, level: u3, nrc: bool) ?Set {
        // `gate` is the level at which xterm's parser passes the final
        // on (`VTPrsTbl.c` `scstable` and `scs_*_table`, the
        // `CASE_GSETS*` arms); `group` is the `sgroup` it passes.
        const prefix: u8, const gate: u3, const group: u3 = switch (intermediates.len) {
            1 => switch (final) {
                '0', '1', '2', 'A', 'B' => .{ 0, 1, 1 },
                '4', '5', '6', '7', '<', '=', 'C', 'E', 'H', 'I', 'J', 'K', 'Q', 'R', 'Y', 'Z', 'f' => .{ 0, 2, 2 },
                '9', '>', '`' => .{ 0, 3, 3 },
                else => return null,
            },
            2 => switch (intermediates[1]) {
                '"' => switch (final) {
                    '4', '>', '?' => .{ '"', 5, 5 },
                    else => return null,
                },
                '&' => switch (final) {
                    '4', '5' => .{ '&', 5, 5 },
                    else => return null,
                },
                '%' => switch (final) {
                    '0', '2', '=' => .{ '%', 3, 5 },
                    '3', '5', '6' => .{ '%', 3, 3 },
                    else => return null,
                },
                else => return null,
            },
            else => return null,
        };
        if (level < gate) return null;
        return lookup(prefix, final, group, level, nrc);
    }

    /// The set that `ESC - F`, `ESC . F` or `ESC / F` designates; as
    /// `designation94`.
    pub fn designation96(final: u8, level: u3, nrc: bool) ?Set {
        const gate: u3 = switch (final) {
            'A' => 3,
            'B', 'F', 'H', 'L', 'M' => 5,
            else => return null,
        };
        if (level < gate) return null;
        return lookup(0, final, gate, level, nrc);
    }

    /// The first row of `designations` that matches, as xterm scans its
    /// `scs_table`, else ASCII.
    fn lookup(prefix: u8, final: u8, group: u3, level: u3, nrc: bool) Set {
        for (designations) |row| {
            if (row.prefix == prefix and row.final == final and
                group <= row.min_level and
                row.min_level <= level and level <= row.max_level and
                (!row.nrc or nrc)) return row.set;
        }
        return .ascii;
    }
};

/// One row of xterm's designation table (`charproc.c` `scs_table`): the
/// set that `prefix` and `final` name from VT level `min_level` to
/// `max_level`, and whether it needs DECNRCM.
const Designation = struct {
    set: Set,
    prefix: u8 = 0,
    final: u8,
    min_level: u3,
    max_level: u3 = 7,
    nrc: bool = false,
};

/// xterm `scs_table`, in its order, which decides between rows that
/// share a final. Rex has no DEC Alt Chars or Alt Graphics (`1`, `2`,
/// VT100 only), so those designate ASCII. xterm reads `<` from level 3 as
/// DEC UPSS; Rex has none, so its DEC Supplemental row has no upper
/// level. xterm's British Latin-1 row (`ESC - A` with DECNRCM) is the UK
/// set, which xterm maps the same way.
const designations = [_]Designation{
    .{ .set = .ascii, .final = 'B', .min_level = 1 },
    .{ .set = .uk, .final = 'A', .min_level = 1 },
    .{ .set = .dec_special, .final = '0', .min_level = 1 },
    // VT2xx
    .{ .set = .dec_suppl, .final = '<', .min_level = 2 },
    .{ .set = .dutch, .final = '4', .min_level = 2, .nrc = true },
    .{ .set = .finnish, .final = '5', .min_level = 2, .nrc = true },
    .{ .set = .finnish, .final = 'C', .min_level = 2, .nrc = true },
    .{ .set = .french, .final = 'R', .min_level = 2, .nrc = true },
    .{ .set = .french, .final = 'f', .min_level = 2, .nrc = true },
    .{ .set = .french_ca, .final = 'Q', .min_level = 2, .nrc = true },
    .{ .set = .german, .final = 'K', .min_level = 2, .nrc = true },
    .{ .set = .italian, .final = 'Y', .min_level = 2, .nrc = true },
    .{ .set = .norwegian, .final = 'E', .min_level = 2, .nrc = true },
    .{ .set = .norwegian, .final = '6', .min_level = 2, .nrc = true },
    .{ .set = .spanish, .final = 'Z', .min_level = 2, .nrc = true },
    .{ .set = .swedish, .final = '7', .min_level = 2, .nrc = true },
    .{ .set = .swedish, .final = 'H', .min_level = 2, .nrc = true },
    .{ .set = .swiss, .final = '=', .min_level = 2, .nrc = true },
    // VT3xx
    .{ .set = .uk, .final = 'A', .min_level = 3, .nrc = true },
    .{ .set = .dec_suppl_graphic, .prefix = '%', .final = '5', .min_level = 3 },
    .{ .set = .dec_technical, .final = '>', .min_level = 3 },
    .{ .set = .french_ca, .final = '9', .min_level = 3, .nrc = true },
    .{ .set = .norwegian, .final = '`', .min_level = 3, .nrc = true },
    .{ .set = .portuguese, .prefix = '%', .final = '6', .min_level = 3, .nrc = true },
    .{ .set = .iso_latin1, .final = 'A', .min_level = 3 },
    .{ .set = .jis_katakana, .final = 'I', .min_level = 3, .max_level = 3 },
    .{ .set = .jis_roman, .final = 'J', .min_level = 3, .max_level = 3 },
    // VT5xx
    .{ .set = .greek_nrc, .prefix = '"', .final = '>', .min_level = 5, .nrc = true },
    .{ .set = .hebrew_nrc, .prefix = '%', .final = '=', .min_level = 5, .nrc = true },
    .{ .set = .dec_russian, .prefix = '&', .final = '5', .min_level = 5, .nrc = true },
    .{ .set = .serbo_croatian, .prefix = '%', .final = '3', .min_level = 5, .nrc = true },
    .{ .set = .turkish_nrc, .prefix = '%', .final = '2', .min_level = 5, .nrc = true },
    .{ .set = .dec_cyrillic, .prefix = '&', .final = '4', .min_level = 5 },
    .{ .set = .dec_greek, .prefix = '"', .final = '?', .min_level = 5 },
    .{ .set = .dec_hebrew, .prefix = '"', .final = '4', .min_level = 5 },
    .{ .set = .dec_turkish, .prefix = '%', .final = '0', .min_level = 5 },
    .{ .set = .iso_greek, .final = 'F', .min_level = 5 },
    .{ .set = .iso_hebrew, .final = 'H', .min_level = 5 },
    .{ .set = .iso_latin2, .final = 'B', .min_level = 5 },
    .{ .set = .iso_latin5, .final = 'M', .min_level = 5 },
    .{ .set = .iso_cyrillic, .final = 'L', .min_level = 5 },
};

comptime {
    std.debug.assert(1 == @sizeOf(Set));
    std.debug.assert(6 == @bitSizeOf(Set));
}

/// A single NRC replacement entry: one ASCII byte, one Unicode codepoint.
const NrcEntry = struct { from: u8, to: u21 };

const nrc_dutch: []const NrcEntry = &.{
    .{ .from = '#', .to = 0x00A3 }, // £  pound sign
    .{ .from = '@', .to = 0x00BE }, // ¾  three-quarters
    .{ .from = '[', .to = 0x0133 }, // ij Dutch ij ligature
    .{ .from = '\\', .to = 0x00BD }, // ½  one-half
    .{ .from = ']', .to = 0x007C }, // |  xterm map_NRCS_Dutch 0x5D
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
    .{ .from = '@', .to = 0x00C4 }, // Ä
    .{ .from = '[', .to = 0x00C6 }, // Æ
    .{ .from = '\\', .to = 0x00D8 }, // Ø
    .{ .from = ']', .to = 0x00C5 }, // Å
    .{ .from = '^', .to = 0x00DC }, // Ü
    .{ .from = '`', .to = 0x00E4 }, // ä
    .{ .from = '{', .to = 0x00E6 }, // æ
    .{ .from = '|', .to = 0x00F8 }, // ø
    .{ .from = '}', .to = 0x00E5 }, // å
    .{ .from = '~', .to = 0x00FC }, // ü
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
    .{ .from = '_', .to = 0x00E8 }, // è
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

/// G0..G3, GL, GR, and a pending single shift, packed into 4 bytes.
///
/// GL selects the slot for a 7-bit graphic. GR selects the slot for an
/// 8-bit graphic. SS2 and SS3 override GL for one graphic.
///
/// Bit layout, low bits first:
/// [5:0]    g0
/// [11:6]   g1
/// [17:12]  g2
/// [23:18]  g3
/// [25:24]  gl              0..3 = G0..G3
/// [27:26]  gr              0..3 = G0..G3
/// [30:28]  ss              0..3 pending, 4 = none
/// [31]     pad             must stay 0
pub const Mapping = packed struct(u32) {
    g0: Set = .ascii,
    g1: Set = .ascii,
    g2: Set = .ascii,
    g3: Set = .ascii,

    gl: u2 = 0,
    gr: u2 = 2,

    /// 0..3 selects G0..G3 for one graphic. 4 means no shift is pending.
    /// A bare `?u2` would cost 4 bytes (Zig issue #104).
    ss: u3 = no_shift,
    _pad: u1 = 0,

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
    pub fn slot(self: Mapping, index: u2) Set {
        return switch (index) {
            0 => self.g0,
            1 => self.g1,
            2 => self.g2,
            3 => self.g3,
        };
    }

    /// Sets the charset in slot `index`.
    pub fn setSlot(self: *Mapping, index: u2, cs: Set) void {
        switch (index) {
            0 => self.g0 = cs,
            1 => self.g1 = cs,
            2 => self.g2 = cs,
            3 => self.g3 = cs,
        }
    }

    pub fn hasSingleShift(self: Mapping) bool {
        return self.ss != no_shift;
    }

    pub fn clearSingleShift(self: *Mapping) void {
        self.ss = no_shift;
    }

    /// DEC Supplemental Graphic, 94-set, GL column.
    ///
    /// xterm `map_DEC_Supp_Graphic` (`charsets.h`). Positions it leaves
    /// undefined become U+2426. Everything else is the Latin-1 half
    /// (`cp + 0x80`). Space is not in a 94-set.
    pub fn translateDecSuppl(cp: u21) u21 {
        if (cp < 0x21 or cp > 0x7E) return cp;
        return switch (cp) {
            '$', '&', ',', '-', '.', '/', '4', '8', '>', 'P', '^', 'p', '~' => 0x2426,
            '(' => 0x00A4,
            'W' => 0x0152,
            ']' => 0x0178,
            '_' => 0x005F,
            'w' => 0x0153,
            '}' => 0x00FF,
            else => cp + 0x80,
        };
    }

    /// ISO Latin-1 as a 96-set (ECMA-35, final `A`).
    /// `0x20`..`0x7F` map to U+00A0..U+00FF.
    pub fn translateLatin1(cp: u21) u21 {
        if (cp < 0x20 or cp > 0x7F) return cp;
        return cp + 0x80;
    }

    /// DEC Special Graphics (VT100 line-drawing charset).
    ///
    /// 0x60 to 0x7E follow the VT100 User Guide table 3-9. 0x5F (blank on
    /// a VT100) has no Unicode match; xterm `map_DEC_Spec_Graphic` shows
    /// it as U+2426. Everything else passes through.
    pub fn translateDecSpecial(cp: u21) u21 {
        if (cp == 0x5F) return 0x2426;
        if (cp < 0x60 or cp > 0x7E) return cp;
        return dec_map[cp - 0x60];
    }

    pub fn isIdentity(self: Mapping) bool {
        // No single-shift pending AND the active GL slot is ASCII
        return self.ss == no_shift and self.slot(self.gl) == .ascii;
    }

    /// Translate one codepoint through the active GL slot.
    ///
    /// A single shift overrides GL for one graphic, then clears. A
    /// codepoint outside the set is not a graphic, so the shift stays
    /// pending. A 94-set's graphic range is `0x20`..`0x7E` (space
    /// consumes the shift and passes through). A 96-set also covers
    /// `0x7F`. `uk_pound` is whether the UK set shows `#` as £: xterm
    /// does so only while DECNRCM is set or at level 1, and otherwise
    /// treats UK as ASCII (`charsets.c` `xtermCharSetOut`).
    pub fn translate(self: *Mapping, cp: u21, uk_pound: bool) u21 {
        const shifted = self.ss != no_shift;
        const index: u2 = if (shifted) @truncate(self.ss) else self.gl;
        const cs = self.slot(index);
        const limit: u21 = if (cs.is96()) 0x7F else 0x7E;
        const graphic = cp >= 0x20 and cp <= limit;
        if (shifted and graphic) self.ss = no_shift;
        if (!graphic or cs == .ascii) return cp;

        return switch (cs) {
            .ascii => unreachable,
            .dec_special => translateDecSpecial(cp),
            // xterm draws `<` and `% 5` with the same map.
            .dec_suppl, .dec_suppl_graphic => translateDecSuppl(cp),
            .iso_latin1 => translateLatin1(cp),
            .uk => if (cp == '#' and uk_pound) 0x00A3 else cp,
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
            .dec_technical => pages.lookup(&pages.dec_technical, cp),
            .jis_roman => pages.lookup(&pages.jis_roman, cp),
            .jis_katakana => pages.lookup(&pages.jis_katakana, cp),
            .portuguese => pages.lookup(&pages.portuguese, cp),
            .greek_nrc => pages.lookup(&pages.greek_nrc, cp),
            .turkish_nrc => pages.lookup(&pages.turkish_nrc, cp),
            .hebrew_nrc => pages.lookup(&pages.hebrew_nrc, cp),
            .dec_hebrew => pages.lookup(&pages.dec_hebrew, cp),
            .dec_greek => pages.lookup(&pages.dec_greek, cp),
            .dec_turkish => pages.lookup(&pages.dec_turkish, cp),
            .dec_cyrillic => pages.lookup(&pages.dec_cyrillic, cp),
            .serbo_croatian => pages.lookup(&pages.serbo_croatian, cp),
            .dec_russian => pages.lookup(&pages.dec_russian, cp),
            .iso_latin2 => pages.lookup(&pages.iso_latin2, cp),
            .iso_greek => pages.lookup(&pages.iso_greek, cp),
            .iso_hebrew => pages.lookup(&pages.iso_hebrew, cp),
            .iso_cyrillic => pages.lookup(&pages.iso_cyrillic, cp),
            .iso_latin5 => pages.lookup(&pages.iso_latin5, cp),
        };
    }

    /// An 8-bit byte, `0xA0`..`0xFF`, through the GR slot.
    ///
    /// ASCII and ISO Latin-1 in GR leave the byte, so Latin-1 text is
    /// unchanged until a host designates something else. A 94-set covers
    /// `0xA1`..`0xFE` and leaves `0xA0` and `0xFF`. A 96-set covers the
    /// whole byte. UTF-8 codepoints do not come through here. `uk_pound`
    /// as for `translate`.
    pub fn translateGr(self: Mapping, byte: u8, uk_pound: bool) u21 {
        const cs = self.slot(self.gr);
        if (cs == .ascii or cs == .iso_latin1) return byte;
        if (!cs.is96() and (byte == 0xA0 or byte == 0xFF)) return byte;
        var gl = self;
        gl.ss = no_shift;
        gl.gl = self.gr;
        return gl.translate(byte - 0x80, uk_pound);
    }
};

comptime {
    std.debug.assert(4 == @sizeOf(Mapping));
}

test "Mapping: Latin-1 96-set and DEC supplemental" {
    var latin: Mapping = .{};
    latin.gl = 0;
    latin.setSlot(0, .iso_latin1);
    try std.testing.expectEqual(@as(u21, 0xA0), latin.translate(' ', true));
    try std.testing.expectEqual(@as(u21, 0xC1), latin.translate('A', true));

    var dec: Mapping = .{};
    dec.setSlot(0, .dec_suppl);
    try std.testing.expectEqual(@as(u21, ' '), dec.translate(' ', true));
    try std.testing.expectEqual(@as(u21, 0xC1), dec.translate('A', true));
    try std.testing.expectEqual(@as(u21, 0x0152), dec.translate('W', true));
    try std.testing.expectEqual(@as(u21, 0x2426), dec.translate('$', true));

    var gr: Mapping = .{};
    gr.setSlot(gr.gr, .dec_suppl);
    try std.testing.expectEqual(@as(u21, 0x0152), gr.translateGr(0xD7, true));
    try std.testing.expectEqual(@as(u21, 0xD7), (Mapping{}).translateGr(0xD7, true));
}

test "Set: designations follow xterm's levels and DECNRCM" {
    const d94 = Set.designation94;
    const d96 = Set.designation96;
    // VT100 finals at every level; UK needs no DECNRCM.
    try std.testing.expectEqual(Set.dec_special, d94("(", '0', 1, false));
    try std.testing.expectEqual(Set.uk, d94("(", 'A', 1, false));
    try std.testing.expectEqual(Set.uk, d94("(", 'A', 5, false));
    try std.testing.expectEqual(Set.ascii, d94("(", 'B', 3, false));
    // Alt Chars has no Rex set: ASCII.
    try std.testing.expectEqual(Set.ascii, d94("(", '1', 1, false));
    // An NRC set needs DECNRCM; refused, it is ASCII.
    try std.testing.expectEqual(Set.german, d94("(", 'K', 2, true));
    try std.testing.expectEqual(Set.ascii, d94("(", 'K', 2, false));
    // Below its parser level, or never parsed, the slot stays.
    try std.testing.expectEqual(null, d94("(", 'K', 1, true));
    try std.testing.expectEqual(null, d94("(", '>', 2, false));
    try std.testing.expectEqual(null, d94("(", 'X', 5, true));
    try std.testing.expectEqual(null, d94("(%", '9', 5, true));
    // DEC Supplemental at every level from 2 (no UPSS).
    try std.testing.expectEqual(Set.dec_suppl, d94("(", '<', 2, false));
    try std.testing.expectEqual(Set.dec_suppl, d94("(", '<', 4, false));
    // JIS only at level 3; parsed above it, so ASCII.
    try std.testing.expectEqual(Set.jis_katakana, d94("(", 'I', 3, false));
    try std.testing.expectEqual(Set.ascii, d94("(", 'I', 4, false));
    // `%` parses from level 3; Serbo-Croatian is a level 5 set.
    try std.testing.expectEqual(Set.dec_suppl_graphic, d94("(%", '5', 3, false));
    try std.testing.expectEqual(Set.ascii, d94("(%", '3', 4, true));
    try std.testing.expectEqual(Set.serbo_croatian, d94("(%", '3', 5, true));
    // `"` and `&` parse only from level 5.
    try std.testing.expectEqual(null, d94("(\"", '?', 4, false));
    try std.testing.expectEqual(Set.dec_greek, d94("(\"", '?', 5, false));
    // Rows sharing a final: Swedish needs DECNRCM, then ISO Hebrew.
    try std.testing.expectEqual(Set.swedish, d94("(", 'H', 5, true));
    try std.testing.expectEqual(Set.iso_hebrew, d94("(", 'H', 5, false));
    // 96-sets: Latin-1 from level 3, the rest from level 5.
    try std.testing.expectEqual(null, d96('A', 2, false));
    try std.testing.expectEqual(Set.iso_latin1, d96('A', 3, false));
    try std.testing.expectEqual(Set.uk, d96('A', 3, true));
    try std.testing.expectEqual(null, d96('B', 4, false));
    try std.testing.expectEqual(Set.iso_latin2, d96('B', 5, false));
    try std.testing.expectEqual(null, d96('C', 5, false));
}

test "Mapping: translate DEC special graphics and NRC" {
    var cs: Mapping = .{};
    try std.testing.expect(cs.isIdentity());

    // Switch GL to G1 and set G1 = dec_special
    cs.gl = 1;
    cs.setSlot(1, .dec_special);
    try std.testing.expectEqual('─', cs.translate('q', true));
    try std.testing.expectEqual('┌', cs.translate('l', true));
    try std.testing.expectEqual('┘', cs.translate('j', true));

    // Switch G1 to UK
    cs.setSlot(1, .uk);
    try std.testing.expectEqual(0x00A3, cs.translate('#', true));
    try std.testing.expectEqual('A', cs.translate('A', true));
}

test "Mapping: single-shift override and clear" {
    var cs: Mapping = .{};
    cs.setSlot(2, .dec_special);
    cs.ss = 2; // single-shift to G2
    try std.testing.expect(cs.hasSingleShift());
    try std.testing.expectEqual('─', cs.translate('q', true));
    // SS is one-shot: should clear back to no_shift after one character
    try std.testing.expect(!cs.hasSingleShift());
    try std.testing.expectEqual('q', cs.translate('q', true));
}

test "Mapping: a non-GL codepoint does not consume a single shift" {
    var cs: Mapping = .{};
    cs.setSlot(2, .dec_special);
    cs.ss = 2;
    try std.testing.expectEqual(@as(u21, 0x4E2D), cs.translate(0x4E2D, true));
    try std.testing.expect(cs.hasSingleShift());
    try std.testing.expectEqual('─', cs.translate('q', true));
    try std.testing.expect(!cs.hasSingleShift());
}

test "Mapping: a 96-set DEL consumes a single shift" {
    var latin2: Mapping = .{};
    latin2.setSlot(2, .iso_latin2);
    latin2.ss = 2;
    try std.testing.expectEqual(@as(u21, 0x02D9), latin2.translate(0x7F, true));
    try std.testing.expect(!latin2.hasSingleShift());

    var technical: Mapping = .{};
    technical.setSlot(2, .dec_technical);
    technical.ss = 2;
    try std.testing.expectEqual(@as(u21, 0x7F), technical.translate(0x7F, true));
    try std.testing.expect(technical.hasSingleShift());
}

test "Mapping: Latin-2 GR covers 0xA0 and 0xFF" {
    var cs: Mapping = .{};
    cs.setSlot(cs.gr, .iso_latin2);
    try std.testing.expectEqual(@as(u21, 0x00A0), cs.translateGr(0xA0, true));
    try std.testing.expectEqual(@as(u21, 0x0104), cs.translateGr(0xA1, true));
    try std.testing.expectEqual(@as(u21, 0x02D9), cs.translateGr(0xFF, true));
}

test "Mapping: Norwegian/Danish, Swiss and DEC Special positions from xterm charsets.h" {
    var cs: Mapping = .{};
    cs.setSlot(0, .norwegian);
    try std.testing.expectEqual(@as(u21, 0x00C4), cs.translate('@', true)); // Ä
    try std.testing.expectEqual(@as(u21, 0x00DC), cs.translate('^', true)); // Ü
    try std.testing.expectEqual(@as(u21, 0x00E4), cs.translate('`', true)); // ä
    try std.testing.expectEqual(@as(u21, 0x00FC), cs.translate('~', true)); // ü
    cs.setSlot(0, .swiss);
    try std.testing.expectEqual(@as(u21, 0x00E8), cs.translate('_', true)); // è
    cs.setSlot(0, .dec_special);
    try std.testing.expectEqual(@as(u21, 0x2426), cs.translate('_', true));
}

test "Mapping: NRC German umlauts" {
    var cs: Mapping = .{};
    cs.setSlot(0, .german);
    try std.testing.expectEqual(0x00C4, cs.translate('[', true)); // Ä
    try std.testing.expectEqual(0x00D6, cs.translate('\\', true)); // Ö
    try std.testing.expectEqual(0x00DC, cs.translate(']', true)); // Ü
    try std.testing.expectEqual(0x00DF, cs.translate('~', true)); // ß
}
