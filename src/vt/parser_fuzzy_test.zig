const std = @import("std");
const Parser = @import("parser.zig").Parser;
const State = @import("parser.zig").State;

const log = std.log.scoped(.ansi_test);

// test {
//     std.testing.log_level = .debug;
// }

const NullDispatcher = struct {
    pub fn print(_: *@This(), _: u8) void {}
    pub fn execute(_: *@This(), _: u8) void {}
    pub fn escDispatch(_: *@This(), _: u8, _: []const u8) void {}
    pub fn csiDispatch(_: *@This(), _: u8, _: []const u8, _: []const u16) void {}
    pub fn oscStart(_: *@This()) void {}
    pub fn oscPut(_: *@This(), _: u8) void {}
    pub fn oscEnd(_: *@This()) void {}
};

fn fuzzEscapeState(_: void, smith: *std.testing.Smith) anyerror!void {
    var d: NullDispatcher = .{};
    var p: Parser(NullDispatcher) = .{};

    var buf: [3]u8 = undefined;
    const n = smith.slice(&buf);

    if (n == 0) return;

    p.feed(&d, buf[0..n]);
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
