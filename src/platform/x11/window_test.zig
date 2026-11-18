//! X11 window pointer and attention behaviour on a display. Uses its own
//! connection so it is independent of backend init/deinit order in the suite.

const std = @import("std");
const testing = std.testing;

const x = @import("x11");
const xlib = @import("xlib.zig");
const backend = @import("backend.zig");
const X11Window = @import("X11Window.zig");
const events = @import("events.zig");
const Event = @import("../Event.zig").Event;

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

test "X11 window: WM_DELETE_WINDOW produces a close event" {
    var lib = xlib.load() catch return error.SkipZigTest;
    defer lib.lib.close();
    const display = lib.XOpenDisplay(null) orelse return error.SkipZigTest;
    defer _ = lib.XCloseDisplay(display);

    backend.state = .{};
    defer backend.state = .{};
    backend.state.x11 = lib;
    backend.state.display = display;
    backend.state.wm_delete_atom = lib.XInternAtom(display, "WM_DELETE_WINDOW", 0);
    backend.state.wm_protocols_atom = lib.XInternAtom(display, "WM_PROTOCOLS", 0);

    const root = lib.XDefaultRootWindow(display);
    const handle = lib.XCreateSimpleWindow(display, root, 0, 0, 32, 32, 0, 0, 0);
    defer _ = lib.XDestroyWindow(display, handle);
    backend.state.window_slots[0].handle = handle;
    backend.state.window_used[0] = true;

    var message: x.XEvent = std.mem.zeroes(x.XEvent);
    message.type = x.ClientMessage;
    message.xclient.window = handle;
    message.xclient.message_type = backend.state.wm_protocols_atom;
    message.xclient.format = 32;
    message.xclient.data.l[0] = @intCast(backend.state.wm_delete_atom);
    events.dispatch(&message);

    var got_close = false;
    var event: Event = undefined;
    while (backend.nextEvent(&event)) {
        if (std.meta.activeTag(event) == .close) got_close = true;
    }
    try testing.expect(got_close);
}

test "X11 window: wheel buttons produce scroll events" {
    var lib = xlib.load() catch return error.SkipZigTest;
    defer lib.lib.close();
    const display = lib.XOpenDisplay(null) orelse return error.SkipZigTest;
    defer _ = lib.XCloseDisplay(display);

    backend.state = .{};
    defer backend.state = .{};
    backend.state.x11 = lib;
    backend.state.display = display;

    const root = lib.XDefaultRootWindow(display);
    const handle = lib.XCreateSimpleWindow(display, root, 0, 0, 32, 32, 0, 0, 0);
    defer _ = lib.XDestroyWindow(display, handle);
    backend.state.window_slots[0].handle = handle;
    backend.state.window_used[0] = true;

    const expected = [_]struct { button: u8, dy: f64 }{
        .{ .button = 4, .dy = 1 },
        .{ .button = 5, .dy = -1 },
    };
    for (expected) |wheel| {
        var press: x.XEvent = std.mem.zeroes(x.XEvent);
        press.type = x.ButtonPress;
        press.xbutton.window = handle;
        press.xbutton.button = wheel.button;
        events.dispatch(&press);

        var event: Event = undefined;
        var found = false;
        while (backend.nextEvent(&event)) {
            if (std.meta.activeTag(event) != .scroll) continue;
            try testing.expectEqual(wheel.dy, event.scroll.dy);
            try testing.expectEqual(@as(f64, 0), event.scroll.dx);
            found = true;
        }
        try testing.expect(found);
    }
}
