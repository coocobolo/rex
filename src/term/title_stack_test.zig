const std = @import("std");
const testing = std.testing;

const TitleStack = @import("TitleStack.zig");

test "TitleStack: pops in reverse order, then nothing" {
    var stack: TitleStack = .{};
    try testing.expectEqual(null, stack.pop(.both));
    stack.push(.both, "one", "icon one");
    stack.push(.both, "two", "icon two");

    const two = stack.pop(.both).?;
    try testing.expectEqualStrings("two", two.title.?);
    try testing.expectEqualStrings("icon two", two.icon_name.?);
    const one = stack.pop(.both).?;
    try testing.expectEqualStrings("one", one.title.?);
    try testing.expectEqualStrings("icon one", one.icon_name.?);
    try testing.expectEqual(null, stack.pop(.both));
}

test "TitleStack: each part is pushed and popped on its own" {
    var stack: TitleStack = .{};
    stack.push(.title, "vim", "ignored");
    const popped = stack.pop(.both).?;
    try testing.expectEqualStrings("vim", popped.title.?);
    try testing.expectEqual(null, popped.icon_name); // never pushed

    stack.push(.both, "t", "i");
    const icon_only = stack.pop(.icon_name).?;
    try testing.expectEqual(null, icon_only.title); // not asked for
    try testing.expectEqualStrings("i", icon_only.icon_name.?);
}

test "TitleStack: a missing part comes from the nearest older entry" {
    var stack: TitleStack = .{};
    stack.push(.both, "old title", "old icon");
    stack.push(.icon_name, "", "new icon");
    const popped = stack.pop(.both).?;
    try testing.expectEqualStrings("old title", popped.title.?);
    try testing.expectEqualStrings("new icon", popped.icon_name.?);
}

test "TitleStack: an empty title is a value, not a missing part" {
    var stack: TitleStack = .{};
    stack.push(.both, "old", "old");
    stack.push(.both, "", "");
    const popped = stack.pop(.both).?;
    try testing.expectEqualStrings("", popped.title.?);
    try testing.expectEqualStrings("", popped.icon_name.?);
}

test "TitleStack: a push onto a full stack overwrites the oldest" {
    var stack: TitleStack = .{};
    var buf: [8]u8 = undefined;
    for (0..TitleStack.depth + 2) |i| {
        const title = try std.fmt.bufPrint(&buf, "t{d}", .{i});
        stack.push(.both, title, title);
    }
    // t11 down to t2: t0 and t1 were overwritten.
    var i: usize = TitleStack.depth + 2;
    while (i > 2) {
        i -= 1;
        const want = try std.fmt.bufPrint(&buf, "t{d}", .{i});
        try testing.expectEqualStrings(want, stack.pop(.both).?.title.?);
    }
    try testing.expectEqual(null, stack.pop(.both));
}

test "TitleStack: holds titles of the longest length" {
    var stack: TitleStack = .{};
    const long = "x" ** TitleStack.max_len;
    stack.push(.both, long, long);
    try testing.expectEqualStrings(long, stack.pop(.title).?.title.?);
}
