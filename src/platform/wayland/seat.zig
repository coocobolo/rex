//! Wayland `wl_seat` input handling: keyboard (`xkbcommon` keymap, modifiers,
//! key repeat), pointer (motion, buttons, wheel) and `wp_cursor_shape_v1`.
//! Lives inside `backend.state` at a fixed address so C listeners stay valid.

const std = @import("std");

const c_xkb = @import("xkbcommon");
const w = @import("wayland");
const Key = @import("../../input/key.zig").Key;
const Modifiers = @import("../../input/key.zig").Modifiers;
const events = @import("../Event.zig");
const backend = @import("backend.zig");
const key = @import("key.zig");
const proto = @import("proto.zig");
const WaylandWindow = @import("WaylandWindow.zig");
const wl = @import("wl.zig");

const linux = std.os.linux;
const posix = std.posix;
const system = posix.system;

/// Maximum number of `input.Key` variants tracked in `keys_down`.
const key_bitset_len = 128;

pub const Seat = struct {
    wl_keyboard: ?*wl.Proxy = null,
    wl_pointer: ?*wl.Proxy = null,
    cursor_shape_device: ?*wl.Proxy = null,
    xkb_ctx: ?*c_xkb.xkb_context = null,
    xkb_keymap: ?*c_xkb.xkb_keymap = null,
    xkb_state: ?*c_xkb.xkb_state = null,
    kb_focus: ?*WaylandWindow = null,
    ptr_focus: ?*WaylandWindow = null,
    pending_scroll: ?Scroll = null,
    repeat_next_ns: i64 = 0,
    last_serial: u32 = 0,
    pointer_enter_serial: u32 = 0,
    repeat_rate_hz: u32 = 25,
    repeat_delay_ms: u32 = 400,
    repeat_keycode: u32 = 0,
    repeat_codepoint: u21 = 0,
    repeat_key: Key = .escape,
    mods: Modifiers = .none,
    repeat_active: bool = false,
    keys_down: std.StaticBitSet(key_bitset_len) = .initEmpty(),

    const Scroll = struct {
        dx: f64 = 0,
        dy: f64 = 0,
    };

    /// Attaches the `wl_seat` listener and creates the `xkbcommon` context.
    pub fn attach(self: *Seat, wl_seat: *wl.Proxy) void {
        const wl_lib = &backend.state.wl.?;
        if (self.xkb_ctx == null) {
            if (backend.state.xkb) |*xkb_lib| {
                self.xkb_ctx = xkb_lib.xkb_context_new(c_xkb.XKB_CONTEXT_NO_FLAGS);
            }
        }
        _ = wl_lib.wl_proxy_add_listener(wl_seat, @ptrCast(@constCast(&seat_listener)), self);
    }

    /// Releases keyboard, pointer, cursor-shape device and `xkbcommon` objects.
    pub fn deinit(self: *Seat) void {
        if (backend.state.wl) |*wl_lib| {
            if (self.cursor_shape_device) |dev| {
                _ = wl_lib.wl_proxy_marshal_flags(dev, proto.cursor_shape_device.destroy, null, wl_lib.wl_proxy_get_version(dev), proto.marshal_flag_destroy);
                self.cursor_shape_device = null;
            }
            if (self.wl_pointer) |ptr| {
                if (wl_lib.wl_proxy_get_version(ptr) >= 3) {
                    _ = wl_lib.wl_proxy_marshal_flags(ptr, proto.pointer.release, null, wl_lib.wl_proxy_get_version(ptr), proto.marshal_flag_destroy);
                } else {
                    wl_lib.wl_proxy_destroy(ptr);
                }
                self.wl_pointer = null;
            }
            if (self.wl_keyboard) |kb| {
                if (wl_lib.wl_proxy_get_version(kb) >= 3) {
                    _ = wl_lib.wl_proxy_marshal_flags(kb, proto.keyboard.release, null, wl_lib.wl_proxy_get_version(kb), proto.marshal_flag_destroy);
                } else {
                    wl_lib.wl_proxy_destroy(kb);
                }
                self.wl_keyboard = null;
            }
        }
        if (backend.state.xkb) |*xkb_lib| {
            if (self.xkb_state) |st| xkb_lib.xkb_state_unref(st);
            if (self.xkb_keymap) |km| xkb_lib.xkb_keymap_unref(km);
            if (self.xkb_ctx) |ctx| xkb_lib.xkb_context_unref(ctx);
        }
        self.* = .{};
    }

    /// Clears focus pointers if a window is destroyed while focused.
    pub fn onWindowDestroyed(self: *Seat, win: *WaylandWindow) void {
        if (self.kb_focus == win) {
            self.kb_focus = null;
            self.repeat_active = false;
            self.keys_down = .initEmpty();
        }
        if (self.ptr_focus == win) {
            self.ptr_focus = null;
        }
    }

    /// Returns whether `k` is currently held on `win`.
    pub fn isKeyDown(self: *const Seat, win: *const WaylandWindow, k: Key) bool {
        if (self.kb_focus != win) return false;
        const idx: usize = @intFromEnum(k);
        if (idx >= key_bitset_len) return false;
        return self.keys_down.isSet(idx);
    }

    /// Applies the window's pointer visibility and shape when the pointer is over it.
    pub fn applyCursor(self: *Seat, win: *const WaylandWindow) void {
        if (self.ptr_focus != win) return;
        const wl_lib = if (backend.state.wl) |*wlib| wlib else return;
        const ptr = self.wl_pointer orelse return;
        if (!win.pointer_visible) {
            _ = wl_lib.wl_proxy_marshal_flags(
                ptr,
                proto.pointer.set_cursor,
                null,
                wl_lib.wl_proxy_get_version(ptr),
                0,
                self.pointer_enter_serial,
                @as(?*wl.Proxy, null),
                @as(i32, 0),
                @as(i32, 0),
            );
            return;
        }
        if (self.cursor_shape_device) |dev| {
            _ = wl_lib.wl_proxy_marshal_flags(
                dev,
                proto.cursor_shape_device.set_shape,
                null,
                wl_lib.wl_proxy_get_version(dev),
                0,
                self.pointer_enter_serial,
                key.cursorShape(win.pointer_shape),
            );
        }
    }

    /// Milliseconds until the next key repeat fires, or null when idle.
    pub fn repeatTimeoutMs(self: *const Seat, now_ns: i64) ?f64 {
        if (!self.repeat_active or self.repeat_rate_hz == 0) return null;
        const rem_ns = self.repeat_next_ns - now_ns;
        if (rem_ns <= 0) return 0.0;
        return @as(f64, @floatFromInt(rem_ns)) / @as(f64, std.time.ns_per_ms);
    }

    /// Emits due key repeat events and advances the repeat deadline.
    pub fn tickRepeat(self: *Seat, now_ns: i64) void {
        if (!self.repeat_active or self.repeat_rate_hz == 0) return;
        const win = self.kb_focus orelse {
            self.repeat_active = false;
            return;
        };
        if (now_ns < self.repeat_next_ns) return;

        const period_ns: i64 = @divTrunc(std.time.ns_per_s, @as(i64, @intCast(self.repeat_rate_hz)));
        // Emit at most one repeat per tick so a stalled frame does not flood the ring.
        backend.pushEvent(.{ .key = .{
            .window = win.windowHandle(),
            .key = self.repeat_key,
            .mods = self.mods,
            .action = .repeat,
        } });
        if (self.repeat_codepoint != 0) {
            backend.pushEvent(.{ .text = .{
                .window = win.windowHandle(),
                .codepoint = self.repeat_codepoint,
            } });
        }
        self.repeat_next_ns = now_ns + @max(period_ns, 1);
    }

    /// Starts repeating a held key using the compositor's delay and rate.
    pub fn startRepeat(self: *Seat, keycode: u32, k: Key, cp: u21, now_ns: i64) void {
        if (self.repeat_rate_hz == 0) return;
        self.repeat_active = true;
        self.repeat_keycode = keycode;
        self.repeat_key = k;
        self.repeat_codepoint = cp;
        self.repeat_next_ns = now_ns + @as(i64, @intCast(self.repeat_delay_ms)) * std.time.ns_per_ms;
    }

    /// Stops repeating if `keycode` matches the currently repeating key.
    pub fn stopRepeat(self: *Seat, keycode: u32) void {
        if (self.repeat_active and self.repeat_keycode == keycode) {
            self.repeat_active = false;
        }
    }

    fn addScroll(self: *Seat, dx: f64, dy: f64) void {
        const pending: Scroll = self.pending_scroll orelse .{};
        self.pending_scroll = .{ .dx = pending.dx + dx, .dy = pending.dy + dy };
    }
};

/// Monotonic timestamp in nanoseconds for repeat scheduling.
pub fn monotonicNs() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * std.time.ns_per_s + @as(i64, ts.nsec);
}

fn ensureCursorShapeDevice(self: *Seat) void {
    if (self.cursor_shape_device != null) return;
    const ptr = self.wl_pointer orelse return;
    const mgr = backend.state.cursor_shape_manager orelse return;
    const wl_lib = &backend.state.wl.?;
    const ifaces = proto.interfaces();
    self.cursor_shape_device = wl_lib.wl_proxy_marshal_flags(
        mgr,
        proto.cursor_shape_manager.get_pointer,
        ifaces.cursor_shape_device,
        wl_lib.wl_proxy_get_version(mgr),
        0,
        @as(?*anyopaque, null),
        ptr,
    );
}

fn onSeatCapabilities(data: ?*anyopaque, wl_seat: ?*wl.Proxy, caps: u32) callconv(.c) void {
    const self: *Seat = @ptrCast(@alignCast(data.?));
    const wl_lib = &backend.state.wl.?;

    const has_kb = (caps & proto.seat.capability_keyboard) != 0;
    if (has_kb and self.wl_keyboard == null) {
        if (wl_lib.wl_proxy_marshal_flags(
            wl_seat,
            proto.seat.get_keyboard,
            wl_lib.keyboard_interface,
            wl_lib.wl_proxy_get_version(wl_seat),
            0,
            @as(?*anyopaque, null),
        )) |kb| {
            self.wl_keyboard = kb;
            _ = wl_lib.wl_proxy_add_listener(kb, @ptrCast(@constCast(&keyboard_listener)), self);
        }
    } else if (!has_kb and self.wl_keyboard != null) {
        const kb = self.wl_keyboard.?;
        if (wl_lib.wl_proxy_get_version(kb) >= 3) {
            _ = wl_lib.wl_proxy_marshal_flags(kb, proto.keyboard.release, null, wl_lib.wl_proxy_get_version(kb), proto.marshal_flag_destroy);
        } else {
            wl_lib.wl_proxy_destroy(kb);
        }
        self.wl_keyboard = null;
        self.kb_focus = null;
        self.repeat_active = false;
    }

    const has_ptr = (caps & proto.seat.capability_pointer) != 0;
    if (has_ptr and self.wl_pointer == null) {
        if (wl_lib.wl_proxy_marshal_flags(
            wl_seat,
            proto.seat.get_pointer,
            wl_lib.pointer_interface,
            wl_lib.wl_proxy_get_version(wl_seat),
            0,
            @as(?*anyopaque, null),
        )) |ptr| {
            self.wl_pointer = ptr;
            _ = wl_lib.wl_proxy_add_listener(ptr, @ptrCast(@constCast(&pointer_listener)), self);
            ensureCursorShapeDevice(self);
        }
    } else if (!has_ptr and self.wl_pointer != null) {
        if (self.cursor_shape_device) |dev| {
            _ = wl_lib.wl_proxy_marshal_flags(dev, proto.cursor_shape_device.destroy, null, wl_lib.wl_proxy_get_version(dev), proto.marshal_flag_destroy);
            self.cursor_shape_device = null;
        }
        const ptr = self.wl_pointer.?;
        if (wl_lib.wl_proxy_get_version(ptr) >= 3) {
            _ = wl_lib.wl_proxy_marshal_flags(ptr, proto.pointer.release, null, wl_lib.wl_proxy_get_version(ptr), proto.marshal_flag_destroy);
        } else {
            wl_lib.wl_proxy_destroy(ptr);
        }
        self.wl_pointer = null;
        self.ptr_focus = null;
    }
}

fn onSeatName(_: ?*anyopaque, _: ?*wl.Proxy, _: [*c]const u8) callconv(.c) void {}

fn onKeyboardKeymap(data: ?*anyopaque, _: ?*wl.Proxy, format: u32, fd: i32, size: u32) callconv(.c) void {
    defer _ = system.close(fd);
    const self: *Seat = @ptrCast(@alignCast(data.?));
    if (format != proto.keyboard.keymap_format_xkb_v1 or size == 0) return;
    const xkb_lib = if (backend.state.xkb) |*x| x else return;
    const ctx = self.xkb_ctx orelse return;

    const map_ptr = linux.mmap(null, size, .{ .READ = true }, .{ .TYPE = .PRIVATE }, fd, 0);
    if (linux.errno(map_ptr) != .SUCCESS) return;
    const mapped: [*]align(std.heap.page_size_min) const u8 = @ptrFromInt(map_ptr);
    defer _ = linux.munmap(mapped, size);
    if (mapped[size - 1] != 0) return;

    const keymap = xkb_lib.xkb_keymap_new_from_string(
        ctx,
        @ptrCast(mapped),
        c_xkb.XKB_KEYMAP_FORMAT_TEXT_V1,
        c_xkb.XKB_KEYMAP_COMPILE_NO_FLAGS,
    ) orelse return;
    const xkb_st = xkb_lib.xkb_state_new(keymap) orelse {
        xkb_lib.xkb_keymap_unref(keymap);
        return;
    };

    if (self.xkb_state) |old| xkb_lib.xkb_state_unref(old);
    if (self.xkb_keymap) |old| xkb_lib.xkb_keymap_unref(old);
    self.xkb_keymap = keymap;
    self.xkb_state = xkb_st;
}

fn onKeyboardEnter(
    data: ?*anyopaque,
    _: ?*wl.Proxy,
    serial: u32,
    surface: ?*wl.Proxy,
    _: ?*w.wl_array,
) callconv(.c) void {
    const self: *Seat = @ptrCast(@alignCast(data.?));
    self.last_serial = serial;
    self.kb_focus = backend.findWindowBySurface(surface);
    self.repeat_active = false;
    self.keys_down = .initEmpty();
}

fn onKeyboardLeave(data: ?*anyopaque, _: ?*wl.Proxy, serial: u32, _: ?*wl.Proxy) callconv(.c) void {
    const self: *Seat = @ptrCast(@alignCast(data.?));
    self.last_serial = serial;
    self.kb_focus = null;
    self.repeat_active = false;
    self.keys_down = .initEmpty();
}

fn onKeyboardKey(
    data: ?*anyopaque,
    _: ?*wl.Proxy,
    serial: u32,
    _: u32,
    evdev_key: u32,
    key_state: u32,
) callconv(.c) void {
    const self: *Seat = @ptrCast(@alignCast(data.?));
    self.last_serial = serial;
    const win = self.kb_focus orelse return;
    const xkb_lib = if (backend.state.xkb) |*x| x else return;
    const xkb_st = self.xkb_state orelse return;

    const xkb_code: c_xkb.xkb_keycode_t = evdev_key +% 8;
    const base_sym: c_xkb.xkb_keysym_t = blk: {
        if (self.xkb_keymap) |km| {
            const layout = xkb_lib.xkb_state_key_get_layout(xkb_st, xkb_code);
            var syms: [*c]const c_xkb.xkb_keysym_t = null;
            if (xkb_lib.xkb_keymap_key_get_syms_by_level(km, xkb_code, layout, 0, &syms) > 0 and syms != null) {
                break :blk syms[0];
            }
        }
        break :blk xkb_lib.xkb_state_key_get_one_sym(xkb_st, xkb_code);
    };
    const pressed = key_state == proto.keyboard.key_state_pressed;

    const mapped_key = key.fromKeysym(base_sym);
    if (mapped_key) |k| {
        const idx: usize = @intFromEnum(k);
        if (idx < key_bitset_len) {
            if (pressed) self.keys_down.set(idx) else self.keys_down.unset(idx);
        }
        backend.pushEvent(.{ .key = .{
            .window = win.windowHandle(),
            .key = k,
            .mods = self.mods,
            .action = if (pressed) .press else .release,
        } });
    }

    var text_cp: u21 = 0;
    if (pressed and !self.mods.ctrl and !self.mods.alt and !self.mods.super) {
        const raw_cp = xkb_lib.xkb_state_key_get_utf32(xkb_st, xkb_code);
        if (raw_cp >= 0x20 and raw_cp != 0x7f and raw_cp <= 0x10FFFF) {
            text_cp = @intCast(raw_cp);
            backend.pushEvent(.{ .text = .{
                .window = win.windowHandle(),
                .codepoint = text_cp,
            } });
        }
    }

    if (pressed) {
        if (mapped_key) |k| {
            const repeats = if (self.xkb_keymap) |km| xkb_lib.xkb_keymap_key_repeats(km, xkb_code) != 0 else false;
            if (repeats) self.startRepeat(xkb_code, k, text_cp, monotonicNs());
        }
    } else {
        self.stopRepeat(xkb_code);
    }
}

fn onKeyboardModifiers(
    data: ?*anyopaque,
    _: ?*wl.Proxy,
    serial: u32,
    depressed: u32,
    latched: u32,
    locked: u32,
    group: u32,
) callconv(.c) void {
    const self: *Seat = @ptrCast(@alignCast(data.?));
    self.last_serial = serial;
    const xkb_lib = if (backend.state.xkb) |*x| x else return;
    const xkb_st = self.xkb_state orelse return;
    _ = xkb_lib.xkb_state_update_mask(xkb_st, depressed, latched, locked, 0, 0, group);
    self.mods = .{
        .shift = xkb_lib.xkb_state_mod_name_is_active(xkb_st, c_xkb.XKB_MOD_NAME_SHIFT, c_xkb.XKB_STATE_MODS_EFFECTIVE) > 0,
        .ctrl = xkb_lib.xkb_state_mod_name_is_active(xkb_st, c_xkb.XKB_MOD_NAME_CTRL, c_xkb.XKB_STATE_MODS_EFFECTIVE) > 0,
        .alt = xkb_lib.xkb_state_mod_name_is_active(xkb_st, c_xkb.XKB_MOD_NAME_ALT, c_xkb.XKB_STATE_MODS_EFFECTIVE) > 0,
        .super = xkb_lib.xkb_state_mod_name_is_active(xkb_st, c_xkb.XKB_MOD_NAME_LOGO, c_xkb.XKB_STATE_MODS_EFFECTIVE) > 0,
    };
}

fn onKeyboardRepeatInfo(data: ?*anyopaque, _: ?*wl.Proxy, rate: i32, delay: i32) callconv(.c) void {
    const self: *Seat = @ptrCast(@alignCast(data.?));
    self.repeat_rate_hz = if (rate > 0) @intCast(rate) else 0;
    self.repeat_delay_ms = if (delay > 0) @intCast(delay) else 0;
}

fn onPointerEnter(
    data: ?*anyopaque,
    _: ?*wl.Proxy,
    serial: u32,
    surface: ?*wl.Proxy,
    sx: i32,
    sy: i32,
) callconv(.c) void {
    const self: *Seat = @ptrCast(@alignCast(data.?));
    self.last_serial = serial;
    self.pointer_enter_serial = serial;
    const win = backend.findWindowBySurface(surface) orelse return;
    self.ptr_focus = win;
    ensureCursorShapeDevice(self);
    self.applyCursor(win);
    backend.pushEvent(.{ .cursor_enter = .{
        .window = win.windowHandle(),
        .entered = true,
    } });
    backend.pushEvent(.{ .cursor_pos = .{
        .window = win.windowHandle(),
        .x = key.pointerPixelPos(sx, win.scale),
        .y = key.pointerPixelPos(sy, win.scale),
    } });
}

fn onPointerLeave(data: ?*anyopaque, _: ?*wl.Proxy, serial: u32, _: ?*wl.Proxy) callconv(.c) void {
    const self: *Seat = @ptrCast(@alignCast(data.?));
    self.last_serial = serial;
    if (self.ptr_focus) |win| {
        backend.pushEvent(.{ .cursor_enter = .{
            .window = win.windowHandle(),
            .entered = false,
        } });
        self.ptr_focus = null;
    }
}

fn onPointerMotion(data: ?*anyopaque, _: ?*wl.Proxy, _: u32, sx: i32, sy: i32) callconv(.c) void {
    const self: *Seat = @ptrCast(@alignCast(data.?));
    const win = self.ptr_focus orelse return;
    backend.pushEvent(.{ .cursor_pos = .{
        .window = win.windowHandle(),
        .x = key.pointerPixelPos(sx, win.scale),
        .y = key.pointerPixelPos(sy, win.scale),
    } });
}

fn onPointerButton(
    data: ?*anyopaque,
    _: ?*wl.Proxy,
    serial: u32,
    _: u32,
    button_code: u32,
    btn_state: u32,
) callconv(.c) void {
    const self: *Seat = @ptrCast(@alignCast(data.?));
    self.last_serial = serial;
    const win = self.ptr_focus orelse return;
    const btn = key.mouseButton(button_code) orelse return;
    backend.pushEvent(.{ .mouse_button = .{
        .window = win.windowHandle(),
        .button = btn,
        .action = if (btn_state == proto.pointer.button_state_pressed) .press else .release,
        .mods = self.mods,
    } });
}

fn onPointerAxis(data: ?*anyopaque, _: ?*wl.Proxy, _: u32, axis: u32, value: i32) callconv(.c) void {
    const self: *Seat = @ptrCast(@alignCast(data.?));
    const pixels = key.fixedToF64(value);
    if (axis == proto.pointer.axis_vertical) {
        self.addScroll(0, key.verticalScroll(pixels));
    } else if (axis == proto.pointer.axis_horizontal) {
        self.addScroll(key.horizontalScroll(pixels), 0);
    }
}

fn onPointerFrame(data: ?*anyopaque, _: ?*wl.Proxy) callconv(.c) void {
    const self: *Seat = @ptrCast(@alignCast(data.?));
    const scroll = self.pending_scroll orelse return;
    self.pending_scroll = null;
    const win = self.ptr_focus orelse return;
    if (scroll.dx != 0 or scroll.dy != 0) {
        backend.pushEvent(.{ .scroll = .{
            .window = win.windowHandle(),
            .dx = scroll.dx,
            .dy = scroll.dy,
        } });
    }
}

fn onPointerAxisSource(_: ?*anyopaque, _: ?*wl.Proxy, _: u32) callconv(.c) void {}
fn onPointerAxisStop(_: ?*anyopaque, _: ?*wl.Proxy, _: u32, _: u32) callconv(.c) void {}
fn onPointerAxisDiscrete(_: ?*anyopaque, _: ?*wl.Proxy, _: u32, _: i32) callconv(.c) void {}
fn onPointerAxisValue120(_: ?*anyopaque, _: ?*wl.Proxy, _: u32, _: i32) callconv(.c) void {}
fn onPointerAxisRelativeDirection(_: ?*anyopaque, _: ?*wl.Proxy, _: u32, _: u32) callconv(.c) void {}

const seat_listener: proto.seat.Listener = .{
    .capabilities = onSeatCapabilities,
    .name = onSeatName,
};

const keyboard_listener: proto.keyboard.Listener = .{
    .keymap = onKeyboardKeymap,
    .enter = onKeyboardEnter,
    .leave = onKeyboardLeave,
    .key = onKeyboardKey,
    .modifiers = onKeyboardModifiers,
    .repeat_info = onKeyboardRepeatInfo,
};

const pointer_listener: proto.pointer.Listener = .{
    .enter = onPointerEnter,
    .leave = onPointerLeave,
    .motion = onPointerMotion,
    .button = onPointerButton,
    .axis = onPointerAxis,
    .frame = onPointerFrame,
    .axis_source = onPointerAxisSource,
    .axis_stop = onPointerAxisStop,
    .axis_discrete = onPointerAxisDiscrete,
    .axis_value120 = onPointerAxisValue120,
    .axis_relative_direction = onPointerAxisRelativeDirection,
};
