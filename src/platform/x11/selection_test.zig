//! X11 selection ownership: a request for a selection we own is answered by
//! our own SelectionRequest handler and read back through XConvertSelection.

const std = @import("std");
const testing = std.testing;

const x = @import("x11");
const xlib = @import("xlib.zig");
const backend = @import("backend.zig");
const selection = @import("selection.zig");

const selected = @import("build_options").platform_backend;
const selected_x11 = std.mem.eql(u8, selected, "x11");

test "X11 selection: reading a selection we own returns its text" {
    if (!selected_x11) return;
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

    // The display-global selection state holds the text and owning window handle.
    const text = "shared text";
    const sel = &backend.selection_state;
    defer sel.clear();
    @memcpy(sel.clipboard_text[0..text.len], text);
    sel.clipboard_text[text.len] = 0;
    sel.clipboard_len = text.len;
    sel.clipboard_owner = window;
    _ = lib.XSetSelectionOwner(display, backend.state.clipboard_atom, window, x.CurrentTime);
    _ = lib.XSetInputFocus(display, window, x.RevertToPointerRoot, x.CurrentTime);
    _ = lib.XSync(display, 0);

    var out: [4096]u8 = undefined;
    const n = selection.read(backend.state.clipboard_atom, &out) orelse
        return testing.expect(false);
    try testing.expectEqualSlices(u8, text, out[0..n]);
}
