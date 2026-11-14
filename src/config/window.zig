//! What the user sets for the window (`[window]`): platform, size and
//! background. Plain data that imports nothing else, so anything that
//! reads the config can import it without the renderer.

/// The display server to start on (`[window] platform`).
pub const Platform = enum { auto, wayland, x11 };

/// A size in logical pixels.
pub const Size = struct {
    width: u16,
    height: u16,
};

pub const Background = struct {
    /// Global background opacity multiplier (0.0-1.0).
    alpha: f32 = 1.0,

    pub const default: Background = .{};
};
