const std = @import("std");
const testing = std.testing;

const Theme = @import("Theme.zig");
const text = @import("text.zig");
const tree_zig = @import("tree.zig");
const toggle = @import("toggle.zig");

test "Toggle: pressed and unpressed views stay within node_max" {
    var nodes: [32]tree_zig.Node = undefined;
    var lines: [16]text.Line = undefined;
    const theme = Theme.dark;

    var t1: tree_zig.Tree = .init(&nodes, &lines);
    try toggle.view(&t1, &theme, .{
        .id = tree_zig.Id.of("flag1"),
        .label = "Grayscale screen",
        .pressed = true,
        .focused = true,
    });
    try testing.expectEqual(@as(usize, 4), t1.len);
    try testing.expect(t1.len <= toggle.node_max);

    var t0: tree_zig.Tree = .init(&nodes, &lines);
    try toggle.view(&t0, &theme, .{
        .id = tree_zig.Id.of("flag2"),
        .label = "Lock input",
        .pressed = false,
    });
    try testing.expectEqual(@as(usize, 3), t0.len);
}
