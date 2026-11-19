//! What the user sets for the toasts, banners and dialogs drawn over the
//! terminal by the UI kit (`[toast]`, `[banner]`, `[modal]`, `[modal.blur]`
//! and `[alert_dialog]`). Plain data free of native dependencies, so anything
//! that reads the config (including fuzz targets and tool windows) can import
//! it without the renderer or terminal.

const std = @import("std");

const ScreenAnchor = @import("../kit/Tree.zig").ScreenAnchor;
const AlertPlacement = @import("../kit/alert.zig").Placement;
const DialogPosition = @import("../kit/dialog.zig").Position;
const ToastLayout = @import("../kit/toast.zig").Layout;

pub const Toast = struct {
    width: f32 = 356,
    duration_ms: u32 = 5000,
    position: ScreenAnchor = .bottom_right,
    layout: ToastLayout = .stacked,
    margin: u8 = 24,
    padding: u8 = 16,
    gap: u8 = 14,
    enabled: bool = true,
};

pub const Banner = struct {
    max_width: f32 = 560,
    placement: AlertPlacement = .floating,
    position: ScreenAnchor = .top_center,
    margin: u8 = 16,
    padding: u8 = 14,
    enabled: bool = true,
};

pub const Modal = struct {
    /// Opacity of the darkened backdrop behind the dialog, 0 to 1.
    backdrop_opacity: f32 = 180.0 / 255.0,
    position: DialogPosition = .center,
    on_outside_click: OutsideClick = .close,
    blur_radius: u8 = 12,
    margin: u8 = 16,
    padding: u8 = 24,
    gap: u8 = 16,
    blur: bool = false,

    /// `backdrop_opacity` as the alpha byte the renderer uses; out-of-range
    /// and non-finite values are clamped (non-finite counts as 0).
    pub fn backdropAlpha(self: Modal) u8 {
        const opacity = if (std.math.isFinite(self.backdrop_opacity)) std.math.clamp(self.backdrop_opacity, 0, 1) else 0;
        return @intFromFloat(@round(opacity * 255));
    }

    /// What a click outside an open dialog does.
    pub const OutsideClick = enum(u8) { close, ignore };
};

pub const AlertDialog = struct {
    width: f32 = 420,
    default_focus: DefaultFocus = .confirm,
    icon: Icon = .warning,

    pub const DefaultFocus = enum(u8) {
        confirm,
        cancel,
    };

    pub const Icon = enum(u8) {
        warning,
        info,
        @"error",
        none,
    };
};
