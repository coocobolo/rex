const std = @import("std");
const testing = std.testing;

const Theme = @import("Theme.zig");
const separator = @import("separator.zig");
const text = @import("text.zig");
const Tree = @import("Tree.zig");

fn measure(_: *anyopaque, bytes: []const u8, _: text.Style, _: text.Figures) f32 {
    return @floatFromInt(bytes.len * 8);
}

var no_state: u8 = 0;
const measurer: text.Measurer = .{ .context = &no_state, .widthFn = measure };

test "separator: horizontal and vertical rules keep 1px thickness under squeeze" {
    var nodes: [16]Tree.Node = undefined;
    var lines: [4]text.Line = undefined;
    var tree = Tree.init(&nodes, &lines);
    const theme = &Theme.dark;

    const col = try tree.open(.{ .width = .{ .fixed = 120 }, .height = .{ .fixed = 20 } });
    _ = try tree.leaf(.{ .width = .fill, .height = .{ .fixed = 18 } });
    try separator.horizontal(&tree, theme);
    _ = try tree.leaf(.{ .width = .fill, .height = .{ .fixed = 18 } });
    tree.close(col);

    const row = try tree.open(.{ .axis = .row, .width = .{ .fixed = 20 }, .height = .{ .fixed = 32 } });
    _ = try tree.leaf(.{ .width = .{ .fixed = 18 }, .height = .fill });
    try separator.vertical(&tree, theme);
    _ = try tree.leaf(.{ .width = .{ .fixed = 18 }, .height = .fill });
    tree.close(row);

    try tree.layout(measurer, 200, 200);

    // Horizontal separator is node 2; vertical separator is node 6.
    try testing.expectEqual(@as(f32, 120), tree.nodes[2].rect.w);
    try testing.expectEqual(@as(f32, 1), tree.nodes[2].rect.h);
    try testing.expectEqual(theme.border, tree.nodes[2].box.fill);
    try testing.expect(!tree.nodes[2].box.shrink);

    try testing.expectEqual(@as(f32, 1), tree.nodes[6].rect.w);
    try testing.expectEqual(@as(f32, 32), tree.nodes[6].rect.h);
    try testing.expect(!tree.nodes[6].box.shrink);
}
