//! The platform process. One per process; GLFW's event wait is global, so
//! windows share the event ring and the wakeup function. No backend type
//! appears in the application's view of it.

const Platform = @This();

const backend = @import("backend.zig").selected;
const window_config = @import("../config/window.zig");
const input_key = @import("../input/key.zig");
const PlatformEvent = @import("Event.zig").Event;
const Window = @import("Window.zig");
const Choice = backend.Choice;

choice: Choice,

/// Initialises the backend for a choice the caller has already resolved.
/// Session detection belongs to the caller; use choose for that decision.
pub fn init(choice: Choice) !Platform {
    try backend.init(choice);
    return .{ .choice = choice };
}

/// Releases the backend and invalidates the value.
pub fn deinit(self: *Platform) void {
    backend.deinit();
    self.* = undefined;
}

/// The window system an automatic or explicit choice selects.
pub fn choose(requested: window_config.Platform, wayland_session: bool) Choice {
    return backend.choose(requested, wayland_session);
}

/// Creates a window with the given size and title.
pub fn createWindow(_: *Platform, options: Window.Options) !Window {
    return backend.createWindow(.{
        .width = options.width,
        .height = options.height,
        .title = options.title,
    });
}

/// Processes pending window events without blocking.
pub fn pollEvents(self: Platform) void {
    _ = self;
    backend.pollEvents();
}

/// Waits for window events, or for the given timeout in milliseconds.
pub fn waitEvents(self: Platform, timeout_ms: ?f64) void {
    _ = self;
    backend.waitEvents(timeout_ms);
}

/// Signature required by the driver's wakeup callback (`?*const fn () void`).
pub fn postWakeup() void {
    backend.postWakeup();
}

/// The monotonic clock in seconds.
pub fn now(self: Platform) f64 {
    _ = self;
    return backend.now();
}

/// The primary monitor refresh rate, or null when unknown.
pub fn primaryRefreshHz(self: Platform) ?u32 {
    _ = self;
    return backend.primaryRefreshHz();
}

/// Whether the given key is held on the given window.
pub fn isKeyDown(self: Platform, window: Window, key: input_key.Key) bool {
    _ = self;
    return backend.isKeyDown(window, key);
}

/// Copies the oldest queued event into `out`, returning false when empty.
pub fn nextEvent(self: Platform, out: *PlatformEvent) bool {
    _ = self;
    return backend.nextEvent(out);
}

/// The number of dropped events since the last call, then resets it.
pub fn takeDropped(self: Platform) u32 {
    _ = self;
    return backend.takeDropped();
}

/// Readies the shared GL test context, skipping when there is no display.
pub fn testGlContext(self: Platform) !void {
    _ = self;
    return backend.testGlContext();
}
