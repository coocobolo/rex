//! By convention, root.zig is the root source file when making a library.
const std = @import("std");

pub const App = @import("app.zig");
pub const input = @import("input.zig");
pub const gl = @import("renderer/gl.zig");

pub const renderer = @import("renderer/root.zig");

pub const Screen = @import("term/screen.zig").Screen;
pub const terminal = @import("term/root.zig");

pub const Term = @import("term/term.zig").Terminal;

pub const dirs = @import("dirs/root.zig");
pub const env = @import("env/root.zig");
pub const unicode = @import("unicode/root.zig");

pub const Selection = @import("selection.zig");

pub const VT = @import("vt/parser.zig");

pub const termio = @import("termio/root.zig");
pub const FreeType = @import("freetype/root.zig");
pub const builtin = @import("builtin/root.zig");

// pub const Audio = @import("audio.zig");

test {
    std.testing.refAllDecls(@This());
}
