//! Key bindings: the actions a key chord can trigger and the default
//! keymap.

const Key = @import("key.zig").Key;
const Modifiers = @import("key.zig").Modifiers;

pub const Action = union(enum) {
    copy_selection,
    paste_clipboard,
    increase_font_size,
    decrease_font_size,
    reset_font_size,
    new_window,
    quit,

    // Focus & Wellbeing
    focus_toggle, // start / pause / resume
    focus_reset, // restart current session from scratch
    focus_skip, // skip to next phase (work to break or break to work)
    focus_toggle_phase_end, // switch on_phase_end between wait and start_next
    wellbeing_dashboard, // show Digital Wellbeing dashboard
    wellbeing_clear, // clear Digital Wellbeing history
    wellbeing_dismiss, // dismiss active wellbeing alert / unlock input

    // Toast notifications
    toast_dismiss,
    toast_activate,

    scroll_up,
    scroll_down,

    // Configuration
    reload_config,

    send_to_pty: []const u8, // for custom sequences
};

pub const Binding = struct {
    key: Key,
    mods: Modifiers = .{},
    action: Action,
};

pub const default_keymap: []const Binding = &.{
    .{ .key = .num_0, .mods = .{ .ctrl = true }, .action = .reset_font_size },
    .{ .key = .a, .mods = .{ .ctrl = true, .shift = true }, .action = .focus_toggle_phase_end },
    .{ .key = .backspace, .mods = .{ .ctrl = true, .shift = true }, .action = .focus_reset },
    .{ .key = .c, .mods = .{ .ctrl = true, .shift = true }, .action = .copy_selection },
    .{ .key = .d, .mods = .{ .ctrl = true, .shift = true }, .action = .wellbeing_dismiss },
    .{ .key = .equal, .mods = .{ .ctrl = true }, .action = .increase_font_size },
    .{ .key = .j, .mods = .{ .ctrl = true, .shift = true }, .action = .scroll_down },
    .{ .key = .k, .mods = .{ .ctrl = true, .shift = true }, .action = .scroll_up },
    .{ .key = .minus, .mods = .{ .ctrl = true }, .action = .decrease_font_size },
    .{ .key = .n, .mods = .{ .ctrl = true, .shift = true }, .action = .new_window },
    .{ .key = .p, .mods = .{ .ctrl = true, .shift = true }, .action = .focus_toggle },
    .{ .key = .q, .mods = .{ .ctrl = true, .shift = true }, .action = .quit },
    .{ .key = .f5, .mods = .{ .ctrl = true, .shift = true }, .action = .reload_config },
    .{ .key = .right_bracket, .mods = .{ .ctrl = true, .shift = true }, .action = .focus_skip },
    .{ .key = .v, .mods = .{ .ctrl = true, .shift = true }, .action = .paste_clipboard },
    .{ .key = .w, .mods = .{ .ctrl = true, .shift = true }, .action = .wellbeing_dashboard },
};

/// The action bound to `key` with exactly `mods`, or null.
pub fn matchBinding(bindings: []const Binding, key: Key, mods: Modifiers) ?Action {
    for (bindings) |b| {
        if (b.key == key and @as(u8, @bitCast(b.mods)) == @as(u8, @bitCast(mods))) return b.action;
    }
    return null;
}
