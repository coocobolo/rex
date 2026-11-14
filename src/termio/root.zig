pub const pipe = @import("pipe.zig");
pub const pty = @import("pty.zig");
pub const Pty = @import("pty.zig").Pty;

test {
    _ = @import("pty_test.zig");
    _ = @import("pipe_test.zig");
    @import("std").testing.refAllDecls(@This());
}
