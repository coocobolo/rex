const std = @import("std");
const testing = std.testing;

const e = @import("egl");
const x = @import("x11");
const xlib = @import("xlib.zig");
const egl = @import("egl.zig");

const selected = @import("build_options").platform_backend;
const selected_x11 = std.mem.eql(u8, selected, "x11");

test "EGL: a core OpenGL 3.3 context can be created on an X11 window" {
    if (!selected_x11) return;
    var x11 = xlib.load() catch return error.SkipZigTest;
    defer x11.lib.close();
    var egl_lib = egl.load() catch return error.SkipZigTest;
    defer egl_lib.lib.close();

    const display = x11.XOpenDisplay(null) orelse return error.SkipZigTest;
    defer _ = x11.XCloseDisplay(display);
    const root = x11.XDefaultRootWindow(display);
    const window = x11.XCreateSimpleWindow(display, root, 0, 0, 64, 64, 0, 0, 0);
    defer _ = x11.XDestroyWindow(display, window);
    _ = x11.XMapWindow(display, window);
    _ = x11.XSync(display, 0);

    const edpy = egl_lib.getPlatformDisplay(e.EGL_PLATFORM_X11_EXT, display, null);
    try testing.expect(edpy != e.EGL_NO_DISPLAY);
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

    const surf = egl_lib.eglCreateWindowSurface(edpy, config, @intCast(window), null);
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

    // A core profile must report the core bit in the GL context mask.
    const gl = @import("../../renderer/gl.zig");
    const get_integerv: *const fn (gl.GLenum, [*c]gl.GLint) callconv(.c) void =
        @ptrCast(@alignCast(egl_lib.eglGetProcAddress("glGetIntegerv").?));
    var profile: gl.GLint = 0;
    get_integerv(0x9126, &profile);
    try testing.expect((profile & 0x1) != 0);
}
