//! What the user sets for the toasts, banners and dialogs drawn over the
//! terminal by the UI kit (`[toast]`, `[banner]`, `[modal]`, `[modal.blur]`
//! and `[alert_dialog]`). Plain data free of native dependencies, so anything
//! that reads the config (including fuzz targets and tool windows) can import
//! it without the renderer or terminal.

const std = @import("std");

const ScreenAnchor = @import("../kit/Tree.zig").ScreenAnchor;
const AsciiCanvas = @import("../kit/AsciiCanvas.zig");
const AlertPlacement = @import("../kit/alert.zig").Placement;
const DialogPosition = @import("../kit/dialog.zig").Position;
const toast = @import("../kit/toast.zig");
const wellbeing_widget = @import("../kit/wellbeing_widget.zig");

pub const Toast = struct {
    width: f32 = toast.width,
    scale_step: f32 = toast.scale_step,
    duration_ms: u32 = 5000,
    position: ScreenAnchor = .bottom_right,
    layout: toast.Layout = .stacked,
    margin: u8 = toast.margin,
    padding: u8 = toast.padding,
    gap: u8 = toast.gap,
    peek: u8 = toast.peek,
    /// How far below its place a toast starts and ends, in pixels.
    rise_distance: f32 = 16,
    /// Time constant of the glide to a new place, in milliseconds.
    glide_ms: u32 = 40,
    enabled: bool = true,
};

pub const Banner = struct {
    max_width: f32 = 560,
    /// How far a banner slides in from the edge, in pixels.
    slide_distance: f32 = 12,
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

pub const WellbeingWidget = struct {
    width: f32 = wellbeing_widget.default_width,
    height: f32 = wellbeing_widget.default_height,
    anchor: ScreenAnchor = .bottom_right,
    progress_style: wellbeing_widget.ProgressStyle = .auto,
    default_visible: bool = false,
    tooltip: bool = true,

    pub fn toKitOption(self: WellbeingWidget) wellbeing_widget.Option {
        return .{
            .default_width = self.width,
            .default_height = self.height,
            .anchor = self.anchor,
            .progress_style = self.progress_style,
            .tooltip = self.tooltip,
        };
    }
};

/// Fullscreen ASCII animation overlay shown during wellbeing breaks and
/// reminders (`[wellbeing.ascii]`).
pub const WellbeingAscii = struct {
    /// Opt-out switch: when false, locking reminders use the classic card.
    enabled: bool = true,
    /// Built-in procedural scene or external multi-frame ASCII file.
    scene: AsciiCanvas.Scene = .spin_3d,
    /// Optional path to a UTF-8 frame-delimited ASCII file when `scene = file`.
    file: ?[*:0]const u8 = null,
    /// Animation playback cadence in frames per second (1..30).
    fps: u8 = 20,
    /// Cell geometry used to lay out the ASCII grid (`square` or `terminal`).
    cell_aspect: AsciiCanvas.CellAspect = .square,
    /// Whether all wellbeing reminders or only locking breaks open the overlay.
    trigger: AsciiCanvas.Trigger = .all,
};
