//! Selection highlight style (`[selection]`): plain data importing nothing
//! else so both `config/Config.zig` and `renderer/Selection.zig` can share it.

/// How multi-line selection borders are outlined (`[selection] border_style`).
pub const BorderStyle = enum(u1) {
    /// Each row gets its own full border rectangle.
    per_row = 0,
    /// All rows share a single outer perimeter, with no internal row dividers.
    unified = 1,
};
