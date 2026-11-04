//! Unicode support shared by the terminal and renderer: UTF-8
//! decoding, terminal cell widths and character classes.

const std = @import("std");

pub const Classifier = @import("Classifier.zig");
pub const utf8 = @import("utf8.zig");
pub const wcwidth = @import("wcwidth.zig");

test {
    _ = @import("utf8_test.zig");
    _ = @import("wcwidth_table_test.zig");
    _ = @import("wcwidth_test.zig");
    std.testing.refAllDecls(@This());
}
