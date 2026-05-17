const std = @import("std");
const log = std.log.scoped(.osc);

const Transition = @import("parser.zig").Transition;

pub const State = enum {
    osc_param, // collecting numeric parameter before ';'
    osc_string, // collecting string payload after ';'
    osc_maybe_st, // saw ESC in valid state, waiting for '\'
    ignore, // malformed, consuming until terminator
    ignore_maybe_st, // saw ESC in ignore state, waiting for '\'
};

/// osc_param ─ ';' ─ osc_string ─ ESC ─ osc_maybe_st ─ '\' ─ .complete
///     |                  |                     |
///    ESC                ESC                  else ─ ignore
///     |                  |
/// osc_maybe_st        ignore_maybe_st
///     |
///    '\' ─ .abort (came from ignore path)
pub fn Osc(comptime max_string_len: usize) type {
    return struct {
        const Self = @This();
        pub const cap = max_string_len;

        param: u32,
        state: State,
        buffer_len: usize,
        buffer: [max_string_len]u8,

        pub const default: Self = .{
            .param = 0,
            .buffer = undefined,
            .buffer_len = 0,
            .state = .osc_param,
        };

        /// Per ECMA-48 §8.3.89: C0 controls other than BEL and ESC
        /// are ignored inside OSC strings.
        /// 0x7F (DEL) is also ignored.
        pub fn feed(self: *Self, byte: u8) Transition {
            return switch (self.state) {
                .osc_param => switch (byte) {
                    '0'...'9' => blk: {
                        const d: u32 = byte - '0';
                        const t = self.param *% 10 +% d;
                        if (t < self.param) {
                            // overflow
                            self.state = .ignore;
                            break :blk .next;
                        }

                        self.param = t;
                        break :blk .next;
                    },
                    ';' => blk: {
                        self.state = .osc_string;
                        break :blk .next;
                    },
                    0x07 => .abort, // BEL before ';' - malformed, still terminate
                    0x1B => blk: {
                        self.state = .ignore_maybe_st;
                        break :blk .next;
                    },
                    // C0 controls (except BEL, ESC) and DEL are ignored per ECMA-48
                    0x00...0x06, 0x08...0x1A, 0x1C...0x1F, 0x7F => .next,
                    else => blk: {
                        self.state = .ignore;
                        break :blk .next;
                    },
                },

                .osc_string => switch (byte) {
                    0x07 => .complete, // BEL terminator
                    0x1B => blk: {
                        self.state = .osc_maybe_st;
                        break :blk .next;
                    },
                    0x00...0x06, 0x08...0x1A, 0x1C...0x1F, 0x7F => .next,
                    else => blk: {
                        if (self.buffer_len < max_string_len) {
                            self.buffer[self.buffer_len] = byte;
                            self.buffer_len += 1;
                        } else {
                            self.state = .ignore;
                        }

                        break :blk .next;
                    },
                },

                .osc_maybe_st => switch (byte) {
                    '\\' => .complete,
                    0x07 => .abort,
                    else => blk: {
                        self.state = .ignore;
                        break :blk .next;
                    },
                },

                .ignore => switch (byte) {
                    0x07 => .abort,
                    0x1B => blk: {
                        self.state = .ignore_maybe_st;
                        break :blk .next;
                    },
                    else => .next,
                },

                .ignore_maybe_st => switch (byte) {
                    '\\' => .abort, // ESC \ = ST, but was malformed
                    0x07 => .abort,
                    else => blk: {
                        self.state = .ignore;
                        break :blk .next;
                    },
                },
            };
        }

        pub fn reset(self: *Self) void {
            self.param = 0;
            self.buffer_len = 0;
            self.state = .osc_param;
        }

        /// Returns the collected OSC string paylaod.
        /// Thus, dispatch or get the string only on (.complete) state.
        pub fn getString(self: *const Self) []const u8 {
            return self.buffer[0..self.buffer_len];
        }
    };
}

const MaxStringLen = 1 << 8;
const TestOsc = OSC(MaxStringLen);

fn feedAll(osc: *TestOsc, input: []const u8) Transition {
    var t: Transition = .next;
    for (input) |byte| t = osc.feed(byte);
    return t;
}

test "OSC: simple string, BEL terminator" {
    var osc: TestOsc = .empty;
    const t = feedAll(&osc, "2;My Window\x07");
    try std.testing.expectEqual(Transition.complete, t);
    try std.testing.expectEqual(@as(u32, 2), osc.param);
    try std.testing.expectEqualSlices(u8, "My Window", osc.getString());
}

test "OSC: simple string, ST terminator (ESC \\)" {
    var osc: TestOsc = .empty;
    const t = feedAll(&osc, "2;My Window\x1b\\");
    try std.testing.expectEqual(Transition.complete, t);
    try std.testing.expectEqual(@as(u32, 2), osc.param);
    try std.testing.expectEqualSlices(u8, "My Window", osc.getString());
}

test "OSC: param=0 (set icon name and title)" {
    var osc: TestOsc = .empty;
    const t = feedAll(&osc, "0;title\x07");
    try std.testing.expectEqual(Transition.complete, t);
    try std.testing.expectEqual(@as(u32, 0), osc.param);
    try std.testing.expectEqualSlices(u8, "title", osc.getString());
}

test "OSC: multi-digit param" {
    var osc: TestOsc = .empty;
    const t = feedAll(&osc, "104;color\x07");
    try std.testing.expectEqual(Transition.complete, t);
    try std.testing.expectEqual(@as(u32, 104), osc.param);
    try std.testing.expectEqualSlices(u8, "color", osc.getString());
}

test "OSC: empty string payload" {
    var osc: TestOsc = .empty;
    const t = feedAll(&osc, "0;\x07");
    try std.testing.expectEqual(Transition.complete, t);
    try std.testing.expectEqual(@as(u32, 0), osc.param);
    try std.testing.expectEqualSlices(u8, "", osc.getString());
}

test "OSC: zero param (no digits before semicolon)" {
    var osc: TestOsc = .empty;

    // ';' with no preceding digits → param defaults to 0
    const t = feedAll(&osc, ";\x07");
    try std.testing.expectEqual(Transition.complete, t);
    try std.testing.expectEqual(@as(u32, 0), osc.param);
}

test "OSC: OSC 52 clipboard (base64 payload)" {
    var osc: TestOsc = .empty;
    const t = feedAll(&osc, "52;c;aGVsbG8=\x07");
    try std.testing.expectEqual(Transition.complete, t);
    try std.testing.expectEqual(@as(u32, 52), osc.param);
    try std.testing.expectEqualSlices(u8, "c;aGVsbG8=", osc.getString());
}

test "OSC: OSC 8 hyperlink (double semicolon in string)" {
    var osc: TestOsc = .empty;
    const t = feedAll(&osc, "8;;https://example.com\x07");
    try std.testing.expectEqual(Transition.complete, t);
    try std.testing.expectEqual(@as(u32, 8), osc.param);
    try std.testing.expectEqualSlices(u8, ";https://example.com", osc.getString());
}

test "OSC: string with printable ASCII range" {
    var osc: TestOsc = .empty;
    const t = feedAll(&osc, "1; !\"#$%&'()*+,-./0123456789:;<=>?@AZ\x07");
    try std.testing.expectEqual(Transition.complete, t);
    try std.testing.expectEqual(@as(u32, 1), osc.param);
}

test "OSC: reset and reuse" {
    var osc: TestOsc = .empty;
    _ = feedAll(&osc, "2;first\x07");
    osc.reset();
    try std.testing.expectEqual(@as(u32, 0), osc.param);
    try std.testing.expectEqual(@as(usize, 0), osc.buffer_len);
    try std.testing.expectEqual(.osc_param, osc.state);

    const t = feedAll(&osc, "1;second\x07");
    try std.testing.expectEqual(Transition.complete, t);
    try std.testing.expectEqualSlices(u8, "second", osc.getString());
}

test "OSC: C0 controls (except BEL/ESC) ignored in string" {
    // 0x01..0x06 and 0x08..0x1A are ignored per ECMA-48 §8.3.89
    var osc: TestOsc = .empty;
    const t = feedAll(&osc, "0;ab\x01\x08\x0Acd\x07");
    try std.testing.expectEqual(Transition.complete, t);
    // C0 bytes are ignored, string is "abcd"
    try std.testing.expectEqualSlices(u8, "abcd", osc.getString());
}

test "OSC: DEL (0x7F) ignored in string" {
    var osc: TestOsc = .empty;
    const t = feedAll(&osc, "0;ab\x7Fcd\x07");
    try std.testing.expectEqual(Transition.complete, t);
    try std.testing.expectEqualSlices(u8, "abcd", osc.getString());
}

// maybe_st

test "OSC: ESC followed by non-backslash resumes string collection" {
    // ESC X (not ST) — ESC is consumed, X is processed as a string byte
    // (or ignored if it's a C0 control — depends on your design)

    var osc: TestOsc = .empty;
    // ESC followed by 'A' (not '\') — should NOT terminate
    _ = osc.feed('0');
    _ = osc.feed(';');
    _ = osc.feed('a');
    _ = osc.feed(0x1b); // ESC → maybe_st

    const t1 = osc.feed('A'); // not '\' → back to osc_string, 'A' processed
    try std.testing.expect(t1 == .next);
    const t2 = osc.feed('\x07'); // BEL → complete
    try std.testing.expectEqual(Transition.abort, t2);
    // string is "aA" (ESC consumed, 'A' added) — or "a" if 'A' is also dropped
    try std.testing.expect(osc.getString().len >= 1);
}

test "OSC: ESC at end of string (no following byte before BEL)" {
    // ESC then BEL — BEL is not '\', so not ST; behavior is implementation-defined

    var osc: TestOsc = .empty;
    _ = osc.feed('0');
    _ = osc.feed(';');
    _ = osc.feed(0x1b); // ESC → maybe_st
    const t = osc.feed(0x07); // BEL — not '\', so not ST

    // Most implementations: treat as abort or ignore the ESC and complete on BEL
    try std.testing.expect(t == .abort);
}

test "OSC: non-digit non-semicolon byte in osc_param → abort" {
    var osc: TestOsc = .empty;
    // 'A' (0x41) is not a digit or ';' in the param phase
    const t = osc.feed('A');

    try std.testing.expectEqual(Transition.next, t);
}

test "OSC: BEL before semicolon (no string phase entered) → abort" {
    // BEL arrives while still in osc_param (no ';' seen yet)
    var osc: TestOsc = .empty;
    _ = osc.feed('2');
    const t = osc.feed(0x07); // BEL in osc_param state
    try std.testing.expectEqual(Transition.abort, t);
}

test "OSC: ST before semicolon → abort" {
    var osc: TestOsc = .empty;

    _ = osc.feed('2');
    _ = osc.feed(0x1b); // ESC in osc_param
    const t = osc.feed('\\');
    try std.testing.expectEqual(Transition.abort, t);
}

test "OSC: param overflow → ignore → abort at terminator" {
    var osc: TestOsc = .empty;
    // Feed enough digits to overflow u32 (> 4294967295)
    _ = feedAll(&osc, "99999999999");
    _ = osc.feed(';');
    _ = feedAll(&osc, "payload");
    const t = osc.feed(0x07);
    try std.testing.expectEqual(Transition.abort, t);
}

test "OSC: string overflow → ignore → abort at terminator" {
    var osc: TestOsc = .empty;
    _ = osc.feed('0');
    _ = osc.feed(';');
    // Fill the string buffer past max_string_len
    for (0..TestOsc.cap + 1) |_| {
        _ = osc.feed('x');
    }
    // State should now be .ignore
    try std.testing.expectEqual(.ignore, osc.state);
    const t = osc.feed(0x07);
    try std.testing.expectEqual(Transition.abort, t);
}

test "OSC: abort in ignore state, then reset and reuse" {
    var osc: TestOsc = .empty;
    // Trigger overflow → ignore
    _ = osc.feed('0');
    _ = osc.feed(';');
    for (0..TestOsc.cap + 1) |_| {
        _ = osc.feed('x');
    }
    const t = osc.feed(0x07);
    try std.testing.expectEqual(Transition.abort, t);

    // After reset, parser should work normally
    osc.reset();
    const t2 = feedAll(&osc, "1;ok\x07");
    try std.testing.expectEqual(Transition.complete, t2);
    try std.testing.expectEqualSlices(u8, "ok", osc.getString());
}

// Boundary / exact-capacity cases
test "OSC: string exactly at max_string_len → complete" {
    var osc: TestOsc = .empty;
    _ = osc.feed('0');
    _ = osc.feed(';');
    for (0..TestOsc.cap) |_| {
        _ = osc.feed('x');
    }
    const t = osc.feed(0x07);
    try std.testing.expectEqual(Transition.complete, t);
    try std.testing.expectEqual(TestOsc.cap, osc.getString().len);
}

test "OSC: string one byte over max_string_len → abort" {
    var osc: TestOsc = .empty;
    _ = osc.feed('0');
    _ = osc.feed(';');
    for (0..TestOsc.cap + 1) |_| {
        _ = osc.feed('x');
    }
    const t = osc.feed(0x07);
    try std.testing.expectEqual(Transition.abort, t);
}

test "OSC: param = max u32 boundary (4294967295)" {
    // 4294967295 = 0xFFFFFFFF — if your overflow check is > max, this should complete
    // if your check is >= max, this should abort. Adjust to match your design.
    var osc: TestOsc = .empty;
    const t = feedAll(&osc, "4294967295;x\x07");
    try std.testing.expect(t == .complete);
}

test "OSC: fuzz — no crash on arbitrary input" {
    const Context = struct {
        fn testOne(_: @This(), smith: *std.testing.Smith) anyerror!void {
            var buf: [256]u8 = undefined;
            smith.bytes(&buf);

            // First byte encodes input length (0..255)
            const input = buf[1..][0..buf[0]];

            var osc: TestOsc = .empty;

            for (input) |byte| {
                const t = osc.feed(byte);
                switch (t) {
                    .next => {
                        try std.testing.expect(osc.buffer_len <= TestOsc.cap);
                    },
                    .complete => {
                        try std.testing.expect(osc.state != .ignore);
                        _ = osc.getString(); // must not panic
                        osc.reset();
                        try std.testing.expectEqual(.osc_param, osc.state);
                        try std.testing.expectEqual(@as(u32, 0), osc.param);
                        try std.testing.expectEqual(@as(usize, 0), osc.buffer_len);
                    },
                    .abort => {
                        osc.reset();
                    },
                }
            }
        }
    };

    try std.testing.fuzz(Context{}, Context.testOne, .{
        .corpus = &.{
            "\x08" ++ "0;title\x07",
            "\x09" ++ "2;window\x07",
            "\x09" ++ "0;title\x1b\\",
            "\x02" ++ ";\x07",
            "\x01" ++ "\x07", // BEL with no param → abort
            "\x0d" ++ "52;c;aGVsbG8=\x07",
            "\x16" ++ "8;;https://example.com\x07",
            "\x04" ++ "0;a\x1b", // ESC at end, no terminator
            "\x05" ++ "0;a\x1b\\", // ST terminator
            "\x00", // empty input
        },
    });
}
