//! The xterm key encoder over GLFW key codes. Temporary: ADR 0007 replaces
//! it with an encoder over `input.Key` in `src/input/`.

const std = @import("std");

const c = @import("glfw");

/// Terminal modes relevant to key encoding
pub const KeyContext = struct {
    /// 0 = off
    /// 1 = partial
    /// 2 = full
    modify_other_keys: u2 = 0,
    /// DECCKM | application cursor keys (SS3 vs CSI)
    cursor_keys: bool = false,
    /// DECKPAM | application keypad
    keypad_app: bool = false,
};

/// Compute the xterm 1-based modifier number from GLFW mods.
///  1 = No mods
///  2 = Shift
///  3 = Alt
///  4 = Shift+Alt
///  5 = Ctrl
///  6 = Shift+Ctrl
///  7 = Alt+Ctrl
///  8 = Shift+Alt+Ctrl
inline fn modNum(mods: c_int) u8 {
    var m: u8 = 0;
    if (mods & c.GLFW_MOD_SHIFT != 0) m |= 1;
    if (mods & c.GLFW_MOD_ALT != 0) m |= 2;
    if (mods & c.GLFW_MOD_CONTROL != 0) m |= 4;
    if (mods & c.GLFW_MOD_SUPER != 0) m |= 8;
    return m + 1;
}

const mods_mask = c.GLFW_MOD_SHIFT | c.GLFW_MOD_ALT | c.GLFW_MOD_CONTROL | c.GLFW_MOD_SUPER;

inline fn hasMod(mods: c_int) bool {
    return mods & (mods_mask) != 0;
}

/// The control code xterm sends for Ctrl+`digit` on a US layout, where
/// 2 to 8 stand for @, [, \, ], ^, _ and ?. Other digits have none.
fn ctrlDigit(digit: u8) ?u8 {
    return switch (digit) {
        '2' => 0x00, // NUL, Ctrl+@
        '3' => 0x1b, // ESC, Ctrl+[
        '4' => 0x1c, // FS, Ctrl+\
        '5' => 0x1d, // GS, Ctrl+]
        '6' => 0x1e, // RS, Ctrl+^
        '7' => 0x1f, // US, Ctrl+_
        '8' => 0x7f, // DEL, Ctrl+?
        else => null,
    };
}

/// Format [CSI num ~] | [CSI num ; mod ~]
fn fmtTilde(buf: *[32]u8, num: u16, mod: u8) []const u8 {
    if (mod <= 1) return std.fmt.bufPrint(buf, "\x1b[{d}~", .{num}) catch "";
    return std.fmt.bufPrint(buf, "\x1b[{d};{d}~", .{ num, mod }) catch "";
}

/// Format [CSI letter] | [CSI 1 ; mod letter]  (arrows, Home, End)
fn fmtCsi1(buf: *[32]u8, letter: u8, mod: u8) []const u8 {
    if (mod <= 1) {
        buf[0] = 0x1b;
        buf[1] = '[';
        buf[2] = letter;
        return buf[0..3];
    }
    return std.fmt.bufPrint(buf, "\x1b[1;{d}{c}", .{ mod, letter }) catch "";
}

/// Format SS3 letter  (application cursor / F1-F4 without modifier)
fn fmtSs3(buf: *[32]u8, letter: u8) []const u8 {
    buf[0] = 0x1b;
    buf[1] = 'O';
    buf[2] = letter;
    return buf[0..3];
}

/// Format CSI 27 ; mod ; codepoint ~  (modifyOtherKeys level 1/2)
fn fmtMok(buf: *[32]u8, mod: u8, cp: u21) []const u8 {
    return std.fmt.bufPrint(buf, "\x1b[27;{d};{d}~", .{ mod, cp }) catch "";
}

// modifyOtherKeys, ported from xterm 412 `input.c` (ModifyOtherKeys,
// allowedCharModifiers, filterAltMeta and the check in Input) with xterm's
// default resources: metaSendsEscape off, Alt reported as Alt (3), no
// modifier ignored, DECBKM reset (Backspace sends DEL), a US layout, and
// the CSI 27 ; mod ; code ~ format (formatOtherKeys 0). Super is not a
// modifier here. Level 3 and up are not supported.

/// Shift, Alt and Ctrl as xterm's state bits; the parameter is 1 + bits.
const ModState = packed struct(u3) {
    shift: bool = false,
    alt: bool = false,
    ctrl: bool = false,

    const none: ModState = .{};

    fn bits(self: ModState) u3 {
        return @bitCast(self);
    }

    /// xtermStateToParam: 0 without modifiers, else 1 + Shift + 2 Alt + 4 Ctrl.
    fn param(self: ModState) u8 {
        return if (self.bits() == 0) 0 else @as(u8, self.bits()) + 1;
    }

    fn without(self: ModState, mask: ModState) ModState {
        return @bitCast(self.bits() & ~mask.bits());
    }
};

/// The X keysym of a key xterm counts as ordinary: an ASCII character
/// after Shift (US layout), or one of the predefined keys between
/// ISO_Lock and Delete. `delete` is Backspace after the backarrow toggle.
const OtherKey = union(enum) {
    char: u8,
    backspace,
    delete,
    tab,
    left_tab,
    enter,
    escape,

    fn isPredefined(self: OtherKey) bool {
        return self != .char;
    }

    /// IsControlInput: a keysym from 0x40 to 0x7f.
    fn isControlInput(self: OtherKey) bool {
        return switch (self) {
            .char => |ch| ch >= 0x40 and ch <= 0x7f,
            else => false,
        };
    }

    /// The one byte XLookupString gives for the key, with Xlib's Ctrl
    /// conversion for characters (`_XTranslateKeySym`).
    fn byte(self: OtherKey, ctrl: bool) u8 {
        return switch (self) {
            .char => |ch| if (!ctrl) ch else switch (ch) {
                '@'...'~', ' ' => ch & 0x1f,
                '2' => 0x00,
                '3'...'7' => ch - ('3' - 0x1b),
                '8' => 0x7f,
                '/' => '_' & 0x1f,
                else => ch,
            },
            .backspace => 0x08,
            .delete => 0x7f,
            .tab, .left_tab => '\t',
            .enter => '\r',
            .escape => 0x1b,
        };
    }

    /// IsControlAlias: the key's byte is a control character (IS_CTRL).
    fn isControlAlias(self: OtherKey, ctrl: bool) bool {
        const b = self.byte(ctrl);
        return b < 0x20 or (b >= 0x7f and b <= 0x9f);
    }
};

/// allowedCharModifiers: at levels 0 and 1 drop the modifiers a key's
/// usual byte already carries, then a bare Alt (filterAltMeta).
fn allowedModifiers(level: u2, state: ModState, key: OtherKey, ctrl_held: bool) ModState {
    var result = state;
    if (level <= 1) {
        if (key.isControlInput() and result.without(.{ .ctrl = true }).bits() == 0) {
            if (level == 0) result.ctrl = false;
        } else if (key == .tab or key == .enter) {
            // kept
        } else if (key.isControlAlias(ctrl_held)) {
            if (result.without(.{ .ctrl = true, .shift = true }).bits() == 0) result = .none;
        } else if (!key.isPredefined()) {
            if (!result.ctrl) result.shift = false;
        }
        if (result.alt and result.without(.{ .alt = true }).bits() == 0) result.alt = false;
    }
    return result;
}

/// ModifyOtherKeys: whether the key is sent as CSI 27 ; mod ; code ~.
/// May turn `key` from Backspace into Delete (the backarrow toggle).
fn modifiesOtherKey(level: u2, event: ModState, key: *OtherKey) bool {
    const modify_parm = event.param();
    if (modify_parm == 0) return false;
    var state = event;
    if (key.* == .backspace and !state.ctrl) key.* = .delete;
    if (!key.isPredefined()) state = allowedModifiers(level, state, key.*, event.ctrl);
    if (state.bits() == 0) return false;

    return switch (level) {
        0, 3 => false,
        1 => switch (key.*) {
            .backspace, .delete => false,
            .left_tab => state.without(.{ .shift = true }).param() != 0,
            .enter, .tab => true,
            else => if (key.isControlInput())
                !(std.meta.eql(state, ModState{ .ctrl = true }) or std.meta.eql(state, ModState{ .shift = true }))
            else if (key.isControlAlias(event.ctrl))
                !std.meta.eql(state, ModState{ .shift = true }) and state.without(.{ .ctrl = true }).param() != 0
            else
                true,
        },
        2 => switch (key.*) {
            .backspace => state.without(.{ .ctrl = true }).param() != 0,
            .delete => state.param() != 0,
            .left_tab => state.without(.{ .shift = true }).param() != 0,
            .escape, .enter, .tab => true,
            .char => |ch| key.isControlInput() or
                (std.meta.eql(state, ModState{ .shift = true }) and ch == ' ') or
                state.without(.{ .shift = true }).param() != 0,
        },
    };
}

/// The CSI 27 ; mod ; code ~ fields xterm sends for `key`, or null when
/// the key goes out its usual way. The code is the keysym when it is
/// below 256, else the key's byte.
fn otherKeyReport(level: u2, event: ModState, key_in: OtherKey) ?struct { param: u8, code: u8 } {
    var key = key_in;
    if (!modifiesOtherKey(level, event, &key)) return null;
    const state = allowedModifiers(level, event, key, event.ctrl);
    if (state.bits() == 0) return null;
    const code = switch (key) {
        .char => |ch| ch,
        else => key.byte(event.ctrl),
    };
    return .{ .param = state.param(), .code = code };
}

/// The unshifted and shifted ASCII characters of a key on a US layout.
fn usLayout(key: c_int) ?[2]u8 {
    return switch (key) {
        c.GLFW_KEY_A...c.GLFW_KEY_Z => .{ @intCast('a' + (key - c.GLFW_KEY_A)), @intCast('A' + (key - c.GLFW_KEY_A)) },
        c.GLFW_KEY_0...c.GLFW_KEY_9 => .{ @intCast('0' + (key - c.GLFW_KEY_0)), ")!@#$%^&*("[@intCast(key - c.GLFW_KEY_0)] },
        c.GLFW_KEY_SPACE => .{ ' ', ' ' },
        c.GLFW_KEY_APOSTROPHE => .{ '\'', '"' },
        c.GLFW_KEY_COMMA => .{ ',', '<' },
        c.GLFW_KEY_MINUS => .{ '-', '_' },
        c.GLFW_KEY_PERIOD => .{ '.', '>' },
        c.GLFW_KEY_SLASH => .{ '/', '?' },
        c.GLFW_KEY_SEMICOLON => .{ ';', ':' },
        c.GLFW_KEY_EQUAL => .{ '=', '+' },
        c.GLFW_KEY_LEFT_BRACKET => .{ '[', '{' },
        c.GLFW_KEY_BACKSLASH => .{ '\\', '|' },
        c.GLFW_KEY_RIGHT_BRACKET => .{ ']', '}' },
        c.GLFW_KEY_GRAVE_ACCENT => .{ '`', '~' },
        else => null,
    };
}

/// The modifyOtherKeys sequence for `key`, or null when it is not an
/// ordinary key or xterm would send it the usual way.
fn encodeOtherKey(level: u2, key: c_int, mods: c_int, buf: *[32]u8) ?[]const u8 {
    if (mods & c.GLFW_MOD_SUPER != 0) return null;
    const event: ModState = .{
        .shift = mods & c.GLFW_MOD_SHIFT != 0,
        .alt = mods & c.GLFW_MOD_ALT != 0,
        .ctrl = mods & c.GLFW_MOD_CONTROL != 0,
    };
    const other: OtherKey = switch (key) {
        c.GLFW_KEY_BACKSPACE => .backspace,
        c.GLFW_KEY_TAB => if (event.shift) .left_tab else .tab,
        c.GLFW_KEY_ENTER => .enter,
        c.GLFW_KEY_ESCAPE => .escape,
        else => .{ .char = (usLayout(key) orelse return null)[@intFromBool(event.shift)] },
    };
    const report = otherKeyReport(level, event, other) orelse return null;
    return fmtMok(buf, report.param, report.code);
}

/// Encode a GLFW key event into a terminal escape sequence.
///
/// Returns a slice into `buf` or a string literal, never allocates.
/// Returns "" when the key should be handled by the char callback instead
/// (i.e. plain printable with no Ctrl/Alt modifier).
pub inline fn encodeKey(
    key: c_int,
    mods: c_int,
    ctx: KeyContext,
    buf: *[32]u8,
) []const u8 {
    const shift = mods & c.GLFW_MOD_SHIFT != 0;
    const ctrl = mods & c.GLFW_MOD_CONTROL != 0;
    const alt = mods & c.GLFW_MOD_ALT != 0;
    const mod = modNum(mods);
    const has = hasMod(mods);
    if (ctx.modify_other_keys != 0) {
        if (encodeOtherKey(ctx.modify_other_keys, key, mods, buf)) |seq| return seq;
    }

    return switch (key) {
        // Arrow keys
        c.GLFW_KEY_UP => if (!has) (if (ctx.cursor_keys) fmtSs3(buf, 'A') else fmtCsi1(buf, 'A', 1)) else fmtCsi1(buf, 'A', mod),
        c.GLFW_KEY_DOWN => if (!has) (if (ctx.cursor_keys) fmtSs3(buf, 'B') else fmtCsi1(buf, 'B', 1)) else fmtCsi1(buf, 'B', mod),
        c.GLFW_KEY_RIGHT => if (!has) (if (ctx.cursor_keys) fmtSs3(buf, 'C') else fmtCsi1(buf, 'C', 1)) else fmtCsi1(buf, 'C', mod),
        c.GLFW_KEY_LEFT => if (!has) (if (ctx.cursor_keys) fmtSs3(buf, 'D') else fmtCsi1(buf, 'D', 1)) else fmtCsi1(buf, 'D', mod),

        // Function keys
        // F1-F4: SS3 P/Q/R/S without modifier, CSI 1;mod P/Q/R/S with modifier
        c.GLFW_KEY_F1 => if (!has) fmtSs3(buf, 'P') else std.fmt.bufPrint(buf, "\x1b[1;{d}P", .{mod}) catch "",
        c.GLFW_KEY_F2 => if (!has) fmtSs3(buf, 'Q') else std.fmt.bufPrint(buf, "\x1b[1;{d}Q", .{mod}) catch "",
        c.GLFW_KEY_F3 => if (!has) fmtSs3(buf, 'R') else std.fmt.bufPrint(buf, "\x1b[1;{d}R", .{mod}) catch "",
        c.GLFW_KEY_F4 => if (!has) fmtSs3(buf, 'S') else std.fmt.bufPrint(buf, "\x1b[1;{d}S", .{mod}) catch "",
        // F5-F12: CSI num ~
        c.GLFW_KEY_F5 => return fmtTilde(buf, 15, if (has) mod else 1),
        c.GLFW_KEY_F6 => return fmtTilde(buf, 17, if (has) mod else 1),
        c.GLFW_KEY_F7 => return fmtTilde(buf, 18, if (has) mod else 1),
        c.GLFW_KEY_F8 => return fmtTilde(buf, 19, if (has) mod else 1),
        c.GLFW_KEY_F9 => return fmtTilde(buf, 20, if (has) mod else 1),
        c.GLFW_KEY_F10 => return fmtTilde(buf, 21, if (has) mod else 1),
        c.GLFW_KEY_F11 => return fmtTilde(buf, 23, if (has) mod else 1),
        c.GLFW_KEY_F12 => return fmtTilde(buf, 24, if (has) mod else 1),

        // Navigation
        c.GLFW_KEY_HOME => return fmtCsi1(buf, 'H', if (has) mod else 1),
        c.GLFW_KEY_END => return fmtCsi1(buf, 'F', if (has) mod else 1),
        c.GLFW_KEY_INSERT => return fmtTilde(buf, 2, if (has) mod else 1),
        c.GLFW_KEY_DELETE => return fmtTilde(buf, 3, if (has) mod else 1),
        c.GLFW_KEY_PAGE_UP => return fmtTilde(buf, 5, if (has) mod else 1),
        c.GLFW_KEY_PAGE_DOWN => return fmtTilde(buf, 6, if (has) mod else 1),

        // Enter <CR>
        c.GLFW_KEY_ENTER, c.GLFW_KEY_KP_ENTER => {
            if (alt) {
                buf[0] = 0x1b;
                buf[1] = '\r';
                return buf[0..2];
            }
            return "\r";
        },

        // Backspace
        c.GLFW_KEY_BACKSPACE => {
            if (ctrl) return "\x08";
            if (alt) {
                buf[0] = 0x1b;
                buf[1] = 0x7f;
                return buf[0..2];
            }
            return "\x7f";
        },

        // Tab
        c.GLFW_KEY_TAB => {
            if (shift) return "\x1b[Z"; // Shift+Tab = backtab (always)
            if (alt) {
                buf[0] = 0x1b;
                buf[1] = '\t';
                return buf[0..2];
            }
            return "\t";
        },

        // Escape
        c.GLFW_KEY_ESCAPE => {
            return "\x1b";
        },

        // Space
        c.GLFW_KEY_SPACE => {
            if (ctrl) return "\x00"; // Ctrl+Space = NUL
            if (alt) {
                buf[0] = 0x1b;
                buf[1] = ' ';
                return buf[0..2];
            }
            return ""; // let char callback handle plain space
        },

        // Letters [A-Z]
        c.GLFW_KEY_A...c.GLFW_KEY_Z => {
            const lower: u8 = @intCast('a' + (key - c.GLFW_KEY_A));
            const upper: u8 = @intCast('A' + (key - c.GLFW_KEY_A));
            const ctrl_code: u8 = @intCast(key - c.GLFW_KEY_A + 1);

            if (ctrl) {
                // standard: Alt+Ctrl+letter sends ESC + ^letter
                if (alt) {
                    buf[0] = 0x1b;
                    buf[1] = ctrl_code;
                    return buf[0..2];
                }
                // standard: Ctrl+letter sends ^letter
                buf[0] = ctrl_code;
                return buf[0..1];
            }

            if (alt) {
                // standard: Alt+letter sends ESC + letter
                buf[0] = 0x1b;
                buf[1] = if (shift) upper else lower;
                return buf[0..2];
            }

            // plain letter or Shift+letter: let char callback handle
            return "";
        },

        // Digits [0-9]
        c.GLFW_KEY_0...c.GLFW_KEY_9 => {
            const digit: u8 = @intCast('0' + (key - c.GLFW_KEY_0));
            if (ctrl or alt) {
                // As in xterm on a US layout, with ESC first when Alt is held.
                if (ctrl) if (ctrlDigit(digit)) |code| {
                    if (!alt) {
                        buf[0] = code;
                        return buf[0..1];
                    }
                    buf[0] = 0x1b;
                    buf[1] = code;
                    return buf[0..2];
                };
                if (alt) {
                    buf[0] = 0x1b;
                    buf[1] = digit;
                    return buf[0..2];
                }
            }
            return ""; // let char callback handle
        },

        // Keypad
        c.GLFW_KEY_KP_0...c.GLFW_KEY_KP_9 => {
            if (ctx.keypad_app) {
                const letter: u8 = @intCast('p' + (key - c.GLFW_KEY_KP_0));
                return fmtSs3(buf, letter);
            }
            return ""; // let char callback handle digit
        },

        // Outside keypad application mode the char callback sends these.
        c.GLFW_KEY_KP_DECIMAL => if (ctx.keypad_app) fmtSs3(buf, 'n') else "",
        c.GLFW_KEY_KP_DIVIDE => if (ctx.keypad_app) fmtSs3(buf, 'o') else "",
        c.GLFW_KEY_KP_MULTIPLY => if (ctx.keypad_app) fmtSs3(buf, 'j') else "",
        c.GLFW_KEY_KP_SUBTRACT => if (ctx.keypad_app) fmtSs3(buf, 'm') else "",
        c.GLFW_KEY_KP_ADD => if (ctx.keypad_app) fmtSs3(buf, 'k') else "",
        c.GLFW_KEY_KP_EQUAL => if (ctx.keypad_app) fmtSs3(buf, 'X') else "",

        // Ctrl+punctuation

        c.GLFW_KEY_LEFT_BRACKET => {
            if (ctrl) { // Ctrl+[ = ESC
                buf[0] = 0x1b;
                return buf[0..1];
            }

            if (alt) {
                buf[0] = 0x1b;
                buf[1] = '[';
                return buf[0..2];
            }

            return "";
        },
        c.GLFW_KEY_BACKSLASH => {
            if (ctrl) {
                buf[0] = 0x1c;
                return buf[0..1];
            } // Ctrl+\ = FS (SIGQUIT)
            if (alt) {
                buf[0] = 0x1b;
                buf[1] = '\\';
                return buf[0..2];
            }
            return "";
        },
        c.GLFW_KEY_RIGHT_BRACKET => {
            if (ctrl) {
                buf[0] = 0x1d;
                return buf[0..1];
            } // Ctrl+] = GS
            if (alt) {
                buf[0] = 0x1b;
                buf[1] = ']';
                return buf[0..2];
            }
            return "";
        },
        c.GLFW_KEY_GRAVE_ACCENT => {
            if (ctrl) {
                buf[0] = 0x00;
                return buf[0..1];
            } // Ctrl+` = NUL, as in xterm
            if (alt) {
                buf[0] = 0x1b;
                buf[1] = '`';
                return buf[0..2];
            }
            return "";
        },
        c.GLFW_KEY_MINUS => {
            if (ctrl) {
                buf[0] = 0x1f;
                return buf[0..1];
            } // Ctrl+- = US
            if (alt) {
                buf[0] = 0x1b;
                buf[1] = '-';
                return buf[0..2];
            }
            return "";
        },
        c.GLFW_KEY_SLASH => {
            if (ctrl) {
                buf[0] = 0x1f;
                return buf[0..1];
            } // Ctrl+/ = US (same as Ctrl+-)
            if (alt) {
                buf[0] = 0x1b;
                buf[1] = '/';
                return buf[0..2];
            }
            return "";
        },

        else => return "",
    };
}
