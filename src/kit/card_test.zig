const std = @import("std");
const testing = std.testing;

const Theme = @import("Theme.zig");
const card = @import("card.zig");
const text = @import("text.zig");
const Tree = @import("Tree.zig");

fn measure(_: *anyopaque, bytes: []const u8, _: text.Style, _: text.Figures) f32 {
    return @floatFromInt(bytes.len * 8);
}

var no_state: u8 = 0;
const measurer: text.Measurer = .{ .context = &no_state, .widthFn = measure };

test "card: composes header, title, description, action, content, and footer" {
    var nodes: [32]Tree.Node = undefined;
    var lines: [16]text.Line = undefined;
    var tree = Tree.init(&nodes, &lines);
    const theme = &Theme.dark;

    const c = try card.open(&tree, theme, .{
        .id = .of("card"),
        .width = .{ .fixed = 300 },
    });
    const head = try card.openHeader(&tree, .{ .axis = .row, .cross = .center });
    const titles = try tree.open(.{ .width = .fill, .gap = 4 });
    try card.title(&tree, theme, "This week", .{});
    try card.description(&tree, theme, "Daily screen and focus totals", .{});
    tree.close(titles);
    const action = try card.openAction(&tree);
    _ = try tree.leaf(.{ .width = .{ .fixed = 24 }, .height = .{ .fixed = 24 } });
    tree.close(action);
    tree.close(head);

    const content = try card.openContent(&tree, .{});
    _ = try tree.leaf(.{ .width = .fill, .height = .{ .fixed = 80 } });
    tree.close(content);

    const foot = try card.openFooter(&tree, .{ .axis = .row });
    _ = try tree.text("Updated just now", .{ .color = theme.muted_foreground, .style = .xs });
    tree.close(foot);
    card.close(&tree, c);

    try tree.layout(measurer, 400, 400);

    const root = tree.find(.of("card")).?;
    try testing.expectEqual(theme.card, root.box.fill);
    try testing.expectEqual(theme.border, root.box.border);
    try testing.expectEqual(@as(u8, Theme.border_width), root.box.border_width);
    try testing.expectEqual(@as(f32, 300), root.rect.w);
    try testing.expect(root.rect.h > 80);
}
