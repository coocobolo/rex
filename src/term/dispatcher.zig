//! Maps parsed C0, ESC, CSI, OSC and DCS sequences to Terminal
//! operations and replies. It holds no state of its own and must not
//! format reply bytes: it names a `Reply` and `Terminal.reply` encodes
//! it.

const std = @import("std");

const Parameter = @import("../vt/parser.zig").Parameter;
const Terminal = @import("term.zig").Terminal;
const AnsiMode = @import("term.zig").AnsiMode;
const Set = @import("charset.zig").Set;
const Option = @import("term.zig").Option;
const CellPosition = @import("term.zig").CellPosition;
const Palette = @import("Palette.zig").Palette;
const screen_mod = @import("screen.zig");
const Screen = screen_mod.Screen;
const EraseDisplay = screen_mod.EraseDisplay;
const EraseLine = screen_mod.EraseLine;
const TabClear = screen_mod.TabClear;
const sgr = @import("sgr.zig");
const Title = @import("Title.zig");

/// The cursor position CPR and DECXCPR report: under DECOM the row counts
/// from the top margin, as xterm does (`charproc.c` CASE_DSR) and the VT100
/// manual describes.
fn reportedPosition(comptime option: Option, screen: *const Screen(option)) CellPosition {
    const top: u16 = @intCast(screen.effectiveTop());
    return .{ .row = screen.cursor.row -| top, .col = screen.cursor.col };
}

/// Returns parameter `index` (skipping sub-parameters), or `default` when absent or 0.
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
    /// Dispatches a parsed ESC sequence to `term` or its active screen.
    pub fn dispatch(comptime option: Option, term: *Terminal(option), final: u8, intermediates: []const u8) void {
        if (intermediates.len == 0) {
            switch (final) {
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
                else => {}, // unrecognized; ignore (ECMA-48)
            }
            return;
        }

        // ESC ( ) * + designate a 94-set, which may carry a second intermediate
        // (such as `"`, `%`, or `&`); `Set.designation94` validates the full slice.
        switch (intermediates[0]) {
            '(' => designate94(option, term, 0, intermediates, final),
            ')' => designate94(option, term, 1, intermediates, final),
            '*' => designate94(option, term, 2, intermediates, final),
            '+' => designate94(option, term, 3, intermediates, final),
            else => if (intermediates.len == 1) switch (intermediates[0]) {
                ' ' => switch (final) {
                    // S7C1T / switch output to 7-bit C1, does NOT change conformance_level
                    'F' => term.control_format = .s7c1t,
                    // S8C1T / switch output to 8-bit C1, does NOT change conformance_level
                    'G' => term.control_format = .s8c1t,
                    else => {},
                },
                '#' => switch (final) {
                    '3' => term.active().setLineAttr(.double_top), // DECDHL / ESC # 3
                    '4' => term.active().setLineAttr(.double_bottom), // DECDHL / ESC # 4
                    '5' => term.active().setLineAttr(.normal), // DECSWL / ESC # 5
                    '6' => term.active().setLineAttr(.double_width), // DECDWL / ESC # 6
                    '8' => term.active().decaln(), // DECALN / ESC # 8
                    else => {},
                },
                '%' => switch (final) {
                    '@' => term.input.encoding = .latin1, // ESC % @ (ISO Latin-1)
                    'G' => term.input.encoding = .utf8, // ESC % G (UTF-8 mode)
                    else => {},
                },
                '-' => designate96(option, term, 1, final),
                '.' => designate96(option, term, 2, final),
                '/' => designate96(option, term, 3, final),
                else => {}, // unrecognized; ignore (ECMA-48)
            },
        }
    }
};

fn designate94(comptime option: Option, term: *Terminal(option), slot: u2, intermediates: []const u8, final: u8) void {
    const level = term.conformance_level.number();
    const cs = Set.designation94(intermediates, final, level, term.mode.nrc) orelse return;
    term.active().designateCharset(slot, cs);
}

fn designate96(comptime option: Option, term: *Terminal(option), slot: u2, final: u8) void {
    const level = term.conformance_level.number();
    const cs = Set.designation96(final, level, term.mode.nrc) orelse return;
    term.active().designateCharset(slot, cs);
}

/// Handle C0 control characters (bytes 0x00–0x1F) and DEL (0x7F).
///
/// Called by the VT parser for bytes that are not part of an escape sequence.
/// Most C0 bytes are either ignored or map directly to a single Screen method.
pub const C0 = struct {
    /// Dispatches a C0/DEL or C1 single-byte control (`byte`) to `term`.
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
            0x8E => term.active().singleShift2(), // SS2 (C1)
            0x8F => term.active().singleShift3(), // SS3 (C1)
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
    /// Dispatches a parsed CSI sequence with intermediates and parameters to `terminal`.
    pub fn dispatch(
        comptime option: Option,
        terminal: *Terminal(option),
        final: u8,
        intermediates: []const u8,
        parameters: []const Parameter,
    ) void {
        const p1_0 = paramOr(parameters, 0, 0);
        const p1 = if (p1_0 > 0) p1_0 else 1;

        const p2_0 = paramOr(parameters, 1, 0);
        const p2 = if (p2_0 > 0) p2_0 else 1;

        // Resolved once per sequence. Cases that can switch screens
        // (DECSET 47/1047/1049, DECSTR) go through `terminal` instead.
        const screen = terminal.active();

        switch (intermediates.len) {
            0 => switch (final) {
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
                'J' => if (std.enums.fromInt(EraseDisplay, p1_0)) |mode| screen.eraseDisplay(mode), // ED / CSI Ps J
                'K' => if (std.enums.fromInt(EraseLine, p1_0)) |mode| screen.eraseLine(mode), // EL / CSI Ps K
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

                'g' => if (std.enums.fromInt(TabClear, p1_0)) |mode| screen.clearTabStop(mode), // TBC Ps g

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

                // SM / CSI Pm h, RM / CSI Pm l
                'h', 'l' => {
                    for (parameters) |*p| {
                        if (p.separator == .sub_parameter) continue;
                        if (std.enums.fromInt(AnsiMode, p.value)) |mode| {
                            terminal.setMode(mode, final == 'h');
                        }
                    }
                },

                // XTWINOPS / CSI Ps ; Ps t: only the title stack, 22 pushes and
                // 23 pops. xterm's third parameter (direct access to a slot) is
                // not supported, so a sequence with one does nothing.
                't' => if (parameters.len <= 2) switch (p1_0) {
                    22 => if (std.enums.fromInt(Title.Part, p2_0)) |part| terminal.pushTitle(part),
                    23 => if (std.enums.fromInt(Title.Part, p2_0)) |part| terminal.popTitle(part),
                    else => {},
                },

                else => {},
            },

            1 => switch (intermediates[0]) {
                ' ' => switch (final) {
                    'q' => terminal.setCursorStyle(p1_0), // DECSCUSR / CSI Ps SP q
                    else => {},
                },
                '!' => switch (final) {
                    'p' => terminal.softReset(), // DECSTR / CSI ! p
                    else => {},
                },
                '"' => switch (final) {
                    'p' => terminal.decscl(p1_0, p2_0), // DECSCL / CSI Ps ; Pc " p
                    else => {},
                },
                '$' => switch (final) {
                    // DECRQM / CSI Ps $ p (ANSI mode)
                    'p' => terminal.reply(.{ .mode_report = .{ .mode = p1_0, .state = terminal.ansiModeReport(p1_0) } }),
                    else => {},
                },
                '>' => switch (final) {
                    // DA2 / CSI > c
                    'c' => if (p1_0 == 0) terminal.reply(.secondary_attributes),
                    // XTMODKEYS / CSI > Pp ; Pv m. Only modifyOtherKeys (Pp 4) is
                    // implemented; no parameters resets every resource.
                    'm' => if (parameters.len == 0) {
                        terminal.setModifyOtherKeys(null);
                    } else if (p1_0 == 4) {
                        terminal.setModifyOtherKeys(if (parameters.len < 2) null else p2_0);
                    },
                    // CSI > Pp n disables a key modifier resource (xterm's -1);
                    // for modifyOtherKeys that is level 0.
                    'n' => if (p1_0 == 4) terminal.setModifyOtherKeys(null),
                    // XTVERSION / CSI > Ps q, Ps 0 only (`charproc.c`
                    // CASE_REPORT_VERSION). CSI > Ps p is xterm's XTSMPOINTER.
                    'q' => if (p1_0 == 0) terminal.xtversion(),
                    else => {},
                },
                '?' => switch (final) {
                    // DECSET / CSI ? Pm h, DECRST / CSI ? Pm l
                    'h', 'l' => {
                        for (parameters) |*p| {
                            if (p.separator == .sub_parameter) continue;
                            terminal.setDecMode(p.value, final == 'h');
                        }
                    },
                    // DEC DSR / CSI ? Ps n
                    'n' => switch (p1_0) {
                        6 => terminal.reply(.{ .dec_cursor_position = reportedPosition(option, screen) }), // DECXCPR
                        else => {},
                    },
                    // FIXME requires protected
                    // 'J' => terminal.active().selectiveEraseDisplay(p1_0), // DECSED
                    // 'K' => terminal.active().selectiveEraseLine(p1_0), // DECSEL
                    else => {},
                },
                else => {},
            },

            2 => if (intermediates[0] == '?' and intermediates[1] == '$' and final == 'p') {
                // DECRQM / CSI ? Ps $ p (DEC private mode)
                terminal.reply(.{ .dec_mode_report = .{ .mode = p1_0, .state = terminal.decModeReport(p1_0) } });
            },

            else => {},
        }
    }
};

pub const Osc = struct {
    /// Dispatches a parsed OSC `code` and payload slice to `term`.
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

            52 => {}, // only `52` without `;`: OSC 52 data goes to `Clipboard` (Terminal.oscPut)

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
