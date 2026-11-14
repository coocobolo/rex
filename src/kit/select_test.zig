const std = @import("std");
const testing = std.testing;

const Theme = @import("Theme.zig");
const icons = @import("icons.zig");
const text = @import("text.zig");
const tree_zig = @import("tree.zig");
const select = @import("select.zig");

const Tree = tree_zig.Tree;
const Id = tree_zig.Id;

test "select: trigger writes value and chevron; list opens anchored popup" {
    const choices = [_][]const u8{ "Dark", "Light", "Auto" };
    var nodes: [select.trigger_node_max + select.list_node_max + choices.len * select.item_node_max]tree_zig.Node = undefined;
    var lines: [8]text.Line = undefined;
    var tree = Tree.init(&nodes, &lines);

    const trigger_id = Id.of("sel.trigger");
    try select.trigger(&tree, &Theme.dark, .{
        .id = trigger_id,
        .value = choices[0],
        .open = true,
        .focused = true,
    });
    try testing.expectEqual(@as(usize, select.trigger_node_max), tree.len);
    try testing.expectEqual(Theme.dark.accent, tree.nodes[1].box.fill);
    try testing.expectEqual(icons.chevron_down, tree.nodes[3].content.icon.codepoint);

    const card = try select.openList(&tree, &Theme.dark, .{
        .layer_id = Id.of("sel.layer"),
        .anchor = trigger_id,
    });
    for (choices, 0..) |label, i| {
        try select.item(&tree, &Theme.dark, .{
            .id = Id.of("sel.item").item(@intCast(i)),
            .label = label,
            .highlighted = i == 1,
            .selected = i == 0,
        });
    }
    select.closeList(&tree, card);
    try testing.expect(tree.len <= nodes.len);
}
