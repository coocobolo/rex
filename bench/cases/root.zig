const std = @import("std");

const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const term = @import("term/root.zig");
pub const vt = @import("vt/root.zig");

const Options = @import("../support.zig").Options;

pub fn run(gpa: Allocator, io: Io, options: Options) !void {
    try vt.parser.runDispatcher(
        io,
        gpa,
        options,
    );

    try vt.parser.runCorpus(
        io,
        gpa,
        options,
    );

    try vt.parser.runCostModel(
        io,
        gpa,
        options,
    );

    // try term.screen.runPhysRow(
    //     gpa,
    //     io,
    //     iteration,
    //     samples,
    // );
}