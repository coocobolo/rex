//! Row-clear strategies on an 80-cell row and a production `max_cols`
//! row: `screen` is the `zeroRow` that scroll and erase use, the rest are
//! the alternatives it was chosen from. The `rep stosq` variant is
//! x86_64 only.

const std = @import("std");
const builtin = @import("builtin");

const Io = std.Io;
const Allocator = std.mem.Allocator;

const rex = @import("rex");
const Cell = rex.terminal.Cell;
const screen = rex.terminal.screen;

const support = @import("../../support.zig");
const Options = support.Options;
const Result = support.Result;

const term = @import("root.zig");

const strategies = .{
    .{ "screen", screen.zeroRow },
    .{ "memset", zeroRowMemset },
    .{ "bytes", zeroRowBytes },
    .{ "vector", zeroRowVector },
} ++ if (builtin.cpu.arch == .x86_64) .{
    .{ "stosq", zeroRowStosq },
} else .{};

noinline fn zeroRowMemset(dest: [*]Cell, n: usize) void {
    @memset(dest[0..n], Cell{});
}

noinline fn zeroRowBytes(dest: [*]Cell, n: usize) void {
    const bytes: [*]u8 = @ptrCast(dest);
    @memset(bytes[0 .. n * @sizeOf(Cell)], 0);
}

noinline fn zeroRowVector(dest: [*]Cell, n: usize) void {
    const bytes = n * @sizeOf(Cell);
    const p: [*]u8 = @ptrCast(dest);

    const V = @Vector(32, u8);
    const zero: V = @splat(0);

    var i: usize = 0;
    while (i + 128 <= bytes) : (i += 128) {
        @as(*align(1) V, @ptrCast(p + i + 0)).* = zero;
        @as(*align(1) V, @ptrCast(p + i + 32)).* = zero;
        @as(*align(1) V, @ptrCast(p + i + 64)).* = zero;
        @as(*align(1) V, @ptrCast(p + i + 96)).* = zero;
    }
    while (i + 32 <= bytes) : (i += 32) {
        @as(*align(1) V, @ptrCast(p + i)).* = zero;
    }
    while (i < bytes) : (i += 1) {
        p[i] = 0;
    }
}

/// `rep stosq` writes `n` quadwords of `rax` to `[rdi]`; a `Cell` is one
/// quadword.
noinline fn zeroRowStosq(dest: [*]Cell, n: usize) void {
    asm volatile ("rep stosq"
        :
        : [_dst] "{rdi}" (dest),
          [_ax] "{rax}" (@as(u64, 0)),
          [_n] "{rcx}" (n),
        : .{ .memory = true, .rdi = true, .rcx = true });
}

const widths = .{ 80, rex.config.Config.default_terminal.max_cols };

const Context = struct {
    row: []align(64) Cell,
    zero: *const fn ([*]Cell, usize) void,

    fn step(ctx: *Context) !void {
        ctx.zero(ctx.row.ptr, ctx.row.len);
        std.mem.doNotOptimizeAway(ctx.row.ptr);
    }
};

pub fn run(io: Io, gpa: Allocator, opts: Options, results: *std.ArrayList(Result)) !void {
    inline for (widths) |n| {
        const case = std.fmt.comptimePrint("zero_row_{d}", .{n});
        inline for (strategies) |s| {
            const name, const zero = s;
            if (support.allowed(opts.filter, case, name)) {
                const row = try gpa.alignedAlloc(Cell, .@"64", n);
                defer gpa.free(row);
                // Dirty, so the first clear is not a no-op.
                @memset(row, .{ .codepoint = 'x', .kind = .narrow });

                var ctx: Context = .{ .row = row, .zero = zero };
                const bytes = n * @sizeOf(Cell);
                var stats = try support.run(gpa, io, Context.step, &ctx, opts.iterationsFor(bytes) * 4, opts.samples, bytes);
                defer stats.deinit(gpa);

                // Every strategy must leave the same all-default row.
                var h: std.hash.Wyhash = .init(0);
                h.update(std.mem.sliceAsBytes(row));
                const fp = h.final();

                std.debug.print("{s:<40} {f}  checksum={x}\n", .{ case ++ "/" ++ name, stats, fp });
                try results.append(gpa, stats.toResult(term.suite ++ "." ++ case, name, fp));
            }
        }
    }
}
