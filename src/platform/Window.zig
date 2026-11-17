//! The window handle the platform interface hands to the application. No
//! backend type appears here: `impl` is an opaque pointer that the selected
//! backend casts to its own window struct. Every method is a thin delegation
//! to that backend.

const Window = @This();

const backend = @import("glfw/backend.zig");
const Dimension = @import("../renderer/dimension.zig").Dimension;

/// The pointer shapes a window can show.
pub const PointerShape = enum(u8) {
    arrow,
    hand,
    text,
};

impl: *anyopaque,

/// The size and title requested for a new window.
pub const Options = struct {
    width: u16,
    height: u16,
    title: [:0]const u8,
};

/// Destroys the window and releases its backend slot.
pub fn deinit(self: Window) void {
    backend.destroyWindow(self);
}

/// Associates an application pointer with the window.
pub fn setContext(self: Window, ptr: ?*anyopaque) void {
    backend.windowSetContext(self, ptr);
}

/// The application pointer set with setContext, or null.
pub fn getContext(self: Window) ?*anyopaque {
    return backend.windowGetContext(self);
}

/// Sets the title shown by the desktop.
pub fn setTitle(self: Window, title: [:0]const u8) void {
    backend.windowSetTitle(self, title);
}

/// Whether the window system has asked the window to close.
pub fn shouldClose(self: Window) bool {
    return backend.windowShouldClose(self);
}

/// Marks the window to close on the next event loop pass.
pub fn setShouldClose(self: Window, set: bool) void {
    backend.windowSetShouldClose(self, set);
}

/// Presents the rendered frame.
pub fn swapBuffers(self: Window) void {
    backend.windowSwapBuffers(self);
}

/// The drawable size in pixels, converted to T.
pub fn framebufferSize(self: Window, comptime T: type) Dimension(T) {
    return backend.windowFramebufferSize(self, T);
}

/// The scale from logical to device pixels.
pub fn contentScale(self: Window) Dimension(f32) {
    return backend.windowContentScale(self);
}

/// Whether the window currently has input focus.
pub fn focused(self: Window) bool {
    return backend.windowFocused(self);
}

/// Sets the smallest size the user may resize to.
pub fn setMinimumSize(self: Window, width: c_int, height: c_int) void {
    backend.windowSetMinimumSize(self, width, height);
}

/// Shows the given standard cursor while the pointer is over the window.
pub fn setPointerShape(self: Window, shape: PointerShape) void {
    backend.windowSetPointerShape(self, shape);
}

/// Shows or hides the pointer over the window.
pub fn setPointerVisible(self: Window, visible: bool) void {
    backend.windowSetPointerVisible(self, visible);
}

/// Sets the CLIPBOARD selection to the given text.
pub fn setClipboard(self: Window, text: [:0]const u8) void {
    backend.windowSetClipboard(self, text);
}

/// The CLIPBOARD selection, or null when it holds no text. The pointer is
/// owned by the backend and stays valid until the next clipboard call.
pub fn getClipboard(self: Window) ?[:0]const u8 {
    return backend.windowGetClipboard(self);
}

/// The PRIMARY selection where the platform provides one.
pub fn getPrimarySelection(self: Window) ?[:0]const u8 {
    return backend.windowGetPrimarySelection(self);
}

/// Sets PRIMARY where supported, returning false when it is unavailable.
pub fn setPrimarySelection(self: Window, text: [:0]const u8) bool {
    return backend.windowSetPrimarySelection(self, text);
}

/// Asks the desktop to draw attention to the window.
pub fn requestAttention(self: Window) void {
    backend.windowRequestAttention(self);
}

/// Rings the audible bell where available, otherwise asks for attention.
/// Volume is clamped to zero through one.
pub fn ringBell(self: Window, volume: f32) void {
    backend.windowRingBell(self, volume);
}
