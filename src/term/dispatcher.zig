const std = @import("std");

const Parameter = @import("../vt/parser.zig").Parameter;
const Terminal = @import("term.zig").Terminal;
const Charset = @import("cell.zig").Charset;
const Option = @import("term.zig").Option;
const Palette = @import("palette.zig").Palette;
const Screen = @import("screen.zig").Screen;
// const ControlSequence = @import("parser.zig").ControlSequence;
// const EscapeSequence = @import("actions.zig").EscapeDispatch;
// const OscDispatch = @import("actions.zig").OscDispatch;
const sgr = @import("sgr.zig");

const seqIntroducer = @import("term.zig").seqIntroducer;

test {
    // FIXME!
    _ = @import("dispatcher_test.zig");
}

/// helper: get param value or default fallback, skipping sub-params
pub fn paramOr(params: []const Parameter, index: usize, default: u16) u16 {
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
        // std.debug.print("dispatch={f}key=0x{x}\n\n", .{ esc, key });

        switch (key) {
            '=' => term.mode.keypad_app = true, // DECKPAM
            '>' => term.mode.keypad_app = false, // DECKPNM
            '7' => term.active.saveCursor(), // DECSC
            '6' => {}, // DECBI (VT420); FIXME requires scrollRight
            '8' => term.active.restoreCursor(), // DECRC
            '9' => {}, // DECFI (VT420); FIXME requires scrollLeft
            'D' => term.active.index(), // IND
            'E' => { // NEL (CR + LF)
                term.active.index();
                term.active.cursor.col = 0;
                term.active.cursor.wrap_pending = false;
            },
            'H' => term.active.setTabStop(), // HTS
            'M' => term.active.reverseIndex(), // RI
            'N' => term.active.singleShift2(), // SS2
            'O' => term.active.singleShift3(), // SS3
            'Z' => {
                // FIXME obsolete CSI 0 C
                // (see details)[https://invisible-island.net/xterm/manpage/xterm.html#VT100-Widget-Resources:decTerminalID]
                // const prefix = term.parser.csiPrefix();
                term.events.response.append("\x1b[?1;2c"); // DECID: DA1 response
            },

            'c' => term.hardReset(), // RIS

            'n' => term.active.lockingShift(2, .gl), // LS2: GL = G2
            'o' => term.active.lockingShift(3, .gl), // LS3: GL = G3
            '~' => term.active.lockingShift(1, .gr), // LS1R: GR = G1
            '}' => term.active.lockingShift(2, .gr), // LS2R: GR = G2
            '|' => term.active.lockingShift(3, .gr), // LS3R: GR = G3

            // DECSCL | ESC [ level ; control-format " p

            // S7C1T / switch output to 7-bit C1, does NOT change conformance_level
            0x2046 => term.control_format = .s7c1t,

            // S8C1T / switch output to 8-bit C1, does NOT change conformance_level
            0x2047 => term.control_format = .s8c1t,

            // ESC # (0x23) DEC screen operations (VT100)
            0x2333 => term.active.setLineAttr(.double_top), // DECDHL / ESC # 3
            0x2334 => term.active.setLineAttr(.double_bottom), // DECDHL / ESC # 4
            0x2335 => term.active.setLineAttr(.normal), // DECSWL /  ESC # 5
            0x2336 => term.active.setLineAttr(.double_width), // DECDWL / ESC # 6
            0x2338 => term.active.decaln(), // DECALN / ESC # 8

            0x2540 => term.encoding = .latin1, // ESC % @ (ISO Latin-1)
            0x2547 => term.encoding = .utf8, // ESC % G (UTF-8 mode)

            // ESC ( ) * + Charset designation
            0x2800...0x28FF => term.active.designateCharset(0, Charset.charsetFromByte(final)),
            0x2900...0x29FF => term.active.designateCharset(1, Charset.charsetFromByte(final)),
            0x2A00...0x2AFF => term.active.designateCharset(2, Charset.charsetFromByte(final)),
            0x2B00...0x2BFF => term.active.designateCharset(3, Charset.charsetFromByte(final)),

            // - . / : Designate G1/G2/G3 96-character sets (VT300)
            0x2D00...0x2DFF => term.active.designateCharset(1, Charset.charsetFromByte96(final)),
            0x2E00...0x2EFF => term.active.designateCharset(2, Charset.charsetFromByte96(final)),
            0x2F00...0x2FFF => term.active.designateCharset(3, Charset.charsetFromByte96(final)),

            else => {
                // escape control sequences that need > 1 intermediates
                // ESC ( " > (DEC Greek)
                // ESC ( % 2 (Turkish) have two intermediate bytes — ( and "
                // multi-byte-intermediate charset (VT500 Greek/Turkish/Hebrew)

                // otherwise, unrecognized; silently ignore per ECMA-48 S6.6
                // std.debug.print("unhandled dispatch={f}key=0x{x}\n\n", .{ esc, key });
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
        // std.debug.print("c0: {x}\n", .{byte});
        switch (byte) {
            0x00 => {}, // NUL
            0x05 => term.events.response.append(term.getAnswerback()), // ENQ
            0x07 => { // BEL
                if (!term.events.bell) term.events.bell = true;
            },
            0x08 => term.active.cursorLeft(1), // BS
            0x09 => term.active.tabForward(1), // HT
            0x0A, 0x0B, 0x0C => { // LF, VT, FF
                term.active.index();
                if (term.mode.linefeed) {
                    term.active.cursor.col = 0;
                    term.active.cursor.wrap_pending = false;
                }
            },
            0x0D => { // CR
                term.active.cursor.col = 0;
                term.active.cursor.wrap_pending = false;
                term.active.markDirty(term.active.cursor.row);
            },
            0x0E => term.active.shiftOut(), // SO | GL = G1
            0x0F => term.active.shiftIn(), // SI | GL = G0
            0x18, 0x1A => term.utf8_decoder.reset(),
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

        // std.debug.print("CSI final={x}'{c}' key={x}\n", .{ final, final, key });
        var buf: [32]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);

        const control_format = terminal.control_format;
        const prefix = seqIntroducer(.csi, control_format);

        switch (key) {
            's' => terminal.active.saveCursor(), // ANSI SC / CSI s
            'u' => terminal.active.restoreCursor(), // ANSI RC / CSI u

            // Cursor Movement
            'A' => terminal.active.cursorUp(p1), // CUU / CSI Ps A
            'B' => terminal.active.cursorDown(p1), // CUD / CSI Ps B
            'C' => terminal.active.cursorRight(p1), // CUF / CSI Ps C
            'D' => terminal.active.cursorLeft(p1), // CUB / CSI Ps D

            'E' => {
                // CNL / CSI Ps E (down N, column 0)
                // cursorUp clears `wrap_pending`.
                terminal.active.cursorDown(p1);
                terminal.active.cursor.col = 0;
            },

            'F' => {
                // CPL / CSI Ps F (up N, column 0)
                terminal.active.cursorUp(p1);
                terminal.active.cursor.col = 0; // cursorUp clears `wrap_pending`.
            },

            'G' => terminal.active.cursorCol(p1 -| 1), // CHA / CSI Ps G
            'H' => terminal.active.cursorPos(p1 -| 1, p2 -| 1), // CUP / CSI Ps ; Ps H
            'f' => terminal.active.cursorPos(p1 -| 1, p2 -| 1), // HVP / CSI Ps ; Ps f
            'I' => terminal.active.tabForward(p1), // CHT / CSI Ps I
            'J' => terminal.active.eraseDisplay(p1_0), // ED / CSI Ps J
            'K' => terminal.active.eraseLine(p1_0), // EL / CSI Ps K
            'X' => terminal.active.eraseChars(p1), // ECH / CSI Ps X

            '@' => terminal.active.insertChars(p1), // ICH / CSI Ps @
            'P' => terminal.active.deleteChars(p1), // DCH / CSI Ps P
            'L' => terminal.active.insertLines(p1), // IL / CSI Ps L
            'M' => terminal.active.deleteLines(p1), // DL / CSI Ps M

            'S' => terminal.active.scrollUp(p1), // SU / CSI Ps S
            'T' => terminal.active.scrollDown(p1), // SD / CSI Ps T
            'Z' => terminal.active.tabBackward(p1), // CBT / CSI Ps Z

            'a' => terminal.active.cursorRight(p1), // HPR / CSI Ps a
            'b' => terminal.active.repeatChar(p1), // REP / CSI Ps b
            'c' => {
                switch (p1_0) {
                    // claim vt220 with color ansi, xterm compatibile (52)
                    0 => {
                        // terminal.events.response.print("{s}?{d};{d};{d}c", .{ prefix, 62, 22, 52 });
                        terminal.events.response.append(prefix);
                        terminal.events.response.append("?"); // if your escape starts with ?
                        terminal.events.response.appendInt(62); // write integer as ASCII
                        terminal.events.response.append(";"); // separator
                        terminal.events.response.appendInt(22);
                        terminal.events.response.append(";");
                        terminal.events.response.appendInt(52);
                        terminal.events.response.append("c"); // final char
                    },
                    else => {},
                }
            },

            'm' => {
                sgr.parse(option, terminal, parameters); // SGR / CSI Ps m;
            },

            // VPA — Vertical Position Absolute (CSI Ps d): 1-based row, ignores DECOM
            'd' => terminal.active.cursorRow(p1 -| 1),

            'e' => terminal.active.cursorDown(p1), // VPR / CSI Ps e
            '`' => terminal.active.cursorCol(p1 -| 1), // HPA / CSI Ps `

            'g' => terminal.active.clearTabStop(p1_0), // TBC Ps g

            'r' => {
                // DECSTBM
                // std.debug.print("DECSTBM: p1_0={} p1_1={} p2_0={}\n", .{ p1_0, p1, p2_0 });
                terminal.active.setScrollRegion(p1_0, p2_0);
            },

            'n' => {
                switch (p1_0) {
                    5 => terminal.events.response.append("\x1b[0n"),
                    6 => {
                        // DSR / CSI Ps n
                        // CPR: report 1-based absolute position.
                        // When DECOM is active, xterm still reports absolute (not relative
                        // to scroll region). Match xterm behavior.

                        // terminal.events.response.print("{s}{d};{d}R", .{
                        //     prefix,
                        //     terminal.active.cursor.row + 1,
                        //     terminal.active.cursor.col + 1,
                        // });

                        w.print("{s}{d};{d}R", .{
                            prefix,
                            terminal.active.cursor.row + 1,
                            terminal.active.cursor.col + 1,
                        }) catch {};
                        terminal.events.response.append(buf[0..w.end]);

                        // terminal.events.response.append(prefix);
                        // terminal.events.response.appendInt(@intCast(terminal.active.cursor.row + 1));
                        // terminal.events.response.append(";");
                        // terminal.events.response.appendInt(@intCast(terminal.active.cursor.col + 1));
                        // terminal.events.response.append("R");
                    },
                    else => {},
                }
            },

            0x0068, 0x006c => {
                // SM / CSI Pm h
                // RM / CSI Pm l
                for (parameters) |*p| {
                    if (p.separator == .sub_parameter) continue;
                    terminal.setMode(p.value, key == 0x68);
                }
            },

            0x3E63 => { // DA2 / CSI > Ps c
                switch (p1_0) {
                    0 => {
                        terminal.events.response.append(prefix);
                        terminal.events.response.append(">");
                        terminal.events.response.appendInt(1);
                        terminal.events.response.append(";");
                        terminal.events.response.appendInt(0);
                        terminal.events.response.append(";");
                        terminal.events.response.appendInt(0);
                        terminal.events.response.append("c");
                    },
                    else => {},
                }
            },

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

            0x3F6E => {
                // Device Status Report (DSR, DEC-specific) / CSI ? Ps n
                switch (p1_0) {
                    6 => {
                        // terminal.events.response.print("{s}?{d};{d}R", .{
                        //     prefix,
                        //     terminal.active.cursor.row + 1,
                        //     terminal.active.cursor.col + 1,
                        // });
                        // terminal.events.response.append(prefix);
                        // terminal.events.response.append("?");
                        // terminal.events.response.appendInt(@intCast(terminal.active.cursor.row + 1));
                        // terminal.events.response.append(";");
                        // terminal.events.response.appendInt(@intCast(terminal.active.cursor.col + 1));
                        // terminal.events.response.append("R");

                        w.print("{s}{d};{d}R", .{
                            prefix,
                            terminal.active.cursor.row + 1,
                            terminal.active.cursor.col + 1,
                        }) catch {};
                        terminal.events.response.append(buf[0..w.end]);
                    },
                    else => {},
                }
            },

            // FIXME requires protected
            // 0x3F4A => term.active.selectiveEraseDisplay(p1_0), // DECSED
            // 0x3F4B => term.active.selectiveEraseLine(p1_0), // DECSEL

            else => {}, // std.debug.print("unhandled dispatch={f}key=0x{x}\n\n", .{ sequence, key }),

        }
    }
};

pub const Osc = struct {
    pub fn dispatch(comptime option: Option, term: *Terminal(option), code: u16, data: []const u8) void {
        // std.debug.print("OSC code={} data={s}\n", .{ code, data });

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
            110 => term.active.palette.set(.foreground, null),

            // OSC 111 — Reset default background color
            111 => term.active.palette.set(.background, null),

            // OSC 112 — Reset default cursor color
            112 => term.cursor_color = null,

            else => {}, //std.debug.print("unhandled dispatch={f}\n", .{sequence}),
        }
    }
};