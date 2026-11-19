//! A native Wayland window with its xdg_toplevel and EGL surface. The window
//! lives in a stable backend slot so Wayland listener user-data pointers stay
//! valid for the window's lifetime; no allocation happens after creation.

const std = @import("std");

const e = @import("egl");
const w = @import("wayland");
const gl = @import("../../renderer/gl.zig");
const Dimension = @import("../../renderer/dimension.zig").Dimension;
const Window = @import("../Window.zig");
const backend = @import("backend.zig");
const proto = @import("proto.zig");
const wl = @import("wl.zig");

const WaylandWindow = @This();

wl_surface: ?*wl.Proxy = null,
xdg_surface: ?*wl.Proxy = null,
xdg_toplevel: ?*wl.Proxy = null,
xdg_decoration: ?*wl.Proxy = null,
fractional_scale: ?*wl.Proxy = null,
viewport: ?*wl.Proxy = null,
egl_window: ?*w.wl_egl_window = null,
egl_surface: e.EGLSurface = null,
context: e.EGLContext = null,
/// Application pointer set through the platform API.
context_ptr: ?*anyopaque = null,
logical_width: u32 = 0,
logical_height: u32 = 0,
pending_width: u32 = 0,
pending_height: u32 = 0,
scale: f32 = 1.0,
configured: bool = false,
should_close: bool = false,
focused: bool = false,
pending_activated: bool = false,
pointer_visible: bool = true,
pointer_shape: Window.PointerShape = .arrow,

pub const InitOption = struct {
    width: u16,
    height: u16,
    title: [:0]const u8,
    decorated: bool = true,
};

pub const Error = error{
    SurfaceFailed,
    ToplevelFailed,
    EglWindowFailed,
    ContextFailed,
    MakeCurrentFailed,
    GlLoadFailed,
};

/// Initializes the window in its pinned backend slot (`self`).
pub fn init(self: *WaylandWindow, option: InitOption) Error!void {
    const wl_lib = &backend.state.wl.?;
    const wl_egl_lib = &backend.state.wl_egl.?;
    const egl_lib = &backend.state.egl.?;
    const ifaces = proto.interfaces();

    const compositor = backend.state.compositor orelse return error.SurfaceFailed;
    const wm_base = backend.state.xdg_wm_base orelse return error.ToplevelFailed;

    self.* = .{
        .logical_width = @max(@as(u32, option.width), 1),
        .logical_height = @max(@as(u32, option.height), 1),
    };

    const surf = wl_lib.wl_proxy_marshal_flags(
        compositor,
        proto.compositor.create_surface,
        wl_lib.surface_interface,
        wl_lib.wl_proxy_get_version(compositor),
        0,
        @as(?*anyopaque, null),
    ) orelse return error.SurfaceFailed;
    self.wl_surface = surf;
    errdefer {
        _ = wl_lib.wl_proxy_marshal_flags(surf, proto.surface.destroy, null, wl_lib.wl_proxy_get_version(surf), proto.marshal_flag_destroy);
        self.wl_surface = null;
    }

    const xdg_surf = wl_lib.wl_proxy_marshal_flags(
        wm_base,
        proto.xdg_wm_base.get_xdg_surface,
        ifaces.xdg_surface,
        wl_lib.wl_proxy_get_version(wm_base),
        0,
        @as(?*anyopaque, null),
        surf,
    ) orelse return error.ToplevelFailed;
    self.xdg_surface = xdg_surf;
    errdefer {
        _ = wl_lib.wl_proxy_marshal_flags(xdg_surf, proto.xdg_surface.destroy, null, wl_lib.wl_proxy_get_version(xdg_surf), proto.marshal_flag_destroy);
        self.xdg_surface = null;
    }
    _ = wl_lib.wl_proxy_add_listener(xdg_surf, @ptrCast(@constCast(&xdg_surface_listener)), self);

    const toplevel = wl_lib.wl_proxy_marshal_flags(
        xdg_surf,
        proto.xdg_surface.get_toplevel,
        ifaces.xdg_toplevel,
        wl_lib.wl_proxy_get_version(xdg_surf),
        0,
        @as(?*anyopaque, null),
    ) orelse return error.ToplevelFailed;
    self.xdg_toplevel = toplevel;
    errdefer {
        _ = wl_lib.wl_proxy_marshal_flags(toplevel, proto.xdg_toplevel.destroy, null, wl_lib.wl_proxy_get_version(toplevel), proto.marshal_flag_destroy);
        self.xdg_toplevel = null;
    }
    _ = wl_lib.wl_proxy_add_listener(toplevel, @ptrCast(@constCast(&xdg_toplevel_listener)), self);

    self.setTitle(option.title);
    const app_id: [:0]const u8 = "rex";
    _ = wl_lib.wl_proxy_marshal_flags(
        toplevel,
        proto.xdg_toplevel.set_app_id,
        null,
        wl_lib.wl_proxy_get_version(toplevel),
        0,
        app_id.ptr,
    );

    if (backend.state.xdg_decoration_manager) |mgr| {
        if (wl_lib.wl_proxy_marshal_flags(
            mgr,
            proto.xdg_decoration_manager.get_toplevel_decoration,
            ifaces.xdg_toplevel_decoration,
            wl_lib.wl_proxy_get_version(mgr),
            0,
            @as(?*anyopaque, null),
            toplevel,
        )) |deco| {
            self.xdg_decoration = deco;
            _ = wl_lib.wl_proxy_add_listener(deco, @ptrCast(@constCast(&xdg_decoration_listener)), self);
            const mode = if (option.decorated)
                proto.xdg_toplevel_decoration.mode_server_side
            else
                proto.xdg_toplevel_decoration.mode_client_side;
            _ = wl_lib.wl_proxy_marshal_flags(
                deco,
                proto.xdg_toplevel_decoration.set_mode,
                null,
                wl_lib.wl_proxy_get_version(deco),
                0,
                mode,
            );
        }
    }
    errdefer if (self.xdg_decoration) |deco| {
        _ = wl_lib.wl_proxy_marshal_flags(deco, proto.xdg_toplevel_decoration.destroy, null, wl_lib.wl_proxy_get_version(deco), proto.marshal_flag_destroy);
        self.xdg_decoration = null;
    };

    if (backend.state.fractional_scale_manager) |fs_mgr| {
        if (wl_lib.wl_proxy_marshal_flags(
            fs_mgr,
            proto.fractional_scale_manager.get_fractional_scale,
            ifaces.fractional_scale,
            wl_lib.wl_proxy_get_version(fs_mgr),
            0,
            @as(?*anyopaque, null),
            surf,
        )) |fs| {
            self.fractional_scale = fs;
            _ = wl_lib.wl_proxy_add_listener(fs, @ptrCast(@constCast(&fractional_scale_listener)), self);
        }
    }
    errdefer if (self.fractional_scale) |fs| {
        _ = wl_lib.wl_proxy_marshal_flags(fs, proto.fractional_scale.destroy, null, wl_lib.wl_proxy_get_version(fs), proto.marshal_flag_destroy);
        self.fractional_scale = null;
    };

    if (backend.state.viewporter) |vp_mgr| {
        self.viewport = wl_lib.wl_proxy_marshal_flags(
            vp_mgr,
            proto.viewporter.get_viewport,
            ifaces.viewport,
            wl_lib.wl_proxy_get_version(vp_mgr),
            0,
            @as(?*anyopaque, null),
            surf,
        );
    }
    errdefer if (self.viewport) |vp| {
        _ = wl_lib.wl_proxy_marshal_flags(vp, proto.viewport.destroy, null, wl_lib.wl_proxy_get_version(vp), proto.marshal_flag_destroy);
        self.viewport = null;
    };

    // Commit empty surface so the compositor sends the initial configure.
    _ = wl_lib.wl_proxy_marshal_flags(surf, proto.surface.commit, null, wl_lib.wl_proxy_get_version(surf), 0);
    _ = wl_lib.wl_display_roundtrip(backend.state.display.?);
    self.applyViewport();

    const fb_w: c_int = @intCast(self.pixelWidth());
    const fb_h: c_int = @intCast(self.pixelHeight());
    const egl_win = wl_egl_lib.wl_egl_window_create(@ptrCast(surf), fb_w, fb_h) orelse
        return error.EglWindowFailed;
    self.egl_window = egl_win;
    errdefer {
        wl_egl_lib.wl_egl_window_destroy(egl_win);
        self.egl_window = null;
    }

    const native_win: e.EGLNativeWindowType = @intFromPtr(egl_win);
    const egl_surf = egl_lib.eglCreateWindowSurface(
        backend.state.egl_display,
        backend.state.egl_config,
        native_win,
        null,
    );
    if (egl_surf == e.EGL_NO_SURFACE) return error.SurfaceFailed;
    self.egl_surface = egl_surf;
    errdefer {
        _ = egl_lib.eglDestroySurface(backend.state.egl_display, egl_surf);
        self.egl_surface = null;
    }

    const ctx_attr = [_]e.EGLint{
        e.EGL_CONTEXT_MAJOR_VERSION,       backend.gl_version.major,
        e.EGL_CONTEXT_MINOR_VERSION,       backend.gl_version.minor,
        e.EGL_CONTEXT_OPENGL_PROFILE_MASK, e.EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT,
        e.EGL_NONE,
    };
    const ctx = egl_lib.eglCreateContext(
        backend.state.egl_display,
        backend.state.egl_config,
        backend.state.context,
        &ctx_attr,
    );
    if (ctx == e.EGL_NO_CONTEXT) return error.ContextFailed;
    self.context = ctx;
    errdefer {
        _ = egl_lib.eglDestroyContext(backend.state.egl_display, ctx);
        self.context = null;
    }

    if (egl_lib.eglMakeCurrent(backend.state.egl_display, egl_surf, egl_surf, ctx) == 0) {
        return error.MakeCurrentFailed;
    }
    if (gl.gladLoadGLLoader(backend.getProcAddress()) == 0) return error.GlLoadFailed;
}

/// Releases GL/EGL and Wayland resources in reverse creation order and poisons `self`.
pub fn deinit(self: *WaylandWindow) void {
    const egl_lib = &backend.state.egl.?;
    const wl_egl_lib = &backend.state.wl_egl.?;
    const wl_lib = &backend.state.wl.?;

    if (backend.state.egl_display != e.EGL_NO_DISPLAY) {
        _ = egl_lib.eglMakeCurrent(backend.state.egl_display, e.EGL_NO_SURFACE, e.EGL_NO_SURFACE, e.EGL_NO_CONTEXT);
        if (self.context != e.EGL_NO_CONTEXT) {
            _ = egl_lib.eglDestroyContext(backend.state.egl_display, self.context);
        }
        if (self.egl_surface != e.EGL_NO_SURFACE) {
            _ = egl_lib.eglDestroySurface(backend.state.egl_display, self.egl_surface);
        }
    }
    if (self.egl_window) |egl_win| wl_egl_lib.wl_egl_window_destroy(egl_win);
    if (self.viewport) |vp| {
        _ = wl_lib.wl_proxy_marshal_flags(vp, proto.viewport.destroy, null, wl_lib.wl_proxy_get_version(vp), proto.marshal_flag_destroy);
    }
    if (self.fractional_scale) |fs| {
        _ = wl_lib.wl_proxy_marshal_flags(fs, proto.fractional_scale.destroy, null, wl_lib.wl_proxy_get_version(fs), proto.marshal_flag_destroy);
    }
    if (self.xdg_decoration) |deco| {
        _ = wl_lib.wl_proxy_marshal_flags(deco, proto.xdg_toplevel_decoration.destroy, null, wl_lib.wl_proxy_get_version(deco), proto.marshal_flag_destroy);
    }
    if (self.xdg_toplevel) |tl| {
        _ = wl_lib.wl_proxy_marshal_flags(tl, proto.xdg_toplevel.destroy, null, wl_lib.wl_proxy_get_version(tl), proto.marshal_flag_destroy);
    }
    if (self.xdg_surface) |xs| {
        _ = wl_lib.wl_proxy_marshal_flags(xs, proto.xdg_surface.destroy, null, wl_lib.wl_proxy_get_version(xs), proto.marshal_flag_destroy);
    }
    if (self.wl_surface) |s| {
        _ = wl_lib.wl_proxy_marshal_flags(s, proto.surface.destroy, null, wl_lib.wl_proxy_get_version(s), proto.marshal_flag_destroy);
    }
    if (backend.state.display) |dpy| _ = wl_lib.wl_display_flush(dpy);
    self.* = undefined;
}

/// Sets the window title on the xdg_toplevel.
pub fn setTitle(self: *WaylandWindow, title: [:0]const u8) void {
    const wl_lib = &backend.state.wl.?;
    const tl = self.xdg_toplevel orelse return;
    _ = wl_lib.wl_proxy_marshal_flags(
        tl,
        proto.xdg_toplevel.set_title,
        null,
        wl_lib.wl_proxy_get_version(tl),
        0,
        title.ptr,
    );
    if (backend.state.display) |dpy| _ = wl_lib.wl_display_flush(dpy);
}

/// Requests server-side decorations (`decorated == true`) or borderless client-side mode.
pub fn setDecorated(self: *WaylandWindow, decorated: bool) void {
    const wl_lib = &backend.state.wl.?;
    const deco = self.xdg_decoration orelse return;
    const mode = if (decorated)
        proto.xdg_toplevel_decoration.mode_server_side
    else
        proto.xdg_toplevel_decoration.mode_client_side;
    _ = wl_lib.wl_proxy_marshal_flags(
        deco,
        proto.xdg_toplevel_decoration.set_mode,
        null,
        wl_lib.wl_proxy_get_version(deco),
        0,
        mode,
    );
    if (self.wl_surface) |surf| {
        _ = wl_lib.wl_proxy_marshal_flags(surf, proto.surface.commit, null, wl_lib.wl_proxy_get_version(surf), 0);
    }
    if (backend.state.display) |dpy| _ = wl_lib.wl_display_flush(dpy);
}

/// Sets the minimum logical window size on the xdg_toplevel.
pub fn setMinimumSize(self: *WaylandWindow, width: c_int, height: c_int) void {
    const wl_lib = &backend.state.wl.?;
    const tl = self.xdg_toplevel orelse return;
    const min_w: i32 = @max(width, 0);
    const min_h: i32 = @max(height, 0);
    _ = wl_lib.wl_proxy_marshal_flags(
        tl,
        proto.xdg_toplevel.set_min_size,
        null,
        wl_lib.wl_proxy_get_version(tl),
        0,
        min_w,
        min_h,
    );
    if (backend.state.display) |dpy| _ = wl_lib.wl_display_flush(dpy);
}

/// Swaps the EGL back buffer onto the Wayland surface.
pub fn swapBuffers(self: *WaylandWindow) void {
    const egl_lib = &backend.state.egl.?;
    if (self.egl_surface != e.EGL_NO_SURFACE) {
        _ = egl_lib.eglSwapBuffers(backend.state.egl_display, self.egl_surface);
    }
}

/// Drawable pixel dimensions for the window.
pub fn framebufferSize(self: *const WaylandWindow, comptime T: type) Dimension(T) {
    const w_px = self.pixelWidth();
    const h_px = self.pixelHeight();
    return switch (@typeInfo(T)) {
        .float => .{
            .width = @floatFromInt(w_px),
            .height = @floatFromInt(h_px),
        },
        .int => .{
            .width = @intCast(w_px),
            .height = @intCast(h_px),
        },
        else => @compileError("Dimension type must be int or float"),
    };
}

/// Scale factor from logical pixels to device pixels.
pub fn contentScale(self: *const WaylandWindow) Dimension(f32) {
    return .{ .width = self.scale, .height = self.scale };
}

/// Wraps this pinned slot pointer as an opaque `Window` handle.
pub fn windowHandle(self: *WaylandWindow) Window {
    return .{ .impl = @ptrCast(self) };
}

pub fn pixelWidth(self: *const WaylandWindow) u32 {
    const scaled: f32 = @round(@as(f32, @floatFromInt(self.logical_width)) * self.scale);
    return @max(@as(u32, @intFromFloat(scaled)), 1);
}

pub fn pixelHeight(self: *const WaylandWindow) u32 {
    const scaled: f32 = @round(@as(f32, @floatFromInt(self.logical_height)) * self.scale);
    return @max(@as(u32, @intFromFloat(scaled)), 1);
}

fn onXdgSurfaceConfigure(data: ?*anyopaque, xdg_surf: ?*wl.Proxy, serial: u32) callconv(.c) void {
    const self: *WaylandWindow = @ptrCast(@alignCast(data.?));
    const wl_lib = &backend.state.wl.?;
    _ = wl_lib.wl_proxy_marshal_flags(
        xdg_surf,
        proto.xdg_surface.ack_configure,
        null,
        wl_lib.wl_proxy_get_version(xdg_surf),
        0,
        serial,
    );

    const prev_w = self.pixelWidth();
    const prev_h = self.pixelHeight();
    if (self.pending_width > 0 and self.pending_height > 0) {
        self.logical_width = self.pending_width;
        self.logical_height = self.pending_height;
    }
    const new_w = self.pixelWidth();
    const new_h = self.pixelHeight();
    self.configured = true;
    self.applyViewport();

    if (self.egl_window) |egl_win| {
        if (new_w != prev_w or new_h != prev_h) {
            backend.state.wl_egl.?.wl_egl_window_resize(egl_win, @intCast(new_w), @intCast(new_h), 0, 0);
            backend.pushEvent(.{ .framebuffer_size = .{
                .window = self.windowHandle(),
                .width = new_w,
                .height = new_h,
            } });
        }
    }

    if (self.pending_activated != self.focused) {
        self.focused = self.pending_activated;
        backend.pushEvent(.{ .focus = .{
            .window = self.windowHandle(),
            .focused = self.focused,
        } });
    }
}

fn onXdgToplevelConfigure(
    data: ?*anyopaque,
    _: ?*wl.Proxy,
    width: i32,
    height: i32,
    states: ?*w.wl_array,
) callconv(.c) void {
    const self: *WaylandWindow = @ptrCast(@alignCast(data.?));
    if (width > 0 and height > 0) {
        self.pending_width = @intCast(width);
        self.pending_height = @intCast(height);
    }
    var activated = false;
    if (states) |arr| {
        if (arr.data) |raw| {
            const count = @divTrunc(arr.size, @sizeOf(u32));
            const items: [*]const u32 = @ptrCast(@alignCast(raw));
            for (items[0..count]) |st| {
                if (st == proto.xdg_toplevel.state_activated) {
                    activated = true;
                    break;
                }
            }
        }
    }
    self.pending_activated = activated;
}

fn onXdgToplevelClose(data: ?*anyopaque, _: ?*wl.Proxy) callconv(.c) void {
    const self: *WaylandWindow = @ptrCast(@alignCast(data.?));
    self.should_close = true;
    backend.pushEvent(.{ .close = .{ .window = self.windowHandle() } });
}

fn onXdgToplevelConfigureBounds(_: ?*anyopaque, _: ?*wl.Proxy, _: i32, _: i32) callconv(.c) void {}

fn onXdgToplevelWmCapabilities(_: ?*anyopaque, _: ?*wl.Proxy, _: ?*w.wl_array) callconv(.c) void {}

fn onXdgDecorationConfigure(_: ?*anyopaque, _: ?*wl.Proxy, _: u32) callconv(.c) void {}

const xdg_surface_listener: proto.xdg_surface.Listener = .{
    .configure = onXdgSurfaceConfigure,
};

const xdg_toplevel_listener: proto.xdg_toplevel.Listener = .{
    .configure = onXdgToplevelConfigure,
    .close = onXdgToplevelClose,
    .configure_bounds = onXdgToplevelConfigureBounds,
    .wm_capabilities = onXdgToplevelWmCapabilities,
};

/// Converts a `wp_fractional_scale_v1` value (in 1/120ths) to a scale factor.
pub fn scaleFrom120(scale_120: u32) f32 {
    if (scale_120 == 0) return 1.0;
    return @as(f32, @floatFromInt(scale_120)) / 120.0;
}

fn applyViewport(self: *WaylandWindow) void {
    const vp = self.viewport orelse return;
    const wl_lib = if (backend.state.wl) |*wlib| wlib else return;
    _ = wl_lib.wl_proxy_marshal_flags(
        vp,
        proto.viewport.set_destination,
        null,
        wl_lib.wl_proxy_get_version(vp),
        0,
        @as(i32, @intCast(self.logical_width)),
        @as(i32, @intCast(self.logical_height)),
    );
}

fn onFractionalScale(data: ?*anyopaque, _: ?*wl.Proxy, scale_120: u32) callconv(.c) void {
    const self: *WaylandWindow = @ptrCast(@alignCast(data.?));
    if (scale_120 == 0) return;
    const new_scale = scaleFrom120(scale_120);
    if (new_scale == self.scale) return;

    const prev_w = self.pixelWidth();
    const prev_h = self.pixelHeight();
    self.scale = new_scale;
    const new_w = self.pixelWidth();
    const new_h = self.pixelHeight();

    self.applyViewport();
    if (self.egl_window) |egl_win| {
        if (new_w != prev_w or new_h != prev_h) {
            backend.state.wl_egl.?.wl_egl_window_resize(egl_win, @intCast(new_w), @intCast(new_h), 0, 0);
        }
    }
    backend.pushEvent(.{ .content_scale = .{
        .window = self.windowHandle(),
        .x = new_scale,
        .y = new_scale,
    } });
    if (new_w != prev_w or new_h != prev_h) {
        backend.pushEvent(.{ .framebuffer_size = .{
            .window = self.windowHandle(),
            .width = new_w,
            .height = new_h,
        } });
    }
}

const fractional_scale_listener: proto.fractional_scale.Listener = .{
    .preferred_scale = onFractionalScale,
};

const xdg_decoration_listener: proto.xdg_toplevel_decoration.Listener = .{
    .configure = onXdgDecorationConfigure,
};
