const std = @import("std");
const Io = std.Io;

const kib = 1024;
const mib = 1024 * kib;
const ns_per_second = 1_000_000_000.0;

const utf8 = @import("utf8.zig");
const Decoder = utf8.Decoder;

const Result = struct {
    throughput_mibs: f64,
    checksum: usize,
    elapsed_ns: i96,
    bytes_processed: usize,
    ns_per_call: f64,
};

fn finishResult(
    start: Io.Timestamp,
    end: Io.Timestamp,
    bytes_processed: usize,
    checksum: usize,
    iterations: usize,
) Result {
    const elapsed_ns = start.durationTo(end).toNanoseconds();

    const ns_per_call =
        @as(f64, @floatFromInt(elapsed_ns)) /
        @as(f64, @floatFromInt(iterations));
    return .{
        .throughput_mibs = throughput(elapsed_ns, bytes_processed),
        .checksum = checksum,
        .elapsed_ns = elapsed_ns,
        .bytes_processed = bytes_processed,
        .ns_per_call = ns_per_call,
    };
}

fn throughput(elapsed_ns: i96, byte_count: usize) f64 {
    if (elapsed_ns == 0) {
        return std.math.inf(f64);
    }

    const elapsed_s = @as(f64, @floatFromInt(elapsed_ns)) / ns_per_second;

    const bytes = @as(f64, @floatFromInt(byte_count));

    return (bytes / elapsed_s) / mib;
}

fn warmupAsciiPrefixLenSwar(
    buf: []const u8,
    iterations: usize,
) void {
    var decoder: Decoder = .empty;
    var selector: u8 = 0;
    const selector_ptr: *volatile u8 = @volatileCast(&selector);

    var checksum: usize = 0;

    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const value = selector_ptr.*;
        selector_ptr.* = value +% 1;

        const trim = @as(usize, value % 8);
        const len = buf.len - @min(trim, buf.len);
        const sample = buf[0..len];

        const n = Decoder.asciiPrefixLenSwar(
            &decoder,
            sample,
        );

        checksum +%= n;
    }

    std.mem.doNotOptimizeAway(&checksum);
}

fn benchAsciiPrefixLenSwar(
    io: Io,
    buf: []const u8,
    iterations: usize,
) Result {
    var decoder: Decoder = .empty;
    var selector: u8 = 0;
    const selector_ptr: *volatile u8 = @volatileCast(&selector);

    var total_bytes: usize = 0;
    var checksum: usize = 0;

    warmupAsciiPrefixLenSwar(
        buf,
        @min(iterations, 10_000),
    );
    const start = Io.Clock.now(.awake, io);

    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const value = selector_ptr.*;
        selector_ptr.* = value +% 1;

        const trim = @as(usize, value % 8);
        const len = buf.len - @min(trim, buf.len);
        const sample = buf[0..len];

        total_bytes += sample.len;

        const n = @call(
            .never_inline,
            Decoder.asciiPrefixLenSwar,
            .{ &decoder, sample },
        );

        checksum +%= n;
        std.mem.doNotOptimizeAway(&n);
    }

    const end = Io.Clock.now(.awake, io);

    return finishResult(
        start,
        end,
        total_bytes,
        checksum,
        iterations,
    );
}

fn benchAsciiPrefixLenVector(
    io: Io,
    buf: []const u8,
    iterations: usize,
) Result {
    var decoder: Decoder = .empty;
    var selector: u8 = 0;
    const selector_ptr: *volatile u8 = @volatileCast(&selector);

    var total_bytes: usize = 0;
    var checksum: usize = 0;

    warmupAsciiPrefixLenSwar(
        buf,
        @min(iterations, 10_000),
    );
    const start = Io.Clock.now(.awake, io);

    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const value = selector_ptr.*;
        selector_ptr.* = value +% 1;

        const trim = @as(usize, value % 8);
        const len = buf.len - @min(trim, buf.len);
        const sample = buf[0..len];

        total_bytes += sample.len;

        const n = @call(
            .never_inline,
            Decoder.asciiPrefixLen,
            .{ &decoder, sample },
        );

        checksum +%= n;
        std.mem.doNotOptimizeAway(&n);
    }

    const end = Io.Clock.now(.awake, io);

    return finishResult(
        start,
        end,
        total_bytes,
        checksum,
        iterations,
    );
}

const Corpus = struct {
    name: []const u8,
    data: []const u8,
};

fn benchmarkIterations(buf_len: usize) usize {
    // Try to process at least 64 MiB per benchmark sample.
    const target_bytes: usize = 64 * mib;

    const calculated = target_bytes / @max(buf_len, 1);

    // Also require enough calls for early-exit cases.
    // return @max(calculated, 1_000_000);

    // Keep enough calls to make tiny inputs measurable,
    // but don't force huge corpora to process tens of GiB.
    return @max(calculated, 10_000);
}

const corpus_empty = @embedFile("testdata/corpus/utf8/empty.bin");

const corpus_ascii_01 = @embedFile("testdata/corpus/utf8/ascii_01.bin");
const corpus_ascii_02 = @embedFile("testdata/corpus/utf8/ascii_02.bin");
const corpus_ascii_03 = @embedFile("testdata/corpus/utf8/ascii_03.bin");
const corpus_ascii_04 = @embedFile("testdata/corpus/utf8/ascii_04.bin");
const corpus_ascii_05 = @embedFile("testdata/corpus/utf8/ascii_05.bin");
const corpus_ascii_06 = @embedFile("testdata/corpus/utf8/ascii_06.bin");
const corpus_ascii_07 = @embedFile("testdata/corpus/utf8/ascii_07.bin");
const corpus_ascii_08 = @embedFile("testdata/corpus/utf8/ascii_08.bin");
const corpus_ascii_09 = @embedFile("testdata/corpus/utf8/ascii_09.bin");
const corpus_ascii_10 = @embedFile("testdata/corpus/utf8/ascii_10.bin");
const corpus_ascii_11 = @embedFile("testdata/corpus/utf8/ascii_11.bin");
const corpus_ascii_12 = @embedFile("testdata/corpus/utf8/ascii_12.bin");
const corpus_ascii_13 = @embedFile("testdata/corpus/utf8/ascii_13.bin");
const corpus_ascii_14 = @embedFile("testdata/corpus/utf8/ascii_14.bin");
const corpus_ascii_15 = @embedFile("testdata/corpus/utf8/ascii_15.bin");
const corpus_ascii_16 = @embedFile("testdata/corpus/utf8/ascii_16.bin");
const corpus_ascii_17 = @embedFile("testdata/corpus/utf8/ascii_17.bin");
const corpus_ascii_18 = @embedFile("testdata/corpus/utf8/ascii_18.bin");
const corpus_ascii_19 = @embedFile("testdata/corpus/utf8/ascii_19.bin");
const corpus_ascii_20 = @embedFile("testdata/corpus/utf8/ascii_20.bin");
const corpus_ascii_21 = @embedFile("testdata/corpus/utf8/ascii_21.bin");
const corpus_ascii_22 = @embedFile("testdata/corpus/utf8/ascii_22.bin");
const corpus_ascii_23 = @embedFile("testdata/corpus/utf8/ascii_23.bin");
const corpus_ascii_24 = @embedFile("testdata/corpus/utf8/ascii_24.bin");
const corpus_ascii_25 = @embedFile("testdata/corpus/utf8/ascii_25.bin");
const corpus_ascii_26 = @embedFile("testdata/corpus/utf8/ascii_26.bin");
const corpus_ascii_27 = @embedFile("testdata/corpus/utf8/ascii_27.bin");
const corpus_ascii_28 = @embedFile("testdata/corpus/utf8/ascii_28.bin");
const corpus_ascii_29 = @embedFile("testdata/corpus/utf8/ascii_29.bin");
const corpus_ascii_30 = @embedFile("testdata/corpus/utf8/ascii_30.bin");
const corpus_ascii_31 = @embedFile("testdata/corpus/utf8/ascii_31.bin");
const corpus_ascii_32 = @embedFile("testdata/corpus/utf8/ascii_32.bin");
const corpus_ascii_64 = @embedFile("testdata/corpus/utf8/ascii_64.bin");
const corpus_ascii_128 = @embedFile("testdata/corpus/utf8/ascii_128.bin");
const corpus_ascii_4k = @embedFile("testdata/corpus/utf8/ascii_4k.bin");
const corpus_ascii_64k = @embedFile("testdata/corpus/utf8/ascii_64k.bin");

const corpus_highbit_80 = @embedFile("testdata/corpus/utf8/highbit_80.bin");
const corpus_highbit_ff = @embedFile("testdata/corpus/utf8/highbit_ff.bin");

const corpus_nonascii_exact_end =
    @embedFile("testdata/corpus/utf8/nonascii_exact_end.bin");

const corpus_nonascii_offset_1 =
    @embedFile("testdata/corpus/utf8/nonascii_offset_1.bin");

const corpus_nonascii_offset_7 =
    @embedFile("testdata/corpus/utf8/nonascii_offset_7.bin");

const corpus_nonascii_offset_8 =
    @embedFile("testdata/corpus/utf8/nonascii_offset_8.bin");

const corpus_nonascii_offset_15 =
    @embedFile("testdata/corpus/utf8/nonascii_offset_15.bin");

const corpus_nonascii_offset_16 =
    @embedFile("testdata/corpus/utf8/nonascii_offset_16.bin");

const corpus_nonascii_start_80 =
    @embedFile("testdata/corpus/utf8/nonascii_start_80.bin");

const corpus_nonascii_start_ff =
    @embedFile("testdata/corpus/utf8/nonascii_start_ff.bin");

const corpus_nonascii_tail_1 =
    @embedFile("testdata/corpus/utf8/nonascii_tail_1.bin");

const corpus_nonascii_tail_2 =
    @embedFile("testdata/corpus/utf8/nonascii_tail_2.bin");

const corpus_nonascii_tail_4 =
    @embedFile("testdata/corpus/utf8/nonascii_tail_4.bin");

const corpus_nonascii_tail_8 =
    @embedFile("testdata/corpus/utf8/nonascii_tail_8.bin");

const corpus_nonascii_tail_16 =
    @embedFile("testdata/corpus/utf8/nonascii_tail_16.bin");

const corpus_nonascii_tail_32 =
    @embedFile("testdata/corpus/utf8/nonascii_tail_32.bin");

const corpus_utf8_2byte =
    @embedFile("testdata/corpus/utf8/utf8_2byte.bin");

const corpus_utf8_3byte =
    @embedFile("testdata/corpus/utf8/utf8_3byte.bin");

const corpus_utf8_4byte =
    @embedFile("testdata/corpus/utf8/utf8_4byte.bin");

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;

    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    const corpora = [_]Corpus{
        .{
            .name = "empty",
            .data = corpus_empty,
        },

        // Tiny ASCII.
        .{
            .name = "ascii_01 (1 B)",
            .data = corpus_ascii_01,
        },
        .{
            .name = "ascii_02 (2 B)",
            .data = corpus_ascii_02,
        },
        .{
            .name = "ascii_03 (3 B)",
            .data = corpus_ascii_03,
        },
        .{
            .name = "ascii_04 (4 B)",
            .data = corpus_ascii_04,
        },
        .{
            .name = "ascii_05 (5 B)",
            .data = corpus_ascii_05,
        },
        .{
            .name = "ascii_06 (6 B)",
            .data = corpus_ascii_06,
        },
        .{
            .name = "ascii_07 (7 B)",
            .data = corpus_ascii_07,
        },

        // 8-byte / SWAR boundary.
        .{
            .name = "ascii_08 (8 B)",
            .data = corpus_ascii_08,
        },
        .{
            .name = "ascii_09 (9 B)",
            .data = corpus_ascii_09,
        },
        .{
            .name = "ascii_10 (10 B)",
            .data = corpus_ascii_10,
        },
        .{
            .name = "ascii_11 (11 B)",
            .data = corpus_ascii_11,
        },
        .{
            .name = "ascii_12 (12 B)",
            .data = corpus_ascii_12,
        },
        .{
            .name = "ascii_13 (13 B)",
            .data = corpus_ascii_13,
        },
        .{
            .name = "ascii_14 (14 B)",
            .data = corpus_ascii_14,
        },
        .{
            .name = "ascii_15 (15 B)",
            .data = corpus_ascii_15,
        },

        // 16-byte / vector boundary.
        .{
            .name = "ascii_16 (16 B)",
            .data = corpus_ascii_16,
        },
        .{
            .name = "ascii_17 (17 B)",
            .data = corpus_ascii_17,
        },
        .{
            .name = "ascii_18 (18 B)",
            .data = corpus_ascii_18,
        },
        .{
            .name = "ascii_19 (19 B)",
            .data = corpus_ascii_19,
        },
        .{
            .name = "ascii_20 (20 B)",
            .data = corpus_ascii_20,
        },
        .{
            .name = "ascii_21 (21 B)",
            .data = corpus_ascii_21,
        },
        .{
            .name = "ascii_22 (22 B)",
            .data = corpus_ascii_22,
        },
        .{
            .name = "ascii_23 (23 B)",
            .data = corpus_ascii_23,
        },
        .{
            .name = "ascii_24 (24 B)",
            .data = corpus_ascii_24,
        },
        .{
            .name = "ascii_25 (25 B)",
            .data = corpus_ascii_25,
        },
        .{
            .name = "ascii_26 (26 B)",
            .data = corpus_ascii_26,
        },
        .{
            .name = "ascii_27 (27 B)",
            .data = corpus_ascii_27,
        },
        .{
            .name = "ascii_28 (28 B)",
            .data = corpus_ascii_28,
        },
        .{
            .name = "ascii_29 (29 B)",
            .data = corpus_ascii_29,
        },
        .{
            .name = "ascii_30 (30 B)",
            .data = corpus_ascii_30,
        },
        .{
            .name = "ascii_31 (31 B)",
            .data = corpus_ascii_31,
        },
        .{
            .name = "ascii_32 (32 B)",
            .data = corpus_ascii_32,
        },

        // Larger ASCII.
        .{
            .name = "ascii_64 (64 B)",
            .data = corpus_ascii_64,
        },
        .{
            .name = "ascii_128 (128 B)",
            .data = corpus_ascii_128,
        },
        .{
            .name = "ascii_4k (4 KiB)",
            .data = corpus_ascii_4k,
        },
        .{
            .name = "ascii_64k (64 KiB)",
            .data = corpus_ascii_64k,
        },

        // Immediate early exit.
        .{
            .name = "nonascii_start_80",
            .data = corpus_nonascii_start_80,
        },
        .{
            .name = "nonascii_start_ff",
            .data = corpus_nonascii_start_ff,
        },

        // Word/vector boundaries.
        .{
            .name = "nonascii_offset_1",
            .data = corpus_nonascii_offset_1,
        },
        .{
            .name = "nonascii_offset_7",
            .data = corpus_nonascii_offset_7,
        },
        .{
            .name = "nonascii_offset_8",
            .data = corpus_nonascii_offset_8,
        },
        .{
            .name = "nonascii_offset_15",
            .data = corpus_nonascii_offset_15,
        },
        .{
            .name = "nonascii_offset_16",
            .data = corpus_nonascii_offset_16,
        },

        // Near-end detection.
        .{
            .name = "nonascii_tail_1",
            .data = corpus_nonascii_tail_1,
        },
        .{
            .name = "nonascii_tail_2",
            .data = corpus_nonascii_tail_2,
        },
        .{
            .name = "nonascii_tail_4",
            .data = corpus_nonascii_tail_4,
        },
        .{
            .name = "nonascii_tail_8",
            .data = corpus_nonascii_tail_8,
        },
        .{
            .name = "nonascii_tail_16",
            .data = corpus_nonascii_tail_16,
        },
        .{
            .name = "nonascii_tail_32",
            .data = corpus_nonascii_tail_32,
        },
        .{
            .name = "nonascii_exact_end",
            .data = corpus_nonascii_exact_end,
        },

        // Raw high-bit detection.
        .{
            .name = "highbit_80",
            .data = corpus_highbit_80,
        },
        .{
            .name = "highbit_ff",
            .data = corpus_highbit_ff,
        },

        // UTF-8 sequence lengths.
        .{
            .name = "utf8_2byte",
            .data = corpus_utf8_2byte,
        },
        .{
            .name = "utf8_3byte",
            .data = corpus_utf8_3byte,
        },
        .{
            .name = "utf8_4byte",
            .data = corpus_utf8_4byte,
        },
    };

    for (corpora) |corpus| {
        const iterations = benchmarkIterations(corpus.data.len);

        try stdout.print(
            "\n=== {s} ({d} bytes, {d} iterations) ===\n",
            .{
                corpus.name,
                corpus.data.len,
                iterations,
            },
        );
        try stdout.flush();

        const swar = benchAsciiPrefixLenSwar(
            io,
            corpus.data,
            iterations,
        );

        try stdout.print(
            "  asciiPrefixLen (SWAR/usize): {d:>10.2} MiB/s, {d:>8.3} ns/call, {d} ns, {d} bytes [chk={d}]\n",
            .{
                swar.throughput_mibs,
                swar.ns_per_call,
                swar.elapsed_ns,
                swar.bytes_processed,
                swar.checksum,
            },
        );

        const vec = benchAsciiPrefixLenVector(
            io,
            corpus.data,
            iterations,
        );

        try stdout.print(
            "  asciiPrefixLen (@Vector):   {d:>10.2} MiB/s, {d:>8.3} ns/call, {d} ns, {d} bytes [chk={d}]\n",
            .{
                vec.throughput_mibs,
                vec.ns_per_call,
                vec.elapsed_ns,
                vec.bytes_processed,
                vec.checksum,
            },
        );

        // Make sure both implementations produced the same answer.
        if (swar.checksum != vec.checksum) {
            return error.BenchmarkMismatch;
        }

        const vector_speedup = swar.ns_per_call / vec.ns_per_call;

        try stdout.print(
            "  -> vector/swar speedup: {d:.2}x\n",
            .{vector_speedup},
        );

        try stdout.flush();
    }
}
