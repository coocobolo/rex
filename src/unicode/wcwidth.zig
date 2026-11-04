//! Older width lookup, still used by term/screen.zig and
//! freetype/Rasterizer.zig until they move to wcwidth_v2.zig.

const std = @import("std");

pub const Range = struct {
    start: u32,
    end: u32,
};

const zero_width = [_]Range{
    .{ .start = 0x00300, .end = 0x0036f }, // Combining Grave Accent   .. Combining Latin Small Le
    .{ .start = 0x00483, .end = 0x00489 }, // Combining Cyrillic Titlo .. Combining Cyrillic Milli
    .{ .start = 0x00591, .end = 0x005bd }, // Hebrew Accent Etnahta    .. Hebrew Point Meteg
    .{ .start = 0x005bf, .end = 0x005bf }, // Hebrew Point Rafe        .. Hebrew Point Rafe
    .{ .start = 0x005c1, .end = 0x005c2 }, // Hebrew Point Shin Dot    .. Hebrew Point Sin Dot
    .{ .start = 0x005c4, .end = 0x005c5 }, // Hebrew Mark Upper Dot    .. Hebrew Mark Lower Dot
    .{ .start = 0x005c7, .end = 0x005c7 }, // Hebrew Point Qamats Qata .. Hebrew Point Qamats Qata
    .{ .start = 0x00610, .end = 0x0061a }, // Arabic Sign Sallallahou  .. Arabic Small Kasra
    .{ .start = 0x0064b, .end = 0x0065f }, // Arabic Fathatan          .. Arabic Wavy Hamza Below
    .{ .start = 0x00670, .end = 0x00670 }, // Arabic Letter Superscrip .. Arabic Letter Superscrip
    .{ .start = 0x006d6, .end = 0x006dc }, // Arabic Small High Ligatu .. Arabic Small High Seen
    .{ .start = 0x006df, .end = 0x006e4 }, // Arabic Small High Rounde .. Arabic Small High Madda
    .{ .start = 0x006e7, .end = 0x006e8 }, // Arabic Small High Yeh    .. Arabic Small High Noon
    .{ .start = 0x006ea, .end = 0x006ed }, // Arabic Empty Centre Low  .. Arabic Small Low Meem
    .{ .start = 0x00711, .end = 0x00711 }, // Syriac Letter Superscrip .. Syriac Letter Superscrip
    .{ .start = 0x00730, .end = 0x0074a }, // Syriac Pthaha Above      .. Syriac Barrekh
    .{ .start = 0x007a6, .end = 0x007b0 }, // Thaana Abafili           .. Thaana Sukun
    .{ .start = 0x007eb, .end = 0x007f3 }, // Nko Combining Short High .. Nko Combining Double Dot
    .{ .start = 0x007fd, .end = 0x007fd }, // Nko Dantayalan           .. Nko Dantayalan
    .{ .start = 0x00816, .end = 0x00819 }, // Samaritan Mark In        .. Samaritan Mark Dagesh
    .{ .start = 0x0081b, .end = 0x00823 }, // Samaritan Mark Epentheti .. Samaritan Vowel Sign A
    .{ .start = 0x00825, .end = 0x00827 }, // Samaritan Vowel Sign Sho .. Samaritan Vowel Sign U
    .{ .start = 0x00829, .end = 0x0082d }, // Samaritan Vowel Sign Lon .. Samaritan Mark Nequdaa
    .{ .start = 0x00859, .end = 0x0085b }, // Mandaic Affrication Mark .. Mandaic Gemination Mark
    .{ .start = 0x00898, .end = 0x0089f }, // Arabic Small High Word A .. Arabic Half Madda Over M
    .{ .start = 0x008ca, .end = 0x008e1 }, // Arabic Small High Farsi  .. Arabic Small High Sign S
    .{ .start = 0x008e3, .end = 0x00902 }, // Arabic Turned Damma Belo .. Devanagari Sign Anusvara
    .{ .start = 0x0093a, .end = 0x0093a }, // Devanagari Vowel Sign Oe .. Devanagari Vowel Sign Oe
    .{ .start = 0x0093c, .end = 0x0093c }, // Devanagari Sign Nukta    .. Devanagari Sign Nukta
    .{ .start = 0x00941, .end = 0x00948 }, // Devanagari Vowel Sign U  .. Devanagari Vowel Sign Ai
    .{ .start = 0x0094d, .end = 0x0094d }, // Devanagari Sign Virama   .. Devanagari Sign Virama
    .{ .start = 0x00951, .end = 0x00957 }, // Devanagari Stress Sign U .. Devanagari Vowel Sign Uu
    .{ .start = 0x00962, .end = 0x00963 }, // Devanagari Vowel Sign Vo .. Devanagari Vowel Sign Vo
    .{ .start = 0x00981, .end = 0x00981 }, // Bengali Sign Candrabindu .. Bengali Sign Candrabindu
    .{ .start = 0x009bc, .end = 0x009bc }, // Bengali Sign Nukta       .. Bengali Sign Nukta
    .{ .start = 0x009c1, .end = 0x009c4 }, // Bengali Vowel Sign U     .. Bengali Vowel Sign Vocal
    .{ .start = 0x009cd, .end = 0x009cd }, // Bengali Sign Virama      .. Bengali Sign Virama
    .{ .start = 0x009e2, .end = 0x009e3 }, // Bengali Vowel Sign Vocal .. Bengali Vowel Sign Vocal
    .{ .start = 0x009fe, .end = 0x009fe }, // Bengali Sandhi Mark      .. Bengali Sandhi Mark
    .{ .start = 0x00a01, .end = 0x00a02 }, // Gurmukhi Sign Adak Bindi .. Gurmukhi Sign Bindi
    .{ .start = 0x00a3c, .end = 0x00a3c }, // Gurmukhi Sign Nukta      .. Gurmukhi Sign Nukta
    .{ .start = 0x00a41, .end = 0x00a42 }, // Gurmukhi Vowel Sign U    .. Gurmukhi Vowel Sign Uu
    .{ .start = 0x00a47, .end = 0x00a48 }, // Gurmukhi Vowel Sign Ee   .. Gurmukhi Vowel Sign Ai
    .{ .start = 0x00a4b, .end = 0x00a4d }, // Gurmukhi Vowel Sign Oo   .. Gurmukhi Sign Virama
    .{ .start = 0x00a51, .end = 0x00a51 }, // Gurmukhi Sign Udaat      .. Gurmukhi Sign Udaat
    .{ .start = 0x00a70, .end = 0x00a71 }, // Gurmukhi Tippi           .. Gurmukhi Addak
    .{ .start = 0x00a75, .end = 0x00a75 }, // Gurmukhi Sign Yakash     .. Gurmukhi Sign Yakash
    .{ .start = 0x00a81, .end = 0x00a82 }, // Gujarati Sign Candrabind .. Gujarati Sign Anusvara
    .{ .start = 0x00abc, .end = 0x00abc }, // Gujarati Sign Nukta      .. Gujarati Sign Nukta
    .{ .start = 0x00ac1, .end = 0x00ac5 }, // Gujarati Vowel Sign U    .. Gujarati Vowel Sign Cand
    .{ .start = 0x00ac7, .end = 0x00ac8 }, // Gujarati Vowel Sign E    .. Gujarati Vowel Sign Ai
    .{ .start = 0x00acd, .end = 0x00acd }, // Gujarati Sign Virama     .. Gujarati Sign Virama
    .{ .start = 0x00ae2, .end = 0x00ae3 }, // Gujarati Vowel Sign Voca .. Gujarati Vowel Sign Voca
    .{ .start = 0x00afa, .end = 0x00aff }, // Gujarati Sign Sukun      .. Gujarati Sign Two-circle
    .{ .start = 0x00b01, .end = 0x00b01 }, // Oriya Sign Candrabindu   .. Oriya Sign Candrabindu
    .{ .start = 0x00b3c, .end = 0x00b3c }, // Oriya Sign Nukta         .. Oriya Sign Nukta
    .{ .start = 0x00b3f, .end = 0x00b3f }, // Oriya Vowel Sign I       .. Oriya Vowel Sign I
    .{ .start = 0x00b41, .end = 0x00b44 }, // Oriya Vowel Sign U       .. Oriya Vowel Sign Vocalic
    .{ .start = 0x00b4d, .end = 0x00b4d }, // Oriya Sign Virama        .. Oriya Sign Virama
    .{ .start = 0x00b55, .end = 0x00b56 }, // Oriya Sign Overline      .. Oriya Ai Length Mark
    .{ .start = 0x00b62, .end = 0x00b63 }, // Oriya Vowel Sign Vocalic .. Oriya Vowel Sign Vocalic
    .{ .start = 0x00b82, .end = 0x00b82 }, // Tamil Sign Anusvara      .. Tamil Sign Anusvara
    .{ .start = 0x00bc0, .end = 0x00bc0 }, // Tamil Vowel Sign Ii      .. Tamil Vowel Sign Ii
    .{ .start = 0x00bcd, .end = 0x00bcd }, // Tamil Sign Virama        .. Tamil Sign Virama
    .{ .start = 0x00c00, .end = 0x00c00 }, // Telugu Sign Combining Ca .. Telugu Sign Combining Ca
    .{ .start = 0x00c04, .end = 0x00c04 }, // Telugu Sign Combining An .. Telugu Sign Combining An
    .{ .start = 0x00c3c, .end = 0x00c3c }, // Telugu Sign Nukta        .. Telugu Sign Nukta
    .{ .start = 0x00c3e, .end = 0x00c40 }, // Telugu Vowel Sign Aa     .. Telugu Vowel Sign Ii
    .{ .start = 0x00c46, .end = 0x00c48 }, // Telugu Vowel Sign E      .. Telugu Vowel Sign Ai
    .{ .start = 0x00c4a, .end = 0x00c4d }, // Telugu Vowel Sign O      .. Telugu Sign Virama
    .{ .start = 0x00c55, .end = 0x00c56 }, // Telugu Length Mark       .. Telugu Ai Length Mark
    .{ .start = 0x00c62, .end = 0x00c63 }, // Telugu Vowel Sign Vocali .. Telugu Vowel Sign Vocali
    .{ .start = 0x00c81, .end = 0x00c81 }, // Kannada Sign Candrabindu .. Kannada Sign Candrabindu
    .{ .start = 0x00cbc, .end = 0x00cbc }, // Kannada Sign Nukta       .. Kannada Sign Nukta
    .{ .start = 0x00cbf, .end = 0x00cbf }, // Kannada Vowel Sign I     .. Kannada Vowel Sign I
    .{ .start = 0x00cc6, .end = 0x00cc6 }, // Kannada Vowel Sign E     .. Kannada Vowel Sign E
    .{ .start = 0x00ccc, .end = 0x00ccd }, // Kannada Vowel Sign Au    .. Kannada Sign Virama
    .{ .start = 0x00ce2, .end = 0x00ce3 }, // Kannada Vowel Sign Vocal .. Kannada Vowel Sign Vocal
    .{ .start = 0x00d00, .end = 0x00d01 }, // Malayalam Sign Combining .. Malayalam Sign Candrabin
    .{ .start = 0x00d3b, .end = 0x00d3c }, // Malayalam Sign Vertical  .. Malayalam Sign Circular
    .{ .start = 0x00d41, .end = 0x00d44 }, // Malayalam Vowel Sign U   .. Malayalam Vowel Sign Voc
    .{ .start = 0x00d4d, .end = 0x00d4d }, // Malayalam Sign Virama    .. Malayalam Sign Virama
    .{ .start = 0x00d62, .end = 0x00d63 }, // Malayalam Vowel Sign Voc .. Malayalam Vowel Sign Voc
    .{ .start = 0x00d81, .end = 0x00d81 }, // Sinhala Sign Candrabindu .. Sinhala Sign Candrabindu
    .{ .start = 0x00dca, .end = 0x00dca }, // Sinhala Sign Al-lakuna   .. Sinhala Sign Al-lakuna
    .{ .start = 0x00dd2, .end = 0x00dd4 }, // Sinhala Vowel Sign Ketti .. Sinhala Vowel Sign Ketti
    .{ .start = 0x00dd6, .end = 0x00dd6 }, // Sinhala Vowel Sign Diga  .. Sinhala Vowel Sign Diga
    .{ .start = 0x00e31, .end = 0x00e31 }, // Thai Character Mai Han-a .. Thai Character Mai Han-a
    .{ .start = 0x00e34, .end = 0x00e3a }, // Thai Character Sara I    .. Thai Character Phinthu
    .{ .start = 0x00e47, .end = 0x00e4e }, // Thai Character Maitaikhu .. Thai Character Yamakkan
    .{ .start = 0x00eb1, .end = 0x00eb1 }, // Lao Vowel Sign Mai Kan   .. Lao Vowel Sign Mai Kan
    .{ .start = 0x00eb4, .end = 0x00ebc }, // Lao Vowel Sign I         .. Lao Semivowel Sign Lo
    .{ .start = 0x00ec8, .end = 0x00ece }, // Lao Tone Mai Ek          .. (nil)
    .{ .start = 0x00f18, .end = 0x00f19 }, // Tibetan Astrological Sig .. Tibetan Astrological Sig
    .{ .start = 0x00f35, .end = 0x00f35 }, // Tibetan Mark Ngas Bzung  .. Tibetan Mark Ngas Bzung
    .{ .start = 0x00f37, .end = 0x00f37 }, // Tibetan Mark Ngas Bzung  .. Tibetan Mark Ngas Bzung
    .{ .start = 0x00f39, .end = 0x00f39 }, // Tibetan Mark Tsa -phru   .. Tibetan Mark Tsa -phru
    .{ .start = 0x00f71, .end = 0x00f7e }, // Tibetan Vowel Sign Aa    .. Tibetan Sign Rjes Su Nga
    .{ .start = 0x00f80, .end = 0x00f84 }, // Tibetan Vowel Sign Rever .. Tibetan Mark Halanta
    .{ .start = 0x00f86, .end = 0x00f87 }, // Tibetan Sign Lci Rtags   .. Tibetan Sign Yang Rtags
    .{ .start = 0x00f8d, .end = 0x00f97 }, // Tibetan Subjoined Sign L .. Tibetan Subjoined Letter
    .{ .start = 0x00f99, .end = 0x00fbc }, // Tibetan Subjoined Letter .. Tibetan Subjoined Letter
    .{ .start = 0x00fc6, .end = 0x00fc6 }, // Tibetan Symbol Padma Gda .. Tibetan Symbol Padma Gda
    .{ .start = 0x0102d, .end = 0x01030 }, // Myanmar Vowel Sign I     .. Myanmar Vowel Sign Uu
    .{ .start = 0x01032, .end = 0x01037 }, // Myanmar Vowel Sign Ai    .. Myanmar Sign Dot Below
    .{ .start = 0x01039, .end = 0x0103a }, // Myanmar Sign Virama      .. Myanmar Sign Asat
    .{ .start = 0x0103d, .end = 0x0103e }, // Myanmar Consonant Sign M .. Myanmar Consonant Sign M
    .{ .start = 0x01058, .end = 0x01059 }, // Myanmar Vowel Sign Vocal .. Myanmar Vowel Sign Vocal
    .{ .start = 0x0105e, .end = 0x01060 }, // Myanmar Consonant Sign M .. Myanmar Consonant Sign M
    .{ .start = 0x01071, .end = 0x01074 }, // Myanmar Vowel Sign Geba  .. Myanmar Vowel Sign Kayah
    .{ .start = 0x01082, .end = 0x01082 }, // Myanmar Consonant Sign S .. Myanmar Consonant Sign S
    .{ .start = 0x01085, .end = 0x01086 }, // Myanmar Vowel Sign Shan  .. Myanmar Vowel Sign Shan
    .{ .start = 0x0108d, .end = 0x0108d }, // Myanmar Sign Shan Counci .. Myanmar Sign Shan Counci
    .{ .start = 0x0109d, .end = 0x0109d }, // Myanmar Vowel Sign Aiton .. Myanmar Vowel Sign Aiton
    .{ .start = 0x0135d, .end = 0x0135f }, // Ethiopic Combining Gemin .. Ethiopic Combining Gemin
    .{ .start = 0x01712, .end = 0x01714 }, // Tagalog Vowel Sign I     .. Tagalog Sign Virama
    .{ .start = 0x01732, .end = 0x01733 }, // Hanunoo Vowel Sign I     .. Hanunoo Vowel Sign U
    .{ .start = 0x01752, .end = 0x01753 }, // Buhid Vowel Sign I       .. Buhid Vowel Sign U
    .{ .start = 0x01772, .end = 0x01773 }, // Tagbanwa Vowel Sign I    .. Tagbanwa Vowel Sign U
    .{ .start = 0x017b4, .end = 0x017b5 }, // Khmer Vowel Inherent Aq  .. Khmer Vowel Inherent Aa
    .{ .start = 0x017b7, .end = 0x017bd }, // Khmer Vowel Sign I       .. Khmer Vowel Sign Ua
    .{ .start = 0x017c6, .end = 0x017c6 }, // Khmer Sign Nikahit       .. Khmer Sign Nikahit
    .{ .start = 0x017c9, .end = 0x017d3 }, // Khmer Sign Muusikatoan   .. Khmer Sign Bathamasat
    .{ .start = 0x017dd, .end = 0x017dd }, // Khmer Sign Atthacan      .. Khmer Sign Atthacan
    .{ .start = 0x0180b, .end = 0x0180d }, // Mongolian Free Variation .. Mongolian Free Variation
    .{ .start = 0x0180f, .end = 0x0180f }, // Mongolian Free Variation .. Mongolian Free Variation
    .{ .start = 0x01885, .end = 0x01886 }, // Mongolian Letter Ali Gal .. Mongolian Letter Ali Gal
    .{ .start = 0x018a9, .end = 0x018a9 }, // Mongolian Letter Ali Gal .. Mongolian Letter Ali Gal
    .{ .start = 0x01920, .end = 0x01922 }, // Limbu Vowel Sign A       .. Limbu Vowel Sign U
    .{ .start = 0x01927, .end = 0x01928 }, // Limbu Vowel Sign E       .. Limbu Vowel Sign O
    .{ .start = 0x01932, .end = 0x01932 }, // Limbu Small Letter Anusv .. Limbu Small Letter Anusv
    .{ .start = 0x01939, .end = 0x0193b }, // Limbu Sign Mukphreng     .. Limbu Sign Sa-i
    .{ .start = 0x01a17, .end = 0x01a18 }, // Buginese Vowel Sign I    .. Buginese Vowel Sign U
    .{ .start = 0x01a1b, .end = 0x01a1b }, // Buginese Vowel Sign Ae   .. Buginese Vowel Sign Ae
    .{ .start = 0x01a56, .end = 0x01a56 }, // Tai Tham Consonant Sign  .. Tai Tham Consonant Sign
    .{ .start = 0x01a58, .end = 0x01a5e }, // Tai Tham Sign Mai Kang L .. Tai Tham Consonant Sign
    .{ .start = 0x01a60, .end = 0x01a60 }, // Tai Tham Sign Sakot      .. Tai Tham Sign Sakot
    .{ .start = 0x01a62, .end = 0x01a62 }, // Tai Tham Vowel Sign Mai  .. Tai Tham Vowel Sign Mai
    .{ .start = 0x01a65, .end = 0x01a6c }, // Tai Tham Vowel Sign I    .. Tai Tham Vowel Sign Oa B
    .{ .start = 0x01a73, .end = 0x01a7c }, // Tai Tham Vowel Sign Oa A .. Tai Tham Sign Khuen-lue
    .{ .start = 0x01a7f, .end = 0x01a7f }, // Tai Tham Combining Crypt .. Tai Tham Combining Crypt
    .{ .start = 0x01ab0, .end = 0x01ace }, // Combining Doubled Circum .. Combining Latin Small Le
    .{ .start = 0x01b00, .end = 0x01b03 }, // Balinese Sign Ulu Ricem  .. Balinese Sign Surang
    .{ .start = 0x01b34, .end = 0x01b34 }, // Balinese Sign Rerekan    .. Balinese Sign Rerekan
    .{ .start = 0x01b36, .end = 0x01b3a }, // Balinese Vowel Sign Ulu  .. Balinese Vowel Sign Ra R
    .{ .start = 0x01b3c, .end = 0x01b3c }, // Balinese Vowel Sign La L .. Balinese Vowel Sign La L
    .{ .start = 0x01b42, .end = 0x01b42 }, // Balinese Vowel Sign Pepe .. Balinese Vowel Sign Pepe
    .{ .start = 0x01b6b, .end = 0x01b73 }, // Balinese Musical Symbol  .. Balinese Musical Symbol
    .{ .start = 0x01b80, .end = 0x01b81 }, // Sundanese Sign Panyecek  .. Sundanese Sign Panglayar
    .{ .start = 0x01ba2, .end = 0x01ba5 }, // Sundanese Consonant Sign .. Sundanese Vowel Sign Pan
    .{ .start = 0x01ba8, .end = 0x01ba9 }, // Sundanese Vowel Sign Pam .. Sundanese Vowel Sign Pan
    .{ .start = 0x01bab, .end = 0x01bad }, // Sundanese Sign Virama    .. Sundanese Consonant Sign
    .{ .start = 0x01be6, .end = 0x01be6 }, // Batak Sign Tompi         .. Batak Sign Tompi
    .{ .start = 0x01be8, .end = 0x01be9 }, // Batak Vowel Sign Pakpak  .. Batak Vowel Sign Ee
    .{ .start = 0x01bed, .end = 0x01bed }, // Batak Vowel Sign Karo O  .. Batak Vowel Sign Karo O
    .{ .start = 0x01bef, .end = 0x01bf1 }, // Batak Vowel Sign U For S .. Batak Consonant Sign H
    .{ .start = 0x01c2c, .end = 0x01c33 }, // Lepcha Vowel Sign E      .. Lepcha Consonant Sign T
    .{ .start = 0x01c36, .end = 0x01c37 }, // Lepcha Sign Ran          .. Lepcha Sign Nukta
    .{ .start = 0x01cd0, .end = 0x01cd2 }, // Vedic Tone Karshana      .. Vedic Tone Prenkha
    .{ .start = 0x01cd4, .end = 0x01ce0 }, // Vedic Sign Yajurvedic Mi .. Vedic Tone Rigvedic Kash
    .{ .start = 0x01ce2, .end = 0x01ce8 }, // Vedic Sign Visarga Svari .. Vedic Sign Visarga Anuda
    .{ .start = 0x01ced, .end = 0x01ced }, // Vedic Sign Tiryak        .. Vedic Sign Tiryak
    .{ .start = 0x01cf4, .end = 0x01cf4 }, // Vedic Tone Candra Above  .. Vedic Tone Candra Above
    .{ .start = 0x01cf8, .end = 0x01cf9 }, // Vedic Tone Ring Above    .. Vedic Tone Double Ring A
    .{ .start = 0x01dc0, .end = 0x01dff }, // Combining Dotted Grave A .. Combining Right Arrowhea
    .{ .start = 0x020d0, .end = 0x020f0 }, // Combining Left Harpoon A .. Combining Asterisk Above
    .{ .start = 0x02cef, .end = 0x02cf1 }, // Coptic Combining Ni Abov .. Coptic Combining Spiritu
    .{ .start = 0x02d7f, .end = 0x02d7f }, // Tifinagh Consonant Joine .. Tifinagh Consonant Joine
    .{ .start = 0x02de0, .end = 0x02dff }, // Combining Cyrillic Lette .. Combining Cyrillic Lette
    .{ .start = 0x0302a, .end = 0x0302d }, // Ideographic Level Tone M .. Ideographic Entering Ton
    .{ .start = 0x03099, .end = 0x0309a }, // Combining Katakana-hirag .. Combining Katakana-hirag
    .{ .start = 0x0a66f, .end = 0x0a672 }, // Combining Cyrillic Vzmet .. Combining Cyrillic Thous
    .{ .start = 0x0a674, .end = 0x0a67d }, // Combining Cyrillic Lette .. Combining Cyrillic Payer
    .{ .start = 0x0a69e, .end = 0x0a69f }, // Combining Cyrillic Lette .. Combining Cyrillic Lette
    .{ .start = 0x0a6f0, .end = 0x0a6f1 }, // Bamum Combining Mark Koq .. Bamum Combining Mark Tuk
    .{ .start = 0x0a802, .end = 0x0a802 }, // Syloti Nagri Sign Dvisva .. Syloti Nagri Sign Dvisva
    .{ .start = 0x0a806, .end = 0x0a806 }, // Syloti Nagri Sign Hasant .. Syloti Nagri Sign Hasant
    .{ .start = 0x0a80b, .end = 0x0a80b }, // Syloti Nagri Sign Anusva .. Syloti Nagri Sign Anusva
    .{ .start = 0x0a825, .end = 0x0a826 }, // Syloti Nagri Vowel Sign  .. Syloti Nagri Vowel Sign
    .{ .start = 0x0a82c, .end = 0x0a82c }, // Syloti Nagri Sign Altern .. Syloti Nagri Sign Altern
    .{ .start = 0x0a8c4, .end = 0x0a8c5 }, // Saurashtra Sign Virama   .. Saurashtra Sign Candrabi
    .{ .start = 0x0a8e0, .end = 0x0a8f1 }, // Combining Devanagari Dig .. Combining Devanagari Sig
    .{ .start = 0x0a8ff, .end = 0x0a8ff }, // Devanagari Vowel Sign Ay .. Devanagari Vowel Sign Ay
    .{ .start = 0x0a926, .end = 0x0a92d }, // Kayah Li Vowel Ue        .. Kayah Li Tone Calya Plop
    .{ .start = 0x0a947, .end = 0x0a951 }, // Rejang Vowel Sign I      .. Rejang Consonant Sign R
    .{ .start = 0x0a980, .end = 0x0a982 }, // Javanese Sign Panyangga  .. Javanese Sign Layar
    .{ .start = 0x0a9b3, .end = 0x0a9b3 }, // Javanese Sign Cecak Telu .. Javanese Sign Cecak Telu
    .{ .start = 0x0a9b6, .end = 0x0a9b9 }, // Javanese Vowel Sign Wulu .. Javanese Vowel Sign Suku
    .{ .start = 0x0a9bc, .end = 0x0a9bd }, // Javanese Vowel Sign Pepe .. Javanese Consonant Sign
    .{ .start = 0x0a9e5, .end = 0x0a9e5 }, // Myanmar Sign Shan Saw    .. Myanmar Sign Shan Saw
    .{ .start = 0x0aa29, .end = 0x0aa2e }, // Cham Vowel Sign Aa       .. Cham Vowel Sign Oe
    .{ .start = 0x0aa31, .end = 0x0aa32 }, // Cham Vowel Sign Au       .. Cham Vowel Sign Ue
    .{ .start = 0x0aa35, .end = 0x0aa36 }, // Cham Consonant Sign La   .. Cham Consonant Sign Wa
    .{ .start = 0x0aa43, .end = 0x0aa43 }, // Cham Consonant Sign Fina .. Cham Consonant Sign Fina
    .{ .start = 0x0aa4c, .end = 0x0aa4c }, // Cham Consonant Sign Fina .. Cham Consonant Sign Fina
    .{ .start = 0x0aa7c, .end = 0x0aa7c }, // Myanmar Sign Tai Laing T .. Myanmar Sign Tai Laing T
    .{ .start = 0x0aab0, .end = 0x0aab0 }, // Tai Viet Mai Kang        .. Tai Viet Mai Kang
    .{ .start = 0x0aab2, .end = 0x0aab4 }, // Tai Viet Vowel I         .. Tai Viet Vowel U
    .{ .start = 0x0aab7, .end = 0x0aab8 }, // Tai Viet Mai Khit        .. Tai Viet Vowel Ia
    .{ .start = 0x0aabe, .end = 0x0aabf }, // Tai Viet Vowel Am        .. Tai Viet Tone Mai Ek
    .{ .start = 0x0aac1, .end = 0x0aac1 }, // Tai Viet Tone Mai Tho    .. Tai Viet Tone Mai Tho
    .{ .start = 0x0aaec, .end = 0x0aaed }, // Meetei Mayek Vowel Sign  .. Meetei Mayek Vowel Sign
    .{ .start = 0x0aaf6, .end = 0x0aaf6 }, // Meetei Mayek Virama      .. Meetei Mayek Virama
    .{ .start = 0x0abe5, .end = 0x0abe5 }, // Meetei Mayek Vowel Sign  .. Meetei Mayek Vowel Sign
    .{ .start = 0x0abe8, .end = 0x0abe8 }, // Meetei Mayek Vowel Sign  .. Meetei Mayek Vowel Sign
    .{ .start = 0x0abed, .end = 0x0abed }, // Meetei Mayek Apun Iyek   .. Meetei Mayek Apun Iyek
    .{ .start = 0x0fb1e, .end = 0x0fb1e }, // Hebrew Point Judeo-spani .. Hebrew Point Judeo-spani
    .{ .start = 0x0fe00, .end = 0x0fe0f }, // Variation Selector-1     .. Variation Selector-16
    .{ .start = 0x0fe20, .end = 0x0fe2f }, // Combining Ligature Left  .. Combining Cyrillic Titlo
    .{ .start = 0x101fd, .end = 0x101fd }, // Phaistos Disc Sign Combi .. Phaistos Disc Sign Combi
    .{ .start = 0x102e0, .end = 0x102e0 }, // Coptic Epact Thousands M .. Coptic Epact Thousands M
    .{ .start = 0x10376, .end = 0x1037a }, // Combining Old Permic Let .. Combining Old Permic Let
    .{ .start = 0x10a01, .end = 0x10a03 }, // Kharoshthi Vowel Sign I  .. Kharoshthi Vowel Sign Vo
    .{ .start = 0x10a05, .end = 0x10a06 }, // Kharoshthi Vowel Sign E  .. Kharoshthi Vowel Sign O
    .{ .start = 0x10a0c, .end = 0x10a0f }, // Kharoshthi Vowel Length  .. Kharoshthi Sign Visarga
    .{ .start = 0x10a38, .end = 0x10a3a }, // Kharoshthi Sign Bar Abov .. Kharoshthi Sign Dot Belo
    .{ .start = 0x10a3f, .end = 0x10a3f }, // Kharoshthi Virama        .. Kharoshthi Virama
    .{ .start = 0x10ae5, .end = 0x10ae6 }, // Manichaean Abbreviation  .. Manichaean Abbreviation
    .{ .start = 0x10d24, .end = 0x10d27 }, // Hanifi Rohingya Sign Har .. Hanifi Rohingya Sign Tas
    .{ .start = 0x10eab, .end = 0x10eac }, // Yezidi Combining Hamza M .. Yezidi Combining Madda M
    .{ .start = 0x10efd, .end = 0x10eff }, // (nil)                    .. (nil)
    .{ .start = 0x10f46, .end = 0x10f50 }, // Sogdian Combining Dot Be .. Sogdian Combining Stroke
    .{ .start = 0x10f82, .end = 0x10f85 }, // Old Uyghur Combining Dot .. Old Uyghur Combining Two
    .{ .start = 0x11001, .end = 0x11001 }, // Brahmi Sign Anusvara     .. Brahmi Sign Anusvara
    .{ .start = 0x11038, .end = 0x11046 }, // Brahmi Vowel Sign Aa     .. Brahmi Virama
    .{ .start = 0x11070, .end = 0x11070 }, // Brahmi Sign Old Tamil Vi .. Brahmi Sign Old Tamil Vi
    .{ .start = 0x11073, .end = 0x11074 }, // Brahmi Vowel Sign Old Ta .. Brahmi Vowel Sign Old Ta
    .{ .start = 0x1107f, .end = 0x11081 }, // Brahmi Number Joiner     .. Kaithi Sign Anusvara
    .{ .start = 0x110b3, .end = 0x110b6 }, // Kaithi Vowel Sign U      .. Kaithi Vowel Sign Ai
    .{ .start = 0x110b9, .end = 0x110ba }, // Kaithi Sign Virama       .. Kaithi Sign Nukta
    .{ .start = 0x110c2, .end = 0x110c2 }, // Kaithi Vowel Sign Vocali .. Kaithi Vowel Sign Vocali
    .{ .start = 0x11100, .end = 0x11102 }, // Chakma Sign Candrabindu  .. Chakma Sign Visarga
    .{ .start = 0x11127, .end = 0x1112b }, // Chakma Vowel Sign A      .. Chakma Vowel Sign Uu
    .{ .start = 0x1112d, .end = 0x11134 }, // Chakma Vowel Sign Ai     .. Chakma Maayyaa
    .{ .start = 0x11173, .end = 0x11173 }, // Mahajani Sign Nukta      .. Mahajani Sign Nukta
    .{ .start = 0x11180, .end = 0x11181 }, // Sharada Sign Candrabindu .. Sharada Sign Anusvara
    .{ .start = 0x111b6, .end = 0x111be }, // Sharada Vowel Sign U     .. Sharada Vowel Sign O
    .{ .start = 0x111c9, .end = 0x111cc }, // Sharada Sandhi Mark      .. Sharada Extra Short Vowe
    .{ .start = 0x111cf, .end = 0x111cf }, // Sharada Sign Inverted Ca .. Sharada Sign Inverted Ca
    .{ .start = 0x1122f, .end = 0x11231 }, // Khojki Vowel Sign U      .. Khojki Vowel Sign Ai
    .{ .start = 0x11234, .end = 0x11234 }, // Khojki Sign Anusvara     .. Khojki Sign Anusvara
    .{ .start = 0x11236, .end = 0x11237 }, // Khojki Sign Nukta        .. Khojki Sign Shadda
    .{ .start = 0x1123e, .end = 0x1123e }, // Khojki Sign Sukun        .. Khojki Sign Sukun
    .{ .start = 0x11241, .end = 0x11241 }, // (nil)                    .. (nil)
    .{ .start = 0x112df, .end = 0x112df }, // Khudawadi Sign Anusvara  .. Khudawadi Sign Anusvara
    .{ .start = 0x112e3, .end = 0x112ea }, // Khudawadi Vowel Sign U   .. Khudawadi Sign Virama
    .{ .start = 0x11300, .end = 0x11301 }, // Grantha Sign Combining A .. Grantha Sign Candrabindu
    .{ .start = 0x1133b, .end = 0x1133c }, // Combining Bindu Below    .. Grantha Sign Nukta
    .{ .start = 0x11340, .end = 0x11340 }, // Grantha Vowel Sign Ii    .. Grantha Vowel Sign Ii
    .{ .start = 0x11366, .end = 0x1136c }, // Combining Grantha Digit  .. Combining Grantha Digit
    .{ .start = 0x11370, .end = 0x11374 }, // Combining Grantha Letter .. Combining Grantha Letter
    .{ .start = 0x11438, .end = 0x1143f }, // Newa Vowel Sign U        .. Newa Vowel Sign Ai
    .{ .start = 0x11442, .end = 0x11444 }, // Newa Sign Virama         .. Newa Sign Anusvara
    .{ .start = 0x11446, .end = 0x11446 }, // Newa Sign Nukta          .. Newa Sign Nukta
    .{ .start = 0x1145e, .end = 0x1145e }, // Newa Sandhi Mark         .. Newa Sandhi Mark
    .{ .start = 0x114b3, .end = 0x114b8 }, // Tirhuta Vowel Sign U     .. Tirhuta Vowel Sign Vocal
    .{ .start = 0x114ba, .end = 0x114ba }, // Tirhuta Vowel Sign Short .. Tirhuta Vowel Sign Short
    .{ .start = 0x114bf, .end = 0x114c0 }, // Tirhuta Sign Candrabindu .. Tirhuta Sign Anusvara
    .{ .start = 0x114c2, .end = 0x114c3 }, // Tirhuta Sign Virama      .. Tirhuta Sign Nukta
    .{ .start = 0x115b2, .end = 0x115b5 }, // Siddham Vowel Sign U     .. Siddham Vowel Sign Vocal
    .{ .start = 0x115bc, .end = 0x115bd }, // Siddham Sign Candrabindu .. Siddham Sign Anusvara
    .{ .start = 0x115bf, .end = 0x115c0 }, // Siddham Sign Virama      .. Siddham Sign Nukta
    .{ .start = 0x115dc, .end = 0x115dd }, // Siddham Vowel Sign Alter .. Siddham Vowel Sign Alter
    .{ .start = 0x11633, .end = 0x1163a }, // Modi Vowel Sign U        .. Modi Vowel Sign Ai
    .{ .start = 0x1163d, .end = 0x1163d }, // Modi Sign Anusvara       .. Modi Sign Anusvara
    .{ .start = 0x1163f, .end = 0x11640 }, // Modi Sign Virama         .. Modi Sign Ardhacandra
    .{ .start = 0x116ab, .end = 0x116ab }, // Takri Sign Anusvara      .. Takri Sign Anusvara
    .{ .start = 0x116ad, .end = 0x116ad }, // Takri Vowel Sign Aa      .. Takri Vowel Sign Aa
    .{ .start = 0x116b0, .end = 0x116b5 }, // Takri Vowel Sign U       .. Takri Vowel Sign Au
    .{ .start = 0x116b7, .end = 0x116b7 }, // Takri Sign Nukta         .. Takri Sign Nukta
    .{ .start = 0x1171d, .end = 0x1171f }, // Ahom Consonant Sign Medi .. Ahom Consonant Sign Medi
    .{ .start = 0x11722, .end = 0x11725 }, // Ahom Vowel Sign I        .. Ahom Vowel Sign Uu
    .{ .start = 0x11727, .end = 0x1172b }, // Ahom Vowel Sign Aw       .. Ahom Sign Killer
    .{ .start = 0x1182f, .end = 0x11837 }, // Dogra Vowel Sign U       .. Dogra Sign Anusvara
    .{ .start = 0x11839, .end = 0x1183a }, // Dogra Sign Virama        .. Dogra Sign Nukta
    .{ .start = 0x1193b, .end = 0x1193c }, // Dives Akuru Sign Anusvar .. Dives Akuru Sign Candrab
    .{ .start = 0x1193e, .end = 0x1193e }, // Dives Akuru Virama       .. Dives Akuru Virama
    .{ .start = 0x11943, .end = 0x11943 }, // Dives Akuru Sign Nukta   .. Dives Akuru Sign Nukta
    .{ .start = 0x119d4, .end = 0x119d7 }, // Nandinagari Vowel Sign U .. Nandinagari Vowel Sign V
    .{ .start = 0x119da, .end = 0x119db }, // Nandinagari Vowel Sign E .. Nandinagari Vowel Sign A
    .{ .start = 0x119e0, .end = 0x119e0 }, // Nandinagari Sign Virama  .. Nandinagari Sign Virama
    .{ .start = 0x11a01, .end = 0x11a0a }, // Zanabazar Square Vowel S .. Zanabazar Square Vowel L
    .{ .start = 0x11a33, .end = 0x11a38 }, // Zanabazar Square Final C .. Zanabazar Square Sign An
    .{ .start = 0x11a3b, .end = 0x11a3e }, // Zanabazar Square Cluster .. Zanabazar Square Cluster
    .{ .start = 0x11a47, .end = 0x11a47 }, // Zanabazar Square Subjoin .. Zanabazar Square Subjoin
    .{ .start = 0x11a51, .end = 0x11a56 }, // Soyombo Vowel Sign I     .. Soyombo Vowel Sign Oe
    .{ .start = 0x11a59, .end = 0x11a5b }, // Soyombo Vowel Sign Vocal .. Soyombo Vowel Length Mar
    .{ .start = 0x11a8a, .end = 0x11a96 }, // Soyombo Final Consonant  .. Soyombo Sign Anusvara
    .{ .start = 0x11a98, .end = 0x11a99 }, // Soyombo Gemination Mark  .. Soyombo Subjoiner
    .{ .start = 0x11c30, .end = 0x11c36 }, // Bhaiksuki Vowel Sign I   .. Bhaiksuki Vowel Sign Voc
    .{ .start = 0x11c38, .end = 0x11c3d }, // Bhaiksuki Vowel Sign E   .. Bhaiksuki Sign Anusvara
    .{ .start = 0x11c3f, .end = 0x11c3f }, // Bhaiksuki Sign Virama    .. Bhaiksuki Sign Virama
    .{ .start = 0x11c92, .end = 0x11ca7 }, // Marchen Subjoined Letter .. Marchen Subjoined Letter
    .{ .start = 0x11caa, .end = 0x11cb0 }, // Marchen Subjoined Letter .. Marchen Vowel Sign Aa
    .{ .start = 0x11cb2, .end = 0x11cb3 }, // Marchen Vowel Sign U     .. Marchen Vowel Sign E
    .{ .start = 0x11cb5, .end = 0x11cb6 }, // Marchen Sign Anusvara    .. Marchen Sign Candrabindu
    .{ .start = 0x11d31, .end = 0x11d36 }, // Masaram Gondi Vowel Sign .. Masaram Gondi Vowel Sign
    .{ .start = 0x11d3a, .end = 0x11d3a }, // Masaram Gondi Vowel Sign .. Masaram Gondi Vowel Sign
    .{ .start = 0x11d3c, .end = 0x11d3d }, // Masaram Gondi Vowel Sign .. Masaram Gondi Vowel Sign
    .{ .start = 0x11d3f, .end = 0x11d45 }, // Masaram Gondi Vowel Sign .. Masaram Gondi Virama
    .{ .start = 0x11d47, .end = 0x11d47 }, // Masaram Gondi Ra-kara    .. Masaram Gondi Ra-kara
    .{ .start = 0x11d90, .end = 0x11d91 }, // Gunjala Gondi Vowel Sign .. Gunjala Gondi Vowel Sign
    .{ .start = 0x11d95, .end = 0x11d95 }, // Gunjala Gondi Sign Anusv .. Gunjala Gondi Sign Anusv
    .{ .start = 0x11d97, .end = 0x11d97 }, // Gunjala Gondi Virama     .. Gunjala Gondi Virama
    .{ .start = 0x11ef3, .end = 0x11ef4 }, // Makasar Vowel Sign I     .. Makasar Vowel Sign U
    .{ .start = 0x11f00, .end = 0x11f01 }, // (nil)                    .. (nil)
    .{ .start = 0x11f36, .end = 0x11f3a }, // (nil)                    .. (nil)
    .{ .start = 0x11f40, .end = 0x11f40 }, // (nil)                    .. (nil)
    .{ .start = 0x11f42, .end = 0x11f42 }, // (nil)                    .. (nil)
    .{ .start = 0x13440, .end = 0x13440 }, // (nil)                    .. (nil)
    .{ .start = 0x13447, .end = 0x13455 }, // (nil)                    .. (nil)
    .{ .start = 0x16af0, .end = 0x16af4 }, // Bassa Vah Combining High .. Bassa Vah Combining High
    .{ .start = 0x16b30, .end = 0x16b36 }, // Pahawh Hmong Mark Cim Tu .. Pahawh Hmong Mark Cim Ta
    .{ .start = 0x16f4f, .end = 0x16f4f }, // Miao Sign Consonant Modi .. Miao Sign Consonant Modi
    .{ .start = 0x16f8f, .end = 0x16f92 }, // Miao Tone Right          .. Miao Tone Below
    .{ .start = 0x16fe4, .end = 0x16fe4 }, // Khitan Small Script Fill .. Khitan Small Script Fill
    .{ .start = 0x1bc9d, .end = 0x1bc9e }, // Duployan Thick Letter Se .. Duployan Double Mark
    .{ .start = 0x1cf00, .end = 0x1cf2d }, // Znamenny Combining Mark  .. Znamenny Combining Mark
    .{ .start = 0x1cf30, .end = 0x1cf46 }, // Znamenny Combining Tonal .. Znamenny Priznak Modifie
    .{ .start = 0x1d167, .end = 0x1d169 }, // Musical Symbol Combining .. Musical Symbol Combining
    .{ .start = 0x1d17b, .end = 0x1d182 }, // Musical Symbol Combining .. Musical Symbol Combining
    .{ .start = 0x1d185, .end = 0x1d18b }, // Musical Symbol Combining .. Musical Symbol Combining
    .{ .start = 0x1d1aa, .end = 0x1d1ad }, // Musical Symbol Combining .. Musical Symbol Combining
    .{ .start = 0x1d242, .end = 0x1d244 }, // Combining Greek Musical  .. Combining Greek Musical
    .{ .start = 0x1da00, .end = 0x1da36 }, // Signwriting Head Rim     .. Signwriting Air Sucking
    .{ .start = 0x1da3b, .end = 0x1da6c }, // Signwriting Mouth Closed .. Signwriting Excitement
    .{ .start = 0x1da75, .end = 0x1da75 }, // Signwriting Upper Body T .. Signwriting Upper Body T
    .{ .start = 0x1da84, .end = 0x1da84 }, // Signwriting Location Hea .. Signwriting Location Hea
    .{ .start = 0x1da9b, .end = 0x1da9f }, // Signwriting Fill Modifie .. Signwriting Fill Modifie
    .{ .start = 0x1daa1, .end = 0x1daaf }, // Signwriting Rotation Mod .. Signwriting Rotation Mod
    .{ .start = 0x1e000, .end = 0x1e006 }, // Combining Glagolitic Let .. Combining Glagolitic Let
    .{ .start = 0x1e008, .end = 0x1e018 }, // Combining Glagolitic Let .. Combining Glagolitic Let
    .{ .start = 0x1e01b, .end = 0x1e021 }, // Combining Glagolitic Let .. Combining Glagolitic Let
    .{ .start = 0x1e023, .end = 0x1e024 }, // Combining Glagolitic Let .. Combining Glagolitic Let
    .{ .start = 0x1e026, .end = 0x1e02a }, // Combining Glagolitic Let .. Combining Glagolitic Let
    .{ .start = 0x1e08f, .end = 0x1e08f }, // (nil)                    .. (nil)
    .{ .start = 0x1e130, .end = 0x1e136 }, // Nyiakeng Puachue Hmong T .. Nyiakeng Puachue Hmong T
    .{ .start = 0x1e2ae, .end = 0x1e2ae }, // Toto Sign Rising Tone    .. Toto Sign Rising Tone
    .{ .start = 0x1e2ec, .end = 0x1e2ef }, // Wancho Tone Tup          .. Wancho Tone Koini
    .{ .start = 0x1e4ec, .end = 0x1e4ef }, // (nil)                    .. (nil)
    .{ .start = 0x1e8d0, .end = 0x1e8d6 }, // Mende Kikakui Combining  .. Mende Kikakui Combining
    .{ .start = 0x1e944, .end = 0x1e94a }, // Adlam Alif Lengthener    .. Adlam Nukta
    .{ .start = 0xe0100, .end = 0xe01ef }, // Variation Selector-17    .. Variation Selector-256
};

const wide_eastasian = [_]Range{
    .{ .start = 0x01100, .end = 0x0115f }, // Hangul Choseong Kiyeok   .. Hangul Choseong Filler
    .{ .start = 0x0231a, .end = 0x0231b }, // Watch                    .. Hourglass
    .{ .start = 0x02329, .end = 0x0232a }, // Left-pointing Angle Brac .. Right-pointing Angle Bra
    .{ .start = 0x023e9, .end = 0x023ec }, // Black Right-pointing Dou .. Black Down-pointing Doub
    .{ .start = 0x023f0, .end = 0x023f0 }, // Alarm Clock              .. Alarm Clock
    .{ .start = 0x023f3, .end = 0x023f3 }, // Hourglass With Flowing S .. Hourglass With Flowing S
    .{ .start = 0x025fd, .end = 0x025fe }, // White Medium Small Squar .. Black Medium Small Squar
    .{ .start = 0x02614, .end = 0x02615 }, // Umbrella With Rain Drops .. Hot Beverage
    .{ .start = 0x02648, .end = 0x02653 }, // Aries                    .. Pisces
    .{ .start = 0x0267f, .end = 0x0267f }, // Wheelchair Symbol        .. Wheelchair Symbol
    .{ .start = 0x02693, .end = 0x02693 }, // Anchor                   .. Anchor
    .{ .start = 0x026a1, .end = 0x026a1 }, // High Voltage Sign        .. High Voltage Sign
    .{ .start = 0x026aa, .end = 0x026ab }, // Medium White Circle      .. Medium Black Circle
    .{ .start = 0x026bd, .end = 0x026be }, // Soccer Ball              .. Baseball
    .{ .start = 0x026c4, .end = 0x026c5 }, // Snowman Without Snow     .. Sun Behind Cloud
    .{ .start = 0x026ce, .end = 0x026ce }, // Ophiuchus                .. Ophiuchus
    .{ .start = 0x026d4, .end = 0x026d4 }, // No Entry                 .. No Entry
    .{ .start = 0x026ea, .end = 0x026ea }, // Church                   .. Church
    .{ .start = 0x026f2, .end = 0x026f3 }, // Fountain                 .. Flag In Hole
    .{ .start = 0x026f5, .end = 0x026f5 }, // Sailboat                 .. Sailboat
    .{ .start = 0x026fa, .end = 0x026fa }, // Tent                     .. Tent
    .{ .start = 0x026fd, .end = 0x026fd }, // Fuel Pump                .. Fuel Pump
    .{ .start = 0x02705, .end = 0x02705 }, // White Heavy Check Mark   .. White Heavy Check Mark
    .{ .start = 0x0270a, .end = 0x0270b }, // Raised Fist              .. Raised Hand
    .{ .start = 0x02728, .end = 0x02728 }, // Sparkles                 .. Sparkles
    .{ .start = 0x0274c, .end = 0x0274c }, // Cross Mark               .. Cross Mark
    .{ .start = 0x0274e, .end = 0x0274e }, // Negative Squared Cross M .. Negative Squared Cross M
    .{ .start = 0x02753, .end = 0x02755 }, // Black Question Mark Orna .. White Exclamation Mark O
    .{ .start = 0x02757, .end = 0x02757 }, // Heavy Exclamation Mark S .. Heavy Exclamation Mark S
    .{ .start = 0x02795, .end = 0x02797 }, // Heavy Plus Sign          .. Heavy Division Sign
    .{ .start = 0x027b0, .end = 0x027b0 }, // Curly Loop               .. Curly Loop
    .{ .start = 0x027bf, .end = 0x027bf }, // Double Curly Loop        .. Double Curly Loop
    .{ .start = 0x02b1b, .end = 0x02b1c }, // Black Large Square       .. White Large Square
    .{ .start = 0x02b50, .end = 0x02b50 }, // White Medium Star        .. White Medium Star
    .{ .start = 0x02b55, .end = 0x02b55 }, // Heavy Large Circle       .. Heavy Large Circle
    .{ .start = 0x02e80, .end = 0x02e99 }, // Cjk Radical Repeat       .. Cjk Radical Rap
    .{ .start = 0x02e9b, .end = 0x02ef3 }, // Cjk Radical Choke        .. Cjk Radical C-simplified
    .{ .start = 0x02f00, .end = 0x02fd5 }, // Kangxi Radical One       .. Kangxi Radical Flute
    .{ .start = 0x02ff0, .end = 0x02ffb }, // Ideographic Description  .. Ideographic Description
    .{ .start = 0x03000, .end = 0x0303e }, // Ideographic Space        .. Ideographic Variation In
    .{ .start = 0x03041, .end = 0x03096 }, // Hiragana Letter Small A  .. Hiragana Letter Small Ke
    .{ .start = 0x03099, .end = 0x030ff }, // Combining Katakana-hirag .. Katakana Digraph Koto
    .{ .start = 0x03105, .end = 0x0312f }, // Bopomofo Letter B        .. Bopomofo Letter Nn
    .{ .start = 0x03131, .end = 0x0318e }, // Hangul Letter Kiyeok     .. Hangul Letter Araeae
    .{ .start = 0x03190, .end = 0x031e3 }, // Ideographic Annotation L .. Cjk Stroke Q
    .{ .start = 0x031f0, .end = 0x0321e }, // Katakana Letter Small Ku .. Parenthesized Korean Cha
    .{ .start = 0x03220, .end = 0x03247 }, // Parenthesized Ideograph  .. Circled Ideograph Koto
    .{ .start = 0x03250, .end = 0x04dbf }, // Partnership Sign         .. Cjk Unified Ideograph-4d
    .{ .start = 0x04e00, .end = 0x0a48c }, // Cjk Unified Ideograph-4e .. Yi Syllable Yyr
    .{ .start = 0x0a490, .end = 0x0a4c6 }, // Yi Radical Qot           .. Yi Radical Ke
    .{ .start = 0x0a960, .end = 0x0a97c }, // Hangul Choseong Tikeut-m .. Hangul Choseong Ssangyeo
    .{ .start = 0x0ac00, .end = 0x0d7a3 }, // Hangul Syllable Ga       .. Hangul Syllable Hih
    .{ .start = 0x0f900, .end = 0x0faff }, // Cjk Compatibility Ideogr .. (nil)
    .{ .start = 0x0fe10, .end = 0x0fe19 }, // Presentation Form For Ve .. Presentation Form For Ve
    .{ .start = 0x0fe30, .end = 0x0fe52 }, // Presentation Form For Ve .. Small Full Stop
    .{ .start = 0x0fe54, .end = 0x0fe66 }, // Small Semicolon          .. Small Equals Sign
    .{ .start = 0x0fe68, .end = 0x0fe6b }, // Small Reverse Solidus    .. Small Commercial At
    .{ .start = 0x0ff01, .end = 0x0ff60 }, // Fullwidth Exclamation Ma .. Fullwidth Right White Pa
    .{ .start = 0x0ffe0, .end = 0x0ffe6 }, // Fullwidth Cent Sign      .. Fullwidth Won Sign
    .{ .start = 0x16fe0, .end = 0x16fe4 }, // Tangut Iteration Mark    .. Khitan Small Script Fill
    .{ .start = 0x16ff0, .end = 0x16ff1 }, // Vietnamese Alternate Rea .. Vietnamese Alternate Rea
    .{ .start = 0x17000, .end = 0x187f7 }, // (nil)                    .. (nil)
    .{ .start = 0x18800, .end = 0x18cd5 }, // Tangut Component-001     .. Khitan Small Script Char
    .{ .start = 0x18d00, .end = 0x18d08 }, // (nil)                    .. (nil)
    .{ .start = 0x1aff0, .end = 0x1aff3 }, // Katakana Letter Minnan T .. Katakana Letter Minnan T
    .{ .start = 0x1aff5, .end = 0x1affb }, // Katakana Letter Minnan T .. Katakana Letter Minnan N
    .{ .start = 0x1affd, .end = 0x1affe }, // Katakana Letter Minnan N .. Katakana Letter Minnan N
    .{ .start = 0x1b000, .end = 0x1b122 }, // Katakana Letter Archaic  .. Katakana Letter Archaic
    .{ .start = 0x1b132, .end = 0x1b132 }, // (nil)                    .. (nil)
    .{ .start = 0x1b150, .end = 0x1b152 }, // Hiragana Letter Small Wi .. Hiragana Letter Small Wo
    .{ .start = 0x1b155, .end = 0x1b155 }, // (nil)                    .. (nil)
    .{ .start = 0x1b164, .end = 0x1b167 }, // Katakana Letter Small Wi .. Katakana Letter Small N
    .{ .start = 0x1b170, .end = 0x1b2fb }, // Nushu Character-1b170    .. Nushu Character-1b2fb
    .{ .start = 0x1f004, .end = 0x1f004 }, // Mahjong Tile Red Dragon  .. Mahjong Tile Red Dragon
    .{ .start = 0x1f0cf, .end = 0x1f0cf }, // Playing Card Black Joker .. Playing Card Black Joker
    .{ .start = 0x1f18e, .end = 0x1f18e }, // Negative Squared Ab      .. Negative Squared Ab
    .{ .start = 0x1f191, .end = 0x1f19a }, // Squared Cl               .. Squared Vs
    .{ .start = 0x1f200, .end = 0x1f202 }, // Square Hiragana Hoka     .. Squared Katakana Sa
    .{ .start = 0x1f210, .end = 0x1f23b }, // Squared Cjk Unified Ideo .. Squared Cjk Unified Ideo
    .{ .start = 0x1f240, .end = 0x1f248 }, // Tortoise Shell Bracketed .. Tortoise Shell Bracketed
    .{ .start = 0x1f250, .end = 0x1f251 }, // Circled Ideograph Advant .. Circled Ideograph Accept
    .{ .start = 0x1f260, .end = 0x1f265 }, // Rounded Symbol For Fu    .. Rounded Symbol For Cai
    .{ .start = 0x1f300, .end = 0x1f320 }, // Cyclone                  .. Shooting Star
    .{ .start = 0x1f32d, .end = 0x1f335 }, // Hot Dog                  .. Cactus
    .{ .start = 0x1f337, .end = 0x1f37c }, // Tulip                    .. Baby Bottle
    .{ .start = 0x1f37e, .end = 0x1f393 }, // Bottle With Popping Cork .. Graduation Cap
    .{ .start = 0x1f3a0, .end = 0x1f3ca }, // Carousel Horse           .. Swimmer
    .{ .start = 0x1f3cf, .end = 0x1f3d3 }, // Cricket Bat And Ball     .. Table Tennis Paddle And
    .{ .start = 0x1f3e0, .end = 0x1f3f0 }, // House Building           .. European Castle
    .{ .start = 0x1f3f4, .end = 0x1f3f4 }, // Waving Black Flag        .. Waving Black Flag
    .{ .start = 0x1f3f8, .end = 0x1f43e }, // Badminton Racquet And Sh .. Paw Prints
    .{ .start = 0x1f440, .end = 0x1f440 }, // Eyes                     .. Eyes
    .{ .start = 0x1f442, .end = 0x1f4fc }, // Ear                      .. Videocassette
    .{ .start = 0x1f4ff, .end = 0x1f53d }, // Prayer Beads             .. Down-pointing Small Red
    .{ .start = 0x1f54b, .end = 0x1f54e }, // Kaaba                    .. Menorah With Nine Branch
    .{ .start = 0x1f550, .end = 0x1f567 }, // Clock Face One Oclock    .. Clock Face Twelve-thirty
    .{ .start = 0x1f57a, .end = 0x1f57a }, // Man Dancing              .. Man Dancing
    .{ .start = 0x1f595, .end = 0x1f596 }, // Reversed Hand With Middl .. Raised Hand With Part Be
    .{ .start = 0x1f5a4, .end = 0x1f5a4 }, // Black Heart              .. Black Heart
    .{ .start = 0x1f5fb, .end = 0x1f64f }, // Mount Fuji               .. Person With Folded Hands
    .{ .start = 0x1f680, .end = 0x1f6c5 }, // Rocket                   .. Left Luggage
    .{ .start = 0x1f6cc, .end = 0x1f6cc }, // Sleeping Accommodation   .. Sleeping Accommodation
    .{ .start = 0x1f6d0, .end = 0x1f6d2 }, // Place Of Worship         .. Shopping Trolley
    .{ .start = 0x1f6d5, .end = 0x1f6d7 }, // Hindu Temple             .. Elevator
    .{ .start = 0x1f6dc, .end = 0x1f6df }, // (nil)                    .. Ring Buoy
    .{ .start = 0x1f6eb, .end = 0x1f6ec }, // Airplane Departure       .. Airplane Arriving
    .{ .start = 0x1f6f4, .end = 0x1f6fc }, // Scooter                  .. Roller Skate
    .{ .start = 0x1f7e0, .end = 0x1f7eb }, // Large Orange Circle      .. Large Brown Square
    .{ .start = 0x1f7f0, .end = 0x1f7f0 }, // Heavy Equals Sign        .. Heavy Equals Sign
    .{ .start = 0x1f90c, .end = 0x1f93a }, // Pinched Fingers          .. Fencer
    .{ .start = 0x1f93c, .end = 0x1f945 }, // Wrestlers                .. Goal Net
    .{ .start = 0x1f947, .end = 0x1f9ff }, // First Place Medal        .. Nazar Amulet
    .{ .start = 0x1fa70, .end = 0x1fa7c }, // Ballet Shoes             .. Crutch
    .{ .start = 0x1fa80, .end = 0x1fa88 }, // Yo-yo                    .. (nil)
    .{ .start = 0x1fa90, .end = 0x1fabd }, // Ringed Planet            .. (nil)
    .{ .start = 0x1fabf, .end = 0x1fac5 }, // (nil)                    .. Person With Crown
    .{ .start = 0x1face, .end = 0x1fadb }, // (nil)                    .. (nil)
    .{ .start = 0x1fae0, .end = 0x1fae8 }, // Melting Face             .. (nil)
    .{ .start = 0x1faf0, .end = 0x1faf8 }, // Hand With Index Finger A .. (nil)
    .{ .start = 0x20000, .end = 0x2fffd }, // Cjk Unified Ideograph-20 .. (nil)
    .{ .start = 0x30000, .end = 0x3fffd }, // Cjk Unified Ideograph-30 .. (nil)
};

fn inTable(table: []const Range, cp: u32) bool {
    if (table.len == 0) return false;

    // Fast rejection.
    if (cp < table[0].start) return false;

    var bot: usize = 0;
    var top: usize = table.len - 1;

    while (bot <= top) {
        const mid = bot + (top - bot) / 2;
        const interval = table[mid];

        if (interval.end < cp) {
            bot = mid + 1;
        } else if (interval.start > cp) {
            if (mid == 0) break;
            top = mid - 1;
        } else {
            return true;
        }
    }

    return false;
}

inline fn emojiWidth(cp: u32) bool {
    // Emoji_Presentation: always width 2 regardless of wcwidth
    // Source: Unicode emoji-data.txt Emoji_Presentation property
    return switch (cp) {
        0x203C,
        0x2049,
        0x2139,
        0x2194...0x2199,
        0x21A9...0x21AA,
        0x2328,
        0x23cf,
        0x24c2,
        0x2600...0x2601,
        0x2602...0x2604,
        0x260e,
        0x2611,
        0x2614...0x2615, // umbrella with rain, hot beverage
        0x2618,
        0x261d,
        0x2620,
        0x2622...0x2623,
        0x2626,
        0x262a,
        0x262e,
        0x262f,
        0x2638...0x2639,
        0x263a,
        0x2640,
        0x2642,
        0x2648...0x2653, // zodiac signs
        0x265f,
        0x2660,
        0x2663,
        0x2665...0x2666,
        0x2668,
        0x267b,
        0x267e,
        0x267F, // wheelchair symbol
        0x2692...0x2697, // anchor
        0x2699,
        0x269b...0x269c,
        0x26a0...0x26a1,
        0x26a7,
        0x26AA...0x26AB, // medium circles
        0x26B0...0x26B1, // soccer ball, baseball
        0x26BD...0x26BE, // soccer ball, baseball
        0x26C4...0x26C5, // snowman, sun behind cloud
        0x26C8,
        0x26CE, // Ophiuchus
        0x26CF,
        0x26D1, // no entry
        0x26D3,
        0x26D4,
        0x26EA, // church
        0x26E9, // shinto shrine
        0x26F2...0x26F3, // fountain, golf
        0x26F0...0x26F1, // mountain .. umbrella on ground
        0x26F7...0x26F9, // skier .. person bouncing ball
        0x26F5, // sailboat
        0x26FA, // tent
        0x26FD, // fuel pump
        0x231A...0x231B,
        0x23E9...0x23F3,
        0x23F8...0x23FA,
        0x25AA...0x25AB,
        0x25B6,
        0x25C0,
        0x25FB...0x25FE,
        0x2702,
        0x2705,
        0x2708...0x270D,
        0x270F,
        0x2712,
        0x2714,
        0x2716,
        0x271D,
        0x2721,
        0x2728,
        0x2733...0x2734,
        0x2744,
        0x2747,
        0x274C,
        0x274E,
        0x2753...0x2755,
        0x2757,
        0x2763...0x2764,
        0x2795...0x2797,
        0x27A1,
        0x27B0,
        0x27BF,
        0x2934...0x2935,
        0x2B05...0x2B07,
        0x2B1B...0x2B1C,
        0x2B50,
        0x2B55,
        0x3030,
        0x303D,
        0x3297,
        0x3299,
        // Full-width emoji blocks
        0x1F000...0x1FAFF,
        => true,
        else => false,
    };
}

pub inline fn wcwidth(cp: u32) i8 {
    if (cp < 0x80) return 1; // ASCII (cp is always printable here in practice)
    if (cp < 0xa0) return -1; // C1 controls (0x80–0x9F); 0x7F already returned 1 above
    if (cp < 0x0300) return 1; // common printable Latin/Greek/etc., always narrow
    if (emojiWidth(cp)) return 2; // emoji, only called for cp >= 0x0300
    if (inTable(&zero_width, cp)) return 0;
    return if (inTable(&wide_eastasian, cp)) 2 else 1;
}
