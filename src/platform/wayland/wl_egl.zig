//! Wayland EGL window entry points loaded at runtime. The translated `wayland`
//! module supplies exact C types; this file resolves symbols by name only, so
//! the binary links no Wayland EGL library.

const std = @import("std");
const c = @import("wayland");

/// The runtime library loaded by `load`.
pub const soname = "libwayland-egl.so.1";

/// Runtime Wayland EGL library. Every pointer is looked up once in `load`.
pub const WaylandEgl = struct {
    lib: std.DynLib,
    wl_egl_window_create: *const fn (?*c.wl_surface, c_int, c_int) callconv(.c) ?*c.wl_egl_window,
    wl_egl_window_destroy: *const fn (?*c.wl_egl_window) callconv(.c) void,
    wl_egl_window_resize: *const fn (?*c.wl_egl_window, c_int, c_int, c_int, c_int) callconv(.c) void,
    wl_egl_window_get_attached_size: *const fn (?*c.wl_egl_window, [*c]c_int, [*c]c_int) callconv(.c) void,

    /// Closes the loaded library handle and invalidates the struct.
    pub fn deinit(self: *WaylandEgl) void {
        self.lib.close();
        self.* = undefined;
    }
};

/// Loads libwayland-egl.so.1 and resolves every entry point the backend uses.
pub fn load() (std.DynLib.Error || error{SymbolNotFound})!WaylandEgl {
    var lib = try std.DynLib.openZ(soname);
    errdefer lib.close();
    return .{
        .lib = lib,
        .wl_egl_window_create = try sym(*const fn (?*c.wl_surface, c_int, c_int) callconv(.c) ?*c.wl_egl_window, &lib, "wl_egl_window_create"),
        .wl_egl_window_destroy = try sym(*const fn (?*c.wl_egl_window) callconv(.c) void, &lib, "wl_egl_window_destroy"),
        .wl_egl_window_resize = try sym(*const fn (?*c.wl_egl_window, c_int, c_int, c_int, c_int) callconv(.c) void, &lib, "wl_egl_window_resize"),
        .wl_egl_window_get_attached_size = try sym(*const fn (?*c.wl_egl_window, [*c]c_int, [*c]c_int) callconv(.c) void, &lib, "wl_egl_window_get_attached_size"),
    };
}

fn sym(comptime T: type, lib: *std.DynLib, name: [:0]const u8) error{SymbolNotFound}!T {
    return lib.lookup(T, name) orelse error.SymbolNotFound;
}
