const std = @import("std");
const builtin = @import("builtin");

const Io = std.Io;
const Clock = std.Io.Clock;
const Allocator = std.mem.Allocator;

const baseline_version: u64 = 1;
const flag_threshold_pct: u64 = 3.0;

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

pub const Result = struct {
    case: []const u8,
    variant: []const u8,
    min_ns: u64,
    p50_ns: u64,
    stddev_ns: u64,
    drift_pct: f64, // first-half min, second-half min, %
    checksum: u64,

    /// One line: {"case":"sgr_heavy","variant":"feed_once","min_ns":…,"p50_ns":…,"checksum":"…"}
    /// Checksum is hex so equal-key comparisons in --compare are exact.
    pub fn writeJsonl(self: *const Result, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.print(
            \\{{"case":"{s}","variant":"{s}","min_ns":{d},"p50_ns":{d},"stddev_ns":{d},"drift":{d:.2},"checksum":"{x}"}}
            \\
        , .{ self.case, self.variant, self.min_ns, self.p50_ns, self.stddev_ns, self.drift_pct, self.checksum });
    }

    pub fn key(self: *const Result, buf: []u8) ![]const u8 {
        return try std.fmt.bufPrint(buf, "{s}/{s}", .{ self.case, self.variant });
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

pub const Baseline = struct {
    meta_cpu: ?[]const u8,
    meta_git: ?[]const u8,
    results: std.StringHashMap(Result),

    pub fn deinit(self: *Baseline, gpa: Allocator) void {
        var it = self.results.iterator();
        while (it.next()) |e| gpa.free(e.key_ptr.*);
        self.results.deinit();
        if (self.meta_cpu) |s| gpa.free(s);
        if (self.meta_git) |s| gpa.free(s);
    }

    pub fn loadBaseline(gpa: Allocator, io: Io, path: []const u8) !Baseline {
        var base: Baseline = .{
            .meta_cpu = null,
            .meta_git = null,
            .results = .init(gpa),
        };
        errdefer base.deinit(gpa);

        const file = try std.Io.Dir.openFile(.cwd(), io, path, .{});
        defer file.close(io);

        var buf: [8 << 10]u8 = undefined;
        var fr = file.reader(io, &buf);
        const r = &fr.interface;

        while (r.takeDelimiter('\n') catch null) |line| {
            if (line.len == 0) continue;
            const parsed = std.json.parseFromSlice(std.json.Value, gpa, line, .{}) catch continue;
            defer parsed.deinit();
            const obj = parsed.value.object;

            if (obj.get("meta")) |m| {
                if (m.object.get("cpu")) |cpu| base.meta_cpu = try gpa.dupe(u8, cpu.string);
                if (m.object.get("git")) |git| base.meta_git = try gpa.dupe(u8, git.string);
                continue;
            }

            var result: Result = undefined;
            result.case = try gpa.dupe(u8, obj.get("case").?.string);
            result.variant = try gpa.dupe(u8, obj.get("variant").?.string);
            result.min_ns = @intCast(obj.get("min_ns").?.integer);
            result.p50_ns = @intCast(obj.get("p50_ns").?.integer);
            result.stddev_ns = if (obj.get("stddev_ns")) |v| @intCast(v.integer) else 0;
            result.drift_pct = if (obj.get("drift")) |v| v.float else 0;
            const chk = obj.get("checksum").?.string;
            result.checksum = std.fmt.parseInt(u46, chk, 16) catch 0;

            var keybuf: [1 << 10]u8 = undefined;
            const key = try gpa.dupe(u8, try result.key(&keybuf));
            try base.results.put(key, result);
        }
        return base;
    }
};

pub fn compareResults(
    gpa: Allocator,
    io: Io,
    baseline_path: []const u8,
    results: []const Result,
) !void {
    var base = try Baseline.loadBaseline(gpa, io, baseline_path);
    defer base.deinit(gpa);

    // machine check, a diff across different CPUs is meanngless.
    if (base.meta_cpu) |cpu| {
        if (!std.mem.eql(u8, cpu, builtin.cpu.model.name)) {
            std.debug.print("warning: baseline captured on '{s}', running on '{s}' deltas are machine noise", .{
                cpu, builtin.cpu.model.name,
            });
        }
    }
    if (base.meta_git) |sha| {
        const current = gitShortSha(gpa, io) orelse "unknown";
        if (!std.mem.eql(u8, sha, current)) {
            std.debug.print("note: baseline git={x}, current={x}\n", .{ sha, current });
        }
    }

    var keybuf: [256]u8 = undefined;
    for (results) |*r| {
        const key = try r.key(&keybuf);
        const b = base.results.get(key) orelse {
            std.debug.print("{s}: (new)\n", .{key});
            continue;
        };

        if (b.checksum != r.checksum) {
            std.debug.print("{s}: (CHECKSUM CHANGED {x} => {x})\n", .{ key, b.checksum, r.checksum });
        }
        const delta = @as(f64, @floatFromInt(r.min_ns)) / @as(f64, @floatFromInt(b.min_ns)) - 1.0;
        const mark: []const u8 = if (@abs(delta) < 0.03) " " else if (delta < 0) "v" else "x";
        std.debug.print("{s}{s}: {d:.1}% (min {d} -> {d} ns", .{
            mark, key, delta * 100.0, b.min_ns, r.min_ns,
        });
        // If the baseline row itself was noisy, flag it instead of trusting the delta.
        if (@abs(b.drift_pct) > 10) {
            std.debug.print(", baseline drift {d:.1}% — suspect)", .{b.drift_pct});
        } else std.debug.print(")", .{});
        std.debug.print("\n", .{});
    }
}

pub fn saveResults(gpa: Allocator, io: Io, path: []const u8, results: []const Result) !void {
    const file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);

    var buf: [4 << 10]u8 = undefined;
    var fw = file.writer(io, &buf);
    const w = &fw.interface;

    // Meta header, identifies the file and lets future compare reject stale
    // baselines (schema bump, different machine, different build).
    try w.print(
        \\{{"meta":{{"version":{d},"git":"{s}","cpu":"{s}"}}}}
        \\
    ,
        .{
            baseline_version,
            gitShortSha(gpa, io) orelse "unknown",
            builtin.cpu.model.name,
        },
    );

    for (results) |*r| try r.writeJsonl(w);
    try w.flush();
    std.debug.print("saved: {d} results to {s}\n", .{ results.len, path });
}

/// `git rev-parse --short HEAD`, best-effort. Returns error on any failure.
fn gitShortSha(gpa: Allocator, io: Io) ?[]const u8 {
    var child = std.process.spawn(io, .{
        .argv = &.{ "git", "rev-parse", "--short", "HEAD" },
        .stdin = .ignore,
        .stderr = .ignore,
        .stdout = .pipe,
    }) catch |err| {
        std.debug.print("gitShortSha: spawn failed: {s}\n", .{@errorName(err)});
        return null;
    };

    defer if (child.id != null) {
        _ = child.wait(io) catch |err| {
            std.debug.print("gitShortSha: deferred wait failed: {s}\n", .{@errorName(err)});
        };
    };

    const stdout = child.stdout orelse return null;

    var buf: [4 << 10]u8 = undefined;
    var reader = stdout.reader(io, &buf);
    const out = reader.interface.takeDelimiter('\n') catch |err| {
        std.debug.print("gitShortSha: reading stdout failed: {s}\n", .{@errorName(err)});
        _ = child.wait(io) catch |wait_err| {
            std.debug.print("gitShortSha: wait after read failure failed: {s}\n", .{@errorName(wait_err)});
        };
        return null;
    } orelse return null;

    const term = child.wait(io) catch |err| {
        std.debug.print("gitShortSha: wait failed: {s}\n", .{@errorName(err)});
        return null;
    };

    if (term != .exited or term.exited != 0) return null;

    const sha = std.mem.trim(u8, out, " \n\r\t");
    return if (sha.len > 0)
        gpa.dupe(u8, sha) catch |err| {
            std.debug.print("gitShortSha: copying SHA failed: {s}\n", .{@errorName(err)});
            return null;
        }
    else
        null;
}

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
