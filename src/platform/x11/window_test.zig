//! X11 window pointer and attention behaviour on a display. Uses its own
//! connection so it is independent of backend init/deinit order in the suite.

const std = @import("std");
const testing = std.testing;

const x = @import("x11");
const xlib = @import("xlib.zig");
const backend = @import("backend.zig");
const X11Window = @import("X11Window.zig");

test "X11 window: pointer shapes, visibility and urgency hint" {
    var lib = xlib.load() catch return error.SkipZigTest;
    defer lib.lib.close();
    const display = lib.XOpenDisplay(null) orelse return error.SkipZigTest;
    defer _ = lib.XCloseDisplay(display);

    backend.state.x11 = lib;
    backend.state.display = display;
    defer backend.state = .{};

    const root = lib.XDefaultRootWindow(display);
    const handle = lib.XCreateSimpleWindow(display, root, 0, 0, 32, 32, 0, 0, 0);
    defer _ = lib.XDestroyWindow(display, handle);
    _ = lib.XMapWindow(display, handle);
    _ = lib.XSync(display, 0);

    var window = X11Window{ .handle = handle };
    window.setPointerShape(.hand);
    try testing.expect(window.cursors[@intFromEnum(@as(@TypeOf(window.pointer_shape), .hand))] != 0);
    window.setPointerVisible(false);
    try testing.expect(window.hidden_cursor != 0);
    window.setPointerVisible(true);

    window.requestAttention();
    const hints = lib.XGetWMHints(display, handle) orelse return error.NoWMHints;
    defer _ = lib.XFree(@ptrCast(hints));
    try testing.expect((hints[0].flags & x.XUrgencyHint) != 0);
}
