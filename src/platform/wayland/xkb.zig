//! xkbcommon entry points loaded at runtime for Wayland keyboard translation.
//! The translated `xkbcommon` module supplies exact C types; this file resolves
//! symbols by name only, so the binary links no xkbcommon library.

const std = @import("std");
const c = @import("xkbcommon");

/// The runtime library loaded by `load`.
pub const soname = "libxkbcommon.so.0";

/// Runtime xkbcommon library. Every pointer is looked up once in `load`.
pub const Xkb = struct {
    lib: std.DynLib,
    xkb_context_new: *const fn (c.xkb_context_flags) callconv(.c) ?*c.xkb_context,
    xkb_context_unref: *const fn (?*c.xkb_context) callconv(.c) void,
    xkb_keymap_new_from_string: *const fn (?*c.xkb_context, [*c]const u8, c.xkb_keymap_format, c.xkb_keymap_compile_flags) callconv(.c) ?*c.xkb_keymap,
    xkb_keymap_unref: *const fn (?*c.xkb_keymap) callconv(.c) void,
    xkb_keymap_key_repeats: *const fn (?*c.xkb_keymap, c.xkb_keycode_t) callconv(.c) c_int,
    xkb_state_new: *const fn (?*c.xkb_keymap) callconv(.c) ?*c.xkb_state,
    xkb_state_unref: *const fn (?*c.xkb_state) callconv(.c) void,
    xkb_state_update_mask: *const fn (?*c.xkb_state, c.xkb_mod_mask_t, c.xkb_mod_mask_t, c.xkb_mod_mask_t, c.xkb_layout_index_t, c.xkb_layout_index_t, c.xkb_layout_index_t) callconv(.c) c.xkb_state_component,
    xkb_state_key_get_one_sym: *const fn (?*c.xkb_state, c.xkb_keycode_t) callconv(.c) c.xkb_keysym_t,
    xkb_state_key_get_utf32: *const fn (?*c.xkb_state, c.xkb_keycode_t) callconv(.c) u32,
    xkb_state_key_get_utf8: *const fn (?*c.xkb_state, c.xkb_keycode_t, [*c]u8, usize) callconv(.c) c_int,
    xkb_state_mod_name_is_active: *const fn (?*c.xkb_state, [*c]const u8, c.xkb_state_component) callconv(.c) c_int,

    /// Closes the loaded library handle and invalidates the struct.
    pub fn deinit(self: *Xkb) void {
        self.lib.close();
        self.* = undefined;
    }
};

/// Loads libxkbcommon.so.0 and resolves every entry point the backend uses.
pub fn load() (std.DynLib.Error || error{SymbolNotFound})!Xkb {
    var lib = try std.DynLib.openZ(soname);
    errdefer lib.close();
    return .{
        .lib = lib,
        .xkb_context_new = try sym(*const fn (c.xkb_context_flags) callconv(.c) ?*c.xkb_context, &lib, "xkb_context_new"),
        .xkb_context_unref = try sym(*const fn (?*c.xkb_context) callconv(.c) void, &lib, "xkb_context_unref"),
        .xkb_keymap_new_from_string = try sym(*const fn (?*c.xkb_context, [*c]const u8, c.xkb_keymap_format, c.xkb_keymap_compile_flags) callconv(.c) ?*c.xkb_keymap, &lib, "xkb_keymap_new_from_string"),
        .xkb_keymap_unref = try sym(*const fn (?*c.xkb_keymap) callconv(.c) void, &lib, "xkb_keymap_unref"),
        .xkb_keymap_key_repeats = try sym(*const fn (?*c.xkb_keymap, c.xkb_keycode_t) callconv(.c) c_int, &lib, "xkb_keymap_key_repeats"),
        .xkb_state_new = try sym(*const fn (?*c.xkb_keymap) callconv(.c) ?*c.xkb_state, &lib, "xkb_state_new"),
        .xkb_state_unref = try sym(*const fn (?*c.xkb_state) callconv(.c) void, &lib, "xkb_state_unref"),
        .xkb_state_update_mask = try sym(*const fn (?*c.xkb_state, c.xkb_mod_mask_t, c.xkb_mod_mask_t, c.xkb_mod_mask_t, c.xkb_layout_index_t, c.xkb_layout_index_t, c.xkb_layout_index_t) callconv(.c) c.xkb_state_component, &lib, "xkb_state_update_mask"),
        .xkb_state_key_get_one_sym = try sym(*const fn (?*c.xkb_state, c.xkb_keycode_t) callconv(.c) c.xkb_keysym_t, &lib, "xkb_state_key_get_one_sym"),
        .xkb_state_key_get_utf32 = try sym(*const fn (?*c.xkb_state, c.xkb_keycode_t) callconv(.c) u32, &lib, "xkb_state_key_get_utf32"),
        .xkb_state_key_get_utf8 = try sym(*const fn (?*c.xkb_state, c.xkb_keycode_t, [*c]u8, usize) callconv(.c) c_int, &lib, "xkb_state_key_get_utf8"),
        .xkb_state_mod_name_is_active = try sym(*const fn (?*c.xkb_state, [*c]const u8, c.xkb_state_component) callconv(.c) c_int, &lib, "xkb_state_mod_name_is_active"),
    };
}

fn sym(comptime T: type, lib: *std.DynLib, name: [:0]const u8) error{SymbolNotFound}!T {
    return lib.lookup(T, name) orelse error.SymbolNotFound;
}
