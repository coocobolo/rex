//! The built-in defaults: the base config the system and user files are
//! applied on, and what `default` restores for a key (rebuild plan C3).
//!
//! Neutral values only, each type's own `default` preset. No machine's
//! preferences belong here; `main.zig` puts its own on top.

const Config = @import("Config.zig");
const default_keymap = @import("../input/binding.zig").default_keymap;

/// The documented default config file: every key with the value in
/// `default` (checked by default_test.zig), except `[font] file`,
/// `italic_file` and `emoji_file`. Those stay unset so startup can point
/// them at the faces installed next to the executable. `rex config defaults`
/// prints this file.
pub const text = @embedFile("default.conf");

pub const default: Config = .{
    .font = .default,
    .keymap = default_keymap,
    .theme = .graphite,
    .window = .default,
    .environments = Config.default_environments,
    .selection = .default,
};
