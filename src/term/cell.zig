const std = @import("std");

const Palette = @import("Palette.zig").Palette;
const x11_colors = @import("../color/x11.zig");
// const Instance = @import("../renderer/instance.zig").Instance;

/// A terminal color value stored in 4 bytes.
///
/// Four representations are supported:
///   .default    use the terminal's configured foreground/background
///               color. The tag is preserved in cell storage so that
///               theme changes recolor existing content without a
///               full redraw.
///
///   .indexed    one of the 256 ANSI/xterm palette entries (0–255).
///               Entries 0–15 are the standard 16 colors; 16–231 are the
///               6×6×6 color cube; 232–255 are the grayscale ramp.
///
///   .rgb        24-bit true color (r, g, b each 0–255).
///               Used for SGR 38;2;r;g;b and 48;2;r;g;b sequences.
///
/// Layout (Zig union(enum), tag = u8, max payload = 3 bytes)
pub const Color = union(enum) {
    /// Use the terminal's default foreground or background color.
    default,
    /// ANSI/xterm 256-color palette index.
    indexed: u8,
    /// 24-bit true color.
    rgb: Rgb,

    pub fn fromRgb(r: u8, g: u8, b: u8) Color {
        return .{ .rgb = .{ .r = r, .g = g, .b = b } };
    }

    pub const Rgb = struct {
        r: u8,
        g: u8,
        b: u8,

        const Self = @This();

        pub const white: Color.Rgb = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF };
        pub const black: Color.Rgb = .{ .r = 0x00, .g = 0x00, .b = 0x00 };
        pub const gray: Color.Rgb = .{ .r = 0x2F, .g = 0x2F, .b = 0x2F };

        pub inline fn toArray(self: Rgb) [3]u8 {
            return .{ self.r, self.g, self.b };
        }

        pub inline fn toRgba(self: Rgb, a: u8) [4]f32 {
            return .{
                @floatFromInt(self.r),
                @floatFromInt(self.g),
                @floatFromInt(self.b),
                @floatFromInt(a),
            };
        }

        pub inline fn toNormalizedRgba(self: Rgb, a: f32) [4]f32 {
            const scale: f32 = 1.0 / 255.0;

            return .{
                @as(f32, @floatFromInt(self.r)) * scale,
                @as(f32, @floatFromInt(self.g)) * scale,
                @as(f32, @floatFromInt(self.b)) * scale,
                a,
            };
        }

        /// Pack to the u32 key format used by Palette entries:
        /// 0xRRGGBB_FF (tag byte 0xFF in the low byte is not used here,
        /// the palette tag is in the high byte of the 32-bit key).
        pub fn toU32(self: Self) u32 {
            // return (@as(u32, self.r) << 16) | (@as(u32, self.g) << 8) | @as(u32, self.b);
            return (@as(u32, self.r) << 24) | (@as(u32, self.g) << 16) | (@as(u32, self.b) << 8) | 0xFF;
        }

        pub fn fromU32(v: u32) Rgb {
            return .{
                .r = @intCast((v >> 24) & 0xFF),
                .g = @intCast((v >> 16) & 0xFF),
                .b = @intCast((v >> 8) & 0xFF),
            };
        }

        pub fn fromColorKey(key: u32) Rgb {
            return .{
                .r = @intCast((key >> 16) & 0xFF),
                .g = @intCast((key >> 8) & 0xFF),
                .b = @intCast(key & 0xFF),
            };
        }

        /// Parse an X11/CSS color specification into an RGB triple.
        ///
        /// Supported formats:
        ///   Named X11 colors case insensitive
        ///   #RGB        (4-bit per channel, expanded to 8-bit)
        ///   #RRGGBB     (8-bit per channel)
        ///   #RRRRGGGGBBBB (16-bit per channel, truncated to 8-bit)
        ///   rgb:R/G/B   (X11 format, 1-4 hex digits per channel)
        ///
        /// Returns null on parse failure.
        pub fn parseSpec(spec: []const u8) ?Rgb {
            if (spec.len == 0) return null;

            // #RGB / #RRGGBB / #RRRRGGGGBBBB
            if (spec[0] == '#') {
                const hex = spec[1..];
                switch (hex.len) {
                    3 => {
                        const r4 = std.fmt.parseInt(u8, hex[0..1], 16) catch return null;
                        const g4 = std.fmt.parseInt(u8, hex[1..2], 16) catch return null;
                        const b4 = std.fmt.parseInt(u8, hex[2..3], 16) catch return null;
                        return .{ .r = r4 * 17, .g = g4 * 17, .b = b4 * 17 };
                    },
                    6 => {
                        const r = std.fmt.parseInt(u8, hex[0..2], 16) catch return null;
                        const g = std.fmt.parseInt(u8, hex[2..4], 16) catch return null;
                        const b = std.fmt.parseInt(u8, hex[4..6], 16) catch return null;
                        return .{ .r = r, .g = g, .b = b };
                    },
                    12 => {
                        // 16-bit per channel — take the high byte
                        const r = std.fmt.parseInt(u16, hex[0..4], 16) catch return null;
                        const g = std.fmt.parseInt(u16, hex[4..8], 16) catch return null;
                        const b = std.fmt.parseInt(u16, hex[8..12], 16) catch return null;
                        return .{ .r = @intCast(r >> 8), .g = @intCast(g >> 8), .b = @intCast(b >> 8) };
                    },
                    else => return null,
                }
            }

            // rgb:R/G/B  (X11 format, 1-4 hex digits per channel)
            if (std.mem.startsWith(u8, spec, "rgb:")) {
                const rgb = spec[4..];
                var it = std.mem.splitScalar(u8, rgb, '/');
                const rs = it.next() orelse return null;
                const gs = it.next() orelse return null;
                const bs = it.next() orelse return null;
                if (it.next() != null) return null; // too many components
                const r = parseX11Channel(rs) orelse return null;
                const g = parseX11Channel(gs) orelse return null;
                const b = parseX11Channel(bs) orelse return null;
                return .{ .r = r, .g = g, .b = b };
            }

            // Named X11 colors (case-insensitive)
            // Longest X11 color name is ~20 chars; 64 is a safe upper bound.
            if (spec.len <= 64) {
                // var lower_buf: [64]u8 = undefined;
                // const lower = std.ascii.lowerString(lower_buf[0..spec.len], spec);
                if (x11_colors.fromName(spec)) |c| return Rgb{ .r = c.r, .g = c.g, .b = c.b };
            }

            return null;
        }

        /// Parse a 1-4 hex digit X11 channel value, normalised to 8-bit.
        fn parseX11Channel(s: []const u8) ?u8 {
            if (s.len == 0 or s.len > 4) return null;

            const v = std.fmt.parseInt(u16, s, 16) catch return null;
            // Scale to 8-bit: 1 digit (0-F) → *17, 2 digits (00-FF) → as-is,
            // 3 digits (000-FFF) → >>4, 4 digits (0000-FFFF) → >>8
            return switch (s.len) {
                1 => @intCast(v * 17),
                2 => @intCast(v),
                3 => @intCast(v >> 4),
                4 => @intCast(v >> 8),
                else => unreachable,
            };
        }
    };
};

comptime {
    std.debug.assert(4 == @sizeOf(Color));
}

/// Underline style encoded in 2 bits.
///
/// Matches the SGR 4 sub-parameter space:
///   SGR 4   → single
///   SGR 4:2 → double
///   SGR 4:3 → curly  (kitty / VTE extension)
///   SGR 4:4 → dotted (kitty / VTE extension)
///   SGR 4:5 → dashed  (kitty / VTE extension)
///
/// Stored inside AttrFlags to keep the entire flags field at exactly 1 byte.
pub const UnderlineStyle = enum(u3) {
    none = 0,
    single = 1,
    double = 2,
    curly = 3,
    // underline extension (widely adopted by VTE, WezTerm, foot, etc.)
    dotted = 4,
    dashed = 5,
    // 6, 7 reserved
};

comptime {
    std.debug.assert(1 == @sizeOf(UnderlineStyle));
    std.debug.assert(3 == @bitSizeOf(UnderlineStyle));
}

pub const Charset = enum(u4) {
    ascii = 0, // ISO 646 / US-ASCII (default)
    dec_special = 1, // DEC Special Graphics (box drawing)
    dec_suppl = 2, // DEC Supplemental (VT220)
    uk = 3, // British NRC (# → £)
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
            else => .ascii, // unknown — pass-through
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

const dec_map = [_]u21{
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
    // dec_map has 31 entries (0x7E - 0x60 + 1 = 31),
    // and cp - 0x60 produces indices 0..30
    std.debug.assert(dec_map.len == 0x7E - 0x60 + 1);
}

/// VT100/VT220 character set state, packed into 4 bytes (u32).
///
/// Terminals maintain four charset slots (G0–G3), each designatable to
/// a named character set via ESC ( X … ESC + X. The GL register selects
/// which slot maps to the 7-bit range; GR selects the 8-bit range.
/// SS2 (ESC N) and SS3 (ESC O) temporarily override GL for one character.
///
/// Bit layout (32 bits total):
/// [3:0]      g0              G0 slot charset (Charset, 4 bits)
/// [7:4]      g1              G1 slot charset (Charset, 4 bits)
/// [11:8]     g2              G2 slot charset (Charset, 4 bits)
/// [15:12]    g3              G3 slot charset (Charset, 4 bits)
/// [17:16]    gl              active GL register (0–3 = G0–G3)
/// [19:18]    gr              active GR register (0–3 = G0–G3)
/// [22:20]    single_shift    0–3 = G0–G3 pending; 4 = none (sentinel)
/// [31:23]    _pad            reserved, must be 0
pub const CharsetState = packed struct(u32) {
    g0: Charset = .ascii,
    g1: Charset = .ascii,
    g2: Charset = .ascii,
    g3: Charset = .ascii,
    // 4×4 = 16 bits used

    gl: u2 = 0, // GL register (0–3 = G0–G3)
    gr: u2 = 2, // GR register (0–3 = G0–G3)

    /// Single-shift override for the next character only (SS2/SS3).
    /// Values 0–3 = G0–G3 pending. Value 4 = no shift pending (sentinel).
    /// Replaces `?u2` (which would cost 4 bytes due to Zig issue #104).
    ss: u3 = no_shift,
    _pad: u9 = 0,
    // 16 + 2 + 2 + 3 + 9 = 32 bits

    pub const no_shift: u3 = 4;

    /// Linear scan through a comptime NRC table.
    /// Tables are tiny (≤12 entries) so a loop is faster than a hash map.
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

    /// Returns the charset in slot `index` (0–3 = G0–G3).
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
    /// Only the 0x60–0x7E range is remapped; everything else passes through.
    /// The mapping follows the VT100 User Guide table 3-9.
    fn translateDecSpecial(cp: u21) u21 {
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
    /// Only the 0x20–0x7E printable ASCII range is remapped; control
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
            .ascii => unreachable, // asci is fast path doesn't has to pay for the range check
            .dec_special => translateDecSpecial(cp),
            // dec_suppl and iso_latin1 are GR sets (0xA0–0xFF range).
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

/// Cursor rendering styles.
///
/// IMPORTANT: The numeric values are part of the implemenation.
/// * even discriminants reprsents blinking styles.
/// * odd discriminants reprsents steady styles.
///
/// DO NOT reorder or renumber these values unless all parity-based
/// code (e.g. `CursorStyle.blink()`, shaders instance flags) is updated.
pub const CursorStyle = enum(u3) {
    blinking_block = 0,
    steady_block = 1,
    blinking_underline = 2,
    steady_underline = 3,
    blinking_beam = 4,
    steady_beam = 5,

    comptime {
        for ([_]CursorStyle{ .blinking_block, .blinking_underline, .blinking_beam }) |style| {
            std.debug.assert((@intFromEnum(style) & 1) == 0);
        }

        for ([_]CursorStyle{ .steady_block, .steady_underline, .steady_beam }) |style| {
            std.debug.assert((@intFromEnum(style) & 1) == 1);
        }
    }

    pub const default: CursorStyle = .blinking_block;

    pub const Blink = enum {
        /// steady (visible)
        off,
        /// blinking
        on,
    };

    /// Returns the geometric shape, independent of blink mode.
    /// Use this to select the draw path in the Renderer.
    pub const Shape = enum { block, underline, beam };

    /// Returns whether cursor style blinks.
    pub inline fn blink(self: CursorStyle) Blink {
        return if ((@intFromEnum(self) & 1) == 0) .on else .off;
    }

    /// Cursor Shape encoding:
    /// bits 1-2: shape (0 = block, 1 = underline, 2 = beam)
    pub fn shape(self: CursorStyle) Shape {
        return @enumFromInt(@intFromEnum(self) >> 1);
    }
};

pub const Cursor = struct {
    row: u16 = 0, // logical row
    col: u16 = 0,
    attr: Attr = .{},
    wrap_pending: bool = false,
    origin: bool = false,
    style: CursorStyle = .default,
    charset: CharsetState = .{},

    pub fn position(self: *const Cursor) struct { u16, u16 } {
        return .{ self.row, self.col };
    }
};

pub const SavedCursor = struct {
    row: u16 = 0,
    col: u16 = 0,
    origin: bool = false,
    attr: Attr = .{},
    style: CursorStyle = .steady_block,
    charset: CharsetState = .{},
    charset_is_identity: bool = true,
};

comptime {
    std.debug.assert(16 == @sizeOf(Cursor));
    std.debug.assert(16 == @sizeOf(SavedCursor));
}

/// SGR text-decoration flags packed into a single byte.
pub const AttrFlags = packed struct(u12) {
    bold: bool = false, // SGR 1
    dim: bool = false, // SGR 2
    italic: bool = false, // SGR 3
    blink: bool = false, // SGR 5
    blink_rapid: bool = false, // SGR 6
    reverse: bool = false, // SGR 7
    invisible: bool = false, // SGR 8
    strikethrough: bool = false, // SGR 9
    overline: bool = false, // SGR 53
    underline: UnderlineStyle = .none, // SGR 4 / 4:[0-5] (3 bits)

    pub const default: AttrFlags = .{
        .bold = false,
        .dim = false,
        .italic = false,
        .blink = false,
        .blink_rapid = false,
        .reverse = false,
        .invisible = false,
        .strikethrough = false,
        .overline = false,
        .underline = .none,
    };
};

comptime {
    std.debug.assert(12 == @bitSizeOf(AttrFlags));
}

/// SGR (Select Graphic Rendition) attributes for a single cell.
pub const Attr = struct {
    flags: AttrFlags = .{},
    fg: u8 = 0,
    bg: u8 = 0,
};

comptime {
    std.debug.assert(4 == @sizeOf(Attr));
    std.debug.assert(32 == @bitSizeOf(Attr));
}

pub const Kind = enum(u3) {
    /// blank cell (codepoint == 0)
    empty = 0,
    /// 1-col codepoint
    narrow = 1,
    /// 1-col wide character left-half
    wide_left = 2,
    /// 2-col wide character right-half placeholder
    wide_right = 3,
    /// 1-col ZWJ/grapheme sequence ID, narrow
    grapheme = 4,
    /// 2-col ZWJ/grapheme sequence ID, wide
    grapheme_wide = 5,
    /// TODO reserved future HarfBuzz shaped run
    shaped = 6,

    // 7 = reserved

    pub fn columnSpan(self: Kind) u2 {
        return switch (self) {
            .empty => 1, // ocupies 1 column (blank)
            .narrow => 1,
            .grapheme => 1,
            .wide_left, .grapheme_wide => 2,
            .wide_right => 0, // placeholder, caller must guard against infinite loop
            .shaped => unreachable, // shaped cells carry their own span
        };
    }

    /// Returns the kind is ZWJ/grapheme sequence ID (narrow/wide).
    pub inline fn isGrapheme(self: Kind) bool {
        return self == .grapheme or self == .grapheme_wide;
    }

    pub inline fn isWideLeft(self: Kind) bool {
        return self == .wide_left or self == .grapheme_wide;
    }
};

pub const ExtAttr = struct {
    pub const Coordinate = struct { row: u16, col: u16 };

    /// SGR 58 underline color (palette index)
    /// 0 = use fg color
    ul_color: u8,

    /// valid IDs start at 1
    /// 0 = no URL
    url_id: u16,
};

/// A single terminal grid cell.
pub const Cell = packed struct(u64) {
    /// Unicode scalar value (U+0000–U+10FFFF) or grapheme sequence ID.
    /// default: 0 (NUL) means the cell is empty.
    codepoint: u32 = 0,

    /// What the current cell kind codepoint
    kind: Kind = .empty,
    flags: AttrFlags = .default,

    // HACK: The bottleneck is not palette size, but it's
    // eviction policy. With index 0 = default and indicies 1-15 ANSI colors,
    // 8-bit gives 240 dynamic slots. A typical terminal session (vim,tmux,syntax,higlighting)
    // uses 20-50 distinct colors simultaneously. I think 240 is still overkill.
    /// store palette index (0 = default)
    foreground: u8 = 0,

    /// store palette index (0 = default)
    background: u8 = 0,

    _: u1 = 0,

    pub const empty: Cell = .{};
};

comptime {
    std.debug.assert(8 == @sizeOf(Cell));
    std.debug.assert(8 == @alignOf(Cell));
}
