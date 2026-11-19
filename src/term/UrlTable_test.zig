//! Tests for the per-screen OSC 8 URI table (ADR 0012).

const std = @import("std");
const testing = std.testing;
const UrlTable = @import("UrlTable.zig");

test "UrlTable: fixed layout per screen" {
    try testing.expectEqual(@as(usize, 16400), @sizeOf(UrlTable));
    try testing.expectEqual(@as(usize, 8), @alignOf(UrlTable));
}

test "UrlTable: identical URIs share an ID, 0 means no link" {
    var table: UrlTable = .init(testing.allocator);
    defer table.deinit();

    try testing.expectEqual(null, table.get(0));
    const a = table.intern("https://example.com").?;
    const b = table.intern("https://example.com").?;
    try testing.expectEqual(a, b);
    try testing.expectEqualStrings("https://example.com", table.get(a).?);
    try testing.expectEqual(null, table.get(a + 100));
}

test "UrlTable: oversized URIs are dropped whole, never truncated" {
    var table: UrlTable = .init(testing.allocator);
    defer table.deinit();

    const long = "u" ** (UrlTable.max_len + 1);
    try testing.expectEqual(null, table.intern(long));
    try testing.expectEqual(null, table.intern(""));
}

test "UrlTable: sweep frees unreferenced URIs and keeps the rest" {
    var table: UrlTable = .init(testing.allocator);
    defer table.deinit();

    const kept = table.intern("https://kept.example").?;
    const dropped = table.intern("https://dropped.example").?;
    var in_use: UrlTable.InUse = .initEmpty();
    in_use.set(kept);
    table.sweep(&in_use);
    try testing.expectEqualStrings("https://kept.example", table.get(kept).?);
    try testing.expectEqual(null, table.get(dropped));
    // The freed ID is reusable.
    const reused = table.intern("https://new.example").?;
    try testing.expectEqual(dropped, reused);
}

test "UrlTable: reset clears every URI and keeps the table usable" {
    var table: UrlTable = .init(testing.allocator);
    defer table.deinit();

    const id = table.intern("https://example.com").?;
    table.reset();
    try testing.expectEqual(null, table.get(id));
    try testing.expect(table.intern("https://example.org") != null);
}
