//! Native-free platform interface. The selected backend is owned by this
//! module; no backend type appears in the application's view of it.

const backend = @import("glfw/backend.zig");

/// The events the application receives from the backend.
pub const Event = @import("Event.zig");
/// The opaque window handle and its operations.
pub const Window = @import("Window.zig");
/// The platform process, with one instance per process.
pub const Platform = @import("Platform.zig");
/// The window systems the backend can start on.
pub const System = backend.System;
/// The selected system and whether the user forced it.
pub const Choice = backend.Choice;
/// The standard cursor shapes a window can show.
pub const PointerShape = Window.PointerShape;
/// The GL version the renderer targets, shared with the GL tests.
pub const gl_version = backend.gl_version;
/// Readies the hidden GL context used by tests, skipping without a display.
pub const testGlContext = backend.testGlContext;

test {
    _ = @import("event_test.zig");
}
