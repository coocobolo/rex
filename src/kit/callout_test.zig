const std = @import("std");
const testing = std.testing;

const Theme = @import("Theme.zig");
const callout = @import("callout.zig");
const icons = @import("icons.zig");
const text = @import("text.zig");
const Tree = @import("Tree.zig");

const byte_width = 7;

fn fixedWidth(_: *anyopaque, bytes: []const u8, _: text.Style, _: text.Figures) f32 {
    return @floatFromInt(bytes.len * byte_width);
}

var no_state: u8 = 0;
const measurer: text.Measurer = .{ .context = &no_state, .widthFn = fixedWidth };

const Fixture = struct {
    nodes: [32]Tree.Node = undefined,
    lines: [callout.line_max]text.Line = undefined,

    fn tree(self: *Fixture) Tree {
        return .init(&self.nodes, &self.lines);
    }
};

fn show(fixture: *Fixture, theme: *const Theme, variant: callout.Variant, icon: u21, with_description: bool) !Tree {
    var tree = fixture.tree();
    const frame = try callout.view(&tree, theme, .{ .variant = variant, .icon = icon });
    try callout.title(&tree, theme, frame, "Config error");
    if (with_description) try callout.description(&tree, theme, frame, "the file could not be written");
    callout.close(&tree, frame);
    try tree.layout(measurer, 400, 200);
    return tree;
}

test "callout: Options and Frame keep their measured sizes" {
    try testing.expectEqual(20, @sizeOf(callout.Options));
    try testing.expectEqual(6, @sizeOf(callout.Frame));
}

test "callout: the default variant uses a card, an info icon and a foreground title" {
    var fixture: Fixture = .{};
    const tree = try show(&fixture, &Theme.dark, .default, icons.info, true);

    try testing.expectEqual(callout.node_max, tree.len);
    try testing.expectEqual(Theme.dark.card, tree.nodes[0].box.fill);
    try testing.expectEqual(Theme.dark.border, tree.nodes[0].box.border);
    try testing.expectEqual(icons.info, tree.nodes[2].content.icon.codepoint);
    try testing.expectEqual(Theme.dark.foreground, tree.nodes[2].content.icon.color);
    try testing.expectEqual(Theme.dark.foreground, tree.nodes[4].content.text.color);
    try testing.expectEqual(Theme.dark.muted_foreground, tree.nodes[5].content.text.color);
}

test "callout: the destructive variant uses the error icon and destructive colors" {
    var fixture: Fixture = .{};
    const tree = try show(&fixture, &Theme.light, .destructive, icons.circle_x, true);

    try testing.expectEqual(Theme.light.border, tree.nodes[0].box.border);
    try testing.expectEqual(icons.circle_x, tree.nodes[2].content.icon.codepoint);
    try testing.expectEqual(Theme.light.destructive, tree.nodes[2].content.icon.color);
    try testing.expectEqual(Theme.light.destructive, tree.nodes[4].content.text.color);
    try testing.expectEqual(Theme.light.destructive.alpha(90), tree.nodes[5].content.text.color);
}

test "callout: the description sits below the title" {
    var fixture: Fixture = .{};
    const tree = try show(&fixture, &Theme.dark, .default, icons.info, true);

    try testing.expect(tree.nodes[5].rect.y >= tree.nodes[4].rect.y + tree.nodes[4].rect.h);
}

test "callout: omitting the icon leaves four nodes" {
    var fixture: Fixture = .{};
    var tree = fixture.tree();
    const frame = try callout.view(&tree, &Theme.dark, .{ .icon = icons.none });
    try callout.title(&tree, &Theme.dark, frame, "Saved");
    try callout.description(&tree, &Theme.dark, frame, "the file is unchanged");
    callout.close(&tree, frame);

    try testing.expectEqual(4, tree.len);
}

test "callout: close restores the tree so a sibling can be written" {
    var fixture: Fixture = .{};
    var tree = fixture.tree();
    const frame = try callout.view(&tree, &Theme.dark, .{});
    try callout.title(&tree, &Theme.dark, frame, "Saved");
    callout.close(&tree, frame);
    const sibling = try tree.open(.{ .width = .fill });
    tree.close(sibling);

    try testing.expectEqual(tree.nodes[0].parent, tree.nodes[sibling].parent);
}
