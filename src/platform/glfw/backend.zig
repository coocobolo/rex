//! GLFW implementation of the Rex platform interface. The only GLFW calls
//! and types in this stage live in `src/platform/glfw/` (ADR 0011).

const std = @import("std");
const builtin = @import("builtin");

const c = @import("glfw");
const gl = @import("../../renderer/gl.zig");
const window_config = @import("../../config/window.zig");
const events = @import("../Event.zig");
const Window = @import("../Window.zig");
const GlfwWindow = @import("GlfwWindow.zig");
const callbacks = @import("callbacks.zig");
const key_translate = @import("key.zig");

const log = std.log.scoped(.platform);

/// The OpenGL core version the renderer targets. The shaders are GLSL 330.
pub const gl_version: struct { major: c_int, minor: c_int } = .{ .major = 3, .minor = 3 };

/// The event type delivered to the application.
pub const Event = events.Event;
/// The bounded event ring owned by this backend.
pub const Ring = events.Ring;

/// The window system a backend starts on. GLFW's `c_int` never leaves this
/// file; the application sees this enum.
pub const System = enum {
    x11,
    wayland,
    cocoa,
    null_backend,

    fn toGlfw(self: System) c_int {
        return switch (self) {
            .x11 => c.GLFW_PLATFORM_X11,
            .wayland => c.GLFW_PLATFORM_WAYLAND,
            .cocoa => c.GLFW_PLATFORM_COCOA,
            .null_backend => c.GLFW_PLATFORM_NULL,
        };
    }

    fn name(self: System) []const u8 {
        return switch (self) {
            .x11 => "x11",
            .wayland => "wayland",
            .cocoa => "cocoa",
            .null_backend => "null",
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

/// `auto` is Cocoa on macOS, Wayland on a Wayland session, X11 otherwise.
/// An explicit choice is forced, so it never degrades silently.
pub fn choose(requested: window_config.Platform, wayland_session: bool) Choice {
    return switch (requested) {
        .auto => .{
            .system = if (builtin.os.tag == .macos)
                .cocoa
            else if (wayland_session)
                .wayland
            else
                .x11,
            .forced = false,
        },
        .x11 => .{ .system = .x11, .forced = true },
        .wayland => .{ .system = .wayland, .forced = true },
    };
}

const max_windows = 8;

/// Who started GLFW and whether a platform choice was recorded. A test context
/// can ready GLFW before the platform does, so ownership is part of the state.
const Phase = enum {
    none,
    test_context,
    test_with_platform,
    platform,
};

/// All mutable backend state in one place. The C callbacks reach it through
/// the window impl; the ring is touched only on the main thread.
const State = struct {
    phase: Phase = .none,
    /// Events from all windows, drained once per event loop pass.
    event_ring: Ring = .{},
    window_slots: [max_windows]GlfwWindow = undefined,
    window_used: [max_windows]bool = @splat(false),
    test_window: ?*c.GLFWwindow = null,
};

var state: State = .{};

fn glfwErrorCallback(code: c_int, desc: [*c]const u8) callconv(.c) void {
    log.err("GLFW error {d}: {s}", .{ code, desc });
}

/// Initialises GLFW on `choice.system`, never on GLFW's own pick. An automatic
/// Wayland that fails falls back to X11 explicitly, with a warning; a forced
/// platform that fails is an error. Idempotent, so a tool host and its tests
/// can both call it.
pub fn init(choice: Choice) error{ PlatformUnsupported, GlfwInitFailed }!void {
    switch (state.phase) {
        .platform, .test_with_platform => return,
        .test_context => {
            // GLFW is already running for a test context; record the platform
            // choice, but its hints cannot be reapplied.
            state.phase = .test_with_platform;
            return;
        },
        .none => {},
    }

    _ = c.glfwSetErrorCallback(glfwErrorCallback);
    const wanted = choice.system.toGlfw();
    if (c.glfwPlatformSupported(wanted) == 0) {
        log.err("platform {f} is not built into this Rex binary", .{choice});
        return error.PlatformUnsupported;
    }

    c.glfwInitHint(c.GLFW_PLATFORM, wanted);
    if (c.glfwInit() != 0) {
        log.info("platform: {f}", .{Choice{ .system = choice.system, .forced = false }});
        state.phase = .platform;
        return;
    }

    if (choice.forced or choice.system != .wayland) {
        log.err("cannot start on {f} (see GLFW error above)", .{choice});
        return error.GlfwInitFailed;
    }

    log.warn("cannot start on wayland (see the GLFW error above); falling back to x11", .{});
    c.glfwInitHint(c.GLFW_PLATFORM, c.GLFW_PLATFORM_X11);
    if (c.glfwInit() == 0) return error.GlfwInitFailed;
    log.info("platform: x11 (fallback from wayland)", .{});
    state.phase = .platform;
}

/// Terminates GLFW only when this platform started it. A test owned context
/// stays alive, but its platform choice and all window state are released.
pub fn deinit() void {
    switch (state.phase) {
        .none, .test_context => {},
        .test_with_platform => {
            state.phase = .test_context;
            state.event_ring = .{};
            state.window_used = @splat(false);
        },
        .platform => {
            c.glfwTerminate();
            state = .{};
        },
    }
}

/// Platform-global: GLFW's event wait is not tied to one window. The driver
/// and the config watcher call this from their own threads.
pub fn postWakeup() void {
    c.glfwPostEmptyEvent();
}

/// Processes pending window events without blocking.
pub fn pollEvents() void {
    c.glfwPollEvents();
}

/// Waits for window events, or for the given timeout in milliseconds.
pub fn waitEvents(timeout_ms: ?f64) void {
    if (timeout_ms) |ms| {
        c.glfwWaitEventsTimeout(@max(0.001, ms / 1000.0));
    } else {
        c.glfwWaitEvents();
    }
}

/// Monotonic clock in seconds, from the caller's Io.
pub fn now(io: std.Io) f64 {
    const ns = std.Io.Clock.Timestamp.now(io, .awake).raw.toNanoseconds();
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_s;
}

/// The primary monitor refresh rate, or null when GLFW does not know it.
pub fn primaryRefreshHz() ?u32 {
    const monitor = c.glfwGetPrimaryMonitor() orelse return null;
    const mode = c.glfwGetVideoMode(monitor) orelse return null;
    if (mode.*.refreshRate <= 0) return null;
    return @intCast(mode.*.refreshRate);
}

/// Key state belongs to a window, not to whatever context happens to be
/// current, so multi-window hosts cannot ask about the wrong one.
pub fn isKeyDown(window: Window, k: @import("../../input/key.zig").Key) bool {
    const code = key_translate.toGlfw(k) orelse return false;
    const handle: *c.GLFWwindow = @ptrCast(@alignCast(window.impl));
    return c.glfwGetKey(handle, code) == c.GLFW_PRESS;
}

fn gladLoader(name: [*c]const u8) callconv(.c) ?*anyopaque {
    const proc = c.glfwGetProcAddress(name) orelse return null;
    const p: *const anyopaque = @ptrCast(proc);
    return @constCast(p);
}

/// The GL function loader GLAD uses for this backend.
pub fn getProcAddress() gl.GLADloadproc {
    return &gladLoader;
}

/// Push an event from a backend callback. Callbacks run on the main thread,
/// so no synchronisation is needed here.
pub fn pushEvent(event: Event) void {
    state.event_ring.push(event);
}

/// Delivers a key through the real GLFW callback path so tests exercise the
/// user-pointer routing that events from the window system rely on.
pub fn testKeyEvent(window: Window, k: @import("../../input/key.zig").Key) void {
    if (!builtin.is_test) @compileError("testKeyEvent is for tests only");
    const code = key_translate.toGlfw(k) orelse return;
    const impl: *GlfwWindow = @ptrCast(@alignCast(window.impl));
    callbacks.keyCallback(impl.handle, code, 0, c.GLFW_PRESS, 0);
}

/// Copies the oldest queued event into `out`, returning false when empty.
pub fn nextEvent(out: *Event) bool {
    return state.event_ring.next(out);
}

/// The number of dropped events since the last call, then resets it.
pub fn takeDropped() u32 {
    return state.event_ring.takeDropped();
}

/// Windows live in fixed slots so the opaque handle stays a stable pointer
/// without allocating. Eight is well above the one-window-per-process design.
/// Creates a window in a fixed slot and installs the event callbacks.
pub fn createWindow(option: GlfwWindow.InitOption) !Window {
    if (state.phase == .none) return error.PlatformNotInitialised;
    var slot: ?usize = null;
    for (state.window_used, 0..) |used, i| {
        if (!used) {
            slot = i;
            break;
        }
    }
    const index = slot orelse return error.TooManyWindows;
    hintContext();
    const impl = &state.window_slots[index];
    try impl.init(option, getProcAddress());
    state.window_used[index] = true;

    _ = c.glfwSetKeyCallback(impl.handle, callbacks.keyCallback);
    _ = c.glfwSetCharCallback(impl.handle, callbacks.charCallback);
    _ = c.glfwSetMouseButtonCallback(impl.handle, callbacks.mouseButtonCallback);
    _ = c.glfwSetCursorPosCallback(impl.handle, callbacks.cursorPosCallback);
    _ = c.glfwSetScrollCallback(impl.handle, callbacks.scrollCallback);
    _ = c.glfwSetCursorEnterCallback(impl.handle, callbacks.cursorEnterCallback);
    _ = c.glfwSetWindowFocusCallback(impl.handle, callbacks.focusCallback);
    _ = c.glfwSetFramebufferSizeCallback(impl.handle, callbacks.framebufferSizeCallback);
    _ = c.glfwSetWindowContentScaleCallback(impl.handle, callbacks.contentScaleCallback);
    _ = c.glfwSetWindowCloseCallback(impl.handle, callbacks.closeCallback);

    return .{ .impl = @ptrCast(impl) };
}

/// Destroys the window and frees its slot.
pub fn destroyWindow(window: Window) void {
    const impl: *GlfwWindow = @ptrCast(@alignCast(window.impl));
    for (state.window_used, 0..) |used, i| {
        if (used and &state.window_slots[i] == impl) {
            state.window_used[i] = false;
            break;
        }
    }
    c.glfwSetWindowUserPointer(impl.handle, null);
    impl.deinit();
}

fn implOf(window: Window) *GlfwWindow {
    return @ptrCast(@alignCast(window.impl));
}

/// Associates an application pointer with the window.
pub fn windowSetContext(window: Window, ptr: ?*anyopaque) void {
    implOf(window).setContext(ptr);
}

/// The application pointer set on the window.
pub fn windowGetContext(window: Window) ?*anyopaque {
    return implOf(window).getContext();
}

/// Sets the title shown by the desktop.
pub fn windowSetTitle(window: Window, title: [:0]const u8) void {
    implOf(window).setTitle(title);
}

/// Shows or hides the window's server-side titlebar and borders.
pub fn windowSetDecorated(window: Window, decorated: bool) void {
    implOf(window).setDecorated(decorated);
}

/// Whether the window system has asked the window to close.
pub fn windowShouldClose(window: Window) bool {
    return implOf(window).shouldClose();
}

/// Marks the window to close on the next event loop pass.
pub fn windowSetShouldClose(window: Window, set: bool) void {
    implOf(window).setShouldClose(set);
}

/// Presents the rendered frame.
pub fn windowSwapBuffers(window: Window) void {
    implOf(window).swapBuffers();
}

/// The drawable size in pixels, converted to T.
pub fn windowFramebufferSize(window: Window, comptime T: type) @import("../../renderer/dimension.zig").Dimension(T) {
    return implOf(window).framebufferSize(T);
}

/// The scale from logical to device pixels.
pub fn windowContentScale(window: Window) @import("../../renderer/dimension.zig").Dimension(f32) {
    return implOf(window).contentScale();
}

/// Whether the window currently has input focus.
pub fn windowFocused(window: Window) bool {
    return implOf(window).focused();
}

/// Sets the smallest size the user may resize to.
pub fn windowSetMinimumSize(window: Window, width: c_int, height: c_int) void {
    implOf(window).setMinimumSize(width, height);
}

/// Shows the given standard cursor over the window.
pub fn windowSetPointerShape(window: Window, shape: Window.PointerShape) void {
    implOf(window).setPointerShape(switch (shape) {
        .arrow => .arrow,
        .hand => .hand,
        .text => .text,
    });
}

/// Shows or hides the pointer over the window.
pub fn windowSetPointerVisible(window: Window, visible: bool) void {
    implOf(window).setPointerVisible(visible);
}

/// Sets the CLIPBOARD selection to the given text.
pub fn windowSetClipboard(window: Window, text: [:0]const u8) void {
    implOf(window).setClipboard(text);
}

/// The CLIPBOARD selection, or null when it holds no text.
pub fn windowGetClipboard(window: Window) ?[:0]const u8 {
    return implOf(window).getClipboard();
}

/// The PRIMARY selection where the platform provides one.
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

/// Rings the audible bell where available, otherwise asks for attention.
pub fn windowRingBell(window: Window, volume: f32) void {
    implOf(window).ringBell(volume);
}

fn hintContext() void {
    c.glfwWindowHint(c.GLFW_CONTEXT_VERSION_MAJOR, 3);
    c.glfwWindowHint(c.GLFW_CONTEXT_VERSION_MINOR, 3);
    c.glfwWindowHint(c.GLFW_OPENGL_PROFILE, c.GLFW_OPENGL_CORE_PROFILE);
    c.glfwWindowHint(c.GLFW_OPENGL_FORWARD_COMPAT, c.GLFW_TRUE);
}

/// The hidden window whose GL context every GL test shares. It stays current
/// across tests and is cleared when a platform that owns GLFW shuts down.
/// Skips the test when there is no display.
pub fn testGlContext() !void {
    if (!builtin.is_test) @compileError("testGlContext is for tests only");
    if (state.test_window) |win| return c.glfwMakeContextCurrent(win);

    if (state.phase == .none) {
        if (c.glfwInit() == 0) return error.SkipZigTest;
        state.phase = .test_context;
    }
    c.glfwWindowHint(c.GLFW_VISIBLE, c.GLFW_FALSE);
    hintContext();

    const win = c.glfwCreateWindow(1, 1, "test", null, null) orelse return error.WindowFailed;
    c.glfwMakeContextCurrent(win);

    const loader = getProcAddress();
    if (gl.gladLoadGLLoader(loader) == 0) return error.GladLoadFailed;

    var profile: c_int = 0;
    gl.getIntegerv(gl.CONTEXT_PROFILE_MASK, &profile);
    if (profile & gl.CONTEXT_CORE_PROFILE_BIT == 0) {
        log.warn("got compatibility profile, not core", .{});
    }

    state.test_window = win;
}
