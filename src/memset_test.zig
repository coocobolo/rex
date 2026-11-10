const std = @import("std");
const testing = std.testing;

const memset = @import("memset.zig");

/// Background of the test buffer; no fill value below uses it, so a
/// stray write outside the filled range shows up.
const guard: u8 = 0x5a;

test "memset: fill sets exactly the requested bytes" {
    const max_len = 512;
    const max_offset = 64;
    // `max_offset` guard bytes before the widest start and after the
    // longest fill catch writes past either end.
    var buf: [max_offset + max_len + max_offset]u8 = undefined;

    for ([_]u8{ 0x00, 0xa5, 0xff }) |c| {
        for (0..max_offset) |offset| {
            for (0..max_len + 1) |len| {
                for (&buf) |*b| b.* = guard;
                memset.fill(buf[offset..].ptr, c, len);

                for (buf, 0..) |b, i| {
                    const inside = i >= offset and i < offset + len;
                    if (b != if (inside) c else guard) {
                        std.debug.print("c=0x{x} offset={d} len={d}: byte {d} is 0x{x}\n", .{ c, offset, len, i, b });
                        return error.TestUnexpectedResult;
                    }
                }
            }
        }
    }
}

test "memset: the exported symbol returns dest and accepts null with zero length" {
    const c_memset = @extern(*const fn (?[*]u8, c_int, usize) callconv(.c) ?[*]u8, .{ .name = "memset" });

    var buf: [100]u8 = @splat(guard);
    try testing.expectEqual(@as(?[*]u8, &buf), c_memset(&buf, 0x1ff, 99));
    // C passes `int`; only the low byte counts.
    for (buf[0..99]) |b| try testing.expectEqual(0xff, b);
    try testing.expectEqual(guard, buf[99]);

    try testing.expectEqual(null, c_memset(null, 0, 0));
}
