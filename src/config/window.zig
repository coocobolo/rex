//! What the user sets for the window (`[window]`, `[surface]` and the
//! surface sections): platform, size, background and surfaces. Plain data
//! that imports nothing but std, so anything that reads the config can
//! import it without the renderer. The renderer's `Option` types are these.

const std = @import("std");

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

pub const Surface = struct {
    corner_radius: f32 = 8.0,
    border_width: f32 = 1.0,
    border_shape: BorderShape = .rounded,
    border_style: BorderStyle = .semantic,

    pub fn effectiveRadius(self: Surface) f32 {
        return switch (self.border_shape) {
            .rounded => self.corner_radius,
            .sharp => 0.0,
        };
    }

    pub const BorderShape = enum {
        rounded,
        sharp,
    };

    pub const BorderStyle = enum {
        semantic,
        subtle,
    };
};
