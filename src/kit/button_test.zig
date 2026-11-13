const std = @import("std");
const testing = std.testing;

const Theme = @import("Theme.zig");
const button = @import("button.zig");
const kbd = @import("kbd.zig");
const text = @import("text.zig");
const tree_zig = @import("tree.zig");
const Tree = tree_zig.Tree;
const Id = tree_zig.Id;
const layout = @import("layout.zig").layout;

const byte_width = 7;

fn fixedWidth(_: *anyopaque, bytes: []const u8, _: text.Style) f32 {
    return @floatFromInt(bytes.len * byte_width);
}

/// `fixedWidth` keeps no state.
var no_state: u8 = 0;
const measurer: text.Measurer = .{ .context = &no_state, .widthFn = fixedWidth };

const Fixture = struct {
    nodes: [32]tree_zig.Node = undefined,
    lines: [16]text.Line = undefined,

    fn tree(self: *Fixture) Tree {
        return .init(&self.nodes, &self.lines);
    }
};

const id = Id.of("test.button");

/// One button alone in a tree: node 0 is its ring slot, 1 its face and 2
/// its label.
fn one(fixture: *Fixture, theme: *const Theme, options: button.Options) !Tree {
    var tree = fixture.tree();
    try button.view(&tree, theme, options);
    try layout(&tree, measurer, 400, 200);
    return tree;
}

test "button: each variant has its fill, border and label color" {
    const theme = &Theme.dark;
    const Case = struct { variant: button.Variant, fill: Theme.Color, border: Theme.Color, label: Theme.Color };
    const cases = [_]Case{
        .{ .variant = .outline, .fill = .transparent, .border = theme.input, .label = theme.foreground },
        .{ .variant = .primary, .fill = theme.primary, .border = .transparent, .label = theme.primary_foreground },
        .{ .variant = .ghost, .fill = .transparent, .border = .transparent, .label = theme.foreground },
        .{ .variant = .destructive, .fill = theme.destructive, .border = .transparent, .label = theme.destructive_foreground },
    };
    for (cases) |case| {
        var fixture: Fixture = .{};
        const tree = try one(&fixture, theme, .{ .id = id, .label = "Save", .variant = case.variant });
        try testing.expectEqual(case.fill, tree.nodes[1].box.fill);
        try testing.expectEqual(case.border, tree.nodes[1].box.border);
        try testing.expectEqual(case.label, tree.nodes[2].content.text.color);
        // No ring without the focus.
        try testing.expectEqual(0, tree.nodes[0].box.border.a);
    }
}

test "button: hover and press change the fill" {
    const theme = &Theme.light;
    const Case = struct { variant: button.Variant, hovered: Theme.Color, pressed: Theme.Color };
    const cases = [_]Case{
        .{ .variant = .outline, .hovered = theme.accent, .pressed = theme.accent },
        .{ .variant = .ghost, .hovered = theme.accent, .pressed = theme.accent },
        .{ .variant = .primary, .hovered = theme.primary.alpha(90), .pressed = theme.primary.alpha(80) },
        .{ .variant = .destructive, .hovered = theme.destructive.alpha(90), .pressed = theme.destructive.alpha(80) },
    };
    for (cases) |case| {
        var fixture: Fixture = .{};
        var tree = try one(&fixture, theme, .{ .id = id, .label = "Save", .variant = case.variant, .state = .hovered });
        try testing.expectEqual(case.hovered, tree.nodes[1].box.fill);
        tree = try one(&fixture, theme, .{ .id = id, .label = "Save", .variant = case.variant, .state = .pressed });
        try testing.expectEqual(case.pressed, tree.nodes[1].box.fill);
    }
}

test "button: a disabled button is drawn at half opacity" {
    const theme = &Theme.dark;
    var fixture: Fixture = .{};
    const tree = try one(&fixture, theme, .{ .id = id, .label = "Save", .variant = .primary, .state = .disabled });
    try testing.expectEqual(theme.primary.fade(0.5), tree.nodes[1].box.fill);
    try testing.expectEqual(theme.primary_foreground.fade(0.5), tree.nodes[2].content.text.color);
}

test "button: the focus ring surrounds the face without moving it, and carries the id" {
    const theme = &Theme.dark;
    var fixture: Fixture = .{};
    var tree = try one(&fixture, theme, .{ .id = id, .label = "Save" });
    const face = tree.nodes[1].rect;
    try testing.expectEqual(tree_zig.Rect{ .x = Theme.ring_width, .y = Theme.ring_width, .w = 2 * 16 + 4 * byte_width, .h = Theme.control }, face);

    tree = try one(&fixture, theme, .{ .id = id, .label = "Save", .focused = true });
    try testing.expectEqual(face, tree.nodes[1].rect);
    try testing.expectEqual(theme.ring.alpha(Theme.ring_opacity), tree.nodes[0].box.border);
    try testing.expectEqual(theme.ring, tree.nodes[1].box.border);
    try testing.expectEqual(id, tree.hitTest(1, 1));
    try testing.expectEqual(id, tree.hitTest(face.x + 4, face.y + 4));
}

test "button: the small size is lower and narrower" {
    var fixture: Fixture = .{};
    const tree = try one(&fixture, &Theme.dark, .{ .id = id, .label = "Open", .size = .sm });
    try testing.expectEqual(Theme.control_sm, tree.nodes[1].rect.h);
    try testing.expectEqual(2 * 12 + 4 * byte_width, tree.nodes[1].rect.w);
}

test "button: a key cap follows the label, and the node count holds" {
    var fixture: Fixture = .{};
    const tree = try one(&fixture, &Theme.dark, .{ .id = id, .label = "Cancel", .key_cap = "Esc" });
    try testing.expectEqual(button.node_max, tree.len);
    const label = tree.nodes[2].rect;
    const cap = tree.nodes[3].rect;
    try testing.expectEqual(label.x + label.w + button.gap, cap.x);
    try testing.expectEqual(Theme.dark.muted, tree.nodes[3].box.fill);
}

test "kbd: a group is its caps in a row" {
    var fixture: Fixture = .{};
    var tree = fixture.tree();
    const keys = [_][]const u8{ "Ctrl", "Shift", "P" };
    try kbd.group(&tree, &Theme.dark, &keys, 1);
    try layout(&tree, measurer, 400, 200);

    try testing.expectEqual(kbd.groupNodes(keys.len), tree.len);
    // Caps are nodes 1, 3 and 5; each is its text plus 6 px on both sides.
    const ctrl = tree.nodes[1].rect;
    const shift = tree.nodes[3].rect;
    const p = tree.nodes[5].rect;
    try testing.expectEqual(4 * byte_width + 12, ctrl.w);
    try testing.expectEqual(ctrl.x + ctrl.w + kbd.gap, shift.x);
    try testing.expectEqual(shift.x + shift.w + kbd.gap, p.x);
    try testing.expectEqual(ctrl.y, p.y);
    try testing.expectEqual("Shift", tree.nodes[4].content.text.bytes);
}
