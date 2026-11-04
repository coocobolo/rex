//! Root of the `rex` module: the application plus each subsystem's
//! namespace. Types are reached through their namespace, e.g.
//! `rex.terminal.Terminal` or `rex.vt.Parser`; nothing is re-exported
//! twice.
const std = @import("std");

pub const App = @import("App.zig");
pub const input = @import("input.zig");
pub const Selection = @import("Selection.zig");

pub const renderer = @import("renderer/root.zig");
pub const terminal = @import("term/root.zig");
pub const vt = @import("vt/root.zig");
pub const termio = @import("termio/root.zig");
pub const unicode = @import("unicode/root.zig");

pub const dirs = @import("dirs/root.zig");
pub const env = @import("env/root.zig");
pub const FreeType = @import("freetype/root.zig");
pub const builtin = @import("builtin/root.zig");

test {
    _ = @import("fuzz/root.zig");
    std.testing.refAllDecls(@This());
}
