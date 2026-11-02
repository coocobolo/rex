const std = @import("std");

pub fn Dimension(comptime T: type) type {
    return struct {
        width: T,
        height: T,

        const Self = Dimension(T);

        pub const empty: Self = .{ .width = 0, .height = 0 };
    };
}
