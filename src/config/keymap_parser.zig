//! Human-readable keybinding syntax parser for Rex configuration files.
//!
//! Translates strings like "ctrl+shift+w" and "wellbeing_dashboard" into
//! canonical input Key, Modifiers, and Action structures.

const std = @import("std");
const input = @import("../input.zig");
const Key = input.Key;
const Modifiers = input.Modifiers;
const Action = input.Action;
const Binding = input.Binding;

/// Parses a human-readable modifier and key string into Key and Modifiers.
pub fn parseKeyCombination(str: []const u8) ?struct { key: Key, mods: Modifiers } {
    var mods: Modifiers = .{};
    var iter = std.mem.splitScalar(u8, str, '+');
    var last_part: ?[]const u8 = null;

    while (iter.next()) |raw_part| {
        const part = std.mem.trim(u8, raw_part, " \t");
        if (part.len == 0) continue;

        if (std.ascii.eqlIgnoreCase(part, "ctrl") or std.ascii.eqlIgnoreCase(part, "control")) {
            mods.ctrl = true;
        } else if (std.ascii.eqlIgnoreCase(part, "shift")) {
            mods.shift = true;
        } else if (std.ascii.eqlIgnoreCase(part, "alt") or std.ascii.eqlIgnoreCase(part, "opt") or std.ascii.eqlIgnoreCase(part, "option")) {
            mods.alt = true;
        } else if (std.ascii.eqlIgnoreCase(part, "super") or std.ascii.eqlIgnoreCase(part, "cmd") or std.ascii.eqlIgnoreCase(part, "command") or std.ascii.eqlIgnoreCase(part, "win") or std.ascii.eqlIgnoreCase(part, "windows")) {
            mods.super = true;
        } else {
            last_part = part;
        }
    }

    const key_str = last_part orelse return null;
    const key = parseKey(key_str) orelse return null;
    return .{ .key = key, .mods = mods };
}

/// Parses a key name into a canonical Key enumeration value.
pub fn parseKey(str: []const u8) ?Key {
    // Single ASCII letters
    if (str.len == 1) {
        const c = std.ascii.toLower(str[0]);
        if (c >= 'a' and c <= 'z') {
            return @enumFromInt(@as(u16, @intFromEnum(Key.a)) + (c - 'a'));
        }
        if (c >= '0' and c <= '9') {
            return @enumFromInt(@as(u16, @intFromEnum(Key.num_0)) + (c - '0'));
        }
        return switch (c) {
            ' ' => .space,
            '-' => .minus,
            '=' => .equal,
            '+' => .equal,
            '[' => .left_bracket,
            ']' => .right_bracket,
            '\\' => .backslash,
            ';' => .semicolon,
            '\'' => .apostrophe,
            ',' => .comma,
            '.' => .period,
            '/' => .slash,
            '`' => .grave_accent,
            else => null,
        };
    }

    // Function keys (f1..f25)
    if ((str[0] == 'f' or str[0] == 'F') and str.len >= 2 and str.len <= 3) {
        const num = std.fmt.parseInt(u8, str[1..], 10) catch 0;
        if (num >= 1 and num <= 25) {
            return @enumFromInt(@as(u16, @intFromEnum(Key.f1)) + (num - 1));
        }
    }

    // Named special keys
    if (std.ascii.eqlIgnoreCase(str, "space")) return .space;
    if (std.ascii.eqlIgnoreCase(str, "enter") or std.ascii.eqlIgnoreCase(str, "return")) return .enter;
    if (std.ascii.eqlIgnoreCase(str, "tab")) return .tab;
    if (std.ascii.eqlIgnoreCase(str, "backspace")) return .backspace;
    if (std.ascii.eqlIgnoreCase(str, "escape") or std.ascii.eqlIgnoreCase(str, "esc")) return .escape;
    if (std.ascii.eqlIgnoreCase(str, "delete") or std.ascii.eqlIgnoreCase(str, "del")) return .delete;
    if (std.ascii.eqlIgnoreCase(str, "insert") or std.ascii.eqlIgnoreCase(str, "ins")) return .insert;
    if (std.ascii.eqlIgnoreCase(str, "home")) return .home;
    if (std.ascii.eqlIgnoreCase(str, "end")) return .end;
    if (std.ascii.eqlIgnoreCase(str, "page_up") or std.ascii.eqlIgnoreCase(str, "pageup") or std.ascii.eqlIgnoreCase(str, "pgup")) return .page_up;
    if (std.ascii.eqlIgnoreCase(str, "page_down") or std.ascii.eqlIgnoreCase(str, "pagedown") or std.ascii.eqlIgnoreCase(str, "pgdown")) return .page_down;
    if (std.ascii.eqlIgnoreCase(str, "up")) return .up;
    if (std.ascii.eqlIgnoreCase(str, "down")) return .down;
    if (std.ascii.eqlIgnoreCase(str, "left")) return .left;
    if (std.ascii.eqlIgnoreCase(str, "right")) return .right;
    if (std.ascii.eqlIgnoreCase(str, "minus")) return .minus;
    if (std.ascii.eqlIgnoreCase(str, "equal") or std.ascii.eqlIgnoreCase(str, "plus")) return .equal;
    if (std.ascii.eqlIgnoreCase(str, "left_bracket") or std.ascii.eqlIgnoreCase(str, "bracket_left")) return .left_bracket;
    if (std.ascii.eqlIgnoreCase(str, "right_bracket") or std.ascii.eqlIgnoreCase(str, "bracket_right")) return .right_bracket;
    if (std.ascii.eqlIgnoreCase(str, "backslash")) return .backslash;
    if (std.ascii.eqlIgnoreCase(str, "semicolon")) return .semicolon;
    if (std.ascii.eqlIgnoreCase(str, "apostrophe") or std.ascii.eqlIgnoreCase(str, "quote")) return .apostrophe;
    if (std.ascii.eqlIgnoreCase(str, "comma")) return .comma;
    if (std.ascii.eqlIgnoreCase(str, "period") or std.ascii.eqlIgnoreCase(str, "dot")) return .period;
    if (std.ascii.eqlIgnoreCase(str, "slash")) return .slash;
    if (std.ascii.eqlIgnoreCase(str, "grave") or std.ascii.eqlIgnoreCase(str, "backtick")) return .grave_accent;

    return null;
}

/// Parses an action string into a canonical Action value.
pub fn parseAction(str: []const u8) ?Action {
    if (std.ascii.eqlIgnoreCase(str, "copy_selection") or std.ascii.eqlIgnoreCase(str, "copy")) return .copy_selection;
    if (std.ascii.eqlIgnoreCase(str, "paste_clipboard") or std.ascii.eqlIgnoreCase(str, "paste")) return .paste_clipboard;
    if (std.ascii.eqlIgnoreCase(str, "increase_font_size") or std.ascii.eqlIgnoreCase(str, "zoom_in")) return .increase_font_size;
    if (std.ascii.eqlIgnoreCase(str, "decrease_font_size") or std.ascii.eqlIgnoreCase(str, "zoom_out")) return .decrease_font_size;
    if (std.ascii.eqlIgnoreCase(str, "reset_font_size") or std.ascii.eqlIgnoreCase(str, "zoom_reset")) return .reset_font_size;
    if (std.ascii.eqlIgnoreCase(str, "new_window")) return .new_window;
    if (std.ascii.eqlIgnoreCase(str, "quit") or std.ascii.eqlIgnoreCase(str, "close")) return .quit;
    if (std.ascii.eqlIgnoreCase(str, "focus_toggle")) return .focus_toggle;
    if (std.ascii.eqlIgnoreCase(str, "focus_reset")) return .focus_reset;
    if (std.ascii.eqlIgnoreCase(str, "focus_skip")) return .focus_skip;
    if (std.ascii.eqlIgnoreCase(str, "focus_auto_transition")) return .focus_auto_transition;
    if (std.ascii.eqlIgnoreCase(str, "wellbeing_dashboard")) return .wellbeing_dashboard;
    if (std.ascii.eqlIgnoreCase(str, "wellbeing_clear")) return .wellbeing_clear;
    if (std.ascii.eqlIgnoreCase(str, "wellbeing_dismiss")) return .wellbeing_dismiss;
    if (std.ascii.eqlIgnoreCase(str, "wellbeing_toast_toggle")) return .wellbeing_toast_toggle;
    if (std.ascii.eqlIgnoreCase(str, "toast_dismiss")) return .toast_dismiss;
    if (std.ascii.eqlIgnoreCase(str, "toast_activate")) return .toast_activate;
    if (std.ascii.eqlIgnoreCase(str, "scroll_up")) return .scroll_up;
    if (std.ascii.eqlIgnoreCase(str, "scroll_down")) return .scroll_down;
    if (std.ascii.eqlIgnoreCase(str, "debug")) return .debug;
    if (std.ascii.eqlIgnoreCase(str, "reload_config") or std.ascii.eqlIgnoreCase(str, "config_reload")) return .reload_config;
    return null;
}

/// Parses a full binding key-value pair, e.g. "ctrl+shift+w" and "wellbeing_dashboard".
pub fn parseBinding(key_str: []const u8, action_str: []const u8) ?Binding {
    const km = parseKeyCombination(key_str) orelse return null;
    const action = parseAction(action_str) orelse return null;
    return Binding{
        .key = km.key,
        .mods = km.mods,
        .action = action,
    };
}
