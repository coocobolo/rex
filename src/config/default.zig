//! The built-in defaults: the base config the system and user files are
//! applied on, and what `default` restores for a key (rebuild plan C3).
//!
//! Neutral values only, each type's own `default` preset. No machine's
//! preferences belong here; `main.zig` puts its own on top.

const Config = @import("Config.zig");
const default_keymap = @import("../input.zig").default_keymap;

/// The documented default config file: every key with the value in
/// `default` (checked by default_test.zig), except `[font] file`, which has
/// no default yet. `rex config dump-default` prints it.
pub const text = @embedFile("default.conf");

pub const default: Config = .{
    .blink = .default,
    .font = .default,
    .keymap = default_keymap,
    .termio = .default,
    .theme = .graphite,
    .window = .default,
    .environments = Config.default_environments,
    .selection = .default,
};
