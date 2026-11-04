//! Term suite: screen-grid operations on the production terminal
//! geometry.
//!
//!   scroll.zig     scrollUp/scrollDown by region (moved from the old
//!                  standalone src/term/screen_bench.zig)
//!   zero_row.zig   row-clear strategies (rep stos, vector, memset)
//!   reflow.zig     Terminal.resize on a near-full ring: zoom steps,
//!                  window dragging, height-only resizes

const std = @import("std");

const Io = std.Io;
const Allocator = std.mem.Allocator;

const support = @import("../../support.zig");
const Options = support.Options;
const Result = support.Result;

pub const scroll = @import("scroll.zig");
pub const zero_row = @import("zero_row.zig");
pub const reflow = @import("reflow.zig");

/// Prefix of every Result.case in this suite.
pub const suite = "term";

pub fn run(io: Io, gpa: Allocator, options: Options, results: *std.ArrayList(Result)) !void {
    try scroll.run(io, gpa, options, results);
    try zero_row.run(io, gpa, options, results);
    try reflow.run(io, gpa, options, results);
}

/// Hash of everything a screen shows: every scrollback and active row
/// (`active_cols` cells each), the cursor and the geometry. Untimed;
/// used to verify that a benchmark's work is deterministic and, for
/// round-trip variants, lossless.
pub fn fingerprint(s: anytype) u64 {
    var h: std.hash.Wyhash = .init(0);
    const used = s.scrollbackUsedAs(i64);
    const rows: i64 = @intCast(s.active_rows);

    var anchor: i64 = -used;
    while (anchor < rows) : (anchor += 1) {
        for (0..s.active_cols) |c| {
            const bits: u64 = @bitCast(s.cellAtAnchor(anchor, c));
            h.update(std.mem.asBytes(&bits));
        }
    }

    const tail = [_]u64{ s.cursor.row, s.cursor.col, s.active_rows, s.active_cols, @intCast(used) };
    h.update(std.mem.sliceAsBytes(&tail));
    return h.final();
}
