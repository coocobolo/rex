const std = @import("std");
const testing = std.testing;

const Id = @import("tree.zig").Id;
const memory = @import("memory.zig");

test "Table: a value is kept while its id is written each frame" {
    var table: memory.Table = .empty;
    const a = Id.of("a");
    const b = Id.of("b");
    try testing.expectEqual(null, table.get(a));

    try table.set(a, 10);
    try table.set(b, 20);
    table.sweep();
    try testing.expectEqual(10, table.get(a));
    try testing.expectEqual(20, table.get(b));

    // Only b is in the next frame's view.
    try table.set(b, 21);
    table.sweep();
    try testing.expectEqual(null, table.get(a));
    try testing.expectEqual(21, table.get(b));
    try testing.expectEqual(1, table.len);

    table.sweep();
    try testing.expectEqual(0, table.len);
}

test "Table: a full table is an error, and writing a known id is not" {
    var table: memory.Table = .empty;
    const list = Id.of("list");
    for (0..memory.capacity) |index| try table.set(list.item(@intCast(index)), 0);
    try testing.expectError(error.OutOfSlots, table.set(Id.of("one more"), 0));
    try table.set(list.item(3), 7);
    try testing.expectEqual(7, table.get(list.item(3)));
}
