//! Layered configuration merging and resolution for Rex.
//!
//! Applies settings across comptime defaults, system presets, user XDG config,
//! and explicit CLI flags in deterministic precedence order.

const std = @import("std");
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
const App = @import("../App.zig");

/// Maximum size in bytes read from a single configuration file.
pub const max_config_file_size = 64 * 1024;

/// System-wide configuration file location on POSIX systems.
pub const system_config_path = "/etc/rex/config";

/// Loads and parses a configuration file from the filesystem if present.
pub fn loadFile(path: []const u8, config: *FileConfig, diags: *Diagnostics) !bool {
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

/// Merges non-null fields from a FileConfig into an active App.Config struct.
pub fn applyFileConfig(target: *App.Config, file: *const FileConfig, allocator: Allocator) !void {
    // Theme
    if (file.theme) |t| target.theme = t;

    // Font properties
    if (file.font_size) |sz| {
        target.font.height = @intFromFloat(sz);
    }
    if (target.font.font.family == .variable) {
        if (file.font_weight) |w| target.font.font.family.variable.regular_weight = @floatFromInt(w);
        if (file.font_weight_bold) |wb| target.font.font.family.variable.bold_weight = @floatFromInt(wb);
        if (file.getFontFamily()) |fam| {
            const fam_z = try allocator.dupeZ(u8, fam);
            target.font.font.family.variable.upright = fam_z.ptr;
        }
    }

    // Window options
    if (file.window_background_alpha) |a| target.window.background.alpha = a;
    if (file.window_confirm_quit) |cq| target.window.confirm_quit = cq;
    if (file.window_dim_alpha) |da| target.window.dim_alpha = da;
    if (file.window_bell) |bell| target.window.bell = switch (bell) {
        .on => .on,
        .off => .off,
    };
    if (file.window_bell_volume) |vol| target.window.bell_volume = vol;
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
    if (file.banner_style) |st| target.window.banner.style = st;
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
    if (file.modal_dim_alpha) |da| target.window.modal.dim_alpha = da;
    if (file.modal_blur) |b| target.window.modal.blur = b;
    if (file.modal_blur_radius) |br| target.window.modal.blur_radius = br;
    if (file.modal_close_on_outside_click) |cl| target.window.modal.close_on_outside_click = cl;
    if (file.modal_default_focus) |df| target.window.modal.default_focus = df;
    if (file.modal_border_style) |mbs| target.window.modal.border_style = mbs;

    // Wellbeing options
    if (file.wellbeing_enabled) |en| target.wellbeing.enabled = en;
    if (file.wellbeing_daily_limit_minutes) |dl| target.wellbeing.screen_time.daily_limit_minutes = dl;
    if (file.wellbeing_idle_threshold_s) |it| target.wellbeing.screen_time.idle_threshold_s = it;
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

/// Dumps the canonical default configuration file with comments and descriptions.
pub fn dumpDefaultConfig(writer: anytype) !void {
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
        \\theme = graphite
        \\
        \\# Monospace font family or variable font file.
        \\# Supported values: any font family name or TTF/OTF path
        \\# Default: GoogleSansCode-VariableFont_MONO,wght.ttf
        \\# font_family = "GoogleSansCode-VariableFont_MONO,wght.ttf"
        \\
        \\# Font size in points.
        \\# Supported values: positive float (e.g. 10.0, 14.0, 18.0)
        \\# Default: 14.0
        \\font_size = 14.0
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
        \\#   semantic  - Border tinted by diagnostic severity (error: red, warning: yellow, info: accent)
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
        \\#     increase_font_size      - Increase font size by 1 point
        \\#     decrease_font_size      - Decrease font size by 1 point
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
    );
}
