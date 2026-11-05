//! Single-pass zero-allocation parser for Rex configuration files.
//!
//! Converts lexical tokens into typed configurations, coercing units,
//! colors, and enumerations directly into memory.

const std = @import("std");
const types = @import("types.zig");
const FileConfig = types.FileConfig;
const Section = types.Section;
const Diagnostics = types.Diagnostics;
const lexer_mod = @import("lexer.zig");
const Lexer = lexer_mod.Lexer;
const keymap_parser = @import("keymap_parser.zig");
const Theme = @import("../color/Theme.zig");
const Card = @import("../renderer/Card.zig");
const Toast = @import("../ui/Toast.zig");
const Modal = @import("../ui/Modal.zig");

/// Parses boolean values from common text representations.
pub fn parseBool(str: []const u8) ?bool {
    if (std.ascii.eqlIgnoreCase(str, "true") or std.ascii.eqlIgnoreCase(str, "yes") or std.ascii.eqlIgnoreCase(str, "on") or std.mem.eql(u8, str, "1")) {
        return true;
    }
    if (std.ascii.eqlIgnoreCase(str, "false") or std.ascii.eqlIgnoreCase(str, "no") or std.ascii.eqlIgnoreCase(str, "off") or std.mem.eql(u8, str, "0")) {
        return false;
    }
    return null;
}

/// Parses duration strings with unit suffixes (ms, s, m, h) into milliseconds.
pub fn parseDurationMs(str: []const u8) ?u32 {
    const trimmed = std.mem.trim(u8, str, " \t");
    if (trimmed.len == 0) return null;

    if (std.mem.endsWith(u8, trimmed, "ms")) {
        const val = std.fmt.parseInt(u32, trimmed[0 .. trimmed.len - 2], 10) catch return null;
        return val;
    }
    if (std.mem.endsWith(u8, trimmed, "s")) {
        const val = std.fmt.parseInt(u32, trimmed[0 .. trimmed.len - 1], 10) catch return null;
        return val * 1000;
    }
    if (std.mem.endsWith(u8, trimmed, "m")) {
        const val = std.fmt.parseInt(u32, trimmed[0 .. trimmed.len - 1], 10) catch return null;
        return val * 60 * 1000;
    }
    if (std.mem.endsWith(u8, trimmed, "h")) {
        const val = std.fmt.parseInt(u32, trimmed[0 .. trimmed.len - 1], 10) catch return null;
        return val * 3600 * 1000;
    }

    // Bare number defaults to milliseconds
    return std.fmt.parseInt(u32, trimmed, 10) catch null;
}

/// Parses duration strings with unit suffixes into minutes.
pub fn parseDurationMinutes(str: []const u8) ?u32 {
    const trimmed = std.mem.trim(u8, str, " \t");
    if (trimmed.len == 0) return null;

    if (std.mem.endsWith(u8, trimmed, "h")) {
        const val = std.fmt.parseInt(u32, trimmed[0 .. trimmed.len - 1], 10) catch return null;
        return val * 60;
    }
    if (std.mem.endsWith(u8, trimmed, "m")) {
        return std.fmt.parseInt(u32, trimmed[0 .. trimmed.len - 1], 10) catch null;
    }
    if (std.mem.endsWith(u8, trimmed, "s")) {
        const val = std.fmt.parseInt(u32, trimmed[0 .. trimmed.len - 1], 10) catch return null;
        return val / 60;
    }
    return std.fmt.parseInt(u32, trimmed, 10) catch null;
}

/// Parses duration strings with unit suffixes into seconds.
pub fn parseDurationSeconds(str: []const u8) ?u32 {
    const trimmed = std.mem.trim(u8, str, " \t");
    if (trimmed.len == 0) return null;

    if (std.mem.endsWith(u8, trimmed, "s") and !std.mem.endsWith(u8, trimmed, "ms")) {
        return std.fmt.parseInt(u32, trimmed[0 .. trimmed.len - 1], 10) catch null;
    }
    if (std.mem.endsWith(u8, trimmed, "m")) {
        const val = std.fmt.parseInt(u32, trimmed[0 .. trimmed.len - 1], 10) catch return null;
        return val * 60;
    }
    if (std.mem.endsWith(u8, trimmed, "h")) {
        const val = std.fmt.parseInt(u32, trimmed[0 .. trimmed.len - 1], 10) catch return null;
        return val * 3600;
    }
    return std.fmt.parseInt(u32, trimmed, 10) catch null;
}

/// Normalizes key names by stripping dashes and underscores for case-insensitive matching.
fn matchKey(key: []const u8, comptime target: []const u8) bool {
    var ki: usize = 0;
    var ti: usize = 0;

    while (ki < key.len and ti < target.len) {
        const kc = key[ki];
        const tc = target[ti];

        if (kc == '-' or kc == '_') {
            ki += 1;
            continue;
        }
        if (tc == '-' or tc == '_') {
            ti += 1;
            continue;
        }

        if (std.ascii.toLower(kc) != std.ascii.toLower(tc)) return false;
        ki += 1;
        ti += 1;
    }

    while (ki < key.len and (key[ki] == '-' or key[ki] == '_')) ki += 1;
    while (ti < target.len and (target[ti] == '-' or target[ti] == '_')) ti += 1;

    return ki == key.len and ti == target.len;
}

/// Configuration parser managing linear streaming passes over source text.
pub const Parser = struct {
    lexer: Lexer,

    pub fn init(source: []const u8) Parser {
        return .{
            .lexer = Lexer.init(source),
        };
    }

    /// Parses tokens from the source into the destination FileConfig structure.
    pub fn parseInto(self: *Parser, config: *FileConfig, diags: *Diagnostics) void {
        var current_section: Section = .root;

        while (true) {
            const tok = self.lexer.next();
            switch (tok.kind) {
                .eof => break,
                .section => {
                    if (Section.fromString(tok.key)) |sec| {
                        current_section = sec;
                    } else {
                        diags.warn(tok.line, tok.col, "unknown section header '[{s}]'", .{tok.key});
                    }
                },
                .key_value => {
                    self.applyKeyValue(config, current_section, tok.key, tok.value, tok.line, tok.col, diags);
                },
                .invalid => {
                    diags.err(tok.line, tok.col, "{s}", .{tok.key});
                },
            }
        }
    }

    fn applyKeyValue(
        self: *Parser,
        config: *FileConfig,
        section: Section,
        raw_key: []const u8,
        val: []const u8,
        line: usize,
        col: usize,
        diags: *Diagnostics,
    ) void {
        var effective_section = section;
        var key = raw_key;

        // Support dot notation: e.g. "card.corner-radius" or "window.dim-alpha"
        if (std.mem.indexOfScalar(u8, raw_key, '.')) |dot_idx| {
            const sec_str = raw_key[0..dot_idx];
            if (Section.fromString(sec_str)) |sec| {
                effective_section = sec;
                key = raw_key[dot_idx + 1 ..];
            }
        }

        switch (effective_section) {
            .root => {
                if (matchKey(key, "theme")) {
                    config.theme = parseTheme(val) orelse {
                        diags.warn(line, col, "unknown theme '{s}'", .{val});
                        return;
                    };
                } else if (matchKey(key, "font-family") or matchKey(key, "font")) {
                    copyString(&config.font_family, &config.font_family_len, val);
                } else if (matchKey(key, "font-size")) {
                    config.font_size = std.fmt.parseFloat(f32, val) catch {
                        diags.warn(line, col, "invalid font size '{s}'", .{val});
                        return;
                    };
                } else if (matchKey(key, "font-weight")) {
                    config.font_weight = std.fmt.parseInt(u16, val, 10) catch {
                        diags.warn(line, col, "invalid font weight '{s}'", .{val});
                        return;
                    };
                } else if (matchKey(key, "font-weight-bold")) {
                    config.font_weight_bold = std.fmt.parseInt(u16, val, 10) catch {
                        diags.warn(line, col, "invalid bold font weight '{s}'", .{val});
                        return;
                    };
                } else {
                    // Try parsing as window key fallback
                    self.applyWindowKey(config, key, val, line, col, diags);
                }
            },
            .window => self.applyWindowKey(config, key, val, line, col, diags),
            .font => {
                if (matchKey(key, "family") or matchKey(key, "font-family") or matchKey(key, "file")) {
                    copyString(&config.font_family, &config.font_family_len, val);
                } else if (matchKey(key, "size")) {
                    config.font_size = std.fmt.parseFloat(f32, val) catch {
                        diags.warn(line, col, "invalid font size '{s}'", .{val});
                        return;
                    };
                } else if (matchKey(key, "weight")) {
                    config.font_weight = std.fmt.parseInt(u16, val, 10) catch {
                        diags.warn(line, col, "invalid font weight '{s}'", .{val});
                        return;
                    };
                } else if (matchKey(key, "weight-bold") or matchKey(key, "bold-weight")) {
                    config.font_weight_bold = std.fmt.parseInt(u16, val, 10) catch {
                        diags.warn(line, col, "invalid bold font weight '{s}'", .{val});
                        return;
                    };
                } else {
                    diags.warn(line, col, "unknown font option '{s}'", .{key});
                }
            },
            .card => {
                if (matchKey(key, "corner-radius") or matchKey(key, "radius")) {
                    config.card_corner_radius = std.fmt.parseFloat(f32, val) catch {
                        diags.warn(line, col, "invalid card corner radius '{s}'", .{val});
                        return;
                    };
                } else if (matchKey(key, "border-width") or matchKey(key, "width")) {
                    config.card_border_width = std.fmt.parseFloat(f32, val) catch {
                        diags.warn(line, col, "invalid card border width '{s}'", .{val});
                        return;
                    };
                } else if (matchKey(key, "border-shape") or matchKey(key, "shape")) {
                    if (std.ascii.eqlIgnoreCase(val, "rounded")) {
                        config.card_border_shape = .rounded;
                    } else if (std.ascii.eqlIgnoreCase(val, "sharp")) {
                        config.card_border_shape = .sharp;
                    } else {
                        diags.warn(line, col, "unknown card border shape '{s}' (expected 'rounded' or 'sharp')", .{val});
                    }
                } else {
                    diags.warn(line, col, "unknown card option '{s}'", .{key});
                }
            },
            .toast => {
                if (matchKey(key, "enabled")) {
                    config.toast_enabled = parseBool(val) orelse {
                        diags.warn(line, col, "invalid boolean '{s}' for toast.enabled", .{val});
                        return;
                    };
                } else if (matchKey(key, "position")) {
                    if (std.ascii.eqlIgnoreCase(val, "top-right") or std.ascii.eqlIgnoreCase(val, "top_right")) {
                        config.toast_position = .top_right;
                    } else if (std.ascii.eqlIgnoreCase(val, "top-center") or std.ascii.eqlIgnoreCase(val, "top_center")) {
                        config.toast_position = .top_center;
                    } else if (std.ascii.eqlIgnoreCase(val, "bottom-right") or std.ascii.eqlIgnoreCase(val, "bottom_right")) {
                        config.toast_position = .bottom_right;
                    } else {
                        diags.warn(line, col, "unknown toast position '{s}'", .{val});
                    }
                } else if (matchKey(key, "border-style")) {
                    if (std.ascii.eqlIgnoreCase(val, "semantic")) {
                        config.toast_border_style = .semantic;
                    } else if (std.ascii.eqlIgnoreCase(val, "subtle")) {
                        config.toast_border_style = .subtle;
                    } else {
                        diags.warn(line, col, "unknown toast border style '{s}'", .{val});
                    }
                } else if (matchKey(key, "duration")) {
                    config.toast_duration_ms = parseDurationMs(val) orelse {
                        diags.warn(line, col, "invalid toast duration '{s}'", .{val});
                        return;
                    };
                } else if (matchKey(key, "min-width")) {
                    config.toast_min_width = std.fmt.parseInt(u16, val, 10) catch null;
                } else if (matchKey(key, "max-width")) {
                    config.toast_max_width = std.fmt.parseInt(u16, val, 10) catch null;
                } else {
                    diags.warn(line, col, "unknown toast option '{s}'", .{key});
                }
            },
            .modal => {
                if (matchKey(key, "width")) {
                    config.modal_width = std.fmt.parseInt(u16, val, 10) catch {
                        diags.warn(line, col, "invalid modal width '{s}'", .{val});
                        return;
                    };
                } else if (matchKey(key, "dim-alpha")) {
                    config.modal_dim_alpha = std.fmt.parseInt(u8, val, 10) catch {
                        diags.warn(line, col, "invalid modal dim alpha '{s}'", .{val});
                        return;
                    };
                } else if (matchKey(key, "close-on-outside-click")) {
                    config.modal_close_on_outside_click = parseBool(val) orelse {
                        diags.warn(line, col, "invalid boolean for modal close-on-outside-click", .{});
                        return;
                    };
                } else if (matchKey(key, "default-focus")) {
                    if (std.ascii.eqlIgnoreCase(val, "confirm")) {
                        config.modal_default_focus = .confirm;
                    } else if (std.ascii.eqlIgnoreCase(val, "cancel")) {
                        config.modal_default_focus = .cancel;
                    } else {
                        diags.warn(line, col, "invalid default focus '{s}' (expected 'confirm' or 'cancel')", .{val});
                    }
                } else {
                    diags.warn(line, col, "unknown modal option '{s}'", .{key});
                }
            },
            .wellbeing => {
                if (matchKey(key, "enabled")) {
                    config.wellbeing_enabled = parseBool(val);
                } else if (matchKey(key, "daily-limit")) {
                    config.wellbeing_daily_limit_minutes = parseDurationMinutes(val);
                } else if (matchKey(key, "idle-threshold")) {
                    config.wellbeing_idle_threshold_s = parseDurationSeconds(val);
                } else if (matchKey(key, "focus-time") or matchKey(key, "task-time")) {
                    config.wellbeing_focus_task_ms = parseDurationMs(val);
                } else if (matchKey(key, "short-break")) {
                    config.wellbeing_focus_short_break_ms = parseDurationMs(val);
                } else if (matchKey(key, "long-break")) {
                    config.wellbeing_focus_long_break_ms = parseDurationMs(val);
                } else if (matchKey(key, "tasks-before-long-break")) {
                    config.wellbeing_tasks_before_long_break = std.fmt.parseInt(u32, val, 10) catch null;
                } else if (matchKey(key, "lock-input-on-break")) {
                    config.wellbeing_lock_input_on_break = parseBool(val);
                } else if (matchKey(key, "show-break-animation")) {
                    config.wellbeing_show_break_animation = parseBool(val);
                } else if (matchKey(key, "mute-notifications-in-task")) {
                    config.wellbeing_mute_notifications_in_task = parseBool(val);
                } else if (matchKey(key, "eyesight-interval")) {
                    config.wellbeing_eyesight_interval_minutes = parseDurationMinutes(val);
                } else if (matchKey(key, "movement-interval")) {
                    config.wellbeing_movement_interval_minutes = parseDurationMinutes(val);
                } else if (matchKey(key, "hydration-interval")) {
                    config.wellbeing_hydration_interval_minutes = parseDurationMinutes(val);
                } else if (matchKey(key, "posture-interval")) {
                    config.wellbeing_posture_interval_minutes = parseDurationMinutes(val);
                } else {
                    diags.warn(line, col, "unknown wellbeing option '{s}'", .{key});
                }
            },
            .scroll => {
                if (matchKey(key, "lines")) {
                    config.scroll_lines = std.fmt.parseInt(u32, val, 10) catch null;
                } else if (matchKey(key, "wheel-lines")) {
                    config.scroll_wheel_lines = std.fmt.parseInt(u32, val, 10) catch null;
                } else {
                    diags.warn(line, col, "unknown scroll option '{s}'", .{key});
                }
            },
            .keybinds => {
                config.keybindings_specified = true;
                if (keymap_parser.parseBinding(key, val)) |binding| {
                    if (config.keybindings_count < types.max_dynamic_keybindings) {
                        config.keybindings[config.keybindings_count] = binding;
                        config.keybindings_count += 1;
                    } else {
                        diags.warn(line, col, "exceeded maximum of {d} keybindings", .{types.max_dynamic_keybindings});
                    }
                } else {
                    diags.warn(line, col, "invalid keybinding '{s} = {s}'", .{ key, val });
                }
            },
        }
    }

    fn applyWindowKey(
        self: *Parser,
        config: *FileConfig,
        key: []const u8,
        val: []const u8,
        line: usize,
        col: usize,
        diags: *Diagnostics,
    ) void {
        _ = self;
        if (matchKey(key, "background-alpha") or matchKey(key, "opacity")) {
            config.window_background_alpha = std.fmt.parseFloat(f32, val) catch {
                diags.warn(line, col, "invalid background alpha '{s}'", .{val});
                return;
            };
        } else if (matchKey(key, "background-blur") or matchKey(key, "blur")) {
            config.window_background_blur = std.fmt.parseInt(u32, val, 10) catch {
                diags.warn(line, col, "invalid blur radius '{s}'", .{val});
                return;
            };
        } else if (matchKey(key, "confirm-quit")) {
            config.window_confirm_quit = parseBool(val) orelse {
                diags.warn(line, col, "invalid boolean for confirm-quit", .{});
                return;
            };
        } else if (matchKey(key, "dim-alpha")) {
            config.window_dim_alpha = std.fmt.parseFloat(f32, val) catch {
                diags.warn(line, col, "invalid dim alpha '{s}'", .{val});
                return;
            };
        } else if (matchKey(key, "bell")) {
            if (parseBool(val)) |b| {
                config.window_bell = if (b) .on else .off;
            } else {
                diags.warn(line, col, "invalid bell setting '{s}'", .{val});
            }
        } else if (matchKey(key, "bell-volume")) {
            config.window_bell_volume = std.fmt.parseInt(u8, val, 10) catch null;
        } else if (matchKey(key, "title")) {
            copyString(&config.window_title, &config.window_title_len, val);
        } else if (matchKey(key, "width")) {
            config.window_width = std.fmt.parseInt(u16, val, 10) catch null;
        } else if (matchKey(key, "height")) {
            config.window_height = std.fmt.parseInt(u16, val, 10) catch null;
        } else {
            diags.warn(line, col, "unknown window option '{s}'", .{key});
        }
    }
};

fn copyString(dest: *?[128]u8, dest_len: *usize, src: []const u8) void {
    var buf: [128]u8 = undefined;
    const len = @min(src.len, buf.len - 1);
    @memcpy(buf[0..len], src[0..len]);
    buf[len] = 0;
    dest.* = buf;
    dest_len.* = len;
}

pub fn parseTheme(str: []const u8) ?Theme {
    if (std.ascii.eqlIgnoreCase(str, "graphite")) return Theme.graphite;
    return null;
}
