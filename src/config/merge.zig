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

    // Toast options
    if (file.toast_enabled) |en| target.window.toast.enabled = en;
    if (file.toast_position) |pos| target.window.toast.position = pos;
    if (file.toast_border_style) |bs| target.window.toast.border_style = bs;
    if (file.toast_duration_ms) |dur| target.window.toast.duration_ms = dur;
    if (file.toast_min_width) |mw| target.window.toast.min_width = mw;
    if (file.toast_max_width) |mw| target.window.toast.max_width = mw;

    // Modal options
    if (file.modal_width) |w| target.window.modal.width = w;
    if (file.modal_dim_alpha) |da| target.window.modal.dim_alpha = da;
    if (file.modal_blur) |b| target.window.modal.blur = b;
    if (file.modal_blur_radius) |br| target.window.modal.blur_radius = br;
    if (file.modal_close_on_outside_click) |cl| target.window.modal.close_on_outside_click = cl;
    if (file.modal_default_focus) |df| target.window.modal.default_focus = df;

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
        \\# Rex Terminal Emulator Configuration
        \\
        \\# Theme & Appearance
        \\theme = graphite
        \\# font_family = "GoogleSansCode-VariableFont_MONO,wght.ttf"
        \\font_size = 14.0
        \\font_weight = 400
        \\font_weight_bold = 550
        \\
        \\[window]
        \\background_alpha = 0.95
        \\confirm_quit = true
        \\dim_alpha = 0.5
        \\bell = on
        \\bell_volume = 100
        \\
        \\[card]
        \\corner_radius = 8.0
        \\border_width = 1.0
        \\border_shape = rounded
        \\
        \\[toast]
        \\enabled = true
        \\position = top_right
        \\border_style = semantic
        \\duration = 5s
        \\
        \\[modal]
        \\width = 46
        \\dim_alpha = 180
        \\blur = false
        \\blur_radius = 12
        \\close_on_outside_click = true
        \\default_focus = confirm
        \\
        \\[wellbeing]
        \\enabled = true
        \\daily_limit = 8h
        \\focus_time = 25m
        \\short_break = 5m
        \\long_break = 15m
        \\tasks_before_long_break = 4
        \\lock_input_on_break = false
        \\
        \\[scroll]
        \\lines = 3
        \\wheel_lines = 3
        \\
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
