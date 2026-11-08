//! GLFW key and mouse input: key bindings and xterm key encoding.

const std = @import("std");

const c = @import("glfw");

/// Platform-agnostic keyboard modifiers packed into a single byte.
pub const Modifiers = packed struct(u8) {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    super: bool = false,
    _pad: u4 = 0,

    pub const none: Modifiers = .{};

    pub fn fromGlfw(mods: c_int) Modifiers {
        return .{
            .shift = (mods & c.GLFW_MOD_SHIFT) != 0,
            .ctrl = (mods & c.GLFW_MOD_CONTROL) != 0,
            .alt = (mods & c.GLFW_MOD_ALT) != 0,
            .super = (mods & c.GLFW_MOD_SUPER) != 0,
        };
    }

    pub fn toGlfw(self: Modifiers) c_int {
        var m: c_int = 0;
        if (self.shift) m |= c.GLFW_MOD_SHIFT;
        if (self.ctrl) m |= c.GLFW_MOD_CONTROL;
        if (self.alt) m |= c.GLFW_MOD_ALT;
        if (self.super) m |= c.GLFW_MOD_SUPER;
        return m;
    }

    pub fn hasAny(self: Modifiers) bool {
        return self.shift or self.ctrl or self.alt or self.super;
    }
};

/// Canonical platform-agnostic keyboard keys.
pub const Key = enum(u16) {
    escape,
    enter,
    tab,
    backspace,
    insert,
    delete,
    left,
    right,
    up,
    down,
    page_up,
    page_down,
    home,
    end,
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
    a,
    b,
    c,
    d,
    e,
    f,
    g,
    h,
    i,
    j,
    k,
    l,
    m,
    n,
    o,
    p,
    q,
    r,
    s,
    t,
    u,
    v,
    w,
    x,
    y,
    z,
    num_0,
    num_1,
    num_2,
    num_3,
    num_4,
    num_5,
    num_6,
    num_7,
    num_8,
    num_9,
    space,
    minus,
    equal,
    left_bracket,
    right_bracket,
    backslash,
    semicolon,
    apostrophe,
    comma,
    period,
    slash,
    grave_accent,
    kp_enter,
    kp_0,
    kp_1,
    kp_2,
    kp_3,
    kp_4,
    kp_5,
    kp_6,
    kp_7,
    kp_8,
    kp_9,
    kp_add,
    kp_subtract,
    kp_multiply,
    kp_divide,
    kp_decimal,
    kp_equal,
    left_shift,
    right_shift,
    left_control,
    right_control,
    left_alt,
    right_alt,
    left_super,
    right_super,

    pub fn fromGlfw(key: c_int) ?Key {
        return switch (key) {
            c.GLFW_KEY_ESCAPE => .escape,
            c.GLFW_KEY_ENTER => .enter,
            c.GLFW_KEY_TAB => .tab,
            c.GLFW_KEY_BACKSPACE => .backspace,
            c.GLFW_KEY_INSERT => .insert,
            c.GLFW_KEY_DELETE => .delete,
            c.GLFW_KEY_LEFT => .left,
            c.GLFW_KEY_RIGHT => .right,
            c.GLFW_KEY_UP => .up,
            c.GLFW_KEY_DOWN => .down,
            c.GLFW_KEY_PAGE_UP => .page_up,
            c.GLFW_KEY_PAGE_DOWN => .page_down,
            c.GLFW_KEY_HOME => .home,
            c.GLFW_KEY_END => .end,
            c.GLFW_KEY_F1 => .f1,
            c.GLFW_KEY_F2 => .f2,
            c.GLFW_KEY_F3 => .f3,
            c.GLFW_KEY_F4 => .f4,
            c.GLFW_KEY_F5 => .f5,
            c.GLFW_KEY_F6 => .f6,
            c.GLFW_KEY_F7 => .f7,
            c.GLFW_KEY_F8 => .f8,
            c.GLFW_KEY_F9 => .f9,
            c.GLFW_KEY_F10 => .f10,
            c.GLFW_KEY_F11 => .f11,
            c.GLFW_KEY_F12 => .f12,
            c.GLFW_KEY_A => .a,
            c.GLFW_KEY_B => .b,
            c.GLFW_KEY_C => .c,
            c.GLFW_KEY_D => .d,
            c.GLFW_KEY_E => .e,
            c.GLFW_KEY_F => .f,
            c.GLFW_KEY_G => .g,
            c.GLFW_KEY_H => .h,
            c.GLFW_KEY_I => .i,
            c.GLFW_KEY_J => .j,
            c.GLFW_KEY_K => .k,
            c.GLFW_KEY_L => .l,
            c.GLFW_KEY_M => .m,
            c.GLFW_KEY_N => .n,
            c.GLFW_KEY_O => .o,
            c.GLFW_KEY_P => .p,
            c.GLFW_KEY_Q => .q,
            c.GLFW_KEY_R => .r,
            c.GLFW_KEY_S => .s,
            c.GLFW_KEY_T => .t,
            c.GLFW_KEY_U => .u,
            c.GLFW_KEY_V => .v,
            c.GLFW_KEY_W => .w,
            c.GLFW_KEY_X => .x,
            c.GLFW_KEY_Y => .y,
            c.GLFW_KEY_Z => .z,
            c.GLFW_KEY_0 => .num_0,
            c.GLFW_KEY_1 => .num_1,
            c.GLFW_KEY_2 => .num_2,
            c.GLFW_KEY_3 => .num_3,
            c.GLFW_KEY_4 => .num_4,
            c.GLFW_KEY_5 => .num_5,
            c.GLFW_KEY_6 => .num_6,
            c.GLFW_KEY_7 => .num_7,
            c.GLFW_KEY_8 => .num_8,
            c.GLFW_KEY_9 => .num_9,
            c.GLFW_KEY_SPACE => .space,
            c.GLFW_KEY_MINUS => .minus,
            c.GLFW_KEY_EQUAL => .equal,
            c.GLFW_KEY_LEFT_BRACKET => .left_bracket,
            c.GLFW_KEY_RIGHT_BRACKET => .right_bracket,
            c.GLFW_KEY_BACKSLASH => .backslash,
            c.GLFW_KEY_SEMICOLON => .semicolon,
            c.GLFW_KEY_APOSTROPHE => .apostrophe,
            c.GLFW_KEY_COMMA => .comma,
            c.GLFW_KEY_PERIOD => .period,
            c.GLFW_KEY_SLASH => .slash,
            c.GLFW_KEY_GRAVE_ACCENT => .grave_accent,
            c.GLFW_KEY_KP_ENTER => .kp_enter,
            c.GLFW_KEY_KP_0 => .kp_0,
            c.GLFW_KEY_KP_1 => .kp_1,
            c.GLFW_KEY_KP_2 => .kp_2,
            c.GLFW_KEY_KP_3 => .kp_3,
            c.GLFW_KEY_KP_4 => .kp_4,
            c.GLFW_KEY_KP_5 => .kp_5,
            c.GLFW_KEY_KP_6 => .kp_6,
            c.GLFW_KEY_KP_7 => .kp_7,
            c.GLFW_KEY_KP_8 => .kp_8,
            c.GLFW_KEY_KP_9 => .kp_9,
            c.GLFW_KEY_KP_ADD => .kp_add,
            c.GLFW_KEY_KP_SUBTRACT => .kp_subtract,
            c.GLFW_KEY_KP_MULTIPLY => .kp_multiply,
            c.GLFW_KEY_KP_DIVIDE => .kp_divide,
            c.GLFW_KEY_KP_DECIMAL => .kp_decimal,
            c.GLFW_KEY_KP_EQUAL => .kp_equal,
            c.GLFW_KEY_LEFT_SHIFT => .left_shift,
            c.GLFW_KEY_RIGHT_SHIFT => .right_shift,
            c.GLFW_KEY_LEFT_CONTROL => .left_control,
            c.GLFW_KEY_RIGHT_CONTROL => .right_control,
            c.GLFW_KEY_LEFT_ALT => .left_alt,
            c.GLFW_KEY_RIGHT_ALT => .right_alt,
            c.GLFW_KEY_LEFT_SUPER => .left_super,
            c.GLFW_KEY_RIGHT_SUPER => .right_super,
            else => null,
        };
    }

    pub fn toGlfw(self: Key) c_int {
        return switch (self) {
            .escape => c.GLFW_KEY_ESCAPE,
            .enter => c.GLFW_KEY_ENTER,
            .tab => c.GLFW_KEY_TAB,
            .backspace => c.GLFW_KEY_BACKSPACE,
            .insert => c.GLFW_KEY_INSERT,
            .delete => c.GLFW_KEY_DELETE,
            .left => c.GLFW_KEY_LEFT,
            .right => c.GLFW_KEY_RIGHT,
            .up => c.GLFW_KEY_UP,
            .down => c.GLFW_KEY_DOWN,
            .page_up => c.GLFW_KEY_PAGE_UP,
            .page_down => c.GLFW_KEY_PAGE_DOWN,
            .home => c.GLFW_KEY_HOME,
            .end => c.GLFW_KEY_END,
            .f1 => c.GLFW_KEY_F1,
            .f2 => c.GLFW_KEY_F2,
            .f3 => c.GLFW_KEY_F3,
            .f4 => c.GLFW_KEY_F4,
            .f5 => c.GLFW_KEY_F5,
            .f6 => c.GLFW_KEY_F6,
            .f7 => c.GLFW_KEY_F7,
            .f8 => c.GLFW_KEY_F8,
            .f9 => c.GLFW_KEY_F9,
            .f10 => c.GLFW_KEY_F10,
            .f11 => c.GLFW_KEY_F11,
            .f12 => c.GLFW_KEY_F12,
            .a => c.GLFW_KEY_A,
            .b => c.GLFW_KEY_B,
            .c => c.GLFW_KEY_C,
            .d => c.GLFW_KEY_D,
            .e => c.GLFW_KEY_E,
            .f => c.GLFW_KEY_F,
            .g => c.GLFW_KEY_G,
            .h => c.GLFW_KEY_H,
            .i => c.GLFW_KEY_I,
            .j => c.GLFW_KEY_J,
            .k => c.GLFW_KEY_K,
            .l => c.GLFW_KEY_L,
            .m => c.GLFW_KEY_M,
            .n => c.GLFW_KEY_N,
            .o => c.GLFW_KEY_O,
            .p => c.GLFW_KEY_P,
            .q => c.GLFW_KEY_Q,
            .r => c.GLFW_KEY_R,
            .s => c.GLFW_KEY_S,
            .t => c.GLFW_KEY_T,
            .u => c.GLFW_KEY_U,
            .v => c.GLFW_KEY_V,
            .w => c.GLFW_KEY_W,
            .x => c.GLFW_KEY_X,
            .y => c.GLFW_KEY_Y,
            .z => c.GLFW_KEY_Z,
            .num_0 => c.GLFW_KEY_0,
            .num_1 => c.GLFW_KEY_1,
            .num_2 => c.GLFW_KEY_2,
            .num_3 => c.GLFW_KEY_3,
            .num_4 => c.GLFW_KEY_4,
            .num_5 => c.GLFW_KEY_5,
            .num_6 => c.GLFW_KEY_6,
            .num_7 => c.GLFW_KEY_7,
            .num_8 => c.GLFW_KEY_8,
            .num_9 => c.GLFW_KEY_9,
            .space => c.GLFW_KEY_SPACE,
            .minus => c.GLFW_KEY_MINUS,
            .equal => c.GLFW_KEY_EQUAL,
            .left_bracket => c.GLFW_KEY_LEFT_BRACKET,
            .right_bracket => c.GLFW_KEY_RIGHT_BRACKET,
            .backslash => c.GLFW_KEY_BACKSLASH,
            .semicolon => c.GLFW_KEY_SEMICOLON,
            .apostrophe => c.GLFW_KEY_APOSTROPHE,
            .comma => c.GLFW_KEY_COMMA,
            .period => c.GLFW_KEY_PERIOD,
            .slash => c.GLFW_KEY_SLASH,
            .grave_accent => c.GLFW_KEY_GRAVE_ACCENT,
            .kp_enter => c.GLFW_KEY_KP_ENTER,
            .kp_0 => c.GLFW_KEY_KP_0,
            .kp_1 => c.GLFW_KEY_KP_1,
            .kp_2 => c.GLFW_KEY_KP_2,
            .kp_3 => c.GLFW_KEY_KP_3,
            .kp_4 => c.GLFW_KEY_KP_4,
            .kp_5 => c.GLFW_KEY_KP_5,
            .kp_6 => c.GLFW_KEY_KP_6,
            .kp_7 => c.GLFW_KEY_KP_7,
            .kp_8 => c.GLFW_KEY_KP_8,
            .kp_9 => c.GLFW_KEY_KP_9,
            .kp_add => c.GLFW_KEY_KP_ADD,
            .kp_subtract => c.GLFW_KEY_KP_SUBTRACT,
            .kp_multiply => c.GLFW_KEY_KP_MULTIPLY,
            .kp_divide => c.GLFW_KEY_KP_DIVIDE,
            .kp_decimal => c.GLFW_KEY_KP_DECIMAL,
            .kp_equal => c.GLFW_KEY_KP_EQUAL,
            .left_shift => c.GLFW_KEY_LEFT_SHIFT,
            .right_shift => c.GLFW_KEY_RIGHT_SHIFT,
            .left_control => c.GLFW_KEY_LEFT_CONTROL,
            .right_control => c.GLFW_KEY_RIGHT_CONTROL,
            .left_alt => c.GLFW_KEY_LEFT_ALT,
            .right_alt => c.GLFW_KEY_RIGHT_ALT,
            .left_super => c.GLFW_KEY_LEFT_SUPER,
            .right_super => c.GLFW_KEY_RIGHT_SUPER,
        };
    }

    pub fn isModifier(self: Key) bool {
        return switch (self) {
            .left_shift,
            .right_shift,
            .left_control,
            .right_control,
            .left_alt,
            .right_alt,
            .left_super,
            .right_super,
            => true,
            else => false,
        };
    }
};

/// Returns whether `key` is one of GLFW's left or right modifier keys.
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
    quit,

    // Focus & Wellbeing
    focus_toggle, // start / pause / resume
    focus_reset, // restart current session from scratch
    focus_skip, // skip to next phase (work to break or break to work)
    focus_toggle_phase_end, // switch on_phase_end between wait and start_next
    wellbeing_dashboard, // show Digital Wellbeing dashboard
    wellbeing_clear, // clear Digital Wellbeing history
    wellbeing_dismiss, // dismiss active wellbeing alert / unlock input
    wellbeing_toast_toggle, // toggle toast notification for debugging

    // Toast notifications
    toast_dismiss,
    toast_activate,

    scroll_up,
    scroll_down,

    // global debugging stats, option, etc.
    debug,

    // Configuration
    reload_config,

    send_to_pty: []const u8, // for custom sequences
};

pub const Binding = struct {
    key: Key,
    mods: Modifiers = .{},
    action: Action,
};

pub const default_keymap: []const Binding = &.{
    .{ .key = .num_0, .mods = .{ .ctrl = true }, .action = .reset_font_size },
    .{ .key = .a, .mods = .{ .ctrl = true, .shift = true }, .action = .focus_toggle_phase_end },
    .{ .key = .backspace, .mods = .{ .ctrl = true, .shift = true }, .action = .focus_reset },
    .{ .key = .c, .mods = .{ .ctrl = true, .shift = true }, .action = .copy_selection },
    .{ .key = .d, .mods = .{ .ctrl = true, .shift = true }, .action = .wellbeing_dismiss },
    .{ .key = .equal, .mods = .{ .ctrl = true }, .action = .increase_font_size },
    .{ .key = .f6, .mods = .{ .ctrl = true, .shift = true }, .action = .debug },
    .{ .key = .j, .mods = .{ .ctrl = true, .shift = true }, .action = .scroll_down },
    .{ .key = .k, .mods = .{ .ctrl = true, .shift = true }, .action = .scroll_up },
    .{ .key = .minus, .mods = .{ .ctrl = true }, .action = .decrease_font_size },
    .{ .key = .n, .mods = .{ .ctrl = true, .shift = true }, .action = .new_window },
    .{ .key = .p, .mods = .{ .ctrl = true, .shift = true }, .action = .focus_toggle },
    .{ .key = .q, .mods = .{ .ctrl = true, .shift = true }, .action = .quit },
    .{ .key = .f5, .mods = .{ .ctrl = true, .shift = true }, .action = .reload_config },
    .{ .key = .right_bracket, .mods = .{ .ctrl = true, .shift = true }, .action = .focus_skip },
    .{ .key = .t, .mods = .{ .ctrl = true, .shift = true }, .action = .wellbeing_toast_toggle },
    .{ .key = .v, .mods = .{ .ctrl = true, .shift = true }, .action = .paste_clipboard },
    .{ .key = .w, .mods = .{ .ctrl = true, .shift = true }, .action = .wellbeing_dashboard },
};

pub inline fn matchBinding(bindings: []const Binding, key: Key, mods: Modifiers) ?Action {
    for (bindings) |b| {
        if (b.key == key and @as(u8, @bitCast(b.mods)) == @as(u8, @bitCast(mods))) return b.action;
    }
    return null;
}

pub inline fn matchGlfwBinding(bindings: []const Binding, glfw_key: c_int, glfw_mods: c_int) ?Action {
    const key = Key.fromGlfw(glfw_key) orelse return null;
    const mods = Modifiers.fromGlfw(glfw_mods);
    return matchBinding(bindings, key, mods);
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
