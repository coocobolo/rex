const std = @import("std");

pub const classifier = @import("char_class.zig");
pub const Classifier = @import("char_class.zig").Classifier;
pub const utf8 = @import("utf8.zig");
pub const wc = @import("wcwidth_v2.zig");
pub const wcwidth = @import("wcwidth_v2.zig").wcwidth;

test {
    _ = @import("wcwidth_v2_test.zig");
    std.testing.refAllDecls(@This());
}

// const corpus = [_][]const u8{
//     @embedFile("fuzz/wcwidth/crash-630ff0a4f49ee617.bin"),
// };
