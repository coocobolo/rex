//! What the user sets for the toasts, banners and dialogs drawn over the
//! terminal by `src/ui/` (`[toast]`, `[banner]`, `[modal]` and the icons
//! and buttons in them). Plain data that imports nothing but std, so
//! anything that reads the config can import it without the UI code. The
//! UI's `Option` types are these.

const std = @import("std");

pub const Toast = struct {
    enabled: bool = true,
    position: Position = .top_right,
    icon_style: Icon.IconStyle = .auto,
    duration_ms: u32 = 5000,
    min_cols: u16 = 32,
    max_cols: u16 = 48,
    margin_cols: u16 = 2,
    margin_rows: u16 = 1,
    dismiss_str: ?[]const u8 = null,
    action_prompt: []const u8 = ">",
    action_margin: u16 = 1,

    pub const Position = enum {
        top_right,
        top_center,
        bottom_right,
    };
};

pub const Banner = struct {
    enabled: bool = true,
    placement: Placement = .floating,
    position: Position = .top_center,
    min_cols: u16 = 36,
    max_cols: u16 = 72,
    margin_cols: u16 = 2,
    margin_rows: u16 = 1,
    dismiss_str: []const u8 = "✕",

    /// Whether the banner floats over the terminal or is docked to its edge.
    pub const Placement = enum {
        floating,
        docked,
    };

    pub const Position = enum {
        top_center,
        top_right,
        top_left,
    };
};

pub const Modal = struct {
    /// Dialog width, in terminal columns.
    cols: u16 = 46,
    /// Opacity of the darkened backdrop behind the dialog, 0 to 1.
    backdrop_opacity: f32 = 180.0 / 255.0,
    blur: bool = false,
    blur_radius: u8 = 12,
    on_outside_click: OutsideClick = .close,
    icon_style: Icon.IconStyle = .auto,
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

pub const Button = struct {
    focus_indicator: []const u8 = ">",
    icon_style: Icon.IconStyle = .auto,
    corner_radius: f32 = 4.0,
    border_width: f32 = 1.0,
    focus_border_width: f32 = 1.5,
};

pub const Icon = struct {
    style: IconStyle = .auto,
    custom: Glyphs = .{},

    /// Icon rendering mode for terminal UI elements.
    pub const IconStyle = enum {
        auto,
        nerd_font,
        unicode,
        ascii,
    };

    pub const Glyphs = struct {
        lock: ?[]const u8 = null,
        unlock: ?[]const u8 = null,
        coffee: ?[]const u8 = null,
        warning: ?[]const u8 = null,
        error_icon: ?[]const u8 = null,
        success: ?[]const u8 = null,
        info: ?[]const u8 = null,
        pause: ?[]const u8 = null,
        play: ?[]const u8 = null,
        check: ?[]const u8 = null,
        clock: ?[]const u8 = null,
        settings: ?[]const u8 = null,
        eye: ?[]const u8 = null,
        walk: ?[]const u8 = null,
        water: ?[]const u8 = null,
        posture: ?[]const u8 = null,
    };
};
