const std = @import("std");

pub const cell = @import("cell.zig");
pub const Cell = cell.Cell;

pub const term = @import("term.zig");
pub const Terminal = term.Terminal;
pub const Option = term.Option;

pub const screen = @import("screen.zig");
pub const Screen = screen.Screen;
pub const Palette = @import("Palette.zig");
pub const Theme = @import("Theme.zig");
pub const grapheme = @import("grapheme.zig");

pub const ScreenBench = @import("screen_bench.zig");

test {
    _ = @import("term_test.zig");
    _ = @import("dispatcher_test.zig");
    _ = @import("screen_test.zig");
    _ = @import("input_engine_test.zig");
    _ = @import("grapheme_test.zig");
    _ = @import("palette_test.zig");
    std.testing.refAllDecls(@This());
}