const std = @import("std");
const testing = std.testing;

const Theme = @import("Theme.zig");
const button_group = @import("button_group.zig");
const icons = @import("icons.zig");
const text = @import("text.zig");
const Tree = @import("Tree.zig");

test "button_group: opens clipped group inside focus ring and styles segments" {
    var nodes: [16]Tree.Node = undefined;
    var lines: [4]text.Line = undefined;
    var tree = Tree.init(&nodes, &lines);

    const frame = try button_group.open(&tree, &Theme.dark, .{
        .focused = true,
    });
    try button_group.iconSegment(&tree, &Theme.dark, icons.sun, .{
        .id = .of("seg.0"),
        .selected = true,
    });
    try button_group.separator(&tree, &Theme.dark);
    try button_group.iconSegment(&tree, &Theme.dark, icons.moon, .{
        .id = .of("seg.1"),
        .hovered = true,
    });
    try button_group.separator(&tree, &Theme.dark);
    try button_group.textSegment(&tree, &Theme.dark, "Auto", .{
        .id = .of("seg.2"),
    });
    button_group.close(&tree, frame);

    try testing.expectEqual(Tree.Overflow.clip, tree.nodes[frame.group].box.overflow);
    try testing.expectEqual(@as(u8, Theme.radius_md), tree.nodes[frame.group].box.radius);
    try testing.expectEqual(Theme.dark.accent, tree.find(.of("seg.0")).?.box.fill);
    try testing.expectEqual(Theme.dark.muted, tree.find(.of("seg.1")).?.box.fill);
    try testing.expectEqual(Theme.Color.transparent, tree.find(.of("seg.2")).?.box.fill);
}
