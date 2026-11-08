//! Shared fixtures for the config/ tests and the config fuzz target.

const Config = @import("Config.zig");
const Theme = @import("../color/Theme.zig");

/// A complete Config for tests: the fields without defaults get minimal
/// values, the font is a variable family at `/base/upright.ttf`, size 20,
/// bounds 6 to 96, and the keymap is empty.
pub const test_config: Config = .{
    .blink = .{},
    .font = .{
        .faces = .{ .family = .{ .variable = .{ .upright = "/base/upright.ttf" } } },
        .size = 20,
        .max_size = 96,
        .min_size = 6,
    },
    .keymap = &.{},
    .termio = .{},
    .theme = Theme.graphite,
    .window = .{ .background = .{}, .scrollbar = .{}, .cursor = .{}, .selection = .{} },
    .selection = .{ .classifier = .{} },
    .environments = &.{},
};
