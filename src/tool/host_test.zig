const std = @import("std");
const testing = std.testing;

const Theme = @import("../kit/Theme.zig");
const Tree = @import("../kit/Tree.zig");
const scroll_area = @import("../kit/scroll_area.zig");
const text = @import("../kit/text.zig");
const host = @import("host.zig");

const Id = Tree.Id;
const Line = text.Line;
const Node = Tree.Node;

var dummy_ctx: u8 = 0;

fn fixedWidth(_: *anyopaque, bytes: []const u8, _: text.Style, _: text.Figures) f32 {
    return @as(f32, @floatFromInt(bytes.len)) * 8.0;
}

const measurer: text.Measurer = .{ .context = &dummy_ctx, .widthFn = fixedWidth };

fn buildVerticalArea(
    tree: *Tree,
    theme: *const Theme,
    id: Id,
    offset_y: f32,
    content_h: f32,
    view_w: f32,
    view_h: f32,
) !void {
    tree.reset();
    const area = try scroll_area.open(tree, .{
        .id = id,
        .offset = .{ .y = offset_y },
        .width = .fill,
        .height = .fill,
    });
    _ = try tree.leaf(.{ .width = .fill, .height = .{ .fixed = content_h } });
    try scroll_area.close(tree, theme, area);
    try tree.layout(measurer, view_w, view_h);
}

fn buildHorizontalArea(
    tree: *Tree,
    theme: *const Theme,
    id: Id,
    offset_x: f32,
    content_w: f32,
    view_w: f32,
    view_h: f32,
) !void {
    tree.reset();
    const area = try scroll_area.open(tree, .{
        .id = id,
        .axis = .row,
        .offset = .{ .x = offset_x },
        .width = .fill,
        .height = .fill,
    });
    _ = try tree.leaf(.{ .width = .{ .fixed = content_w }, .height = .fill });
    try scroll_area.close(tree, theme, area);
    try tree.layout(measurer, view_w, view_h);
}

test "host: a wheel notch down scrolls the content one step up" {
    try testing.expectEqual(@as(f32, host.scroll_step), host.scrollDelta(-1));
    try testing.expectEqual(@as(f32, -host.scroll_step), host.scrollDelta(1));
    // A touchpad's fraction of a notch.
    try testing.expectEqual(@as(f32, host.scroll_step) / 4, host.scrollDelta(-0.25));
}

test "host: ScrollbarDrag thumb grab preserves grab offset and sums batched moves" {
    var nodes: [16]Node = undefined;
    var lines: [16]Line = undefined;
    var tree: Tree = .init(&nodes, &lines);
    const theme = &Theme.dark;
    const area_id: Id = @enumFromInt(10);

    // Viewport 200x108 -> track_len = 100 (y in [4, 104]), content 432 -> max_y = 324, thumb_len = 25, travel = 75.
    try buildVerticalArea(&tree, theme, area_id, 0, 432, 200, 108);
    const hit = tree.scrollbarAt(196, 14) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(Tree.Scroll.Part.thumb, hit.part);

    var drag: host.ScrollbarDrag = .idle;
    // Grabbing the thumb must not jump immediately.
    try testing.expectEqual(@as(?host.Event, null), drag.begin(hit, 196, 14));
    try testing.expectEqual(area_id, drag.activeId());

    // Two batched moves before any tree rebuild accumulate without double-counting.
    var offset: f32 = 0;
    const ev1 = drag.moveTo(196, 39) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(area_id, ev1.scroll.id);
    try testing.expectEqual(@as(f32, 0), ev1.scroll.dx);
    offset = std.math.clamp(offset + ev1.scroll.dy, 0, ev1.scroll.max_y);
    try testing.expectApproxEqAbs(@as(f32, 108), offset, 0.01);

    const ev2 = drag.moveTo(196, 89) orelse return error.TestUnexpectedResult;
    offset = std.math.clamp(offset + ev2.scroll.dy, 0, ev2.scroll.max_y);
    try testing.expectApproxEqAbs(@as(f32, 324), offset, 0.01);

    // Dragging past the bottom stays clamped and emits no further scroll event.
    try testing.expectEqual(@as(?host.Event, null), drag.moveTo(196, 200));

    // Dragging past the top clamps cleanly back to 0.
    const ev3 = drag.moveTo(196, -50) orelse return error.TestUnexpectedResult;
    offset = std.math.clamp(offset + ev3.scroll.dy, 0, ev3.scroll.max_y);
    try testing.expectApproxEqAbs(@as(f32, 0), offset, 0.01);
}

test "host: ScrollbarDrag track click jumps thumb center and continues dragging" {
    var nodes: [16]Node = undefined;
    var lines: [16]Line = undefined;
    var tree: Tree = .init(&nodes, &lines);
    const theme = &Theme.dark;
    const area_id: Id = @enumFromInt(11);

    // Viewport 200x108 -> track [4, 104], thumb_len = 25, travel = 75, max_y = 324.
    try buildVerticalArea(&tree, theme, area_id, 0, 432, 200, 108);
    // Click track center at y = 54 -> thumb_pos = 54 - 12.5 = 41.5 -> ratio = (41.5 - 4) / 75 = 0.5 -> offset = 162.
    const hit = tree.scrollbarAt(196, 54) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(Tree.Scroll.Part.track, hit.part);

    var drag: host.ScrollbarDrag = .idle;
    const jump = drag.begin(hit, 196, 54) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(area_id, jump.scroll.id);
    try testing.expectApproxEqAbs(@as(f32, 162), jump.scroll.dy, 0.01);

    // Dragging down 37.5 px from center reaches the bottom (offset = 324).
    const move = drag.moveTo(196, 91.5) orelse return error.TestUnexpectedResult;
    try testing.expectApproxEqAbs(@as(f32, 162), move.scroll.dy, 0.01);
}

test "host: ScrollbarDrag supports horizontal scrollbars and sync cancellation" {
    var nodes: [16]Node = undefined;
    var lines: [16]Line = undefined;
    var tree: Tree = .init(&nodes, &lines);
    const theme = &Theme.dark;
    const area_id: Id = @enumFromInt(12);

    // Viewport 108x200 -> track [4, 104], content 432 -> max_x = 324, thumb_len = 25, travel = 75.
    try buildHorizontalArea(&tree, theme, area_id, 0, 432, 108, 200);
    const hit = tree.scrollbarAt(14, 196) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(Tree.Axis.row, hit.axis);
    try testing.expectEqual(Tree.Scroll.Part.thumb, hit.part);

    var drag: host.ScrollbarDrag = .idle;
    try testing.expectEqual(@as(?host.Event, null), drag.begin(hit, 14, 196));
    const ev = drag.moveTo(89, 196) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(f32, 0), ev.scroll.dy);
    try testing.expectApproxEqAbs(@as(f32, 324), ev.scroll.dx, 0.01);

    // Rebuild with still-overflowing content keeps the drag alive.
    try buildHorizontalArea(&tree, theme, area_id, 324, 432, 108, 200);
    drag.sync(&tree);
    try testing.expectEqual(area_id, drag.activeId());

    // Rebuild where content now fits cancels the drag to `.idle`.
    try buildHorizontalArea(&tree, theme, area_id, 0, 80, 108, 200);
    drag.sync(&tree);
    try testing.expectEqual(Id.none, drag.activeId());
}

test "host: applyScrollbarHighlight widens active thumb inward and boosts opacity" {
    var nodes: [16]Node = undefined;
    var lines: [16]Line = undefined;
    var tree: Tree = .init(&nodes, &lines);
    const theme = &Theme.dark;
    const area_id: Id = @enumFromInt(13);

    // Newly overflowing region peeks at resting opacity and 4 px thickness.
    try buildVerticalArea(&tree, theme, area_id, 0, 400, 200, 100);
    const rest_thumb = tree.nodes[tree.scrolls[0].thumb];
    var vis: host.ScrollbarVisibility = .{};
    vis.sync(&tree, .none, .none, 0);
    host.applyScrollbarHighlight(&tree, theme, &vis, .none, .none, 0);
    try testing.expectEqual(rest_thumb.rect, tree.nodes[tree.scrolls[0].thumb].rect);
    try testing.expectEqual(theme.muted_foreground.fade(scroll_area.thumb_opacity), tree.nodes[tree.scrolls[0].thumb].box.fill);
    try testing.expectEqual(scroll_area.thumb_radius, tree.nodes[tree.scrolls[0].thumb].box.radius);

    // Hover state widens inward by 2 px (right edge preserved) with hover opacity and radius 3.
    host.applyScrollbarHighlight(&tree, theme, &vis, area_id, .none, 0);
    const hovered = tree.nodes[tree.scrolls[0].thumb];
    try testing.expectEqual(scroll_area.thumb_active_thickness, hovered.rect.w);
    try testing.expectEqual(rest_thumb.rect.x + rest_thumb.rect.w, hovered.rect.x + hovered.rect.w);
    try testing.expectEqual(theme.muted_foreground.fade(scroll_area.thumb_hover_opacity), hovered.box.fill);
    try testing.expectEqual(scroll_area.thumb_active_radius, hovered.box.radius);

    // Drag state takes precedence over hover with drag opacity.
    try buildVerticalArea(&tree, theme, area_id, 0, 400, 200, 100);
    host.applyScrollbarHighlight(&tree, theme, &vis, area_id, area_id, 0);
    const dragged = tree.nodes[tree.scrolls[0].thumb];
    try testing.expectEqual(scroll_area.thumb_active_thickness, dragged.rect.w);
    try testing.expectEqual(rest_thumb.rect.x + rest_thumb.rect.w, dragged.rect.x + dragged.rect.w);
    try testing.expectEqual(theme.muted_foreground.fade(scroll_area.thumb_drag_opacity), dragged.box.fill);
    try testing.expectEqual(scroll_area.thumb_active_radius, dragged.box.radius);

    // Horizontal thumb widens upward, preserving bottom inset.
    try buildHorizontalArea(&tree, theme, area_id, 0, 400, 100, 200);
    const h_rest = tree.nodes[tree.scrolls[0].thumb];
    host.applyScrollbarHighlight(&tree, theme, &vis, area_id, .none, 0);
    const h_hover = tree.nodes[tree.scrolls[0].thumb];
    try testing.expectEqual(scroll_area.thumb_active_thickness, h_hover.rect.h);
    try testing.expectEqual(h_rest.rect.y + h_rest.rect.h, h_hover.rect.y + h_hover.rect.h);
    try testing.expectEqual(theme.muted_foreground.fade(scroll_area.thumb_hover_opacity), h_hover.box.fill);
    try testing.expectEqual(scroll_area.thumb_active_radius, h_hover.box.radius);
}

test "host: ScrollbarVisibility holds, fades to hidden with zero idle wakeups, and stays grabbable" {
    var nodes: [16]Node = undefined;
    var lines: [16]Line = undefined;
    var tree: Tree = .init(&nodes, &lines);
    const theme = &Theme.dark;
    const area_id: Id = @enumFromInt(14);
    const hold = host.ScrollbarVisibility.hold_ms;
    const fade = host.ScrollbarVisibility.fade_ms;

    try buildVerticalArea(&tree, theme, area_id, 0, 400, 200, 100);
    var vis: host.ScrollbarVisibility = .{};

    // First sync peeks the newly overflowing scrollbar for `hold_ms`.
    vis.sync(&tree, .none, .none, 100);
    try testing.expectEqual(@as(?f64, @floatFromInt(hold)), vis.nextWaitMs(100));
    try testing.expectApproxEqAbs(scroll_area.thumb_opacity, vis.opacityOf(area_id, .none, .none, 100), 1e-5);
    try testing.expect(!vis.tick(100 + hold - 1));

    // At `hold_ms`, transitions to fading and schedules frame ticks.
    try testing.expect(vis.tick(100 + hold));
    const fade_start = 100 + hold;
    try testing.expectEqual(@as(?f64, host.ScrollbarVisibility.fade_frame_ms), vis.nextWaitMs(fade_start));

    // Mid-fade opacity is half of resting opacity.
    const mid = fade_start + @divTrunc(fade, 2);
    try testing.expectApproxEqAbs(scroll_area.thumb_opacity * 0.5, vis.opacityOf(area_id, .none, .none, mid), 1e-5);
    try testing.expect(vis.tick(mid));

    // After `fade_ms`, transitions to hidden with `nextWaitMs == null` (zero idle wakeups).
    const done = fade_start + fade;
    try testing.expect(vis.tick(done));
    try testing.expectEqual(@as(?f64, null), vis.nextWaitMs(done));
    try testing.expectEqual(@as(f32, 0), vis.opacityOf(area_id, .none, .none, done));
    try testing.expect(!vis.tick(done + 5000));

    // Hidden thumb paints transparent while keeping its rect so edge hover still hits it.
    host.applyScrollbarHighlight(&tree, theme, &vis, .none, .none, done);
    try testing.expectEqual(Theme.Color.transparent, tree.nodes[tree.scrolls[0].thumb].box.fill);
    try testing.expect(tree.scrollbarAt(196, 10) != null);

    // Wheel scroll reveals a hidden scrollbar and requests a redraw; repeating while holding extends timer silently.
    try testing.expect(vis.reveal(area_id, done + 10));
    try testing.expectApproxEqAbs(scroll_area.thumb_opacity, vis.opacityOf(area_id, .none, .none, done + 10), 1e-5);
    try testing.expect(!vis.reveal(area_id, done + 50));
    try testing.expectEqual(@as(?f64, @floatFromInt(hold)), vis.nextWaitMs(done + 50));

    // Pinning holds indefinitely with zero timer wakeups; unpinning starts a fresh hold.
    vis.pin(area_id);
    try testing.expectEqual(@as(?f64, null), vis.nextWaitMs(done + 50));
    vis.unpin(area_id, done + 200);
    try testing.expectEqual(@as(?f64, @floatFromInt(hold)), vis.nextWaitMs(done + 200));

    // Resize revealAll restores hidden scrollbars without unpinning pinned ones.
    try testing.expect(vis.tick(done + 200 + hold));
    try testing.expect(vis.tick(done + 200 + hold + fade));
    try testing.expectEqual(@as(?f64, null), vis.nextWaitMs(done + 200 + hold + fade));
    vis.revealAll(done + 200 + hold + fade + 10);
    try testing.expectEqual(@as(?f64, @floatFromInt(hold)), vis.nextWaitMs(done + 200 + hold + fade + 10));

    // When content stops overflowing, the entry is dropped so re-overflowing peeks again.
    try buildVerticalArea(&tree, theme, area_id, 0, 50, 200, 100);
    vis.sync(&tree, .none, .none, done + 5000);
    try testing.expectEqual(@as(u8, 0), vis.len);
    try testing.expectEqual(@as(?f64, null), vis.nextWaitMs(done + 5000));
}
