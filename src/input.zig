//! GLFW key and mouse input: key bindings and xterm key encoding.

const std = @import("std");

const c = @import("glfw");

/// Returns whether `key` is one of GLFW's left or right modifier keys.
///
/// This includes Shift, Control, Alt, and Super. Lock keys such as Caps Lock
/// and Num Lock are not considered modifiers by this function.
pub fn isModifierKey(key: c_int) bool {
    return switch (key) {
        c.GLFW_KEY_LEFT_SHIFT,
        c.GLFW_KEY_RIGHT_SHIFT,
        c.GLFW_KEY_LEFT_CONTROL,
        c.GLFW_KEY_RIGHT_CONTROL,
        c.GLFW_KEY_LEFT_ALT,
        c.GLFW_KEY_RIGHT_ALT,
        c.GLFW_KEY_LEFT_SUPER,
        c.GLFW_KEY_RIGHT_SUPER,
        => true,
        else => false,
    };
}

pub fn glfwModsToMouseMods(mods: c_int) u8 {
    var m: u8 = 0;
    if (mods & c.GLFW_MOD_SHIFT != 0) m |= 4;
    if (mods & c.GLFW_MOD_ALT != 0) m |= 8;
    if (mods & c.GLFW_MOD_CONTROL != 0) m |= 16;
    return m;
}

pub const Action = union(enum) {
    copy_selection,
    paste_clipboard,
    increase_font_size,
    decrease_font_size,
    reset_font_size,
    new_window,

    // Pomodoro
    pomodoro_toggle, // start / pause / resume
    pomodoro_reset, // restart current session from scratch
    pomodoro_skip, // skip to next phase (work to break or break to work)
    pomodoro_auto_transition, // transition to the next phase

    scroll_up,
    scroll_down,

    // global debugging stats, option, etc.
    debug,

    send_to_pty: []const u8, // for custom sequences
};

pub const Binding = struct {
    key: c_int,
    mods: c_int,
    action: Action,
};

pub const default_keymap: []const Binding = &.{
    Binding{ .key = c.GLFW_KEY_0, .mods = c.GLFW_MOD_CONTROL, .action = .reset_font_size },
    Binding{ .key = c.GLFW_KEY_A, .mods = c.GLFW_MOD_CONTROL | c.GLFW_MOD_SHIFT, .action = .pomodoro_auto_transition },
    Binding{ .key = c.GLFW_KEY_BACKSPACE, .mods = c.GLFW_MOD_CONTROL | c.GLFW_MOD_SHIFT, .action = .pomodoro_reset },
    Binding{ .key = c.GLFW_KEY_C, .mods = c.GLFW_MOD_CONTROL | c.GLFW_MOD_SHIFT, .action = .copy_selection },
    Binding{ .key = c.GLFW_KEY_EQUAL, .mods = c.GLFW_MOD_CONTROL, .action = .increase_font_size },
    Binding{ .key = c.GLFW_KEY_F6, .mods = c.GLFW_MOD_CONTROL | c.GLFW_MOD_SHIFT, .action = .debug },
    Binding{ .key = c.GLFW_KEY_J, .mods = c.GLFW_MOD_CONTROL | c.GLFW_MOD_SHIFT, .action = .scroll_down },
    Binding{ .key = c.GLFW_KEY_K, .mods = c.GLFW_MOD_CONTROL | c.GLFW_MOD_SHIFT, .action = .scroll_up },
    Binding{ .key = c.GLFW_KEY_MINUS, .mods = c.GLFW_MOD_CONTROL, .action = .decrease_font_size },
    Binding{ .key = c.GLFW_KEY_N, .mods = c.GLFW_MOD_CONTROL | c.GLFW_MOD_SHIFT, .action = .new_window },
    Binding{ .key = c.GLFW_KEY_P, .mods = c.GLFW_MOD_CONTROL | c.GLFW_MOD_SHIFT, .action = .pomodoro_toggle },
    Binding{ .key = c.GLFW_KEY_RIGHT_BRACKET, .mods = c.GLFW_MOD_CONTROL | c.GLFW_MOD_SHIFT, .action = .pomodoro_skip },
    Binding{ .key = c.GLFW_KEY_V, .mods = c.GLFW_MOD_CONTROL | c.GLFW_MOD_SHIFT, .action = .paste_clipboard },
};

pub inline fn matchBinding(bindings: []const Binding, key: c_int, mods: c_int) ?Action {
    for (bindings) |b| if (b.key == key and b.mods == mods) return b.action;
    return null;
}

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
    const mok = ctx.modify_other_keys;

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
            if (mok >= 2 and has) return fmtMok(buf, mod, 13);
            if (alt) {
                buf[0] = 0x1b;
                buf[1] = '\r';
                return buf[0..2];
            }
            return "\r";
        },

        // Backspace
        c.GLFW_KEY_BACKSPACE => {
            if (mok >= 2 and has) return fmtMok(buf, mod, 127);
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
            if (mok >= 2 and has) return fmtMok(buf, mod, 9);
            if (alt) {
                buf[0] = 0x1b;
                buf[1] = '\t';
                return buf[0..2];
            }
            return "\t";
        },

        // Escape
        c.GLFW_KEY_ESCAPE => {
            if (mok >= 2 and has) return fmtMok(buf, mod, 27);
            return "\x1b";
        },

        // Space
        c.GLFW_KEY_SPACE => {
            if (ctrl) return "\x00"; // Ctrl+Space = NUL
            if (mok >= 2 and has) return fmtMok(buf, mod, 32);
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
                // level 2: Ctrl+Shift+letter sends CSI 27 ; mod ; UPPER ~
                if (mok >= 2 and shift) return fmtMok(buf, mod, upper);
                // level 1/2: Ctrl+Alt+letter sends CSI 27 ; mod ; lower ~
                if (mok >= 1 and alt) return fmtMok(buf, mod, lower);
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
                // level 2: Alt+letter sends CSI 27 ; mod ; codepoint ~
                if (mok >= 2) return fmtMok(buf, mod, if (shift) upper else lower);
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
                if (mok >= 1) return fmtMok(buf, mod, digit);
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
