//! Maps parsed C0, ESC, CSI, OSC and DCS sequences to Terminal
//! operations and replies. It holds no state of its own and must not
//! format reply bytes: it names a `Reply` and `Terminal.reply` encodes
//! it.

const std = @import("std");

const Parameter = @import("../vt/parser.zig").Parameter;
const Terminal = @import("term.zig").Terminal;
const Charset = @import("cell.zig").Charset;
const Option = @import("term.zig").Option;
const CellPosition = @import("term.zig").CellPosition;
const Palette = @import("Palette.zig").Palette;
const Screen = @import("screen.zig").Screen;
const sgr = @import("sgr.zig");

/// helper: get param value or default fallback, skipping sub-params
/// The cursor position CPR and DECXCPR report: under DECOM the row counts
/// from the top margin, as xterm does (`charproc.c` CASE_DSR) and the VT100
/// manual describes.
fn reportedPosition(comptime option: Option, screen: *const Screen(option)) CellPosition {
    const top: u16 = @intCast(screen.effectiveTop());
    return .{ .row = screen.cursor.row -| top, .col = screen.cursor.col };
}

fn paramOr(params: []const Parameter, index: usize, default: u16) u16 {
    var n: usize = 0;
    for (params) |p| {
        if (p.separator == .sub_parameter) continue;
        if (n == index) return if (p.value == 0) default else p.value;
        n += 1;
    }
    return default;
}

pub const Escape = struct {
    pub fn dispatch(comptime option: Option, term: *Terminal(option), final: u8, intermediates: []const u8) void {
        const inter: u8 = if (intermediates.len > 0) intermediates[0] else 0;
        const key: u16 = (@as(u16, inter) << 8) | @as(u16, final);

        switch (key) {
            '=' => term.mode.keypad_app = true, // DECKPAM
            '>' => term.mode.keypad_app = false, // DECKPNM
            '7' => term.active().saveCursor(), // DECSC
            '6' => {}, // DECBI (VT420); FIXME requires scrollRight
            '8' => term.active().restoreCursor(), // DECRC
            '9' => {}, // DECFI (VT420); FIXME requires scrollLeft
            'D' => term.active().index(), // IND
            'E' => { // NEL (CR + LF)
                term.active().index();
                term.active().cursor.col = 0;
                term.active().cursor.wrap_pending = false;
            },
            'H' => term.active().setTabStop(), // HTS
            'M' => term.active().reverseIndex(), // RI
            'N' => term.active().singleShift2(), // SS2
            'O' => term.active().singleShift3(), // SS3
            'Z' => term.reply(.primary_attributes), // DECID, the obsolete DA1 request

            'c' => term.hardReset(), // RIS

            'n' => term.active().lockingShift(2, .gl), // LS2: GL = G2
            'o' => term.active().lockingShift(3, .gl), // LS3: GL = G3
            '~' => term.active().lockingShift(1, .gr), // LS1R: GR = G1
            '}' => term.active().lockingShift(2, .gr), // LS2R: GR = G2
            '|' => term.active().lockingShift(3, .gr), // LS3R: GR = G3

            // DECSCL | ESC [ level ; control-format " p

            // S7C1T / switch output to 7-bit C1, does NOT change conformance_level
            0x2046 => term.control_format = .s7c1t,

            // S8C1T / switch output to 8-bit C1, does NOT change conformance_level
            0x2047 => term.control_format = .s8c1t,

            // ESC # (0x23) DEC screen operations (VT100)
            0x2333 => term.active().setLineAttr(.double_top), // DECDHL / ESC # 3
            0x2334 => term.active().setLineAttr(.double_bottom), // DECDHL / ESC # 4
            0x2335 => term.active().setLineAttr(.normal), // DECSWL /  ESC # 5
            0x2336 => term.active().setLineAttr(.double_width), // DECDWL / ESC # 6
            0x2338 => term.active().decaln(), // DECALN / ESC # 8

            0x2540 => term.input.encoding = .latin1, // ESC % @ (ISO Latin-1)
            0x2547 => term.input.encoding = .utf8, // ESC % G (UTF-8 mode)

            // ESC ( ) * + Charset designation
            0x2800...0x28FF => term.active().designateCharset(0, Charset.charsetFromByte(final)),
            0x2900...0x29FF => term.active().designateCharset(1, Charset.charsetFromByte(final)),
            0x2A00...0x2AFF => term.active().designateCharset(2, Charset.charsetFromByte(final)),
            0x2B00...0x2BFF => term.active().designateCharset(3, Charset.charsetFromByte(final)),

            // - . / : Designate G1/G2/G3 96-character sets (VT300)
            0x2D00...0x2DFF => term.active().designateCharset(1, Charset.charsetFromByte96(final)),
            0x2E00...0x2EFF => term.active().designateCharset(2, Charset.charsetFromByte96(final)),
            0x2F00...0x2FFF => term.active().designateCharset(3, Charset.charsetFromByte96(final)),

            else => {
                // escape control sequences that need > 1 intermediates
                // ESC ( " > (DEC Greek)
                // ESC ( % 2 (Turkish) have two intermediate bytes — ( and "
                // multi-byte-intermediate charset (VT500 Greek/Turkish/Hebrew)

                // otherwise, unrecognized; silently ignore per ECMA-48 S6.6
            },
        }
    }
};

/// Handle C0 control characters (bytes 0x00–0x1F) and DEL (0x7F).
///
/// Called by the VT parser for bytes that are not part of an escape sequence.
/// Most C0 bytes are either ignored or map directly to a single Screen method.
pub const C0 = struct {
    pub fn dispatch(comptime option: Option, term: *Terminal(option), byte: u8) void {
        switch (byte) {
            0x00 => {}, // NUL
            0x05 => term.reply(.{ .answerback = term.getAnswerback() }), // ENQ
            0x07 => { // BEL
                term.events.set(.bell);
            },
            0x08 => term.active().cursorLeft(1), // BS
            0x09 => term.active().tabForward(1), // HT
            0x0A, 0x0B, 0x0C => { // LF, VT, FF
                term.active().index();
                if (term.mode.linefeed) {
                    term.active().cursor.col = 0;
                    term.active().cursor.wrap_pending = false;
                }
            },
            0x0D => { // CR
                term.active().cursor.col = 0;
                term.active().cursor.wrap_pending = false;
                term.active().markDirty(term.active().cursor.row);
            },
            0x0E => term.active().shiftOut(), // SO | GL = G1
            0x0F => term.active().shiftIn(), // SI | GL = G0
            0x18, 0x1A => term.input.abortSequence(term.active()),
            0x7F => {}, // DEL
            else => {}, // other C0
        }
    }
};

// zero runtime cost on comptime option, the compiler will generates
// one concrete version of dispatch per unique `option` value ("monomorphization").
// see details "The compiler monomorphizes S.f for T=u8 on its first use"
// [generics.zig#L182-L186](https://github.com/ziglang/zig/blob/738d2be9/test/behavior/generics.zig#L182-L186)
pub const Csi = struct {
    pub fn dispatch(
        comptime option: Option,
        terminal: *Terminal(option),
        final: u8,
        intermediates: []const u8,
        parameters: []const Parameter,
    ) void {
        const marker = if (intermediates.len > 0) intermediates[0] else 0;
        const key: u16 = (@as(u16, marker) << 8) | @as(u16, final);

        const p1_0 = paramOr(parameters, 0, 0);
        const p1 = if (p1_0 > 0) p1_0 else 1;

        const p2_0 = paramOr(parameters, 1, 0);
        const p2 = if (p2_0 > 0) p2_0 else 1;

        // Resolved once per sequence. Cases that can switch screens
        // (DECSET 47/1047/1049, DECSTR) go through `terminal` instead.
        const screen = terminal.active();

        switch (key) {
            's' => screen.saveCursor(), // ANSI SC / CSI s
            'u' => screen.restoreCursor(), // ANSI RC / CSI u

            // Cursor Movement
            'A' => screen.cursorUp(p1), // CUU / CSI Ps A
            'B' => screen.cursorDown(p1), // CUD / CSI Ps B
            'C' => screen.cursorRight(p1), // CUF / CSI Ps C
            'D' => screen.cursorLeft(p1), // CUB / CSI Ps D

            'E' => {
                // CNL / CSI Ps E (down N, column 0)
                // cursorDown clears `wrap_pending`.
                screen.cursorDown(p1);
                screen.cursor.col = 0;
            },

            'F' => {
                // CPL / CSI Ps F (up N, column 0)
                screen.cursorUp(p1);
                screen.cursor.col = 0; // cursorUp clears `wrap_pending`.
            },

            'G' => screen.cursorCol(p1 -| 1), // CHA / CSI Ps G
            'H' => screen.cursorPos(p1 -| 1, p2 -| 1), // CUP / CSI Ps ; Ps H
            'f' => screen.cursorPos(p1 -| 1, p2 -| 1), // HVP / CSI Ps ; Ps f
            'I' => screen.tabForward(p1), // CHT / CSI Ps I
            'J' => screen.eraseDisplay(p1_0), // ED / CSI Ps J
            'K' => screen.eraseLine(p1_0), // EL / CSI Ps K
            'X' => screen.eraseChars(p1), // ECH / CSI Ps X

            '@' => screen.insertChars(p1), // ICH / CSI Ps @
            'P' => screen.deleteChars(p1), // DCH / CSI Ps P
            'L' => screen.insertLines(p1), // IL / CSI Ps L
            'M' => screen.deleteLines(p1), // DL / CSI Ps M

            'S' => screen.scrollUp(p1), // SU / CSI Ps S
            'T' => screen.scrollDown(p1), // SD / CSI Ps T
            'Z' => screen.tabBackward(p1), // CBT / CSI Ps Z

            'a' => screen.cursorRight(p1), // HPR / CSI Ps a
            'b' => screen.repeatChar(p1), // REP / CSI Ps b
            'c' => if (p1_0 == 0) terminal.reply(.primary_attributes), // DA1 / CSI c

            'm' => {
                sgr.parse(option, terminal, parameters); // SGR / CSI Ps m;
            },

            // VPA — Vertical Position Absolute (CSI Ps d): 1-based row, ignores DECOM
            'd' => screen.cursorRow(p1 -| 1),

            'e' => screen.cursorDown(p1), // VPR / CSI Ps e
            '`' => screen.cursorCol(p1 -| 1), // HPA / CSI Ps `

            'g' => screen.clearTabStop(p1_0), // TBC Ps g

            'r' => {
                // DECSTBM
                screen.setScrollRegion(p1_0, p2_0);
            },

            // DSR / CSI Ps n
            'n' => switch (p1_0) {
                5 => terminal.reply(.status_ok),
                6 => terminal.reply(.{ .cursor_position = reportedPosition(option, screen) }), // CPR
                else => {},
            },

            0x0068, 0x006c => {
                // SM / CSI Pm h
                // RM / CSI Pm l
                for (parameters) |*p| {
                    if (p.separator == .sub_parameter) continue;
                    terminal.setMode(p.value, key == 0x68);
                }
            },

            // DA2 / CSI > c.
            0x3E63 => if (p1_0 == 0) terminal.reply(.secondary_attributes),
            // XTMODKEYS / CSI > Pp ; Pv m. Only modifyOtherKeys (Pp 4) is
            // implemented; no parameters resets every resource.
            0x3E6D => if (parameters.len == 0) {
                terminal.setModifyOtherKeys(null);
            } else if (p1_0 == 4) {
                terminal.setModifyOtherKeys(if (parameters.len < 2) null else p2_0);
            },
            // CSI > Pp n disables a key modifier resource (xterm's -1);
            // for modifyOtherKeys that is level 0.
            0x3E6E => if (p1_0 == 4) terminal.setModifyOtherKeys(null),

            0x3E70 => terminal.xtversion(), // XTVERSION / CSI > Ps q
            0x2071 => terminal.setCursorStyle(p1_0), // DECSCUSR / CSI Ps SP q

            0x3F68, 0x3F6C => {
                // DECSET / CSI ? h
                // DECSET / CSI ? l
                for (parameters) |*p| {
                    if (p.separator == .sub_parameter) continue;
                    terminal.setDecMode(p.value, key == 0x3F68);
                }
            },

            0x2170 => terminal.softReset(), // DECSTR / CSI ! p
            0x2270 => terminal.decscl(p1_0, p2_0), // DECSCL | CSI Ps;Pc " p

            // DECRQM / CSI Ps $ p (ANSI mode)
            0x2470 => terminal.reply(.{ .mode_report = .{ .mode = p1_0, .state = terminal.ansiModeReport(p1_0) } }),
            // DECRQM / CSI ? Ps $ p (DEC private mode). The key keeps only
            // the first intermediate, so the `$` is checked here.
            0x3F70 => if (intermediates.len == 2 and intermediates[1] == '$') {
                terminal.reply(.{ .dec_mode_report = .{ .mode = p1_0, .state = terminal.decModeReport(p1_0) } });
            },

            // DEC DSR / CSI ? Ps n
            0x3F6E => switch (p1_0) {
                6 => terminal.reply(.{ .dec_cursor_position = reportedPosition(option, screen) }), // DECXCPR
                else => {},
            },

            // FIXME requires protected
            // 0x3F4A => term.active().selectiveEraseDisplay(p1_0), // DECSED
            // 0x3F4B => term.active().selectiveEraseLine(p1_0), // DECSEL

            else => {}, // std.debug.print("unhandled dispatch={f}key=0x{x}\n\n", .{ sequence, key }),

        }
    }
};

pub const Osc = struct {
    pub fn dispatch(comptime option: Option, term: *Terminal(option), code: u16, data: []const u8) void {
        switch (code) {
            0 => {
                // OSC 0
                term.setTitle(data);
                term.setIconName(data);
            },
            1 => term.setIconName(data), // OSC 1
            2 => term.setTitle(data), // OSC 2

            // OSC 4 ; n ; spec [; n ; spec ...] ST
            4 => term.setPaletteColor(data),
            10 => term.setOrQueryColor(data, .fg),
            11 => term.setOrQueryColor(data, .bg),
            12 => term.setOrQueryColor(data, .cursor),

            17 => term.setOrQueryColor(data, .selection_bg),
            19 => term.setOrQueryColor(data, .selection_fg),

            52 => {}, // TODO: clipboard

            // OSC 104 ; n — Reset palette color n (no arg = reset all)
            104 => term.resetPaletteColor(data),

            // OSC 110 — Reset default foreground color
            110 => term.palette.set(.foreground, null),

            // OSC 111 — Reset default background color
            111 => term.palette.set(.background, null),

            // OSC 112 — Reset default cursor color
            112 => term.cursor_color = null,

            // OSC 117 — Reset selection background color
            117 => term.selection_background = null,

            // OSC 119 — Reset selection foreground color
            119 => term.selection_foreground = null,

            else => {}, //std.debug.print("unhandled dispatch={f}\n", .{sequence}),
        }
    }
};
