//! Keys, modifiers and key bindings, with no platform dependency
//! (ADR 0007).

const key = @import("key.zig");
const binding = @import("binding.zig");

pub const encode = @import("encode.zig");

pub const Key = key.Key;
pub const Modifiers = key.Modifiers;
pub const Action = binding.Action;
pub const Binding = binding.Binding;
pub const default_keymap = binding.default_keymap;
pub const matchBinding = binding.matchBinding;

test {
    _ = @import("binding_test.zig");
    _ = @import("encode_test.zig");
}
