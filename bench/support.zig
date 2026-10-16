const std = @import("std");

const Io = std.Io;
const Clock = std.Io.Clock;
const Allocator = std.mem.Allocator;

pub const Options = struct {
    sample_mib: usize,
    samples: usize,
    filter: ?[]const u8,
    /// Write JSONL results to this path (baseline capture).
    save: ?[]const u8,
    /// Compare against a previously saved JSONL baseline.
    compare: ?[]const u8,
    cost_model: bool,

    pub const default: Options = .{
        .sample_mib = 8,
        .samples = 15,
        .cost_model = false,
        .save = null,
        .compare = null,
        .filter = null,
    };
};

pub const Sample = struct {
    iterations: u64,
    elapsed: Io.Duration,

    pub fn nsPerIteration(self: *const Sample) f64 {
        return @as(f64, @floatFromInt(self.elapsed.toNanoseconds())) / @as(f64, @floatFromInt(self.iterations));
    }
};

// FIXME! needs to implement baseline for compare to other baseline and save results mechanism
pub const Result = struct {
    case: []const u8,
    variant: []const u8,
    min_ns: u64,
    p50_ns: u64,
    checksum: u64,

    /// One line: {"case":"sgr_heavy","variant":"feed_once","min_ns":…,"p50_ns":…,"checksum":"…"}
    /// Checksum is hex so equal-key comparisons in --compare are exact.
    pub fn writeJsonl(self: *const Result, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.print(
            \\{{"case":"{s}","variant":"{s}","min_ns":{d},"p50_ns":{d},"checksum":"{x}"}}  
            \\  
        , .{ self.case, self.variant, self.min_ns, self.p50_ns, self.checksum });
    }

    pub fn key(self: *const Result, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "{s}/{s}", .{ self.case, self.variant });
    }
};

pub const Stats = struct {
    samples: []Sample, // Run order, for drift
    sorted: []f64, // ns/op ascending, or percentiles
    bytes_per_iteration: u64,

    pub fn deinit(self: *const Stats, gpa: Allocator) void {
        gpa.free(self.samples);
        gpa.free(self.sorted);
    }

    pub fn minNsPerIteration(self: *const Stats) f64 {
        var result = std.math.inf(f64);
        for (self.samples) |*s| {
            result = @min(result, s.nsPerIteration());
        }
        return result;
    }

    pub fn meanNsPerIteration(self: *const Stats) f64 {
        var total: f64 = 0;
        for (self.samples) |*s| {
            total += s.nsPerIteration();
        }
        return total / @as(f64, @floatFromInt(self.samples.len));
    }

    pub fn mibPerSec(self: *const Stats, ns_per_op: f64) f64 {
        const bytes: f64 = @floatFromInt(self.bytes_per_iteration);
        return bytes / ns_per_op * 1e9 / (1024.0 * 1024.0);
    }

    /// Linear-interpoolated percentile, p in [0, 100].
    pub fn percentile(self: *const Stats, p: f64) f64 {
        const n = self.sorted.len;
        if (n == 0) return std.math.nan(f64);

        const clamped = std.math.clamp(p, 0.0, 100.0);
        const rank = clamped / 100.0 * @as(f64, @floatFromInt(n - 1));
        const floor_rank = @floor(rank);

        const lo: usize = @intFromFloat(floor_rank);
        const hi = @min(lo + 1, n - 1);
        const frac = rank - floor_rank;

        return self.sorted[lo] + (self.sorted[hi] - self.sorted[lo]) * frac;
    }

    pub fn stddevNsPerIteration(self: *const Stats) f64 {
        const n = self.samples.len;
        if (n < 2) return 0;
        const m = self.meanNsPerIteration();
        var acc: f64 = 0;
        for (self.samples) |*s| {
            const d = s.nsPerIteration() - m;
            acc += d * d;
        }
        return @sqrt(acc / @as(f64, @floatFromInt(n - 1)));
    }

    /// % change from the first half of the runs to the second half.
    /// A consistent sign suggests thermal or frequency drift, not random noise.
    pub fn driftPercent(self: *const Stats) f64 {
        const n = self.samples.len;
        if (n < 4) return 0;
        const half = n / 2;
        var first = std.math.inf(f64);
        var second = std.math.inf(f64);
        for (self.samples[0..half]) |*s| first = @min(first, s.nsPerIteration());
        for (self.samples[n - half ..]) |*s| second = @min(second, s.nsPerIteration());
        return (second - first) / first * 100.0;
    }

    pub fn toResult(
        self: *const Stats,
        case: []const u8,
        variant: []const u8,
        checksum: u64,
    ) Result {
        return .{
            .case = case,
            .variant = variant,
            .min_ns = @intFromFloat(self.minNsPerIteration()),
            .p50_ns = @intFromFloat(self.percentile(50)),
            .checksum = checksum,
        };
    }

    pub fn format(self: *const Stats, writer: *Io.Writer) Io.Writer.Error!void {
        const p50 = self.percentile(50);
        try writer.print(
            \\Benchmark (ns/op)
            \\  min:    {d:.2}
            \\  p50:    {d:.2}
            \\  p90:    {d:.2}
            \\  p95:    {d:.2}
            \\  p99:    {d:.2}
            \\  p99.9:  {d:.2}
            \\  mean:   {d:.2}
            \\  stddev: {d:.2}
            \\  drift:  {d:.1}%
            \\
        , .{
            self.minNsPerIteration(),
            p50,
            self.percentile(90),
            self.percentile(95),
            self.percentile(99),
            self.percentile(99.9),
            self.meanNsPerIteration(),
            self.stddevNsPerIteration(),
            self.driftPercent(),
        });

        if (self.bytes_per_iteration != 0) {
            try writer.print(
                " | best={d:.1} sustained={d:.1} MiB/s",
                .{
                    self.mibPerSec(self.minNsPerIteration()),
                    self.mibPerSec(p50),
                },
            );
        }
    }
};

pub fn run(
    gpa: Allocator,
    io: Io,
    comptime function: anytype,
    context: anytype,
    iterations: u64,
    samples_count: usize,
    bytes_per_iteration: u64,
) !Stats {
    const samples = try gpa.alloc(Sample, samples_count);
    errdefer gpa.free(samples);

    const warmup_iterations = @max(1, iterations / 10);

    // warm up caches, branch predictors, and lazy initilization.
    for (0..warmup_iterations) |_| {
        const r = try @call(.auto, function, .{context});
        std.mem.doNotOptimizeAway(r);
    }

    for (samples) |*sample| {
        const start = Clock.now(.awake, io);
        for (0..iterations) |_| {
            try @call(.auto, function, .{context});
        }
        const end = Clock.now(.awake, io);

        sample.* = .{
            .elapsed = start.durationTo(end),
            .iterations = iterations,
        };
    }

    const sorted = try gpa.alloc(f64, samples_count);
    errdefer gpa.free(sorted);

    for (samples, sorted) |*s, *out| out.* = s.nsPerIteration();
    std.mem.sort(f64, sorted, {}, std.sort.asc(f64));

    return .{
        .samples = samples,
        .sorted = sorted,
        .bytes_per_iteration = bytes_per_iteration,
    };
}
