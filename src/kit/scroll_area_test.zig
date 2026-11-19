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

test "scroll_area: scrollbarAt distinguishes thumb, track, miss, and horizontal axis" {
    var nodes: [scroll_area.node_max + 4]Tree.Node = undefined;
    var lines: [1]text.Line = undefined;
    var tree: Tree = .init(&nodes, &lines);

    // Non-overflowing scroll area has no visible scrollbar to hit.
    const fit_id = Tree.Id.of("scroll.hit.fit");
    const fit_area = try scroll_area.open(&tree, .{ .id = fit_id });
    _ = try tree.leaf(.{ .width = .fill, .height = .{ .fixed = 60 } });
    try scroll_area.close(&tree, &Theme.dark, fit_area);
    try tree.layout(measurer(), 200, 100);
    try testing.expectEqual(@as(?Tree.Scroll.ScrollbarHit, null), tree.scrollbarAt(196, 50));

    // Vertical overflow: viewport 200x100, offset 50 -> thumb at y = 27..73, 12 px grab strip x = 188..200.
    tree.reset();
    const vert_id = Tree.Id.of("scroll.hit.vert");
    const item_id = Tree.Id.of("scroll.hit.item");
    const vert_area = try scroll_area.open(&tree, .{ .id = vert_id, .offset = .{ .y = 50 } });
    // Descendant item spans full width (like a dropdown row) and must not occlude its own scrollbar.
    _ = try tree.leaf(.{ .id = item_id, .width = .fill, .height = .{ .fixed = 200 } });
    try scroll_area.close(&tree, &Theme.dark, vert_area);
    try tree.layout(measurer(), 200, 100);

    // Just left of the 12 px strip: miss.
    try testing.expectEqual(@as(?Tree.Scroll.ScrollbarHit, null), tree.scrollbarAt(187, 50));
    // Inside the 12 px strip at thumb vertical range (even slightly left of the 4 px thumb): .thumb.
    const hit_thumb = tree.scrollbarAt(190, 50).?;
    try testing.expectEqual(vert_id, hit_thumb.region.id);
    try testing.expectEqual(Tree.Axis.column, hit_thumb.axis);
    try testing.expectEqual(Tree.Scroll.Part.thumb, hit_thumb.part);
    try testing.expectEqual(@as(f32, 4), hit_thumb.track_start);
    try testing.expectEqual(@as(f32, 92), hit_thumb.track_len);
    try testing.expectEqual(@as(f32, 27), hit_thumb.thumb_start);
    try testing.expectEqual(@as(f32, 46), hit_thumb.thumb_len);
    // Above and below the thumb inside the track strip: .track.
    try testing.expectEqual(Tree.Scroll.Part.track, tree.scrollbarAt(195, 10).?.part);
    try testing.expectEqual(Tree.Scroll.Part.track, tree.scrollbarAt(195, 85).?.part);

    // Horizontal overflow: viewport 200x100, content 400 wide, offset.x = 100 -> thumb x = 4 + 48 = 52..148.
    tree.reset();
    const horiz_id = Tree.Id.of("scroll.hit.horiz");
    const horiz_area = try scroll_area.open(&tree, .{ .id = horiz_id, .axis = .row, .offset = .{ .x = 100 } });
    _ = try tree.leaf(.{ .width = .{ .fixed = 400 }, .height = .fill });
    try scroll_area.close(&tree, &Theme.dark, horiz_area);
    try tree.layout(measurer(), 200, 100);

    try testing.expectEqual(@as(?Tree.Scroll.ScrollbarHit, null), tree.scrollbarAt(100, 87));
    const h_thumb = tree.scrollbarAt(100, 92).?;
    try testing.expectEqual(horiz_id, h_thumb.region.id);
    try testing.expectEqual(Tree.Axis.row, h_thumb.axis);
    try testing.expectEqual(Tree.Scroll.Part.thumb, h_thumb.part);
    try testing.expectEqual(Tree.Scroll.Part.track, tree.scrollbarAt(10, 92).?.part);
}

test "scroll_area: later overlay root occludes underlying scrollbar" {
    var nodes: [scroll_area.node_max + 4]Tree.Node = undefined;
    var lines: [1]text.Line = undefined;
    var tree: Tree = .init(&nodes, &lines);

    const area_id = Tree.Id.of("scroll.occluded");
    const area = try scroll_area.open(&tree, .{ .id = area_id });
    _ = try tree.leaf(.{ .width = .fill, .height = .{ .fixed = 240 } });
    try scroll_area.close(&tree, &Theme.dark, area);

    // A later root (like a modal scrim or popup backdrop) covers the whole window.
    _ = try tree.leaf(.{ .id = Tree.Id.of("popup.layer"), .width = .fill, .height = .fill });
    try tree.layout(measurer(), 200, 100);

    try testing.expectEqual(@as(?Tree.Scroll.ScrollbarHit, null), tree.scrollbarAt(196, 20));
}
