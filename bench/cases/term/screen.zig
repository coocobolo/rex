const std = @import("std");
const Allocator = std.mem.Allocator;

const rex = @import("rex");

const support = @import("../../support.zig");

const screen = rex.terminal.ScreenV2;
const Cell = rex.terminal.Cell;
const Screen = screen.Screen;

const max_rows = 24;
const max_cols = 80;
const max_scrollback = 8;
const ring_rows = max_rows + max_scrollback;

const Primary = Screen(.{
    .max_rows = max_rows,
    .max_cols = max_cols,
    .tab_width = 8,
    .max_scrollback = max_scrollback,
    .version = "",
    .name = "primary",
});

const Alternate = Screen(.{
    .max_rows = max_rows,
    .max_cols = max_cols,
    .tab_width = 8,
    .max_scrollback = 0,
    .version = "",
    .name = "alternate",
});

const PhysRowContext = struct {
    screen: *Primary,
    current: [*]const usize,
    begin: [*]const usize,
    end: [*]const usize,
};

const Workload = struct {
    name: []const u8,
    buffer: []usize,
};

fn allocSequential(gpa: Allocator, count: usize, active_region: usize) ![]usize {
    const buffer = try gpa.alloc(usize, count);
    for (buffer, 0..) |*buf, i| buf.* = i % active_region;
    return buffer;
}

fn allocInside(
    gpa: Allocator,
    count: usize,
    random: std.Random,
    region_lo: usize,
    region_len: usize,
) ![]usize {
    const buffer = try gpa.alloc(usize, count);
    for (buffer) |*buf| buf.* = region_lo + random.uintLessThan(usize, region_len);
    return buffer;
}

fn allocOutside(
    gpa: Allocator,
    count: usize,
    random: std.Random,
    active_region: usize,
    region_lo: usize,
    region_len: usize,
) ![]usize {
    const buffer = try gpa.alloc(usize, count);
    for (buffer) |*buf| {
        var r = random.uintLessThan(usize, active_region);
        while (r >= region_lo and r < region_lo + region_len) {
            r = random.uintLessThan(usize, active_region);
        }
        buf.* = r;
    }
    return buffer;
}

fn allocConstant(gpa: std.mem.Allocator, count: usize, value: usize) ![]usize {
    const buffer = try gpa.alloc(usize, count);
    for (buffer) |*buf| buf.* = value;
    return buffer;
}

fn allocAlternating(gpa: std.mem.Allocator, count: usize, inside_region: usize, outside_region: usize) ![]usize {
    const buffer = try gpa.alloc(usize, count);
    for (buffer, 0..) |*buf, i| buf.* = if (i % 2 == 0) inside_region else outside_region;
    return buffer;
}

noinline fn benchmarkViewRow(s: anytype, logical_row: usize) usize {
    return s.viewRow(logical_row);
}

noinline fn benchmarkPhysRow(s: anytype, logical_row: usize) usize {
    return s.physRow(logical_row);
}

noinline fn benchmarkFillRows(s: *Primary, start: usize, end: usize, fill: Cell) void {
    s.fillRows(start, end, fill, false);
}

noinline fn benchmarkFillRowsFast(s: *Primary, start: usize, end: usize, fill: Cell) void {
    s.fillRowsFast(start, end, fill, false);
}

pub fn physRowPrecomputed(context: *PhysRowContext) !void {
    const logical_row = context.current[0];

    context.current += 1;
    if (context.current == context.end) {
        context.current = context.begin;
    }

    const physical_row = benchmarkPhysRow(context.screen, logical_row);
    std.mem.doNotOptimizeAway(physical_row);
}

fn runPhysRowCase(
    gpa: std.mem.Allocator,
    io: std.Io,
    s: *Primary,
    rows: []const usize,
    state: Primary.RowMapState,
    name: []const u8,
    iterations: u64,
    samples: usize,
) !void {
    s.row_map_state = state;

    var context = PhysRowContext{
        .screen = s,
        .current = rows.ptr,
        .begin = rows.ptr,
        .end = rows.ptr + rows.len,
    };

    const stats = try support.run(
        gpa,
        io,
        physRowPrecomputed,
        &context,
        iterations,
        samples,
    );
    defer stats.deinit(gpa);

    std.debug.print("{s}: {f}\n", .{ name, stats });
}

pub fn runPhysRow(
    gpa: std.mem.Allocator,
    io: std.Io,
    iterations: u64,
    samples: usize,
) !void {
    var s: Primary = try .create(gpa);
    defer s.destroy(gpa);

    const count: usize = @intCast(iterations);

    var prng = std.Random.DefaultPrng.init(0x1234_5678_9abc_def0);
    const random = prng.random();

    const active_rows: usize = @intCast(s.active_rows);

    // Region geometry, shared by region_offset and permutation states.
    const region_lo = active_rows / 4;
    const requested_region_len = @max(@as(usize, 1), active_rows / 2);
    const region_len = @min(requested_region_len, active_rows - region_lo);
    const region_hi = region_lo + region_len - 1;
    const rotation = region_len / 3;

    const has_outside = region_len < active_rows;

    // --- identity baseline (no region concept, so run separately up front) ---
    const rows_identity_random = try gpa.alloc(usize, count);
    defer gpa.free(rows_identity_random);
    for (rows_identity_random) |*row| row.* = random.uintLessThan(usize, active_rows);

    const rows_identity_sequential = try allocSequential(gpa, count, active_rows);
    defer gpa.free(rows_identity_sequential);

    try runPhysRowCase(gpa, io, &s, rows_identity_random, .identity, "physRow/identity-random", iterations, samples);
    try runPhysRowCase(gpa, io, &s, rows_identity_sequential, .identity, "physRow/identity-sequential", iterations, samples);

    // shared row buffers for region_offset / permutation
    const rows_sequential = try allocSequential(gpa, count, active_rows);
    defer gpa.free(rows_sequential);

    const rows_inside = try allocInside(gpa, count, random, region_lo, region_len);
    defer gpa.free(rows_inside);

    const rows_lo_boundary = try allocConstant(gpa, count, region_lo);
    defer gpa.free(rows_lo_boundary);

    const rows_hi_boundary = try allocConstant(gpa, count, region_hi);
    defer gpa.free(rows_hi_boundary);

    // Only meaningful if there's room outside the region.
    var rows_outside: ?[]usize = null;
    defer if (rows_outside) |r| gpa.free(r);
    var rows_alternating: ?[]usize = null;
    defer if (rows_alternating) |r| gpa.free(r);

    if (has_outside) {
        rows_outside = try allocOutside(gpa, count, random, active_rows, region_lo, region_len);

        const inside_row = region_lo + region_len / 2;
        const outside_row: usize = if (region_lo > 0) region_lo - 1 else region_hi + 1;
        std.debug.assert(outside_row < active_rows);
        rows_alternating = try allocAlternating(gpa, count, inside_row, outside_row);
    }

    var workloads: std.ArrayList(Workload) = .empty;
    defer workloads.deinit(gpa);

    try workloads.append(gpa, .{ .name = "sequential", .buffer = rows_sequential });
    try workloads.append(gpa, .{ .name = "inside", .buffer = rows_inside });
    try workloads.append(gpa, .{ .name = "lo-boundary", .buffer = rows_lo_boundary });
    try workloads.append(gpa, .{ .name = "hi-boundary", .buffer = rows_hi_boundary });
    if (rows_outside) |r| try workloads.append(gpa, .{ .name = "outside", .buffer = r });
    if (rows_alternating) |r| try workloads.append(gpa, .{ .name = "alternating", .buffer = r });

    // Fully materialized permutation: rotation baked into map, offset == 0.
    var map_materialized: [max_rows]u16 = undefined;
    for (&map_materialized, 0..) |*entry, i| entry.* = @intCast(i);
    for (region_lo..region_hi + 1) |r| {
        const local = r - region_lo;
        map_materialized[r] = @intCast((local + rotation) % region_len);
    }
    for (region_lo..region_hi + 1) |r| {
        const local = r - region_lo;
        const expected = (local + rotation) % region_len;
        std.debug.assert(@as(usize, map_materialized[r]) == expected);
    }

    const permutation_materialized_state: Primary.RowMapState = .{
        .permutation = .{
            .lo = @intCast(region_lo),
            .len = @intCast(region_len),
            .offset = 0,
            .map = map_materialized,
        },
    };

    // Pending offset: map is untouched (local == identity within the region),
    // full rotation applied via offset instead — simulates a second scroll
    // stacked on top of an already-materialized permutation.
    var map_pending: [max_rows]u16 = undefined;
    for (&map_pending, 0..) |*entry, i| entry.* = @intCast(i);
    for (region_lo..region_hi + 1) |r| {
        const local = r - region_lo;
        map_pending[r] = @intCast(local); // no rotation baked in yet
    }
    const pending_offset = rotation; // apply rotation via offset instead

    const permutation_pending_state: Primary.RowMapState = .{
        .permutation = .{
            .lo = @intCast(region_lo),
            .len = @intCast(region_len),
            .offset = @intCast(pending_offset),
            .map = map_pending,
        },
    };

    // Verify it matches the same rows region_state/permutation_state produce.
    for (region_lo..region_hi + 1) |r| {
        const local = r - region_lo;
        const expected_mapped_local = (local + rotation) % region_len;
        const actual = (@as(usize, map_pending[r]) + pending_offset) % region_len;
        std.debug.assert(actual == expected_mapped_local);
    }

    const states = [_]struct { name: []const u8, state: Primary.RowMapState }{
        .{
            .name = "region-offset",
            .state = .{ .region_offset = .{
                .lo = @intCast(region_lo),
                .len = @intCast(region_len),
                .offset = @intCast(rotation),
            } },
        },
        .{
            .name = "permutation",
            .state = permutation_materialized_state,
        },
        .{
            .name = "permutation-offset",
            .state = permutation_pending_state,
        },
    };

    for (states) |entry| {
        for (workloads.items) |*wl| {
            const name = try std.fmt.allocPrint(gpa, "physRow/{s}-{s}", .{ entry.name, wl.name });
            defer gpa.free(name);
            try runPhysRowCase(gpa, io, &s, wl.buffer, entry.state, name, iterations, samples);
        }
    }
}

const FillRowsContext = struct {
    s: *Primary,
    start: usize,
    end: usize,
    fill: Cell,
};

pub fn runFillRowsCase(
    gpa: Allocator,
    io: std.Io,
    s: *Primary,
    start: usize,
    end: usize,
    scroll_offset: u32,
    row_map_state: Primary.RowMapState,
    comptime use_fast: bool,
    name: []const u8,
    iterations: u64,
    samples: usize,
) !void {
    s.row_map_state = row_map_state;
    s.scroll_offset = scroll_offset; // explicit reset, every case, every call

    const fill: Cell = .{ .codepoint = 'x' };
    const context: FillRowsContext = .{
        .end = end,
        .start = start,
        .fill = fill,
        .s = s,
    };

    const step = struct {
        fn step(ctx: FillRowsContext) !void {
            if (comptime use_fast) {
                benchmarkFillRowsFast(ctx.s, ctx.start, ctx.end, ctx.fill);
            } else {
                benchmarkFillRows(ctx.s, ctx.start, ctx.end, ctx.fill);
            }
        }
    }.step;

    const stats = try support.run(gpa, io, step, context, iterations, samples);
    defer stats.deinit(gpa);

    std.debug.print("{s}: {f}\n", .{ name, stats });
}

pub fn runFillRows(
    gpa: Allocator,
    io: std.Io,
    iterations: u64,
    samples: usize,
) !void {
    var s: Primary = try .create(gpa);
    defer s.destroy(gpa);

    const active_rows = s.active_rows;
    const region_lo: usize = 4;
    const region_hi: usize = active_rows - 4;
    const region_len = region_hi - region_lo + 1;

    // .region_offset: rotate the sub-region by a fixed, nonzero amount.
    const region_state: Primary.RowMapState = .{
        .region_offset = .{
            .lo = @intCast(region_lo),
            .len = @intCast(region_len),
            .offset = @intCast(region_len / 2),
        },
    };

    // .permutation, contiguous case: a rotation baked into map (best case for
    // run-coalescing — same shape .region_offset produces).
    var map_contig: [max_rows]u16 = undefined;
    for (&map_contig, 0..) |*entry, i| entry.* = @intCast(i);
    for (region_lo..region_hi + 1) |r| {
        const local = r - region_lo;
        map_contig[r] = @intCast((local + region_len / 2) % region_len);
    }
    const permutation_contig_state: Primary.RowMapState = .{
        .permutation = .{
            .lo = @intCast(region_lo),
            .len = @intCast(region_len),
            .offset = 0,
            .map = map_contig,
        },
    };

    // .permutation, scrambled case: reverse the region, which breaks every
    // "consecutive r -> consecutive phys" run (run_len == 1 every step).
    var map_scrambled: [max_rows]u16 = undefined;
    for (&map_scrambled, 0..) |*entry, i| entry.* = @intCast(i);
    for (region_lo..region_hi + 1) |r| {
        const local = r - region_lo;
        map_scrambled[r] = @intCast(region_len - 1 - local);
    }
    const permutation_scrambled_state: Primary.RowMapState = .{
        .permutation = .{
            .lo = @intCast(region_lo),
            .len = @intCast(region_len),
            .offset = 0,
            .map = map_scrambled,
        },
    };

    // Straddles the ring wrap: only meaningful for .identity, needs
    // scroll_offset placed so phys_start + len > ring_rows.

    const cases = [_]struct {
        name: []const u8,
        state: Primary.RowMapState,
        range: struct { start: usize, end: usize },
        scroll_offset: u32 = 0,
    }{
        .{
            .name = "identity-full",
            .state = .identity,
            .range = .{ .start = 0, .end = active_rows },
        },
        .{
            .name = "identity-wrap-straddle",
            .state = .identity,
            .range = .{ .start = 0, .end = 6 },
            .scroll_offset = ring_rows - 3,
        },
        .{
            .name = "region-offset-full",
            .state = region_state,
            .range = .{ .start = 0, .end = active_rows },
        },
        .{
            .name = "region-offset-inside",
            .state = region_state,
            .range = .{ .start = region_lo, .end = region_hi + 1 },
        },
        .{
            .name = "permutation-contig-inside",
            .state = permutation_contig_state,
            .range = .{ .start = region_lo, .end = region_hi + 1 },
        },
        .{
            .name = "permutation-scrambled-inside",
            .state = permutation_scrambled_state,
            .range = .{ .start = region_lo, .end = region_hi + 1 },
        },
    };

    var name_buf: [128]u8 = undefined;
    for (cases) |c| {
        {
            const name = try std.fmt.bufPrint(&name_buf, "fillRows/{s}", .{c.name});

            try runFillRowsCase(
                gpa,
                io,
                &s,
                c.range.start,
                c.range.end,
                c.scroll_offset,
                c.state,
                false,
                name,
                iterations,
                samples,
            );
        }

        {
            const name = try std.fmt.bufPrint(&name_buf, "fillRowsFast/{s}", .{c.name});

            try runFillRowsCase(
                gpa,
                io,
                &s,
                c.range.start,
                c.range.end,
                c.scroll_offset,
                c.state,
                true,
                name,
                iterations,
                samples,
            );
        }
    }
}