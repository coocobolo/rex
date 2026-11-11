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
    /// S8C1T: CSI and SS3 go out as one 8-bit byte each.
    eight_bit_controls: bool = false,
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

/// Where a sequence is written, and in which form its introducer goes
/// out. xterm sends key sequences through the same path as its replies
/// (`charproc.c` unparseseq), so under 8-bit controls CSI and SS3 are the
/// single bytes 0x9B and 0x8F. The ESC that Alt puts before a key's byte
/// is not an introducer and stays ESC.
const Out = struct {
    buf: *[max_len]u8,
    eight_bit: bool,

    /// Writes CSI (`[`) or SS3 (`O`) and returns its length.
    fn introducer(self: Out, comptime final: u8) usize {
        if (self.eight_bit) {
            self.buf[0] = final + 0x40;
            return 1;
        }
        self.buf[0] = 0x1b;
        self.buf[1] = final;
        return 2;
    }

    /// The introducer, then `fmt`. No sequence comes near `max_len`: the
    /// longest is CSI 27 ; 8 ; 127 ~, 12 bytes.
    fn print(self: Out, comptime final: u8, comptime fmt: []const u8, args: anytype) []const u8 {
        const n = self.introducer(final);
        const rest = std.fmt.bufPrint(self.buf[n..], fmt, args) catch unreachable;
        return self.buf[0 .. n + rest.len];
    }

    /// CSI num ~, or CSI num ; mod ~ with a modifier.
    fn tilde(self: Out, num: u16, mod: u8) []const u8 {
        if (mod <= 1) return self.print('[', "{d}~", .{num});
        return self.print('[', "{d};{d}~", .{ num, mod });
    }

    /// CSI letter, or CSI 1 ; mod letter with a modifier.
    fn csi(self: Out, letter: u8, mod: u8) []const u8 {
        if (mod <= 1) return self.print('[', "{c}", .{letter});
        return self.print('[', "1;{d}{c}", .{ mod, letter });
    }

    /// SS3 letter.
    fn ss3(self: Out, letter: u8) []const u8 {
        return self.print('O', "{c}", .{letter});
    }

    /// SS3 letter, or SS3 mod letter with a modifier: the keypad in
    /// application mode (`input.c`, the IsKeypadKey branch of Input).
    fn keypad(self: Out, letter: u8, mod: u8) []const u8 {
        if (mod <= 1) return self.ss3(letter);
        return self.print('O', "{d}{c}", .{ mod, letter });
    }

    /// CSI 27 ; mod ; code ~, the modifyOtherKeys form.
    fn otherKey(self: Out, mod: u8, code: u8) []const u8 {
        return self.print('[', "27;{d};{d}~", .{ mod, code });
    }

    /// ESC then `byte`: what Alt adds to a key's byte.
    fn escThen(self: Out, byte: u8) []const u8 {
        self.buf[0] = 0x1b;
        self.buf[1] = byte;
        return self.buf[0..2];
    }

    fn one(self: Out, byte: u8) []const u8 {
        self.buf[0] = byte;
        return self.buf[0..1];
    }
};

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
fn encodeOtherKey(level: Level, key: Key, mods: Modifiers, out: Out) ?[]const u8 {
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
    return out.otherKey(report.param, report.code);
}

/// A cursor key (the arrows, Home and End): SS3 `letter` in application mode, else CSI `letter`, and
/// always CSI 1 ; mod `letter` with a modifier.
fn cursorKey(out: Out, letter: u8, mod: u8, modes: Modes) []const u8 {
    if (mod > 1) return out.csi(letter, mod);
    return if (modes.cursor_keys) out.ss3(letter) else out.csi(letter, 1);
}

/// F1 to F4: SS3 `letter`, or CSI 1 ; mod `letter` with a modifier.
fn pfKey(out: Out, letter: u8, mod: u8) []const u8 {
    return if (mod > 1) out.csi(letter, mod) else out.ss3(letter);
}

/// A punctuation key: `ctrl_code` with Ctrl, ESC `char` with Alt, else
/// left to the character event.
fn punctuation(out: Out, mods: Modifiers, ctrl_code: u8, char: u8) []const u8 {
    if (mods.ctrl) return out.one(ctrl_code);
    if (mods.alt) return out.escThen(char);
    return "";
}

/// The bytes `key` sends with `mods` held, as xterm sends them on a US
/// layout. The result is in `buf` or static. It is empty when the key
/// sends nothing by itself: a modifier key, or a printable key whose
/// character arrives as text.
pub fn encode(key: Key, mods: Modifiers, modes: Modes, buf: *[max_len]u8) []const u8 {
    const mod = modifierParam(mods);
    const out: Out = .{ .buf = buf, .eight_bit = modes.eight_bit_controls };
    if (modes.modify_other_keys != .off) {
        if (encodeOtherKey(modes.modify_other_keys, key, mods, out)) |seq| return seq;
    }

    if (offsetIn(key, .a, .z)) |i| {
        if (mods.ctrl) return if (mods.alt) out.escThen(i + 1) else out.one(i + 1);
        if (mods.alt) return out.escThen((if (mods.shift) @as(u8, 'A') else 'a') + i);
        return "";
    }
    if (offsetIn(key, .num_0, .num_9)) |i| {
        const digit = '0' + i;
        // As in xterm on a US layout, with ESC first when Alt is held.
        if (mods.ctrl) if (ctrlDigit(digit)) |code| {
            return if (mods.alt) out.escThen(code) else out.one(code);
        };
        if (mods.alt) return out.escThen(digit);
        return "";
    }
    if (offsetIn(key, .kp_0, .kp_9)) |i| {
        return if (modes.keypad_app) out.ss3('p' + i) else "";
    }

    return switch (key) {
        .up => cursorKey(out, 'A', mod, modes),
        .down => cursorKey(out, 'B', mod, modes),
        .right => cursorKey(out, 'C', mod, modes),
        .left => cursorKey(out, 'D', mod, modes),

        .f1 => pfKey(out, 'P', mod),
        .f2 => pfKey(out, 'Q', mod),
        .f3 => pfKey(out, 'R', mod),
        .f4 => pfKey(out, 'S', mod),
        .f5 => out.tilde(15, mod),
        .f6 => out.tilde(17, mod),
        .f7 => out.tilde(18, mod),
        .f8 => out.tilde(19, mod),
        .f9 => out.tilde(20, mod),
        .f10 => out.tilde(21, mod),
        .f11 => out.tilde(23, mod),
        .f12 => out.tilde(24, mod),

        // Home and End are cursor keys in xterm (`input.c` IsCursorKey).
        .home => cursorKey(out, 'H', mod, modes),
        .end => cursorKey(out, 'F', mod, modes),
        .insert => out.tilde(2, mod),
        .delete => out.tilde(3, mod),
        .page_up => out.tilde(5, mod),
        .page_down => out.tilde(6, mod),

        .enter => if (mods.alt) out.escThen('\r') else "\r",
        // In keypad application mode xterm sends SS3 M, with the modifier
        // parameter before the M (measured on xterm 390).
        .kp_enter => if (modes.keypad_app) out.keypad('M', mod) else if (mods.alt) out.escThen('\r') else "\r",
        .backspace => if (mods.ctrl) "\x08" else if (mods.alt) out.escThen(0x7f) else "\x7f",
        // Shift+Tab is always the back tab.
        .tab => if (mods.shift) out.csi('Z', 1) else if (mods.alt) out.escThen('\t') else "\t",
        .escape => "\x1b",
        .space => punctuation(out, mods, 0x00, ' '),

        // Outside keypad application mode these arrive as characters.
        .kp_decimal => if (modes.keypad_app) out.ss3('n') else "",
        .kp_divide => if (modes.keypad_app) out.ss3('o') else "",
        .kp_multiply => if (modes.keypad_app) out.ss3('j') else "",
        .kp_subtract => if (modes.keypad_app) out.ss3('m') else "",
        .kp_add => if (modes.keypad_app) out.ss3('k') else "",
        .kp_equal => if (modes.keypad_app) out.ss3('X') else "",

        .left_bracket => punctuation(out, mods, 0x1b, '['), // Ctrl+[ is ESC
        .backslash => punctuation(out, mods, 0x1c, '\\'), // FS
        .right_bracket => punctuation(out, mods, 0x1d, ']'), // GS
        .grave_accent => punctuation(out, mods, 0x00, '`'), // NUL, as in xterm
        .minus => punctuation(out, mods, 0x1f, '-'), // US
        .slash => punctuation(out, mods, 0x1f, '/'), // US, as Ctrl+-

        else => "",
    };
}
