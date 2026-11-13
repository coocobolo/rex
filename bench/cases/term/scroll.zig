//! Scroll benchmark: one `scrollUp(1)` / `scrollDown(1)` per iteration
//! on a 24x80 grid, by scroll region. Shows whether the cost is flat
//! (ring rotation) or scales with the region height (row moves).
//!
//! `alt/*` uses a screen without scrollback (alternate screen, TUIs);
//! `primary/*` uses the production ring, where full-screen scrolls feed
//! scrollback (`cat`, build logs).

const std = @import("std");

const Io = std.Io;
const Allocator = std.mem.Allocator;

const rex = @import("rex");
const Cell = rex.terminal.Cell;
const Screen = rex.terminal.Screen;

const support = @import("../../support.zig");
const Options = support.Options;
const Result = support.Result;

const term = @import("root.zig");

const rows = 24;
const cols = 80;

const AltScreen = Screen(.{ .max_rows = rows, .max_cols = cols, .max_scrollback = 0 });
const PrimaryScreen = Screen(rex.App.default_terminal_option);

const Direction = enum { up, down };

/// One scroll region case. `top`/`bottom` are 1-based like DECSTBM.
const Case = struct {
    name: []const u8,
    top: usize,
    bottom: usize,
    direction: Direction = .up,
};

const cases = [_]Case{
    .{ .name = "full", .top = 1, .bottom = rows },
    // A status line on row 1, the rest scrolls (tmux, less).
    .{ .name = "bottom_region", .top = 2, .bottom = rows },
    // A status line on the last row (vim, htop).
    .{ .name = "top_region", .top = 1, .bottom = rows - 1 },
    // A small region: does cost scale with region height?
    .{ .name = "small_region", .top = 21, .bottom = rows },
    .{ .name = "bottom_region_down", .top = 2, .bottom = rows, .direction = .down },
};

fn Context(comptime S: type) type {
    return struct {
        s: *S,
        direction: Direction,

        fn step(ctx: *@This()) !void {
            switch (ctx.direction) {
                .up => ctx.s.scrollUp(1),
                .down => ctx.s.scrollDown(1),
            }
            std.mem.doNotOptimizeAway(ctx.s);
        }
    };
}

/// Every row starts as distinct text, so scrolling moves real content.
fn prepare(comptime S: type, s: *S, case: Case) void {
    s.setActive(rows, cols);
    for (0..rows) |r| {
        for (0..cols) |c| {
            s.setCell(r, c, .{ .codepoint = @intCast('A' + (r + c) % 26), .kind = .narrow });
        }
    }
    s.setScrollRegion(case.top, case.bottom);
}

/// Fingerprint after a fixed number of scrolls on a fresh screen, so the
/// checksum depends only on the case, never on `--samples` or the budget.
fn checksum(comptime S: type, gpa: Allocator, case: Case) !u64 {
    const s = try gpa.create(S);
    defer gpa.destroy(s);
    s.* = try .create(gpa);
    defer s.destroy(gpa);

    prepare(S, s, case);
    var ctx: Context(S) = .{ .s = s, .direction = case.direction };
    for (0..37) |_| try ctx.step();
    return term.fingerprint(s);
}

fn runScreen(
    comptime S: type,
    comptime screen_name: []const u8,
    io: Io,
    gpa: Allocator,
    opts: Options,
    results: *std.ArrayList(Result),
) !void {
    inline for (cases) |case| {
        // Full-screen only on primary: partial regions never touch scrollback,
        // so they would just repeat the alt numbers.
        const skip = comptime std.mem.eql(u8, screen_name, "primary") and !std.mem.eql(u8, case.name, "full");
        if (!skip and support.allowed(opts.filter, "scroll", screen_name ++ "/" ++ case.name)) {
            const s = try gpa.create(S);
            defer gpa.destroy(s);
            s.* = try .create(gpa);
            defer s.destroy(gpa);
            prepare(S, s, case);

            // Size by the row a scroll blanks: the floor of its work.
            const iterations = opts.iterationsFor(cols * @sizeOf(Cell)) * 4;
            var ctx: Context(S) = .{ .s = s, .direction = case.direction };
            var stats = try support.run(gpa, io, Context(S).step, &ctx, iterations, opts.samples, 0);
            defer stats.deinit(gpa);

            const variant = screen_name ++ "/" ++ case.name;
            const fp = try checksum(S, gpa, case);
            std.debug.print("{s:<40} {f}  checksum={x}\n", .{ "scroll/" ++ variant, stats, fp });
            try results.append(gpa, stats.toResult(term.suite ++ ".scroll", variant, fp));
        }
    }
}

pub fn run(io: Io, gpa: Allocator, opts: Options, results: *std.ArrayList(Result)) !void {
    try runScreen(AltScreen, "alt", io, gpa, opts, results);
    try runScreen(PrimaryScreen, "primary", io, gpa, opts, results);
}
