const std = @import("std");

const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const vt = @import("vt/root.zig");

const support = @import("../support.zig");
const Options = support.Options;
const Result = support.Result;

pub fn run(gpa: Allocator, io: Io, options: Options) !void {
    var results: std.ArrayList(Result) = .empty;
    defer results.deinit(gpa);

    try vt.parser.runDispatcher(
        io,
        gpa,
        options,
        &results,
    );

    try vt.parser.runCorpus(
        io,
        gpa,
        options,
        &results,
    );

    if (options.cost_model) try vt.parser.runCostModel(
        io,
        gpa,
        options,
        &results,
    );

    if (options.compare) |path| try support.compareResults(gpa, io, path, results.items);
    if (options.save) |path| try support.saveResults(gpa, io, path, results.items);
}
