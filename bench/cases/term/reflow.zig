//! Reflow benchmark: `Terminal.resize` on a primary screen whose ring
//! (scrollback + active area) is nearly full, i.e. what one zoom step or
//! one frame of window dragging costs on the production geometry
//! (`App.terminal_option`: 4096-row ring, 220 max columns).
//!
//! Each case fills the ring once, untimed, by feeding generated output
//! through the real parser, so soft-wrap flags, wide cells and margin
//! spacer cells are laid out exactly as a shell session leaves them. The
//! fill happens at the narrow width, so every narrower layout the
//! variants visit fits the ring and nothing is evicted.
//!
//! Every variant's iteration ends at the size it started from, so all
//! iterations do identical work. That round trip doubles as the
//! correctness check: the ring fingerprint before and after one untimed
//! iteration must match, else a line starting with `!!` is printed.
//!
//! Timings are per iteration; the `per_resize` line divides by the number
//! of resizes and shows the share of a 60 Hz frame budget.
//!
//! Allocation: `Terminal.resize` takes no allocator and reflow touches
//! no stored one (the grapheme arena is never used on this path), so the
//! zero-allocation rule is enforced by the signature, not sampled here.

const std = @import("std");

const Io = std.Io;
const Allocator = std.mem.Allocator;

const rex = @import("rex");
const Cell = rex.terminal.Cell;

const support = @import("../../support.zig");
const Options = support.Options;
const Result = support.Result;

const term = @import("root.zig");

const option = rex.App.terminal_option;
const Term = rex.terminal.Terminal(option);

const Size = struct { rows: u16, cols: u16 };

/// Maximised window at the default font, then two zoom-in steps' worth.
const wide: Size = .{ .rows = 60, .cols = 200 };
const narrow: Size = .{ .rows = 30, .cols = 100 };

/// Columns covered by one direction of the drag sweep.
const drag_span = 16;

/// Rows of scrollback left free when filling, so cursor rows and the
/// final prompt never push the oldest lines out.
const fill_headroom = 64;

const frame_ns: f64 = 1e9 / 60.0;
const seed: u64 = 0x5eed_cafe;
const prompt = "user@rex:~/src/rex$ ";

// Variants

const Variant = struct {
    name: []const u8,
    /// Sizes visited in order; the last one is the starting size.
    steps: []const Size,
    /// Whether the steps change columns and so stream the ring. Height-only
    /// resizes do not, and get no MiB/s.
    streams: bool = true,
};

fn dragSteps() [2 * drag_span]Size {
    var out: [2 * drag_span]Size = undefined;
    for (0..drag_span) |i| {
        out[i] = .{ .rows = wide.rows, .cols = wide.cols - 1 - i };
        out[2 * drag_span - 1 - i] = .{ .rows = wide.rows, .cols = wide.cols - i };
    }
    return out;
}

const drag_steps = dragSteps();

const variants = [_]Variant{
    // Zoom in then out: both dimensions change, as with Ctrl+/Ctrl-.
    .{ .name = "zoom", .steps = &.{ narrow, wide } },
    // Dragging the window edge: one column per frame, in then back out.
    .{ .name = "drag", .steps = &drag_steps },
    // Rows only: takes the setActive path, the floor to compare against.
    .{ .name = "height", .steps = &.{ .{ .rows = narrow.rows, .cols = wide.cols }, wide }, .streams = false },
};

// Content

const Shape = enum {
    /// `ls -l`/`git log` shaped: 20..100 ASCII columns, no wraps at either width.
    short_lines,
    /// 150..1200 columns: most rows are soft-wrapped at both widths.
    long_lines,
    /// 80..600 columns of ASCII words mixed with CJK: wide cells and spacers.
    cjk_mixed,
    /// A fresh shell: a few lines and the prompt, no scrollback.
    prompt_only,
};

const Line = struct {
    buf: [8 << 10]u8 = undefined,
    len: usize = 0,

    fn add(self: *Line, bytes: []const u8) void {
        @memcpy(self.buf[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
    }

    fn addCodepoint(self: *Line, cp: u21) void {
        self.len += std.unicode.utf8Encode(cp, self.buf[self.len..]) catch unreachable;
    }

    fn slice(self: *const Line) []const u8 {
        return self.buf[0..self.len];
    }
};

/// One line of `shape` content, terminated by CRLF.
fn genLine(line: *Line, rng: std.Random, shape: Shape) void {
    line.len = 0;
    switch (shape) {
        .short_lines, .prompt_only => {
            const n = rng.intRangeAtMost(usize, 20, 100);
            for (0..n) |_| line.addCodepoint(rng.intRangeAtMost(u8, 0x20, 0x7e));
        },
        .long_lines => {
            const n = rng.intRangeAtMost(usize, 150, 1200);
            for (0..n) |_| line.addCodepoint(rng.intRangeAtMost(u8, 0x21, 0x7e));
        },
        .cjk_mixed => {
            var width: usize = 0;
            const target = rng.intRangeAtMost(usize, 80, 600);
            while (width < target) {
                if (rng.boolean()) {
                    const word = rng.intRangeAtMost(usize, 1, 8);
                    for (0..word) |_| line.addCodepoint(rng.intRangeAtMost(u8, 'a', 'z'));
                    line.add(" ");
                    width += word + 1;
                } else {
                    const cjk_count = rng.intRangeAtMost(usize, 1, 6);
                    for (0..cjk_count) |_| line.addCodepoint(rng.intRangeAtMost(u21, 0x4e00, 0x4fff));
                    width += 2 * cjk_count;
                }
            }
        },
    }
    line.add("\r\n");
}

/// Feeds `shape` output at the narrow size until the ring is nearly full
/// (or a screenful for `prompt_only`), ends with a prompt, then settles at
/// the wide size. Starts from a hard reset, so every variant sees the same
/// ring. Untimed.
fn fill(t: *Term, shape: Shape) void {
    t.hardReset();
    t.resize(narrow.rows, narrow.cols);

    var prng = std.Random.DefaultPrng.init(seed);
    const rng = prng.random();
    var line: Line = .{};

    if (shape == .prompt_only) {
        for (0..8) |_| {
            genLine(&line, rng, shape);
            t.feed(line.slice());
        }
    } else {
        while (t.primary.scrollback_used + fill_headroom < option.max_scrollback) {
            genLine(&line, rng, shape);
            t.feed(line.slice());
        }
    }
    t.feed(prompt);
    t.resize(wide.rows, wide.cols);
}

// Timing

const Context = struct {
    t: *Term,
    steps: []const Size,

    fn cycle(ctx: *Context) !void {
        for (ctx.steps) |s| ctx.t.resize(s.rows, s.cols);
        std.mem.doNotOptimizeAway(&ctx.t.primary.cursor);
    }
};

/// Bytes of source cells the reflow reader walks in one iteration:
/// every used row at the width it is read from. Untimed, one cycle.
fn streamedBytes(t: *Term, steps: []const Size) usize {
    var total: usize = 0;
    for (steps) |s| {
        const p = &t.primary;
        if (s.cols != p.active_cols) {
            total += (p.scrollback_used + p.active_rows) * p.active_cols * @sizeOf(Cell);
        }
        t.resize(s.rows, s.cols);
    }
    return total;
}

fn runCase(
    io: Io,
    gpa: Allocator,
    opts: Options,
    results: *std.ArrayList(Result),
    t: *Term,
    comptime shape: Shape,
) !void {
    const case = @tagName(shape);
    const result_case = term.suite ++ ".reflow." ++ case;

    inline for (variants) |v| {
        if (support.allowed(opts.filter, "reflow/" ++ case, v.name)) {
            fill(t, shape);
            std.debug.print("profile reflow/{s:<12} ring rows={d} (scrollback {d})\n", .{
                case, t.primary.scrollback_used + t.primary.active_rows, t.primary.scrollback_used,
            });

            // Untimed round trip: settles the layout, verifies it is
            // lossless and measures the bytes one iteration streams.
            const before = term.fingerprint(&t.primary);
            const bytes = if (v.streams)
                streamedBytes(t, v.steps)
            else
                @as(usize, wide.rows) * @as(usize, wide.cols) * @sizeOf(Cell) * v.steps.len;
            const after = term.fingerprint(&t.primary);
            if (before != after) {
                std.debug.print("!! reflow/{s}/{s}: round trip changed the ring ({x} -> {x})\n", .{
                    case, v.name, before, after,
                });
            }

            var ctx: Context = .{ .t = t, .steps = v.steps };
            const iterations = opts.iterationsFor(bytes);
            var stats = try support.run(gpa, io, Context.cycle, &ctx, iterations, opts.samples, if (v.streams) bytes else 0);
            defer stats.deinit(gpa);

            const label = "reflow/" ++ case ++ "/" ++ v.name;
            std.debug.print("{s:<40} {f}  checksum={x}\n", .{ label, stats, after });

            const per_resize = stats.minNsPerIteration() / @as(f64, @floatFromInt(v.steps.len));
            std.debug.print("{s}/per_resize  {d:.1} us  ({d:.1}% of a 60 Hz frame, {d} resizes/iteration)\n", .{
                label, per_resize / 1e3, per_resize / frame_ns * 100.0, v.steps.len,
            });

            try results.append(gpa, stats.toResult(result_case, v.name, after));
        }
    }
}

const all_shapes = [_]Shape{
    .short_lines,
    .long_lines,
    .cjk_mixed,
    .prompt_only,
};

pub fn run(io: Io, gpa: Allocator, opts: Options, results: *std.ArrayList(Result)) !void {
    if (!anyAllowed(opts.filter)) return;

    // Heap, not stack: two screens with their ring metadata.
    const t = try gpa.create(Term);
    defer gpa.destroy(t);
    t.* = try Term.create(gpa);
    defer t.destroy(gpa);

    inline for (all_shapes) |shape| {
        try runCase(io, gpa, opts, results, t, shape);
    }
}

fn anyAllowed(filter: ?[]const u8) bool {
    inline for (all_shapes) |shape| {
        inline for (variants) |v| {
            if (support.allowed(filter, "reflow/" ++ @tagName(shape), v.name)) return true;
        }
    }
    return false;
}
