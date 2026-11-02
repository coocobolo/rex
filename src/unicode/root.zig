const std = @import("std");

pub const classifer = @import("char_class.zig");
pub const Classifier = @import("char_class.zig").Classifier;
pub const utf8 = @import("utf8.zig");
pub const wc = @import("wcwidth_v2.zig");
pub const wcwidth = @import("wcwidth_v2.zig").wcwidth;

// const corpus = [_][]const u8{
//     @embedFile("fuzz/wcwidth/crash-630ff0a4f49ee617.bin"),
// };

test {
    // for (corpus) |item| {
    //     std.debug.print("corpus: {s}\n", .{item});
    // }
    std.testing.refAllDecls(@This());
}
