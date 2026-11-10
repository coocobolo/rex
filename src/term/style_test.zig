const std = @import("std");
const testing = std.testing;
const Style = @import("Style.zig");
const Table = Style.Table;
const Color = @import("../color/color.zig").Color;

fn rgbStyle(n: u32) Style {
    const c: Color = .{ .rgb = .{ .r = @truncate(n >> 16), .g = @truncate(n >> 8), .b = @truncate(n) } };
    return Style.init(c, .default, .default);
}

/// Fills every ID of `table` with a distinct style; returns the last one's
/// argument to `rgbStyle`.
fn fill(table: *Table) u32 {
    var n: u32 = 0;
    while (table.intern(rgbStyle(n)) != null) n += 1;
    return n;
}

test "Style: 12 bytes, encodes and decodes every color kind" {
    try testing.expectEqual(12, @sizeOf(Style));
    for ([_]Color{ .default, .{ .indexed = 0 }, .{ .indexed = 255 }, .{ .rgb = .{ .r = 1, .g = 2, .b = 3 } } }) |c| {
        try testing.expectEqual(c, Style.decode(Style.encode(c)));
    }
    try testing.expect(Style.init(.default, .default, .default).isDefault());
}

test "Style.Table intern: the default style is ID 0 and is never stored" {
    var t = try Table.init(testing.allocator);
    defer t.deinit(testing.allocator);
    try testing.expectEqual(Table.default_id, t.intern(.default).?);
    try testing.expectEqual(0, t.count());
}

test "Style.Table intern: the same style twice gives the same ID, others differ" {
    var t = try Table.init(testing.allocator);
    defer t.deinit(testing.allocator);
    const a = t.intern(rgbStyle(1)).?;
    const b = t.intern(rgbStyle(2)).?;
    try testing.expect(a != b);
    try testing.expectEqual(a, t.intern(rgbStyle(1)).?);
    try testing.expect(t.get(a).eql(rgbStyle(1)));
    try testing.expectEqual(2, t.count());
}

test "Style.Table intern: an indexed and an RGB color with the same bits are different styles" {
    var t = try Table.init(testing.allocator);
    defer t.deinit(testing.allocator);
    const indexed = t.intern(Style.init(.{ .indexed = 1 }, .default, .default)).?;
    const rgb = t.intern(Style.init(.{ .rgb = .{ .r = 0, .g = 0, .b = 1 } }, .default, .default)).?;
    try testing.expect(indexed != rgb);
}

test "Style.Table intern: a full table returns null and asks for a sweep" {
    var t = try Table.init(testing.allocator);
    defer t.deinit(testing.allocator);
    const n = fill(&t);
    try testing.expectEqual(Table.capacity - 1, n);
    try testing.expectEqual(Table.capacity - 1, t.count());
    try testing.expect(t.sweepDue());
    // Styles already in the table are still found.
    try testing.expectEqual(t.intern(rgbStyle(5)).?, t.intern(rgbStyle(5)).?);
}

test "Style.Table sweep: IDs in use keep their styles and are still found" {
    var t = try Table.init(testing.allocator);
    defer t.deinit(testing.allocator);
    _ = fill(&t);
    var in_use: Table.InUse = .initEmpty();
    const kept = [_]u32{ 0, 7, 9000, Table.capacity - 2 };
    var ids: [kept.len]Style.Id = undefined;
    for (kept, &ids) |n, *id| {
        id.* = t.intern(rgbStyle(n)).?;
        in_use.set(id.*);
    }
    try testing.expectEqual(Table.capacity - 1 - kept.len, t.sweep(&in_use));
    try testing.expectEqual(kept.len, t.count());
    for (kept, ids) |n, id| {
        try testing.expect(t.get(id).eql(rgbStyle(n)));
        try testing.expectEqual(id, t.intern(rgbStyle(n)).?);
    }
}

test "Style.Table sweep: freed IDs are reused, kept IDs never are" {
    var t = try Table.init(testing.allocator);
    defer t.deinit(testing.allocator);
    const n = fill(&t);
    var in_use: Table.InUse = .initEmpty();
    const kept = t.intern(rgbStyle(3)).?;
    in_use.set(kept);
    _ = t.sweep(&in_use);
    // The whole free list can be handed out again, none of it as `kept`.
    var i: u32 = 0;
    while (i < Table.capacity - 2) : (i += 1) {
        const id = t.intern(rgbStyle(n + 1 + i)).?;
        try testing.expect(id != kept);
    }
    try testing.expectEqual(null, t.intern(rgbStyle(n + 1 + i)));
    try testing.expect(t.get(kept).eql(rgbStyle(3)));
}

test "Style.Table sweepDue: after a sweep that freed nothing, waits for more misses" {
    var t = try Table.init(testing.allocator);
    defer t.deinit(testing.allocator);
    const n = fill(&t);
    var all: Table.InUse = .initFull();
    try testing.expectEqual(0, t.sweep(&all));
    try testing.expect(!t.sweepDue());
    var i: u32 = 0;
    while (!t.sweepDue()) : (i += 1) try testing.expectEqual(null, t.intern(rgbStyle(n + 1 + i)));
    try testing.expectEqual(Table.capacity / 8, i);
}

test "Style.Table nearest: picks a close live style and changes nothing" {
    var t = try Table.init(testing.allocator);
    defer t.deinit(testing.allocator);
    const far = t.intern(rgbStyle(0x000000)).?;
    const near = t.intern(rgbStyle(0xF0F0F0)).?;
    const id = t.nearest(rgbStyle(0xFFFFFF));
    try testing.expectEqual(near, id);
    try testing.expect(t.get(far).eql(rgbStyle(0x000000)));
    try testing.expect(t.get(near).eql(rgbStyle(0xF0F0F0)));
    try testing.expectEqual(2, t.count());
}

test "Style.Table nearest: an empty table gives the default style" {
    var t = try Table.init(testing.allocator);
    defer t.deinit(testing.allocator);
    try testing.expectEqual(Table.default_id, t.nearest(rgbStyle(0x123456)));
}

test "Style.Table generation: changes when a style is added, not on a hit or a sweep" {
    var t = try Table.init(testing.allocator);
    defer t.deinit(testing.allocator);
    const g0 = t.generation;
    const id = t.intern(rgbStyle(1)).?;
    const g1 = t.generation;
    try testing.expect(g1 != g0);
    _ = t.intern(rgbStyle(1));
    try testing.expectEqual(g1, t.generation);
    var in_use: Table.InUse = .initEmpty();
    in_use.set(id);
    _ = t.sweep(&in_use);
    try testing.expectEqual(g1, t.generation);
}

test "Style.Table reset: empties the table and hands out IDs from the start" {
    var t = try Table.init(testing.allocator);
    defer t.deinit(testing.allocator);
    const first = t.intern(rgbStyle(1)).?;
    _ = t.intern(rgbStyle(2));
    const g = t.generation;
    t.reset();
    try testing.expectEqual(0, t.count());
    try testing.expect(t.generation != g);
    try testing.expectEqual(first, t.intern(rgbStyle(9)).?);
    try testing.expect(t.get(first).eql(rgbStyle(9)));
}

test "Style.Table requestSweep: a full table that swept for nothing sweeps again at once" {
    var t = try Table.init(testing.allocator);
    defer t.deinit(testing.allocator);
    const n = fill(&t);
    var all: Table.InUse = .initFull();
    _ = t.sweep(&all);
    try testing.expectEqual(null, t.intern(rgbStyle(n + 1)));
    try testing.expect(!t.sweepDue());
    t.requestSweep();
    try testing.expect(t.sweepDue());
}

test "Style.Table reset: a table reset with few or many live styles is empty and reusable" {
    var t = try Table.init(testing.allocator);
    defer t.deinit(testing.allocator);
    for ([_]u32{ 10, Table.capacity / 16 + 50 }) |live| {
        var n: u32 = 0;
        while (n < live) : (n += 1) _ = t.intern(rgbStyle(n)).?;
        t.reset();
        try testing.expectEqual(0, t.count());
        try testing.expect(std.mem.allEqual(Style.Id, t.index, 0));
        // Old styles are not found; new ones start from the first ID.
        try testing.expectEqual(@as(Style.Id, 1), t.intern(rgbStyle(7)).?);
        t.reset();
    }
}
