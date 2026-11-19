const std = @import("std");
const testing = std.testing;

const e = @import("egl");
const w = @import("wayland");
const egl = @import("../egl.zig");
const wl = @import("wl.zig");
const wl_egl = @import("wl_egl.zig");

const selected = @import("build_options").platform_backend;
const selected_wayland = std.mem.eql(u8, selected, "wayland");

const wl_display_get_registry_opcode: u32 = 1;
const wl_registry_bind_opcode: u32 = 0;
const wl_compositor_create_surface_opcode: u32 = 0;

const RegistryState = struct {
    lib: *const wl.Wayland,
    compositor: ?*wl.Proxy = null,
};

const RegistryListener = extern struct {
    global: *const fn (?*anyopaque, ?*wl.Proxy, u32, [*c]const u8, u32) callconv(.c) void,
    global_remove: *const fn (?*anyopaque, ?*wl.Proxy, u32) callconv(.c) void,
};

fn onGlobal(
    data: ?*anyopaque,
    registry: ?*wl.Proxy,
    name: u32,
    interface: [*c]const u8,
    version: u32,
) callconv(.c) void {
    const state: *RegistryState = @ptrCast(@alignCast(data.?));
    if (std.mem.eql(u8, std.mem.span(interface), "wl_compositor")) {
        const bind_version: u32 = @min(version, 4);
        state.compositor = state.lib.wl_proxy_marshal_flags(
            registry,
            wl_registry_bind_opcode,
            state.lib.compositor_interface,
            bind_version,
            0,
            name,
            state.lib.compositor_interface.name,
            bind_version,
            @as(?*anyopaque, null),
        );
    }
}

fn onGlobalRemove(_: ?*anyopaque, _: ?*wl.Proxy, _: u32) callconv(.c) void {}

const registry_listener: RegistryListener = .{
    .global = onGlobal,
    .global_remove = onGlobalRemove,
};

test "EGL: a core OpenGL 3.3 context can be created on a Wayland surface" {
    if (!selected_wayland) return;

    var wl_lib = wl.load() catch return error.SkipZigTest;
    defer wl_lib.deinit();
    var wl_egl_lib = wl_egl.load() catch return error.SkipZigTest;
    defer wl_egl_lib.deinit();
    var egl_lib = egl.load() catch return error.SkipZigTest;
    defer egl_lib.lib.close();

    const display = wl_lib.wl_display_connect(null) orelse return error.SkipZigTest;
    defer wl_lib.wl_display_disconnect(display);

    const registry = wl_lib.wl_proxy_marshal_flags(
        @ptrCast(display),
        wl_display_get_registry_opcode,
        wl_lib.registry_interface,
        wl_lib.wl_proxy_get_version(@ptrCast(display)),
        0,
        @as(?*anyopaque, null),
    ) orelse return error.TestUnexpectedResult;
    defer wl_lib.wl_proxy_destroy(registry);

    var reg_state: RegistryState = .{ .lib = &wl_lib };
    try testing.expectEqual(
        @as(c_int, 0),
        wl_lib.wl_proxy_add_listener(registry, @ptrCast(@constCast(&registry_listener)), &reg_state),
    );
    try testing.expect(wl_lib.wl_display_roundtrip(display) >= 0);

    const compositor = reg_state.compositor orelse return error.SkipZigTest;
    defer wl_lib.wl_proxy_destroy(compositor);

    const surface = wl_lib.wl_proxy_marshal_flags(
        compositor,
        wl_compositor_create_surface_opcode,
        wl_lib.surface_interface,
        wl_lib.wl_proxy_get_version(compositor),
        0,
        @as(?*anyopaque, null),
    ) orelse return error.TestUnexpectedResult;
    defer wl_lib.wl_proxy_destroy(surface);

    const egl_win = wl_egl_lib.wl_egl_window_create(@ptrCast(surface), 64, 64) orelse
        return error.TestUnexpectedResult;
    defer wl_egl_lib.wl_egl_window_destroy(egl_win);

    const edpy = egl_lib.getPlatformDisplay(e.EGL_PLATFORM_WAYLAND_KHR, display, null);
    try testing.expect(edpy != e.EGL_NO_DISPLAY);
    defer _ = egl_lib.eglTerminate(edpy);

    var major: e.EGLint = 0;
    var minor: e.EGLint = 0;
    try testing.expect(egl_lib.eglInitialize(edpy, &major, &minor) != 0);
    try testing.expect(egl_lib.eglBindAPI(e.EGL_OPENGL_API) != 0);

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
    try testing.expect(egl_lib.eglChooseConfig(edpy, &cfg_attr, &config, 1, &count) != 0);
    try testing.expect(count > 0);

    const native_win: e.EGLNativeWindowType = @intFromPtr(@as(*w.wl_egl_window, egl_win));
    const surf = egl_lib.eglCreateWindowSurface(edpy, config, native_win, null);
    try testing.expect(surf != e.EGL_NO_SURFACE);
    defer _ = egl_lib.eglDestroySurface(edpy, surf);

    const ctx_attr = [_]e.EGLint{
        e.EGL_CONTEXT_MAJOR_VERSION,       3,
        e.EGL_CONTEXT_MINOR_VERSION,       3,
        e.EGL_CONTEXT_OPENGL_PROFILE_MASK, e.EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT,
        e.EGL_NONE,
    };
    const ctx = egl_lib.eglCreateContext(edpy, config, null, &ctx_attr);
    try testing.expect(ctx != e.EGL_NO_CONTEXT);
    defer _ = egl_lib.eglDestroyContext(edpy, ctx);
    try testing.expect(egl_lib.eglMakeCurrent(edpy, surf, surf, ctx) != 0);
    defer _ = egl_lib.eglMakeCurrent(edpy, e.EGL_NO_SURFACE, e.EGL_NO_SURFACE, e.EGL_NO_CONTEXT);

    const gl = @import("../../renderer/gl.zig");
    const get_integerv: *const fn (gl.GLenum, [*c]gl.GLint) callconv(.c) void =
        @ptrCast(@alignCast(egl_lib.eglGetProcAddress("glGetIntegerv").?));
    var profile: gl.GLint = 0;
    get_integerv(0x9126, &profile);
    try testing.expect((profile & 0x1) != 0);
}
