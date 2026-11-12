//! Root of the `rex` module: the application plus each subsystem's
//! namespace. Types are reached through their namespace, e.g.
//! `rex.terminal.Terminal` or `rex.vt.Parser`; nothing is re-exported
//! twice.
const std = @import("std");

pub const App = @import("App.zig");
pub const input = @import("input/root.zig");
pub const Selection = @import("Selection.zig");

pub const color = @import("color/root.zig");
pub const ui = @import("ui/root.zig");
pub const kit = @import("kit/root.zig");
pub const renderer = @import("renderer/root.zig");
pub const terminal = @import("term/root.zig");
pub const vt = @import("vt/root.zig");
pub const termio = @import("termio/root.zig");
pub const unicode = @import("unicode/root.zig");
pub const driver = @import("driver/root.zig");

pub const dirs = @import("dirs/root.zig");
pub const env = @import("env/root.zig");
pub const FreeType = @import("freetype/root.zig");
pub const builtin = @import("builtin/root.zig");
pub const config = @import("config/root.zig");

test {
    _ = @import("color/root.zig");
    _ = @import("ui/root.zig");
    _ = @import("kit/root.zig");
    _ = @import("fuzz/root.zig");
    _ = @import("input/root.zig");
    _ = @import("driver/root.zig");
    _ = @import("config/root.zig");
    _ = @import("flag_set.zig");
    _ = @import("kit_overlay_test.zig");
    std.testing.refAllDecls(@This());
}
