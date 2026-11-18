//! X11 selection ownership: a request for a selection we own is answered by
//! our own SelectionRequest handler and read back through XConvertSelection.

const std = @import("std");
const testing = std.testing;

const x = @import("x11");
const xlib = @import("xlib.zig");
const backend = @import("backend.zig");
const selection = @import("selection.zig");

test "X11 selection: reading a selection we own returns its text" {
    var lib = xlib.load() catch return error.SkipZigTest;
    defer lib.lib.close();
    const display = lib.XOpenDisplay(null) orelse return error.SkipZigTest;
    defer _ = lib.XCloseDisplay(display);

    // Install the minimal backend state the selection code reads. No other
    // test touches this global, and it is restored on exit.
    backend.state.x11 = lib;
    backend.state.display = display;
    backend.state.clipboard_atom = lib.XInternAtom(display, "CLIPBOARD", 0);
    backend.state.utf8_atom = lib.XInternAtom(display, "UTF8_STRING", 0);
    backend.state.targets_atom = lib.XInternAtom(display, "TARGETS", 0);
    backend.state.reply_atom = lib.XInternAtom(display, "REX_SELECTION_TEST", 0);
    defer backend.state = .{};

    const root = lib.XDefaultRootWindow(display);
    const window = lib.XCreateSimpleWindow(display, root, 0, 0, 32, 32, 0, 0, 0);
    defer _ = lib.XDestroyWindow(display, window);
    _ = lib.XMapWindow(display, window);
    _ = lib.XSync(display, 0);

    // The owner slot holds the text and the owning window's handle.
    const text = "shared text";
    const slot = &backend.state.window_slots[0];
    slot.handle = window;
    @memcpy(slot.clipboard_text[0..text.len], text);
    slot.clipboard_text[text.len] = 0;
    slot.clipboard_len = text.len;
    backend.state.window_used[0] = true;
    _ = lib.XSetSelectionOwner(display, backend.state.clipboard_atom, window, x.CurrentTime);
    _ = lib.XSetInputFocus(display, window, x.RevertToPointerRoot, x.CurrentTime);
    _ = lib.XSync(display, 0);

    var out: [4096]u8 = undefined;
    const n = selection.read(backend.state.clipboard_atom, &out) orelse
        return testing.expect(false);
    try testing.expectEqualSlices(u8, text, out[0..n]);
}
