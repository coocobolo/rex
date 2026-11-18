//! Native X11 implementation of the Rex platform interface. Xlib and EGL are
//! loaded at runtime; this backend owns the connection, GL contexts, window
//! state and the event pump.

const std = @import("std");
const builtin = @import("builtin");

const x = @import("x11");
const e = @import("egl");
const gl = @import("../../renderer/gl.zig");
const window_config = @import("../../config/window.zig");
const events = @import("../Event.zig");
const Window = @import("../Window.zig");
const xlib = @import("xlib.zig");
const egl = @import("egl.zig");

const log = std.log.scoped(.platform);

/// The OpenGL core version the renderer targets. The shaders are GLSL 330.
pub const gl_version: struct { major: c_int, minor: c_int } = .{ .major = 3, .minor = 3 };

pub const Event = events.Event;
pub const Ring = events.Ring;

/// The window systems this build can start on. A native X11 binary supports
/// only X11; Wayland needs its own backend.
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

/// `auto` is X11 on a Linux or FreeBSD build with only the X11 backend. A
/// forced Wayland choice on this build fails at init with a clear error.
pub fn choose(requested: window_config.Platform, wayland_session: bool) Choice {
    _ = wayland_session;
    return switch (requested) {
        .auto, .x11 => .{ .system = .x11, .forced = requested != .auto },
        .wayland => .{ .system = .wayland, .forced = true },
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
    x11: ?xlib.Xlib = null,
    egl: ?egl.Egl = null,
    display: ?*x.Display = null,
    egl_display: e.EGLDisplay = null,
    egl_config: e.EGLConfig = null,
    context: e.EGLContext = null,
    test_surface: e.EGLSurface = null,
    window_slots: [max_windows]@import("X11Window.zig").X11Window = undefined,
    window_used: [max_windows]bool = @splat(false),
};

pub var state: State = .{};

/// Initialises Xlib, EGL and a core GL context. A forced Wayland choice fails
/// loudly rather than silently starting X11.
pub fn init(choice: Choice) error{ WaylandUnavailable, XlibUnavailable, EglUnavailable, GlInitFailed }!void {
    if (state.phase == .ready) return;
    if (choice.system == .wayland) {
        log.err("this build has no Wayland backend; rebuild with a Wayland backend or choose x11", .{});
        return error.WaylandUnavailable;
    }

    var x11_lib = xlib.load() catch {
        log.err("cannot load {s} at runtime", .{xlib.soname});
        return error.XlibUnavailable;
    };
    errdefer x11_lib.lib.close();
    const display = x11_lib.XOpenDisplay(null) orelse {
        log.err("cannot open the X11 display", .{});
        return error.XlibUnavailable;
    };

    var egl_lib = egl.load() catch {
        log.err("cannot load {s} at runtime", .{egl.soname});
        return error.EglUnavailable;
    };
    errdefer egl_lib.lib.close();

    const edpy = egl_lib.eglGetPlatformDisplayEXT(e.EGL_PLATFORM_X11_EXT, display, null);
    if (edpy == e.EGL_NO_DISPLAY) return error.GlInitFailed;
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
        e.EGL_NONE,
    };
    var config: e.EGLConfig = null;
    var count: e.EGLint = 0;
    if (egl_lib.eglChooseConfig(edpy, &cfg_attr, &config, 1, &count) == 0 or count == 0)
        return error.GlInitFailed;

    state.x11 = x11_lib;
    state.egl = egl_lib;
    state.display = display;
    state.egl_display = edpy;
    state.egl_config = config;
    state.phase = .ready;
    log.info("platform: x11", .{});
}

/// Releases EGL and Xlib. Windows must be destroyed before this call.
pub fn deinit() void {
    if (state.phase != .ready) return;
    if (state.egl) |lib| {
        if (state.context != null) _ = lib.eglDestroyContext(state.egl_display, state.context);
        _ = lib.eglTerminate(state.egl_display);
        lib.lib.close();
    }
    if (state.x11) |lib| {
        if (state.display) |display| _ = lib.XCloseDisplay(display);
        lib.lib.close();
    }
    state = .{};
}

/// GLAD resolves GL symbols through EGL at runtime.
fn gladLoader(name: [*c]const u8) callconv(.c) ?*anyopaque {
    const lib = &state.egl.?;
    const proc = lib.eglGetProcAddress(name);
    if (proc == null) return null;
    const p: *const anyopaque = @ptrCast(proc);
    return @constCast(p);
}

pub fn getProcAddress() gl.GLADloadproc {
    return &gladLoader;
}

/// Platform-global wakeup from the pty worker or config watcher. XNextEvent
/// is woken by sending a ClientMessage to every window; implemented later.
pub fn postWakeup() void {}

pub fn pollEvents() void {
    if (state.phase == .ready) @import("events.zig").pump();
}

pub fn waitEvents(timeout_ms: ?f64) void {
    if (state.phase != .ready) return;
    const lib = &state.x11.?;
    const display = state.display.?;
    if (lib.XPending(display) > 0) {
        @import("events.zig").pump();
        return;
    }
    // A short poll loop avoids needing a second wakeup fd inside Xlib.
    const deadline = std.time.nanoTimestamp() + @as(i128, @intFromFloat((timeout_ms orelse 1000.0) * std.time.ns_per_ms));
    while (std.time.nanoTimestamp() < deadline) {
        if (lib.XPending(display) > 0) {
            @import("events.zig").pump();
            return;
        }
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
}

pub fn now() f64 {
    return @as(f64, @floatFromInt(std.time.nanoTimestamp())) / std.time.ns_per_s;
}

pub fn primaryRefreshHz() ?u32 {
    return 60;
}

pub fn isKeyDown(window: Window, k: @import("../../input/key.zig").Key) bool {
    const sym = @import("key.zig").toKeysym(k) orelse return false;
    const lib = &state.x11.?;
    const code = lib.XKeysymToKeycode(state.display.?, sym);
    if (code == 0) return false;
    var map: [32]u8 = undefined;
    _ = lib.XQueryKeymap(state.display.?, &map);
    const byte = map[code / 8];
    return (byte & (@as(u8, 1) << @intCast(code % 8))) != 0;
}

pub fn pushEvent(event: Event) void {
    state.event_ring.push(event);
}

pub fn nextEvent(out: *Event) bool {
    return state.event_ring.next(out);
}

pub fn takeDropped() u32 {
    return state.event_ring.takeDropped();
}

pub fn testGlContext() !void {
    if (!builtin.is_test) @compileError("testGlContext is for tests only");
    return error.SkipZigTest;
}

pub fn testKeyEvent(window: Window, k: @import("../../input/key.zig").Key) void {
    if (!builtin.is_test) @compileError("testKeyEvent is for tests only");
    _ = window;
    _ = k;
}

pub fn createWindow(option: @import("X11Window.zig").InitOption) !Window {
    if (state.phase != .ready) return error.PlatformNotInitialised;
    var slot: ?usize = null;
    for (state.window_used, 0..) |used, i| {
        if (!used) {
            slot = i;
            break;
        }
    }
    const index = slot orelse return error.TooManyWindows;
    const impl = &state.window_slots[index];
    try impl.init(option);
    state.window_used[index] = true;
    return .{ .impl = @ptrCast(impl) };
}

pub fn destroyWindow(window: Window) void {
    const impl: *@import("X11Window.zig").X11Window = @ptrCast(@alignCast(window.impl));
    for (state.window_used, 0..) |used, i| {
        if (used and &state.window_slots[i] == impl) {
            state.window_used[i] = false;
            break;
        }
    }
    impl.deinit();
}

fn implOf(window: Window) *@import("X11Window.zig").X11Window {
    return @ptrCast(@alignCast(window.impl));
}

pub fn windowSetContext(window: Window, ptr: ?*anyopaque) void {
    implOf(window).context = ptr;
}

pub fn windowGetContext(window: Window) ?*anyopaque {
    return implOf(window).context;
}

pub fn windowSetTitle(window: Window, title: [:0]const u8) void {
    implOf(window).setTitle(title);
}

pub fn windowShouldClose(window: Window) bool {
    return implOf(window).should_close;
}

pub fn windowSetShouldClose(window: Window, set: bool) void {
    implOf(window).should_close = set;
}

pub fn windowSwapBuffers(window: Window) void {
    implOf(window).swapBuffers();
}

pub fn windowFramebufferSize(window: Window, comptime T: type) @import("../../renderer/dimension.zig").Dimension(T) {
    return implOf(window).framebufferSize(T);
}

pub fn windowContentScale(window: Window) @import("../../renderer/dimension.zig").Dimension(f32) {
    return implOf(window).contentScale();
}

pub fn windowFocused(window: Window) bool {
    return implOf(window).focused;
}

pub fn windowSetMinimumSize(window: Window, width: c_int, height: c_int) void {
    implOf(window).setMinimumSize(width, height);
}

pub fn windowSetPointerShape(window: Window, shape: Window.PointerShape) void {
    implOf(window).setPointerShape(shape);
}

pub fn windowSetPointerVisible(window: Window, visible: bool) void {
    implOf(window).setPointerVisible(visible);
}

pub fn windowSetClipboard(window: Window, text: [:0]const u8) void {
    implOf(window).setClipboard(text);
}

pub fn windowGetClipboard(window: Window) ?[:0]const u8 {
    return implOf(window).getClipboard();
}

pub fn windowGetPrimarySelection(window: Window) ?[:0]const u8 {
    return implOf(window).getPrimarySelection();
}

pub fn windowSetPrimarySelection(window: Window, text: [:0]const u8) bool {
    return implOf(window).setPrimarySelection(text);
}

pub fn windowRequestAttention(window: Window) void {
    implOf(window).requestAttention();
}

pub fn windowRingBell(window: Window, volume: f32) void {
    implOf(window).ringBell(volume);
}
