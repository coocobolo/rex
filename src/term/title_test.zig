const std = @import("std");
const testing = std.testing;

const Title = @import("Title.zig");

fn expectTitle(title: *const Title, want_title: []const u8, want_icon_name: []const u8) !void {
    try testing.expectEqualStrings(want_title, title.get());
    try testing.expectEqualStrings(want_icon_name, title.getIconName());
}

fn setBoth(title: *Title, text: []const u8, icon_name: []const u8) void {
    title.set(text);
    title.setIconName(icon_name);
}

test "Title: starts empty, and reset empties the texts but keeps the stack" {
    var title: Title = .{};
    try expectTitle(&title, "", "");

    setBoth(&title, "saved", "saved icon");
    title.push(.both);
    setBoth(&title, "current", "current icon");
    title.reset();
    try expectTitle(&title, "", "");

    try testing.expectEqual(Title.Restored{ .title = true, .icon_name = true }, title.pop(.both));
    try expectTitle(&title, "saved", "saved icon");
}

test "Title: a text over max_len is cut on a UTF-8 boundary" {
    var title: Title = .{};
    const head = "A" ** (Title.max_len - 2);
    title.set(head ++ "\u{4e16}");
    try testing.expectEqualStrings(head, title.get());
    title.setIconName(head ++ "\u{e9}" ++ "B");
    try testing.expectEqualStrings(head ++ "\u{e9}", title.getIconName());
}

test "Title: pops in reverse order, then nothing" {
    var title: Title = .{};
    try testing.expectEqual(Title.Restored{}, title.pop(.both));
    setBoth(&title, "one", "icon one");
    title.push(.both);
    setBoth(&title, "two", "icon two");
    title.push(.both);
    setBoth(&title, "three", "icon three");

    _ = title.pop(.both);
    try expectTitle(&title, "two", "icon two");
    _ = title.pop(.both);
    try expectTitle(&title, "one", "icon one");
    try testing.expectEqual(Title.Restored{}, title.pop(.both));
    try expectTitle(&title, "one", "icon one");
}

test "Title: each part is pushed and popped on its own" {
    var title: Title = .{};
    setBoth(&title, "vim", "ignored");
    title.push(.title);
    setBoth(&title, "now", "now icon");
    // The icon name was never pushed.
    try testing.expectEqual(Title.Restored{ .title = true }, title.pop(.both));
    try expectTitle(&title, "vim", "now icon");

    setBoth(&title, "t", "i");
    title.push(.both);
    setBoth(&title, "now", "now icon");
    // The title was not asked for.
    try testing.expectEqual(Title.Restored{ .icon_name = true }, title.pop(.icon_name));
    try expectTitle(&title, "now", "i");
}

test "Title: a missing part comes from the nearest older entry" {
    var title: Title = .{};
    setBoth(&title, "old title", "old icon");
    title.push(.both);
    setBoth(&title, "", "new icon");
    title.push(.icon_name);
    setBoth(&title, "now", "now icon");
    try testing.expectEqual(Title.Restored{ .title = true, .icon_name = true }, title.pop(.both));
    try expectTitle(&title, "old title", "new icon");
}

test "Title: an empty title is a value, not a missing part" {
    var title: Title = .{};
    setBoth(&title, "old", "old");
    title.push(.both);
    setBoth(&title, "", "");
    title.push(.both);
    setBoth(&title, "now", "now");
    try testing.expectEqual(Title.Restored{ .title = true, .icon_name = true }, title.pop(.both));
    try expectTitle(&title, "", "");
}

test "Title: a push onto a full stack overwrites the oldest" {
    var title: Title = .{};
    var buf: [8]u8 = undefined;
    for (0..Title.depth + 2) |i| {
        title.set(try std.fmt.bufPrint(&buf, "t{d}", .{i}));
        title.push(.both);
    }
    // t11 down to t2: t0 and t1 were overwritten.
    var i: usize = Title.depth + 2;
    while (i > 2) {
        i -= 1;
        try testing.expect(title.pop(.both).title);
        try testing.expectEqualStrings(try std.fmt.bufPrint(&buf, "t{d}", .{i}), title.get());
    }
    try testing.expectEqual(Title.Restored{}, title.pop(.both));
}

test "Title: holds titles of the longest length" {
    var title: Title = .{};
    const long = "x" ** Title.max_len;
    setBoth(&title, long, long);
    title.push(.both);
    setBoth(&title, "", "");
    try testing.expect(title.pop(.title).title);
    try testing.expectEqualStrings(long, title.get());
}
