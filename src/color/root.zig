//! Colors in the terminal pipeline pass through four distinct representations, each serving a different layer.
//! The VT parser produces a Color union, either .default, .indexed, or .rgb which Palette.intern() maps to a
//! u8 index stored directly in each Cell. That index is looked up in Palette.entries, where each slot holds a
//! u32 color key encoding both the color kind and its value, used internally for interning and eviction.
//!
//! Before the renderer can use it, that key is decoded into a concrete Rgb value, which the renderer then
//! converts to RGBA pixel data. Index 0 is special: it always means "terminal default,"
//! resolved at render time to the user-overridden foreground or background if set, otherwise the built-in fallback.
//! The u32 key and the u32 RGBA are entirely different encodings and are never interchangeable.

pub const ansi = @import("ansi.zig");
pub const x11 = @import("x11.zig");
pub const Color = @import("color.zig").Color;
pub const Rgb = @import("Rgb.zig").Rgb;
