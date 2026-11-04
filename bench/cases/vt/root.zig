//! VT suite: parser throughput by feed shape and content, plus the
//! opt-in cost model (`--cost-model`).

const std = @import("std");

const Io = std.Io;
const Allocator = std.mem.Allocator;

const support = @import("../../support.zig");
const Options = support.Options;
const Result = support.Result;

pub const parser = @import("parser.zig");

pub fn run(io: Io, gpa: Allocator, options: Options, results: *std.ArrayList(Result)) !void {
    try parser.runDispatcher(io, gpa, options, results);
    try parser.runCorpus(io, gpa, options, results);
    if (options.cost_model) try parser.runCostModel(io, gpa, options, results);
}
