//! Native Wayland implementation of the Rex platform interface. Wayland,
//! wayland-egl, EGL and xkbcommon are loaded at runtime; this backend owns the
//! display connection, GL contexts, pinned window slots and the event pump.

const std = @import("std");
const builtin = @import("builtin");

const e = @import("egl");
const w = @import("wayland");
const gl = @import("../../renderer/gl.zig");
const Dimension = @import("../../renderer/dimension.zig").Dimension;
const window_config = @import("../../config/window.zig");
const input_key = @import("../../input/key.zig");
const pipe = @import("../../termio/pipe.zig");
const egl = @import("../egl.zig");
const events = @import("../Event.zig");
const Window = @import("../Window.zig");
const proto = @import("proto.zig");
const seat = @import("seat.zig");
const selection = @import("selection.zig");
const text_input = @import("text_input.zig");
const WaylandWindow = @import("WaylandWindow.zig");
const wl = @import("wl.zig");
const wl_egl = @import("wl_egl.zig");
const xkb = @import("xkb.zig");

const log = std.log.scoped(.platform);
const posix = std.posix;
const system = posix.system;

/// The OpenGL core version the renderer targets. The shaders are GLSL 330.
pub const gl_version: struct { major: c_int, minor: c_int } = .{ .major = 3, .minor = 3 };

pub const Event = events.Event;
pub const Ring = events.Ring;

/// The window systems this build can start on. A native Wayland binary
/// supports only Wayland; X11 needs its own backend.
pub const System = enum {
    x11,
    wayland,

    fn name(self: System) []const u8 {
        return switch (self) {
            .x11 => "x11",
            .wayland => "wayland",
        };
    }
};

/// The selected window system and whether the user forced it.
pub const Choice = struct {
    system: System,
    forced: bool,

    /// Writes the system name for the startup log.
    pub fn format(self: Choice, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("{s}", .{self.system.name()});
    }
};

/// `auto` is Wayland on a Wayland-only build. A forced X11 choice fails at
/// `init` with a clear error rather than silently starting Wayland.
pub fn choose(requested: window_config.Platform, wayland_session: bool) Choice {
    _ = wayland_session;
    return switch (requested) {
        .auto, .wayland => .{ .system = .wayland, .forced = requested != .auto },
        .x11 => .{ .system = .x11, .forced = true },
    };
}

const max_windows = 8;

const Phase = enum {
    none,
    ready,
};

const State = struct {
    phase: Phase = .none,
    event_ring: Ring = .{},
    wl: ?wl.Wayland = null,
    wl_egl: ?wl_egl.WaylandEgl = null,
    egl: ?egl.Egl = null,
    xkb: ?xkb.Xkb = null,
    display: ?*wl.Display = null,
    registry: ?*wl.Proxy = null,
    compositor: ?*wl.Proxy = null,
    xdg_wm_base: ?*wl.Proxy = null,
    xdg_decoration_manager: ?*wl.Proxy = null,
    fractional_scale_manager: ?*wl.Proxy = null,
    viewporter: ?*wl.Proxy = null,
    text_input_manager: ?*wl.Proxy = null,
    cursor_shape_manager: ?*wl.Proxy = null,
    data_device_manager: ?*wl.Proxy = null,
    primary_selection_manager: ?*wl.Proxy = null,
    xdg_activation: ?*wl.Proxy = null,
    xdg_system_bell: ?*wl.Proxy = null,
    seat: ?*wl.Proxy = null,
    seat_state: seat.Seat = .{},
    text_input_state: text_input.TextInput = .{},
    egl_display: e.EGLDisplay = null,
    egl_config: e.EGLConfig = null,
    context: e.EGLContext = null,
    test_wl_surface: ?*wl.Proxy = null,
    test_egl_window: ?*w.wl_egl_window = null,
    test_surface: e.EGLSurface = null,
    test_context: e.EGLContext = null,
    window_slots: [max_windows]WaylandWindow = undefined,
    window_used: [max_windows]bool = @splat(false),
    wakeup_read: posix.fd_t = -1,
    wakeup_write: posix.fd_t = -1,
};

pub var state: State = .{};
/// Kept in `.bss` separately from `state` so its 3 MiB fixed selection buffers
/// are never copied on the stack during `state = .{}` resets.
pub var selection_state: selection.Selection = .{};

pub const InitError = error{
    X11Unavailable,
    WaylandUnavailable,
    EglUnavailable,
    XkbUnavailable,
    GlInitFailed,
};

/// Initialises Wayland, EGL and a core GL 3.3 context. A forced X11 choice
/// fails loudly rather than silently starting Wayland.
pub fn init(choice: Choice) InitError!void {
    if (choice.system == .x11) {
        if (!builtin.is_test) {
            log.err("this build has no X11 backend; rebuild with an X11 backend or choose wayland", .{});
        }
        return error.X11Unavailable;
    }
    if (state.phase == .ready) return;

    var wl_lib = wl.load() catch {
        log.err("cannot load {s} at runtime", .{wl.soname});
        return error.WaylandUnavailable;
    };
    errdefer wl_lib.deinit();

    var wl_egl_lib = wl_egl.load() catch {
        log.err("cannot load {s} at runtime", .{wl_egl.soname});
        return error.WaylandUnavailable;
    };
    errdefer wl_egl_lib.deinit();

    var egl_lib = egl.load() catch {
        log.err("cannot load {s} at runtime", .{egl.soname});
        return error.EglUnavailable;
    };
    errdefer egl_lib.lib.close();

    var xkb_lib = xkb.load() catch {
        log.err("cannot load {s} at runtime", .{xkb.soname});
        return error.XkbUnavailable;
    };
    errdefer xkb_lib.deinit();

    const display = wl_lib.wl_display_connect(null) orelse {
        log.err("cannot connect to a Wayland display", .{});
        return error.WaylandUnavailable;
    };
    errdefer wl_lib.wl_display_disconnect(display);

    var wakeup_fds: [2]posix.fd_t = undefined;
    pipe.open(&wakeup_fds, .{ .CLOEXEC = true, .NONBLOCK = true }) catch return error.WaylandUnavailable;
    errdefer {
        _ = system.close(wakeup_fds[0]);
        _ = system.close(wakeup_fds[1]);
    }

    state = .{
        .phase = .none,
        .wl = wl_lib,
        .wl_egl = wl_egl_lib,
        .egl = egl_lib,
        .xkb = xkb_lib,
        .display = display,
        .wakeup_read = wakeup_fds[0],
        .wakeup_write = wakeup_fds[1],
    };
    errdefer {
        destroyGlobals();
        state = .{};
    }

    const reg = wl_lib.wl_proxy_marshal_flags(
        @ptrCast(display),
        proto.display.get_registry,
        wl_lib.registry_interface,
        wl_lib.wl_proxy_get_version(@ptrCast(display)),
        0,
        @as(?*anyopaque, null),
    ) orelse return error.WaylandUnavailable;
    state.registry = reg;
    _ = wl_lib.wl_proxy_add_listener(reg, @ptrCast(@constCast(&registry_listener)), null);
    if (wl_lib.wl_display_roundtrip(display) < 0) return error.WaylandUnavailable;

    if (state.compositor == null or state.xdg_wm_base == null) {
        log.err("Wayland compositor missing wl_compositor or xdg_wm_base", .{});
        return error.WaylandUnavailable;
    }

    const edpy = egl_lib.getPlatformDisplay(e.EGL_PLATFORM_WAYLAND_KHR, display, null);
    if (edpy == e.EGL_NO_DISPLAY) return error.GlInitFailed;
    errdefer _ = egl_lib.eglTerminate(edpy);

    var major: e.EGLint = 0;
    var minor: e.EGLint = 0;
    if (egl_lib.eglInitialize(edpy, &major, &minor) == 0) return error.GlInitFailed;
    if (egl_lib.eglBindAPI(e.EGL_OPENGL_API) == 0) return error.GlInitFailed;

    const cfg_attr = [_]e.EGLint{
        e.EGL_SURFACE_TYPE,    e.EGL_WINDOW_BIT,
        e.EGL_RENDERABLE_TYPE, e.EGL_OPENGL_BIT,
        e.EGL_RED_SIZE,        8,
        e.EGL_GREEN_SIZE,      8,
        e.EGL_BLUE_SIZE,       8,
        e.EGL_ALPHA_SIZE,      8,
        e.EGL_NONE,
    };
    var config: e.EGLConfig = null;
    var count: e.EGLint = 0;
    if (egl_lib.eglChooseConfig(edpy, &cfg_attr, &config, 1, &count) == 0 or count == 0) {
        return error.GlInitFailed;
    }

    const ctx_attr = [_]e.EGLint{
        e.EGL_CONTEXT_MAJOR_VERSION,       gl_version.major,
        e.EGL_CONTEXT_MINOR_VERSION,       gl_version.minor,
        e.EGL_CONTEXT_OPENGL_PROFILE_MASK, e.EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT,
        e.EGL_NONE,
    };
    const ctx = egl_lib.eglCreateContext(edpy, config, null, &ctx_attr);
    if (ctx == e.EGL_NO_CONTEXT) return error.GlInitFailed;

    state.egl_display = edpy;
    state.egl_config = config;
    state.context = ctx;
    state.phase = .ready;
    errdefer comptime unreachable;
}

/// Releases all windows, EGL/GL state, Wayland objects and runtime libraries.
pub fn deinit() void {
    if (state.phase != .ready) return;

    for (&state.window_slots, &state.window_used) |*slot, *used| {
        if (used.*) {
            slot.deinit();
            used.* = false;
        }
    }

    const egl_lib = &state.egl.?;
    const wl_egl_lib = &state.wl_egl.?;
    const wl_lib = &state.wl.?;

    if (state.egl_display != e.EGL_NO_DISPLAY) {
        _ = egl_lib.eglMakeCurrent(state.egl_display, e.EGL_NO_SURFACE, e.EGL_NO_SURFACE, e.EGL_NO_CONTEXT);
        if (state.test_context != e.EGL_NO_CONTEXT) _ = egl_lib.eglDestroyContext(state.egl_display, state.test_context);
        if (state.test_surface != e.EGL_NO_SURFACE) _ = egl_lib.eglDestroySurface(state.egl_display, state.test_surface);
        if (state.context != e.EGL_NO_CONTEXT) _ = egl_lib.eglDestroyContext(state.egl_display, state.context);
        _ = egl_lib.eglTerminate(state.egl_display);
    }
    if (state.test_egl_window) |ew| wl_egl_lib.wl_egl_window_destroy(ew);
    if (state.test_wl_surface) |s| {
        _ = wl_lib.wl_proxy_marshal_flags(s, proto.surface.destroy, null, wl_lib.wl_proxy_get_version(s), proto.marshal_flag_destroy);
    }

    destroyGlobals();
    if (state.display) |dpy| wl_lib.wl_display_disconnect(dpy);
    if (state.wakeup_read >= 0) _ = system.close(state.wakeup_read);
    if (state.wakeup_write >= 0) _ = system.close(state.wakeup_write);

    if (state.xkb) |*x| x.deinit();
    if (state.egl) |*eg| eg.lib.close();
    if (state.wl_egl) |*we| we.deinit();
    if (state.wl) |*wlib| wlib.deinit();
    state = .{};
}

fn gladLoader(name: [*c]const u8) callconv(.c) ?*anyopaque {
    const proc = state.egl.?.eglGetProcAddress(name);
    if (proc == null) return null;
    const p: *const anyopaque = @ptrCast(proc);
    return @constCast(p);
}

/// Function pointer loader for GLAD.
pub fn getProcAddress() gl.GLADloadproc {
    return &gladLoader;
}

/// Wakes a thread blocked in `waitEvents`.
pub fn postWakeup() void {
    if (state.wakeup_write < 0) return;
    const byte = [1]u8{1};
    _ = system.write(state.wakeup_write, &byte, 1);
}

/// Processes pending Wayland events without blocking.
pub fn pollEvents() void {
    if (state.phase != .ready) return;
    const wl_lib = &state.wl.?;
    const dpy = state.display orelse return;

    _ = wl_lib.wl_display_dispatch_pending(dpy);
    _ = wl_lib.wl_display_flush(dpy);

    while (wl_lib.wl_display_prepare_read(dpy) != 0) {
        _ = wl_lib.wl_display_dispatch_pending(dpy);
    }
    var pfd = [1]posix.pollfd{.{
        .fd = wl_lib.wl_display_get_fd(dpy),
        .events = posix.POLL.IN,
        .revents = 0,
    }};
    const ready = system.poll(&pfd, 1, 0);
    if (ready > 0 and (pfd[0].revents & posix.POLL.IN) != 0) {
        if (wl_lib.wl_display_read_events(dpy) == 0) {
            _ = wl_lib.wl_display_dispatch_pending(dpy);
        }
    } else {
        wl_lib.wl_display_cancel_read(dpy);
    }
    state.seat_state.tickRepeat(seat.monotonicNs());
}

/// Waits for Wayland events or a wakeup signal, up to `timeout_ms`.
pub fn waitEvents(timeout_ms: ?f64) void {
    if (state.phase != .ready) return;
    const wl_lib = &state.wl.?;
    const dpy = state.display orelse return;

    while (wl_lib.wl_display_prepare_read(dpy) != 0) {
        _ = wl_lib.wl_display_dispatch_pending(dpy);
    }
    _ = wl_lib.wl_display_flush(dpy);

    var pfds = [2]posix.pollfd{
        .{ .fd = wl_lib.wl_display_get_fd(dpy), .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = state.wakeup_read, .events = posix.POLL.IN, .revents = 0 },
    };
    const repeat_ms = state.seat_state.repeatTimeoutMs(seat.monotonicNs());
    const effective_ms: ?f64 = if (timeout_ms) |t|
        (if (repeat_ms) |r| @min(t, r) else t)
    else
        repeat_ms;
    const timeout: i32 = if (effective_ms) |ms| blk: {
        const clamped = @max(ms, 0.0);
        const max_ms: f64 = @floatFromInt(std.math.maxInt(i32));
        break :blk @intFromFloat(@min(clamped, max_ms));
    } else -1;

    const ready = system.poll(&pfds, 2, timeout);
    if (ready > 0 and (pfds[0].revents & posix.POLL.IN) != 0) {
        if (wl_lib.wl_display_read_events(dpy) == 0) {
            _ = wl_lib.wl_display_dispatch_pending(dpy);
        }
    } else {
        wl_lib.wl_display_cancel_read(dpy);
    }

    if (ready > 0 and (pfds[1].revents & posix.POLL.IN) != 0) {
        drainWakeup();
    }
    state.seat_state.tickRepeat(seat.monotonicNs());
}

/// Monotonic clock in seconds.
pub fn now(io: std.Io) f64 {
    const ns = std.Io.Clock.Timestamp.now(io, .awake).raw.toNanoseconds();
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_s;
}

/// Primary monitor refresh rate, or null when unknown.
pub fn primaryRefreshHz() ?u32 {
    return 60;
}

/// Whether `k` is currently held on `window`.
pub fn isKeyDown(window: Window, k: input_key.Key) bool {
    return state.seat_state.isKeyDown(fromHandle(window), k);
}

/// Finds the active `WaylandWindow` owning `surface`, or null.
pub fn findWindowBySurface(surface: ?*wl.Proxy) ?*WaylandWindow {
    const target = surface orelse return null;
    for (&state.window_slots, &state.window_used) |*slot, used| {
        if (used and slot.wl_surface == target) return slot;
    }
    return null;
}

/// Appends `event` to the bounded event ring.
pub fn pushEvent(event: Event) void {
    state.event_ring.push(event);
}

/// Pops the oldest event from the bounded event ring into `out`.
pub fn nextEvent(out: *Event) bool {
    return state.event_ring.next(out);
}

/// Returns and resets the number of events dropped due to a full ring.
pub fn takeDropped() u32 {
    return state.event_ring.takeDropped();
}

/// Readies a hidden GL 3.3 core context for renderer tests, skipping without a
/// Wayland compositor.
pub fn testGlContext() error{SkipZigTest}!void {
    if (state.phase != .ready) {
        init(.{ .system = .wayland, .forced = false }) catch return error.SkipZigTest;
    }
    if (state.test_context != e.EGL_NO_CONTEXT) {
        if (state.egl.?.eglMakeCurrent(state.egl_display, state.test_surface, state.test_surface, state.test_context) == 0) {
            return error.SkipZigTest;
        }
        return;
    }

    const wl_lib = &state.wl.?;
    const wl_egl_lib = &state.wl_egl.?;
    const egl_lib = &state.egl.?;
    const compositor = state.compositor orelse return error.SkipZigTest;

    const surf = wl_lib.wl_proxy_marshal_flags(
        compositor,
        proto.compositor.create_surface,
        wl_lib.surface_interface,
        wl_lib.wl_proxy_get_version(compositor),
        0,
        @as(?*anyopaque, null),
    ) orelse return error.SkipZigTest;
    errdefer _ = wl_lib.wl_proxy_marshal_flags(surf, proto.surface.destroy, null, wl_lib.wl_proxy_get_version(surf), proto.marshal_flag_destroy);

    const egl_win = wl_egl_lib.wl_egl_window_create(@ptrCast(surf), 64, 64) orelse return error.SkipZigTest;
    errdefer wl_egl_lib.wl_egl_window_destroy(egl_win);

    const native_win: e.EGLNativeWindowType = @intFromPtr(egl_win);
    const egl_surf = egl_lib.eglCreateWindowSurface(state.egl_display, state.egl_config, native_win, null);
    if (egl_surf == e.EGL_NO_SURFACE) return error.SkipZigTest;
    errdefer _ = egl_lib.eglDestroySurface(state.egl_display, egl_surf);

    const ctx_attr = [_]e.EGLint{
        e.EGL_CONTEXT_MAJOR_VERSION,       gl_version.major,
        e.EGL_CONTEXT_MINOR_VERSION,       gl_version.minor,
        e.EGL_CONTEXT_OPENGL_PROFILE_MASK, e.EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT,
        e.EGL_NONE,
    };
    const ctx = egl_lib.eglCreateContext(state.egl_display, state.egl_config, state.context, &ctx_attr);
    if (ctx == e.EGL_NO_CONTEXT) return error.SkipZigTest;
    errdefer _ = egl_lib.eglDestroyContext(state.egl_display, ctx);

    if (egl_lib.eglMakeCurrent(state.egl_display, egl_surf, egl_surf, ctx) == 0) return error.SkipZigTest;
    if (gl.gladLoadGLLoader(getProcAddress()) == 0) return error.SkipZigTest;

    state.test_wl_surface = surf;
    state.test_egl_window = egl_win;
    state.test_surface = egl_surf;
    state.test_context = ctx;
}

/// Pushes a synthetic key press into the event ring for tests.
pub fn testKeyEvent(window: Window, k: input_key.Key) void {
    pushEvent(.{ .key = .{
        .window = window,
        .key = k,
        .mods = .{},
        .action = .press,
    } });
}

/// Creates a Wayland window in a free pinned backend slot.
pub fn createWindow(option: WaylandWindow.InitOption) (WaylandWindow.Error || error{ TooManyWindows, NotInitialized })!Window {
    if (state.phase != .ready) return error.NotInitialized;
    for (&state.window_slots, &state.window_used) |*slot, *used| {
        if (!used.*) {
            try slot.init(option);
            used.* = true;
            return slot.windowHandle();
        }
    }
    return error.TooManyWindows;
}

/// Destroys a Wayland window and frees its backend slot.
pub fn destroyWindow(window: Window) void {
    const ptr = fromHandle(window);
    for (&state.window_slots, &state.window_used) |*slot, *used| {
        if (slot == ptr and used.*) {
            state.seat_state.onWindowDestroyed(slot);
            state.text_input_state.onWindowDestroyed(slot);
            slot.deinit();
            used.* = false;
            return;
        }
    }
}

pub fn windowSetContext(window: Window, ptr: ?*anyopaque) void {
    fromHandle(window).context_ptr = ptr;
}

pub fn windowGetContext(window: Window) ?*anyopaque {
    return fromHandle(window).context_ptr;
}

pub fn windowSetTitle(window: Window, title: [:0]const u8) void {
    fromHandle(window).setTitle(title);
}

pub fn windowShouldClose(window: Window) bool {
    return fromHandle(window).should_close;
}

pub fn windowSetShouldClose(window: Window, set: bool) void {
    fromHandle(window).should_close = set;
}

pub fn windowSwapBuffers(window: Window) void {
    fromHandle(window).swapBuffers();
}

pub fn windowFramebufferSize(window: Window, comptime T: type) Dimension(T) {
    return fromHandle(window).framebufferSize(T);
}

pub fn windowContentScale(window: Window) Dimension(f32) {
    return fromHandle(window).contentScale();
}

pub fn windowFocused(window: Window) bool {
    return fromHandle(window).focused;
}

pub fn windowSetMinimumSize(window: Window, width: c_int, height: c_int) void {
    fromHandle(window).setMinimumSize(width, height);
}

pub fn windowSetPointerShape(window: Window, shape: Window.PointerShape) void {
    const win = fromHandle(window);
    win.pointer_shape = shape;
    state.seat_state.applyCursor(win);
}

pub fn windowSetPointerVisible(window: Window, visible: bool) void {
    const win = fromHandle(window);
    win.pointer_visible = visible;
    state.seat_state.applyCursor(win);
}

pub fn windowSetClipboard(_: Window, text: [:0]const u8) void {
    selection_state.setClipboard(text);
}

pub fn windowGetClipboard(_: Window) ?[:0]const u8 {
    return selection_state.getClipboard();
}

pub fn windowGetPrimarySelection(_: Window) ?[:0]const u8 {
    return selection_state.getPrimary();
}

pub fn windowSetPrimarySelection(_: Window, text: [:0]const u8) bool {
    return selection_state.setPrimary(text);
}

pub fn windowRequestAttention(window: Window) void {
    const wl_lib = if (state.wl) |*wlib| wlib else return;
    const activation = state.xdg_activation orelse return;
    const win = fromHandle(window);
    const surf = win.wl_surface orelse return;
    const ifaces = proto.interfaces();

    const token = wl_lib.wl_proxy_marshal_flags(
        activation,
        proto.xdg_activation.get_activation_token,
        ifaces.xdg_activation_token,
        wl_lib.wl_proxy_get_version(activation),
        0,
        @as(?*anyopaque, null),
    ) orelse return;
    _ = wl_lib.wl_proxy_add_listener(token, @ptrCast(@constCast(&activation_token_listener)), win);
    const ver = wl_lib.wl_proxy_get_version(token);
    const app_id: [:0]const u8 = "rex";
    _ = wl_lib.wl_proxy_marshal_flags(token, proto.xdg_activation_token.set_app_id, null, ver, 0, app_id.ptr);
    _ = wl_lib.wl_proxy_marshal_flags(token, proto.xdg_activation_token.set_surface, null, ver, 0, surf);
    if (state.seat) |s| {
        if (state.seat_state.last_serial != 0) {
            _ = wl_lib.wl_proxy_marshal_flags(token, proto.xdg_activation_token.set_serial, null, ver, 0, state.seat_state.last_serial, s);
        }
    }
    _ = wl_lib.wl_proxy_marshal_flags(token, proto.xdg_activation_token.commit, null, ver, 0);
    if (state.display) |dpy| _ = wl_lib.wl_display_flush(dpy);
}

pub fn windowRingBell(window: Window, volume: f32) void {
    if (volume <= 0) return;
    const wl_lib = if (state.wl) |*wlib| wlib else return;
    if (state.xdg_system_bell) |bell| {
        const surf = fromHandle(window).wl_surface;
        _ = wl_lib.wl_proxy_marshal_flags(
            bell,
            proto.xdg_system_bell.ring,
            null,
            wl_lib.wl_proxy_get_version(bell),
            0,
            surf,
        );
        if (state.display) |dpy| _ = wl_lib.wl_display_flush(dpy);
        return;
    }
    // Degrade to attention-only bell when the compositor omits xdg_system_bell_v1.
    windowRequestAttention(window);
}

fn fromHandle(window: Window) *WaylandWindow {
    return @ptrCast(@alignCast(window.impl));
}

fn drainWakeup() void {
    var buf: [64]u8 = undefined;
    while (system.read(state.wakeup_read, &buf, buf.len) > 0) {}
}

fn destroyGlobals() void {
    selection_state.deinit();
    state.text_input_state.deinit();
    state.seat_state.deinit();
    const wl_lib = if (state.wl) |*wlib| wlib else return;
    if (state.xdg_system_bell) |p| {
        _ = wl_lib.wl_proxy_marshal_flags(p, proto.xdg_system_bell.destroy, null, wl_lib.wl_proxy_get_version(p), proto.marshal_flag_destroy);
        state.xdg_system_bell = null;
    }
    if (state.xdg_activation) |p| {
        _ = wl_lib.wl_proxy_marshal_flags(p, proto.xdg_activation.destroy, null, wl_lib.wl_proxy_get_version(p), proto.marshal_flag_destroy);
        state.xdg_activation = null;
    }
    if (state.primary_selection_manager) |p| {
        _ = wl_lib.wl_proxy_marshal_flags(p, proto.primary_selection_manager.destroy, null, wl_lib.wl_proxy_get_version(p), proto.marshal_flag_destroy);
        state.primary_selection_manager = null;
    }
    if (state.data_device_manager) |p| {
        wl_lib.wl_proxy_destroy(p);
        state.data_device_manager = null;
    }
    if (state.text_input_manager) |p| {
        _ = wl_lib.wl_proxy_marshal_flags(p, proto.text_input_manager.destroy, null, wl_lib.wl_proxy_get_version(p), proto.marshal_flag_destroy);
        state.text_input_manager = null;
    }
    if (state.viewporter) |p| {
        _ = wl_lib.wl_proxy_marshal_flags(p, proto.viewporter.destroy, null, wl_lib.wl_proxy_get_version(p), proto.marshal_flag_destroy);
        state.viewporter = null;
    }
    if (state.fractional_scale_manager) |p| {
        _ = wl_lib.wl_proxy_marshal_flags(p, proto.fractional_scale_manager.destroy, null, wl_lib.wl_proxy_get_version(p), proto.marshal_flag_destroy);
        state.fractional_scale_manager = null;
    }
    if (state.cursor_shape_manager) |p| {
        _ = wl_lib.wl_proxy_marshal_flags(p, proto.cursor_shape_manager.destroy, null, wl_lib.wl_proxy_get_version(p), proto.marshal_flag_destroy);
        state.cursor_shape_manager = null;
    }
    if (state.xdg_decoration_manager) |p| {
        _ = wl_lib.wl_proxy_marshal_flags(p, proto.xdg_decoration_manager.destroy, null, wl_lib.wl_proxy_get_version(p), proto.marshal_flag_destroy);
        state.xdg_decoration_manager = null;
    }
    if (state.xdg_wm_base) |p| {
        _ = wl_lib.wl_proxy_marshal_flags(p, proto.xdg_wm_base.destroy, null, wl_lib.wl_proxy_get_version(p), proto.marshal_flag_destroy);
        state.xdg_wm_base = null;
    }
    if (state.seat) |p| {
        if (wl_lib.wl_proxy_get_version(p) >= 5) {
            _ = wl_lib.wl_proxy_marshal_flags(p, proto.seat.release, null, wl_lib.wl_proxy_get_version(p), proto.marshal_flag_destroy);
        } else {
            wl_lib.wl_proxy_destroy(p);
        }
        state.seat = null;
    }
    if (state.compositor) |p| {
        wl_lib.wl_proxy_destroy(p);
        state.compositor = null;
    }
    if (state.registry) |p| {
        wl_lib.wl_proxy_destroy(p);
        state.registry = null;
    }
}

fn onRegistryGlobal(
    _: ?*anyopaque,
    registry: ?*wl.Proxy,
    name: u32,
    interface: [*c]const u8,
    version: u32,
) callconv(.c) void {
    const wl_lib = &state.wl.?;
    const ifaces = proto.interfaces();
    const iface_name = std.mem.span(interface);

    if (std.mem.eql(u8, iface_name, "wl_compositor") and state.compositor == null) {
        const v: u32 = @min(version, 4);
        state.compositor = wl_lib.wl_proxy_marshal_flags(
            registry,
            proto.registry.bind,
            wl_lib.compositor_interface,
            v,
            0,
            name,
            wl_lib.compositor_interface.name,
            v,
            @as(?*anyopaque, null),
        );
    } else if (std.mem.eql(u8, iface_name, "xdg_wm_base") and state.xdg_wm_base == null) {
        const v: u32 = @min(version, 5);
        if (wl_lib.wl_proxy_marshal_flags(
            registry,
            proto.registry.bind,
            ifaces.xdg_wm_base,
            v,
            0,
            name,
            ifaces.xdg_wm_base.name,
            v,
            @as(?*anyopaque, null),
        )) |wm_base| {
            state.xdg_wm_base = wm_base;
            _ = wl_lib.wl_proxy_add_listener(wm_base, @ptrCast(@constCast(&xdg_wm_base_listener)), null);
        }
    } else if (std.mem.eql(u8, iface_name, "zxdg_decoration_manager_v1") and state.xdg_decoration_manager == null) {
        const v: u32 = @min(version, 1);
        state.xdg_decoration_manager = wl_lib.wl_proxy_marshal_flags(
            registry,
            proto.registry.bind,
            ifaces.xdg_decoration_manager,
            v,
            0,
            name,
            ifaces.xdg_decoration_manager.name,
            v,
            @as(?*anyopaque, null),
        );
    } else if (std.mem.eql(u8, iface_name, "wp_fractional_scale_manager_v1") and state.fractional_scale_manager == null) {
        const v: u32 = @min(version, 1);
        state.fractional_scale_manager = wl_lib.wl_proxy_marshal_flags(
            registry,
            proto.registry.bind,
            ifaces.fractional_scale_manager,
            v,
            0,
            name,
            ifaces.fractional_scale_manager.name,
            v,
            @as(?*anyopaque, null),
        );
    } else if (std.mem.eql(u8, iface_name, "wp_viewporter") and state.viewporter == null) {
        const v: u32 = @min(version, 1);
        state.viewporter = wl_lib.wl_proxy_marshal_flags(
            registry,
            proto.registry.bind,
            ifaces.viewporter,
            v,
            0,
            name,
            ifaces.viewporter.name,
            v,
            @as(?*anyopaque, null),
        );
    } else if (std.mem.eql(u8, iface_name, "zwp_text_input_manager_v3") and state.text_input_manager == null) {
        const v: u32 = @min(version, 1);
        state.text_input_manager = wl_lib.wl_proxy_marshal_flags(
            registry,
            proto.registry.bind,
            ifaces.text_input_manager,
            v,
            0,
            name,
            ifaces.text_input_manager.name,
            v,
            @as(?*anyopaque, null),
        );
        if (state.text_input_manager) |mgr| {
            if (state.seat) |s| state.text_input_state.attach(mgr, s);
        }
    } else if (std.mem.eql(u8, iface_name, "wp_cursor_shape_manager_v1") and state.cursor_shape_manager == null) {
        const v: u32 = @min(version, 1);
        state.cursor_shape_manager = wl_lib.wl_proxy_marshal_flags(
            registry,
            proto.registry.bind,
            ifaces.cursor_shape_manager,
            v,
            0,
            name,
            ifaces.cursor_shape_manager.name,
            v,
            @as(?*anyopaque, null),
        );
    } else if (std.mem.eql(u8, iface_name, "wl_data_device_manager") and state.data_device_manager == null) {
        const v: u32 = @min(version, 3);
        state.data_device_manager = wl_lib.wl_proxy_marshal_flags(
            registry,
            proto.registry.bind,
            wl_lib.data_device_manager_interface,
            v,
            0,
            name,
            wl_lib.data_device_manager_interface.name,
            v,
            @as(?*anyopaque, null),
        );
        if (state.data_device_manager) |mgr| {
            if (state.seat) |s| selection_state.attachClipboard(mgr, s);
        }
    } else if (std.mem.eql(u8, iface_name, "zwp_primary_selection_device_manager_v1") and state.primary_selection_manager == null) {
        const v: u32 = @min(version, 1);
        state.primary_selection_manager = wl_lib.wl_proxy_marshal_flags(
            registry,
            proto.registry.bind,
            ifaces.primary_selection_manager,
            v,
            0,
            name,
            ifaces.primary_selection_manager.name,
            v,
            @as(?*anyopaque, null),
        );
        if (state.primary_selection_manager) |mgr| {
            if (state.seat) |s| selection_state.attachPrimary(mgr, s);
        }
    } else if (std.mem.eql(u8, iface_name, "xdg_activation_v1") and state.xdg_activation == null) {
        const v: u32 = @min(version, 1);
        state.xdg_activation = wl_lib.wl_proxy_marshal_flags(
            registry,
            proto.registry.bind,
            ifaces.xdg_activation,
            v,
            0,
            name,
            ifaces.xdg_activation.name,
            v,
            @as(?*anyopaque, null),
        );
    } else if (std.mem.eql(u8, iface_name, "xdg_system_bell_v1") and state.xdg_system_bell == null) {
        const v: u32 = @min(version, 1);
        state.xdg_system_bell = wl_lib.wl_proxy_marshal_flags(
            registry,
            proto.registry.bind,
            ifaces.xdg_system_bell,
            v,
            0,
            name,
            ifaces.xdg_system_bell.name,
            v,
            @as(?*anyopaque, null),
        );
    } else if (std.mem.eql(u8, iface_name, "wl_seat") and state.seat == null) {
        const v: u32 = @min(version, 8);
        if (wl_lib.wl_proxy_marshal_flags(
            registry,
            proto.registry.bind,
            wl_lib.seat_interface,
            v,
            0,
            name,
            wl_lib.seat_interface.name,
            v,
            @as(?*anyopaque, null),
        )) |wl_seat| {
            state.seat = wl_seat;
            state.seat_state.attach(wl_seat);
            if (state.text_input_manager) |mgr| state.text_input_state.attach(mgr, wl_seat);
            if (state.data_device_manager) |mgr| selection_state.attachClipboard(mgr, wl_seat);
            if (state.primary_selection_manager) |mgr| selection_state.attachPrimary(mgr, wl_seat);
        }
    }
}

fn onRegistryGlobalRemove(_: ?*anyopaque, _: ?*wl.Proxy, _: u32) callconv(.c) void {}

fn onXdgWmBasePing(_: ?*anyopaque, wm_base: ?*wl.Proxy, serial: u32) callconv(.c) void {
    const wl_lib = &state.wl.?;
    _ = wl_lib.wl_proxy_marshal_flags(
        wm_base,
        proto.xdg_wm_base.pong,
        null,
        wl_lib.wl_proxy_get_version(wm_base),
        0,
        serial,
    );
}

const registry_listener: proto.registry.Listener = .{
    .global = onRegistryGlobal,
    .global_remove = onRegistryGlobalRemove,
};

fn onActivationTokenDone(data: ?*anyopaque, token_proxy: ?*wl.Proxy, token: [*c]const u8) callconv(.c) void {
    const wl_lib = if (state.wl) |*wlib| wlib else return;
    defer _ = wl_lib.wl_proxy_marshal_flags(token_proxy, proto.xdg_activation_token.destroy, null, wl_lib.wl_proxy_get_version(token_proxy), proto.marshal_flag_destroy);
    const activation = state.xdg_activation orelse return;
    if (token == null or data == null) return;
    const win: *WaylandWindow = @ptrCast(@alignCast(data.?));
    var alive = false;
    for (&state.window_slots, &state.window_used) |*slot, used| {
        if (slot == win and used) {
            alive = true;
            break;
        }
    }
    if (!alive) return;
    const surf = win.wl_surface orelse return;
    _ = wl_lib.wl_proxy_marshal_flags(
        activation,
        proto.xdg_activation.activate,
        null,
        wl_lib.wl_proxy_get_version(activation),
        0,
        token,
        surf,
    );
}

const activation_token_listener: proto.xdg_activation_token.Listener = .{
    .done = onActivationTokenDone,
};

const xdg_wm_base_listener: proto.xdg_wm_base.Listener = .{
    .ping = onXdgWmBasePing,
};
