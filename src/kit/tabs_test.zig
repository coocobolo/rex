const std = @import("std");
const testing = std.testing;

const Theme = @import("Theme.zig");
const tabs = @import("tabs.zig");
const text = @import("text.zig");
const tree_zig = @import("tree.zig");
const Tree = tree_zig.Tree;
const Id = tree_zig.Id;
const layout = @import("layout.zig").layout;

const byte_width = 7;

fn fixedWidth(_: *anyopaque, bytes: []const u8, _: text.Style, _: text.Figures) f32 {
    return @floatFromInt(bytes.len * byte_width);
}

var no_state: u8 = 0;
const measurer: text.Measurer = .{ .context = &no_state, .widthFn = fixedWidth };

const today = Id.of("test.today");
const focus = Id.of("test.focus");
const history = Id.of("test.history");

const labels = [_]tabs.Tab{
    .{ .id = today, .label = "Today" },
    .{ .id = focus, .label = "Focus" },
    .{ .id = history, .label = "History" },
};

const Fixture = struct {
    nodes: [16]tree_zig.Node = undefined,
    lines: [8]text.Line = undefined,

    fn tree(self: *Fixture) Tree {
        return .init(&self.nodes, &self.lines);
    }
};

fn show(fixture: *Fixture, theme: *const Theme, options: tabs.Options) !Tree {
    var tree = fixture.tree();
    try tabs.view(&tree, theme, options);
    try layout(&tree, measurer, 400, 200);
    return tree;
}

fn face(tree: *const Tree, index: usize) *const tree_zig.Node {
    return &tree.nodes[1 + index * 2];
}

fn label(tree: *const Tree, index: usize) *const tree_zig.Node {
    return &tree.nodes[2 + index * 2];
}

test "tabs: the track is 32 tall and each face sits in the 3 px inset" {
    var fixture: Fixture = .{};
    const tree = try show(&fixture, &Theme.dark, .{ .tabs = &labels, .current = 0 });

    try testing.expectEqual(tabs.nodeMax(labels.len), tree.len);
    const track = tree.nodes[0];
    try testing.expectEqual(Theme.control_sm, track.rect.h);
    try testing.expectEqual(Theme.dark.muted, track.box.fill);
    try testing.expectEqual(Theme.radius, track.box.radius);

    const first = face(&tree, 0).rect;
    const second = face(&tree, 1).rect;
    const width = tabs.pad * 2 + 5 * byte_width;
    try testing.expectEqual(tree_zig.Rect{
        .x = tabs.inset,
        .y = tabs.inset,
        .w = width,
        .h = tabs.face_height,
    }, first);
    try testing.expectEqual(first.x + first.w, second.x);
    try testing.expectEqual(first.h, second.h);
    try testing.expectEqual(track.rect.w, tabs.inset * 2 + width * 2 + (7 * byte_width + tabs.pad * 2));
}

test "tabs: the current tab is raised, and hover only recolors the label" {
    var fixture: Fixture = .{};
    const dark = try show(&fixture, &Theme.dark, .{ .tabs = &labels, .current = 1, .hovered = 0 });
    try testing.expectEqual(Theme.dark.input.alpha(30), face(&dark, 1).box.fill);
    try testing.expectEqual(Theme.dark.input, face(&dark, 1).box.border);
    try testing.expectEqual(Theme.Color.transparent, face(&dark, 0).box.fill);
    try testing.expectEqual(Theme.dark.foreground, label(&dark, 1).content.text.color);
    try testing.expectEqual(Theme.dark.foreground, label(&dark, 0).content.text.color);
    try testing.expectEqual(Theme.dark.muted_foreground, label(&dark, 2).content.text.color);

    const light = try show(&fixture, &Theme.light, .{ .tabs = &labels, .current = 1 });
    try testing.expectEqual(Theme.light.background, face(&light, 1).box.fill);
    try testing.expectEqual(Theme.Color.transparent, face(&light, 1).box.border);
    try testing.expectEqual(Theme.light.muted_foreground, label(&light, 0).content.text.color);
}

test "tabs: focus is the face's border, and the list does not grow" {
    var fixture: Fixture = .{};
    const plain = try show(&fixture, &Theme.dark, .{ .tabs = &labels, .current = 0 });
    const track = plain.nodes[0].rect;
    const history_rect = face(&plain, 2).rect;
    try testing.expectEqual(Theme.Color.transparent, face(&plain, 2).box.border);
    const ringed = try show(&fixture, &Theme.dark, .{ .tabs = &labels, .current = 0, .focused = 2 });
    try testing.expectEqual(track, ringed.nodes[0].rect);
    try testing.expectEqual(history_rect, face(&ringed, 2).rect);
    try testing.expectEqual(Theme.dark.ring, face(&ringed, 2).box.border);
}

test "tabs: a press lands on the tab under it" {
    var fixture: Fixture = .{};
    const tree = try show(&fixture, &Theme.dark, .{ .tabs = &labels, .current = 0 });
    const at = face(&tree, 1).rect;
    try testing.expectEqual(focus, tree.hitTest(at.x + 4, at.y + 4));
    try testing.expectEqual(Id.none, tree.hitTest(1, 1));
}
