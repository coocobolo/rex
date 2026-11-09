pub const pty = @import("pty.zig");
pub const Pty = @import("pty.zig").Pty;

comptime {
    @import("std").testing.refAllDecls(@This());
}

test {
    _ = @import("pty_test.zig");
}
