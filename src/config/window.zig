//! What the user sets for the window (`[window]`): platform, size,
//! background, unfocused appearance and mouse pointer auto-hide. Plain data
//! with no renderer dependency.

const std = @import("std");

/// The display server to start on (`[window] platform`).
pub const Platform = enum { auto, wayland, x11 };

/// Window titlebar and border decorations (`[window] decorations`).
pub const Decorations = enum { full, none };

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

/// Visual effects applied while the terminal window is unfocused (`[window] on_inactive`).
pub const InactiveEffect = enum {
    /// Switch the window background opacity to `inactive_background_opacity`.
    opacity,
    /// Blend the terminal content toward the background color by `inactive_dim_opacity`.
    dim,
    /// Blur the terminal content with `inactive_blur_radius`.
    blur,
};

pub const InactiveSet = std.EnumSet(InactiveEffect);

/// When to hide the mouse pointer over the terminal (`[window] mouse_auto_hide`).
pub const MouseAutoHide = enum {
    never,
    on_typing,
};
