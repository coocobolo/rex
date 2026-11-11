const Window = @This();

const std = @import("std");
const builtin = @import("builtin");

const log = std.log.scoped(.window);

const gl = @import("gl.zig");
const c = @import("glfw");

const Dimension = @import("dimension.zig").Dimension;

/// The windowing platform the config asks for. `auto` is Wayland on a
/// Wayland session and X11 otherwise (ADR 0001, decision 3).
pub const Platform = enum { auto, wayland, x11 };

/// The GLFW platform `init` starts on, and whether the user forced it.
/// Only an `auto` choice of Wayland may fall back to X11.
pub const PlatformChoice = struct {
    platform: c_int,
    forced: bool,

    pub fn format(self: PlatformChoice, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("{s}", .{self.name()});
    }

    fn name(self: *const PlatformChoice) []const u8 {
        return switch (self.platform) {
            c.GLFW_PLATFORM_X11 => "x11",
            c.GLFW_PLATFORM_WAYLAND => "wayland",
            c.GLFW_PLATFORM_NULL => "null",
            c.GLFW_PLATFORM_COCOA => "cocoa",
            c.GLFW_PLATFORM_WIN32 => "win32",
            else => "unknown",
        };
    }
};

pub fn choosePlatform(requested: Platform, wayland_session: bool) PlatformChoice {
    return switch (requested) {
        .auto => .{
            .platform = if (wayland_session) c.GLFW_PLATFORM_WAYLAND else c.GLFW_PLATFORM_X11,
            .forced = false,
        },
        .x11 => .{ .platform = c.GLFW_PLATFORM_X11, .forced = true },
        .wayland => .{ .platform = c.GLFW_PLATFORM_WAYLAND, .forced = true },
    };
}

/// Initialises GLFW on `choice.platform`, never on GLFW's own pick.
/// An automatic Wayland that fails falls back to X11 explicitly, with a
/// warning; a forced platform that fails is an error.
fn initGlfw(choice: PlatformChoice) error{
    PlatformUnsupported,
    GlfwInitFailed,
}!void {
    if (c.glfwPlatformSupported(choice.platform) == 0) {
        log.err("platform {f} is not built into this Rex binary", .{choice});
        return error.PlatformUnsupported;
    }

    c.glfwInitHint(c.GLFW_PLATFORM, choice.platform);
    if (c.glfwInit() != 0) {
        log.info("platform: {f}", .{PlatformChoice{
            .platform = c.glfwGetPlatform(),
            .forced = false,
        }});
        return;
    }

    if (choice.forced or choice.platform != c.GLFW_PLATFORM_WAYLAND) {
        log.err("cannot start on {f} (see GLFW error above)", .{choice});
        return error.GlfwInitFailed;
    }

    log.warn("cannot start on wayland (see the GLFW error above); falling back to x11", .{});
    c.glfwInitHint(c.GLFW_PLATFORM, c.GLFW_PLATFORM_X11);
    if (c.glfwInit() == 0) return error.GlfwInitFailed;
    log.info("platform: x11 (fallback from wayland)", .{});
}

pub const GlfwWindow = c.GLFWwindow;

fn glfwErrorCallback(code: c_int, desc: [*c]const u8) callconv(.c) void {
    log.err("GLFW error {d}: {s}", .{ code, desc });
}

/// Whether GLFW can run on X11 on this OS, so the X11 bell can exist.
const has_x11 = builtin.os.tag == .linux or builtin.os.tag == .freebsd;

/// The two Xlib functions the bell needs. Rex doesn't link libX11: GLFW
/// loads it at runtime, so opening it again only takes another reference
/// (ADR 0001). `Display` stays opaque; only GLFW's own connection is used.
pub const Xlib = struct {
    pub const Display = opaque {};
    pub const soname = "libX11.so.6";

    lib: std.DynLib,
    bell: *const fn (*Display, c_int) callconv(.c) c_int,
    flush: *const fn (*Display) callconv(.c) c_int,

    /// The caller owns the result and closes it with `close`.
    pub fn load() !Xlib {
        var lib = try std.DynLib.openZ(soname);
        errdefer lib.close();
        const bell = lib.lookup(*const fn (*Display, c_int) callconv(.c) c_int, "XBell") orelse
            return error.SymbolNotFound;
        const flush = lib.lookup(*const fn (*Display) callconv(.c) c_int, "XFlush") orelse
            return error.SymbolNotFound;
        return .{ .lib = lib, .bell = bell, .flush = flush };
    }

    pub fn close(self: *Xlib) void {
        self.lib.close();
        self.* = undefined;
    }
};

/// GLFW's own X connection (glfw3native.h). Null unless GLFW runs on X11;
/// check `glfwGetPlatform` first, as ADR 0001 requires.
pub extern "c" fn glfwGetX11Display() ?*Xlib.Display;

/// Sets X11's PRIMARY selection, copying `string` (glfw3native.h, since
/// 3.3). Main thread only, and only while GLFW runs on X11.
extern "c" fn glfwSetX11SelectionString(string: [*:0]const u8) void;
/// X11's PRIMARY selection as UTF-8, or null (glfw3native.h, since 3.3).
/// GLFW owns it until the next selection call. Main thread, X11 only.
extern "c" fn glfwGetX11SelectionString() ?[*:0]const u8;

handle: *c.GLFWwindow,

/// Xlib, loaded on the first X11 bell and closed by `deinit`.
xlib: union(enum) { unloaded, loaded: Xlib, failed } = .unloaded,

/// Whether a bell that could only ask for attention has been logged, so
/// it's logged once rather than on every bell.
silent_bell_logged: bool = false,
/// Whether a PRIMARY write this platform can't do has been logged, so it's
/// logged once.
no_primary_logged: bool = false,

/// The OpenGL core version the renderer needs: the shaders are GLSL 330
/// and every GL call is core in 3.3. Keep it there so the renderer runs
/// on macOS, whose core profile stops at 4.1.
pub const gl_version: struct { major: c_int, minor: c_int } = .{ .major = 3, .minor = 3 };

/// The Wayland app_id and X11 WM_CLASS of Rex's window. Desktops match it
/// against the `.desktop` file name, so it must stay `rex` while the entry
/// is `rex.desktop`.
const app_id = "rex";

/// Asks GLFW for a core `gl_version` context in the next window.
fn hintContext() void {
    c.glfwWindowHint(c.GLFW_CONTEXT_VERSION_MAJOR, gl_version.major);
    c.glfwWindowHint(c.GLFW_CONTEXT_VERSION_MINOR, gl_version.minor);
    c.glfwWindowHint(c.GLFW_OPENGL_PROFILE, c.GLFW_OPENGL_CORE_PROFILE);
    c.glfwWindowHint(c.GLFW_OPENGL_FORWARD_COMPAT, c.GLFW_TRUE); // required on macOS, harmless on Linux
}

const InitOption = struct {
    width: u16,
    height: u16,
    title: [:0]const u8,
    platform: PlatformChoice,
};

pub fn init(option: InitOption) !Window {
    _ = c.glfwSetErrorCallback(glfwErrorCallback);

    try initGlfw(option.platform);

    hintContext();
    c.glfwWindowHint(c.GLFW_DECORATED, c.GLFW_TRUE);
    c.glfwWindowHint(c.GLFW_RESIZABLE, c.GLFW_TRUE);
    c.glfwWindowHint(c.GLFW_FOCUSED, c.GLFW_TRUE);
    c.glfwWindowHint(c.GLFW_TRANSPARENT_FRAMEBUFFER, c.GLFW_TRUE);
    // The configured size is in logical pixels: on X11 GLFW multiplies it
    // by the content scale when it creates the window (x11_window.c); on
    // Wayland the size is logical anyway and the hint is unused.
    c.glfwWindowHint(c.GLFW_SCALE_TO_MONITOR, c.GLFW_TRUE);
    // Without these GLFW sends no app_id on Wayland, and on X11 it uses the
    // window title as WM_CLASS (wl_window.c, x11_window.c).
    c.glfwWindowHintString(c.GLFW_WAYLAND_APP_ID, app_id);
    c.glfwWindowHintString(c.GLFW_X11_CLASS_NAME, app_id);
    c.glfwWindowHintString(c.GLFW_X11_INSTANCE_NAME, app_id);

    const win = c.glfwCreateWindow(
        @intCast(option.width),
        @intCast(option.height),
        option.title.ptr,
        null,
        null,
    ) orelse {
        // GLFW's error callback has already logged its reason.
        log.err("cannot create a window with an OpenGL {d}.{d} core context", .{ gl_version.major, gl_version.minor });
        return error.WindowCreatedFailed;
    };

    c.glfwMakeContextCurrent(win);
    c.glfwSwapInterval(1); // vsync

    // Load OpenGL functions via GLAD
    const loader: gl.GLADloadproc = &gladGetProcAddress;
    if (gl.gladLoadGLLoader(loader) == 0) {
        return error.GladLoadFailed;
    }

    var profile: c_int = 0;
    gl.getIntegerv(gl.CONTEXT_PROFILE_MASK, &profile);
    if (profile & gl.CONTEXT_CORE_PROFILE_BIT == 0) {
        log.warn("got compatibility profile, not core", .{});
    }

    const monitor = c.glfwGetPrimaryMonitor();

    if (monitor) |m| {
        // Monitor name
        if (c.glfwGetMonitorName(m)) |name| {
            log.debug("name: {s}", .{name});
        }

        // Physical size in millimeters
        var physical_width: c_int = 0;
        var physical_height: c_int = 0;

        c.glfwGetMonitorPhysicalSize(m, &physical_width, &physical_height);

        log.debug(
            "physical size: {d}mm x {d}mm",
            .{ physical_width, physical_height },
        );

        if (c.glfwGetVideoMode(m)) |mode| {
            log.debug(
                "resolution: {}x{}",
                .{
                    mode.*.width,
                    mode.*.height,
                },
            );

            log.debug(
                "refresh rate: {} Hz",
                .{mode.*.refreshRate},
            );

            log.debug(
                "color bits: R{} G{} B{}",
                .{
                    mode.*.redBits,
                    mode.*.greenBits,
                    mode.*.blueBits,
                },
            );
        }
    }

    return .{ .handle = win };
}

fn gladGetProcAddress(name: [*c]const u8) callconv(.c) ?*anyopaque {
    const proc = c.glfwGetProcAddress(name) orelse return null;

    const p: *const anyopaque = @ptrCast(proc);
    return @constCast(p);
}

pub fn deinit(self: *Window) void {
    switch (self.xlib) {
        .loaded => |*xlib| xlib.close(),
        .unloaded, .failed => {},
    }
    c.glfwDestroyWindow(self.handle);
    c.glfwTerminate();
    self.* = undefined;
}

/// Refresh rate of the primary monitor in Hz, or null when GLFW does not
/// know it. GLFW has no "monitor this window is on" for a windowed window,
/// so callers treat this as a starting estimate.
pub fn primaryRefreshHz() ?u32 {
    const monitor = c.glfwGetPrimaryMonitor() orelse return null;
    const mode = c.glfwGetVideoMode(monitor) orelse return null;
    if (mode.*.refreshRate <= 0) return null;
    return @intCast(mode.*.refreshRate);
}

pub fn getWindowContentScale(self: *Window) Dimension(f32) {
    var scale: Dimension(f32) = .empty;
    c.glfwGetWindowContentScale(self.handle, &scale.width, &scale.height);
    return scale;
}

pub fn requestWindowAttention(self: *Window) void {
    c.glfwRequestWindowAttention(self.handle);
}

/// What a bell does on a GLFW platform (`glfwGetPlatform`). GLFW has no
/// bell API, so only X11 gets an audible bell; elsewhere the window only
/// asks for attention.
pub const BellKind = enum { audible_x11, attention_only };

pub fn bellKind(platform: c_int) BellKind {
    return if (has_x11 and platform == c.GLFW_PLATFORM_X11) .audible_x11 else .attention_only;
}

/// XBell's percent for a volume fraction: clamped to 0..100, so XBell never
/// gets a value outside -100..100; a non-finite volume counts as 0.
pub fn bellPercent(volume: f32) u8 {
    const fraction = if (std.math.isFinite(volume)) std.math.clamp(volume, 0, 1) else 0;
    return @intFromFloat(@round(fraction * 100));
}

/// Asks for window attention and, on X11, sounds the X bell at `volume`
/// (a fraction, 0 to 1) of its base volume, on GLFW's own connection.
/// XBell answers a percent outside -100..100 with an X error that ends the
/// program, so `volume` is clamped to 0..1 (non-finite counts as 0) before
/// it becomes a percent. Where there is no audible bell, that is logged
/// once. Call on the GLFW (main) thread.
pub fn ringBell(self: *Window, volume: f32) void {
    self.requestWindowAttention();
    switch (bellKind(c.glfwGetPlatform())) {
        .audible_x11 => if (has_x11) self.ringX11Bell(bellPercent(volume)),
        .attention_only => self.logSilentBell("no audible bell on this platform"),
    }
}

fn ringX11Bell(self: *Window, volume: u8) void {
    const display = glfwGetX11Display() orelse return self.logSilentBell("GLFW has no X11 display");
    if (self.xlib == .unloaded) {
        self.xlib = if (Xlib.load()) |xlib| .{ .loaded = xlib } else |err| blk: {
            log.warn("bell: cannot load {s}: {}", .{ Xlib.soname, err });
            break :blk .failed;
        };
    }
    switch (self.xlib) {
        .loaded => |xlib| {
            _ = xlib.bell(display, volume);
            _ = xlib.flush(display);
        },
        .failed => self.logSilentBell("Xlib is unavailable"),
        .unloaded => unreachable,
    }
}

fn logSilentBell(self: *Window, reason: []const u8) void {
    if (self.silent_bell_logged) return;
    self.silent_bell_logged = true;
    log.info("bell: {s}; it only asks for window attention", .{reason});
}

pub fn setWindowUserPointer(self: *Window, ptr: ?*anyopaque) void {
    c.glfwSetWindowUserPointer(self.handle, ptr);
}

pub fn glfwGetWindowUserPointer(window: ?*c.GLFWwindow) ?*anyopaque {
    return c.glfwGetWindowUserPointer(window);
}

pub fn glfwWaitEventsTimeout(timeout: f64) void {
    c.glfwWaitEventsTimeout(timeout);
}

/// Sets the CLIPBOARD selection. GLFW copies `text`. Main thread only.
pub fn setClipboard(self: *Window, text: [:0]const u8) void {
    c.glfwSetClipboardString(self.handle, text.ptr);
}

/// The CLIPBOARD selection as UTF-8, or null when it is empty or not text.
/// GLFW owns it until the next clipboard call. Main thread only.
pub fn getClipboard(self: *Window) ?[:0]const u8 {
    const raw = c.glfwGetClipboardString(self.handle) orelse return null;
    return std.mem.span(raw);
}

/// The PRIMARY selection as UTF-8 where GLFW can read it (X11), else null.
/// GLFW owns it until the next selection call. Main thread only.
pub fn getPrimarySelection(self: *Window) ?[:0]const u8 {
    _ = self;
    if (!has_x11 or c.glfwGetPlatform() != c.GLFW_PLATFORM_X11) return null;
    const raw = glfwGetX11SelectionString() orelse return null;
    return std.mem.span(raw);
}

/// Sets the PRIMARY selection where GLFW can: on X11. Elsewhere (Wayland,
/// which GLFW gives no primary selection, ADR 0001) it does nothing,
/// logs that once and returns false. GLFW copies `text`. Main thread only.
pub fn setPrimarySelection(self: *Window, text: [:0]const u8) bool {
    if (has_x11 and c.glfwGetPlatform() == c.GLFW_PLATFORM_X11) {
        glfwSetX11SelectionString(text.ptr);
        return true;
    }
    if (!self.no_primary_logged) {
        self.no_primary_logged = true;
        log.info("no PRIMARY selection on this platform; only CLIPBOARD is set", .{});
    }
    return false;
}

pub fn setWindowTitle(self: *Window, title: [:0]const u8) void {
    c.glfwSetWindowTitle(self.handle, title.ptr);
}

pub fn windowShouldClose(self: *const Window) bool {
    return c.glfwWindowShouldClose(self.handle) != 0;
}

pub fn setWindowShouldClose(self: *const Window, set: bool) void {
    c.glfwSetWindowShouldClose(self.handle, if (set) c.GLFW_TRUE else c.GLFW_FALSE);
}

pub fn swapBuffers(self: *const Window) void {
    c.glfwSwapBuffers(self.handle);
}

pub fn glfwPollEvents() void {
    c.glfwPollEvents();
}

pub fn glfwPostEmptyEvent() void {
    c.glfwPostEmptyEvent();
}

pub fn setCharCallback(self: *Window, cb: c.GLFWcharfun) void {
    _ = c.glfwSetCharCallback(self.handle, cb);
}

pub fn setKeyCallback(self: *Window, cb: c.GLFWkeyfun) void {
    _ = c.glfwSetKeyCallback(self.handle, cb);
}

pub fn setFramebufferSizeCallback(self: *Window, cb: c.GLFWframebuffersizefun) void {
    _ = c.glfwSetFramebufferSizeCallback(self.handle, cb);
}

pub fn setMouseButtonCallback(self: *Window, cb: c.GLFWmousebuttonfun) void {
    _ = c.glfwSetMouseButtonCallback(self.handle, cb);
}

pub fn setCursorPosCallback(self: *Window, cb: c.GLFWcursorposfun) void {
    _ = c.glfwSetCursorPosCallback(self.handle, cb);
}

pub fn setScrollCallback(self: *Window, cb: c.GLFWscrollfun) void {
    _ = c.glfwSetScrollCallback(self.handle, cb);
}

pub fn setWindowFocusCallback(self: *Window, cb: c.GLFWwindowfocusfun) void {
    _ = c.glfwSetWindowFocusCallback(self.handle, cb);
}

/// Whether this window has input focus. GLFW does not deliver the focus
/// the window opened with, so read this after installing the focus callback.
pub fn focused(self: *const Window) bool {
    return c.glfwGetWindowAttrib(self.handle, c.GLFW_FOCUSED) == c.GLFW_TRUE;
}

pub fn setWindowCloseCallback(self: *Window, cb: c.GLFWwindowclosefun) void {
    _ = c.glfwSetWindowCloseCallback(self.handle, cb);
}

/// Called when the window's content scale changes, for example when it
/// moves to a monitor with another scale. GLFW reports it on Wayland; on
/// X11 the scale is fixed for the session (Xft.dpi) and it never fires.
pub fn setWindowContentScaleCallback(self: *Window, cb: c.GLFWwindowcontentscalefun) void {
    _ = c.glfwSetWindowContentScaleCallback(self.handle, cb);
}

pub fn frameBufferSize(self: *const Window, comptime T: type) Dimension(T) {
    var width: c_int = 0;
    var height: c_int = 0;

    c.glfwGetFramebufferSize(self.handle, &width, &height);
    return .{ .width = convert(T, width), .height = convert(T, height) };
}

fn convert(comptime T: type, value: c_int) T {
    return switch (@typeInfo(T)) {
        .int => @intCast(value),
        .float => @floatFromInt(value),
        else => @compileError("Dimension only supports comptime int or float types"),
    };
}

pub fn glfwGetTime() f64 {
    return c.glfwGetTime();
}

/// The hidden window whose GL context every GL test shares.
var test_window: ?*c.GLFWwindow = null;

/// Makes the shared test GL context current, creating it on the first
/// call. GLFW is initialised once and never terminated during the run,
/// so GL tests may run in any order and must not destroy the window or
/// terminate GLFW themselves. Skips the test when there is no display.
pub fn testGlContext() !void {
    if (!builtin.is_test) @compileError("testGlContext is for tests only");
    if (test_window) |win| return c.glfwMakeContextCurrent(win);

    // No display (headless CI without Xvfb): skip GL tests, not fail.
    if (c.glfwInit() == 0) return error.SkipZigTest;
    c.glfwWindowHint(c.GLFW_VISIBLE, c.GLFW_FALSE);
    hintContext();

    const win = c.glfwCreateWindow(1, 1, "test", null, null) orelse return error.WindowFailed;
    c.glfwMakeContextCurrent(win);

    // Load OpenGL functions via GLAD
    const loader: gl.GLADloadproc = &gladGetProcAddress;
    if (gl.gladLoadGLLoader(loader) == 0) return error.GladLoadFailed;

    var profile: c_int = 0;
    gl.getIntegerv(gl.CONTEXT_PROFILE_MASK, &profile);
    if (profile & gl.CONTEXT_CORE_PROFILE_BIT == 0) {
        log.warn("got compatibility profile, not core", .{});
    }

    test_window = win;
}
