//! Native X11 implementation of the Rex platform interface. Xlib and EGL are
//! loaded at runtime; this backend owns the connection, GL contexts, window
//! state and the event pump.

const std = @import("std");
const builtin = @import("builtin");

const x = @import("x11");
const e = @import("egl");
const gl = @import("../../renderer/gl.zig");
const Dimension = @import("../../renderer/dimension.zig").Dimension;
const window_config = @import("../../config/window.zig");
const input_key = @import("../../input/key.zig");
const events = @import("../Event.zig");
const Window = @import("../Window.zig");
const x11_events = @import("events.zig");
const key = @import("key.zig");
const xlib = @import("xlib.zig");
const egl = @import("../egl.zig");
const X11Window = @import("X11Window.zig");
const pipe = @import("../../termio/pipe.zig");

const log = std.log.scoped(.platform);
const posix = std.posix;
const system = posix.system;

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
    test_context: e.EGLContext = null,
    window_slots: [max_windows]X11Window = undefined,
    window_used: [max_windows]bool = @splat(false),
    wakeup_read: posix.fd_t = -1,
    wakeup_write: posix.fd_t = -1,
    wm_delete_atom: x.Atom = 0,
    wm_protocols_atom: x.Atom = 0,
    clipboard_atom: x.Atom = 0,
    utf8_atom: x.Atom = 0,
    targets_atom: x.Atom = 0,
    reply_atom: x.Atom = 0,
};

/// Mirrors `TerminalOption.max_clipboard_bytes` (1 MiB) plus null terminator.
pub const selection_capacity = (1 << 20) + 1;

/// Display-global CLIPBOARD/PRIMARY buffers kept in `.bss` separately from
/// `state` so `window_slots` stay small and `state = .{}` never copies 3 MiB.
pub const SelectionState = struct {
    clipboard_owner: x.Window = 0,
    primary_owner: x.Window = 0,
    clipboard_len: usize = 0,
    primary_len: usize = 0,
    read_len: usize = 0,
    clipboard_text: [selection_capacity]u8 = undefined,
    primary_text: [selection_capacity]u8 = undefined,
    read_text: [selection_capacity]u8 = undefined,

    /// Resets the selection owners and lengths, leaving the buffers intact.
    pub fn clear(self: *SelectionState) void {
        self.clipboard_owner = 0;
        self.primary_owner = 0;
        self.clipboard_len = 0;
        self.primary_len = 0;
        self.read_len = 0;
    }
};

pub var state: State = .{};
pub var selection_state: SelectionState = .{};

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

    const edpy = egl_lib.getPlatformDisplay(e.EGL_PLATFORM_X11_EXT, display, null);
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

    var wakeup_fds: [2]posix.fd_t = undefined;
    pipe.open(&wakeup_fds, .{ .CLOEXEC = true, .NONBLOCK = true }) catch |err| {
        log.err("cannot create the wakeup pipe: {}", .{err});
        return error.GlInitFailed;
    };

    state.x11 = x11_lib;
    state.egl = egl_lib;
    state.display = display;
    state.egl_display = edpy;
    state.egl_config = config;
    state.wakeup_read = wakeup_fds[0];
    state.wakeup_write = wakeup_fds[1];
    state.wm_delete_atom = x11_lib.XInternAtom(display, "WM_DELETE_WINDOW", 0);
    state.wm_protocols_atom = x11_lib.XInternAtom(display, "WM_PROTOCOLS", 0);
    state.clipboard_atom = x11_lib.XInternAtom(display, "CLIPBOARD", 0);
    state.utf8_atom = x11_lib.XInternAtom(display, "UTF8_STRING", 0);
    state.targets_atom = x11_lib.XInternAtom(display, "TARGETS", 0);
    state.reply_atom = x11_lib.XInternAtom(display, "REX_SELECTION", 0);
    state.phase = .ready;
    log.info("platform: x11", .{});
}

/// Releases EGL and Xlib. Windows must be destroyed before this call.
pub fn deinit() void {
    if (state.phase != .ready) return;
    // Keep both libraries mapped until every native call is done. libEGL can
    // hold the last reference to libX11 through its GLX/DRI driver, so closing
    // it first may unmap Xlib before XCloseDisplay jumps into it.
    if (state.egl) |lib| {
        if (state.context != null) _ = lib.eglDestroyContext(state.egl_display, state.context);
        _ = lib.eglTerminate(state.egl_display);
    }
    if (state.x11) |lib| {
        if (state.display) |display| _ = lib.XCloseDisplay(display);
    }
    if (state.egl) |*lib| lib.lib.close();
    if (state.x11) |*lib| lib.lib.close();
    if (state.wakeup_read >= 0) _ = system.close(state.wakeup_read);
    if (state.wakeup_write >= 0) _ = system.close(state.wakeup_write);
    selection_state.clear();
    state = .{};
}

/// GLAD resolves GL symbols through EGL at runtime.
fn gladLoader(name: [*c]const u8) callconv(.c) ?*anyopaque {
    const proc = state.egl.?.eglGetProcAddress(name);
    if (proc == null) return null;
    const p: *const anyopaque = @ptrCast(proc);
    return @constCast(p);
}

/// GLAD resolves GL symbols through the EGL display at runtime.
pub fn getProcAddress() gl.GLADloadproc {
    return &gladLoader;
}

/// Platform-global wakeup from the pty worker or config watcher. Writes one
/// byte to a nonblocking pipe that `waitEvents` polls.
pub fn postWakeup() void {
    if (state.wakeup_write < 0) return;
    const b: [1]u8 = .{1};
    _ = system.write(state.wakeup_write, &b, 1);
}

/// Processes pending X11 events without blocking.
pub fn pollEvents() void {
    if (state.phase == .ready) x11_events.pump();
}

/// Blocks in poll() on the X11 connection and the wakeup pipe, so an idle
/// window does not spin. Pending X events are translated into the ring.
pub fn waitEvents(timeout_ms: ?f64) void {
    if (state.phase != .ready) return;
    const lib = &state.x11.?;
    const display = state.display.?;
    if (lib.XPending(display) > 0) {
        x11_events.pump();
        return;
    }
    const x_fd = lib.XConnectionNumber(display);
    var fds = [_]system.pollfd{
        .{ .fd = x_fd, .events = system.POLL.IN, .revents = 0 },
        .{ .fd = state.wakeup_read, .events = system.POLL.IN, .revents = 0 },
    };
    const ms: c_int = if (timeout_ms) |t|
        @intFromFloat(@max(0.0, @min(t, 60000.0)))
    else
        -1;
    _ = system.poll(&fds, fds.len, ms);
    if (fds[1].revents & system.POLL.IN != 0) {
        var buf: [64]u8 = undefined;
        while (true) {
            const n = system.read(state.wakeup_read, &buf, buf.len);
            if (n <= 0) break;
        }
    }
    if (fds[0].revents & system.POLL.IN != 0 or lib.XPending(display) > 0)
        x11_events.pump();
}

/// Monotonic clock in seconds, from the caller's Io.
pub fn now(io: std.Io) f64 {
    const ns = std.Io.Clock.Timestamp.now(io, .awake).raw.toNanoseconds();
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_s;
}

/// Placeholder until XRandR is wired. It only seeds the frame latch.
pub fn primaryRefreshHz() ?u32 {
    return 60;
}

/// Whether a key is currently held on the X11 display.
pub fn isKeyDown(window: Window, k: input_key.Key) bool {
    _ = window;
    const sym = key.toKeysym(k) orelse return false;
    const lib = &state.x11.?;
    const code = lib.XKeysymToKeycode(state.display.?, sym);
    if (code == 0) return false;
    var map: [32]u8 = undefined;
    _ = lib.XQueryKeymap(state.display.?, &map);
    return (map[code / 8] & (@as(u8, 1) << @intCast(code % 8))) != 0;
}

/// Appends an event to the process-wide ring.
pub fn pushEvent(event: Event) void {
    state.event_ring.push(event);
}

/// Copies the oldest queued event into `out`, returning false when empty.
pub fn nextEvent(out: *Event) bool {
    return state.event_ring.next(out);
}

/// Returns and resets the count of events dropped by a full ring.
pub fn takeDropped() u32 {
    return state.event_ring.takeDropped();
}

/// Readies a hidden GL context for renderer tests, skipping without a display.
pub fn testGlContext() !void {
    if (!builtin.is_test) @compileError("testGlContext is for tests only");
    if (state.test_context != null) {
        _ = state.egl.?.eglMakeCurrent(state.egl_display, state.test_surface, state.test_surface, state.test_context);
        return;
    }
    if (state.phase == .none) {
        init(.{ .system = .x11, .forced = false }) catch return error.SkipZigTest;
    }
    const win = createWindow(.{ .width = 1, .height = 1, .title = "test" }) catch return error.SkipZigTest;
    const impl: *X11Window = @ptrCast(@alignCast(win.impl));
    state.test_surface = impl.surface;
    state.test_context = impl.context;
    if (gl.gladLoadGLLoader(getProcAddress()) == 0) return error.GladLoadFailed;
    var profile: c_int = 0;
    gl.getIntegerv(gl.CONTEXT_PROFILE_MASK, &profile);
    if (profile & gl.CONTEXT_CORE_PROFILE_BIT == 0)
        log.warn("got compatibility profile, not core", .{});
}

/// Injects a synthetic key press into the ring for tests.
pub fn testKeyEvent(window: Window, k: input_key.Key) void {
    if (!builtin.is_test) @compileError("testKeyEvent is for tests only");
    // A real XKeyEvent cannot be safely synthesized (XLookupString needs the
    // full event state Xlib fills in on XNextEvent), so inject the translated
    // key straight into the ring, mirroring GLFW's callback-based helper.
    const sym = key.toKeysym(k) orelse return;
    if (key.fromKeysym(sym) == null) return;
    pushEvent(.{ .key = .{
        .window = window,
        .key = k,
        .mods = .{},
        .action = .press,
    } });
}

/// Creates a window in a free slot and prepares its EGL context.
pub fn createWindow(option: X11Window.InitOption) error{ PlatformNotInitialised, TooManyWindows, WindowCreatedFailed, SurfaceFailed, ContextFailed, MakeCurrentFailed, GladLoadFailed }!Window {
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

/// Destroys the window and frees its backend slot.
pub fn destroyWindow(window: Window) void {
    const impl: *X11Window = @ptrCast(@alignCast(window.impl));
    for (state.window_used, 0..) |used, i| {
        if (used and &state.window_slots[i] == impl) {
            state.window_used[i] = false;
            break;
        }
    }
    impl.deinit();
}

fn implOf(window: Window) *X11Window {
    return @ptrCast(@alignCast(window.impl));
}

/// Associates an application pointer with the window.
pub fn windowSetContext(window: Window, ptr: ?*anyopaque) void {
    implOf(window).context_ptr = ptr;
}

/// The application pointer set on the window.
pub fn windowGetContext(window: Window) ?*anyopaque {
    return implOf(window).context_ptr;
}

/// Sets the title shown by the desktop.
pub fn windowSetTitle(window: Window, title: [:0]const u8) void {
    implOf(window).setTitle(title);
}

/// Shows or hides the window manager decorations.
pub fn windowSetDecorated(window: Window, decorated: bool) void {
    implOf(window).setDecorated(decorated);
}

/// Whether the window system has asked the window to close.
pub fn windowShouldClose(window: Window) bool {
    return implOf(window).should_close;
}

/// Marks the window to close on the next event loop pass.
pub fn windowSetShouldClose(window: Window, set: bool) void {
    implOf(window).should_close = set;
}

/// Presents the rendered frame.
pub fn windowSwapBuffers(window: Window) void {
    implOf(window).swapBuffers();
}

/// The drawable size in pixels, converted to `T`.
pub fn windowFramebufferSize(window: Window, comptime T: type) Dimension(T) {
    return implOf(window).framebufferSize(T);
}

/// The scale from logical to device pixels.
pub fn windowContentScale(window: Window) Dimension(f32) {
    return implOf(window).contentScale();
}

/// Whether the window currently has input focus.
pub fn windowFocused(window: Window) bool {
    return implOf(window).focused;
}

/// Sets the smallest size the user may resize to.
pub fn windowSetMinimumSize(window: Window, width: c_int, height: c_int) void {
    implOf(window).setMinimumSize(width, height);
}

/// Shows the given standard cursor over the window.
pub fn windowSetPointerShape(window: Window, shape: Window.PointerShape) void {
    implOf(window).setPointerShape(shape);
}

/// Shows or hides the pointer over the window.
pub fn windowSetPointerVisible(window: Window, visible: bool) void {
    implOf(window).setPointerVisible(visible);
}

/// Sets the CLIPBOARD selection to the given text.
pub fn windowSetClipboard(window: Window, text: [:0]const u8) void {
    implOf(window).setClipboard(text);
}

/// The CLIPBOARD text, or null when the selection is empty.
pub fn windowGetClipboard(window: Window) ?[:0]const u8 {
    return implOf(window).getClipboard();
}

/// The PRIMARY selection, or null when unavailable.
pub fn windowGetPrimarySelection(window: Window) ?[:0]const u8 {
    return implOf(window).getPrimarySelection();
}

/// Sets PRIMARY where supported, returning false when unavailable.
pub fn windowSetPrimarySelection(window: Window, text: [:0]const u8) bool {
    return implOf(window).setPrimarySelection(text);
}

/// Asks the desktop to draw attention to the window.
pub fn windowRequestAttention(window: Window) void {
    implOf(window).requestAttention();
}

/// Rings the audible bell at the given volume.
pub fn windowRingBell(window: Window, volume: f32) void {
    implOf(window).ringBell(volume);
}
