//! The xterm key encoder: the bytes a key press sends to the program, for
//! a `Key`, its `Modifiers` and the terminal's key modes. Pure and
//! allocation-free, with no platform dependency, so the window code and
//! `term/` (XTGETTCAP) both use it (ADR 0007).

const std = @import("std");

const Key = @import("key.zig").Key;
const Modifiers = @import("key.zig").Modifiers;

/// The longest sequence `encode` writes fits in this many bytes.
pub const max_len = 32;

/// XTMODKEYS modifyOtherKeys level (`CSI > 4 ; Pv m`).
pub const ModifyOtherKeys = enum(u2) {
    off = 0,
    /// Level 1: only keys whose usual byte does not carry the modifier.
    partial = 1,
    /// Level 2: every modified ordinary key.
    full = 2,
};

/// The terminal modes that change what a key sends.
pub const Modes = struct {
    modify_other_keys: ModifyOtherKeys = .off,
    /// DECCKM: cursor keys send SS3 instead of CSI.
    cursor_keys: bool = false,
    /// DECKPAM: the keypad sends SS3 sequences instead of characters.
    keypad_app: bool = false,
};

/// xterm's modifier parameter: 1 + Shift + 2 Alt + 4 Ctrl + 8 Super, so 1
/// means none.
fn modifierParam(mods: Modifiers) u8 {
    var m: u8 = 0;
    if (mods.shift) m |= 1;
    if (mods.alt) m |= 2;
    if (mods.ctrl) m |= 4;
    if (mods.super) m |= 8;
    return m + 1;
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
fn fmtTilde(buf: *[max_len]u8, num: u16, mod: u8) []const u8 {
    if (mod <= 1) return std.fmt.bufPrint(buf, "\x1b[{d}~", .{num}) catch "";
    return std.fmt.bufPrint(buf, "\x1b[{d};{d}~", .{ num, mod }) catch "";
}

/// Format [CSI letter] | [CSI 1 ; mod letter]  (arrows, Home, End)
fn fmtCsi1(buf: *[max_len]u8, letter: u8, mod: u8) []const u8 {
    if (mod <= 1) {
        buf[0] = 0x1b;
        buf[1] = '[';
        buf[2] = letter;
        return buf[0..3];
    }
    return std.fmt.bufPrint(buf, "\x1b[1;{d}{c}", .{ mod, letter }) catch "";
}

/// Format SS3 letter  (application cursor / F1-F4 without modifier)
fn fmtSs3(buf: *[max_len]u8, letter: u8) []const u8 {
    buf[0] = 0x1b;
    buf[1] = 'O';
    buf[2] = letter;
    return buf[0..3];
}

/// Format CSI 27 ; mod ; codepoint ~  (modifyOtherKeys level 1/2)
fn fmtMok(buf: *[max_len]u8, mod: u8, cp: u21) []const u8 {
    return std.fmt.bufPrint(buf, "\x1b[27;{d};{d}~", .{ mod, cp }) catch "";
}

// modifyOtherKeys, ported from xterm 412 `input.c` (ModifyOtherKeys,
// allowedCharModifiers, filterAltMeta and the check in Input) with xterm's
// default resources: metaSendsEscape off, Alt reported as Alt (3), no
// modifier ignored, DECBKM reset (Backspace sends DEL), a US layout, and
// the CSI 27 ; mod ; code ~ format (formatOtherKeys 0). Super is not a
// modifier here. Level 3 and up are not supported.

const Level = ModifyOtherKeys;

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
fn allowedModifiers(level: Level, state: ModState, key: OtherKey, ctrl_held: bool) ModState {
    var result = state;
    if (level != .full) {
        if (key.isControlInput() and result.without(.{ .ctrl = true }).bits() == 0) {
            if (level == .off) result.ctrl = false;
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
fn modifiesOtherKey(level: Level, event: ModState, key: *OtherKey) bool {
    const modify_parm = event.param();
    if (modify_parm == 0) return false;
    var state = event;
    if (key.* == .backspace and !state.ctrl) key.* = .delete;
    if (!key.isPredefined()) state = allowedModifiers(level, state, key.*, event.ctrl);
    if (state.bits() == 0) return false;

    return switch (level) {
        .off => false,
        .partial => switch (key.*) {
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
        .full => switch (key.*) {
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
fn otherKeyReport(level: Level, event: ModState, key_in: OtherKey) ?struct { param: u8, code: u8 } {
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

comptime {
    // `offsetIn` relies on these runs being declared in order.
    std.debug.assert(@intFromEnum(Key.z) - @intFromEnum(Key.a) == 25);
    std.debug.assert(@intFromEnum(Key.num_9) - @intFromEnum(Key.num_0) == 9);
    std.debug.assert(@intFromEnum(Key.kp_9) - @intFromEnum(Key.kp_0) == 9);
}

/// The position of `key` in the run of keys from `first` to `last`, or
/// null when it is outside it.
fn offsetIn(key: Key, first: Key, last: Key) ?u8 {
    const k = @intFromEnum(key);
    if (k < @intFromEnum(first) or k > @intFromEnum(last)) return null;
    return @intCast(k - @intFromEnum(first));
}

/// The unshifted and shifted ASCII characters of a key on a US layout.
fn usLayout(key: Key) ?[2]u8 {
    if (offsetIn(key, .a, .z)) |i| return .{ 'a' + i, 'A' + i };
    if (offsetIn(key, .num_0, .num_9)) |i| return .{ '0' + i, ")!@#$%^&*("[i] };
    return switch (key) {
        .space => .{ ' ', ' ' },
        .apostrophe => .{ '\'', '"' },
        .comma => .{ ',', '<' },
        .minus => .{ '-', '_' },
        .period => .{ '.', '>' },
        .slash => .{ '/', '?' },
        .semicolon => .{ ';', ':' },
        .equal => .{ '=', '+' },
        .left_bracket => .{ '[', '{' },
        .backslash => .{ '\\', '|' },
        .right_bracket => .{ ']', '}' },
        .grave_accent => .{ '`', '~' },
        else => null,
    };
}

/// The modifyOtherKeys sequence for `key`, or null when it is not an
/// ordinary key or xterm would send it the usual way.
fn encodeOtherKey(level: Level, key: Key, mods: Modifiers, buf: *[max_len]u8) ?[]const u8 {
    if (mods.super) return null;
    const event: ModState = .{ .shift = mods.shift, .alt = mods.alt, .ctrl = mods.ctrl };
    const other: OtherKey = switch (key) {
        .backspace => .backspace,
        .tab => if (event.shift) .left_tab else .tab,
        .enter => .enter,
        .escape => .escape,
        else => .{ .char = (usLayout(key) orelse return null)[@intFromBool(event.shift)] },
    };
    const report = otherKeyReport(level, event, other) orelse return null;
    return fmtMok(buf, report.param, report.code);
}

/// ESC then `byte`: what Alt adds to a key's byte.
fn escThen(buf: *[max_len]u8, byte: u8) []const u8 {
    buf[0] = 0x1b;
    buf[1] = byte;
    return buf[0..2];
}

fn one(buf: *[max_len]u8, byte: u8) []const u8 {
    buf[0] = byte;
    return buf[0..1];
}

/// A cursor key: SS3 `letter` in application mode, else CSI `letter`, and
/// always CSI 1 ; mod `letter` with a modifier.
fn cursorKey(buf: *[max_len]u8, letter: u8, mod: u8, modes: Modes) []const u8 {
    if (mod > 1) return fmtCsi1(buf, letter, mod);
    return if (modes.cursor_keys) fmtSs3(buf, letter) else fmtCsi1(buf, letter, 1);
}

/// F1 to F4: SS3 `letter`, or CSI 1 ; mod `letter` with a modifier.
fn pfKey(buf: *[max_len]u8, letter: u8, mod: u8) []const u8 {
    return if (mod > 1) fmtCsi1(buf, letter, mod) else fmtSs3(buf, letter);
}

/// A punctuation key: `ctrl_code` with Ctrl, ESC `char` with Alt, else
/// left to the character event.
fn punctuation(buf: *[max_len]u8, mods: Modifiers, ctrl_code: u8, char: u8) []const u8 {
    if (mods.ctrl) return one(buf, ctrl_code);
    if (mods.alt) return escThen(buf, char);
    return "";
}

/// The bytes `key` sends with `mods` held, as xterm sends them on a US
/// layout. The result is in `buf` or static. It is empty when the key
/// sends nothing by itself: a modifier key, or a printable key whose
/// character arrives as text.
pub fn encode(key: Key, mods: Modifiers, modes: Modes, buf: *[max_len]u8) []const u8 {
    const mod = modifierParam(mods);
    if (modes.modify_other_keys != .off) {
        if (encodeOtherKey(modes.modify_other_keys, key, mods, buf)) |seq| return seq;
    }

    if (offsetIn(key, .a, .z)) |i| {
        if (mods.ctrl) return if (mods.alt) escThen(buf, i + 1) else one(buf, i + 1);
        if (mods.alt) return escThen(buf, (if (mods.shift) @as(u8, 'A') else 'a') + i);
        return "";
    }
    if (offsetIn(key, .num_0, .num_9)) |i| {
        const digit = '0' + i;
        // As in xterm on a US layout, with ESC first when Alt is held.
        if (mods.ctrl) if (ctrlDigit(digit)) |code| {
            return if (mods.alt) escThen(buf, code) else one(buf, code);
        };
        if (mods.alt) return escThen(buf, digit);
        return "";
    }
    if (offsetIn(key, .kp_0, .kp_9)) |i| {
        return if (modes.keypad_app) fmtSs3(buf, 'p' + i) else "";
    }

    return switch (key) {
        .up => cursorKey(buf, 'A', mod, modes),
        .down => cursorKey(buf, 'B', mod, modes),
        .right => cursorKey(buf, 'C', mod, modes),
        .left => cursorKey(buf, 'D', mod, modes),

        .f1 => pfKey(buf, 'P', mod),
        .f2 => pfKey(buf, 'Q', mod),
        .f3 => pfKey(buf, 'R', mod),
        .f4 => pfKey(buf, 'S', mod),
        .f5 => fmtTilde(buf, 15, mod),
        .f6 => fmtTilde(buf, 17, mod),
        .f7 => fmtTilde(buf, 18, mod),
        .f8 => fmtTilde(buf, 19, mod),
        .f9 => fmtTilde(buf, 20, mod),
        .f10 => fmtTilde(buf, 21, mod),
        .f11 => fmtTilde(buf, 23, mod),
        .f12 => fmtTilde(buf, 24, mod),

        .home => fmtCsi1(buf, 'H', mod),
        .end => fmtCsi1(buf, 'F', mod),
        .insert => fmtTilde(buf, 2, mod),
        .delete => fmtTilde(buf, 3, mod),
        .page_up => fmtTilde(buf, 5, mod),
        .page_down => fmtTilde(buf, 6, mod),

        .enter, .kp_enter => if (mods.alt) escThen(buf, '\r') else "\r",
        .backspace => if (mods.ctrl) "\x08" else if (mods.alt) escThen(buf, 0x7f) else "\x7f",
        // Shift+Tab is always the back tab.
        .tab => if (mods.shift) "\x1b[Z" else if (mods.alt) escThen(buf, '\t') else "\t",
        .escape => "\x1b",
        .space => punctuation(buf, mods, 0x00, ' '),

        // Outside keypad application mode these arrive as characters.
        .kp_decimal => if (modes.keypad_app) fmtSs3(buf, 'n') else "",
        .kp_divide => if (modes.keypad_app) fmtSs3(buf, 'o') else "",
        .kp_multiply => if (modes.keypad_app) fmtSs3(buf, 'j') else "",
        .kp_subtract => if (modes.keypad_app) fmtSs3(buf, 'm') else "",
        .kp_add => if (modes.keypad_app) fmtSs3(buf, 'k') else "",
        .kp_equal => if (modes.keypad_app) fmtSs3(buf, 'X') else "",

        .left_bracket => punctuation(buf, mods, 0x1b, '['), // Ctrl+[ is ESC
        .backslash => punctuation(buf, mods, 0x1c, '\\'), // FS
        .right_bracket => punctuation(buf, mods, 0x1d, ']'), // GS
        .grave_accent => punctuation(buf, mods, 0x00, '`'), // NUL, as in xterm
        .minus => punctuation(buf, mods, 0x1f, '-'), // US
        .slash => punctuation(buf, mods, 0x1f, '/'), // US, as Ctrl+-

        else => "",
    };
}
