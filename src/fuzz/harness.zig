//! Shared fuzz plumbing: where a target's choices come from, the corpus
//! format, the seeded mutator and the two test entry points every
//! target uses.
//!
//! A target is one function, `fn run(src: *Source) !void`, that makes all
//! its choices through `src`. Each target file then declares:
//!
//!     test "fuzz <name>" {
//!         try harness.fuzz(run, &seeds, &regressions);
//!     }
//!     test "fuzz <name>: seeded mutations" {
//!         try harness.seeded(run, &seeds, 0x<seed>);
//!     }
//!
//! `zig build test` runs both: the seeds and saved regressions once
//! each, then a fixed set of seeded mutations, so Debug safety checks
//! cover every target without --fuzz. `zig build fuzz-<name> --fuzz
//! -Dllvm` hands the first to the fuzzer.

const std = @import("std");
const testing = std.testing;
const Smith = testing.Smith;

/// Where a target's choices come from: the fuzzer's `Smith`, or a seed
/// input split and decorated by a seeded PRNG.
///
/// Every choice takes a comptime `site` name. Smith tells choices apart
/// by call site, and wrapping it here would merge them all into one, so
/// the name is hashed into the choice's id instead.
pub const Source = union(enum) {
    smith: *Smith,
    seeded: Seeded,

    pub const Seeded = struct {
        random: std.Random,
        /// The (mutated) seed, handed out by `chunk` in random pieces.
        input: []const u8,
        pos: usize = 0,
    };

    inline fn hash(comptime site: []const u8) u32 {
        return comptime @truncate(std.hash.Wyhash.hash(0, site));
    }

    /// An integer in `[at_least, at_most]`.
    pub fn range(src: *Source, comptime site: []const u8, comptime T: type, at_least: T, at_most: T) T {
        // Smith wants fixed-size integers.
        const Fixed = if (T == usize) u64 else T;
        return switch (src.*) {
            .smith => |s| @intCast(s.valueRangeAtMostWithHash(Fixed, at_least, at_most, hash(site))),
            .seeded => |s| s.random.intRangeAtMost(T, at_least, at_most),
        };
    }

    /// True about one time in `1 + false_weight / true_weight`.
    pub fn chance(src: *Source, comptime site: []const u8, false_weight: u32, true_weight: u32) bool {
        return switch (src.*) {
            .smith => |s| s.boolWeightedWithHash(false_weight, true_weight, hash(site)),
            .seeded => |s| s.random.uintLessThan(u32, false_weight + true_weight) >= false_weight,
        };
    }

    /// An index into a list of `len` items.
    pub fn index(src: *Source, comptime site: []const u8, len: usize) usize {
        return switch (src.*) {
            .smith => |s| s.indexWithHash(len, hash(site)),
            .seeded => |s| s.random.uintLessThan(usize, len),
        };
    }

    /// A value of enum `T`.
    pub fn pick(src: *Source, comptime site: []const u8, comptime T: type) T {
        return switch (src.*) {
            .smith => |s| s.valueWithHash(T, hash(site)),
            .seeded => |s| s.random.enumValue(T),
        };
    }

    /// Fills `out` with arbitrary bytes.
    pub fn bytes(src: *Source, comptime site: []const u8, out: []u8) void {
        switch (src.*) {
            .smith => |s| s.bytesWithHash(out, hash(site)),
            .seeded => |s| s.random.bytes(out),
        }
    }

    /// True once the input is used up. Smith decides for itself, ending
    /// about one call in `1 + more_weight`.
    pub fn done(src: *Source, comptime site: []const u8, more_weight: u32) bool {
        return switch (src.*) {
            .smith => |s| s.eosWeightedSimpleWithHash(more_weight, 1, hash(site)),
            .seeded => |s| s.pos == s.input.len,
        };
    }

    /// The next piece of input bytes, at most `buf.len` long. Smith fills
    /// `buf`; a seeded source returns a slice of its seed of random
    /// length, so the seed reaches the target split at random points.
    pub fn chunk(src: *Source, comptime site: []const u8, buf: []u8) []const u8 {
        switch (src.*) {
            .smith => |s| return buf[0..s.sliceWithHash(buf, hash(site))],
            .seeded => |*s| {
                const left = s.input.len - s.pos;
                const max = @min(left, buf.len);
                const len = if (max == 0) 0 else if (s.random.boolean())
                    max
                else
                    s.random.intRangeAtMost(usize, 1, max);
                defer s.pos += len;
                return s.input[s.pos..][0..len];
            },
        }
    }
};

/// Largest seed or mutated input.
pub const max_input = 4096;

/// Fragments the mutator splices in: the bytes where parsers, decoders
/// and string states change their minds.
pub const tokens = [_][]const u8{
    "\x1b",         "\x1b[",            "\x1b]",        "\x1bP",    "\x1b\\",       "\x07",
    "\x18",         "\x1a",             "\x9b",         "\x9c",     "\x9d",         "\x90",
    "\x1b[?1049h",  "\x1b[?1049l",      "\x1b[?6h",     "\x1b[?7l", "\x1b[r",       "\x1b[3;5r",
    "\x1b[H",       "\x1b[99;99H",      "\x1b7",        "\x1b8",    "\x1bc",        "\x1b[!p",
    ";",            ":",                "9999999",      "\r\n",     "\t",           "\x08",
    "\xc3",         "\xe2\x80",         "\xf0\x9f\x91", "\xcc\x81", "\xe2\x80\x8d", "\xf0\x9f\x87\xba",
    "\xed\xa0\x80", "\xf4\x90\x80\x80", "\xc0\xaf",     "\xff",     "\x80",         "\xe4\xb8\x80",
};

/// A damaged copy of `bytes` in `buf`: a few bytes set at random or a
/// token spliced in, then maybe cut short or a run duplicated in place.
/// Taken from the zip repo's read fuzz target, plus `tokens`.
pub fn mutate(random: std.Random, bytes: []const u8, buf: *[max_input]u8) []const u8 {
    var len: usize = @min(bytes.len, buf.len);
    @memcpy(buf[0..len], bytes[0..len]);
    for (0..random.intRangeAtMost(u8, 1, 4)) |_| {
        if (len > 0 and random.boolean()) {
            buf[random.uintLessThan(usize, len)] = random.int(u8);
        } else {
            const token = tokens[random.uintLessThan(usize, tokens.len)];
            if (len + token.len > buf.len) continue;
            const at = random.uintAtMost(usize, len);
            std.mem.copyBackwards(u8, buf[at + token.len .. len + token.len], buf[at..len]);
            @memcpy(buf[at..][0..token.len], token);
            len += token.len;
        }
    }
    if (len == 0) return buf[0..0];
    switch (random.uintLessThan(u8, 4)) {
        0 => len = random.uintLessThan(usize, len),
        1 => {
            const at = random.uintLessThan(usize, len);
            const run = @min(random.intRangeAtMost(usize, 1, 32), len - at, buf.len - len);
            std.mem.copyBackwards(u8, buf[at + run .. len + run], buf[at..len]);
            len += run;
        },
        else => {},
    }
    return buf[0..len];
}

/// Mutations run per seed by `seeded`.
pub const mutations_per_seed = 64;

/// Hands `run` to `std.testing.fuzz`, starting from `seeds` (raw bytes,
/// wrapped as the first `chunk`) and `regressions` (saved fuzzer inputs,
/// replayed as they are). Without --fuzz, each runs once.
pub fn fuzz(
    comptime run: fn (src: *Source) anyerror!void,
    seeds: []const []const u8,
    regressions: []const []const u8,
) !void {
    const gpa = testing.allocator;
    var corpus: std.ArrayList([]const u8) = .empty;
    defer {
        for (corpus.items[0..seeds.len]) |input| gpa.free(input);
        corpus.deinit(gpa);
    }
    try corpus.ensureTotalCapacity(gpa, seeds.len + regressions.len);
    for (seeds) |seed| corpus.appendAssumeCapacity(try sliceInput(gpa, seed));
    corpus.appendSliceAssumeCapacity(regressions);

    const Wrap = struct {
        fn one(_: void, smith: *Smith) anyerror!void {
            var src: Source = .{ .smith = smith };
            try run(&src);
        }
    };
    try testing.fuzz({}, Wrap.one, .{ .corpus = corpus.items });
}

/// Runs `run` on each seed as is, then on `mutations_per_seed` seeded
/// mutations of it, with every other choice drawn from the same PRNG.
/// The result is fixed by `seed`, so failures reproduce.
pub fn seeded(
    comptime run: fn (src: *Source) anyerror!void,
    seeds: []const []const u8,
    seed: u64,
) !void {
    var prng: std.Random.DefaultPrng = .init(seed);
    const random = prng.random();
    var buf: [max_input]u8 = undefined;
    for (seeds) |input| {
        var src: Source = .{ .seeded = .{ .random = random, .input = input } };
        try run(&src);
        for (0..mutations_per_seed) |_| {
            src = .{ .seeded = .{ .random = random, .input = mutate(random, input, &buf) } };
            try run(&src);
        }
    }
}

/// `bytes` as a Smith slice input: a little-endian u32 length, then the
/// bytes. Caller owns the result.
fn sliceInput(gpa: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const input = try gpa.alloc(u8, 4 + bytes.len);
    std.mem.writeInt(u32, input[0..4], @intCast(bytes.len), .little);
    @memcpy(input[4..], bytes);
    return input;
}
