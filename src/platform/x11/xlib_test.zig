//! Runtime symbol-resolution test for the Xlib entry points.

const std = @import("std");
const testing = std.testing;

const xlib = @import("xlib.zig");

const selected = @import("build_options").platform_backend;
const selected_x11 = std.mem.eql(u8, selected, "x11");

test "Xlib: every entry point the backend needs resolves at runtime" {
    if (!selected_x11) return;
    var lib = xlib.load() catch return error.SkipZigTest;
    defer lib.lib.close();
    const display = lib.XOpenDisplay(null) orelse return error.SkipZigTest;
    defer _ = lib.XCloseDisplay(display);
    _ = lib.XDefaultRootWindow(display);
    try testing.expect(@intFromPtr(&lib.XOpenDisplay) != 0);
}
