const std = @import("std");

const parser = @import("parser.zig");

const Transition = parser.Transition;
const Separator = parser.Separator;

const ValueCap: usize = 16;
const TestSi = parser.Csi(ValueCap);

test "SeparatorPacked basic set/get" {
    var s: parser.SeparatorPacked(8) = .empty;

    s.set(0, .colon);
    s.set(1, .semicolon);
    s.set(2, .end);

    try std.testing.expectEqual(.colon, s.get(0));
    try std.testing.expectEqual(.semicolon, s.get(1));
    try std.testing.expectEqual(.end, s.get(2));
}

test "SeparatorPacked: set/get round-trip" {
    const P = parser.SeparatorPacked(8);
    var p = P.empty;
    p.set(0, .semicolon);
    p.set(3, .colon);
    p.set(7, .end);
    try std.testing.expectEqual(Separator.semicolon, p.get(0));
    try std.testing.expectEqual(Separator.colon, p.get(3));
    try std.testing.expectEqual(Separator.end, p.get(7));
}

test "SeparatorPacked: fresh instance reads as zero" {
    const P = parser.SeparatorPacked(8);
    const p = P.empty;
    try std.testing.expectEqual(@as(Separator, @enumFromInt(0)), p.get(0));
    try std.testing.expectEqual(@as(Separator, @enumFromInt(0)), p.get(7));
}

test "SeparatorPacked: set does not clobber adjacent slots" {
    const P = parser.SeparatorPacked(4);
    var p = P.empty;
    p.set(1, .semicolon);
    p.set(2, .colon);
    try std.testing.expectEqual(@as(Separator, @enumFromInt(0)), p.get(0));
    try std.testing.expectEqual(Separator.semicolon, p.get(1));
    try std.testing.expectEqual(Separator.colon, p.get(2));
    try std.testing.expectEqual(@as(Separator, @enumFromInt(0)), p.get(3));
}

test "SeparatorPacked: overwrite slot" {
    const P = parser.SeparatorPacked(4);
    var p = P.empty;
    p.set(2, .semicolon);
    p.set(2, .colon); // overwrite
    try std.testing.expectEqual(Separator.colon, p.get(2));
}

test "SeparatorPacked boundary indices" {
    var s: parser.SeparatorPacked(16) = .empty;

    s.set(0, .colon);
    s.set(15, .semicolon);

    try std.testing.expectEqual(.colon, s.get(0));
    try std.testing.expectEqual(.semicolon, s.get(15));
}

test "SeparatorPacked full capacity stress test" {
    var s: parser.SeparatorPacked(32) = .empty;

    // fill pattern
    for (0..32) |i| {
        const v: Separator = if (i % 3 == 0)
            .colon
        else if (i % 3 == 1)
            .semicolon
        else
            .end;

        s.set(i, v);
    }

    // verify
    for (0..32) |i| {
        const expected: Separator = if (i % 3 == 0)
            .colon
        else if (i % 3 == 1)
            .semicolon
        else
            .end;

        try std.testing.expectEqual(expected, s.get(i));
    }
}

test "SeparatorPacked alternating pattern" {
    var s: parser.SeparatorPacked(16) = .empty;
    for (0..16) |i| {
        s.set(i, if (i % 2 == 0) .colon else .semicolon);
    }

    for (0..16) |i| {
        const expected: Separator = if (i % 2 == 0)
            .colon
        else
            .semicolon;

        try std.testing.expectEqual(expected, s.get(i));
    }
}

test "SeparatorPacked default is zeroed" {
    var s: parser.SeparatorPacked(10) = .empty;
    for (0..10) |i| {
        try std.testing.expectEqual(.end, s.get(i));
    }
}

test "SI: no params — bare final byte" {
    var si: TestSi = .default;
    const t = si.feed('m');

    try std.testing.expectEqual(parser.Transition.complete, t);
    try std.testing.expectEqual(@as(u8, 'm'), si.final);
    try std.testing.expectEqual(0, si.value_count);
}

test "SI: single param" {
    var si: TestSi = .default;
    _ = si.feed('5');
    const t = si.feed('m');

    try std.testing.expectEqual(parser.Transition.complete, t);
    try std.testing.expectEqual(@as(u8, 'm'), si.final);
    try std.testing.expectEqual(1, si.value_count);
    try std.testing.expectEqual(5, si.values[0]);
}

/// Feed a byte slice into the parser, stopping at the first
/// .complete or .abort transition. Returns the final transition.
fn feedAll(si: *TestSi, bytes: []const u8) Transition {
    var result: Transition = .next;
    for (bytes) |b| {
        result = si.feed(b);
        if (result == .complete or result == .abort) return result;
    }
    return result;
}

test "SI: multi-digit in single param" {
    var si: TestSi = .default;
    const t = feedAll(&si, "123m");

    try std.testing.expectEqual(parser.Transition.complete, t);
    try std.testing.expectEqual(@as(u8, 'm'), si.final);
    try std.testing.expectEqual(1, si.value_count);
    try std.testing.expectEqual(123, si.values[0]);
}

test "SI: multi-digit in multi param" {
    var si: TestSi = .default;
    const t = feedAll(&si, "123;789m");

    try std.testing.expectEqual(parser.Transition.complete, t);
    try std.testing.expectEqual(@as(u8, 'm'), si.final);
    try std.testing.expectEqual(2, si.value_count);
    try std.testing.expectEqual(123, si.values[0]);
    try std.testing.expectEqual(789, si.values[1]);
}

test "SI: sentinel collision (65535 | no_value) must abort" {
    var si: TestSi = .default;
    const t = feedAll(&si, "65535m");

    try std.testing.expectEqual(Transition.abort, t);
    try std.testing.expectEqual(0, si.final);
    try std.testing.expectEqual(0, si.value_count);
}

test "SI: max parameter value (no_value - 1)" {
    var si: TestSi = .default;
    const t = feedAll(&si, "65534m");

    try std.testing.expectEqual(Transition.complete, t);
    try std.testing.expectEqual('m', si.final);
    try std.testing.expectEqual(1, si.value_count);
    try std.testing.expectEqual(65534, si.value(0, 0));
}

test "SI: two params with semicolon separator" {
    var si: TestSi = .default;
    const t = feedAll(&si, "1;2m");

    try std.testing.expectEqual(Transition.complete, t);
    try std.testing.expectEqual(2, si.value_count);
    try std.testing.expectEqual(@as(u16, 1), si.value(0, 0));
    try std.testing.expectEqual(@as(u16, 2), si.value(1, 0));
    try std.testing.expectEqual(Separator.semicolon, si.separators.get(0));
    try std.testing.expectEqual(Separator.end, si.separators.get(1));
}

test "SI: three params" {
    var si: TestSi = .default;
    const t = feedAll(&si, "1;2;3m");
    try std.testing.expectEqual(Transition.complete, t);
    try std.testing.expectEqual(3, si.value_count);
    try std.testing.expectEqual(@as(u16, 1), si.value(0, 0));
    try std.testing.expectEqual(@as(u16, 2), si.value(1, 0));
    try std.testing.expectEqual(@as(u16, 3), si.value(2, 0));
    try std.testing.expectEqual(Separator.semicolon, si.separators.get(0));
    try std.testing.expectEqual(Separator.semicolon, si.separators.get(1));
    try std.testing.expectEqual(Separator.end, si.separators.get(2));
}

test "SI: colon sub-params (SGR 38:2:r:g:b)" {
    var si: TestSi = .default;
    const t = feedAll(&si, "38:2:255:0:128m");
    try std.testing.expectEqual(Transition.complete, t);
    try std.testing.expectEqual(5, si.value_count);
    try std.testing.expectEqual(@as(u16, 38), si.value(0, 0));
    try std.testing.expectEqual(@as(u16, 2), si.value(1, 0));
    try std.testing.expectEqual(@as(u16, 255), si.value(2, 0));
    try std.testing.expectEqual(@as(u16, 0), si.value(3, 0));
    try std.testing.expectEqual(@as(u16, 128), si.value(4, 0));
    // All separators before the last are .colon
    for (0..4) |i| {
        try std.testing.expectEqual(Separator.colon, si.separators.get(i));
    }
    try std.testing.expectEqual(Separator.end, si.separators.get(4));
}

test "SI: mixed semicolon and colon separators" {
    var si: TestSi = .default;
    // CSI 1;38:2:255:0:0m
    const t = feedAll(&si, "1;38:2:255:0:0m");
    try std.testing.expectEqual(Transition.complete, t);
    try std.testing.expectEqual(6, si.value_count);
    try std.testing.expectEqual(Separator.semicolon, si.separators.get(0)); // after 1
    try std.testing.expectEqual(Separator.colon, si.separators.get(1)); // after 38
    try std.testing.expectEqual(Separator.colon, si.separators.get(2)); // after 2
    try std.testing.expectEqual(Separator.colon, si.separators.get(3)); // after 255
    try std.testing.expectEqual(Separator.colon, si.separators.get(4)); // after 0
    try std.testing.expectEqual(Separator.end, si.separators.get(5)); // after 0
}

test "SI: empty first param uses default" {
    var si: TestSi = .default;
    // CSI ;2m — first param is omitted
    const t = feedAll(&si, ";2m");
    try std.testing.expectEqual(Transition.complete, t);
    try std.testing.expectEqual(2, si.value_count);
    try std.testing.expectEqual(@as(u16, 99), si.value(0, 99)); // empty → default
    try std.testing.expectEqual(@as(u16, 2), si.value(1, 0));
}

test "SI: trailing semicolon creates empty trailing param" {
    var si: TestSi = .default;
    // CSI 1;m — trailing empty param
    const t = feedAll(&si, "1;m");
    try std.testing.expectEqual(Transition.complete, t);
    try std.testing.expectEqual(2, si.value_count);
    try std.testing.expectEqual(@as(u16, 1), si.value(0, 0));
    try std.testing.expectEqual(@as(u16, 99), si.value(1, 99)); // trailing empty → default
}

test "SI: all-empty params (only semicolons)" {
    var si: TestSi = .default;
    // CSI ;;m — three empty params
    const t = feedAll(&si, ";;m");
    try std.testing.expectEqual(Transition.complete, t);
    try std.testing.expectEqual(3, si.value_count);
    try std.testing.expectEqual(@as(u16, 0), si.value(0, 0)); // default = 0
    try std.testing.expectEqual(@as(u16, 0), si.value(1, 0));
    try std.testing.expectEqual(@as(u16, 0), si.value(2, 0));
}

test "SI: private marker '?' at start" {
    var si: TestSi = .default;
    // CSI ?25h
    const t = feedAll(&si, "?25h");
    try std.testing.expectEqual(Transition.complete, t);
    // '?' = 0x3F, byte - 0x3B = 4
    try std.testing.expectEqual(@as(u8, 4), @intFromEnum(si.private_marker));
    try std.testing.expectEqual(@as(u16, 25), si.value(0, 0));
    try std.testing.expectEqual(@as(u8, 'h'), si.final);
}

test "SI: private marker '>' at start" {
    var si: TestSi = .default;
    // CSI >1c
    const t = feedAll(&si, ">1c");
    try std.testing.expectEqual(Transition.complete, t);
    // '>' = 0x3E, byte - 0x3B = 3
    try std.testing.expectEqual(@as(u8, 3), @intFromEnum(si.private_marker));
    try std.testing.expectEqual(@as(u16, 1), si.value(0, 0));
}

test "SI: intermediate byte" {
    var si: TestSi = .default;
    // CSI 1 SP q  (SP = 0x20)
    _ = si.feed('1');
    _ = si.feed(0x20);
    const t = si.feed('q');
    try std.testing.expectEqual(Transition.complete, t);
    try std.testing.expectEqual(@as(u8, 'q'), si.final);
    try std.testing.expectEqual(@as(u8, 0x20), si.intermediates[0]);
    try std.testing.expectEqual(1, si.intermediate_count);
}

test "SI: multiple intermediate bytes" {
    var si: TestSi = .default;
    _ = si.feed(0x20);
    _ = si.feed(0x21);
    const t = si.feed('q');
    try std.testing.expectEqual(Transition.complete, t);
    try std.testing.expectEqual(@as(u8, 0x20), si.intermediates[0]);
    try std.testing.expectEqual(@as(u8, 0x21), si.intermediates[1]);
    try std.testing.expectEqual(2, si.intermediate_count);
}

test "SI: DEL (0x7F) is skipped in params state" {
    var si: TestSi = .default;
    // CSI 1 DEL 2 m — DEL skipped, digits concatenate to 12
    _ = si.feed('1');
    const del_t = si.feed(0x7F);
    try std.testing.expectEqual(Transition.next, del_t);
    _ = si.feed('2');
    const t = si.feed('m');
    try std.testing.expectEqual(Transition.complete, t);
    try std.testing.expectEqual(@as(u16, 12), si.value(0, 0));
}

test "SI: DEL (0x7F) is skipped in intermediates state" {
    var si: TestSi = .default;
    _ = si.feed(0x20); // enter intermediates
    const del_t = si.feed(0x7F);
    try std.testing.expectEqual(Transition.next, del_t);
    const t = si.feed('q');
    try std.testing.expectEqual(Transition.complete, t);
}

test "SI: value() returns default for out-of-bounds index" {
    var si: TestSi = .default;
    _ = feedAll(&si, "5m");
    try std.testing.expectEqual(@as(u16, 5), si.value(0, 99));
    try std.testing.expectEqual(@as(u16, 99), si.value(1, 99)); // out of bounds
    try std.testing.expectEqual(@as(u16, 99), si.value(15, 99)); // far out of bounds
}

test "SI: reset clears all state" {
    var si: TestSi = .default;
    _ = feedAll(&si, "?1;2m");
    si.reset();
    try std.testing.expectEqual(@as(u8, 0), si.final);
    try std.testing.expectEqual(0, si.value_count);
    try std.testing.expectEqual(0, si.intermediate_count);
    // separators must be cleared
    try std.testing.expectEqual(@as(Separator, @enumFromInt(0)), si.separators.get(0));
    // state must be .params
    try std.testing.expectEqual(@as(u2, 0), @intFromEnum(si.state)); // .params = 0
}

test "SI: reset then valid sequence works correctly" {
    var si: TestSi = .default;
    _ = feedAll(&si, "1;2m");
    si.reset();
    const t = feedAll(&si, "42m");
    try std.testing.expectEqual(Transition.complete, t);
    try std.testing.expectEqual(@as(u16, 42), si.value(0, 0));
    try std.testing.expectEqual(1, si.value_count);
}

// ─── Invalid / malformed sequences

test "SI: private marker mid-sequence → ignore state, final byte → abort" {
    var si: TestSi = .default;
    // CSI 1?m — '?' after a digit is malformed
    _ = si.feed('1');
    _ = si.feed('?'); // should transition to .ignore (= 2)
    try std.testing.expectEqual(@as(u2, 2), @intFromEnum(si.state));
    const t = si.feed('m');
    try std.testing.expectEqual(Transition.abort, t);
}

test "SI: param byte during intermediates → ignore state" {
    var si: TestSi = .default;
    // CSI 1 SP 2 m — '2' (0x32) after intermediate SP is malformed
    _ = si.feed('1');
    _ = si.feed(0x20); // → .intermediates
    _ = si.feed('2'); // 0x32 ∈ 0x30..0x3F → .ignore
    try std.testing.expectEqual(@as(u2, 2), @intFromEnum(si.state));
    const t = si.feed('m');
    try std.testing.expectEqual(Transition.abort, t);
}

test "SI: digit overflow (65536) → ignore state" {
    var si: TestSi = .default;
    // 6,5,5,3,6 → temp = 65536 > 0xFFFF
    _ = si.feed('6');
    _ = si.feed('5');
    _ = si.feed('5');
    _ = si.feed('3');
    _ = si.feed('6'); // overflow here
    try std.testing.expectEqual(@as(u2, 2), @intFromEnum(si.state));
    const t = si.feed('m');
    try std.testing.expectEqual(Transition.abort, t);
}

test "SI: value count overflow → ignore state" {
    var si: TestSi = .default;
    // Feed Cap+1 params: "0;0;...;0;0m" with Cap+1 values
    // Cap=16 means 17 values → 17th pushValue overflows
    var buf: [ValueCap * 2 + 2]u8 = undefined;
    for (0..ValueCap) |i| {
        buf[i * 2] = '0';
        buf[i * 2 + 1] = ';';
    }

    buf[ValueCap * 2] = '0'; // 17th value
    buf[ValueCap * 2 + 1] = 'm';

    const t = feedAll(&si, buf[0 .. ValueCap * 2 + 2]);
    try std.testing.expectEqual(Transition.abort, t);
}

test "SI: ignore state consumes all bytes until final byte" {
    var si: TestSi = .default;
    // Enter ignore via mid-sequence private marker
    _ = si.feed('1');
    _ = si.feed('?'); // → .ignore
    // These should all return .next (consuming)
    try std.testing.expectEqual(Transition.next, si.feed('2'));
    try std.testing.expectEqual(Transition.next, si.feed('3'));
    try std.testing.expectEqual(Transition.next, si.feed(';'));
    // Final byte → .abort
    try std.testing.expectEqual(Transition.abort, si.feed('m'));
}

test "SI: reset after ignore allows fresh valid sequence" {
    var si: TestSi = .default;
    _ = si.feed('1');
    _ = si.feed('?'); // → .ignore
    _ = si.feed('m'); // → .abort
    si.reset();
    const t = feedAll(&si, "7;8m");
    try std.testing.expectEqual(Transition.complete, t);
    try std.testing.expectEqual(@as(u16, 7), si.value(0, 0));
    try std.testing.expectEqual(@as(u16, 8), si.value(1, 0));
}

test "SI: intermediate overflow → ignore state" {
    var si: TestSi = .default;
    // Feed more intermediates than si.intermediates.len
    for (0..si.intermediates.len + 1) |_| {
        _ = si.feed(0x20);
    }
    try std.testing.expectEqual(@as(u2, 2), @intFromEnum(si.state));
    const t = si.feed('m');
    try std.testing.expectEqual(Transition.abort, t);
}

test "SI: unknown byte in params → abort" {
    var si: TestSi = .default;
    // 0x10 is not a valid CSI parameter byte
    const t = si.feed(0x10);
    try std.testing.expectEqual(Transition.abort, t);
}

test "SI: unknown byte in intermediates → abort" {
    var si: TestSi = .default;
    _ = si.feed(0x20); // → .intermediates
    const t = si.feed(0x10); // not valid in intermediates
    try std.testing.expectEqual(Transition.abort, t);
}

test "SI: fuzz — no crash on arbitrary input" {
    const Context = struct {
        fn testOne(_: @This(), smith: *std.testing.Smith) anyerror!void {
            // buf[0] = length of actual input (0..255)
            // buf[1..256] = the input bytes
            var buf: [256]u8 = undefined;
            smith.bytes(&buf);

            const len: usize = buf[0]; // 0 → empty, 255 → max
            const input = buf[1..][0..len];

            var si: TestSi = .default;

            for (input) |byte| {
                const t = si.feed(byte);
                switch (t) {
                    .next => {
                        try std.testing.expect(si.value_count <= TestSi.capacity);
                        try std.testing.expect(si.intermediate_count <= si.intermediates.len);
                    },
                    .complete => {
                        try std.testing.expect(si.final >= 0x40 and si.final <= 0x7E);
                        try std.testing.expect(si.state != .ignore);
                        for (0..si.value_count) |i| {
                            _ = si.value(i, 0);
                            _ = si.separators.get(i);
                        }
                        si.reset();
                        try std.testing.expect(si.value_count == 0);
                        try std.testing.expect(si.intermediate_count == 0);
                        try std.testing.expect(si.state == .params);
                    },
                    .abort => {
                        si.reset();
                    },
                }
            }
        }
    };

    try std.testing.fuzz(Context{}, Context.testOne, .{
        // Corpus format: first byte = length, remaining = input bytes
        .corpus = &.{
            "\x01m", // len=1: bare final byte
            "\x02" ++ "1m", // len=2: single param
            "\x04" ++ "1;2m", // len=4: two params
            "\x04" ++ "?25h", // len=4: private marker
            "\x0d" ++ "38:2:255:0:0m", // len=13: colon sub-params
            "\x02" ++ "\x20q", // len=2: intermediate byte
            "\x03" ++ "1?m", // len=3: malformed private marker mid-seq
            "\x04" ++ "\x20\x32m", // len=3: param byte during intermediates
            "\x06" ++ "65534m", // len=6: boundary value
            "\x00", // len=0: empty input

            // .ignore → else → .next (non-final byte consumed in ignore state)
            "\x04" ++ "1?0m",

            // digit overflow → .ignore (65535 >= 0xFFFF)
            "\x07" ++ "65535m",

            // 0x7F in .params → .next
            // DEL then final
            "\x03" ++ "\x7F" ++ "m",

            // else (invalid byte) in .params → .abort
            // 0x01 is not a valid param byte
            "\x02" ++ "\x01m",

            // multiple intermediates in .intermediates
            // two intermediate bytes
            "\x04" ++ "\x20\x20" ++ "q",

            // 0x7F in .intermediates → .next
            "\x04" ++ "\x20\x7F" ++ "q",

            // else (invalid byte) in .intermediates → .abort
            // 0x01 is not valid in intermediates
            "\x03" ++ "\x20\x01",

            // value count overflow → .ignore → .abort (Cap = 16, need 17 values)
            // "0;0;0;0;0;0;0;0;0;0;0;0;0;0;0;0;0m" = 33 bytes
            "\x21" ++ "0;0;0;0;0;0;0;0;0;0;0;0;0;0;0;0;0m",

            // fix the existing bug:
            // was \x04 (wrong length)
            "\x03" ++ "\x20\x32m",
        },
    });
}
