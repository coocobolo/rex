//! Row-clear strategies from screen.zig, on an 80-cell row and a
//! production `max_cols` row. Picks how scroll and reflow blank rows.
//! The `rep stos*` variants are x86_64 only.

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

const is_x86_64 = builtin.cpu.arch == .x86_64;

const strategies = .{
    .{ "memset", screen.zeroRowMemset, true },
    .{ "bytes", screen.zeroRowBytes, true },
    .{ "vector", screen.zeroRowVector, true },
    .{ "stosq", screen.zeroRowStos, is_x86_64 },
    .{ "stosb", screen.zeroRowStosb, is_x86_64 },
};

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
            const name, const zero, const supported = s;
            if (supported and support.allowed(opts.filter, case, name)) {
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
