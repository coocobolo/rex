//! Tests for charset.zig: designations, translation through GL and GR,
//! and the pages generated from xterm's charsets.h.

const std = @import("std");

const charset = @import("charset.zig");
const Set = charset.Set;
const Mapping = charset.Mapping;

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
