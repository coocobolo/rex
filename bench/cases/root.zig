//! Benchmark suites, one folder each. Every suite's root.zig exposes
//!
//!     pub fn run(io: Io, gpa: Allocator, options: Options, results: *std.ArrayList(Result)) !void
//!
//! and builds on ../support.zig (timing, stats, `--filter`, JSONL
//! baselines), so all suites print, filter, save and compare the same
//! way. Adding a suite is a folder, one row in `suites` below and one row
//! in `bench_suites` in build.zig (which gives it `zig build bench-<name>`).

const std = @import("std");

const Io = std.Io;
const Allocator = std.mem.Allocator;

const support = @import("../support.zig");
const Options = support.Options;
const Result = support.Result;

pub const vt = @import("vt/root.zig");
pub const term = @import("term/root.zig");

/// Registered suites, in run order.
pub const suites = .{
    .{ "vt", vt },
    .{ "term", term },
};

pub fn run(gpa: Allocator, io: Io, options: Options) !void {
    if (options.suite) |want| {
        if (!isSuite(want)) {
            std.debug.print("unknown suite '{s}'; known:", .{want});
            inline for (suites) |s| std.debug.print(" {s}", .{s[0]});
            std.debug.print("\n", .{});
            return error.UnknownSuite;
        }
    }

    var results: std.ArrayList(Result) = .empty;
    defer results.deinit(gpa);

    inline for (suites) |s| {
        const name, const suite = s;
        if (options.suite == null or std.mem.eql(u8, options.suite.?, name)) {
            std.debug.print("\n== suite {s} ==\n", .{name});
            try suite.run(io, gpa, options, &results);
        }
    }

    if (options.compare) |path| try support.compareResults(gpa, io, path, results.items);
    if (options.save) |path| try support.saveResults(gpa, io, path, results.items);
}

fn isSuite(name: []const u8) bool {
    inline for (suites) |s| {
        if (std.mem.eql(u8, s[0], name)) return true;
    }
    return false;
}
