//! Xlib entry points loaded at runtime. The translated `x11` module
//! supplies exact C signatures; this file resolves symbols by name only,
//! so the binary links no X11 library.

const std = @import("std");
const x = @import("x11");

/// The runtime library loaded by `load`.
pub const soname = "libX11.so.6";

/// Runtime Xlib library. Every pointer is looked up once in `load`.
pub const Xlib = struct {
    lib: std.DynLib,
    XOpenDisplay: *const fn ([*c]const u8) callconv(.c) ?*x.Display,
    XCloseDisplay: *const fn (?*x.Display) callconv(.c) c_int,
    XDefaultRootWindow: *const fn (?*x.Display) callconv(.c) x.Window,
    XCreateSimpleWindow: *const fn (?*x.Display, x.Window, c_int, c_int, c_uint, c_uint, c_uint, c_ulong, c_ulong) callconv(.c) x.Window,
    XDestroyWindow: *const fn (?*x.Display, x.Window) callconv(.c) c_int,
    XMapWindow: *const fn (?*x.Display, x.Window) callconv(.c) c_int,
    XSelectInput: *const fn (?*x.Display, x.Window, c_long) callconv(.c) c_int,
    XStoreName: *const fn (?*x.Display, x.Window, [*c]const u8) callconv(.c) c_int,
    XGetWindowAttributes: *const fn (?*x.Display, x.Window, [*c]x.XWindowAttributes) callconv(.c) c_int,
    XGetGeometry: *const fn (?*x.Display, x.Drawable, [*c]x.Window, [*c]c_int, [*c]c_int, [*c]c_uint, [*c]c_uint, [*c]c_uint, [*c]c_uint) callconv(.c) c_int,
    XFlush: *const fn (?*x.Display) callconv(.c) c_int,
    XSync: *const fn (?*x.Display, c_int) callconv(.c) c_int,
    XPending: *const fn (?*x.Display) callconv(.c) c_int,
    XNextEvent: *const fn (?*x.Display, [*c]x.XEvent) callconv(.c) c_int,
    XInternAtom: *const fn (?*x.Display, [*c]const u8, c_int) callconv(.c) x.Atom,
    XGetWindowProperty: *const fn (?*x.Display, x.Window, x.Atom, c_long, c_long, c_int, x.Atom, [*c]x.Atom, [*c]c_int, [*c]c_ulong, [*c]c_ulong, [*c][*c]u8) callconv(.c) c_int,
    XChangeProperty: *const fn (?*x.Display, x.Window, x.Atom, x.Atom, c_int, c_int, [*c]const u8, c_int) callconv(.c) c_int,
    XSetSelectionOwner: *const fn (?*x.Display, x.Atom, x.Window, x.Time) callconv(.c) c_int,
    XGetSelectionOwner: *const fn (?*x.Display, x.Atom) callconv(.c) x.Window,
    XConvertSelection: *const fn (?*x.Display, x.Atom, x.Atom, x.Atom, x.Window, x.Time) callconv(.c) c_int,
    XSendEvent: *const fn (?*x.Display, x.Window, c_int, c_long, [*c]x.XEvent) callconv(.c) c_int,
    XBell: *const fn (?*x.Display, c_int) callconv(.c) c_int,
    XLookupString: *const fn ([*c]x.XKeyEvent, [*c]u8, c_int, [*c]x.KeySym, [*c]x.XComposeStatus) callconv(.c) c_int,
    XKeysymToKeycode: *const fn (?*x.Display, x.KeySym) callconv(.c) x.KeyCode,
    XKeycodeToKeysym: *const fn (?*x.Display, x.KeyCode, c_int) callconv(.c) x.KeySym,
    XQueryKeymap: *const fn (?*x.Display, [*c]u8) callconv(.c) c_int,
    XGetInputFocus: *const fn (?*x.Display, [*c]x.Window, [*c]c_int) callconv(.c) c_int,
    XSetInputFocus: *const fn (?*x.Display, x.Window, c_int, x.Time) callconv(.c) c_int,
    XResizeWindow: *const fn (?*x.Display, x.Window, c_uint, c_uint) callconv(.c) c_int,
    XSetWMNormalHints: *const fn (?*x.Display, x.Window, [*c]x.XSizeHints) callconv(.c) void,
    XCreateFontCursor: *const fn (?*x.Display, c_uint) callconv(.c) x.Cursor,
    XDefineCursor: *const fn (?*x.Display, x.Window, x.Cursor) callconv(.c) c_int,
    XFreeCursor: *const fn (?*x.Display, x.Cursor) callconv(.c) c_int,
    XGetErrorText: *const fn (?*x.Display, c_int, [*c]u8, c_int) callconv(.c) c_int,
};

/// Loads libX11.so.6 and resolves every entry point the backend uses.
pub fn load() !Xlib {
    var lib = try std.DynLib.openZ("libX11.so.6");
    errdefer lib.close();
    return .{
        .lib = lib,
        .XOpenDisplay = try sym(*const fn ([*c]const u8) callconv(.c) ?*x.Display, &lib, "XOpenDisplay"),
        .XCloseDisplay = try sym(*const fn (?*x.Display) callconv(.c) c_int, &lib, "XCloseDisplay"),
        .XDefaultRootWindow = try sym(*const fn (?*x.Display) callconv(.c) x.Window, &lib, "XDefaultRootWindow"),
        .XCreateSimpleWindow = try sym(*const fn (?*x.Display, x.Window, c_int, c_int, c_uint, c_uint, c_uint, c_ulong, c_ulong) callconv(.c) x.Window, &lib, "XCreateSimpleWindow"),
        .XDestroyWindow = try sym(*const fn (?*x.Display, x.Window) callconv(.c) c_int, &lib, "XDestroyWindow"),
        .XMapWindow = try sym(*const fn (?*x.Display, x.Window) callconv(.c) c_int, &lib, "XMapWindow"),
        .XSelectInput = try sym(*const fn (?*x.Display, x.Window, c_long) callconv(.c) c_int, &lib, "XSelectInput"),
        .XStoreName = try sym(*const fn (?*x.Display, x.Window, [*c]const u8) callconv(.c) c_int, &lib, "XStoreName"),
        .XGetWindowAttributes = try sym(*const fn (?*x.Display, x.Window, [*c]x.XWindowAttributes) callconv(.c) c_int, &lib, "XGetWindowAttributes"),
        .XGetGeometry = try sym(*const fn (?*x.Display, x.Drawable, [*c]x.Window, [*c]c_int, [*c]c_int, [*c]c_uint, [*c]c_uint, [*c]c_uint, [*c]c_uint) callconv(.c) c_int, &lib, "XGetGeometry"),
        .XFlush = try sym(*const fn (?*x.Display) callconv(.c) c_int, &lib, "XFlush"),
        .XSync = try sym(*const fn (?*x.Display, c_int) callconv(.c) c_int, &lib, "XSync"),
        .XPending = try sym(*const fn (?*x.Display) callconv(.c) c_int, &lib, "XPending"),
        .XNextEvent = try sym(*const fn (?*x.Display, [*c]x.XEvent) callconv(.c) c_int, &lib, "XNextEvent"),
        .XInternAtom = try sym(*const fn (?*x.Display, [*c]const u8, c_int) callconv(.c) x.Atom, &lib, "XInternAtom"),
        .XGetWindowProperty = try sym(*const fn (?*x.Display, x.Window, x.Atom, c_long, c_long, c_int, x.Atom, [*c]x.Atom, [*c]c_int, [*c]c_ulong, [*c]c_ulong, [*c][*c]u8) callconv(.c) c_int, &lib, "XGetWindowProperty"),
        .XChangeProperty = try sym(*const fn (?*x.Display, x.Window, x.Atom, x.Atom, c_int, c_int, [*c]const u8, c_int) callconv(.c) c_int, &lib, "XChangeProperty"),
        .XSetSelectionOwner = try sym(*const fn (?*x.Display, x.Atom, x.Window, x.Time) callconv(.c) c_int, &lib, "XSetSelectionOwner"),
        .XGetSelectionOwner = try sym(*const fn (?*x.Display, x.Atom) callconv(.c) x.Window, &lib, "XGetSelectionOwner"),
        .XConvertSelection = try sym(*const fn (?*x.Display, x.Atom, x.Atom, x.Atom, x.Window, x.Time) callconv(.c) c_int, &lib, "XConvertSelection"),
        .XSendEvent = try sym(*const fn (?*x.Display, x.Window, c_int, c_long, [*c]x.XEvent) callconv(.c) c_int, &lib, "XSendEvent"),
        .XBell = try sym(*const fn (?*x.Display, c_int) callconv(.c) c_int, &lib, "XBell"),
        .XLookupString = try sym(*const fn ([*c]x.XKeyEvent, [*c]u8, c_int, [*c]x.KeySym, [*c]x.XComposeStatus) callconv(.c) c_int, &lib, "XLookupString"),
        .XKeysymToKeycode = try sym(*const fn (?*x.Display, x.KeySym) callconv(.c) x.KeyCode, &lib, "XKeysymToKeycode"),
        .XKeycodeToKeysym = try sym(*const fn (?*x.Display, x.KeyCode, c_int) callconv(.c) x.KeySym, &lib, "XKeycodeToKeysym"),
        .XQueryKeymap = try sym(*const fn (?*x.Display, [*c]u8) callconv(.c) c_int, &lib, "XQueryKeymap"),
        .XGetInputFocus = try sym(*const fn (?*x.Display, [*c]x.Window, [*c]c_int) callconv(.c) c_int, &lib, "XGetInputFocus"),
        .XSetInputFocus = try sym(*const fn (?*x.Display, x.Window, c_int, x.Time) callconv(.c) c_int, &lib, "XSetInputFocus"),
        .XResizeWindow = try sym(*const fn (?*x.Display, x.Window, c_uint, c_uint) callconv(.c) c_int, &lib, "XResizeWindow"),
        .XSetWMNormalHints = try sym(*const fn (?*x.Display, x.Window, [*c]x.XSizeHints) callconv(.c) void, &lib, "XSetWMNormalHints"),
        .XCreateFontCursor = try sym(*const fn (?*x.Display, c_uint) callconv(.c) x.Cursor, &lib, "XCreateFontCursor"),
        .XDefineCursor = try sym(*const fn (?*x.Display, x.Window, x.Cursor) callconv(.c) c_int, &lib, "XDefineCursor"),
        .XFreeCursor = try sym(*const fn (?*x.Display, x.Cursor) callconv(.c) c_int, &lib, "XFreeCursor"),
        .XGetErrorText = try sym(*const fn (?*x.Display, c_int, [*c]u8, c_int) callconv(.c) c_int, &lib, "XGetErrorText"),
    };
}

fn sym(comptime T: type, lib: *std.DynLib, name: [:0]const u8) !T {
    return lib.lookup(T, name) orelse error.SymbolNotFound;
}
