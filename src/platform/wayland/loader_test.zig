const std = @import("std");
const testing = std.testing;

const c_xkb = @import("xkbcommon");
const wl = @import("wl.zig");
const wl_egl = @import("wl_egl.zig");
const xkb = @import("xkb.zig");

const selected = @import("build_options").platform_backend;
const selected_wayland = std.mem.eql(u8, selected, "wayland");

test "Wayland: libwayland-client, libwayland-egl, and libxkbcommon resolve at runtime" {
    if (!selected_wayland) return;

    var wl_lib = wl.load() catch return error.SkipZigTest;
    defer wl_lib.deinit();
    try testing.expect(@intFromPtr(wl_lib.wl_display_connect) != 0);
    try testing.expect(@intFromPtr(wl_lib.compositor_interface) != 0);

    var egl_win = wl_egl.load() catch return error.SkipZigTest;
    defer egl_win.deinit();
    try testing.expect(@intFromPtr(egl_win.wl_egl_window_create) != 0);

    var xkb_lib = xkb.load() catch return error.SkipZigTest;
    defer xkb_lib.deinit();
    try testing.expect(@intFromPtr(xkb_lib.xkb_keymap_key_get_syms_by_level) != 0);
    try testing.expect(@intFromPtr(xkb_lib.xkb_state_key_get_layout) != 0);
    const ctx = xkb_lib.xkb_context_new(c_xkb.XKB_CONTEXT_NO_FLAGS) orelse return error.SkipZigTest;
    defer xkb_lib.xkb_context_unref(ctx);
}
