//! Unicode support shared by the terminal and renderer: UTF-8
//! decoding, terminal cell widths and character classes.

const std = @import("std");

pub const classifier = @import("char_class.zig");
pub const Classifier = @import("char_class.zig").Classifier;
pub const utf8 = @import("utf8.zig");
pub const wc = @import("wcwidth_v2.zig");
pub const wcwidth = @import("wcwidth_v2.zig").wcwidth;

test {
    _ = @import("utf8_test.zig");
    _ = @import("wcwidth_table_test.zig");
    _ = @import("wcwidth_v2_test.zig");
    std.testing.refAllDecls(@This());
}
