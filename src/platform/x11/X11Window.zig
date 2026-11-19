//! A native X11 window with its EGL surface. The window lives in a stable
//! backend slot; no allocation happens after creation.

const std = @import("std");

const x = @import("x11");
const e = @import("egl");
const gl = @import("../../renderer/gl.zig");
const Dimension = @import("../../renderer/dimension.zig").Dimension;
const backend = @import("backend.zig");
const Window = @import("../Window.zig");
const xlib = @import("xlib.zig");
const selection = @import("selection.zig");

const X11Window = @This();

/// The size, title, and decoration preference requested for a new window.
pub const InitOption = struct {
    width: u16,
    height: u16,
    title: [:0]const u8,
    decorated: bool = true,
};

handle: x.Window,
surface: e.EGLSurface = null,
context: e.EGLContext = null,
/// Application pointer set through the platform API.
context_ptr: ?*anyopaque = null,
cursors: [@typeInfo(Window.PointerShape).@"enum".fields.len]x.Cursor = @splat(0),
hidden_cursor: x.Cursor = 0,
should_close: bool = false,
focused: bool = false,
pointer_visible: bool = true,
pointer_shape: Window.PointerShape = .arrow,

/// Creates the X11 window, EGL surface and core context in place.
pub fn init(self: *X11Window, option: InitOption) error{ WindowCreatedFailed, SurfaceFailed, ContextFailed, MakeCurrentFailed, GladLoadFailed }!void {
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
    if (!option.decorated) applyDecoratedHint(lib, display, handle, false);
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
fn setWindowProperties(lib: *const xlib.Xlib, display: *x.Display, handle: x.Window, title: [:0]const u8) void {
    const pid: c_long = @intCast(std.c.getpid());
    _ = lib.XChangeProperty(display, handle, lib.XInternAtom(display, "_NET_WM_PID", 0), x.XA_CARDINAL, 32, x.PropModeReplace, @ptrCast(&pid), 1);
    const class = "rex\x00Rex\x00";
    _ = lib.XChangeProperty(display, handle, lib.XInternAtom(display, "WM_CLASS", 0), x.XA_STRING, 8, x.PropModeReplace, class.ptr, class.len);
    _ = lib.XChangeProperty(display, handle, lib.XInternAtom(display, "_NET_WM_NAME", 0), backend.state.utf8_atom, 8, x.PropModeReplace, @ptrCast(title.ptr), @intCast(title.len));
}

/// Releases the context, surface and window, then poisons `self`.
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

/// Associates an application pointer with the window.
pub fn setContext(self: *X11Window, ptr: ?*anyopaque) void {
    self.context_ptr = ptr;
}

/// The application pointer set on the window.
pub fn getContext(self: *const X11Window) ?*anyopaque {
    return self.context_ptr;
}

/// Sets the window title and EWMH name.
pub fn setTitle(self: *X11Window, title: [:0]const u8) void {
    const lib = &backend.state.x11.?;
    const display = backend.state.display.?;
    _ = lib.XStoreName(display, self.handle, @ptrCast(title.ptr));
    _ = lib.XChangeProperty(display, self.handle, lib.XInternAtom(display, "_NET_WM_NAME", 0), backend.state.utf8_atom, 8, x.PropModeReplace, @ptrCast(title.ptr), @intCast(title.len));
}

/// Shows or hides window manager decorations via `_MOTIF_WM_HINTS`.
pub fn setDecorated(self: *const X11Window, decorated: bool) void {
    const lib = &backend.state.x11.?;
    const display = backend.state.display.?;
    applyDecoratedHint(lib, display, self.handle, decorated);
    _ = lib.XFlush(display);
}

fn applyDecoratedHint(lib: *const xlib.Xlib, display: *x.Display, handle: x.Window, decorated: bool) void {
    const atom = lib.XInternAtom(display, "_MOTIF_WM_HINTS", 0);
    if (atom == 0) return;
    // Xlib format 32 expects `c_ulong` elements per property item:
    // flags = MWM_HINTS_DECORATIONS (1 << 1), decorations = 1 (all) or 0 (none).
    const hints = [5]c_ulong{ 2, 0, if (decorated) 1 else 0, 0, 0 };
    _ = lib.XChangeProperty(display, handle, atom, atom, 32, x.PropModeReplace, @ptrCast(&hints), hints.len);
}

/// Presents the rendered frame.
pub fn swapBuffers(self: *const X11Window) void {
    _ = backend.state.egl.?.eglSwapBuffers(backend.state.egl_display, self.surface);
}

/// The drawable size in pixels, converted to `T`.
pub fn framebufferSize(self: *const X11Window, comptime T: type) Dimension(T) {
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

/// The logical-to-device scale, which X11 reports as one.
pub fn contentScale(self: *const X11Window) Dimension(f32) {
    _ = self;
    return .{ .width = 1, .height = 1 };
}

/// Sets the smallest size the user may resize to.
pub fn setMinimumSize(self: *X11Window, size: Window.MinimumSize) void {
    var hints: x.XSizeHints = .{};
    hints.flags = x.PMinSize;
    hints.min_width = @intCast(size.width);
    hints.min_height = @intCast(size.height);
    _ = backend.state.x11.?.XSetWMNormalHints(backend.state.display.?, self.handle, &hints);
    _ = backend.state.x11.?.XFlush(backend.state.display.?);
}

/// Shows the given standard cursor over the window.
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

/// Shows or hides the pointer over the window.
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
    const sel = &backend.selection_state;
    if (text.len >= sel.clipboard_text.len) {
        sel.clipboard_len = 0;
        sel.clipboard_owner = 0;
        return;
    }
    const len = text.len;
    @memcpy(sel.clipboard_text[0..len], text[0..len]);
    sel.clipboard_text[len] = 0;
    sel.clipboard_len = len;
    sel.clipboard_owner = self.handle;
    _ = backend.state.x11.?.XSetSelectionOwner(backend.state.display.?, backend.state.clipboard_atom, self.handle, x.CurrentTime);
}

/// The CLIPBOARD text. Returns our own buffer when this window owns the
/// selection; otherwise converts the X11 selection into `read_text`. The
/// borrowed slice is valid until the next selection call or window destruction.
pub fn getClipboard(self: *X11Window) ?[:0]const u8 {
    const lib = &backend.state.x11.?;
    const sel = &backend.selection_state;
    const owner = lib.XGetSelectionOwner(backend.state.display.?, backend.state.clipboard_atom);
    if (owner == self.handle and sel.clipboard_owner == self.handle) {
        if (sel.clipboard_len == 0) return null;
        return sel.clipboard_text[0..sel.clipboard_len :0];
    }
    const n = selection.read(backend.state.clipboard_atom, sel.read_text[0 .. sel.read_text.len - 1]) orelse return null;
    sel.read_text[n] = 0;
    sel.read_len = n;
    return sel.read_text[0..sel.read_len :0];
}

/// PRIMARY selection, read through X11 unless this window owns it. The
/// borrowed slice is valid until the next selection call.
pub fn getPrimarySelection(self: *X11Window) ?[:0]const u8 {
    const lib = &backend.state.x11.?;
    const sel = &backend.selection_state;
    const owner = lib.XGetSelectionOwner(backend.state.display.?, x.XA_PRIMARY);
    if (owner == self.handle and sel.primary_owner == self.handle) {
        if (sel.primary_len == 0) return null;
        return sel.primary_text[0..sel.primary_len :0];
    }
    const n = selection.read(x.XA_PRIMARY, sel.read_text[0 .. sel.read_text.len - 1]) orelse return null;
    sel.read_text[n] = 0;
    sel.read_len = n;
    return sel.read_text[0..sel.read_len :0];
}

/// Sets PRIMARY, returning false when the text does not fit.
pub fn setPrimarySelection(self: *X11Window, text: [:0]const u8) bool {
    const sel = &backend.selection_state;
    if (text.len >= sel.primary_text.len) {
        sel.primary_len = 0;
        sel.primary_owner = 0;
        return false;
    }
    const len = text.len;
    @memcpy(sel.primary_text[0..len], text[0..len]);
    sel.primary_text[len] = 0;
    sel.primary_len = len;
    sel.primary_owner = self.handle;
    _ = backend.state.x11.?.XSetSelectionOwner(backend.state.display.?, x.XA_PRIMARY, self.handle, x.CurrentTime);
    return true;
}

/// Marks the window urgent to draw attention.
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

/// Rings XBell at the given volume.
pub fn ringBell(self: *const X11Window, volume: f32) void {
    _ = self;
    const fraction = if (std.math.isFinite(volume)) std.math.clamp(volume, 0, 1) else 0;
    const percent: c_int = @intFromFloat(@round(fraction * 100));
    _ = backend.state.x11.?.XBell(backend.state.display.?, percent);
}
