//! X11 CLIPBOARD and PRIMARY selection ownership. X selections are a request
//! protocol: the owner answers SelectionRequest events, and a reader converts
//! a selection then waits for SelectionNotify before reading the property.

const std = @import("std");

const x = @import("x11");
const backend = @import("backend.zig");
const events = @import("events.zig");

fn nowMs() i64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(ts.nsec, std.time.ns_per_ms);
}

/// Answers a SelectionRequest event for one of our windows.
pub fn answerRequest(event: *const x.XSelectionRequestEvent) void {
    const lib = &backend.state.x11.?;
    const display = backend.state.display.?;
    var reply: x.XSelectionEvent = undefined;
    reply.type = x.SelectionNotify;
    reply.serial = event.serial;
    reply.send_event = 1;
    reply.display = display;
    reply.requestor = event.requestor;
    reply.selection = event.selection;
    reply.target = event.target;
    reply.time = event.time;

    var accepted = false;
    var property = event.property;
    if (event.target == backend.state.utf8_atom or event.target == x.XA_STRING) {
        if (textFor(event.selection)) |slice| {
            if (property == 0) property = event.target;
            _ = lib.XChangeProperty(display, event.requestor, property, event.target, 8, x.PropModeReplace, @ptrCast(slice.ptr), @intCast(slice.len));
            accepted = true;
        }
    } else if (event.target == backend.state.targets_atom) {
        const targets = [_]x.Atom{ backend.state.utf8_atom, x.XA_STRING };
        if (property == 0) property = event.target;
        _ = lib.XChangeProperty(display, event.requestor, property, x.XA_ATOM, 32, x.PropModeReplace, @ptrCast(&targets), targets.len);
        accepted = true;
    }

    reply.property = if (accepted) property else 0;
    _ = lib.XSendEvent(display, event.requestor, 0, x.NoEventMask, @ptrCast(&reply));
    _ = lib.XFlush(display);
}

/// Reads a selection synchronously into `out`, returning the byte length.
/// A short timeout bounds the wait when no owner answers. Unrelated events
/// are dispatched into the normal ring by the event pump.
pub fn read(selection: x.Atom, out: []u8) ?usize {
    const lib = &backend.state.x11.?;
    const display = backend.state.display.?;
    const prop = backend.state.reply_atom;
    var window: x.Window = 0;
    var revert: c_int = 0;
    _ = lib.XGetInputFocus(display, &window, &revert);
    if (window == 0 or window == @as(x.Window, @intCast(x.PointerRoot))) return null;

    _ = lib.XConvertSelection(display, selection, backend.state.utf8_atom, prop, window, x.CurrentTime);
    _ = lib.XFlush(display);

    const deadline = nowMs() + 250;
    while (nowMs() < deadline) {
        if (lib.XPending(display) == 0) continue;
        var event: x.XEvent = undefined;
        _ = lib.XNextEvent(display, &event);
        if (event.type == x.SelectionNotify and event.xselection.requestor == window) {
            if (event.xselection.property == 0) return null;
            var actual_type: x.Atom = 0;
            var actual_format: c_int = 0;
            var nitems: c_ulong = 0;
            var bytes_after: c_ulong = 0;
            var data: [*c]u8 = null;
            const rc = lib.XGetWindowProperty(display, window, prop, 0, 64 * 1024, 1, x.AnyPropertyType, &actual_type, &actual_format, &nitems, &bytes_after, &data);
            if (rc != 0 or data == null) return null;
            defer _ = lib.XFree(@ptrCast(data));
            const len: usize = @intCast(nitems);
            if (len > out.len) return null;
            @memcpy(out[0..len], data[0..len]);
            return len;
        }
        events.dispatch(&event);
    }
    return null;
}

fn textFor(selection: x.Atom) ?[:0]const u8 {
    const slot = &backend.state.window_slots[0];
    if (!backend.state.window_used[0]) return null;
    if (selection == backend.state.clipboard_atom and slot.clipboard_len > 0)
        return slot.clipboard_text[0..slot.clipboard_len :0];
    if (selection == x.XA_PRIMARY and slot.primary_len > 0)
        return slot.primary_text[0..slot.primary_len :0];
    return null;
}
