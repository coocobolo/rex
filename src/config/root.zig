//! Rex configuration: the `Config` the app runs on, the built-in defaults,
//! and loading config files onto them (Tokenizer → Ast → Sema, layered by
//! `Loaded`), with diagnostics and a reload watcher.

const std = @import("std");

pub const Config = @import("Config.zig");
/// The built-in defaults (`default.zig`).
pub const default = @import("default.zig").default;
/// The documented default config file, every key with its default.
pub const default_text = @import("default.zig").text;

pub const Loaded = @import("Loaded.zig");
pub const diagnostics = @import("diagnostics.zig");
pub const paths = @import("paths.zig");
pub const builtin_font = @import("builtin_font.zig");

pub const watcher = @import("watcher.zig");
pub const Watcher = watcher.Watcher;

test {
    _ = @import("tokenizer_test.zig");
    _ = @import("ast_test.zig");
    _ = @import("keys_test.zig");
    _ = @import("sema_test.zig");
    _ = @import("keybind_test.zig");
    _ = @import("default_test.zig");
    _ = @import("diagnostics_test.zig");
    _ = @import("loaded_test.zig");
    _ = @import("builtin_font.zig");
    std.testing.refAllDecls(@This());
}
