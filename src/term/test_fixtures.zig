//! Shared fixtures for the term/ tests.

const Option = @import("term.zig").Option;

/// A small terminal, 12 rows by 24 columns with 20 lines of
/// scrollback, so tests can fill, wrap and scroll the grid cheaply.
pub const test_option: Option = .{
    .max_rows = 12,
    .max_cols = 24,
    .max_scrollback = 20,
    .name = "test",
    .version = "0.0.1",
};
