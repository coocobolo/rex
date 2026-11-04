//! VT parser fuzz target: any bytes through `Parser.feedBytes`, fed
//! whole, one byte at a time and split at random points.
//!
//! Invariants:
//!   - no panic or safety check;
//!   - the three feeds call the handler with the same events in the
//!     same order (print and string runs compared byte by byte), and end
//!     in the same state (and the same live parameter counts), since
//!     `feedBytes` promises its fast paths only change cost;
//!   - parameter and intermediate counts stay within their caps.

const std = @import("std");
const testing = std.testing;

const harness = @import("harness.zig");
const Source = harness.Source;
const vt = @import("../vt/parser.zig");

const options: vt.ParserOptions = .{};
const Parser = vt.Parser(Trace, options);

/// Folds every handler call into an order-sensitive hash. Runs are
/// hashed per byte, so how the parser batches them does not matter.
const Trace = struct {
    hash: u64 = 0,
    events: u32 = 0,

    fn mix(self: *Trace, tag: u8, value: u64) void {
        self.hash = (self.hash ^ (@as(u64, tag) << 56 | value)) *% 0x100000001B3;
        self.events += 1;
    }

    fn mixSequence(self: *Trace, tag: u8, final: u8, intermediates: []const u8, params: []const vt.Parameter) void {
        self.mix(tag, final);
        for (intermediates) |b| self.mix(tag | 0x80, b);
        for (params) |p| self.mix(tag | 0x40, @as(u16, @bitCast(p)));
    }

    pub fn print(self: *Trace, bytes: []const u8) void {
        for (bytes) |b| self.mix(1, b);
    }
    pub fn printByte(self: *Trace, b: u8) void {
        self.mix(1, b);
    }
    pub fn execute(self: *Trace, b: u8) void {
        self.mix(2, b);
    }
    pub fn escDispatch(self: *Trace, final: u8, intermediates: []const u8) void {
        self.mixSequence(3, final, intermediates, &.{});
    }
    pub fn csiDispatch(self: *Trace, final: u8, intermediates: []const u8, params: []const vt.Parameter) void {
        self.mixSequence(4, final, intermediates, params);
    }
    pub fn hook(self: *Trace, final: u8, intermediates: []const u8, params: []const vt.Parameter) void {
        self.mixSequence(5, final, intermediates, params);
    }
    pub fn dcsPut(self: *Trace, b: u8) void {
        self.mix(6, b);
    }
    pub fn dcsPutSlice(self: *Trace, bytes: []const u8) void {
        for (bytes) |b| self.mix(6, b);
    }
    pub fn unhook(self: *Trace) void {
        self.mix(7, 0);
    }
    pub fn oscStart(self: *Trace) void {
        self.mix(8, 0);
    }
    pub fn oscPut(self: *Trace, b: u8) void {
        self.mix(9, b);
    }
    pub fn oscPutSlice(self: *Trace, bytes: []const u8) void {
        for (bytes) |b| self.mix(9, b);
    }
    pub fn oscEnd(self: *Trace) void {
        self.mix(10, 0);
    }
};

const Fed = struct { parser: Parser = .{}, trace: Trace = .{} };

fn expectValid(fed: *const Fed) !void {
    try testing.expect(fed.parser.param_len <= options.max_params);
    try testing.expect(fed.parser.intermediate_len <= options.max_intermediates);
}

fn expectSame(want: *const Fed, got: *const Fed) !void {
    try testing.expectEqual(want.trace.events, got.trace.events);
    try testing.expectEqual(want.trace.hash, got.trace.hash);
    try testing.expectEqual(want.parser.state, got.parser.state);
    // Counts are only live while a sequence collects them; elsewhere a
    // fast path may leave a stale value that nothing reads (csi_ignore
    // entered straight from ground, say).
    switch (want.parser.state) {
        .escape_intermediate, .csi_param, .csi_intermediate, .dcs_param, .dcs_intermediate => {
            try testing.expectEqual(want.parser.param_len, got.parser.param_len);
            try testing.expectEqual(want.parser.intermediate_len, got.parser.intermediate_len);
        },
        else => {},
    }
}

var input_buf: [harness.max_input]u8 = undefined;

fn run(src: *Source) !void {
    var len: usize = 0;
    while (len < input_buf.len) {
        const piece = src.chunk("bytes", input_buf[len..]);
        std.mem.copyForwards(u8, input_buf[len..][0..piece.len], piece);
        len += piece.len;
        if (src.done("more bytes", 3)) break;
    }
    const bytes = input_buf[0..len];

    var whole: Fed = .{};
    whole.parser.feedBytes(&whole.trace, bytes);
    try expectValid(&whole);

    var bytewise: Fed = .{};
    for (bytes) |b| {
        bytewise.parser.feedBytes(&bytewise.trace, &.{b});
        try expectValid(&bytewise);
    }
    try expectSame(&whole, &bytewise);

    var split: Fed = .{};
    var rest = bytes;
    while (rest.len > 0) {
        const n = src.range("split", usize, 1, @min(rest.len, 64));
        split.parser.feedBytes(&split.trace, rest[0..n]);
        try expectValid(&split);
        rest = rest[n..];
    }
    try expectSame(&whole, &split);
}

const seeds = [_][]const u8{
    "\x1b7",                  "\x1b8",                                                                                              "\x1bD",                "\x1bc",
    "\x1b[",                  "\x1b]",                                                                                              "\x1b(B",               "\x1b\x1b",
    "\x1b\x18",               "hello\r\nworld",                                                                                     "\x1b[1;31mred\x1b[0m", "\x1b[?1049h\x1b[2J",
    "\x1b[38:2::1:2:3m",      "\x1b[1;2;3;4;5;6;7;8;9;10;11;12;13;14;15;16;17;18;19;20;21;22;23;24;25;26;27;28;29;30;31;32;33;34m", "\x1b]0;title\x07",     "\x1b]2;title\x1b\\",
    "\x1b]8;;http://x\x1b\\", "\x1b]0;a\x1b7",                                                                                      "\x1bP$qm\x1b\\",       "\x1bP1;2|data\x1b\\",
    "\x1bX sos \x1b\\",       "\x9b1;2H\x9d0;t\x9c",                                                                                "\x90q#0;2;0;0;0\x9c",  "\x1b[?25l\x1b[?25h",
    "\x1b[>c\x1b[=c\x1b[c",   "\x1b[ q\x1b[2 q",
};

const regressions = [_][]const u8{};

test "fuzz parser" {
    try harness.fuzz(run, &seeds, &regressions);
}

test "fuzz parser: seeded mutations" {
    try harness.seeded(run, &seeds, 0x7A25_E201);
}
