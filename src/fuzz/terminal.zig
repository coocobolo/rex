//! Terminal fuzz target: the whole pipeline (byte loop, parser,
//! dispatcher, input engine, screens) driven by random bytes mixed with
//! resizes, end of stream, viewport scrolls and the host draining
//! replies. Runs on two configurations: with scrollback, and without.
//!
//! Invariants:
//!   - no panic, safety check or leak;
//!   - `invariants.expectTerminal` after every step;
//!   - a twin terminal fed the same bytes in one `feed` per step shows
//!     the same screens, so where a read splits the stream never
//!     matters.

const std = @import("std");
const testing = std.testing;

const harness = @import("harness.zig");
const invariants = @import("invariants.zig");
const Source = harness.Source;
const term = @import("../term/term.zig");
const test_option = @import("../term/test_fixtures.zig").test_option;

const no_scrollback: term.Option = .{
    .max_rows = 8,
    .max_cols = 16,
    .max_scrollback = 0,
    .name = "test",
    .version = "0.0.1",
};

const Op = enum { feed, resize, end, drain, viewport };

/// Most steps one input takes.
const max_steps = 64;

/// The steps of one input, printed when the twin check fails.
const Log = struct {
    buf: [8192]u8 = undefined,
    len: usize = 0,

    fn add(self: *Log, op: []const u8, bytes: []const u8) void {
        var w: std.Io.Writer = .fixed(self.buf[self.len..]);
        w.print("{s} \"{f}\"\n", .{ op, std.zig.fmtString(bytes) }) catch {};
        self.len += w.end;
    }

    fn report(self: *const Log, err: anyerror) anyerror {
        std.debug.print("steps fed to the terminal:\n{s}", .{self.buf[0..self.len]});
        return err;
    }
};

fn runOn(comptime option: term.Option, src: *Source) !void {
    const Terminal = term.Terminal(option);
    const gpa = testing.allocator;

    var t: Terminal = try .create(gpa);
    defer t.destroy(gpa);
    var twin: Terminal = try .create(gpa);
    defer twin.destroy(gpa);

    // What `t` was given, for the report when the twin disagrees.
    var log: Log = .{};

    // Bytes `t` got since `twin` last caught up.
    var pending: [harness.max_input]u8 = undefined;
    var pending_len: usize = 0;
    var buf: [256]u8 = undefined;

    var steps: usize = 0;
    while (steps < max_steps and !src.done("step", 15)) : (steps += 1) {
        const op: Op = if (steps == 0) .feed else src.pick("op", Op);
        if (op == .feed) {
            const bytes = src.chunk("bytes", &buf);
            t.feed(bytes);
            log.add("feed", bytes);
            const n = @min(bytes.len, pending.len - pending_len);
            @memcpy(pending[pending_len..][0..n], bytes[0..n]);
            pending_len += n;
            if (n < bytes.len) return; // the twin can no longer follow
            try invariants.expectTerminal(&t);
            continue;
        }

        twin.feed(pending[0..pending_len]);
        pending_len = 0;
        invariants.expectSameTerminal(&t, &twin) catch |err| return log.report(err);
        log.add(@tagName(op), "");

        switch (op) {
            .feed => unreachable,
            .resize => {
                const rows = src.range("rows", u16, 0, option.max_rows + 2);
                const cols = src.range("cols", u16, 0, option.max_cols + 2);
                t.resize(rows, cols);
                twin.resize(rows, cols);
            },
            .end => {
                t.end();
                twin.end();
            },
            .drain => {
                try testing.expectEqualStrings(t.response.slice(), twin.response.slice());
                t.events.clear();
                t.response.clear();
                twin.events.clear();
                twin.response.clear();
            },
            .viewport => if (option.max_scrollback > 0) {
                const lines = src.range("lines", u32, 0, option.max_scrollback + 2);
                const back = src.chance("back", 1, 1);
                inline for (.{ &t, &twin }) |x| {
                    if (back) x.active().scrollViewportBack(lines) else x.active().scrollViewportForward(lines);
                }
            },
        }
        try invariants.expectTerminal(&t);
    }
    twin.feed(pending[0..pending_len]);
    invariants.expectSameTerminal(&t, &twin) catch |err| return log.report(err);
    try testing.expectEqualStrings(t.response.slice(), twin.response.slice());
}

fn run(src: *Source) !void {
    if (src.chance("config", 3, 1)) {
        try runOn(no_scrollback, src);
    } else {
        try runOn(test_option, src);
    }
}

const seeds = [_][]const u8{
    "hello, world\r\n",
    "a\tb\tc\x08\x08\x08\r\n\x1bM\x1bD\x1bE",
    "\x1b[2J\x1b[H\x1b[1;31mred\x1b[0m\x1b[K",
    "\x1b[?1049hALT\x1b[?1049lPRIMARY",
    "\x1b[3;6r\x1b[?6h\x1b[H\x1b[10Ax\x1b[10By\x1b[?6l\x1b[r",
    "\x1b[?7l0123456789012345678901234567890\x1b[?7h",
    "\x1b7\x1b[20;30H\x1b8\x1b[s\x1b[u",
    "\x1b[5S\x1b[5T\x1b[3L\x1b[3M\x1b[4@\x1b[4P\x1b[5X\x1b[3b",
    "e\xcc\x81\xcc\x82\xcc\x83 \xf0\x9f\x91\xa9\xe2\x80\x8d\xf0\x9f\x92\xbb \xf0\x9f\x87\xba\xf0\x9f\x87\xb8",
    "\xe4\xb8\x80\xe4\xb8\x81\xe4\xb8\x82\xe4\xb8\x83\xe4\xb8\x84\xe4\xb8\x85\xe4\xb8\x86\xe4\xb8\x87\xe4\xb8\x88",
    "\xe2\x9d\xa4\x1b[5b\xc3\xa9\x1b[3b",
    "bad \xc0\xaf \xed\xa0\x80 \xf4\x90\x80\x80 \xe2\x82 \xff\xfe end",
    "\x1b[6n\x1b[c\x1b[>c\x1b[?6$p\x1b[>q\x1b[?6n",
    "\x1b]0;title\x07\x1b]2;t2\x1b\\\x1b]1;icon\x07\x1b]4;1;?\x07\x1b]10;?\x07",
    "\x1bP$qm\x1b\\\x1bP$qr\x1b\\\x1bP+q544e\x1b\\",
    "\x1b#8\x1b#3\x1b#4\x1b#6\x1b(0lqk\x1b(B",
    "\x1b[!p\x1bc\x1b[61\"p\x1b[62;1\"p\x1b[64;0\"p",
    "\x1b%G\x1b%@\xe9\x9b\x1b% G",
    "\x1b[?1000h\x1b[?1006h\x1b[?2004h\x1b[?2026h\x1b[?25l",
    "\x1b[38;5;196m\x1b[48;2;1;2;3m\x1b[58:2::4:5:6m\x1b[4:3mX\x1b[m",
};

const regressions = [_][]const u8{
    @embedFile("testdata/terminal/crash-fe798e15b4b2153a.bin"),
    @embedFile("testdata/terminal/crash-3ba3d87de729075b.bin"),
    @embedFile("testdata/terminal/crash-d3907d8773be0a24.bin"),
};

test "fuzz terminal" {
    try harness.fuzz(run, &seeds, &regressions);
}

test "fuzz terminal: seeded mutations" {
    try harness.seeded(run, &seeds, 0x7E21_2026);
}
