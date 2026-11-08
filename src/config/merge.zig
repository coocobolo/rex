//! Layered configuration merging and resolution for Rex.
//!
//! Applies settings across comptime defaults, system presets, user XDG config,
//! and explicit CLI flags in deterministic precedence order.

const std = @import("std");

const log = std.log.scoped(.config);
const Allocator = std.mem.Allocator;
const fs = std.fs;

const types = @import("types.zig");
const FileConfig = types.FileConfig;
const Diagnostics = types.Diagnostics;
const parser_mod = @import("parser.zig");
const Parser = parser_mod.Parser;
const dirs = @import("../dirs/root.zig");
const input = @import("../input.zig");
const Binding = input.Binding;
const Key = input.Key;
const Modifiers = input.Modifiers;
const Config = @import("Config.zig");
const Card = @import("../renderer/Card.zig");
const Toast = @import("../ui/Toast.zig");
const Banner = @import("../ui/Banner.zig");
const Modal = @import("../ui/Modal.zig");
const keymap_parser = @import("keymap_parser.zig");

/// Maximum size in bytes read from a single configuration file.
pub const max_config_file_size = 64 * 1024;

/// System-wide configuration file location on POSIX systems.
pub const system_config_path = "/etc/rex/config";

pub const LoadFileError = std.posix.OpenError || std.posix.ReadError;

/// Parses the configuration file at `path` into `config` if it exists.
/// Returns false when there is no such file.
pub fn loadFile(path: []const u8, config: *FileConfig, diags: *Diagnostics) LoadFileError!bool {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (path.len >= path_buf.len) return false;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;

    const fd = std.posix.openat(std.posix.AT.FDCWD, path_buf[0..path.len :0], .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer _ = std.posix.system.close(fd);

    var buf: [max_config_file_size]u8 = undefined;
    const bytes_read = try std.posix.read(fd, &buf);
    const content = buf[0..bytes_read];

    var p = Parser.init(content);
    p.parseInto(config, diags);
    return true;
}

/// Resolves the absolute path to the user's primary configuration file (~/.config/rex/config).
pub fn resolveUserConfigPath(allocator: Allocator, app_dirs: *const dirs.Application) ![]u8 {
    return std.fs.path.join(allocator, &.{ app_dirs.config, "config" });
}

/// Merges non-null fields from a FileConfig into `target`. What it
/// allocates (the font path, the merged keymap) comes from `allocator`,
/// which must outlive `target`'s use.
pub fn applyFileConfig(target: *Config, file: *const FileConfig, allocator: Allocator) Allocator.Error!void {
    // Theme
    if (file.theme) |t| target.theme = t;

    // Font properties
    if (file.font_size) |sz| {
        target.font.size = @intFromFloat(sz);
    }
    if (file.font_size_step) |step| target.font.size_step = step;
    {
        // Checked together: each bound is valid alone (the parser rejects
        // 0), but the pair must still be ordered.
        const min = file.font_size_min orelse target.font.min_size;
        const max = file.font_size_max orelse target.font.max_size;
        if (min > max) {
            log.warn("font_size_min {d} is above font_size_max {d}; keeping {d} and {d}", .{
                min, max, target.font.min_size, target.font.max_size,
            });
        } else {
            target.font.min_size = min;
            target.font.max_size = max;
        }
    }
    if (target.font.faces.family == .variable) {
        if (file.font_weight) |w| target.font.faces.family.variable.regular_weight = @floatFromInt(w);
        if (file.font_weight_bold) |wb| target.font.faces.family.variable.bold_weight = @floatFromInt(wb);
        if (file.getFontFamily()) |fam| {
            const fam_z = try allocator.dupeZ(u8, fam);
            target.font.faces.family.variable.upright = fam_z.ptr;
        }
    }

    // Window options
    if (file.window_background_alpha) |a| target.window.background.alpha = a;
    if (file.window_confirm_quit) |cq| target.window.confirm_quit = cq;
    if (file.window_dim_alpha) |da| target.window.dim_alpha = da;
    if (file.window_bell) |bell| target.window.bell.enabled = bell == .on;
    if (file.window_platform) |p| target.window.platform = switch (p) {
        .auto => .auto,
        .wayland => .wayland,
        .x11 => .x11,
    };
    if (file.window_bell_volume) |vol| target.window.bell.volume = @as(f32, @floatFromInt(vol)) / 100.0;
    if (file.window_width) |w| target.window.size.width = w;
    if (file.window_height) |h| target.window.size.height = h;

    // Card options
    if (file.card_corner_radius) |r| target.window.card.corner_radius = r;
    if (file.card_border_width) |bw| target.window.card.border_width = bw;
    if (file.card_border_shape) |bs| target.window.card.border_shape = bs;
    if (file.card_border_style) |bst| {
        target.window.card.border_style = bst;
        target.window.toast.border_style = bst;
        target.window.banner.border_style = bst;
        target.window.modal.border_style = bst;
    }

    // Toast options
    if (file.toast_enabled) |en| target.window.toast.enabled = en;
    if (file.toast_position) |pos| target.window.toast.position = pos;
    if (file.toast_border_style) |bs| target.window.toast.border_style = bs;
    if (file.toast_duration_ms) |dur| target.window.toast.duration_ms = dur;
    if (file.toast_min_width) |mw| target.window.toast.min_width = mw;
    if (file.toast_max_width) |mw| target.window.toast.max_width = mw;
    if (file.toast_margin_cols) |mc| target.window.toast.margin_cols = mc;
    if (file.toast_margin_rows) |mr| target.window.toast.margin_rows = mr;

    // Banner options
    if (file.banner_enabled) |en| target.window.banner.enabled = en;
    if (file.banner_style) |st| target.window.banner.placement = st;
    if (file.banner_position) |pos| target.window.banner.position = pos;
    if (file.banner_border_style) |bs| target.window.banner.border_style = bs;
    if (file.banner_corner_radius) |cr| target.window.banner.corner_radius = cr;
    if (file.banner_border_width) |bw| target.window.banner.border_width = bw;
    if (file.banner_min_width) |mw| target.window.banner.min_width = mw;
    if (file.banner_max_width) |mw| target.window.banner.max_width = mw;
    if (file.banner_margin_cols) |mc| target.window.banner.margin_cols = mc;
    if (file.banner_margin_rows) |mr| target.window.banner.margin_rows = mr;

    // Modal options
    if (file.modal_width) |w| target.window.modal.width = w;
    if (file.modal_dim_alpha) |da| target.window.modal.backdrop_opacity = @as(f32, @floatFromInt(da)) / 255.0;
    if (file.modal_blur) |b| target.window.modal.blur = b;
    if (file.modal_blur_radius) |br| target.window.modal.blur_radius = br;
    if (file.modal_close_on_outside_click) |cl| target.window.modal.close_on_outside_click = cl;
    if (file.modal_default_focus) |df| target.window.modal.default_focus = df;
    if (file.modal_border_style) |mbs| target.window.modal.border_style = mbs;

    // Wellbeing options
    if (file.wellbeing_enabled) |en| target.wellbeing.enabled = en;
    if (file.wellbeing_daily_limit_minutes) |dl| target.wellbeing.screen_time.daily_limit_ms = @as(u64, dl) * std.time.ms_per_min;
    if (file.wellbeing_idle_threshold_s) |it| target.wellbeing.screen_time.idle_threshold_ms = @as(u64, it) * std.time.ms_per_s;
    if (file.wellbeing_focus_task_ms) |ft| target.wellbeing.focus.task_ms = ft;
    if (file.wellbeing_focus_short_break_ms) |sb| target.wellbeing.focus.short_break_ms = sb;
    if (file.wellbeing_focus_long_break_ms) |lb| target.wellbeing.focus.long_break_ms = lb;
    if (file.wellbeing_tasks_before_long_break) |tb| target.wellbeing.focus.tasks_before_long_break = @intCast(@min(tb, 255));
    if (file.wellbeing_lock_input_on_break) |li| target.wellbeing.focus.lock_input_on_break = li;
    if (file.wellbeing_show_break_animation) |sa| target.wellbeing.focus.show_break_animation = sa;
    if (file.wellbeing_mute_notifications_in_task) |mn| target.wellbeing.focus.mute_notifications_in_task = mn;

    // Scroll options
    if (file.scroll_lines) |sl| target.scroll.lines = sl;
    if (file.scroll_wheel_lines) |wl| target.scroll.wheel_lines = wl;

    // Custom keybindings: merge user bindings on top of defaults
    if (file.keybindings_specified and file.keybindings_count > 0) {
        var merged: std.ArrayList(Binding) = .empty;
        const user_bindings = file.keybindings[0..file.keybindings_count];

        // Start with default keymap
        for (target.keymap) |def_b| {
            var overridden = false;
            for (user_bindings) |ub| {
                if (ub.key == def_b.key and @as(u8, @bitCast(ub.mods)) == @as(u8, @bitCast(def_b.mods))) {
                    overridden = true;
                    break;
                }
            }
            if (!overridden) {
                try merged.append(allocator, def_b);
            }
        }

        // Add all user bindings
        for (user_bindings) |ub| {
            try merged.append(allocator, ub);
        }

        target.keymap = try merged.toOwnedSlice(allocator);
    }
}

/// Canonical default configuration file content with complete inline documentation.
pub const canonical_default_config: []const u8 =
    \\# ~/.config/rex/config
    \\# Canonical Configuration Template for Rex Terminal Emulator
    \\#
    \\# Syntax rules:
    \\#   - Key-value assignments: key = value
    \\#   - Section headers: [section]
    \\#   - Dot notation is also supported: section.key = value (e.g., card.corner_radius = 8.0)
    \\#   - Comments start with '#'
    \\#   - Keys can use snake_case (dim_alpha) or kebab-case (dim-alpha)
    \\#   - Hot reload active config at runtime with: Ctrl+Shift+R
    \\
    \\# ==============================================================================
    \\# Theme & Typography
    \\# ==============================================================================
    \\
    \\# Built-in terminal color palette preset.
    \\# Supported values: graphite
    \\# Default: graphite
    \\theme = graphite
    \\
    \\# Monospace font family or variable font file.
    \\# Supported values: any font family name or TTF/OTF path
    \\# Default: GoogleSansCode-VariableFont_MONO,wght.ttf
    \\# font_family = "GoogleSansCode-VariableFont_MONO,wght.ttf"
    \\
    \\# Font size in pixels at 100% display scale; Rex multiplies it by the
    \\# display's scale (125%, 150%, ...), so text keeps its size on HiDPI.
    \\# Supported values: positive float (e.g. 10.0, 14.0, 18.0)
    \\# Default: 14.0
    \\font_size = 14.0
    \\
    \\# Step of increase_font_size and decrease_font_size, in pixels at 100% scale.
    \\# Supported values: positive integer
    \\# Default: 2
    \\font_size_step = 2
    \\
    \\# Smallest and largest size those keys reach, in pixels at 100% scale.
    \\# Supported values: positive integer, font_size_min <= font_size_max
    \\# Default: 6 and 196
    \\font_size_min = 6
    \\font_size_max = 196
    \\
    \\# Regular font weight for variable fonts.
    \\# Supported values: integer from 100 to 900 (100: Thin, 400: Regular, 500: Medium, 700: Bold)
    \\# Default: 400
    \\font_weight = 400
    \\
    \\# Bold font weight for variable fonts when bold text (SGR 1) is rendered.
    \\# Supported values: integer from 100 to 900 (must be >= font_weight)
    \\# Default: 550
    \\font_weight_bold = 550
    \\
    \\# ==============================================================================
    \\# Window & Rendering ([window])
    \\# ==============================================================================
    \\[window]
    \\
    \\# Windowing platform, chosen at startup (a config reload doesn't switch it).
    \\# auto: Wayland on a Wayland session, X11 otherwise.
    \\# Supported values: auto, wayland, x11
    \\# Default: auto
    \\platform = auto
    \\
    \\background_alpha = 0.95
    \\# Window background opacity multiplier.
    \\# Supported values: float from 0.0 (completely transparent) to 1.0 (fully opaque)
    \\# Default: 0.95
    \\background_alpha = 0.95
    \\
    \\# Background blur radius when compositor or blur pipeline is active.
    \\# Supported values: integer >= 0 (0 disables background blur)
    \\# Default: 0
    \\background_blur = 0
    \\
    \\# Ask for interactive confirmation before closing window when terminal sessions are active.
    \\# Supported values: true, false, yes, no, on, off, 1, 0
    \\# Default: true
    \\confirm_quit = true
    \\
    \\# Opacity factor for SGR 2 (dim / faint) terminal text.
    \\# Supported values: float from 0.0 to 1.0
    \\# Default: 0.5
    \\dim_alpha = 0.5
    \\
    \\# Audible / visual bell toggle on BEL control character.
    \\# Supported values: on, off, true, false
    \\# Default: on
    \\bell = on
    \\
    \\# Terminal bell volume as a percentage of system alert volume.
    \\# Supported values: integer from 0 to 100
    \\# Default: 100
    \\bell_volume = 100
    \\
    \\# Initial window title (appended with Wellbeing focus session if active).
    \\# Supported values: string up to 127 characters
    \\# Default: rex
    \\title = "rex"
    \\
    \\# Initial window width in screen pixels.
    \\# Supported values: positive integer
    \\# Default: 1920
    \\# width = 1920
    \\
    \\# Initial window height in screen pixels.
    \\# Supported values: positive integer
    \\# Default: 1080
    \\# height = 1080
    \\
    \\# ==============================================================================
    \\# UI Cards & Analytic Surfaces ([card])
    \\# ==============================================================================
    \\# Shared analytic Signed Distance Field (SDF) rounded rectangle geometry
    \\# used for modals, dialogs, toasts, banners, and wellbeing overlay cards.
    \\[card]
    \\
    \\# Corner rounding radius in screen pixels.
    \\# Supported values: float >= 0.0 (0.0 creates sharp corners)
    \\# Default: 8.0
    \\corner_radius = 8.0
    \\
    \\# Outer border stroke thickness in screen pixels.
    \\# Supported values: float >= 0.0 (0.0 disables border stroke)
    \\# Default: 1.0
    \\border_width = 1.0
    \\
    \\# Outer border shape geometry.
    \\# Supported values: rounded, sharp
    \\# Default: rounded
    \\border_shape = rounded
    \\
    \\# Global card border styling cascaded across all native UI cards (modals, toasts, banners).
    \\# Supported values:
    \\#   semantic  - Border tinted by component status or severity
    \\#   subtle    - Low-contrast neutral border from theme tokens
    \\# Default: semantic
    \\border_style = semantic
    \\
    \\# ==============================================================================
    \\# Toast Notifications ([toast])
    \\# ==============================================================================
    \\[toast]
    \\
    \\# Enable or disable in-terminal floating toast notifications.
    \\# Supported values: true, false, on, off
    \\# Default: true
    \\enabled = true
    \\
    \\# Screen anchor position for toast popups.
    \\# Supported values: top_right, top_center, bottom_right
    \\# Default: top_right
    \\position = top_right
    \\
    \\# Toast card border styling.
    \\# Supported values:
    \\#   semantic  - Border tinted by notification type (info: cyan, success: green, warning: yellow, critical: red)
    \\#   subtle    - Low-contrast neutral border from theme tokens
    \\# Default: semantic
    \\border_style = semantic
    \\
    \\# Display duration before automatic fade-out and dismissal.
    \\# Supported units: ms (milliseconds), s (seconds), m (minutes), h (hours)
    \\# Supported values: e.g. 3000ms, 5s, 10s
    \\# Default: 5s
    \\duration = 5s
    \\
    \\# Minimum width in character columns.
    \\# Supported values: positive integer
    \\# Default: 32
    \\min_width = 32
    \\
    \\# Maximum width in character columns (longer text is wrapped across lines or truncated).
    \\# Supported values: positive integer
    \\# Default: 64
    \\max_width = 64
    \\
    \\# Horizontal margin in columns from the screen edge.
    \\# Supported values: integer >= 0
    \\# Default: 2
    \\margin_cols = 2
    \\
    \\# Vertical margin in rows from the screen edge.
    \\# Supported values: integer >= 0
    \\# Default: 1
    \\margin_rows = 1
    \\
    \\# ==============================================================================
    \\# Diagnostic Banner ([banner])
    \\# ==============================================================================
    \\# Configuration diagnostic and status notice banner displayed on hot reload or errors.
    \\[banner]
    \\
    \\# Enable or disable diagnostic and status banners.
    \\# Supported values: true, false, on, off
    \\# Default: true
    \\enabled = true
    \\
    \\# Visual presentation style of the banner.
    \\# Supported values:
    \\#   floating  - Compact 3-row floating card with rounded corners
    \\#   docked    - Spans the viewport top or bottom edge with configurable margins
    \\# Default: floating
    \\style = floating
    \\
    \\# Screen anchor position for the banner.
    \\# Supported values: top_center, top_right, top_left
    \\# Default: top_center
    \\position = top_center
    \\
    \\# Border stroke color styling.
    \\# Supported values:
    \\#   semantic  - Border tinted by diagnostic severity (error: red, warning: yellow, info: cyan)
    \\#   subtle    - Low-contrast neutral border
    \\# Default: semantic
    \\border_style = semantic
    \\
    \\# Corner rounding radius for the banner card in pixels (applied to both floating and docked).
    \\# Supported values: float >= 0.0 (0.0 for square corners)
    \\# Default: 8.0
    \\corner_radius = 8.0
    \\
    \\# Border stroke thickness in screen pixels.
    \\# Supported values: float >= 0.0
    \\# Default: 1.0
    \\border_width = 1.0
    \\
    \\# Minimum banner width in character columns.
    \\# Supported values: positive integer
    \\# Default: 36
    \\min_width = 36
    \\
    \\# Maximum banner width in character columns (text auto-ellipsizes to fit).
    \\# Supported values: positive integer
    \\# Default: 72
    \\max_width = 72
    \\
    \\# Horizontal margin in columns from screen boundaries.
    \\# Supported values: integer >= 0
    \\# Default: 2
    \\margin_cols = 2
    \\
    \\# Vertical margin in rows from screen boundaries (in docked style, 0 aligns flush against the edge).
    \\# Supported values: integer >= 0
    \\# Default: 1
    \\margin_rows = 1
    \\
    \\# ==============================================================================
    \\# Modal Dialogs ([modal])
    \\# ==============================================================================
    \\[modal]
    \\
    \\# Width of centered modal dialogs (e.g. quit confirmation) in character columns.
    \\# Supported values: integer >= 20
    \\# Default: 46
    \\width = 46
    \\
    \\# Opacity of the background dimming veil behind modal dialogs.
    \\# Supported values: integer from 0 (completely clear) to 255 (solid black overlay)
    \\# Default: 180
    \\dim_alpha = 180
    \\
    \\# Progressive multi-scale Dual Kawase blur pass behind active modal dialogs.
    \\# Supported values: true, false, on, off
    \\# Default: false
    \\blur = false
    \\
    \\# Blur radius offset applied to the multi-scale downsampling and upsampling pyramid.
    \\# Supported values: integer from 0 (finest smooth blur) to 16
    \\# Default: 12
    \\blur_radius = 12
    \\
    \\# Dismiss the modal and cancel the prompt when clicking outside the dialog card.
    \\# Supported values: true, false, on, off
    \\# Default: true
    \\close_on_outside_click = true
    \\
    \\# Initial button focus when the modal dialog is opened.
    \\# Supported values:
    \\#   confirm  - Primary confirm button (Enter triggers action)
    \\#   cancel   - Secondary abort button (Esc or Enter aborts action)
    \\# Default: confirm
    \\default_focus = confirm
    \\
    \\# Modal dialog border color styling (inherits [card] border_style if omitted).
    \\# Supported values: semantic, subtle
    \\# Default: semantic
    \\border_style = semantic
    \\
    \\# ==============================================================================
    \\# Digital Wellbeing & Ergonomics ([wellbeing])
    \\# ==============================================================================
    \\# Tracks active typing and terminal engagement, manages Pomodoro focus sessions,
    \\# and surfaces health/ergonomic reminders (20-20-20 eyesight rule, posture, movement).
    \\[wellbeing]
    \\
    \\# Enable or disable the Digital Wellbeing subsystem.
    \\# Supported values: true, false, on, off
    \\# Default: true
    \\enabled = true
    \\
    \\# Cumulative daily active screen-time threshold before notifications suggest rest.
    \\# Supported units: m (minutes), h (hours)
    \\# Supported values: e.g. 8h, 480m
    \\# Default: 8h
    \\daily_limit = 8h
    \\
    \\# Inactivity timeout before terminal pauses screen-time accumulation.
    \\# Supported units: s (seconds), m (minutes)
    \\# Supported values: e.g. 60s, 2m
    \\# Default: 60s
    \\idle_threshold = 60s
    \\
    \\# Pomodoro active focus interval duration.
    \\# Supported units: ms, s, m, h
    \\# Supported values: e.g. 25m, 1500s
    \\# Default: 25m
    \\focus_time = 25m
    \\
    \\# Short rest break duration between focus tasks.
    \\# Supported units: ms, s, m, h
    \\# Supported values: e.g. 5m, 300s
    \\# Default: 5m
    \\short_break = 5m
    \\
    \\# Extended long rest break duration after completing a set of focus tasks.
    \\# Supported units: ms, s, m, h
    \\# Supported values: e.g. 15m, 900s
    \\# Default: 15m
    \\long_break = 15m
    \\
    \\# Number of completed focus tasks required before triggering a long break.
    \\# Supported values: positive integer (1 to 255)
    \\# Default: 4
    \\tasks_before_long_break = 4
    \\
    \\# Temporarily lock terminal input during active break countdowns to encourage stepping away.
    \\# Supported values: true, false
    \\# Default: false
    \\lock_input_on_break = false
    \\
    \\# Display relaxing breathing / break wave animation during rest intervals.
    \\# Supported values: true, false
    \\# Default: true
    \\show_break_animation = true
    \\
    \\# Suppress non-critical notifications while a focus sprint is running.
    \\# Supported values: true, false
    \\# Default: false
    \\mute_notifications_in_task = false
    \\
    \\# 20-20-20 rule eye rest reminder interval (look 20 feet away for 20 seconds).
    \\# Supported units: m, h (e.g. 20m)
    \\# Default: 20m
    \\eyesight_interval = 20m
    \\
    \\# Movement / stand-up reminder interval.
    \\# Supported units: m, h (e.g. 60m, 1h)
    \\# Default: 60m
    \\movement_interval = 60m
    \\
    \\# Water / hydration reminder interval.
    \\# Supported units: m, h (e.g. 45m)
    \\# Default: 45m
    \\hydration_interval = 45m
    \\
    \\# Ergonomic posture check reminder interval.
    \\# Supported units: m, h (e.g. 30m)
    \\# Default: 30m
    \\posture_interval = 30m
    \\
    \\# ==============================================================================
    \\# Scrolling ([scroll])
    \\# ==============================================================================
    \\[scroll]
    \\
    \\# Lines to scroll per scroll_up or scroll_down keybinding invocation.
    \\# Supported values: positive integer
    \\# Default: 3
    \\lines = 3
    \\
    \\# Lines to scroll per mouse scroll wheel notch / event.
    \\# Supported values: positive integer
    \\# Default: 3
    \\wheel_lines = 3
    \\
    \\# ==============================================================================
    \\# Keybindings ([keybinds])
    \\# ==============================================================================
    \\# Syntax: <modifiers>+<key> = <action>
    \\#
    \\# Supported Modifiers:
    \\#   ctrl (control), shift, alt (opt, option), super (cmd, command, win, windows)
    \\#
    \\# Supported Keys:
    \\#   Letters: a..z
    \\#   Numbers: 0..9
    \\#   Function keys: f1..f25
    \\#   Punctuation / Symbols: minus (-), plus / equal (=, +), left_bracket ([), right_bracket (]),
    \\#                          backslash (\), semicolon (;), apostrophe ('), comma (,), period (.),
    \\#                          slash (/), grave (`)
    \\#   Navigation & Editing: space, enter (return), tab, backspace, escape (esc), delete (del),
    \\#                         insert (ins), home, end, page_up (pgup), page_down (pgdown),
    \\#                         up, down, left, right
    \\#
    \\# Supported Actions:
    \\#   Window & Clipboard:
    \\#     copy_selection          - Copy active visual selection to system clipboard
    \\#     paste_clipboard         - Paste system clipboard contents into terminal stdin
    \\#     new_window              - Open a new terminal window
    \\#     quit                    - Terminate Rex window session (prompts if confirm_quit = true)
    \\#
    \\#   Font Zoom:
    \\#     increase_font_size      - Increase font size by font_size_step
    \\#     decrease_font_size      - Decrease font size by font_size_step
    \\#     reset_font_size         - Reset font size to default configured size
    \\#
    \\#   Viewport Scrolling:
    \\#     scroll_up               - Scroll viewport upward by scroll.lines
    \\#     scroll_down             - Scroll viewport downward by scroll.lines
    \\#
    \\#   Configuration & System:
    \\#     reload_config           - Hot-reload configuration from disk without dropping session
    \\#     debug                   - Toggle diagnostic HUD overlay
    \\#
    \\#   Digital Wellbeing & Focus:
    \\#     wellbeing_dashboard     - Toggle interactive wellbeing dashboard overlay
    \\#     wellbeing_dismiss       - Dismiss active wellbeing reminder notification
    \\#     wellbeing_clear         - Purge recorded wellbeing daily activity history
    \\#     wellbeing_toast_toggle  - Toggle wellbeing toast reminders on/off
    \\#     focus_toggle            - Start or pause the current Pomodoro focus timer
    \\#     focus_reset             - Reset current Pomodoro interval to start
    \\#     focus_skip              - Advance to the next task or break immediately
    \\#     focus_auto_transition   - Toggle automatic cycling between tasks and breaks
    \\#
    \\#   Toast Notifications:
    \\#     toast_dismiss           - Dismiss topmost toast notification
    \\#     toast_activate          - Trigger primary action on the active toast
    \\#
    \\[keybinds]
    \\ctrl+shift+w = wellbeing_dashboard
    \\ctrl+shift+d = wellbeing_dismiss
    \\ctrl+shift+p = focus_toggle
    \\ctrl+shift+r = reload_config
    \\ctrl+0 = reset_font_size
    \\ctrl+plus = increase_font_size
    \\ctrl+minus = decrease_font_size
    \\
;

/// Dumps the canonical default configuration file with comments and descriptions.
pub fn dumpDefaultConfig(writer: anytype) !void {
    try writer.writeAll(canonical_default_config);
}

/// Overlays non-null configuration values from the source configuration onto the target configuration.
pub fn mergeFileConfigs(target: *FileConfig, src: *const FileConfig) void {
    if (src.theme) |t| target.theme = t;
    if (src.tokens) |tok| target.tokens = tok;

    if (src.font_family) |fam| {
        target.font_family = fam;
        target.font_family_len = src.font_family_len;
    }
    if (src.font_size) |sz| target.font_size = sz;
    if (src.font_weight) |w| target.font_weight = w;
    if (src.font_weight_bold) |wb| target.font_weight_bold = wb;
    if (src.font_size_step) |v| target.font_size_step = v;
    if (src.font_size_min) |v| target.font_size_min = v;
    if (src.font_size_max) |v| target.font_size_max = v;

    if (src.window_background_alpha) |v| target.window_background_alpha = v;
    if (src.window_background_blur) |v| target.window_background_blur = v;
    if (src.window_confirm_quit) |v| target.window_confirm_quit = v;
    if (src.window_dim_alpha) |v| target.window_dim_alpha = v;
    if (src.window_bell) |v| target.window_bell = v;
    if (src.window_platform) |v| target.window_platform = v;
    if (src.window_bell_volume) |v| target.window_bell_volume = v;
    if (src.window_title) |title| {
        target.window_title = title;
        target.window_title_len = src.window_title_len;
    }
    if (src.window_width) |v| target.window_width = v;
    if (src.window_height) |v| target.window_height = v;

    if (src.card_corner_radius) |v| target.card_corner_radius = v;
    if (src.card_border_width) |v| target.card_border_width = v;
    if (src.card_border_shape) |v| target.card_border_shape = v;
    if (src.card_border_style) |v| target.card_border_style = v;

    if (src.toast_enabled) |v| target.toast_enabled = v;
    if (src.toast_position) |v| target.toast_position = v;
    if (src.toast_border_style) |v| target.toast_border_style = v;
    if (src.toast_duration_ms) |v| target.toast_duration_ms = v;
    if (src.toast_min_width) |v| target.toast_min_width = v;
    if (src.toast_max_width) |v| target.toast_max_width = v;
    if (src.toast_margin_cols) |v| target.toast_margin_cols = v;
    if (src.toast_margin_rows) |v| target.toast_margin_rows = v;

    if (src.banner_enabled) |v| target.banner_enabled = v;
    if (src.banner_style) |v| target.banner_style = v;
    if (src.banner_position) |v| target.banner_position = v;
    if (src.banner_border_style) |v| target.banner_border_style = v;
    if (src.banner_corner_radius) |v| target.banner_corner_radius = v;
    if (src.banner_border_width) |v| target.banner_border_width = v;
    if (src.banner_min_width) |v| target.banner_min_width = v;
    if (src.banner_max_width) |v| target.banner_max_width = v;
    if (src.banner_margin_cols) |v| target.banner_margin_cols = v;
    if (src.banner_margin_rows) |v| target.banner_margin_rows = v;

    if (src.modal_width) |v| target.modal_width = v;
    if (src.modal_dim_alpha) |v| target.modal_dim_alpha = v;
    if (src.modal_blur) |v| target.modal_blur = v;
    if (src.modal_blur_radius) |v| target.modal_blur_radius = v;
    if (src.modal_close_on_outside_click) |v| target.modal_close_on_outside_click = v;
    if (src.modal_default_focus) |v| target.modal_default_focus = v;
    if (src.modal_border_style) |v| target.modal_border_style = v;

    if (src.wellbeing_enabled) |v| target.wellbeing_enabled = v;
    if (src.wellbeing_daily_limit_minutes) |v| target.wellbeing_daily_limit_minutes = v;
    if (src.wellbeing_idle_threshold_s) |v| target.wellbeing_idle_threshold_s = v;
    if (src.wellbeing_focus_task_ms) |v| target.wellbeing_focus_task_ms = v;
    if (src.wellbeing_focus_short_break_ms) |v| target.wellbeing_focus_short_break_ms = v;
    if (src.wellbeing_focus_long_break_ms) |v| target.wellbeing_focus_long_break_ms = v;
    if (src.wellbeing_tasks_before_long_break) |v| target.wellbeing_tasks_before_long_break = v;
    if (src.wellbeing_lock_input_on_break) |v| target.wellbeing_lock_input_on_break = v;
    if (src.wellbeing_show_break_animation) |v| target.wellbeing_show_break_animation = v;
    if (src.wellbeing_mute_notifications_in_task) |v| target.wellbeing_mute_notifications_in_task = v;

    if (src.wellbeing_eyesight_enabled) |v| target.wellbeing_eyesight_enabled = v;
    if (src.wellbeing_eyesight_interval_minutes) |v| target.wellbeing_eyesight_interval_minutes = v;
    if (src.wellbeing_movement_enabled) |v| target.wellbeing_movement_enabled = v;
    if (src.wellbeing_movement_interval_minutes) |v| target.wellbeing_movement_interval_minutes = v;
    if (src.wellbeing_hydration_interval_minutes) |v| target.wellbeing_hydration_interval_minutes = v;
    if (src.wellbeing_posture_interval_minutes) |v| target.wellbeing_posture_interval_minutes = v;

    if (src.scroll_lines) |v| target.scroll_lines = v;
    if (src.scroll_wheel_lines) |v| target.scroll_wheel_lines = v;

    if (src.keybindings_specified) {
        if (!target.keybindings_specified) {
            target.keybindings = src.keybindings;
            target.keybindings_count = src.keybindings_count;
            target.keybindings_specified = true;
        } else {
            for (src.keybindings[0..src.keybindings_count]) |sb| {
                var found = false;
                for (target.keybindings[0..target.keybindings_count]) |*tb| {
                    if (tb.key == sb.key and @as(u8, @bitCast(tb.mods)) == @as(u8, @bitCast(sb.mods))) {
                        tb.action = sb.action;
                        found = true;
                        break;
                    }
                }
                if (!found and target.keybindings_count < types.max_dynamic_keybindings) {
                    target.keybindings[target.keybindings_count] = sb;
                    target.keybindings_count += 1;
                }
            }
        }
    }
}

/// Serializes a FileConfig structure into canonical configuration syntax with complete documentation comments.
pub fn serializeConfig(config: *const FileConfig, writer: anytype) !void {
    try writer.writeAll(
        \\# ~/.config/rex/config
        \\# Canonical Configuration Template for Rex Terminal Emulator
        \\#
        \\# Syntax rules:
        \\#   - Key-value assignments: key = value
        \\#   - Section headers: [section]
        \\#   - Dot notation is also supported: section.key = value (e.g., card.corner_radius = 8.0)
        \\#   - Comments start with '#'
        \\#   - Keys can use snake_case (dim_alpha) or kebab-case (dim-alpha)
        \\#   - Hot reload active config at runtime with: Ctrl+Shift+R
        \\
        \\# ==============================================================================
        \\# Theme & Typography
        \\# ==============================================================================
        \\
        \\# Built-in terminal color palette preset.
        \\# Supported values: graphite
        \\# Default: graphite
        \\
    );
    try writer.writeAll("theme = graphite\n\n");

    try writer.writeAll(
        \\# Monospace font family or variable font file.
        \\# Supported values: any font family name or TTF/OTF path
        \\# Default: GoogleSansCode-VariableFont_MONO,wght.ttf
        \\
    );
    if (config.getFontFamily()) |fam| {
        try writer.print("font_family = \"{s}\"\n\n", .{fam});
    } else {
        try writer.writeAll("# font_family = \"GoogleSansCode-VariableFont_MONO,wght.ttf\"\n\n");
    }

    try writer.writeAll(
        \\# Font size in pixels at 100% display scale; Rex multiplies it by the
        \\# display's scale (125%, 150%, ...), so text keeps its size on HiDPI.
        \\# Supported values: positive float (e.g. 10.0, 14.0, 18.0)
        \\# Default: 14.0
        \\
    );
    try writer.print("font_size = {d:.1}\n\n", .{config.font_size orelse 14.0});

    try writer.writeAll(
        \\# Step of increase_font_size and decrease_font_size, in pixels at 100% scale.
        \\# Supported values: positive integer
        \\# Default: 2
        \\
    );
    try writer.print("font_size_step = {d}\n\n", .{config.font_size_step orelse 2});

    try writer.writeAll(
        \\# Smallest and largest size those keys reach, in pixels at 100% scale.
        \\# Supported values: positive integer, font_size_min <= font_size_max
        \\# Default: 6 and 196
        \\
    );
    try writer.print("font_size_min = {d}\nfont_size_max = {d}\n\n", .{
        config.font_size_min orelse 6,
        config.font_size_max orelse 196,
    });

    try writer.writeAll(
        \\# Regular font weight for variable fonts.
        \\# Supported values: integer from 100 to 900 (100: Thin, 400: Regular, 500: Medium, 700: Bold)
        \\# Default: 400
        \\
    );
    try writer.print("font_weight = {d}\n\n", .{config.font_weight orelse 400});

    try writer.writeAll(
        \\# Bold font weight for variable fonts when bold text (SGR 1) is rendered.
        \\# Supported values: integer from 100 to 900 (must be >= font_weight)
        \\# Default: 550
        \\
    );
    try writer.print("font_weight_bold = {d}\n\n", .{config.font_weight_bold orelse 550});

    try writer.writeAll(
        \\# ==============================================================================
        \\# Window & Rendering ([window])
        \\# ==============================================================================
        \\[window]
        \\
        \\# Window background opacity multiplier.
        \\# Supported values: float from 0.0 (completely transparent) to 1.0 (fully opaque)
        \\# Default: 0.95
        \\
    );

    try writer.writeAll(
        \\# Windowing platform, chosen at startup (a config reload doesn't switch it).
        \\# auto: Wayland on a Wayland session, X11 otherwise.
        \\# Supported values: auto, wayland, x11
        \\# Default: auto
        \\
    );
    try writer.print("platform = {s}\n\n", .{@tagName(config.window_platform orelse .auto)});

    try writer.print("background_alpha = {d:.2}\n\n", .{config.window_background_alpha orelse 0.95});

    try writer.writeAll(
        \\# Background blur radius when compositor or blur pipeline is active.
        \\# Supported values: integer >= 0 (0 disables background blur)
        \\# Default: 0
        \\
    );
    try writer.print("background_blur = {d}\n\n", .{config.window_background_blur orelse 0});

    try writer.writeAll(
        \\# Ask for interactive confirmation before closing window when terminal sessions are active.
        \\# Supported values: true, false, yes, no, on, off, 1, 0
        \\# Default: true
        \\
    );
    try writer.print("confirm_quit = {}\n\n", .{config.window_confirm_quit orelse true});

    try writer.writeAll(
        \\# Opacity factor for SGR 2 (dim / faint) terminal text.
        \\# Supported values: float from 0.0 to 1.0
        \\# Default: 0.5
        \\
    );
    try writer.print("dim_alpha = {d:.2}\n\n", .{config.window_dim_alpha orelse 0.5});

    try writer.writeAll(
        \\# Audible / visual bell toggle on BEL control character.
        \\# Supported values: on, off, true, false
        \\# Default: on
        \\
    );
    const bell_str = if (config.window_bell) |b| switch (b) {
        .on => "on",
        .off => "off",
    } else "on";
    try writer.print("bell = {s}\n\n", .{bell_str});

    try writer.writeAll(
        \\# Terminal bell volume as a percentage of system alert volume.
        \\# Supported values: integer from 0 to 100
        \\# Default: 100
        \\
    );
    try writer.print("bell_volume = {d}\n\n", .{config.window_bell_volume orelse 100});

    try writer.writeAll(
        \\# Initial window title (appended with Wellbeing focus session if active).
        \\# Supported values: string up to 127 characters
        \\# Default: rex
        \\
    );
    if (config.getWindowTitle()) |title| {
        try writer.print("title = \"{s}\"\n\n", .{title});
    } else {
        try writer.writeAll("title = \"rex\"\n\n");
    }

    try writer.writeAll(
        \\# Initial window width in screen pixels.
        \\# Supported values: positive integer
        \\# Default: 1920
        \\
    );
    if (config.window_width) |w| {
        try writer.print("width = {d}\n\n", .{w});
    } else {
        try writer.writeAll("# width = 1920\n\n");
    }

    try writer.writeAll(
        \\# Initial window height in screen pixels.
        \\# Supported values: positive integer
        \\# Default: 1080
        \\
    );
    if (config.window_height) |h| {
        try writer.print("height = {d}\n\n", .{h});
    } else {
        try writer.writeAll("# height = 1080\n\n");
    }

    try writer.writeAll(
        \\# ==============================================================================
        \\# UI Cards & Analytic Surfaces ([card])
        \\# ==============================================================================
        \\# Shared analytic Signed Distance Field (SDF) rounded rectangle geometry
        \\# used for modals, dialogs, toasts, banners, and wellbeing overlay cards.
        \\[card]
        \\
        \\# Corner rounding radius in screen pixels.
        \\# Supported values: float >= 0.0 (0.0 creates sharp corners)
        \\# Default: 8.0
        \\
    );
    try writer.print("corner_radius = {d:.1}\n\n", .{config.card_corner_radius orelse 8.0});

    try writer.writeAll(
        \\# Outer border stroke thickness in screen pixels.
        \\# Supported values: float >= 0.0 (0.0 disables border stroke)
        \\# Default: 1.0
        \\
    );
    try writer.print("border_width = {d:.1}\n\n", .{config.card_border_width orelse 1.0});

    try writer.writeAll(
        \\# Outer border shape geometry.
        \\# Supported values: rounded, sharp
        \\# Default: rounded
        \\
    );
    const border_shape_str = if (config.card_border_shape) |bs| switch (bs) {
        .rounded => "rounded",
        .sharp => "sharp",
    } else "rounded";
    try writer.print("border_shape = {s}\n\n", .{border_shape_str});

    try writer.writeAll(
        \\# Global card border styling cascaded across all native UI cards (modals, toasts, banners).
        \\# Supported values:
        \\#   semantic  - Border tinted by component status or severity
        \\#   subtle    - Low-contrast neutral border from theme tokens
        \\# Default: semantic
        \\
    );
    const card_border_style_str = if (config.card_border_style) |bst| switch (bst) {
        .semantic => "semantic",
        .subtle => "subtle",
    } else "semantic";
    try writer.print("border_style = {s}\n\n", .{card_border_style_str});

    try writer.writeAll(
        \\# ==============================================================================
        \\# Toast Notifications ([toast])
        \\# ==============================================================================
        \\[toast]
        \\
        \\# Enable or disable in-terminal floating toast notifications.
        \\# Supported values: true, false, on, off
        \\# Default: true
        \\
    );
    try writer.print("enabled = {}\n\n", .{config.toast_enabled orelse true});

    try writer.writeAll(
        \\# Screen anchor position for toast popups.
        \\# Supported values: top_right, top_center, bottom_right
        \\# Default: top_right
        \\
    );
    const toast_pos_str = if (config.toast_position) |pos| switch (pos) {
        .top_right => "top_right",
        .top_center => "top_center",
        .bottom_right => "bottom_right",
    } else "top_right";
    try writer.print("position = {s}\n\n", .{toast_pos_str});

    try writer.writeAll(
        \\# Toast card border styling.
        \\# Supported values:
        \\#   semantic  - Border tinted by notification type (info: cyan, success: green, warning: yellow, critical: red)
        \\#   subtle    - Low-contrast neutral border from theme tokens
        \\# Default: semantic
        \\
    );
    const toast_bs_str = if (config.toast_border_style) |bs| switch (bs) {
        .semantic => "semantic",
        .subtle => "subtle",
    } else "semantic";
    try writer.print("border_style = {s}\n\n", .{toast_bs_str});

    try writer.writeAll(
        \\# Display duration before automatic fade-out and dismissal.
        \\# Supported units: ms (milliseconds), s (seconds), m (minutes), h (hours)
        \\# Supported values: e.g. 3000ms, 5s, 10s
        \\# Default: 5s
        \\
    );
    if (config.toast_duration_ms) |dur| {
        if (dur % 1000 == 0) {
            try writer.print("duration = {d}s\n\n", .{dur / 1000});
        } else {
            try writer.print("duration = {d}ms\n\n", .{dur});
        }
    } else {
        try writer.writeAll("duration = 5s\n\n");
    }

    try writer.writeAll(
        \\# Minimum width in character columns.
        \\# Supported values: positive integer
        \\# Default: 32
        \\
    );
    try writer.print("min_width = {d}\n\n", .{config.toast_min_width orelse 32});

    try writer.writeAll(
        \\# Maximum width in character columns (longer text is wrapped across lines or truncated).
        \\# Supported values: positive integer
        \\# Default: 64
        \\
    );
    try writer.print("max_width = {d}\n\n", .{config.toast_max_width orelse 64});

    try writer.writeAll(
        \\# Horizontal margin in columns from the screen edge.
        \\# Supported values: integer >= 0
        \\# Default: 2
        \\
    );
    try writer.print("margin_cols = {d}\n\n", .{config.toast_margin_cols orelse 2});

    try writer.writeAll(
        \\# Vertical margin in rows from the screen edge.
        \\# Supported values: integer >= 0
        \\# Default: 1
        \\
    );
    try writer.print("margin_rows = {d}\n\n", .{config.toast_margin_rows orelse 1});

    try writer.writeAll(
        \\# ==============================================================================
        \\# Diagnostic Banner ([banner])
        \\# ==============================================================================
        \\# Configuration diagnostic and status notice banner displayed on hot reload or errors.
        \\[banner]
        \\
        \\# Enable or disable diagnostic and status banners.
        \\# Supported values: true, false, on, off
        \\# Default: true
        \\
    );
    try writer.print("enabled = {}\n\n", .{config.banner_enabled orelse true});

    try writer.writeAll(
        \\# Visual presentation style of the banner.
        \\# Supported values:
        \\#   floating  - Compact 3-row floating card with rounded corners
        \\#   docked    - Spans the viewport top or bottom edge with configurable margins
        \\# Default: floating
        \\
    );
    const banner_style_str = if (config.banner_style) |st| switch (st) {
        .floating => "floating",
        .docked => "docked",
    } else "floating";
    try writer.print("style = {s}\n\n", .{banner_style_str});

    try writer.writeAll(
        \\# Screen anchor position for the banner.
        \\# Supported values: top_center, top_right, top_left
        \\# Default: top_center
        \\
    );
    const banner_pos_str = if (config.banner_position) |pos| switch (pos) {
        .top_center => "top_center",
        .top_right => "top_right",
        .top_left => "top_left",
    } else "top_center";
    try writer.print("position = {s}\n\n", .{banner_pos_str});

    try writer.writeAll(
        \\# Border stroke color styling.
        \\# Supported values:
        \\#   semantic  - Border tinted by diagnostic severity (error: red, warning: yellow, info: cyan)
        \\#   subtle    - Low-contrast neutral border
        \\# Default: semantic
        \\
    );
    const banner_bs_str = if (config.banner_border_style) |bs| switch (bs) {
        .semantic => "semantic",
        .subtle => "subtle",
    } else "semantic";
    try writer.print("border_style = {s}\n\n", .{banner_bs_str});

    try writer.writeAll(
        \\# Corner rounding radius for the banner card in pixels (applied to both floating and docked).
        \\# Supported values: float >= 0.0 (0.0 for square corners)
        \\# Default: 8.0
        \\
    );
    try writer.print("corner_radius = {d:.1}\n\n", .{config.banner_corner_radius orelse 8.0});

    try writer.writeAll(
        \\# Border stroke thickness in screen pixels.
        \\# Supported values: float >= 0.0
        \\# Default: 1.0
        \\
    );
    try writer.print("border_width = {d:.1}\n\n", .{config.banner_border_width orelse 1.0});

    try writer.writeAll(
        \\# Minimum banner width in character columns.
        \\# Supported values: positive integer
        \\# Default: 36
        \\
    );
    try writer.print("min_width = {d}\n\n", .{config.banner_min_width orelse 36});

    try writer.writeAll(
        \\# Maximum banner width in character columns (text auto-ellipsizes to fit).
        \\# Supported values: positive integer
        \\# Default: 72
        \\
    );
    try writer.print("max_width = {d}\n\n", .{config.banner_max_width orelse 72});

    try writer.writeAll(
        \\# Horizontal margin in columns from screen boundaries.
        \\# Supported values: integer >= 0
        \\# Default: 2
        \\
    );
    try writer.print("margin_cols = {d}\n\n", .{config.banner_margin_cols orelse 2});

    try writer.writeAll(
        \\# Vertical margin in rows from screen boundaries (in docked style, 0 aligns flush against the edge).
        \\# Supported values: integer >= 0
        \\# Default: 1
        \\
    );
    try writer.print("margin_rows = {d}\n\n", .{config.banner_margin_rows orelse 1});

    try writer.writeAll(
        \\# ==============================================================================
        \\# Modal Dialogs ([modal])
        \\# ==============================================================================
        \\[modal]
        \\
        \\# Width of centered modal dialogs (e.g. quit confirmation) in character columns.
        \\# Supported values: integer >= 20
        \\# Default: 46
        \\
    );
    try writer.print("width = {d}\n\n", .{config.modal_width orelse 46});

    try writer.writeAll(
        \\# Opacity of the background dimming veil behind modal dialogs.
        \\# Supported values: integer from 0 (completely clear) to 255 (solid black overlay)
        \\# Default: 180
        \\
    );
    try writer.print("dim_alpha = {d}\n\n", .{config.modal_dim_alpha orelse 180});

    try writer.writeAll(
        \\# Progressive multi-scale Dual Kawase blur pass behind active modal dialogs.
        \\# Supported values: true, false, on, off
        \\# Default: false
        \\
    );
    try writer.print("blur = {}\n\n", .{config.modal_blur orelse false});

    try writer.writeAll(
        \\# Blur radius offset applied to the multi-scale downsampling and upsampling pyramid.
        \\# Supported values: integer from 0 (finest smooth blur) to 16
        \\# Default: 12
        \\
    );
    try writer.print("blur_radius = {d}\n\n", .{config.modal_blur_radius orelse 12});

    try writer.writeAll(
        \\# Dismiss the modal and cancel the prompt when clicking outside the dialog card.
        \\# Supported values: true, false, on, off
        \\# Default: true
        \\
    );
    try writer.print("close_on_outside_click = {}\n\n", .{config.modal_close_on_outside_click orelse true});

    try writer.writeAll(
        \\# Initial button focus when the modal dialog is opened.
        \\# Supported values:
        \\#   confirm  - Primary confirm button (Enter triggers action)
        \\#   cancel   - Secondary abort button (Esc or Enter aborts action)
        \\# Default: confirm
        \\
    );
    const modal_focus_str = if (config.modal_default_focus) |df| switch (df) {
        .confirm => "confirm",
        .cancel => "cancel",
    } else "confirm";
    try writer.print("default_focus = {s}\n\n", .{modal_focus_str});

    try writer.writeAll(
        \\# Modal dialog border color styling (inherits [card] border_style if omitted).
        \\# Supported values: semantic, subtle
        \\# Default: semantic
        \\
    );
    const modal_bs_str = if (config.modal_border_style) |bs| switch (bs) {
        .semantic => "semantic",
        .subtle => "subtle",
    } else "semantic";
    try writer.print("border_style = {s}\n\n", .{modal_bs_str});

    try writer.writeAll(
        \\# ==============================================================================
        \\# Digital Wellbeing & Ergonomics ([wellbeing])
        \\# ==============================================================================
        \\# Tracks active typing and terminal engagement, manages Pomodoro focus sessions,
        \\# and surfaces health/ergonomic reminders (20-20-20 eyesight rule, posture, movement).
        \\[wellbeing]
        \\
        \\# Enable or disable the Digital Wellbeing subsystem.
        \\# Supported values: true, false, on, off
        \\# Default: true
        \\
    );
    try writer.print("enabled = {}\n\n", .{config.wellbeing_enabled orelse true});

    try writer.writeAll(
        \\# Cumulative daily active screen-time threshold before notifications suggest rest.
        \\# Supported units: m (minutes), h (hours)
        \\# Supported values: e.g. 8h, 480m
        \\# Default: 8h
        \\
    );
    if (config.wellbeing_daily_limit_minutes) |dl| {
        if (dl % 60 == 0) {
            try writer.print("daily_limit = {d}h\n\n", .{dl / 60});
        } else {
            try writer.print("daily_limit = {d}m\n\n", .{dl});
        }
    } else {
        try writer.writeAll("daily_limit = 8h\n\n");
    }

    try writer.writeAll(
        \\# Inactivity timeout before terminal pauses screen-time accumulation.
        \\# Supported units: s (seconds), m (minutes)
        \\# Supported values: e.g. 60s, 2m
        \\# Default: 60s
        \\
    );
    if (config.wellbeing_idle_threshold_s) |it| {
        if (it % 60 == 0) {
            try writer.print("idle_threshold = {d}m\n\n", .{it / 60});
        } else {
            try writer.print("idle_threshold = {d}s\n\n", .{it});
        }
    } else {
        try writer.writeAll("idle_threshold = 60s\n\n");
    }

    try writer.writeAll(
        \\# Pomodoro active focus interval duration.
        \\# Supported units: ms, s, m, h
        \\# Supported values: e.g. 25m, 1500s
        \\# Default: 25m
        \\
    );
    if (config.wellbeing_focus_task_ms) |ft| {
        if (ft % 60000 == 0) {
            try writer.print("focus_time = {d}m\n\n", .{ft / 60000});
        } else if (ft % 1000 == 0) {
            try writer.print("focus_time = {d}s\n\n", .{ft / 1000});
        } else {
            try writer.print("focus_time = {d}ms\n\n", .{ft});
        }
    } else {
        try writer.writeAll("focus_time = 25m\n\n");
    }

    try writer.writeAll(
        \\# Short rest break duration between focus tasks.
        \\# Supported units: ms, s, m, h
        \\# Supported values: e.g. 5m, 300s
        \\# Default: 5m
        \\
    );
    if (config.wellbeing_focus_short_break_ms) |sb| {
        if (sb % 60000 == 0) {
            try writer.print("short_break = {d}m\n\n", .{sb / 60000});
        } else if (sb % 1000 == 0) {
            try writer.print("short_break = {d}s\n\n", .{sb / 1000});
        } else {
            try writer.print("short_break = {d}ms\n\n", .{sb});
        }
    } else {
        try writer.writeAll("short_break = 5m\n\n");
    }

    try writer.writeAll(
        \\# Extended long rest break duration after completing a set of focus tasks.
        \\# Supported units: ms, s, m, h
        \\# Supported values: e.g. 15m, 900s
        \\# Default: 15m
        \\
    );
    if (config.wellbeing_focus_long_break_ms) |lb| {
        if (lb % 60000 == 0) {
            try writer.print("long_break = {d}m\n\n", .{lb / 60000});
        } else if (lb % 1000 == 0) {
            try writer.print("long_break = {d}s\n\n", .{lb / 1000});
        } else {
            try writer.print("long_break = {d}ms\n\n", .{lb});
        }
    } else {
        try writer.writeAll("long_break = 15m\n\n");
    }

    try writer.writeAll(
        \\# Number of completed focus tasks required before triggering a long break.
        \\# Supported values: positive integer (1 to 255)
        \\# Default: 4
        \\
    );
    try writer.print("tasks_before_long_break = {d}\n\n", .{config.wellbeing_tasks_before_long_break orelse 4});

    try writer.writeAll(
        \\# Temporarily lock terminal input during active break countdowns to encourage stepping away.
        \\# Supported values: true, false
        \\# Default: false
        \\
    );
    try writer.print("lock_input_on_break = {}\n\n", .{config.wellbeing_lock_input_on_break orelse false});

    try writer.writeAll(
        \\# Display relaxing breathing / break wave animation during rest intervals.
        \\# Supported values: true, false
        \\# Default: true
        \\
    );
    try writer.print("show_break_animation = {}\n\n", .{config.wellbeing_show_break_animation orelse true});

    try writer.writeAll(
        \\# Suppress non-critical notifications while a focus sprint is running.
        \\# Supported values: true, false
        \\# Default: false
        \\
    );
    try writer.print("mute_notifications_in_task = {}\n\n", .{config.wellbeing_mute_notifications_in_task orelse false});

    try writer.writeAll(
        \\# 20-20-20 rule eye rest reminder interval (look 20 feet away for 20 seconds).
        \\# Supported units: m, h (e.g. 20m)
        \\# Default: 20m
        \\
    );
    if (config.wellbeing_eyesight_interval_minutes) |em| {
        if (em % 60 == 0) {
            try writer.print("eyesight_interval = {d}h\n\n", .{em / 60});
        } else {
            try writer.print("eyesight_interval = {d}m\n\n", .{em});
        }
    } else {
        try writer.writeAll("eyesight_interval = 20m\n\n");
    }

    try writer.writeAll(
        \\# Movement / stand-up reminder interval.
        \\# Supported units: m, h (e.g. 60m, 1h)
        \\# Default: 60m
        \\
    );
    if (config.wellbeing_movement_interval_minutes) |mm| {
        if (mm % 60 == 0) {
            try writer.print("movement_interval = {d}h\n\n", .{mm / 60});
        } else {
            try writer.print("movement_interval = {d}m\n\n", .{mm});
        }
    } else {
        try writer.writeAll("movement_interval = 60m\n\n");
    }

    try writer.writeAll(
        \\# Water / hydration reminder interval.
        \\# Supported units: m, h (e.g. 45m)
        \\# Default: 45m
        \\
    );
    if (config.wellbeing_hydration_interval_minutes) |hm| {
        if (hm % 60 == 0) {
            try writer.print("hydration_interval = {d}h\n\n", .{hm / 60});
        } else {
            try writer.print("hydration_interval = {d}m\n\n", .{hm});
        }
    } else {
        try writer.writeAll("hydration_interval = 45m\n\n");
    }

    try writer.writeAll(
        \\# Ergonomic posture check reminder interval.
        \\# Supported units: m, h (e.g. 30m)
        \\# Default: 30m
        \\
    );
    if (config.wellbeing_posture_interval_minutes) |pm| {
        if (pm % 60 == 0) {
            try writer.print("posture_interval = {d}h\n\n", .{pm / 60});
        } else {
            try writer.print("posture_interval = {d}m\n\n", .{pm});
        }
    } else {
        try writer.writeAll("posture_interval = 30m\n\n");
    }

    try writer.writeAll(
        \\# ==============================================================================
        \\# Scrolling ([scroll])
        \\# ==============================================================================
        \\[scroll]
        \\
        \\# Lines to scroll per scroll_up or scroll_down keybinding invocation.
        \\# Supported values: positive integer
        \\# Default: 3
        \\
    );
    try writer.print("lines = {d}\n\n", .{config.scroll_lines orelse 3});

    try writer.writeAll(
        \\# Lines to scroll per mouse scroll wheel notch / event.
        \\# Supported values: positive integer
        \\# Default: 3
        \\
    );
    try writer.print("wheel_lines = {d}\n\n", .{config.scroll_wheel_lines orelse 3});

    try writer.writeAll(
        \\# ==============================================================================
        \\# Keybindings ([keybinds])
        \\# ==============================================================================
        \\# Syntax: <modifiers>+<key> = <action>
        \\#
        \\# Supported Modifiers:
        \\#   ctrl (control), shift, alt (opt, option), super (cmd, command, win, windows)
        \\#
        \\# Supported Keys:
        \\#   Letters: a..z
        \\#   Numbers: 0..9
        \\#   Function keys: f1..f25
        \\#   Punctuation / Symbols: minus (-), plus / equal (=, +), left_bracket ([), right_bracket (]),
        \\#                          backslash (\), semicolon (;), apostrophe ('), comma (,), period (.),
        \\#                          slash (/), grave (`)
        \\#   Navigation & Editing: space, enter (return), tab, backspace, escape (esc), delete (del),
        \\#                         insert (ins), home, end, page_up (pgup), page_down (pgdown),
        \\#                         up, down, left, right
        \\#
        \\# Supported Actions:
        \\#   Window & Clipboard:
        \\#     copy_selection          - Copy active visual selection to system clipboard
        \\#     paste_clipboard         - Paste system clipboard contents into terminal stdin
        \\#     new_window              - Open a new terminal window
        \\#     quit                    - Terminate Rex window session (prompts if confirm_quit = true)
        \\#
        \\#   Font Zoom:
        \\#     increase_font_size      - Increase font size by font_size_step
        \\#     decrease_font_size      - Decrease font size by font_size_step
        \\#     reset_font_size         - Reset font size to default configured size
        \\#
        \\#   Viewport Scrolling:
        \\#     scroll_up               - Scroll viewport upward by scroll.lines
        \\#     scroll_down             - Scroll viewport downward by scroll.lines
        \\#
        \\#   Configuration & System:
        \\#     reload_config           - Hot-reload configuration from disk without dropping session
        \\#     debug                   - Toggle diagnostic HUD overlay
        \\#
        \\#   Digital Wellbeing & Focus:
        \\#     wellbeing_dashboard     - Toggle interactive wellbeing dashboard overlay
        \\#     wellbeing_dismiss       - Dismiss active wellbeing reminder notification
        \\#     wellbeing_clear         - Purge recorded wellbeing daily activity history
        \\#     wellbeing_toast_toggle  - Toggle wellbeing toast reminders on/off
        \\#     focus_toggle            - Start or pause the current Pomodoro focus timer
        \\#     focus_reset             - Reset current Pomodoro interval to start
        \\#     focus_skip              - Advance to the next task or break immediately
        \\#     focus_auto_transition   - Toggle automatic cycling between tasks and breaks
        \\#
        \\#   Toast Notifications:
        \\#     toast_dismiss           - Dismiss topmost toast notification
        \\#     toast_activate          - Trigger primary action on the active toast
        \\#
        \\[keybinds]
        \\
    );

    if (config.keybindings_specified and config.keybindings_count > 0) {
        var line_buf: [128]u8 = undefined;
        for (config.keybindings[0..config.keybindings_count]) |b| {
            const line = keymap_parser.formatBinding(b, &line_buf);
            if (line.len > 0) {
                try writer.print("{s}\n", .{line});
            }
        }
    } else {
        try writer.writeAll(
            \\ctrl+shift+w = wellbeing_dashboard
            \\ctrl+shift+d = wellbeing_dismiss
            \\ctrl+shift+p = focus_toggle
            \\ctrl+shift+r = reload_config
            \\ctrl+0 = reset_font_size
            \\ctrl+plus = increase_font_size
            \\ctrl+minus = decrease_font_size
            \\
        );
    }
}

/// Minimal unbuffered writer on a POSIX file descriptor, for stdout and
/// config files. A reader that closed the pipe early (`rex ... | head`)
/// is `error.BrokenPipe`; every other failed write is `error.WriteFailed`.
pub const FdWriter = struct {
    fd: std.posix.fd_t,

    pub const Error = error{ BrokenPipe, WriteFailed };

    pub fn writeAll(self: @This(), bytes: []const u8) Error!void {
        var written: usize = 0;
        while (written < bytes.len) {
            const rc = std.posix.system.write(self.fd, bytes[written..].ptr, bytes[written..].len);
            switch (std.posix.errno(rc)) {
                .SUCCESS => {
                    if (rc == 0) return error.WriteFailed;
                    written += @intCast(rc);
                },
                .INTR => continue,
                .PIPE => return error.BrokenPipe,
                else => return error.WriteFailed,
            }
        }
    }

    pub fn print(self: @This(), comptime fmt: []const u8, args: anytype) !void {
        var buf: [1024]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf, fmt, args);
        try self.writeAll(msg);
    }
};

fn makePathPosix(path: []const u8) void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if (path.len >= buf.len) return;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;

    var i: usize = 1;
    while (i <= path.len) : (i += 1) {
        if (i == path.len or buf[i] == '/') {
            const save = buf[i];
            buf[i] = 0;
            _ = std.c.mkdir(buf[0..i :0], 0o755);
            buf[i] = save;
        }
    }
}

/// Serializes a FileConfig and writes it directly to the designated file path on disk.
pub fn writeConfigFile(path: []const u8, config: *const FileConfig) !void {
    if (std.fs.path.dirname(path)) |parent| {
        if (parent.len > 0) {
            makePathPosix(parent);
        }
    }

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (path.len >= path_buf.len) return error.NameTooLong;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;

    const fd = try std.posix.openat(
        std.posix.AT.FDCWD,
        path_buf[0..path.len :0],
        .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true },
        0o644,
    );
    defer _ = std.posix.system.close(fd);

    const fw = FdWriter{ .fd = fd };
    try serializeConfig(config, fw);
}

/// Merges two configuration files and writes the combined configuration to an output file or writer.
pub fn mergeFiles(
    base_path: []const u8,
    override_path: []const u8,
    out_path: ?[]const u8,
    writer: anytype,
    diags: *Diagnostics,
) !bool {
    var base_cfg = FileConfig{};
    const base_loaded = try loadFile(base_path, &base_cfg, diags);
    if (!base_loaded) return false;

    var override_cfg = FileConfig{};
    const override_loaded = try loadFile(override_path, &override_cfg, diags);
    if (!override_loaded) return false;

    mergeFileConfigs(&base_cfg, &override_cfg);

    if (out_path) |op| {
        try writeConfigFile(op, &base_cfg);
        try writer.print("Merged configuration written to: {s}\n", .{op});
    } else {
        try serializeConfig(&base_cfg, writer);
    }
    return true;
}

/// Migrates the configuration file at `src_path` by populating the
/// canonical default template with its values.
pub fn migrateConfigFile(
    src_path: []const u8,
    out_path: ?[]const u8,
    in_place: bool,
    writer: anytype,
    diags: *Diagnostics,
) !bool {
    const resolved_src_path = src_path;

    var canonical_cfg = FileConfig{};
    var dump_diags = Diagnostics{};
    var p = Parser.init(canonical_default_config);
    p.parseInto(&canonical_cfg, &dump_diags);

    var user_cfg = FileConfig{};
    const loaded = try loadFile(resolved_src_path, &user_cfg, diags);
    if (!loaded) return false;

    mergeFileConfigs(&canonical_cfg, &user_cfg);

    if (in_place) {
        try writeConfigFile(resolved_src_path, &canonical_cfg);
        try writer.print("Successfully migrated configuration in-place: {s}\n", .{resolved_src_path});
    } else if (out_path) |op| {
        try writeConfigFile(op, &canonical_cfg);
        try writer.print("Successfully migrated configuration to: {s}\n", .{op});
    } else {
        try serializeConfig(&canonical_cfg, writer);
    }
    return true;
}
