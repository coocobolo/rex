const std = @import("std");
const testing = std.testing;

const Theme = @import("Theme.zig");
const text = @import("text.zig");
const tree_zig = @import("tree.zig");
const layout = @import("layout.zig").layout;
const switch_control = @import("switch.zig");

const Tree = tree_zig.Tree;
const Id = tree_zig.Id;

fn fixedWidth(_: *anyopaque, bytes: []const u8, _: text.Style, _: text.Figures) f32 {
    return @floatFromInt(bytes.len * 7);
}

var no_state: u8 = 0;
const measurer: text.Measurer = .{ .context = &no_state, .widthFn = fixedWidth };

test "switch: unchecked vs checked places thumb left vs right" {
    var off_nodes: [switch_control.node_max]tree_zig.Node = undefined;
    var off_lines: [4]text.Line = undefined;
    var off = Tree.init(&off_nodes, &off_lines);
    try switch_control.view(&off, &Theme.dark, .{ .id = Id.of("sw"), .checked = false });
    try testing.expectEqual(@as(usize, switch_control.node_max), off.len);
    try layout(&off, measurer, 200, 100);

    var on_nodes: [switch_control.node_max]tree_zig.Node = undefined;
    var on_lines: [4]text.Line = undefined;
    var on = Tree.init(&on_nodes, &on_lines);
    try switch_control.view(&on, &Theme.dark, .{ .id = Id.of("sw"), .checked = true });
    try layout(&on, measurer, 200, 100);

    const off_thumb = off.nodes[2].rect;
    const on_thumb = on.nodes[2].rect;
    try testing.expect(on_thumb.x > off_thumb.x);
    try testing.expectEqual(switch_control.thumb_size, off_thumb.w);
    try testing.expectEqual(switch_control.thumb_size, on_thumb.w);
    try testing.expectEqual(Theme.dark.input, off.nodes[1].box.fill);
    try testing.expectEqual(Theme.dark.primary, on.nodes[1].box.fill);
}

test "switch: focused sets ring border; disabled suppresses ring and hand pointer" {
    var nodes: [switch_control.node_max]tree_zig.Node = undefined;
    var lines: [4]text.Line = undefined;

    var focused = Tree.init(&nodes, &lines);
    try switch_control.view(&focused, &Theme.dark, .{ .id = Id.of("sw"), .focused = true });
    try testing.expectEqual(Theme.dark.ring.alpha(Theme.ring_opacity), focused.nodes[0].box.border);
    try testing.expectEqual(tree_zig.PointerShape.hand, focused.nodes[0].box.pointer);

    var disabled = Tree.init(&nodes, &lines);
    try switch_control.view(&disabled, &Theme.dark, .{ .id = Id.of("sw"), .focused = true, .disabled = true });
    try testing.expectEqual(Theme.Color.transparent, disabled.nodes[0].box.border);
    try testing.expectEqual(tree_zig.PointerShape.arrow, disabled.nodes[0].box.pointer);
}
