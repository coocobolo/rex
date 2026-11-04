const Window = @This();

const std = @import("std");
const builtin = @import("builtin");

const log = std.log.scoped(.window);

const Dimension = @import("dimension.zig").Dimension;

const gl = @import("gl.zig");

pub const c = @cImport({
    @cInclude("GLFW/glfw3.h");
});

pub const GlfwWindow = c.GLFWwindow;

fn glfwErrorCallback(code: c_int, desc: [*c]const u8) callconv(.c) void {
    log.err("GLFW error {d}: {s}", .{ code, desc });
}

const x11 = if (builtin.os.tag == .linux or builtin.os.tag == .freebsd)
    @cImport(@cInclude("X11/Xlib.h"))
else
    struct {};

handle: *c.GLFWwindow,

pub fn init(width: u16, height: u16, title: [:0]const u8) !Window {
    var major: c_int = 0;
    var minor: c_int = 0;
    var revision: c_int = 0;

    c.glfwGetVersion(&major, &minor, &revision);

    // std.debug.print(
    //     "GLFW version: {}.{}.{}\n",
    //     .{ major, minor, revision },
    // );

    _ = c.glfwSetErrorCallback(glfwErrorCallback);
    if (c.glfwInit() == 0) return error.GlfwInitFailed;

    c.glfwWindowHint(c.GLFW_CONTEXT_VERSION_MAJOR, major);
    c.glfwWindowHint(c.GLFW_CONTEXT_VERSION_MINOR, minor);
    c.glfwWindowHint(c.GLFW_OPENGL_PROFILE, c.GLFW_OPENGL_CORE_PROFILE);
    c.glfwWindowHint(c.GLFW_OPENGL_FORWARD_COMPAT, c.GL_TRUE); // required on macOS, harmless on Linux
    c.glfwWindowHint(c.GLFW_DECORATED, c.GLFW_TRUE);
    c.glfwWindowHint(c.GLFW_RESIZABLE, c.GLFW_TRUE);
    c.glfwWindowHint(c.GLFW_FOCUSED, c.GLFW_TRUE);
    c.glfwWindowHint(c.GLFW_TRANSPARENT_FRAMEBUFFER, c.GLFW_TRUE);

    // c.glfwWindowHint(c.GLFW_ALPHA_BITS, 8);
    // c.glfwWindowHint(c.GLFW_SRGB_CAPABLE, c.GLFW_FALSE);

    const win = c.glfwCreateWindow(
        @intCast(width),
        @intCast(height),
        title.ptr,
        null,
        null,
    ) orelse {
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
    gl.getIntegerv(c.GL_CONTEXT_PROFILE_MASK, &profile);
    if (profile & c.GL_CONTEXT_CORE_PROFILE_BIT == 0) {
        log.warn("got compatibility profile, not the core!", .{});
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
    c.glfwDestroyWindow(self.handle);
    c.glfwTerminate();
    self.* = undefined;
}

pub fn getWindowContentScale(self: *Window) Dimension(f32) {
    var scale: Dimension(f32) = .empty;
    c.glfwGetWindowContentScale(self.handle, &scale.width, &scale.height);
    return scale;
}

pub fn requestWindowAttention(self: *Window) void {
    c.glfwRequestWindowAttention(self.handle);
}

fn ringBellX11(volume: u8) void {
    if (builtin.os.tag == .linux or builtin.os.tag == .freebsd) {
        const display = x11.XOpenDisplay(null) orelse return;
        defer _ = x11.XCloseDisplay(display);
        _ = x11.XBell(display, @intCast(volume)); // percent of base volume
        _ = x11.XFlush(display);
    }
}

pub fn ringBell(self: *Window, volume: u8) void {
    self.requestWindowAttention();
    switch (builtin.os.tag) {
        .linux, .freebsd => ringBellX11(volume),
        else => {},
    }
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

pub fn setWindowTitle(self: *Window, title: [:0]const u8) void {
    c.glfwSetWindowTitle(self.handle, title.ptr);
}

pub fn windowShouldClose(self: *const Window) bool {
    return c.glfwWindowShouldClose(self.handle) != 0;
}

pub fn setWindowShouldClose(self: *const Window, set: bool) bool {
    return c.glfwSetWindowShouldClose(self.handle, set) != 0;
}

pub fn swapBuffers(self: *const Window) void {
    c.glfwSwapBuffers(self.handle);
}

pub fn glfwPollEvents() void {
    c.glfwPollEvents();
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

pub fn testGlContext() !*c.GLFWwindow {
    if (c.glfwInit() == 0) return error.GlfwInitFailed;
    c.glfwWindowHint(c.GLFW_VISIBLE, c.GLFW_FALSE);
    c.glfwWindowHint(c.GLFW_CONTEXT_VERSION_MAJOR, 3);
    c.glfwWindowHint(c.GLFW_CONTEXT_VERSION_MINOR, 3);

    const win = c.glfwCreateWindow(
        1,
        1,
        "test",
        null,
        null,
    ) orelse return error.WindowFailed;
    c.glfwMakeContextCurrent(win);

    // Load OpenGL functions via GLAD

    const loader: gl.GLADloadproc = &gladGetProcAddress;
    if (gl.gladLoadGLLoader(loader) == 0) return error.GladLoadFailed;

    var profile: c_int = 0;
    gl.getIntegerv(c.GL_CONTEXT_PROFILE_MASK, &profile);
    if (profile & c.GL_CONTEXT_CORE_PROFILE_BIT == 0) {
        log.warn("WARNING: got compatibility profile, not core!", .{});
    }

    return win;
}
