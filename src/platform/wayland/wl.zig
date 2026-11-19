//! Wayland client entry points and core protocol interfaces loaded at runtime.
//! The translated `wayland` module supplies exact C types; this file resolves
//! symbols by name only, so the binary links no Wayland library.

const std = @import("std");
const c = @import("wayland");

/// The runtime library loaded by `load`.
pub const soname = "libwayland-client.so.0";

/// Opaque Wayland core objects represented as `wl_proxy` at the C ABI.
pub const Display = c.wl_display;
pub const Proxy = c.wl_proxy;
pub const Interface = c.wl_interface;

/// Runtime Wayland client library. Every symbol is looked up once in `load`.
pub const Wayland = struct {
    lib: std.DynLib,

    wl_display_connect: *const fn ([*c]const u8) callconv(.c) ?*Display,
    wl_display_disconnect: *const fn (*Display) callconv(.c) void,
    wl_display_get_fd: *const fn (*Display) callconv(.c) c_int,
    wl_display_flush: *const fn (*Display) callconv(.c) c_int,
    wl_display_roundtrip: *const fn (*Display) callconv(.c) c_int,
    wl_display_dispatch_pending: *const fn (*Display) callconv(.c) c_int,
    wl_display_prepare_read: *const fn (*Display) callconv(.c) c_int,
    wl_display_cancel_read: *const fn (*Display) callconv(.c) void,
    wl_display_read_events: *const fn (*Display) callconv(.c) c_int,
    wl_display_get_error: *const fn (*Display) callconv(.c) c_int,

    wl_proxy_marshal_flags: *const fn (?*Proxy, u32, ?*const Interface, u32, u32, ...) callconv(.c) ?*Proxy,
    wl_proxy_add_listener: *const fn (?*Proxy, [*c]?*const fn () callconv(.c) void, ?*anyopaque) callconv(.c) c_int,
    wl_proxy_destroy: *const fn (?*Proxy) callconv(.c) void,
    wl_proxy_set_user_data: *const fn (?*Proxy, ?*anyopaque) callconv(.c) void,
    wl_proxy_get_user_data: *const fn (?*Proxy) callconv(.c) ?*anyopaque,
    wl_proxy_get_version: *const fn (?*Proxy) callconv(.c) u32,
    wl_proxy_get_id: *const fn (?*Proxy) callconv(.c) u32,

    registry_interface: *const Interface,
    compositor_interface: *const Interface,
    surface_interface: *const Interface,
    seat_interface: *const Interface,
    keyboard_interface: *const Interface,
    pointer_interface: *const Interface,
    output_interface: *const Interface,
    data_device_manager_interface: *const Interface,
    data_device_interface: *const Interface,
    data_source_interface: *const Interface,
    data_offer_interface: *const Interface,

    /// Closes the loaded library handle and invalidates the struct.
    pub fn deinit(self: *Wayland) void {
        self.lib.close();
        self.* = undefined;
    }
};

/// Loads libwayland-client.so.0 and resolves every core entry point and interface.
pub fn load() (std.DynLib.Error || error{SymbolNotFound})!Wayland {
    var lib = try std.DynLib.openZ(soname);
    errdefer lib.close();
    return .{
        .lib = lib,
        .wl_display_connect = try sym(*const fn ([*c]const u8) callconv(.c) ?*Display, &lib, "wl_display_connect"),
        .wl_display_disconnect = try sym(*const fn (*Display) callconv(.c) void, &lib, "wl_display_disconnect"),
        .wl_display_get_fd = try sym(*const fn (*Display) callconv(.c) c_int, &lib, "wl_display_get_fd"),
        .wl_display_flush = try sym(*const fn (*Display) callconv(.c) c_int, &lib, "wl_display_flush"),
        .wl_display_roundtrip = try sym(*const fn (*Display) callconv(.c) c_int, &lib, "wl_display_roundtrip"),
        .wl_display_dispatch_pending = try sym(*const fn (*Display) callconv(.c) c_int, &lib, "wl_display_dispatch_pending"),
        .wl_display_prepare_read = try sym(*const fn (*Display) callconv(.c) c_int, &lib, "wl_display_prepare_read"),
        .wl_display_cancel_read = try sym(*const fn (*Display) callconv(.c) void, &lib, "wl_display_cancel_read"),
        .wl_display_read_events = try sym(*const fn (*Display) callconv(.c) c_int, &lib, "wl_display_read_events"),
        .wl_display_get_error = try sym(*const fn (*Display) callconv(.c) c_int, &lib, "wl_display_get_error"),
        .wl_proxy_marshal_flags = try sym(*const fn (?*Proxy, u32, ?*const Interface, u32, u32, ...) callconv(.c) ?*Proxy, &lib, "wl_proxy_marshal_flags"),
        .wl_proxy_add_listener = try sym(*const fn (?*Proxy, [*c]?*const fn () callconv(.c) void, ?*anyopaque) callconv(.c) c_int, &lib, "wl_proxy_add_listener"),
        .wl_proxy_destroy = try sym(*const fn (?*Proxy) callconv(.c) void, &lib, "wl_proxy_destroy"),
        .wl_proxy_set_user_data = try sym(*const fn (?*Proxy, ?*anyopaque) callconv(.c) void, &lib, "wl_proxy_set_user_data"),
        .wl_proxy_get_user_data = try sym(*const fn (?*Proxy) callconv(.c) ?*anyopaque, &lib, "wl_proxy_get_user_data"),
        .wl_proxy_get_version = try sym(*const fn (?*Proxy) callconv(.c) u32, &lib, "wl_proxy_get_version"),
        .wl_proxy_get_id = try sym(*const fn (?*Proxy) callconv(.c) u32, &lib, "wl_proxy_get_id"),
        .registry_interface = try sym(*const Interface, &lib, "wl_registry_interface"),
        .compositor_interface = try sym(*const Interface, &lib, "wl_compositor_interface"),
        .surface_interface = try sym(*const Interface, &lib, "wl_surface_interface"),
        .seat_interface = try sym(*const Interface, &lib, "wl_seat_interface"),
        .keyboard_interface = try sym(*const Interface, &lib, "wl_keyboard_interface"),
        .pointer_interface = try sym(*const Interface, &lib, "wl_pointer_interface"),
        .output_interface = try sym(*const Interface, &lib, "wl_output_interface"),
        .data_device_manager_interface = try sym(*const Interface, &lib, "wl_data_device_manager_interface"),
        .data_device_interface = try sym(*const Interface, &lib, "wl_data_device_interface"),
        .data_source_interface = try sym(*const Interface, &lib, "wl_data_source_interface"),
        .data_offer_interface = try sym(*const Interface, &lib, "wl_data_offer_interface"),
    };
}

fn sym(comptime T: type, lib: *std.DynLib, name: [:0]const u8) error{SymbolNotFound}!T {
    return lib.lookup(T, name) orelse error.SymbolNotFound;
}
