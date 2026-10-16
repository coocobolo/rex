const std = @import("std");
const mem = std.mem;

const cases = @import("cases/root.zig");
const support = @import("support.zig");
const Options = support.Options;

fn usage() void {
    std.debug.print(
        \\Usage: bench [options]
        \\
        \\Options:
        \\  -h, --help                 Show this help message
        \\  -n, --sample_mib N         Byte budget of one timed sample, in MiB
        \\      --sample_mib=N
        \\  -s, --samples N            Number of samples per variant
        \\      --samples=N
        \\  -f, --filter PATTERNS      Run only variants whose "case/variant" label
        \\      --filter=PATTERNS      contains one of the comma-separated PATTERNS
        \\      --cost-model           Also run the cost-model cases (default to 
        \\                             feed_once only; use --only to override).
        \\
        \\  -S  --save PATH            Write JSONL results for baseline capture  
        \\  -c  --compare PATH         Diff against a saved baseline (±3% = flag)  
        \\
        \\Examples:
        \\  bench --only plain_lines_64k/feed_once
        \\  bench --only /feed_once
        \\  bench --only htop,man_bash
        \\  bench --cost-model --only csi_,run_
        \\
        \\Defaults:
        \\  sample_mib: {d}
        \\  samples:    {d}
    , .{
        Options.default.sample_mib,
        Options.default.samples,
    });
}

fn parsePositive(bytes: []const u8) !usize {
    const v = try std.fmt.parseInt(usize, bytes, 10);
    if (v == 0) return error.ZeroValue;
    return v;
}

fn parsePattern(bytes: []const u8) ![]const u8 {
    if (bytes.len == 0) return error.EmptyPattern;
    return bytes;
}

/// Returns the argument after args[i.*], adavancing i.
fn nextArg(args: []const [:0]const u8, i: *usize) ![]const u8 {
    i.* += 1;
    if (i.* >= args.len) return error.MissingArgument;
    return args[i.*];
}

pub fn parse(args: []const [:0]const u8) !Options {
    var opts: Options = .default;
    var i: usize = 1; // Skip argv[0].

    const sample_mib_prefix = "--sample_mib=";
    const samples_prefix = "--samples=";
    const filter_prefix = "--filter=";
    const save_prefix = "--save=";
    const compare_prefix = "--compare=";

    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (mem.eql(u8, arg, "-h") or mem.eql(u8, arg, "--help")) {
            return error.HelpRequested;
        }

        if (mem.eql(u8, arg, "-n") or mem.eql(u8, arg, "--sample_mib")) {
            opts.sample_mib = try parsePositive(try nextArg(args, &i));
        } else if (mem.startsWith(u8, arg, sample_mib_prefix)) {
            opts.sample_mib = try parsePositive(arg[sample_mib_prefix.len..]);
        }

        if (mem.eql(u8, arg, "-s") or mem.eql(u8, arg, "--samples")) {
            opts.samples = try parsePositive(try nextArg(args, &i));
        } else if (mem.startsWith(u8, arg, samples_prefix)) {
            opts.samples = try parsePositive(arg[samples_prefix.len..]);
        }

        if (mem.eql(u8, arg, "-f") or mem.eql(u8, arg, "--filter")) {
            opts.filter = try parsePattern(try nextArg(args, &i));
        } else if (mem.startsWith(u8, arg, filter_prefix)) {
            opts.filter = try parsePattern(arg[filter_prefix.len..]);
        }

        if (mem.eql(u8, arg, "-S") or mem.eql(u8, arg, "--save")) {
            opts.save = try parsePattern(try nextArg(args, &i));
        } else if (mem.startsWith(u8, arg, save_prefix)) {
            opts.save = try parsePattern(arg[save_prefix.len..]);
        }

        if (mem.eql(u8, arg, "-c") or mem.eql(u8, arg, "--compare")) {
            opts.compare = try parsePattern(try nextArg(args, &i));
        } else if (mem.startsWith(u8, arg, compare_prefix)) {
            opts.compare = try parsePattern(arg[compare_prefix.len..]);
        }

        if (mem.eql(u8, arg, "--cost-model")) opts.cost_model = true;

        return error.UnknownArgument;
    }

    return opts;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(gpa);
    const options = parse(args) catch |err| {
        usage();
        if (err == error.HelpRequested) return;
        return err;
    };

    std.debug.print("options: {any}\n", .{options});

    try cases.run(
        gpa,
        io,
        options,
    );
}