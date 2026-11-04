const std = @import("std");

const Io = std.Io;
const Allocator = std.mem.Allocator;

const screen = @import("screen.zig");
const Screen = screen.Screen;
const Cell = @import("cell.zig").Cell;

const BenchScreen = Screen(.{
    .max_rows = 24,
    .max_cols = 80,
    .tab_width = 8,
    .max_scrollback = 0,
    .version = "0.0.1",
    .name = "screen_bench",
});

const Nanoseconds = i96;
const warmup_iterations: usize = 10_000;
const measured_iterations: usize = 10_000_000;
const sample_count: usize = 9;

const zero_row_length: usize = 80;

fn benchScrollBottomRegion(io: Io, gpa: Allocator, iterations: usize) !Nanoseconds {
    if (iterations == 0) return 0;
    var s: BenchScreen = try .create(gpa);
    defer s.destroy(gpa);

    // Reverse the top row (e.g. a status line at row 1), scroll region is
    // rows 2..24 (1-based, matches setScrollRegion's DECSTBM semantics).
    s.setScrollRegion(2, 24);

    const start = Io.Clock.now(.awake, io);
    for (0..iterations) |_| {
        s.scrollUp(1);
        std.mem.doNotOptimizeAway(&s);
    }

    const end = Io.Clock.now(.awake, io);
    return start.durationTo(end).toNanoseconds();
}

fn benchScrollTopRegion(io: Io, gpa: Allocator, iterations: usize) !Nanoseconds {
    if (iterations == 0) return 0;

    var s: BenchScreen = try .create(gpa);
    defer s.destroy(gpa);

    // Reverse the top row (e.g. a status line at row 1), scroll region is
    // rows 2..24 (1-based, matches setScrollRegion's DECSTBM semantics).
    s.setScrollRegion(1, 23);

    const start = Io.Clock.now(.awake, io);
    for (0..iterations) |_| {
        s.scrollUp(1);
        std.mem.doNotOptimizeAway(&s);
    }

    const end = Io.Clock.now(.awake, io);
    return start.durationTo(end).toNanoseconds();
}

fn benchScrollBottomSmallRegion(io: Io, gpa: Allocator, iterations: usize) !Nanoseconds {
    if (iterations == 0) return 0;

    var s: BenchScreen = try .create(gpa);
    defer s.destroy(gpa);

    // A small region (e.g. 4 rows) to check whether cost scales with
    // region_height or is flat regardless of size.
    s.setScrollRegion(21, 24);

    const start = Io.Clock.now(.awake, io);
    for (0..iterations) |_| {
        s.scrollUp(1);
        std.mem.doNotOptimizeAway(&s);
    }
    const end = Io.Clock.now(.awake, io);
    return start.durationTo(end).toNanoseconds();
}

fn benchScrollDownBottomRegion(io: Io, gpa: Allocator, iterations: usize) !Nanoseconds {
    if (iterations == 0) return 0;

    var s: BenchScreen = try .create(gpa);
    defer s.destroy(gpa);

    s.setScrollRegion(2, 24);

    const start = Io.Clock.now(.awake, io);
    for (0..iterations) |_| {
        s.scrollDown(1);
        std.mem.doNotOptimizeAway(&s);
    }
    const end = Io.Clock.now(.awake, io);
    return start.durationTo(end).toNanoseconds();
}

fn benchScrollFullScreen(io: Io, gpa: Allocator, iterations: usize) !Nanoseconds {
    if (iterations == 0) return 0;

    var s: BenchScreen = try .create(gpa);
    defer s.destroy(gpa);

    const start = Io.Clock.now(.awake, io);
    for (0..iterations) |_| {
        s.scrollUp(1);

        // Prevent the optimizer from removing or materially changing
        // the benchmarked work.
        std.mem.doNotOptimizeAway(&s);
    }
    const end = Io.Clock.now(.awake, io);
    return start.durationTo(end).toNanoseconds();
}

fn benchZeroRow(
    io: Io,
    row: []Cell,
    iterations: usize,
    comptime zero_fn: anytype,
) Nanoseconds {
    if (iterations == 0) return 0;

    const start = Io.Clock.now(.awake, io);

    for (0..iterations) |_| {
        zero_fn(row.ptr, row.len);

        // Keep the memory operation observable to the compiler.
        std.mem.doNotOptimizeAway(row.ptr);
    }

    const end = Io.Clock.now(.awake, io);
    return start.durationTo(end).toNanoseconds();
}

fn runZeroRowBenchmark(
    io: Io,
    row: []Cell,
    name: []const u8,
    comptime zero_fn: anytype,
) void {
    _ = benchZeroRow(
        io,
        row,
        warmup_iterations,
        zero_fn,
    );

    var samples: [sample_count]Nanoseconds = undefined;

    for (&samples) |*sample| {
        const empty_ns = benchEmpty(
            io,
            measured_iterations,
        );

        const operation_ns = benchZeroRow(
            io,
            row,
            measured_iterations,
            zero_fn,
        );
        sample.* = @max(operation_ns - empty_ns, 0);
    }

    printResult(
        name,
        measured_iterations,
        &samples,
    );
}

fn printResult(
    name: []const u8,
    iterations: usize,
    samples: []const Nanoseconds,
) void {
    std.debug.assert(samples.len > 0);
    std.debug.assert(iterations > 0);

    var min_ns: Nanoseconds = samples[0];
    var max_ns: Nanoseconds = samples[0];
    var total_ns: Nanoseconds = 0;

    for (samples) |sample| {
        min_ns = @min(min_ns, sample);
        max_ns = @max(max_ns, sample);
        total_ns += sample;
    }

    const sample_count_i96: Nanoseconds = @intCast(samples.len);
    const iterations_i96: Nanoseconds = @intCast(iterations);

    const average_ns = @divTrunc(total_ns, sample_count_i96);

    std.debug.print(
        "{s}\n" ++
            "  iterations: {d}\n" ++
            "  samples:    {d}\n" ++
            "  min:        {d} ns total, {d} ns/op\n" ++
            "  average:    {d} ns total, {d} ns/op\n" ++
            "  max:        {d} ns total, {d} ns/op\n\n",
        .{
            name,
            iterations,
            samples.len,

            min_ns,
            @divTrunc(min_ns, iterations_i96),

            average_ns,
            @divTrunc(average_ns, iterations_i96),

            max_ns,
            @divTrunc(max_ns, iterations_i96),
        },
    );
}

fn benchEmpty(
    io: Io,
    iterations: usize,
) Nanoseconds {
    const start = Io.Clock.now(.awake, io);

    for (0..iterations) |_| {
        std.mem.doNotOptimizeAway(iterations);
    }

    const end = Io.Clock.now(.awake, io);
    return start.durationTo(end).toNanoseconds();
}

pub fn run(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    _ = try benchScrollFullScreen(io, gpa, warmup_iterations);
    _ = try benchScrollBottomRegion(io, gpa, warmup_iterations);
    _ = try benchScrollTopRegion(io, gpa, warmup_iterations);
    _ = try benchScrollBottomSmallRegion(io, gpa, warmup_iterations);

    inline for (.{
        .{ benchScrollFullScreen, "scrollUp(1), full-screen 24x80" },
        .{ benchScrollBottomRegion, "scrollUp(1), bottom region (2..24)" },
        .{ benchScrollTopRegion, "scrollUp(1), top region (1..23)" },
        .{ benchScrollBottomSmallRegion, "scrollUp(1), small region (21..24)" },
        .{ benchScrollDownBottomRegion, "scrollDown(1), top region (2..24)" },
    }) |entry| {
        const func, const name = entry;
        var samples: [sample_count]Nanoseconds = undefined;
        for (&samples) |*sample| {
            sample.* = try func(io, gpa, measured_iterations);
        }
        printResult(name, measured_iterations, &samples);
    }
}

pub fn runZeroRow(init: std.process.Init) void {
    _ = init;
    // var row: [zero_row_length]Cell = undefined;
    // // Pre-dirty the row so the clear isn't a no-op the compiler could fold away.
    // for (&row) |*c| c.* = Cell{ .codepoint = 'x' };
    //
    // runZeroRowBenchmark(
    //     io,
    //     row[0..],
    //     "zeroRowStos, 80 cells",
    //     screen.zeroRowStos,
    // );
    //
    // runZeroRowBenchmark(
    //     io,
    //     row[0..],
    //     "zeroRowBytes, 80 cells",
    //     screen.zeroRowBytes,
    // );
    //
    // runZeroRowBenchmark(
    //     io,
    //     row[0..],
    //     "zeroRowMemset, 80 cells",
    //     screen.zeroRowMemset,
    // );
    //
    // runZeroRowBenchmark(
    //     io,
    //     row[0..],
    //     "zeroRowVecttor, 80 cells",
    //     screen.zeroRowVector,
    // );
    //
    // runZeroRowBenchmark(
    //     io,
    //     row[0..],
    //     "zeroRowStosb, 80 cells",
    //     screen.zeroRowStosb,
    // );
}