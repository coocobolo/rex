//! Translates X11 events into Rex platform events. Called from the event
//! pump on the main thread; never blocks.

const std = @import("std");

const x = @import("x11");
const backend = @import("backend.zig");
const Event = @import("../Event.zig").Event;
const Window = @import("../Window.zig");
const key = @import("key.zig");

fn findWindow(handle: x.Window) ?Window {
    for (&backend.state.window_slots, 0..) |*slot, i| {
        if (backend.state.window_used[i] and slot.handle == handle)
            return .{ .impl = @ptrCast(slot) };
    }
    return null;
}

/// Drains every pending X11 event into the platform ring.
pub fn pump() void {
    const lib = &backend.state.x11.?;
    const display = backend.state.display.?;
    while (lib.XPending(display) > 0) {
        var event: x.XEvent = undefined;
        _ = lib.XNextEvent(display, &event);
        dispatch(&event);
    }
}

/// Delivers one X event into the platform ring.
pub fn dispatch(event: *x.XEvent) void {
    const lib = &backend.state.x11.?;
    const display = backend.state.display.?;
    switch (event.type) {
        x.KeyPress, x.KeyRelease => {
            const e = event.xkey;
            const window = findWindow(e.window) orelse return;
            const action: @import("../Event.zig").Action = if (event.type == x.KeyPress) .press else .release;
            const sym = lib.XKeycodeToKeysym(display, @intCast(e.keycode), 0);
            if (key.fromKeysym(sym)) |k| {
                backend.pushEvent(.{ .key = .{
                    .window = window,
                    .key = k,
                    .mods = key.modifiers(e.state),
                    .action = action,
                } });
            }
            if (event.type == x.KeyPress) {
                var buf: [8]u8 = undefined;
                var keysym: x.KeySym = 0;
                const n = lib.XLookupString(@ptrCast(&event.xkey), &buf, buf.len, &keysym, null);
                if (n > 0) {
                    // Decode as UTF-8 and emit one codepoint per event;
                    // pushing raw bytes would split multibyte characters.
                    if (std.unicode.Utf8View.init(buf[0..@intCast(n)])) |view| {
                        var it = view.iterator();
                        while (it.nextCodepoint()) |cp| {
                            backend.pushEvent(.{ .text = .{
                                .window = window,
                                .codepoint = cp,
                            } });
                        }
                    } else |_| {}
                }
            }
        },
        x.ButtonPress, x.ButtonRelease => {
            const e = event.xbutton;
            const window = findWindow(e.window) orelse return;
            const button: @import("../Event.zig").MouseButton = switch (e.button) {
                1 => .left,
                2 => .middle,
                3 => .right,
                else => return,
            };
            backend.pushEvent(.{ .mouse_button = .{
                .window = window,
                .button = button,
                .action = if (event.type == x.ButtonPress) .press else .release,
                .mods = key.modifiers(e.state),
            } });
        },
        x.MotionNotify => {
            const e = event.xmotion;
            const window = findWindow(e.window) orelse return;
            backend.pushEvent(.{ .cursor_pos = .{
                .window = window,
                .x = @floatFromInt(e.x),
                .y = @floatFromInt(e.y),
            } });
        },
        x.EnterNotify, x.LeaveNotify => {
            const e = event.xcrossing;
            const window = findWindow(e.window) orelse return;
            backend.pushEvent(.{ .cursor_enter = .{
                .window = window,
                .entered = event.type == x.EnterNotify,
            } });
        },
        x.FocusIn, x.FocusOut => {
            const e = event.xfocus;
            const window = findWindow(e.window) orelse return;
            backend.pushEvent(.{ .focus = .{
                .window = window,
                .focused = event.type == x.FocusIn,
            } });
        },
        x.ConfigureNotify => {
            const e = event.xconfigure;
            const window = findWindow(e.window) orelse return;
            backend.pushEvent(.{ .framebuffer_size = .{
                .window = window,
                .width = @intCast(e.width),
                .height = @intCast(e.height),
            } });
        },
        x.ClientMessage => {
            const e = event.xclient;
            const window = findWindow(e.window) orelse return;
            // A WM sends WM_PROTOCOLS as the message type and names
            // WM_DELETE_WINDOW in the first data word (ICCCM 4.2.8.1).
            if (e.message_type == backend.state.wm_protocols_atom and
                e.data.l[0] == @as(c_long, @intCast(backend.state.wm_delete_atom)))
                backend.pushEvent(.{ .close = .{ .window = window } });
        },
        x.SelectionRequest => @import("selection.zig").answerRequest(&event.xselectionrequest),
        else => {},
    }
}
