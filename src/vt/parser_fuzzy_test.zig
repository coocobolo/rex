const std = @import("std");

const parser = @import("parser.zig");
const Parser = parser.Parser;
const State = parser.State;
const ChecksumDispatcher = parser.ChecksumDispatcher;

fn fuzzEscapeState(_: void, smith: *std.testing.Smith) anyerror!void {
    var d: ChecksumDispatcher = .{};
    var p: Parser(ChecksumDispatcher, .{}) = .{};

    var buf: [3]u8 = undefined;
    const n = smith.slice(&buf);

    if (n == 0) return;

    p.feedBytes(&d, buf[0..n]);
    const s = @intFromEnum(p.state);
    try std.testing.expect(s < State.count);
}

test "fuzz: escape state" {
    try std.testing.fuzz({}, fuzzEscapeState, .{
        .corpus = &.{
            "\x1b7", // DECSC
            "\x1b8", // DECRC
            "\x1bD", // IND
            "\x1bE", // NEL
            "\x1bM", // RI
            "\x1bc", // RIS
            "\x1b[", // ESC [ csi_entry
            "\x1b]", // ESC ] osc_string
            "\x1b(B", // ESC with intermediate
            "\x1b\x1b", // double ESC
            "\x1b\x18", // ESC then CAN (anywhere transition)
        },
    });
}
