const std = @import("std");

const testing = std.testing;

const utf8 = @import("utf8.zig");
const Decoder = utf8.Decoder;

test "Hoehrmann DFA matches std.unicode.utf8View" {
    const input = "hello 世界 😀 café";

    // collect std.unicode decoded codepoints
    var std_result: [256]u32 = undefined;
    var std_len: usize = 0;

    var view = try std.unicode.Utf8View.init(input);
    var iter = view.iterator();

    while (iter.nextCodepoint()) |cp| {
        std_result[std_len] = cp;
        std_len += 1;
    }

    // collect DFA decoded codepoints
    var dfa: Decoder = .empty;

    var dfa_result: [256]u32 = undefined;
    var dfa_len: usize = 0;

    for (input) |byte| {
        if (dfa.feed(byte)) |cp| {
            dfa_result[dfa_len] = cp;
            dfa_len += 1;
        }

        if (dfa.state == Decoder.reject) {
            return error.InvalidUtf8;
        }
    }

    // compare lengths
    try testing.expectEqual(std_len, dfa_len);

    // compare every codepoint
    for (dfa_result[0..dfa_len], std_result[0..std_len]) |a, b| {
        try testing.expectEqual(a, b);
    }
}

test "Hoehrmann DFA rejects invalid utf8" {
    // invalid continuation byte sequence
    const input = [_]u8{
        0xE2,
        0x28,
        0xA1,
    };

    var dfa: Decoder = .empty;

    var rejected = false;

    for (input) |byte| {
        _ = dfa.feed(byte);

        if (dfa.state == Decoder.reject) {
            rejected = true;
            break;
        }
    }

    try testing.expect(rejected);
}

test "Hoehrmann DFA fuzz compare std.unicode" {
    var prng = std.Random.DefaultPrng.init(0xdeadbeef);
    const random = prng.random();

    var buf: [4096]u8 = undefined;

    for (0..10_000) |_| {
        random.bytes(&buf);

        const std_valid = std.unicode.utf8ValidateSlice(&buf);

        var dfa: Decoder = .empty;
        var dfa_valid = true;

        for (buf) |byte| {
            _ = dfa.feed(byte);
            if (dfa.state == Decoder.reject) {
                dfa_valid = false;
                break;
            }
        }

        // unfinished sequence is invalid
        if (dfa.state != 0)
            dfa_valid = false;

        try testing.expectEqual(std_valid, dfa_valid);
    }
}
