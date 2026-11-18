//! A native X11 window with its EGL surface. The window lives in a stable
//! backend slot; no allocation happens after creation.

const std = @import("std");

const X11Window = @This();

const x = @import("x11");
const e = @import("egl");
const backend = @import("backend.zig");
const Window = @import("../Window.zig");

pub const InitOption = struct {
    width: u16,
    height: u16,
    title: [:0]const u8,
};

handle: x.Window,
surface: e.EGLSurface = null,
context: e.EGLContext = null,
/// Application pointer set through the platform API.
context_ptr: ?*anyopaque = null,
should_close: bool = false,
focused: bool = false,
pointer_visible: bool = true,
pointer_shape: Window.PointerShape = .arrow,
clipboard_text: [4096]u8 = undefined,
clipboard_len: usize = 0,

pub fn init(self: *X11Window, option: InitOption) !void {
    const lib = &backend.state.x11.?;
    const display = backend.state.display.?;
    const root = lib.XDefaultRootWindow(display);
    const handle = lib.XCreateSimpleWindow(
        display,
        root,
        0,
        0,
        @intCast(option.width),
        @intCast(option.height),
        0,
        0,
        0,
    );
    if (handle == 0) return error.WindowCreatedFailed;
    errdefer _ = lib.XDestroyWindow(display, handle);

    _ = lib.XStoreName(display, handle, @ptrCast(option.title.ptr));
    _ = lib.XSelectInput(display, handle, x.StructureNotifyMask | x.KeyPressMask | x.KeyReleaseMask |
        x.ButtonPressMask | x.ButtonReleaseMask | x.PointerMotionMask | x.EnterWindowMask |
        x.LeaveWindowMask | x.FocusChangeMask);
    const protocols = [_]x.Atom{backend.state.wm_delete_atom};
    _ = lib.XChangeProperty(display, handle, backend.state.wm_protocols_atom, x.XA_ATOM, 32, x.PropModeReplace, @ptrCast(&protocols), 1);
    _ = lib.XMapWindow(display, handle);
    _ = lib.XSync(display, 0);

    const egl_lib = &backend.state.egl.?;
    const surface = egl_lib.eglCreateWindowSurface(
        backend.state.egl_display,
        backend.state.egl_config,
        @intCast(handle),
        null,
    );
    if (surface == e.EGL_NO_SURFACE) return error.SurfaceFailed;
    errdefer _ = egl_lib.eglDestroySurface(backend.state.egl_display, surface);

    const ctx_attr = [_]e.EGLint{
        e.EGL_CONTEXT_MAJOR_VERSION,       3,
        e.EGL_CONTEXT_MINOR_VERSION,       3,
        e.EGL_CONTEXT_OPENGL_PROFILE_MASK, e.EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT,
        e.EGL_NONE,
    };
    const context = egl_lib.eglCreateContext(backend.state.egl_display, backend.state.egl_config, null, &ctx_attr);
    if (context == e.EGL_NO_CONTEXT) return error.ContextFailed;
    errdefer _ = egl_lib.eglDestroyContext(backend.state.egl_display, context);

    if (egl_lib.eglMakeCurrent(backend.state.egl_display, surface, surface, context) == 0)
        return error.MakeCurrentFailed;
    if (backend.state.context == null) {
        backend.state.context = context;
        backend.state.test_surface = surface;
    }

    self.* = .{ .handle = handle, .surface = surface, .context = context };
}

pub fn deinit(self: *X11Window) void {
    const lib = &backend.state.x11.?;
    const egl_lib = &backend.state.egl.?;
    if (backend.state.context != self.context) _ = egl_lib.eglDestroyContext(backend.state.egl_display, self.context);
    _ = egl_lib.eglDestroySurface(backend.state.egl_display, self.surface);
    _ = lib.XDestroyWindow(backend.state.display.?, self.handle);
    self.* = undefined;
}

pub fn setContext(self: *X11Window, ptr: ?*anyopaque) void {
    self.context_ptr = ptr;
}

pub fn getContext(self: *const X11Window) ?*anyopaque {
    return self.context_ptr;
}

pub fn setTitle(self: *X11Window, title: [:0]const u8) void {
    _ = backend.state.x11.?.XStoreName(backend.state.display.?, self.handle, @ptrCast(title.ptr));
}

pub fn swapBuffers(self: *const X11Window) void {
    _ = backend.state.egl.?.eglSwapBuffers(backend.state.egl_display, self.surface);
}

pub fn framebufferSize(self: *const X11Window, comptime T: type) @import("../../renderer/dimension.zig").Dimension(T) {
    var root: x.Window = 0;
    var x_pos: c_int = 0;
    var y_pos: c_int = 0;
    var width: c_uint = 0;
    var height: c_uint = 0;
    var border: c_uint = 0;
    var depth: c_uint = 0;
    _ = backend.state.x11.?.XGetGeometry(
        backend.state.display.?,
        self.handle,
        &root,
        &x_pos,
        &y_pos,
        &width,
        &height,
        &border,
        &depth,
    );
    return .{
        .width = convert(T, width),
        .height = convert(T, height),
    };
}

fn convert(comptime T: type, value: c_uint) T {
    return switch (@typeInfo(T)) {
        .int => @intCast(value),
        .float => @floatFromInt(value),
        else => @compileError("Dimension only supports int or float"),
    };
}

pub fn contentScale(self: *const X11Window) @import("../../renderer/dimension.zig").Dimension(f32) {
    _ = self;
    return .{ .width = 1, .height = 1 };
}

pub fn setMinimumSize(self: *X11Window, width: c_int, height: c_int) void {
    _ = self;
    _ = width;
    _ = height;
}

pub fn setPointerShape(self: *X11Window, shape: Window.PointerShape) void {
    self.pointer_shape = shape;
}

pub fn setPointerVisible(self: *X11Window, visible: bool) void {
    self.pointer_visible = visible;
}

/// Sets the local clipboard copy. An oversized string is dropped whole,
/// never truncated, matching the host input policy.
pub fn setClipboard(self: *X11Window, text: [:0]const u8) void {
    if (text.len >= self.clipboard_text.len) {
        self.clipboard_len = 0;
        return;
    }
    const len = text.len;
    @memcpy(self.clipboard_text[0..len], text[0..len]);
    self.clipboard_text[len] = 0;
    self.clipboard_len = len;
}

/// The local clipboard copy. The slice is borrowed from this window and is
/// valid until the next setClipboard call or window destruction.
pub fn getClipboard(self: *const X11Window) ?[:0]const u8 {
    if (self.clipboard_len == 0) return null;
    return self.clipboard_text[0..self.clipboard_len :0];
}

pub fn getPrimarySelection(self: *const X11Window) ?[:0]const u8 {
    return self.getClipboard();
}

pub fn setPrimarySelection(self: *X11Window, text: [:0]const u8) bool {
    self.setClipboard(text);
    return true;
}

pub fn requestAttention(self: *const X11Window) void {
    _ = self;
}

pub fn ringBell(self: *const X11Window, volume: f32) void {
    _ = self;
    const fraction = if (std.math.isFinite(volume)) std.math.clamp(volume, 0, 1) else 0;
    const percent: c_int = @intFromFloat(@round(fraction * 100));
    _ = backend.state.x11.?.XBell(backend.state.display.?, percent);
}
