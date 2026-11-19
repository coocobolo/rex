//! Translates xkbcommon keysyms, Linux mouse button codes, Wayland fixed-point
//! coordinates and pointer shapes into Rex's native-free input types.

const c_xkb = @import("xkbcommon");
const Key = @import("../../input/key.zig").Key;
const events = @import("../Event.zig");
const Window = @import("../Window.zig");
const proto = @import("proto.zig");

/// Linux evdev button codes delivered by `wl_pointer.button`.
pub const btn_left: u32 = 0x110;
pub const btn_right: u32 = 0x111;
pub const btn_middle: u32 = 0x112;

/// Maps an xkbcommon keysym to a Rex `Key` on the US layout.
pub fn fromKeysym(sym: c_xkb.xkb_keysym_t) ?Key {
    return switch (sym) {
        c_xkb.XKB_KEY_Escape => .escape,
        c_xkb.XKB_KEY_Return => .enter,
        c_xkb.XKB_KEY_KP_Enter => .kp_enter,
        c_xkb.XKB_KEY_Tab, c_xkb.XKB_KEY_ISO_Left_Tab => .tab,
        c_xkb.XKB_KEY_BackSpace => .backspace,
        c_xkb.XKB_KEY_Insert => .insert,
        c_xkb.XKB_KEY_Delete => .delete,
        c_xkb.XKB_KEY_Left => .left,
        c_xkb.XKB_KEY_Right => .right,
        c_xkb.XKB_KEY_Up => .up,
        c_xkb.XKB_KEY_Down => .down,
        c_xkb.XKB_KEY_Prior => .page_up,
        c_xkb.XKB_KEY_Next => .page_down,
        c_xkb.XKB_KEY_Home => .home,
        c_xkb.XKB_KEY_End => .end,
        c_xkb.XKB_KEY_F1 => .f1,
        c_xkb.XKB_KEY_F2 => .f2,
        c_xkb.XKB_KEY_F3 => .f3,
        c_xkb.XKB_KEY_F4 => .f4,
        c_xkb.XKB_KEY_F5 => .f5,
        c_xkb.XKB_KEY_F6 => .f6,
        c_xkb.XKB_KEY_F7 => .f7,
        c_xkb.XKB_KEY_F8 => .f8,
        c_xkb.XKB_KEY_F9 => .f9,
        c_xkb.XKB_KEY_F10 => .f10,
        c_xkb.XKB_KEY_F11 => .f11,
        c_xkb.XKB_KEY_F12 => .f12,
        c_xkb.XKB_KEY_space => .space,
        c_xkb.XKB_KEY_minus => .minus,
        c_xkb.XKB_KEY_equal => .equal,
        c_xkb.XKB_KEY_bracketleft => .left_bracket,
        c_xkb.XKB_KEY_bracketright => .right_bracket,
        c_xkb.XKB_KEY_backslash => .backslash,
        c_xkb.XKB_KEY_semicolon => .semicolon,
        c_xkb.XKB_KEY_apostrophe => .apostrophe,
        c_xkb.XKB_KEY_comma => .comma,
        c_xkb.XKB_KEY_period => .period,
        c_xkb.XKB_KEY_slash => .slash,
        c_xkb.XKB_KEY_grave => .grave_accent,
        c_xkb.XKB_KEY_KP_Add => .kp_add,
        c_xkb.XKB_KEY_KP_Subtract => .kp_subtract,
        c_xkb.XKB_KEY_KP_Multiply => .kp_multiply,
        c_xkb.XKB_KEY_KP_Divide => .kp_divide,
        c_xkb.XKB_KEY_KP_Decimal => .kp_decimal,
        c_xkb.XKB_KEY_KP_Equal => .kp_equal,
        c_xkb.XKB_KEY_Shift_L => .left_shift,
        c_xkb.XKB_KEY_Shift_R => .right_shift,
        c_xkb.XKB_KEY_Control_L => .left_control,
        c_xkb.XKB_KEY_Control_R => .right_control,
        c_xkb.XKB_KEY_Alt_L => .left_alt,
        c_xkb.XKB_KEY_Alt_R => .right_alt,
        c_xkb.XKB_KEY_Super_L => .left_super,
        c_xkb.XKB_KEY_Super_R => .right_super,
        'a'...'z' => @enumFromInt(@intFromEnum(Key.a) + @as(u16, @intCast(sym - 'a'))),
        'A'...'Z' => @enumFromInt(@intFromEnum(Key.a) + @as(u16, @intCast(sym - 'A'))),
        '0'...'9' => @enumFromInt(@intFromEnum(Key.num_0) + @as(u16, @intCast(sym - '0'))),
        c_xkb.XKB_KEY_KP_0...c_xkb.XKB_KEY_KP_9 => @enumFromInt(@intFromEnum(Key.kp_0) + @as(u16, @intCast(sym - c_xkb.XKB_KEY_KP_0))),
        else => null,
    };
}

/// Maps a Linux evdev button code to Rex's `MouseButton`.
pub fn mouseButton(code: u32) ?events.MouseButton {
    return switch (code) {
        btn_left => .left,
        btn_middle => .middle,
        btn_right => .right,
        else => null,
    };
}

/// Maps Rex's `PointerShape` to a `wp_cursor_shape_device_v1` shape enum value.
pub fn cursorShape(shape: Window.PointerShape) u32 {
    return switch (shape) {
        .arrow => proto.cursor_shape_device.shape_default,
        .hand => proto.cursor_shape_device.shape_pointer,
        .text => proto.cursor_shape_device.shape_text,
    };
}

/// Converts a Wayland 24.8 signed fixed-point value (`wl_fixed_t`) to `f64`.
pub fn fixedToF64(raw: i32) f64 {
    return @as(f64, @floatFromInt(raw)) / 256.0;
}

/// Converts a Wayland vertical axis delta (positive down) to Rex scroll `dy`
/// (positive up, matching GLFW and X11).
pub fn verticalScroll(wl_pixels: f64) f64 {
    return -wl_pixels / 10.0;
}

/// Converts a Wayland horizontal axis delta (positive right) to Rex scroll `dx`.
pub fn horizontalScroll(wl_pixels: f64) f64 {
    return wl_pixels / 10.0;
}
