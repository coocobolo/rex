const std = @import("std");
const builtin = @import("builtin");

const log = std.log.scoped(.window);

// const c = @import("c");

const c = @cImport({
    @cInclude("glad/glad.h");
    @cInclude("GLFW/glfw3.h");
});

pub const Window = @This();

handle: *c.GLFWwindow,

pub const Option = struct {
    width: u16,
    height: u16,
    title: [:0]const u8,
    adaptive_sync: bool = false,
};

const InitErr = error{
    InitFailed,
    WindowCreatedFailed,
    InitOpenGLContextFailed,
};

pub fn create(option: Option) InitErr!Window {
    _ = c.glfwSetErrorCallback(errorCallback);
    if (c.glfwInit() == 0) return error.InitFailed;
    errdefer c.glfwTerminate();

    const win = try setDefault(option);
    c.glfwMakeContextCurrent(win);

    if (option.adaptive_sync) {
        c.glfwSwapInterval(1); // vsync
    }

    return .{ .handle = win };
}

pub fn destroy(self: *Window) void {
    c.glfwDestroyWindow(self.handle);
    c.glfwTerminate();
}

pub fn testRender(self: *Window) void {
    c.glClearColor(0.0, 0.0, 0.0, 1.0); // black
    c.glPixelStorei(c.GL_UNPACK_ALIGNMENT, 1);

    while (!self.shouldClose()) {
        c.glClear(c.GL_COLOR_BUFFER_BIT); // clears to black
        // (optional: draw your textured quad here)
        c.glfwSwapBuffers(self.handle);
        c.glfwPollEvents();
    }
}

fn setDefault(option: Option) InitErr!*c.struct_GLFWwindow {
    c.glfwWindowHint(c.GLFW_CONTEXT_VERSION_MAJOR, 3);
    c.glfwWindowHint(c.GLFW_CONTEXT_VERSION_MINOR, 3);
    c.glfwWindowHint(c.GLFW_OPENGL_PROFILE, c.GLFW_OPENGL_CORE_PROFILE);
    c.glfwWindowHint(c.GLFW_OPENGL_FORWARD_COMPAT, c.GL_TRUE); // required on macOS, harmless on Linux
    c.glfwWindowHint(c.GLFW_DECORATED, c.GLFW_TRUE);
    c.glfwWindowHint(c.GLFW_RESIZABLE, c.GLFW_TRUE);
    c.glfwWindowHint(c.GLFW_TRANSPARENT_FRAMEBUFFER, c.GLFW_TRUE);

    const win = c.glfwCreateWindow(
        @intCast(option.width),
        @intCast(option.height),
        option.title.ptr,
        null,
        null,
    ) orelse {
        return error.WindowCreatedFailed;
    };

    return win;
}

pub fn gladLoadGLContext(self: *const Window) InitErr!void {
    _ = self;
    // Load OpenGL functions via GLAD
    const version = c.gladLoadGLLoader(@ptrCast(&c.glfwGetProcAddress));
    if (version == 0) return error.InitOpenGLContextFailed;

    var profile: c_int = 0;
    c.glGetIntegerv(c.GL_CONTEXT_PROFILE_MASK, &profile);
    if (profile & c.GL_CONTEXT_CORE_PROFILE_BIT == 0) {
        log.warn("WARNING: got compatibility profile, not core!", .{});
    }
}

fn errorCallback(code: c_int, message: [*c]const u8) callconv(.c) void {
    log.err("GLFW error {d}: {s}", .{ code, message });
}

pub fn setUserPointer(self: *Window, ptr: ?*anyopaque) void {
    c.glfwSetWindowUserPointer(self.handle, ptr);
}

pub fn getUserPointer(self: *Window) ?*anyopaque {
    return c.glfwGetWindowUserPointer(self.handle);
}

pub fn waitEventsTimeout(_: *Window, timeout: f64) void {
    c.glfwWaitEventsTimeout(timeout);
}

pub fn setTitle(self: *const Window, title: [:0]const u8) void {
    c.glfwSetWindowTitle(self.handle, title.ptr);
}

pub fn shouldClose(self: *const Window) bool {
    return c.glfwWindowShouldClose(self.handle) != 0;
}

pub fn swapBuffers(self: *const Window) void {
    c.glfwSwapBuffers(self.handle);
}

pub fn pollEvents(_: *const Window) void {
    c.glfwPollEvents();
}

pub fn setCharCallback(self: *Window, cb: c.GLFWcharfun) void {
    _ = c.glfwSetCharCallback(self.handle, cb);
}

pub fn setKeyCallback(self: *Window, cb: c.GLFWkeyfun) void {
    _ = c.glfwSetKeyCallback(self.handle, cb);
}

pub fn framebufferSize(self: *const Window) struct { w: u16, h: u16 } {
    var w: c_int = 0;
    var h: c_int = 0;
    c.glfwGetFramebufferSize(self.handle, &w, &h);
    return .{ .w = @intCast(w), .h = @intCast(h) };
}
