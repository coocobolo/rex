//! X11 CLIPBOARD and PRIMARY selection ownership. X selections are a request
//! protocol: the owner answers SelectionRequest events, and a reader converts
//! a selection then waits for SelectionNotify before reading the property.

const std = @import("std");

const x = @import("x11");
const backend = @import("backend.zig");
const events = @import("events.zig");

const system = std.posix.system;

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
    if (event.target == backend.state.utf8_atom) {
        if (textFor(event.selection, event.owner)) |slice| {
            if (property == 0) property = event.target;
            _ = lib.XChangeProperty(display, event.requestor, property, event.target, 8, x.PropModeReplace, @ptrCast(slice.ptr), @intCast(slice.len));
            accepted = true;
        }
    } else if (event.target == x.XA_STRING) {
        // ICCCM STRING is Latin-1, so only serve pure ASCII under that name;
        // non-ASCII text stays available as UTF8_STRING.
        if (textFor(event.selection, event.owner)) |slice| {
            var ascii = true;
            for (slice) |byte| {
                if (byte >= 0x80) {
                    ascii = false;
                    break;
                }
            }
            if (ascii) {
                if (property == 0) property = event.target;
                _ = lib.XChangeProperty(display, event.requestor, property, event.target, 8, x.PropModeReplace, @ptrCast(slice.ptr), @intCast(slice.len));
                accepted = true;
            }
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

    const x_fd = lib.XConnectionNumber(display);
    // Bounded wait without a clock: 25 polls of 10 ms each. Only idle polls
    // consume the budget, so a burst of unrelated events cannot starve the
    // SelectionNotify we are waiting for.
    var polls: usize = 0;
    while (true) {
        if (lib.XPending(display) == 0) {
            if (polls >= 25) return null;
            polls += 1;
            // Wait for the X socket instead of spinning the core.
            var fds = [_]system.pollfd{.{ .fd = x_fd, .events = system.POLL.IN, .revents = 0 }};
            _ = system.poll(&fds, 1, 10);
            continue;
        }
        var event: x.XEvent = undefined;
        _ = lib.XNextEvent(display, &event);
        if (event.type == x.SelectionNotify and event.xselection.requestor == window) {
            if (event.xselection.property == 0) return null;
            var actual_type: x.Atom = 0;
            var actual_format: c_int = 0;
            var nitems: c_ulong = 0;
            var bytes_after: c_ulong = 0;
            var data: [*c]u8 = null;
            // long_length counts 32-bit quantities; ask for the whole caller
            // buffer and refuse an oversized reply rather than truncate it.
            const longs: c_long = @intCast(@divTrunc(out.len + 3, 4));
            const rc = lib.XGetWindowProperty(display, window, prop, 0, longs, 1, x.AnyPropertyType, &actual_type, &actual_format, &nitems, &bytes_after, &data);
            defer if (data != null) {
                _ = lib.XFree(@ptrCast(data));
            };
            if (rc != 0 or data == null or bytes_after > 0 or actual_format != 8) return null;
            const len: usize = @intCast(nitems);
            if (len > out.len) return null;
            @memcpy(out[0..len], data[0..len]);
            return len;
        }
        events.dispatch(&event);
    }
    return null;
}

fn textFor(selection: x.Atom, owner: x.Window) ?[:0]const u8 {
    const sel = &backend.selection_state;
    if (selection == backend.state.clipboard_atom and sel.clipboard_owner == owner and sel.clipboard_len > 0)
        return sel.clipboard_text[0..sel.clipboard_len :0];
    if (selection == x.XA_PRIMARY and sel.primary_owner == owner and sel.primary_len > 0)
        return sel.primary_text[0..sel.primary_len :0];
    return null;
}
