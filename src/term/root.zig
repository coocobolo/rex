//! The terminal emulator core: `Terminal` state, its screens, cells,
//! palette and grapheme clustering. Depends on vt/, unicode/ and color/
//! only; nothing here may import renderer/ or other GPU code.

const std = @import("std");

pub const cell = @import("cell.zig");
pub const Cell = cell.Cell;
pub const Cursor = @import("Cursor.zig");
pub const charset = @import("charset.zig");
pub const Style = @import("Style.zig").Style;

pub const term = @import("term.zig");
pub const Terminal = term.Terminal;
pub const Option = term.Option;

pub const screen = @import("screen.zig");
pub const Screen = screen.Screen;
pub const Palette = @import("Palette.zig");
pub const Theme = @import("../color/Theme.zig");
pub const grapheme = @import("grapheme.zig");

test {
    _ = @import("term_test.zig");
    _ = @import("dispatcher_test.zig");
    _ = @import("screen_test.zig");
    _ = @import("input_engine_test.zig");
    _ = @import("grapheme_test.zig");
    _ = @import("palette_test.zig");
    _ = @import("Cursor.zig");
    _ = @import("charset.zig");
    _ = @import("Style.zig");
    _ = @import("cell.zig");
    std.testing.refAllDecls(@This());
}
