const std = @import("std");

const rex = @import("root.zig");

const screen_bench = rex.terminal.ScreenBench;

pub fn main(init: std.process.Init) !void {
    return screen_bench.run(init);
}
