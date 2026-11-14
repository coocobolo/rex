const std = @import("std");
const testing = std.testing;

const Theme = @import("Theme.zig");
const icons = @import("icons.zig");
const text = @import("text.zig");
const tree_zig = @import("tree.zig");
const checkbox = @import("checkbox.zig");

const Tree = tree_zig.Tree;
const Id = tree_zig.Id;

test "checkbox: checked emits check icon; unchecked omits it" {
    var nodes: [checkbox.node_max]tree_zig.Node = undefined;
    var lines: [4]text.Line = undefined;

    var unchecked = Tree.init(&nodes, &lines);
    try checkbox.view(&unchecked, &Theme.dark, .{ .id = Id.of("cb"), .label = "Enable" });
    try testing.expectEqual(@as(usize, 4), unchecked.len);
    try testing.expectEqual(Theme.dark.input, unchecked.nodes[2].box.border);

    var checked = Tree.init(&nodes, &lines);
    try checkbox.view(&checked, &Theme.dark, .{ .id = Id.of("cb"), .checked = true, .label = "Enable" });
    try testing.expectEqual(@as(usize, checkbox.node_max), checked.len);
    try testing.expectEqual(Theme.dark.primary, checked.nodes[2].box.fill);
    try testing.expectEqual(icons.check, checked.nodes[3].content.icon.codepoint);
}

test "checkbox: standalone without label" {
    var nodes: [checkbox.node_max]tree_zig.Node = undefined;
    var lines: [4]text.Line = undefined;
    var tree = Tree.init(&nodes, &lines);
    try checkbox.view(&tree, &Theme.dark, .{ .id = Id.of("cb") });
    try testing.expectEqual(@as(usize, 3), tree.len);
}
