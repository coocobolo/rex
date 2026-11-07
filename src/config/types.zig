//! Configuration types, section enumerations, and diagnostic reporting for Rex.
//!
//! Defines the structured representations of all user-configurable options across
//! typography, themes, windows, card shaders, toasts, modals, wellbeing trackers,
//! and keybindings.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Theme = @import("../color/Theme.zig");
const Tokens = @import("../color/Tokens.zig").Tokens;
const Card = @import("../renderer/Card.zig");
const Background = @import("../renderer/Background.zig");
const Toast = @import("../ui/Toast.zig");
const Banner = @import("../ui/Banner.zig");
const Icon = @import("../ui/Icon.zig");
const Modal = @import("../ui/Modal.zig");
const Button = @import("../ui/Button.zig");
const wellbeing = @import("../builtin/wellbeing/root.zig");
const input = @import("../input.zig");
const Binding = input.Binding;
const Key = input.Key;
const Modifiers = input.Modifiers;
const Action = input.Action;

/// Maximum number of diagnostic messages collected during a single parse pass.
pub const max_diagnostics = 32;

/// Diagnostic severity levels for configuration validation.
pub const Severity = enum {
    warning,
    err,
};

/// A single diagnostic record indicating the file location and description of an issue.
pub const Diagnostic = struct {
    severity: Severity,
    line: usize,
    col: usize,
    msg: [128]u8 = undefined,
    msg_len: usize = 0,

    pub fn message(self: *const Diagnostic) []const u8 {
        return self.msg[0..self.msg_len];
    }
};

/// Zero-allocation fixed-capacity diagnostic collector for configuration parsing.
pub const Diagnostics = struct {
    items: [max_diagnostics]Diagnostic = undefined,
    count: usize = 0,

    pub fn add(self: *Diagnostics, severity: Severity, line: usize, col: usize, comptime fmt: []const u8, args: anytype) void {
        if (self.count >= max_diagnostics) return;
        var diag = &self.items[self.count];
        diag.severity = severity;
        diag.line = line;
        diag.col = col;
        const written = std.fmt.bufPrint(&diag.msg, fmt, args) catch "";
        diag.msg_len = written.len;
        self.count += 1;
    }

    pub fn warn(self: *Diagnostics, line: usize, col: usize, comptime fmt: []const u8, args: anytype) void {
        self.add(.warning, line, col, fmt, args);
    }

    pub fn err(self: *Diagnostics, line: usize, col: usize, comptime fmt: []const u8, args: anytype) void {
        self.add(.err, line, col, fmt, args);
    }

    pub fn hasErrors(self: Diagnostics) bool {
        for (self.items[0..self.count]) |d| {
            if (d.severity == .err) return true;
        }
        return false;
    }
};

/// Supported section headers within declarative configuration files.
pub const Section = enum {
    root,
    window,
    font,
    card,
    toast,
    banner,
    modal,
    wellbeing,
    scroll,
    keybinds,

    pub fn fromString(str: []const u8) ?Section {
        if (std.ascii.eqlIgnoreCase(str, "window")) return .window;
        if (std.ascii.eqlIgnoreCase(str, "font")) return .font;
        if (std.ascii.eqlIgnoreCase(str, "card")) return .card;
        if (std.ascii.eqlIgnoreCase(str, "toast")) return .toast;
        if (std.ascii.eqlIgnoreCase(str, "banner")) return .banner;
        if (std.ascii.eqlIgnoreCase(str, "modal")) return .modal;
        if (std.ascii.eqlIgnoreCase(str, "wellbeing")) return .wellbeing;
        if (std.ascii.eqlIgnoreCase(str, "scroll")) return .scroll;
        if (std.ascii.eqlIgnoreCase(str, "keybinds") or std.ascii.eqlIgnoreCase(str, "bindings") or std.ascii.eqlIgnoreCase(str, "keys")) return .keybinds;
        return null;
    }
};

/// Maximum dynamic keybindings allowed in custom user configurations.
pub const max_dynamic_keybindings = 128;

/// Configurable values parsed from user and system configuration files.
pub const FileConfig = struct {
    theme: ?Theme = null,
    tokens: ?Tokens = null,

    font_family: ?[128]u8 = null,
    font_family_len: usize = 0,
    font_size: ?f32 = null,
    font_weight: ?u16 = null,
    font_weight_bold: ?u16 = null,
    /// Step of increase_font_size and decrease_font_size, in logical pixels.
    font_size_step: ?u32 = null,
    /// Smallest and largest size those keys reach, in logical pixels.
    font_size_min: ?u32 = null,
    font_size_max: ?u32 = null,

    window_background_alpha: ?f32 = null,
    window_background_blur: ?u32 = null,
    window_confirm_quit: ?bool = null,
    window_dim_alpha: ?f32 = null,
    window_bell: ?enum { on, off } = null,
    window_platform: ?enum { auto, wayland, x11 } = null,
    window_bell_volume: ?u8 = null,
    window_title: ?[128]u8 = null,
    window_title_len: usize = 0,
    window_width: ?u16 = null,
    window_height: ?u16 = null,

    card_corner_radius: ?f32 = null,
    card_border_width: ?f32 = null,
    card_border_shape: ?Card.BorderShape = null,
    card_border_style: ?Card.BorderStyle = null,

    toast_enabled: ?bool = null,
    toast_position: ?Toast.Position = null,
    toast_border_style: ?Toast.BorderStyle = null,
    toast_duration_ms: ?u32 = null,
    toast_min_width: ?u16 = null,
    toast_max_width: ?u16 = null,
    toast_margin_cols: ?u16 = null,
    toast_margin_rows: ?u16 = null,

    banner_enabled: ?bool = null,
    banner_style: ?Banner.Style = null,
    banner_position: ?Banner.Position = null,
    banner_border_style: ?Toast.BorderStyle = null,
    banner_corner_radius: ?f32 = null,
    banner_border_width: ?f32 = null,
    banner_min_width: ?u16 = null,
    banner_max_width: ?u16 = null,
    banner_margin_cols: ?u16 = null,
    banner_margin_rows: ?u16 = null,

    modal_width: ?u16 = null,
    modal_dim_alpha: ?u8 = null,
    modal_blur: ?bool = null,
    modal_blur_radius: ?u8 = null,
    modal_close_on_outside_click: ?bool = null,
    modal_default_focus: ?Modal.DefaultFocus = null,
    modal_border_style: ?Card.BorderStyle = null,

    wellbeing_enabled: ?bool = null,
    wellbeing_daily_limit_minutes: ?u32 = null,
    wellbeing_idle_threshold_s: ?u32 = null,
    wellbeing_focus_task_ms: ?u32 = null,
    wellbeing_focus_short_break_ms: ?u32 = null,
    wellbeing_focus_long_break_ms: ?u32 = null,
    wellbeing_tasks_before_long_break: ?u32 = null,
    wellbeing_lock_input_on_break: ?bool = null,
    wellbeing_show_break_animation: ?bool = null,
    wellbeing_mute_notifications_in_task: ?bool = null,

    wellbeing_eyesight_enabled: ?bool = null,
    wellbeing_eyesight_interval_minutes: ?u32 = null,
    wellbeing_movement_enabled: ?bool = null,
    wellbeing_movement_interval_minutes: ?u32 = null,
    wellbeing_hydration_interval_minutes: ?u32 = null,
    wellbeing_posture_interval_minutes: ?u32 = null,

    scroll_lines: ?u32 = null,
    scroll_wheel_lines: ?u32 = null,

    keybindings: [max_dynamic_keybindings]Binding = undefined,
    keybindings_count: usize = 0,
    keybindings_specified: bool = false,

    pub fn getFontFamily(self: *const FileConfig) ?[]const u8 {
        if (self.font_family) |*buf| {
            return buf[0..self.font_family_len];
        }
        return null;
    }

    pub fn getWindowTitle(self: *const FileConfig) ?[]const u8 {
        if (self.window_title) |*buf| {
            return buf[0..self.window_title_len];
        }
        return null;
    }
};
