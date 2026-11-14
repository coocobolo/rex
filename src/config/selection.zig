//! Selection highlight style (`[selection]`): plain data importing nothing
//! else so both `config/Config.zig` and `renderer/Selection.zig` can share it.

/// How multi-line selection borders are drawn (`[selection] border_style`).
pub const BorderStyle = enum(u2) {
    /// Each row gets its own border rectangle (1x dividers between touching rows).
    split = 0,
    /// All rows share a single outer perimeter, with no internal row dividers.
    unified = 1,
    /// Accent bar along the bottom edge of each selected row.
    underline = 2,
    /// Accent bar along the left edge of each selected row.
    left_bar = 3,
};
