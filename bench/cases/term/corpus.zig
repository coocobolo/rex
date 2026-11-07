//! Corpus benchmark: the real PTY captures in bench/cases/vt/testdata/corpus
//! fed through Terminal, which is what Rex does with that output: UTF-8
//! decoding, parsing and the screen work together. The vt suite can only
//! take ASCII-only captures, because `vt.Parser` needs decoded input; this
//! case takes them all.
//!
//! The captures were made at 120x40 (scripts/capture-corpus.sh), so the
//! terminal has that size. `feed_once` feeds a capture in one call;
//! `recorded` replays the PTY read sizes from its `.plan`. Every iteration
//! feeds the whole capture to the same terminal, like running the command
//! again in the same window: scrollback stays at its limit and replies
//! (htop's queries) are drained after each pass, so nothing grows.
//!
//! The checksum is the screen fingerprint after one untimed pass on a fresh
//! terminal, so it depends only on the capture. Both variants must give the
//! same screen, else a line starting with `!!` is printed.

const std = @import("std");

const Io = std.Io;
const Allocator = std.mem.Allocator;

const rex = @import("rex");

const support = @import("../../support.zig");
const Options = support.Options;
const Result = support.Result;

const term = @import("root.zig");
const vt = @import("../vt/parser.zig");

const option = rex.App.default_terminal_option;
const Term = rex.terminal.Terminal(option);

/// Size the captures were made at.
const rows = 40;
const cols = 120;

const corpus_names = [_][]const u8{ "ls_color", "htop", "man_bash" };

const Variant = enum { feed_once, recorded };
const variants = [_]Variant{ .feed_once, .recorded };

const Context = struct {
    t: *Term,
    bytes: []const u8,
    plan: ?[]const u32,
    replies: [4096]u8 = undefined,

    fn pass(ctx: *Context) !void {
        feedPass(ctx.t, ctx.bytes, ctx.plan);
        _ = ctx.t.drainReplies(&ctx.replies);
        std.mem.doNotOptimizeAway(&ctx.t.active().cursor);
    }
};

/// Feeds the whole capture, in one call or in the recorded read sizes, and
/// ends the stream so a pending cluster is drawn.
fn feedPass(t: *Term, bytes: []const u8, plan: ?[]const u32) void {
    if (plan) |chunks| {
        var offset: usize = 0;
        for (chunks) |n| {
            t.feed(bytes[offset..][0..n]);
            offset += n;
        }
    } else {
        t.feed(bytes);
    }
    t.end();
}

/// Creates a terminal at the capture size. Heap, not stack: two screens
/// with their ring metadata.
fn createTerm(gpa: Allocator) !*Term {
    const t = try gpa.create(Term);
    errdefer gpa.destroy(t);
    t.* = try Term.create(gpa);
    t.resize(rows, cols);
    return t;
}

fn destroyTerm(gpa: Allocator, t: *Term) void {
    t.destroy(gpa);
    gpa.destroy(t);
}

/// Screen fingerprint after one pass on a fresh terminal.
fn checksum(gpa: Allocator, bytes: []const u8, plan: ?[]const u32) !u64 {
    const t = try createTerm(gpa);
    defer destroyTerm(gpa, t);
    feedPass(t, bytes, plan);
    return term.fingerprint(t.active());
}

pub fn run(io: Io, gpa: Allocator, opts: Options, results: *std.ArrayList(Result)) !void {
    inline for (corpus_names) |name| {
        const label_case = "corpus/" ++ name;
        if (anyAllowed(opts.filter, label_case)) {
            const raw = try vt.readFile(io, gpa, vt.corpus_dir ++ name ++ ".raw");
            defer gpa.free(raw);
            const plan_text = try vt.readFile(io, gpa, vt.corpus_dir ++ name ++ ".plan");
            defer gpa.free(plan_text);
            const plan = try vt.parsePlan(gpa, plan_text, raw.len);
            defer gpa.free(plan);

            const sum = try checksum(gpa, raw, null);
            const recorded_sum = try checksum(gpa, raw, plan);
            if (sum != recorded_sum) {
                std.debug.print("!! {s}: recorded read sizes changed the screen ({x} -> {x})\n", .{
                    label_case, sum, recorded_sum,
                });
            }

            const t = try createTerm(gpa);
            defer destroyTerm(gpa, t);

            for (variants) |v| {
                if (support.allowed(opts.filter, label_case, @tagName(v))) {
                    var ctx: Context = .{ .t = t, .bytes = raw, .plan = if (v == .recorded) plan else null };
                    const iterations = opts.iterationsFor(raw.len);
                    var stats = try support.run(gpa, io, Context.pass, &ctx, iterations, opts.samples, raw.len);
                    defer stats.deinit(gpa);

                    const v_sum = if (v == .recorded) recorded_sum else sum;
                    std.debug.print("{s}/{s:<26} {f}  checksum={x}\n", .{ label_case, @tagName(v), stats, v_sum });
                    try results.append(gpa, stats.toResult(term.suite ++ ".corpus." ++ name, @tagName(v), v_sum));
                }
            }
        }
    }
}

fn anyAllowed(filter: ?[]const u8, label_case: []const u8) bool {
    for (variants) |v| {
        if (support.allowed(filter, label_case, @tagName(v))) return true;
    }
    return false;
}
