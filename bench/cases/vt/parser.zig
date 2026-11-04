//! VT parser benchmark: feed-shape x content matrix, plus a cost model.
//!
//! Two dispatchers are used on purpose:
//!
//!   * CountingDispatcher: O(1) work per bulk call (`print` adds `bytes.len`).
//!     Used for all timing, so the numbers are the parser's, not the handler's.
//!   * ChecksumDispatcher (NoopDispatcher): touches every byte with a
//!     multiply-add. Used to verify that content is routed correctly, and for
//!     one reference timing per case that shows what the handler costs.
//!
//! Before timing, every feed shape is verified against `feed_once` with BOTH
//! dispatchers. Any mismatch prints a line starting with `!!`.
//!
//! Filtering: `opts.filter` is a comma-separated list of substrings. A variant
//! runs filter if its `case/variant` label contains one of them, e.g.
//!   plain_lines_64k/feed_once        one variant of one case
//!   /feed_once                       feed_once for every case
//!   htop,man_bash                    every variant of two cases
//!
//! Cost model (`opts.cost_model`): streams made of one repeated unit, so that
//! ns/unit can be split into a fixed per-unit cost and a per-byte or per-param
//! cost by a least-squares fit.

// TODO!
//
// Add the remaining content cases (sgr_colon, esc_intermediates, utf8_mixed, c1_8bit).
// Nothing in this run covers UTF-8 or latin1 paths.

const std = @import("std");

const Io = std.Io;
const Allocator = std.mem.Allocator;

const rex = @import("rex");

const vt = rex.vt.parser;
const Parser = vt.Parser;
const ChecksumDispatcher = vt.ChecksumDispatcher;
const support = @import("../../support.zig");
const Options = support.Options;
const Result = support.Result;

const suite = "vt";

const corpus_dir = "bench/cases/vt/testdata/corpus/";
const corpus_names = [_][]const u8{
    "ls_color",
    "htop",
    "man_bash",
};

const mib = 1024 * 1024;
/// Size of the generated print-heavy inputs: bigger than L1, like a large PTY read.
const generated_len = 64 * 1024;

const random_seed: u64 = 0x5eed_cafe;
const random_max_chunk: u32 = 256;
const random_variant = "random_1_256";
const recorded_variant = "recorded";
const reference_variant = "feed_once+checksum";

/// CAN forces the parser back to ground, so every iteration starts in the same state.
const can: u8 = 0x18;

/// Also time `feed_once` with the checksum dispatcher and print the difference.
const compare_checksum_dispatcher = true;

/// Size of each single-event cost-model stream.
const cost_case_len = 16 * 1024;

/// Print-run lengths (bytes before each LF) for the cost-model sweep.
const cost_run_lengths = [_]usize{ 1, 4, 16, 64, 256, 1024 };

/// Parameter counts for the CSI sweep. 20 is above `max_params = 16`.
const cost_csi_params = [_]usize{ 0, 1, 4, 16, 20 };

// Dispatcher

// Cheap handler for timing. Bulk calls are O(1); Per-sequence work is O(params)
// so the parser can't skip computing paramter values. All fields are invariant
// to how the input is chunked.
const CountingDispatcher = struct {
    printed: u64 = 0,
    executed: u64 = 0,
    esc_finals: u64 = 0,
    csi_finals: u64 = 0,
    param_sum: u64 = 0,
    dcs_events: u64 = 0,
    dcs_bytes: u64 = 0,
    osc_events: u64 = 0,
    osc_bytes: u64 = 0,

    pub fn print(self: *@This(), bytes: []const u8) void {
        self.printed +%= @as(u64, bytes.len);
    }
    pub fn printByte(self: *@This(), _: u8) void {
        self.printed +%= 1;
    }
    pub fn execute(self: *@This(), b: u8) void {
        self.executed +%= b;
    }
    pub fn escDispatch(self: *@This(), final: u8, _: []const u8) void {
        self.esc_finals +%= final;
    }
    pub fn csiDispatch(self: *@This(), final: u8, _: []const u8, params: anytype) void {
        self.csi_finals +%= final;
        for (params) |p| self.param_sum +%= p.value;
    }
    pub fn hook(self: *@This(), final: u8, _: []const u8, params: anytype) void {
        self.dcs_events +%= final;
        for (params) |p| self.param_sum +%= p.value;
    }
    pub fn dcsPut(self: *@This(), _: u8) void {
        self.dcs_bytes +%= 1;
    }
    pub fn dcsPutSlice(self: *@This(), bytes: []const u8) void {
        self.dcs_bytes +%= @as(u64, bytes.len);
    }
    pub fn unhook(self: *@This()) void {
        self.dcs_events +%= 1;
    }
    pub fn oscStart(self: *@This()) void {
        self.osc_events +%= 1;
    }
    pub fn oscPut(self: *@This(), _: u8) void {
        self.osc_bytes +%= 1;
    }
    pub fn oscPutSlice(self: *@This(), bytes: []const u8) void {
        self.osc_bytes +%= @as(u64, bytes.len);
    }
    pub fn oscEnd(self: *@This()) void {
        self.osc_events +%= 1;
    }

    pub fn reset(self: *@This()) void {
        self.* = .{};
    }

    /// Folds every counter into one value for cross-shape comparison.
    pub fn fingerprint(self: *const @This()) u64 {
        var h: u64 = 0;
        inline for (std.meta.fields(@This())) |f| {
            h = (h ^ @field(self, f.name)) *% 0x9e37_79b9_7f4a_7c15;
        }
        return h;
    }
};

/// One comparable number from either dispatcher.
fn fingerprint(h: anytype) u64 {
    const T = @TypeOf(h.*);
    return if (@hasDecl(T, "fingerprint")) h.fingerprint() else h.checksum;
}

// Parser context and feed shapes

fn Context(comptime Dispatcher: type) type {
    return struct {
        h: Dispatcher = .{},
        p: Parser(Dispatcher, .{}) = .{},
        bytes: []const u8,
        /// Chunk lengths, used only by `feedPlan`.
        plan: []const u32 = &.{},
    };
}

/// The whole input in a single call: the ceiling number.
fn feedOnce(ctx: anytype) !void {
    ctx.p.feedBytes(&ctx.h, ctx.bytes);
    std.mem.doNotOptimizeAway(&ctx.h);
}

/// Fixed-size slices. `n` is comptime so `Chunked(1)` is a true
/// one-byte-per-call stress case.
fn Chunked(comptime n: usize) type {
    return struct {
        fn feed(ctx: anytype) !void {
            var rest = ctx.bytes;
            while (rest.len > 0) {
                const take = @min(n, rest.len);
                ctx.p.feedBytes(&ctx.h, rest[0..take]);
                rest = rest[take..];
            }
            std.mem.doNotOptimizeAway(&ctx.h);
        }
    };
}

/// Replays a precomputed list of chunk lengths, then feeds whatever is left
/// (e.g. the trailing CAN). Used for both the seeded-random and the recorded
/// PTY plans; all randomness happens outside the timed region.
fn feedPlan(ctx: anytype) !void {
    var rest = ctx.bytes;
    for (ctx.plan) |len| {
        if (rest.len == 0) break;
        const take = @min(len, rest.len);
        ctx.p.feedBytes(&ctx.h, rest[0..take]);
        rest = rest[take..];
    }

    if (rest.len > 0) ctx.p.feedBytes(&ctx.h, rest);
    std.mem.doNotOptimizeAway(&ctx.h);
}

/// Shapes that need no plan. `divisor` shrinks the iteration count for slow
/// shapes; MiB/s stays comparable because it is derived from bytes per iteration.
const shape_variants = .{
    .{ .name = "feed_once", .feed = feedOnce, .divisor = 1 },
    .{ .name = "chunked_4096", .feed = Chunked(4096).feed, .divisor = 1 },
    .{ .name = "chunked_64", .feed = Chunked(64).feed, .divisor = 4 },
    .{ .name = "feed_byte", .feed = Chunked(1).feed, .divisor = 16 },
};

const plan_divisor = 4;

// Filtering

fn allowed(filter: ?[]const u8, name: []const u8, variant: []const u8) bool {
    const terms = filter orelse return true;
    var buf: [128]u8 = undefined;
    const label = std.fmt.bufPrint(&buf, "{s}/{s}", .{ name, variant }) catch return true;

    var it = std.mem.tokenizeScalar(u8, terms, ',');
    while (it.next()) |term| {
        if (std.mem.indexOf(u8, label, term) != null) return true;
    }

    return false;
}

fn anyAllowed(filter: ?[]const u8, name: []const u8, has_recorded: bool) bool {
    inline for (shape_variants) |v| {
        if (allowed(filter, name, v.name)) return true;
    }

    if (allowed(filter, name, random_variant)) return true;
    if (has_recorded and allowed(filter, name, recorded_variant)) return true;
    if (compare_checksum_dispatcher and allowed(filter, name, reference_variant)) return true;

    return false;
}

// Inputs: plans, files, generated text

/// Random chunk lengths in [1, max_chunk] that cover at least `total` bytes.
fn buildRandomPlan(gpa: Allocator, total: usize, max_chunk: u32, seed: u64) ![]u32 {
    var prng = std.Random.DefaultPrng.init(seed);
    const rng = prng.random();

    var list: std.ArrayList(u32) = .empty;
    errdefer list.deinit(gpa);

    var covered: usize = 0;
    while (covered < total) {
        const len = rng.intRangeAtMost(u32, 1, max_chunk);
        try list.append(gpa, len);
        covered += len;
    }
    return list.toOwnedSlice(gpa);
}

/// Parses a `.plan` file (one decimal byte count per line, as written by
/// capture-corpus.sh). The counts must add up to exactly `expected_total`.
fn parsePlan(gpa: Allocator, text: []const u8, expected_total: usize) ![]u32 {
    var list: std.ArrayList(u32) = .empty;
    errdefer list.deinit(gpa);

    var covered: usize = 0;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const n = try std.fmt.parseInt(u32, std.mem.trim(u8, line, " \r"), 10);
        if (n == 0) continue;
        try list.append(gpa, n);
        covered += n;
    }

    if (covered != expected_total) return error.PlanLengthMismatch;
    return list.toOwnedSlice(gpa);
}

fn readFile(io: Io, gpa: Allocator, path: []const u8) ![]u8 {
    var file = try Io.Dir.openFile(.cwd(), io, path, .{ .mode = .read_only });
    defer file.close(io);

    var buffer: [16 * 1024]u8 = undefined;
    var reader = file.reader(io, &buffer);
    return try reader.interface.allocRemaining(gpa, .unlimited);
}

/// Copy of `data` with a trailing CAN.
fn appendCan(gpa: Allocator, data: []const u8) ![]u8 {
    const out = try gpa.alloc(u8, data.len + 1);
    @memcpy(out[0..data.len], data);
    out[data.len] = can;
    return out;
}

/// `len` bytes of random printable ASCII (0x20..0x7e): one long print run.
fn genPlainAscii(gpa: Allocator, len: usize, seed: u64) ![]u8 {
    const buf = try gpa.alloc(u8, len);
    errdefer gpa.free(buf);

    var prng = std.Random.DefaultPrng.init(seed);
    const rng = prng.random();
    for (buf) |*b| b.* = rng.intRangeAtMost(u8, 0x20, 0x7e);
    return buf;
}

/// Text shaped like `cat`/`man` output: lines of 20..100 printable bytes, each ended by CRLF.
fn genPlainLines(gpa: Allocator, len: usize, seed: u64) ![]u8 {
    const buf = try gpa.alloc(u8, len);
    errdefer gpa.free(buf);

    var prng = std.Random.DefaultPrng.init(seed);
    const rng = prng.random();

    var i: usize = 0;
    while (i < len) {
        const text = @min(rng.intRangeAtMost(usize, 20, 100), len - i);
        for (buf[i..][0..text]) |*b| b.* = rng.intRangeAtMost(u8, 0x20, 0x7e);
        i += text;
        if (i < len) {
            buf[i] = '\r';
            i += 1;
        }
        if (i < len) {
            buf[i] = '\n';
            i += 1;
        }
    }
    return buf;
}

/// Units of `run_len` random printable bytes followed by one LF, filling exactly `len` bytes.
/// `len` should be a multiple of `run_len + 1` so every unit is complete.
fn genRuns(gpa: Allocator, len: usize, run_len: usize, seed: u64) ![]u8 {
    const buf = try gpa.alloc(u8, len);
    errdefer gpa.free(buf);

    var prng = std.Random.DefaultPrng.init(seed);
    const rng = prng.random();

    var i: usize = 0;
    while (i < len) {
        const text = @min(run_len, len - i);
        for (buf[i..][0..text]) |*b| b.* = rng.intRangeAtMost(u8, 0x20, 0x7e);
        i += text;
        if (i < len) {
            buf[i] = '\n';
            i += 1;
        }
    }

    return buf;
}

/// `unit` repeated `reps` times, built at compile time.
fn repeatUnit(comptime unit: []const u8, comptime reps: usize) [unit.len * reps]u8 {
    @setEvalBranchQuota(unit.len * reps + 2 << 10);
    var out: [unit.len * reps]u8 = undefined;
    for (0..reps) |i| @memcpy(out[i * unit.len ..][0..unit.len], unit);
    return out;
}

/// `ESC [ 1;1;...;1 m` with `n` parameters (`ESC [ m` for 0).
fn csiUnit(comptime n: usize) []const u8 {
    if (n == 0) return "\x1b[m";
    return "\x1b[" ++ "1;" ** (n - 1) ++ "1m";
}

/// Everything that stays constant while one case runs through its variants.
const CaseRun = struct {
    io: Io,
    gpa: Allocator,
    name: []const u8,
    result_case: []const u8, // "<suite>.<name>": saved in Result.case
    bytes: []const u8,
    sample_bytes: usize,
    samples: usize,
    filter: ?[]const u8,
    /// `feed_once` fingerprints; every other shape must match them.
    expected_checksum: u64,
    expected_counts: u64,
};

fn fingerprintOf(comptime D: type, comptime feed: anytype, bytes: []const u8, plan: []const u32) !u64 {
    var ctx: Context(D) = .{ .bytes = bytes, .plan = plan };
    try feed(&ctx);
    return fingerprint(&ctx.h);
}

/// Untimed: the shape must agree with `feed_once` under both dispatchers.
fn verify(run: CaseRun, variant: []const u8, comptime feed: anytype, plan: []const u32) !void {
    const sum = try fingerprintOf(ChecksumDispatcher, feed, run.bytes, plan);
    if (sum != run.expected_checksum) {
        std.debug.print("!! {s}/{s}: checksum {x} != feed_once {x}\n", .{
            run.name,
            variant,
            sum,
            run.expected_checksum,
        });
    }
    const cnt = try fingerprintOf(CountingDispatcher, feed, run.bytes, plan);
    if (cnt != run.expected_counts) {
        std.debug.print("!! {s}/{s}: counts {x} != feed_once {x}\n", .{
            run.name,
            variant,
            cnt,
            run.expected_counts,
        });
    }
}

/// Times one feed shape with dispatcher `D`. Returns min ns per iteration.
fn measure(
    run: CaseRun,
    comptime D: type,
    variant: []const u8,
    tag: []const u8,
    comptime feed: anytype,
    divisor: usize,
    plan: []const u32,
    results: ?*std.ArrayList(Result),
) !f64 {
    var label_buf: [64]u8 = undefined;
    const label = std.fmt.bufPrint(&label_buf, "{s}/{s}{s}", .{ run.name, variant, tag }) catch run.name;

    var ctx: Context(D) = .{ .bytes = run.bytes, .plan = plan };
    const iterations = @max(1, run.sample_bytes / @max(1, run.bytes.len) / divisor);
    var stats = try support.run(
        run.gpa,
        run.io,
        feed,
        &ctx,
        iterations,
        run.samples,
        run.bytes.len,
    );
    defer stats.deinit(run.gpa);

    // fingerprint exactly ONE pass, not `iterations` passes
    ctx.h.reset();
    _ = try feed(&ctx);

    const fp = fingerprint(&ctx.h);
    const min_ns = stats.minNsPerIteration();

    std.debug.print("{s:<32} {f}  checksum={x}\n", .{ label, stats, fp });

    if (results) |list| {
        try list.append(run.gpa, .{
            .case = run.result_case,
            .variant = if (tag.len > 0) try std.fmt.allocPrint(run.gpa, "{s}{s}", .{ variant, tag }) else variant,
            .min_ns = @intFromFloat(min_ns),
            .p50_ns = @intFromFloat(stats.percentile(50)),
            .checksum = fp,
            .drift_pct = stats.driftPercent(),
            .stddev_ns = @intFromFloat(stats.stddevNsPerIteration()),
        });
    }

    return min_ns;
}

/// Verifies a feed shape, then times it with the counting dispatcher.
/// Returns null if the filter excludes the variant.
fn runVariant(
    run: CaseRun,
    variant: []const u8,
    comptime feed: anytype,
    divisor: usize,
    plan: []const u32,
    results: ?*std.ArrayList(Result),
) !?f64 {
    if (!allowed(run.filter, run.name, variant)) return null;
    try verify(run, variant, feed, plan);
    return try measure(run, CountingDispatcher, variant, "", feed, divisor, plan, results);
}

/// Runs one input through every feed shape that passes the filter. `recorded`
/// is the real PTY chunk plan for corpus files, null otherwise.
/// Returns the min ns/op of `feed_once` (counting dispatcher), or null if it did not run.
fn benchCase(
    io: Io,
    gpa: Allocator,
    name: []const u8,
    bytes: []const u8,
    recorded: ?[]const u32,
    opts: Options,
    results: ?*std.ArrayList(Result),
) !?f64 {
    if (!anyAllowed(opts.filter, name, recorded != null)) return null;

    printProfile(name, bytes);

    const random_plan = try buildRandomPlan(gpa, bytes.len, random_max_chunk, random_seed);
    defer gpa.free(random_plan);

    const result_case = try std.fmt.allocPrint(gpa, "{s}.{s}", .{ suite, name });

    const run: CaseRun = .{
        .io = io,
        .gpa = gpa,
        .name = name,
        .result_case = result_case,
        .bytes = bytes,
        .sample_bytes = opts.sample_mib * mib,
        .samples = opts.samples,
        .filter = opts.filter,
        .expected_checksum = try fingerprintOf(ChecksumDispatcher, feedOnce, bytes, &.{}),
        .expected_counts = try fingerprintOf(CountingDispatcher, feedOnce, bytes, &.{}),
    };

    var once_min: ?f64 = null;
    inline for (shape_variants) |v| {
        const min_ns = try runVariant(run, v.name, v.feed, v.divisor, &.{}, results);
        if (comptime std.mem.eql(u8, v.name, "feed_once")) once_min = min_ns;
    }
    _ = try runVariant(run, random_variant, feedPlan, plan_divisor, random_plan, results);
    if (recorded) |plan| {
        _ = try runVariant(run, recorded_variant, feedPlan, plan_divisor, plan, results);
    }

    if (compare_checksum_dispatcher and allowed(opts.filter, name, reference_variant)) {
        const checksum_min = try measure(
            run,
            ChecksumDispatcher,
            "feed_once",
            "+checksum",
            feedOnce,
            1,
            &.{},
            results,
        );

        const percent_floor_ns: f64 = 100.0;

        if (once_min) |base_ns| {
            const delta_ns = checksum_min - base_ns;

            if (base_ns > percent_floor_ns) {
                const delta_percent = (delta_ns / base_ns) * 100.0;
                std.debug.print(
                    "{s}/dispatcher_cost  {d:.1} ns/op ({d:.1}%)\n",
                    .{ name, delta_ns, delta_percent },
                );
            } else {
                std.debug.print(
                    "{s}/dispatcher_cost  {d:.1} ns/op (base {d:.1} ns/op)\n",
                    .{ name, delta_ns, base_ns },
                );
            }
        }
    }
    return once_min;
}

/// One line describing how escape-dense an input is, so MiB/s differences
/// between inputs can be attributed to content rather than guessed at.
fn printProfile(name: []const u8, bytes: []const u8) void {
    var esc: usize = 0;
    var c0: usize = 0;
    var high: usize = 0;
    for (bytes) |b| {
        if (b == 0x1b) {
            esc += 1;
        } else if (b < 0x20) {
            c0 += 1;
        } else if (b >= 0x80) {
            high += 1;
        }
    }

    const kib = @as(f64, @floatFromInt(bytes.len)) / 1024.0;
    std.debug.print(
        "profile {s:<16} {d} B  esc/KiB={d:.1}  c0/KiB={d:.1}  high/KiB={d:.1}\n",
        .{
            name,
            bytes.len,
            @as(f64, @floatFromInt(esc)) / kib,
            @as(f64, @floatFromInt(c0)) / kib,
            @as(f64, @floatFromInt(high)) / kib,
        },
    );
}

const Synthetic = struct { name: []const u8, bytes: []const u8 };

const synthetic_cases = [_]Synthetic{
    .{ .name = "plain_text", .bytes = "Hello, World! " ** 1000 },
    .{ .name = "sgr_normal", .bytes = "\x1b[1;2;3;0mcolored\x1b[0m " ** 1000 },
    // digits parser SWAR path is deleted
    .{ .name = "sgr_overflow", .bytes = "\x1b[38;2;255;12345678;0mcolored\x1b[0m " ** 1000 },
    .{ .name = "osc_title", .bytes = "\x1b]0;My Title\x07" ** 1000 },
    .{ .name = "dcs_passthrough", .bytes = "\x1bPq#0;2;0;0;0#1~~~~\x1b\\" ** 1000 },
};

pub fn runDispatcher(io: Io, gpa: Allocator, opts: Options, results: *std.ArrayList(Result)) !void {
    for (synthetic_cases) |case| {
        _ = try benchCase(io, gpa, case.name, case.bytes, null, opts, results);
    }

    // Print-heavy inputs. `plain_text` above is 14 KB and L1-resident; these
    // are 64 KiB so the print path is measured on a PTY-sized read.
    const ascii_name = "plain_ascii_64k";
    if (anyAllowed(opts.filter, ascii_name, false)) {
        const ascii = try genPlainAscii(gpa, generated_len, random_seed);
        defer gpa.free(ascii);
        _ = try benchCase(io, gpa, ascii_name, ascii, null, opts, results);
    }

    const lines_name = "plain_lines_64k";
    if (anyAllowed(opts.filter, lines_name, false)) {
        const lines = try genPlainLines(gpa, generated_len, random_seed);
        defer gpa.free(lines);
        _ = try benchCase(io, gpa, lines_name, lines, null, opts, results);
    }
}

/// Real PTY captures made by scripts/capture-corpus.sh. Corpus files are much
/// larger than the synthetic strings, so each sample runs filter a few iterations.
pub fn runCorpus(io: Io, gpa: Allocator, opts: Options, results: *std.ArrayList(Result)) !void {
    for (corpus_names) |name| {
        if (!anyAllowed(opts.filter, name, true)) continue;

        const raw_path = try std.fmt.allocPrint(gpa, "{s}{s}.raw", .{ corpus_dir, name });
        defer gpa.free(raw_path);
        const plan_path = try std.fmt.allocPrint(gpa, "{s}{s}.plan", .{ corpus_dir, name });
        defer gpa.free(plan_path);

        const raw = try readFile(io, gpa, raw_path);
        defer gpa.free(raw);
        const plan_text = try readFile(io, gpa, plan_path);
        defer gpa.free(plan_text);

        // The plan covers the capture fileter; feedPlan feeds the trailing CAN as the remainder.
        const plan = try parsePlan(gpa, plan_text, raw.len);
        defer gpa.free(plan);

        const bytes = try appendCan(gpa, raw);
        defer gpa.free(bytes);

        _ = try benchCase(io, gpa, name, bytes, plan, opts, results);
    }
}

/// Prints ns/unit for a stream made of `units` identical units. Returns ns/unit,
/// or null if the case did not run.
fn reportPerUnit(name: []const u8, min_ns: ?f64, units: usize, bytes_len: usize) ?f64 {
    const ns = min_ns orelse return null;
    const per_unit = ns / @as(f64, @floatFromInt(units));
    std.debug.print(
        "{s}/per_unit  {d:.2} ns/unit  {d:.3} ns/byte  ({d} units)\n",
        .{ name, per_unit, ns / @as(f64, @floatFromInt(bytes_len)), units },
    );
    return per_unit;
}

const Fit = struct { intercept: f64, slope: f64, r2: f64 };

/// Least-squares line y = intercept + slope * x.
fn fitLine(xs: []const f64, ys: []const f64) Fit {
    const n: f64 = @floatFromInt(xs.len);
    var sx: f64 = 0;
    var sy: f64 = 0;
    var sxx: f64 = 0;
    var sxy: f64 = 0;
    for (xs, ys) |x, y| {
        sx += x;
        sy += y;
        sxx += x * x;
        sxy += x * y;
    }
    const slope = (n * sxy - sx * sy) / (n * sxx - sx * sx);
    const intercept = (sy - slope * sx) / n;

    const mean_y = sy / n;
    var ss_res: f64 = 0;
    var ss_tot: f64 = 0;
    for (xs, ys) |x, y| {
        const e = y - (intercept + slope * x);
        ss_res += e * e;
        ss_tot += (y - mean_y) * (y - mean_y);
    }
    return .{
        .intercept = intercept,
        .slope = slope,
        .r2 = if (ss_tot == 0) 1.0 else 1.0 - ss_res / ss_tot,
    };
}

fn reportFit(label: []const u8, x_name: []const u8, xs: []const f64, ys: []const f64) void {
    if (xs.len < 2) return;
    const fit = fitLine(xs, ys);
    std.debug.print(
        "fit {s}: ns/unit = {d:.2} + {d:.3} * {s}   (R^2 {d:.3}, {d} points)\n",
        .{ label, fit.intercept, fit.slope, x_name, fit.r2, xs.len },
    );
}

/// Splits the cost of an event into a fixed part and a variable part.
///
///   * single-event streams: ns per `\n` and per `ESC 7`, with no print runs.
///   * CSI sweep: ns/unit vs parameter count -> per-sequence and per-parameter cost.
///   * run sweep: ns/unit vs print-run length -> per-run restart cost (including
///     the LF execute) and per-print-byte cost.
///
/// Only `feed_once` is timed unless `--filter` says otherwise.
pub fn runCostModel(io: Io, gpa: Allocator, base_opts: Options, results: *std.ArrayList(Result)) !void {
    var opts = base_opts;
    if (opts.filter == null) opts.filter = "/feed_once";

    std.debug.print("\n== cost model ==\n", .{});

    inline for (.{
        .{ "c0_lf", "\n" },
        .{ "esc_dispatch", "\x1b7" },
    }) |e| {
        const units = cost_case_len / e[1].len;
        const bytes = comptime repeatUnit(e[1], units);
        const min_ns = try benchCase(io, gpa, e[0], &bytes, null, opts, results);
        _ = reportPerUnit(e[0], min_ns, units, bytes.len);
    }

    var csi_x: [cost_csi_params.len]f64 = undefined;
    var csi_y: [cost_csi_params.len]f64 = undefined;
    var csi_n: usize = 0;
    inline for (cost_csi_params) |n| {
        const unit = comptime csiUnit(n);
        const units = cost_case_len / unit.len;
        const bytes = comptime repeatUnit(unit, units);
        const name = comptime std.fmt.comptimePrint("csi_p{d}", .{n});

        const min_ns = try benchCase(io, gpa, name, &bytes, null, opts, results);
        if (reportPerUnit(name, min_ns, units, bytes.len)) |per_unit| {
            csi_x[csi_n] = @floatFromInt(n);
            csi_y[csi_n] = per_unit;
            csi_n += 1;
        }
    }
    reportFit("csi", "params", csi_x[0..csi_n], csi_y[0..csi_n]);

    var run_x: [cost_run_lengths.len]f64 = undefined;
    var run_y: [cost_run_lengths.len]f64 = undefined;
    var run_n: usize = 0;
    inline for (cost_run_lengths) |n| {
        const name = comptime std.fmt.comptimePrint("run_{d}_lf", .{n});
        if (anyAllowed(opts.filter, name, false)) {
            const units = generated_len / (n + 1);
            const buf = try genRuns(gpa, units * (n + 1), n, random_seed);
            defer gpa.free(buf);

            const min_ns = try benchCase(io, gpa, name, buf, null, opts, results);
            if (reportPerUnit(name, min_ns, units, buf.len)) |per_unit| {
                run_x[run_n] = @floatFromInt(n);
                run_y[run_n] = per_unit;
                run_n += 1;
            }
        }
    }
    reportFit("run", "print_bytes", run_x[0..run_n], run_y[0..run_n]);
}
