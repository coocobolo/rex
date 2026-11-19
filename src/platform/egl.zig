//! EGL entry points loaded at runtime. The translated `egl` module
//! supplies exact C signatures; this file resolves symbols by name only,
//! so the binary links no EGL library.

const std = @import("std");
const e = @import("egl");

/// The runtime library loaded by `load`.
pub const soname = "libEGL.so.1";

/// Runtime EGL library. Every pointer is looked up once in `load`.
pub const Egl = struct {
    lib: std.DynLib,
    eglTerminate: *const fn (dpy: e.EGLDisplay) callconv(.c) e.EGLBoolean,
    eglGetProcAddress: *const fn (procname: [*c]const u8) callconv(.c) e.__eglMustCastToProperFunctionPointerType,
    /// EGL 1.5 core `eglGetPlatformDisplay`, or the EXT fallback on older EGL.
    getPlatformDisplay: *const fn (e.EGLenum, ?*anyopaque, [*c]const e.EGLint) callconv(.c) e.EGLDisplay,
    eglInitialize: *const fn (dpy: e.EGLDisplay, major: [*c]e.EGLint, minor: [*c]e.EGLint) callconv(.c) e.EGLBoolean,
    eglChooseConfig: *const fn (dpy: e.EGLDisplay, attrib_list: [*c]const e.EGLint, configs: [*c]e.EGLConfig, config_size: e.EGLint, num_config: [*c]e.EGLint) callconv(.c) e.EGLBoolean,
    eglCreateWindowSurface: *const fn (dpy: e.EGLDisplay, config: e.EGLConfig, win: e.EGLNativeWindowType, attrib_list: [*c]const e.EGLint) callconv(.c) e.EGLSurface,
    eglCreateContext: *const fn (dpy: e.EGLDisplay, config: e.EGLConfig, share_context: e.EGLContext, attrib_list: [*c]const e.EGLint) callconv(.c) e.EGLContext,
    eglMakeCurrent: *const fn (dpy: e.EGLDisplay, draw: e.EGLSurface, read: e.EGLSurface, ctx: e.EGLContext) callconv(.c) e.EGLBoolean,
    eglSwapBuffers: *const fn (dpy: e.EGLDisplay, surface: e.EGLSurface) callconv(.c) e.EGLBoolean,
    eglBindAPI: *const fn (api: e.EGLenum) callconv(.c) e.EGLBoolean,
    eglQueryString: *const fn (dpy: e.EGLDisplay, name: e.EGLint) callconv(.c) [*c]const u8,
    eglGetConfigAttrib: *const fn (dpy: e.EGLDisplay, config: e.EGLConfig, attribute: e.EGLint, value: [*c]e.EGLint) callconv(.c) e.EGLBoolean,
    eglDestroySurface: *const fn (dpy: e.EGLDisplay, surface: e.EGLSurface) callconv(.c) e.EGLBoolean,
    eglDestroyContext: *const fn (dpy: e.EGLDisplay, ctx: e.EGLContext) callconv(.c) e.EGLBoolean,
    eglCreatePbufferSurface: *const fn (dpy: e.EGLDisplay, config: e.EGLConfig, attrib_list: [*c]const e.EGLint) callconv(.c) e.EGLSurface,
};

/// Loads libEGL.so.1 and resolves every entry point the backend uses.
pub fn load() (std.DynLib.Error || error{SymbolNotFound})!Egl {
    var lib = try std.DynLib.openZ(soname);
    errdefer lib.close();
    return .{
        .lib = lib,
        .eglTerminate = try sym(*const fn (dpy: e.EGLDisplay) callconv(.c) e.EGLBoolean, &lib, "eglTerminate"),
        .eglGetProcAddress = try sym(*const fn (procname: [*c]const u8) callconv(.c) e.__eglMustCastToProperFunctionPointerType, &lib, "eglGetProcAddress"),
        .getPlatformDisplay = try loadPlatformDisplay(&lib),
        .eglInitialize = try sym(*const fn (dpy: e.EGLDisplay, major: [*c]e.EGLint, minor: [*c]e.EGLint) callconv(.c) e.EGLBoolean, &lib, "eglInitialize"),
        .eglChooseConfig = try sym(*const fn (dpy: e.EGLDisplay, attrib_list: [*c]const e.EGLint, configs: [*c]e.EGLConfig, config_size: e.EGLint, num_config: [*c]e.EGLint) callconv(.c) e.EGLBoolean, &lib, "eglChooseConfig"),
        .eglCreateWindowSurface = try sym(*const fn (dpy: e.EGLDisplay, config: e.EGLConfig, win: e.EGLNativeWindowType, attrib_list: [*c]const e.EGLint) callconv(.c) e.EGLSurface, &lib, "eglCreateWindowSurface"),
        .eglCreateContext = try sym(*const fn (dpy: e.EGLDisplay, config: e.EGLConfig, share_context: e.EGLContext, attrib_list: [*c]const e.EGLint) callconv(.c) e.EGLContext, &lib, "eglCreateContext"),
        .eglMakeCurrent = try sym(*const fn (dpy: e.EGLDisplay, draw: e.EGLSurface, read: e.EGLSurface, ctx: e.EGLContext) callconv(.c) e.EGLBoolean, &lib, "eglMakeCurrent"),
        .eglSwapBuffers = try sym(*const fn (dpy: e.EGLDisplay, surface: e.EGLSurface) callconv(.c) e.EGLBoolean, &lib, "eglSwapBuffers"),
        .eglBindAPI = try sym(*const fn (api: e.EGLenum) callconv(.c) e.EGLBoolean, &lib, "eglBindAPI"),
        .eglQueryString = try sym(*const fn (dpy: e.EGLDisplay, name: e.EGLint) callconv(.c) [*c]const u8, &lib, "eglQueryString"),
        .eglGetConfigAttrib = try sym(*const fn (dpy: e.EGLDisplay, config: e.EGLConfig, attribute: e.EGLint, value: [*c]e.EGLint) callconv(.c) e.EGLBoolean, &lib, "eglGetConfigAttrib"),
        .eglDestroySurface = try sym(*const fn (dpy: e.EGLDisplay, surface: e.EGLSurface) callconv(.c) e.EGLBoolean, &lib, "eglDestroySurface"),
        .eglDestroyContext = try sym(*const fn (dpy: e.EGLDisplay, ctx: e.EGLContext) callconv(.c) e.EGLBoolean, &lib, "eglDestroyContext"),
        .eglCreatePbufferSurface = try sym(*const fn (dpy: e.EGLDisplay, config: e.EGLConfig, attrib_list: [*c]const e.EGLint) callconv(.c) e.EGLSurface, &lib, "eglCreatePbufferSurface"),
    };
}

fn sym(comptime T: type, lib: *std.DynLib, name: [:0]const u8) !T {
    return lib.lookup(T, name) orelse error.SymbolNotFound;
}

fn loadPlatformDisplay(lib: *std.DynLib) !*const fn (e.EGLenum, ?*anyopaque, [*c]const e.EGLint) callconv(.c) e.EGLDisplay {
    const T = *const fn (e.EGLenum, ?*anyopaque, [*c]const e.EGLint) callconv(.c) e.EGLDisplay;
    if (lib.lookup(T, "eglGetPlatformDisplay")) |f| return f;
    return lib.lookup(T, "eglGetPlatformDisplayEXT") orelse error.SymbolNotFound;
}
