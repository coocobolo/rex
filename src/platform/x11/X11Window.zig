//! A native X11 window with its EGL surface. The window lives in a stable
//! backend slot; no allocation happens after creation.

const std = @import("std");

const X11Window = @This();

const x = @import("x11");
const e = @import("egl");
const gl = @import("../../renderer/gl.zig");
const backend = @import("backend.zig");
const Window = @import("../Window.zig");

/// Selection data must stay available until a requestor reads it. This matches
/// TerminalOption.max_clipboard_bytes (1 MiB); the platform layer cannot import
/// term without breaking the boundary check, so the limit is mirrored here.
const selection_capacity = (1 << 20) + 1;

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
cursors: [3]x.Cursor = @splat(0),
hidden_cursor: x.Cursor = 0,
clipboard_text: [selection_capacity]u8 = undefined,
clipboard_len: usize = 0,
primary_text: [selection_capacity]u8 = undefined,
primary_len: usize = 0,
read_text: [selection_capacity]u8 = undefined,
read_len: usize = 0,

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
    setWindowProperties(lib, display, handle, option.title);
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
    if (gl.gladLoadGLLoader(backend.getProcAddress()) == 0) return error.GladLoadFailed;
    if (backend.state.context == null) {
        backend.state.context = context;
        backend.state.test_surface = surface;
    }

    self.* = .{ .handle = handle, .surface = surface, .context = context };
}

/// Standard properties GLFW sets on X11: tooling locates a window by
/// _NET_WM_PID, and window managers use WM_CLASS and the EWMH title.
fn setWindowProperties(lib: *const @import("xlib.zig").Xlib, display: *x.Display, handle: x.Window, title: [:0]const u8) void {
    const pid: c_long = @intCast(std.c.getpid());
    _ = lib.XChangeProperty(display, handle, lib.XInternAtom(display, "_NET_WM_PID", 0), x.XA_CARDINAL, 32, x.PropModeReplace, @ptrCast(&pid), 1);
    const class = "rex\x00Rex\x00";
    _ = lib.XChangeProperty(display, handle, lib.XInternAtom(display, "WM_CLASS", 0), x.XA_STRING, 8, x.PropModeReplace, class.ptr, class.len);
    _ = lib.XChangeProperty(display, handle, lib.XInternAtom(display, "_NET_WM_NAME", 0), backend.state.utf8_atom, 8, x.PropModeReplace, @ptrCast(title.ptr), @intCast(title.len));
}

pub fn deinit(self: *X11Window) void {
    const lib = &backend.state.x11.?;
    const egl_lib = &backend.state.egl.?;
    const display = backend.state.display.?;
    for (self.cursors) |cursor| {
        if (cursor != 0) _ = lib.XFreeCursor(display, cursor);
    }
    if (self.hidden_cursor != 0) _ = lib.XFreeCursor(display, self.hidden_cursor);
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
    const lib = &backend.state.x11.?;
    const display = backend.state.display.?;
    _ = lib.XStoreName(display, self.handle, @ptrCast(title.ptr));
    _ = lib.XChangeProperty(display, self.handle, lib.XInternAtom(display, "_NET_WM_NAME", 0), backend.state.utf8_atom, 8, x.PropModeReplace, @ptrCast(title.ptr), @intCast(title.len));
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
    var hints: x.XSizeHints = .{};
    hints.flags = x.PMinSize;
    hints.min_width = width;
    hints.min_height = height;
    _ = backend.state.x11.?.XSetWMNormalHints(backend.state.display.?, self.handle, &hints);
    _ = backend.state.x11.?.XFlush(backend.state.display.?);
}

pub fn setPointerShape(self: *X11Window, shape: Window.PointerShape) void {
    if (shape == self.pointer_shape) return;
    const lib = &backend.state.x11.?;
    const display = backend.state.display.?;
    if (self.pointer_visible) _ = lib.XDefineCursor(display, self.handle, self.shapeCursor(shape));
    self.pointer_shape = shape;
    _ = lib.XFlush(display);
}

fn shapeCursor(self: *X11Window, shape: Window.PointerShape) x.Cursor {
    const index = @intFromEnum(shape);
    if (self.cursors[index] == 0) {
        const font_shape: c_uint = switch (shape) {
            .arrow => x.XC_arrow,
            .hand => x.XC_hand2,
            .text => x.XC_xterm,
        };
        self.cursors[index] = backend.state.x11.?.XCreateFontCursor(backend.state.display.?, font_shape);
    }
    return self.cursors[index];
}

pub fn setPointerVisible(self: *X11Window, visible: bool) void {
    if (visible == self.pointer_visible) return;
    const lib = &backend.state.x11.?;
    const display = backend.state.display.?;
    if (visible) {
        _ = lib.XDefineCursor(display, self.handle, self.shapeCursor(self.pointer_shape));
    } else {
        if (self.hidden_cursor == 0) {
            const blank: [1]u8 = .{0};
            const bitmap = lib.XCreateBitmapFromData(display, self.handle, &blank, 1, 1);
            if (bitmap != 0) {
                var fg: x.XColor = .{};
                var bg: x.XColor = .{};
                self.hidden_cursor = lib.XCreatePixmapCursor(display, bitmap, 0, &fg, &bg, 0, 0);
                _ = lib.XFreePixmap(display, bitmap);
            }
        }
        if (self.hidden_cursor != 0) _ = lib.XDefineCursor(display, self.handle, self.hidden_cursor);
    }
    self.pointer_visible = visible;
    _ = lib.XFlush(display);
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
    _ = backend.state.x11.?.XSetSelectionOwner(backend.state.display.?, backend.state.clipboard_atom, self.handle, x.CurrentTime);
}

/// The CLIPBOARD text. Returns our own buffer when this window owns the
/// selection; otherwise converts the X11 selection into `read_text`. The
/// borrowed slice is valid until the next selection call or window destruction.
pub fn getClipboard(self: *X11Window) ?[:0]const u8 {
    const lib = &backend.state.x11.?;
    const owner = lib.XGetSelectionOwner(backend.state.display.?, backend.state.clipboard_atom);
    if (owner == self.handle) {
        if (self.clipboard_len == 0) return null;
        return self.clipboard_text[0..self.clipboard_len :0];
    }
    const n = @import("selection.zig").read(backend.state.clipboard_atom, &self.read_text) orelse return null;
    self.read_text[n] = 0;
    self.read_len = n;
    return self.read_text[0..self.read_len :0];
}

/// PRIMARY selection, read through X11 unless this window owns it. The
/// borrowed slice is valid until the next selection call.
pub fn getPrimarySelection(self: *X11Window) ?[:0]const u8 {
    const lib = &backend.state.x11.?;
    const owner = lib.XGetSelectionOwner(backend.state.display.?, x.XA_PRIMARY);
    if (owner == self.handle) {
        if (self.primary_len == 0) return null;
        return self.primary_text[0..self.primary_len :0];
    }
    const n = @import("selection.zig").read(x.XA_PRIMARY, &self.read_text) orelse return null;
    self.read_text[n] = 0;
    self.read_len = n;
    return self.read_text[0..self.read_len :0];
}

pub fn setPrimarySelection(self: *X11Window, text: [:0]const u8) bool {
    if (text.len >= self.primary_text.len) {
        self.primary_len = 0;
        return false;
    }
    const len = text.len;
    @memcpy(self.primary_text[0..len], text[0..len]);
    self.primary_text[len] = 0;
    self.primary_len = len;
    _ = backend.state.x11.?.XSetSelectionOwner(backend.state.display.?, x.XA_PRIMARY, self.handle, x.CurrentTime);
    return true;
}

pub fn requestAttention(self: *const X11Window) void {
    const lib = &backend.state.x11.?;
    const display = backend.state.display.?;
    if (lib.XGetWMHints(display, self.handle)) |hints| {
        hints.*.flags |= x.XUrgencyHint;
        _ = lib.XSetWMHints(display, self.handle, hints);
        _ = lib.XFree(@ptrCast(hints));
    } else {
        var hints: x.XWMHints = .{};
        hints.flags = x.XUrgencyHint;
        _ = lib.XSetWMHints(display, self.handle, &hints);
    }
    _ = lib.XFlush(display);
}

pub fn ringBell(self: *const X11Window, volume: f32) void {
    _ = self;
    const fraction = if (std.math.isFinite(volume)) std.math.clamp(volume, 0, 1) else 0;
    const percent: c_int = @intFromFloat(@round(fraction * 100));
    _ = backend.state.x11.?.XBell(backend.state.display.?, percent);
}
