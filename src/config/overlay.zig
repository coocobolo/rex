//! What the user sets for the toasts, banners and dialogs drawn over the
//! terminal by the UI kit (`[toast]`, `[banner]`, `[modal]` and
//! `[modal.blur]`). Plain data that imports nothing but std, so anything
//! that reads the config can import it without the UI code.

const std = @import("std");

pub const Toast = struct {
    enabled: bool = true,
    duration_ms: u32 = 5000,
};

pub const Banner = struct {
    enabled: bool = true,
};

pub const Modal = struct {
    /// Opacity of the darkened backdrop behind the dialog, 0 to 1.
    backdrop_opacity: f32 = 180.0 / 255.0,
    blur: bool = false,
    blur_radius: u8 = 12,
    on_outside_click: OutsideClick = .close,
    default_focus: DefaultFocus = .confirm,

    /// `backdrop_opacity` as the alpha byte the renderer uses; out-of-range
    /// and non-finite values are clamped (non-finite counts as 0).
    pub fn backdropAlpha(self: Modal) u8 {
        const opacity = if (std.math.isFinite(self.backdrop_opacity)) std.math.clamp(self.backdrop_opacity, 0, 1) else 0;
        return @intFromFloat(@round(opacity * 255));
    }

    pub const DefaultFocus = enum {
        confirm,
        cancel,
    };

    /// What a click outside an open dialog does.
    pub const OutsideClick = enum { close, ignore };
};
