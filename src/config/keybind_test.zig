const std = @import("std");
const keybind = @import("keybind.zig");

test "keybind: chords are modifiers and one key, one spelling each" {
    const chord = try keybind.parseChord("ctrl+shift+w");
    try std.testing.expectEqual(.w, chord.key);
    try std.testing.expect(chord.mods.ctrl and chord.mods.shift and !chord.mods.alt and !chord.mods.super);

    try std.testing.expectEqual(.num_0, (try keybind.parseChord("ctrl+0")).key);
    try std.testing.expectEqual(.f12, (try keybind.parseChord("f12")).key);
    try std.testing.expectEqual(.equal, (try keybind.parseChord("ctrl+equal")).key);
    try std.testing.expectEqual(.page_up, (try keybind.parseChord("shift+page_up")).key);
    try std.testing.expectEqual(.kp_add, (try keybind.parseChord("ctrl+kp_add")).key);
    // Any modifier order.
    try std.testing.expectEqual(try keybind.parseChord("ctrl+shift+w"), try keybind.parseChord("shift+ctrl+w"));

    for ([_][]const u8{
        "",                "ctrl",     "ctrl+",       "+w",        "ctrl++w", "ctrl+a+b", "ctrl+ctrl+w",
        "Ctrl+w",          "ctrl+W",   "control+w",   "cmd+w",     "opt+w",   "win+w",    "ctrl+f13",
        "ctrl+plus",       "ctrl+esc", "ctrl+return", "ctrl+pgup", "ctrl+-",  "ctrl+=",   "ctrl+num_0",
        "ctrl+left_shift", "ctrl+ w",
    }) |text| {
        errdefer std.debug.print("accepted: '{s}'\n", .{text});
        try std.testing.expectError(error.InvalidChord, keybind.parseChord(text));
    }
}

test "keybind: actions are tag names without an argument" {
    try std.testing.expectEqual(.copy_selection, try keybind.parseAction("copy_selection"));
    try std.testing.expectEqual(.reload_config, try keybind.parseAction("reload_config"));
    try std.testing.expectEqual(.open_settings, try keybind.parseAction("open_settings"));
    for ([_][]const u8{ "copy", "paste", "zoom_in", "close", "config_reload", "Quit", "send_to_pty", "" }) |text| {
        errdefer std.debug.print("accepted: '{s}'\n", .{text});
        try std.testing.expectError(error.InvalidAction, keybind.parseAction(text));
    }
}

test "keybind: a binding needs a valid chord and action" {
    const binding = try keybind.parseBinding("ctrl+shift+r", "reload_config");
    try std.testing.expectEqual(.r, binding.key);
    try std.testing.expectEqual(.reload_config, binding.action);
    const settings = try keybind.parseBinding("ctrl+shift+comma", "open_settings");
    try std.testing.expectEqual(.comma, settings.key);
    try std.testing.expect(settings.mods.ctrl and settings.mods.shift and !settings.mods.alt and !settings.mods.super);
    try std.testing.expectEqual(.open_settings, settings.action);
    try std.testing.expectError(error.InvalidChord, keybind.parseBinding("ctrl+f13", "quit"));
    try std.testing.expectError(error.InvalidAction, keybind.parseBinding("ctrl+q", "close"));
}
