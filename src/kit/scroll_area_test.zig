const std = @import("std");
const testing = std.testing;

const Theme = @import("Theme.zig");
const scroll_area = @import("scroll_area.zig");
const text = @import("text.zig");
const Tree = @import("Tree.zig");

fn measurer() text.Measurer {
    const Fixed = struct {
        var unused: u8 = 0;
        fn width(_: *anyopaque, bytes: []const u8, _: text.Style, _: text.Figures) f32 {
            return @floatFromInt(bytes.len * 8);
        }
    };
    return .{ .context = &Fixed.unused, .widthFn = Fixed.width };
}

test "scroll_area: hides thumb when content fits within viewport" {
    var nodes: [scroll_area.node_max + 2]Tree.Node = undefined;
    var lines: [1]text.Line = undefined;
    var tree = Tree.init(&nodes, &lines);

    const area_id = Tree.Id.of("scroll.fit");
    const area = try scroll_area.open(&tree, .{ .id = area_id });
    _ = try tree.leaf(.{ .width = .fill, .height = .{ .fixed = 60 } });
    try scroll_area.close(&tree, &Theme.dark, area);

    try tree.layout(measurer(), 200, 100);
    try testing.expectEqual(@as(f32, 0), tree.scrollMax(area_id).y);
    const thumb = tree.nodes[tree.len - 1];
    try testing.expectEqual(@as(f32, 0), thumb.rect.w);
    try testing.expectEqual(@as(f32, 0), thumb.rect.h);
}

test "scroll_area: sizes and positions thumb proportionally when content overflows" {
    var nodes: [scroll_area.node_max + 2]Tree.Node = undefined;
    var lines: [1]text.Line = undefined;
    var tree = Tree.init(&nodes, &lines);

    const area_id = Tree.Id.of("scroll.overflow");
    const area = try scroll_area.open(&tree, .{
        .id = area_id,
        .offset = .{ .y = 50 },
    });
    const content = try tree.leaf(.{ .width = .fill, .height = .{ .fixed = 200 } });
    try scroll_area.close(&tree, &Theme.dark, area);

    try tree.layout(measurer(), 200, 100);
    try testing.expectEqual(@as(f32, 100), tree.scrollMax(area_id).y);
    try testing.expectEqual(@as(f32, -50), tree.nodes[content].rect.y);

    // Viewport is 200x100; track height is 100 - 8 = 92; content is 200 (2x viewport),
    // so thumb height is 46, travel is 46, and at 50% scroll thumb.y = 4 + 23 = 27.
    const thumb = tree.nodes[tree.len - 1];
    try testing.expectEqual(Tree.Rect{ .x = 194, .y = 27, .w = 4, .h = 46 }, thumb.rect);
}
