const std = @import("std");
const testing = std.testing;

const Theme = @import("Theme.zig");
const collapsible = @import("collapsible.zig");
const icons = @import("icons.zig");
const text = @import("text.zig");
const Tree = @import("Tree.zig");

fn measure(_: *anyopaque, bytes: []const u8, _: text.Style, _: text.Figures) f32 {
    return @floatFromInt(bytes.len * 8);
}

var no_state: u8 = 0;
const measurer: text.Measurer = .{ .context = &no_state, .widthFn = measure };

test "collapsible: collapsed state shows right chevron and omits content" {
    var nodes: [32]Tree.Node = undefined;
    var lines: [16]text.Line = undefined;
    var tree = Tree.init(&nodes, &lines);
    const theme = &Theme.dark;

    const c = try collapsible.open(&tree, theme, .{});
    const trig = try collapsible.openTrigger(&tree, theme, .{
        .id = .of("toggle"),
        .title = "ANSI Palette",
        .description = "Terminal palette colors 0-15",
        .badge = "2 overridden",
        .open = false,
        .focused = true,
    });
    try collapsible.closeTrigger(&tree, theme, trig);
    collapsible.close(&tree, c);

    try testing.expect(tree.len <= collapsible.node_max);
    try tree.layout(measurer, 500, 300);

    try testing.expect(tree.find(.of("toggle")) != null);
    var saw_right = false;
    for (tree.items()) |node| {
        if (node.content == .icon and node.content.icon.codepoint == icons.chevron_right) {
            saw_right = true;
        }
    }
    try testing.expect(saw_right);
}

test "collapsible: open state shows down chevron, divider, and body content" {
    var nodes: [32]Tree.Node = undefined;
    var lines: [16]text.Line = undefined;
    var tree = Tree.init(&nodes, &lines);
    const theme = &Theme.dark;

    const c = try collapsible.open(&tree, theme, .{});
    const trig = try collapsible.openTrigger(&tree, theme, .{
        .id = .of("toggle"),
        .title = "ANSI Palette",
        .open = true,
    });
    try collapsible.closeTrigger(&tree, theme, trig);
    const body = try collapsible.openContent(&tree, theme, .{});
    _ = try tree.leaf(.{ .id = .of("body_child"), .width = .fill, .height = .{ .fixed = 32 } });
    collapsible.closeContent(&tree, body);
    collapsible.close(&tree, c);

    try tree.layout(measurer, 500, 300);

    var saw_down = false;
    for (tree.items()) |node| {
        if (node.content == .icon and node.content.icon.codepoint == icons.chevron_down) {
            saw_down = true;
        }
    }
    try testing.expect(saw_down);
    try testing.expect(tree.find(.of("body_child")) != null);
}
