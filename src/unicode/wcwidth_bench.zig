const std = @import("std");
const lookup = @import("wcwidth.zig").lookup;
// Set this from turbostat if desired, for example:
//
//     const cpu_frequency_ghz: ?f64 = 3.0;
//
// Leave null if the CPU frequency is dynamic or unknown.
const cpu_frequency_ghz: ?f64 = null;

const batch_count: usize = 20;
const warmup_iterations: usize = 100_000;
const iterations: usize = 10_000_000;

fn loadCorpus(gpa: std.mem.Allocator, data: []const u8) ![]u21 {
    var count: usize = 0;

    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (trimmed.len != 0) {
            count += 1;
        }
    }

    const values = try gpa.alloc(u21, count);
    errdefer gpa.free(values);

    var index: usize = 0;
    lines = std.mem.splitScalar(u8, data, '\n');

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (trimmed.len == 0) continue;

        values[index] = try std.fmt.parseInt(u21, trimmed, 10);
        index += 1;
    }

    return values;
}

const Corpus = struct {
    name: []const u8,
    data: []const u8,
};

const corpora = [_]Corpus{
    .{
        .name = "small-fixed",
        .data = @embedFile("testdata/corpus/small-fixed.txt"),
    },
    .{
        .name = "random-unicode",
        .data = @embedFile("testdata/corpus/random-unicode.txt"),
    },
    .{
        .name = "real-text",
        .data = @embedFile("testdata/corpus/real-text.txt"),
    },
    .{
        .name = "range-boundaries",
        .data = @embedFile("testdata/corpus/range-boundaries.txt"),
    },
    .{
        .name = "ascii-heavy",
        .data = @embedFile("testdata/corpus/ascii-heavy.txt"),
    },
};

fn makeRandomIndices(gpa: std.mem.Allocator, corpus_len: usize) ![]u32 {
    const indices = try gpa.alloc(u32, iterations);
    errdefer gpa.free(indices);

    var prng: std.Random.DefaultPrng = .init(0x9e3779b97f4a7c15);
    const random = prng.random();

    const corpus_len_u32: u32 = @intCast(corpus_len);

    for (indices) |*index| {
        index.* = random.uintLessThan(u32, corpus_len_u32);
    }

    return indices;
}

fn runBenchmark(io: std.Io, gpa: std.mem.Allocator, name: []const u8, inputs: []const u21) !void {
    if (inputs.len == 0) {
        return error.EmptyCorpus;
    }

    // Generate this before the timed sections.
    const indices = try makeRandomIndices(gpa, inputs.len);
    defer gpa.free(indices);

    var lookup_checksum: u64 = 0;
    var baseline_checksum: u64 = 0;

    // Warm up the lookup using the same access pattern.
    for (0..warmup_iterations) |i| {
        const corpus_index = indices[i % indices.len];
        const cp = inputs[@intCast(corpus_index)];

        lookup_checksum += @intFromEnum(lookup(cp));
    }

    var lookup_samples: [batch_count]u64 = undefined;
    var baseline_samples: [batch_count]u64 = undefined;
    var adjusted_samples: [batch_count]u64 = undefined;

    for (0..batch_count) |batch| {
        // Measure the baseline loop.
        const baseline_start = std.Io.Clock.now(.awake, io);

        for (indices) |corpus_index| {
            const cp = inputs[@intCast(corpus_index)];
            baseline_checksum += cp;
        }

        const baseline_end = std.Io.Clock.now(.awake, io);

        const baseline_ns: u64 = @intCast(
            baseline_start.durationTo(baseline_end).toNanoseconds(),
        );

        baseline_samples[batch] = baseline_ns;

        // Measure the lookup loop using exactly the same indices.
        const lookup_start = std.Io.Clock.now(.awake, io);

        for (indices) |corpus_index| {
            const cp = inputs[@intCast(corpus_index)];
            lookup_checksum += @intFromEnum(lookup(cp));
        }

        const lookup_end = std.Io.Clock.now(.awake, io);

        const lookup_ns: u64 = @intCast(
            lookup_start.durationTo(lookup_end).toNanoseconds(),
        );

        lookup_samples[batch] = lookup_ns;

        adjusted_samples[batch] =
            if (lookup_ns > baseline_ns)
                lookup_ns - baseline_ns
            else
                0;
    }

    var lookup_total: u64 = 0;
    var baseline_total: u64 = 0;
    var adjusted_total: u64 = 0;

    var lookup_min: u64 = std.math.maxInt(u64);
    var baseline_min: u64 = std.math.maxInt(u64);
    var adjusted_min: u64 = std.math.maxInt(u64);

    for (0..batch_count) |i| {
        const lookup_ns = lookup_samples[i];
        const baseline_ns = baseline_samples[i];
        const adjusted_ns = adjusted_samples[i];

        lookup_total += lookup_ns;
        baseline_total += baseline_ns;
        adjusted_total += adjusted_ns;

        lookup_min = @min(lookup_min, lookup_ns);
        baseline_min = @min(baseline_min, baseline_ns);
        adjusted_min = @min(adjusted_min, adjusted_ns);
    }

    const lookup_average = lookup_total / batch_count;
    const baseline_average = baseline_total / batch_count;
    const adjusted_average = adjusted_total / batch_count;

    const lookup_ns_per_lookup =
        @as(f64, @floatFromInt(lookup_average)) /
        @as(f64, @floatFromInt(iterations));

    const baseline_ns_per_iteration =
        @as(f64, @floatFromInt(baseline_average)) /
        @as(f64, @floatFromInt(iterations));

    const adjusted_ns_per_lookup =
        @as(f64, @floatFromInt(adjusted_average)) /
        @as(f64, @floatFromInt(iterations));

    const lookup_min_ns_per_lookup =
        @as(f64, @floatFromInt(lookup_min)) /
        @as(f64, @floatFromInt(iterations));

    const adjusted_min_ns_per_lookup =
        @as(f64, @floatFromInt(adjusted_min)) /
        @as(f64, @floatFromInt(iterations));

    const lookup_million_per_second =
        (1_000_000_000.0 / lookup_ns_per_lookup) / 1_000_000.0;

    const adjusted_million_per_second =
        (1_000_000_000.0 / adjusted_ns_per_lookup) / 1_000_000.0;

    std.debug.print(
        \\
        \\Profile: {s}
        \\  corpus size: {}
        \\
        \\Raw lookup:
        \\  average: {d:.2} ns/lookup
        \\  minimum: {d:.2} ns/lookup
        \\  throughput: {d:.2} million lookups/sec
        \\
        \\Baseline:
        \\  average: {d:.2} ns/iteration
        \\
        \\Baseline-adjusted:
        \\  average: {d:.2} ns/lookup
        \\  minimum: {d:.2} ns/lookup
        \\  throughput: {d:.2} million lookups/sec
        \\
        \\Checksums:
        \\  lookup: {}
        \\  baseline: {}
        \\
    , .{
        name,
        inputs.len,

        lookup_ns_per_lookup,
        lookup_min_ns_per_lookup,
        lookup_million_per_second,

        baseline_ns_per_iteration,

        adjusted_ns_per_lookup,
        adjusted_min_ns_per_lookup,
        adjusted_million_per_second,

        lookup_checksum,
        baseline_checksum,
    });

    std.mem.doNotOptimizeAway(lookup_checksum);
    std.mem.doNotOptimizeAway(baseline_checksum);
}

// run cmd:
// $sudo cpupower frequency-set -g performance
// $sudo chrt -r 1 taskset -c 6 ./wcwidth_bench
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    for (corpora) |corpus| {
        const inputs = try loadCorpus(gpa, corpus.data);
        defer gpa.free(inputs);

        try runBenchmark(io, gpa, corpus.name, inputs);
    }
}
