//! Character sets: the G0 to G3 registers, which sequence designates
//! which set (as xterm), and translation through GL and GR. The code
//! points every set prints are in `charset_pages.zig`, generated from
//! xterm's charsets.h.

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
        const prefix: usize = switch (intermediates.len) {
            1 => 0,
            2 => switch (intermediates[1]) {
                '"' => 1,
                '%' => 2,
                '&' => 3,
                else => return null,
            },
            else => return null,
        };
        return answer(&answers94[prefix], final, level, nrc);
    }

    /// The set that `ESC - F`, `ESC . F` or `ESC / F` designates; as
    /// `designation94`.
    pub fn designation96(final: u8, level: u3, nrc: bool) ?Set {
        return answer(&answers96, final, level, nrc);
    }
};

/// Every designation's outcome, worked out at compile time from xterm's
/// rules (`decide94`, `decide96`), so a designation at run time is one
/// load: htop designates on almost every line. Indexed by the final
/// minus 0x20, the VT level minus 1 and DECNRCM. `ignored` is null.
const Answers = [96][5][2]u8;
const ignored: u8 = 0xFF;

/// For no intermediate after the slot byte, then `"`, `%` and `&`.
const answers94 = [_]Answers{ tabulate(.set94, 0), tabulate(.set94, '"'), tabulate(.set94, '%'), tabulate(.set94, '&') };
const answers96 = tabulate(.set96, 0);

fn answer(table: *const Answers, final: u8, level: u3, nrc: bool) ?Set {
    if (final < 0x20 or final > 0x7F) return null;
    std.debug.assert(level >= 1 and level <= 5);
    const a = table[final - 0x20][level - 1][@intFromBool(nrc)];
    return if (a == ignored) null else @enumFromInt(a);
}

fn tabulate(comptime size: enum { set94, set96 }, comptime prefix: u8) Answers {
    @setEvalBranchQuota(400_000);
    var out: Answers = undefined;
    for (0..96) |f| {
        for (1..6) |level| {
            for (0..2) |nrc| {
                const final: u8 = @intCast(0x20 + f);
                const set = switch (size) {
                    .set94 => decide94(prefix, final, level, nrc == 1),
                    .set96 => decide96(final, level, nrc == 1),
                };
                out[f][level - 1][nrc] = if (set) |s| @intFromEnum(s) else ignored;
            }
        }
    }
    return out;
}

/// xterm's answer for a 94-set designation with `prefix` (0, `"`, `%` or
/// `&`) after the slot byte. `gate` is the level at which xterm's parser
/// passes the final on (`VTPrsTbl.c` `scstable` and `scs_*_table`, the
/// `CASE_GSETS*` arms); `group` is the `sgroup` it passes to
/// `xtermDecodeSCS`.
fn decide94(prefix: u8, final: u8, level: usize, nrc: bool) ?Set {
    const gate: usize, const group: usize = switch (prefix) {
        0 => switch (final) {
            '0', '1', '2', 'A', 'B' => .{ 1, 1 },
            '4', '5', '6', '7', '<', '=', 'C', 'E', 'H', 'I', 'J', 'K', 'Q', 'R', 'Y', 'Z', 'f' => .{ 2, 2 },
            '9', '>', '`' => .{ 3, 3 },
            else => return null,
        },
        '"' => switch (final) {
            '4', '>', '?' => .{ 5, 5 },
            else => return null,
        },
        '&' => switch (final) {
            '4', '5' => .{ 5, 5 },
            else => return null,
        },
        '%' => switch (final) {
            '0', '2', '=' => .{ 3, 5 },
            '3', '5', '6' => .{ 3, 3 },
            else => return null,
        },
        else => return null,
    };
    if (level < gate) return null;
    return firstRow(prefix, final, group, level, nrc);
}

/// xterm's answer for a 96-set designation (`ESC - F` and so on).
fn decide96(final: u8, level: usize, nrc: bool) ?Set {
    const gate: usize = switch (final) {
        'A' => 3,
        'B', 'F', 'H', 'L', 'M' => 5,
        else => return null,
    };
    if (level < gate) return null;
    return firstRow(0, final, gate, level, nrc);
}

/// The first row of `designations` that matches, as xterm scans its
/// `scs_table`, else ASCII.
fn firstRow(prefix: u8, final: u8, group: usize, level: usize, nrc: bool) Set {
    for (designations) |row| {
        if (row.prefix == prefix and row.final == final and
            group <= row.min_level and
            row.min_level <= level and level <= row.max_level and
            (!row.nrc or nrc)) return row.set;
    }
    return .ascii;
}

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
        if (!graphic) return cp;

        if (cs == .uk) return if (cp == '#' and uk_pound) 0x00A3 else cp;
        const page = page_of[@intFromEnum(cs)] orelse return cp;
        return page[cp - 0x20];
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

/// The page each set prints through; null for ASCII and for UK, whose
/// one replacement depends on `uk_pound`.
const page_of = std.enums.directEnumArray(Set, ?*const pages.Page, 0, .{
    .ascii = null,
    .dec_special = &pages.dec_special,
    .dec_suppl = &pages.dec_suppl,
    .uk = null,
    .dutch = &pages.dutch,
    .finnish = &pages.finnish,
    .french = &pages.french,
    .french_ca = &pages.french_ca,
    .german = &pages.german,
    .italian = &pages.italian,
    .norwegian = &pages.norwegian,
    .spanish = &pages.spanish,
    .swedish = &pages.swedish,
    .swiss = &pages.swiss,
    .iso_latin1 = &pages.iso_latin1,
    .dec_technical = &pages.dec_technical,
    .jis_roman = &pages.jis_roman,
    .jis_katakana = &pages.jis_katakana,
    .portuguese = &pages.portuguese,
    .greek_nrc = &pages.greek_nrc,
    .turkish_nrc = &pages.turkish_nrc,
    .hebrew_nrc = &pages.hebrew_nrc,
    .dec_hebrew = &pages.dec_hebrew,
    .dec_greek = &pages.dec_greek,
    .dec_turkish = &pages.dec_turkish,
    .dec_suppl_graphic = &pages.dec_suppl, // xterm draws `<` and `% 5` alike
    .dec_cyrillic = &pages.dec_cyrillic,
    .serbo_croatian = &pages.serbo_croatian,
    .dec_russian = &pages.dec_russian,
    .iso_latin2 = &pages.iso_latin2,
    .iso_greek = &pages.iso_greek,
    .iso_hebrew = &pages.iso_hebrew,
    .iso_cyrillic = &pages.iso_cyrillic,
    .iso_latin5 = &pages.iso_latin5,
});
