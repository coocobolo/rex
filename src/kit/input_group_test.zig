const std = @import("std");
const testing = std.testing;

const Theme = @import("Theme.zig");
const input_group = @import("input_group.zig");
const text = @import("text.zig");
const Tree = @import("Tree.zig");

test "input_group: combines borderless input, separators, and addon buttons" {
    var nodes: [24]Tree.Node = undefined;
    var lines: [8]text.Line = undefined;
    var tree = Tree.init(&nodes, &lines);

    const frame = try input_group.open(&tree, &Theme.dark, .{
        .width = .{ .fixed = 240 },
        .focused = true,
        .invalid = true,
    });
    try input_group.addonButton(&tree, &Theme.dark, .{
        .id = .of("dec"),
        .label = "−",
        .disabled = true,
    });
    try input_group.separator(&tree, &Theme.dark);
    try input_group.textInput(&tree, &Theme.dark, .{
        .id = .of("inp"),
        .value = "12",
        .width = .fill,
        .focused = true,
        .invalid = true,
        .center = true,
    });
    try input_group.separator(&tree, &Theme.dark);
    try input_group.addonButton(&tree, &Theme.dark, .{
        .id = .of("inc"),
        .label = "+",
        .hovered = true,
    });
    input_group.close(&tree, frame);

    try testing.expectEqual(Tree.Overflow.clip, tree.nodes[frame.group].box.overflow);
    try testing.expectEqual(Theme.dark.destructive, tree.nodes[frame.group].box.border);
    try testing.expectEqual(Tree.PointerShape.arrow, tree.find(.of("dec")).?.box.pointer);
    try testing.expectEqual(Theme.dark.accent, tree.find(.of("inc")).?.box.fill);
}
