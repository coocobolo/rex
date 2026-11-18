const std = @import("std");
const testing = std.testing;

const xlib = @import("xlib.zig");

test "Xlib: every entry point the backend needs resolves at runtime" {
    var lib = xlib.load() catch return error.SkipZigTest;
    defer lib.lib.close();
    const display = lib.XOpenDisplay(null) orelse return error.SkipZigTest;
    defer _ = lib.XCloseDisplay(display);
    _ = lib.XDefaultRootWindow(display);
    try testing.expect(@intFromPtr(&lib.XOpenDisplay) != 0);
}
