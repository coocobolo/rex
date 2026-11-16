const std = @import("std");
const testing = std.testing;

const Theme = @import("Theme.zig");
const tabs = @import("tabs.zig");
const text = @import("text.zig");
const Tree = @import("Tree.zig");
const Id = Tree.Id;

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
    nodes: [16]Tree.Node = undefined,
    lines: [8]text.Line = undefined,

    fn tree(self: *Fixture) Tree {
        return .init(&self.nodes, &self.lines);
    }
};

fn show(fixture: *Fixture, theme: *const Theme, options: tabs.Options) !Tree {
    var tree = fixture.tree();
    try tabs.view(&tree, theme, options);
    try tree.layout(measurer, 400, 200);
    return tree;
}

fn face(tree: *const Tree, index: usize) *const Tree.Node {
    return &tree.nodes[1 + index * 2];
}

fn label(tree: *const Tree, index: usize) *const Tree.Node {
    return &tree.nodes[2 + index * 2];
}

test "tabs: the track is 32 tall and each face sits in the 3 px inset" {
    var fixture: Fixture = .{};
    const tree = try show(&fixture, &Theme.dark, .{ .tabs = &labels, .current = 0 });

    try testing.expectEqual(1 + labels.len * 2, tree.len);
    const track = tree.nodes[0];
    try testing.expectEqual(Theme.control_sm, track.rect.h);
    try testing.expectEqual(Theme.dark.muted, track.box.fill);
    try testing.expectEqual(Theme.radius, track.box.radius);

    const first = face(&tree, 0).rect;
    const second = face(&tree, 1).rect;
    const width = tabs.pad * 2 + 5 * byte_width;
    try testing.expectEqual(Tree.Rect{
        .x = tabs.inset,
        .y = tabs.inset,
        .w = width,
        .h = tabs.horizontal_face_height,
    }, first);
    try testing.expectEqual(first.x + first.w, second.x);
    try testing.expectEqual(first.h, second.h);
    try testing.expectEqual(track.rect.w, tabs.inset * 2 + width * 2 + (7 * byte_width + tabs.pad * 2));
}

test "tabs: the current tab is raised, and hover only recolors the label" {
    var fixture: Fixture = .{};
    const dark = try show(&fixture, &Theme.dark, .{ .tabs = &labels, .current = 1, .hovered = 0 });
    // 30% of `input`'s 15%: alpha 11 of 255, not white at 30%.
    try testing.expectEqual(Theme.Color{ .r = 255, .g = 255, .b = 255, .a = 11 }, face(&dark, 1).box.fill);
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

test "tabs: the line variant adds one indicator node per tab" {
    var fixture: Fixture = .{};
    const tree = try show(&fixture, &Theme.dark, .{ .tabs = &labels, .current = 1, .variant = .line });

    try testing.expectEqual(tabs.nodeMax(labels.len), tree.len);
    try testing.expectEqual(Theme.Color.transparent, tree.nodes[0].box.fill);
    try testing.expectEqual(0, tree.nodes[0].box.radius);
    // Each tab is a face, a label, then the indicator.
    try testing.expectEqual(Theme.Color.transparent, tree.nodes[1 + 1 * 3].box.fill);
    try testing.expectEqual(Theme.dark.foreground, tree.nodes[1 + 1 * 3 + 2].box.fill);
    try testing.expectEqual(Theme.Color.transparent, tree.nodes[1 + 0 * 3 + 2].box.fill);
    const mark = tree.nodes[1 + 1 * 3 + 2].rect;
    try testing.expectEqual(tabs.indicator, mark.h);
    try testing.expectEqual(tree.nodes[1 + 1 * 3].rect.w - 2 * tabs.pad, mark.w);
}

test "tabs: the vertical orientation stacks the faces and aligns their labels" {
    var fixture: Fixture = .{};
    const tree = try show(&fixture, &Theme.dark, .{ .tabs = &labels, .current = 0, .orientation = .vertical });

    try testing.expectEqual(.column, tree.nodes[0].box.axis);
    try testing.expectEqual(Theme.control_sm, tree.nodes[0].rect.w);
    const first = tree.nodes[1].rect;
    const second = tree.nodes[3].rect;
    try testing.expectEqual(first.y + first.h, second.y);
    try testing.expectEqual(first.x, second.x);
    try testing.expectEqual(tree.nodes[2].content.text.alignment, .start);
}

test "tabs: a press lands on the tab under it" {
    var fixture: Fixture = .{};
    const tree = try show(&fixture, &Theme.dark, .{ .tabs = &labels, .current = 0 });
    const at = face(&tree, 1).rect;
    try testing.expectEqual(focus, tree.hitTest(at.x + 4, at.y + 4));
    try testing.expectEqual(Id.none, tree.hitTest(1, 1));
}

test "tabs: Options keeps its 32-byte layout after adding variant and orientation" {
    try testing.expectEqual(32, @sizeOf(tabs.Options));
}
