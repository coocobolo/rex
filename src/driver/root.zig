const std = @import("std");

pub const InputQueue = @import("InputQueue.zig").InputQueue;
pub const InputEvent = @import("InputQueue.zig").InputEvent;
pub const WakeupChannel = @import("InputQueue.zig").WakeupChannel;
pub const TripleBuffer = @import("TripleBuffer.zig").TripleBuffer;
pub const SingleDriver = @import("SingleDriver.zig").SingleDriver;
pub const ThreadedDriver = @import("ThreadedDriver.zig").ThreadedDriver;
pub const DriverEvents = @import("SingleDriver.zig").DriverEvents;
pub const SharedModes = @import("SingleDriver.zig").SharedModes;
pub const resolveAnchor = @import("SingleDriver.zig").resolveAnchor;
pub const extractSelectionText = @import("SingleDriver.zig").extractSelectionText;

pub fn getMonotonicMs() i64 {
    var ts: std.posix.timespec = undefined;
    _ = std.posix.system.clock_gettime(std.posix.CLOCK.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(ts.nsec, 1_000_000);
}

test {
    _ = @import("InputQueue.zig");
    _ = @import("TripleBuffer.zig");
    _ = @import("SingleDriver.zig");
    _ = @import("ThreadedDriver.zig");
    std.testing.refAllDecls(@This());
}
