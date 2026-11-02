const std = @import("std");

const testing = std.testing;
const tables = @import("wcwidth_table.zig");

fn unpackCodepoint(v: u32) u21 {
    return @intCast(v >> 11);
}

fn unpackSize(v: u32) u32 {
    return ((v >> 3) & 0xff) + 1;
}

fn unpackProperty(v: u32) tables.Property {
    return @enumFromInt(@as(u3, @intCast(v & 0x7)));
}

test "tables: table is sorted and well formed" {
    const entries = tables.entries;

    var previous_start: u21 = 0;
    var previous_end: u32 = 0;

    for (entries, 0..) |entry, i| {
        const start = unpackCodepoint(entry);
        const size = unpackSize(entry);
        const end: u32 = @as(u32, start) + size;

        // size-1 occupies bits [3, 11), so the maximum range length is 256.
        try testing.expect(size >= 1 and size <= 256);
        try testing.expect(end <= 0x110000);

        if (i != 0) {
            try testing.expect(start > previous_start);
            try testing.expect(@as(u32, start) >= previous_end);
        }

        // Confirm the packed property is a valid enum value.
        _ = unpackProperty(entry);

        previous_start = start;
        previous_end = end;
    }
}