const std = @import("std");
const testing = std.testing;

const Theme = @import("Theme.zig");
const text = @import("text.zig");
const tree_zig = @import("tree.zig");
const Tree = tree_zig.Tree;
const layout = @import("layout.zig").layout;
const widget = @import("wellbeing_widget.zig");

const byte_width = 7;

fn fixedWidth(_: *anyopaque, bytes: []const u8, _: text.Style, _: text.Figures) f32 {
    return @floatFromInt(bytes.len * byte_width);
}

var no_state: u8 = 0;
const measurer: text.Measurer = .{ .context = &no_state, .widthFn = fixedWidth };

const Fixture = struct {
    nodes: [widget.node_max]tree_zig.Node = undefined,
    lines: [widget.line_max]text.Line = undefined,

    fn tree(self: *Fixture) Tree {
        return .init(&self.nodes, &self.lines);
    }
};

fn findNode(tree: *const Tree, id: tree_zig.Id) ?tree_zig.Rect {
    for (tree.nodes[0..tree.len]) |node| {
        if (node.box.id == id) return node.rect;
    }
    return null;
}

test "wellbeing_widget: hidden produces no nodes and sync updates only on change" {
    var state: widget.State = .empty;
    var fixture: Fixture = .{};
    var tree = fixture.tree();
    try testing.expectEqual(null, try widget.view(&state, &tree, &Theme.dark, 800, 600));

    const snap: widget.Snapshot = .{
        .phase = .task,
        .run = .running,
        .fraction = 0.25,
        .seconds = 975,
        .tasks_in_cycle = 1,
        .tasks_before_long_break = 4,
    };
    try testing.expectEqual(widget.Outcome.redraw, widget.update(&state, .{ .sync = snap }));
    try testing.expectEqualStrings("16:15", state.timeText());
    try testing.expectEqualStrings("2/4", state.cycleText());
    // Same snapshot is a no-op.
    try testing.expectEqual(widget.Outcome.quiet, widget.update(&state, .{ .sync = snap }));

    try testing.expectEqual(widget.Outcome.redraw, widget.update(&state, .toggle_visible));
    try testing.expect(state.visible);
    const root = (try widget.view(&state, &tree, &Theme.dark, 800, 600)).?;
    try layout(&tree, measurer, 800, 600);
    widget.place(&state, &tree, root, 800, 600);
    // Default position sits near the top-right corner.
    try testing.expect(tree.nodes[root].rect.x > 400);
    try testing.expectEqual(@as(f32, 16), tree.nodes[root].rect.y);
}

test "wellbeing_widget: drag move, corner and edge resize update geometry and anchor top-left" {
    var state: widget.State = .empty;
    _ = widget.update(&state, .toggle_visible);

    // Initial placement in top-right, then grabbing corner locks positioned so top-left stays put.
    {
        var fixture: Fixture = .{};
        var tree = fixture.tree();
        const root = (try widget.view(&state, &tree, &Theme.dark, 800, 600)).?;
        try layout(&tree, measurer, 800, 600);
        widget.place(&state, &tree, root, 800, 600);
    }
    const anchored_x = state.x;
    const anchored_y = state.y;

    _ = widget.update(&state, .{ .press = .{ .hit = .resize_w, .x = state.x + state.width, .y = state.y + 40 } });
    try testing.expect(state.positioned);
    _ = widget.update(&state, .{ .pointer = .{ .over = .resize_w, .x = state.x + state.width + 60, .y = state.y + 90 } });
    try testing.expectEqual(widget.default_width + 60, state.width);
    try testing.expectEqual(widget.default_height, state.height);
    try testing.expectEqual(anchored_x, state.x);
    try testing.expectEqual(anchored_y, state.y);
    _ = widget.update(&state, .{ .release = .resize_w });

    _ = widget.update(&state, .{ .press = .{ .hit = .resize_h, .x = state.x + 60, .y = state.y + state.height } });
    _ = widget.update(&state, .{ .pointer = .{ .over = .resize_h, .x = state.x + 120, .y = state.y + state.height + 40 } });
    try testing.expectEqual(widget.default_width + 60, state.width);
    try testing.expectEqual(widget.default_height + 40, state.height);
    _ = widget.update(&state, .{ .release = .resize_h });

    // Card body drag moves the card without resizing it.
    _ = widget.update(&state, .{ .press = .{ .hit = .card, .x = 200, .y = 95 } });
    try testing.expect(state.holdsPress());
    try testing.expectEqual(widget.Outcome.redraw, widget.update(&state, .{ .pointer = .{ .over = .card, .x = 240, .y = 135 } }));
    try testing.expectEqual(anchored_x + 40, state.x);
    try testing.expectEqual(anchored_y + 40, state.y);
    _ = widget.update(&state, .{ .release = .card });
    try testing.expect(!state.holdsPress());

    // Resize below compact threshold clamps cleanly to minimum bounds.
    _ = widget.update(&state, .{ .press = .{ .hit = .resize, .x = state.width, .y = state.height } });
    _ = widget.update(&state, .{ .pointer = .{ .over = .resize, .x = 10, .y = 10 } });
    try testing.expectEqual(widget.min_width, state.width);
    try testing.expectEqual(widget.min_height, state.height);
    _ = widget.update(&state, .{ .release = .resize });

    var fixture: Fixture = .{};
    var tree = fixture.tree();
    const root = (try widget.view(&state, &tree, &Theme.dark, 300, 200)).?;
    try layout(&tree, measurer, 300, 200);
    // Out-of-bounds coordinates clamp inside the viewport.
    state.x = 999;
    state.y = 999;
    widget.place(&state, &tree, root, 300, 200);
    try testing.expectEqual(300 - 4 - widget.min_width, state.x);
    try testing.expectEqual(200 - 4 - widget.min_height, state.y);
}

test "wellbeing_widget: all responsive modes and tiny viewports lay out within bounds" {
    const sizes = [_]struct {
        w: f32,
        h: f32,
        vw: f32,
        vh: f32,
        mode: widget.Mode,
    }{
        .{ .w = 144, .h = 44, .vw = 800, .vh = 600, .mode = .mini },
        .{ .w = 210, .h = 110, .vw = 800, .vh = 600, .mode = .mini },
        .{ .w = 344, .h = 72, .vw = 800, .vh = 600, .mode = .bar },
        .{ .w = 440, .h = 48, .vw = 800, .vh = 600, .mode = .bar },
        .{ .w = 180, .h = 200, .vw = 800, .vh = 600, .mode = .portrait },
        .{ .w = 308, .h = 148, .vw = 800, .vh = 600, .mode = .card },
        .{ .w = 420, .h = 220, .vw = 800, .vh = 600, .mode = .expanded },
        // Large card automatically folds down when the viewport shrinks.
        .{ .w = 420, .h = 220, .vw = 240, .vh = 110, .mode = .mini },
        .{ .w = 420, .h = 220, .vw = 320, .vh = 110, .mode = .bar },
        .{ .w = 420, .h = 220, .vw = 200, .vh = 200, .mode = .portrait },
    };

    for (sizes) |case| {
        var state: widget.State = .empty;
        _ = widget.update(&state, .toggle_visible);
        _ = widget.update(&state, .{ .sync = .{
            .phase = .task,
            .run = .running,
            .fraction = 0.42,
            .seconds = 3925,
            .tasks_in_cycle = 2,
            .tasks_before_long_break = 4,
        } });
        state.width = case.w;
        state.height = case.h;

        const eff = state.effectiveSize(case.vw, case.vh);
        try testing.expectEqual(case.mode, eff.mode);

        for ([_]*const Theme{ &Theme.dark, &Theme.light }) |theme| {
            state.pointer_inside = false;
            var fixture: Fixture = .{};
            var tree = fixture.tree();
            const root = (try widget.view(&state, &tree, theme, case.vw, case.vh)).?;
            try layout(&tree, measurer, case.vw, case.vh);
            widget.place(&state, &tree, root, case.vw, case.vh);

            const card_rect = tree.nodes[root].rect;
            try testing.expect(card_rect.w <= case.vw);
            try testing.expect(card_rect.h <= case.vh);
            try testing.expectEqual(@as(?tree_zig.Rect, null), findNode(&tree, widget.close_id));

            // Corner resize handle is reachable at the outer bottom-right corner and distinct from close.
            const corner_hit = tree.hitTest(card_rect.x + card_rect.w - 4, card_rect.y + card_rect.h - 4);
            try testing.expectEqual(widget.resize_id, corner_hit);

            // Hovering reveals the close pill without colliding with the corner resize grip.
            state.pointer_inside = true;
            var hover_fixture: Fixture = .{};
            var hover_tree = hover_fixture.tree();
            const hover_root = (try widget.view(&state, &hover_tree, theme, case.vw, case.vh)).?;
            try layout(&hover_tree, measurer, case.vw, case.vh);
            widget.place(&state, &hover_tree, hover_root, case.vw, case.vh);

            const close_rect = findNode(&hover_tree, widget.close_id).?;
            const corner_rect = findNode(&hover_tree, widget.resize_id).?;
            try testing.expect(close_rect.x + close_rect.w <= corner_rect.x or close_rect.y + close_rect.h <= corner_rect.y);
        }
    }
}

test "wellbeing_widget: auto-hiding close follows pointer presence" {
    var state: widget.State = .empty;
    _ = widget.update(&state, .toggle_visible);
    try testing.expect(!state.showsClose());

    try testing.expectEqual(widget.Outcome.redraw, widget.update(&state, .{ .pointer = .{ .over = .card, .x = 40, .y = 40 } }));
    try testing.expect(state.showsClose());

    // Moving within the same target stays quiet and preserves visibility.
    try testing.expectEqual(widget.Outcome.quiet, widget.update(&state, .{ .pointer = .{ .over = .card, .x = 60, .y = 60 } }));
    try testing.expect(state.showsClose());
    // Moving onto a button redraws hover state while keeping close visible.
    try testing.expectEqual(widget.Outcome.redraw, widget.update(&state, .{ .pointer = .{ .over = .play_pause, .x = 60, .y = 60 } }));
    try testing.expect(state.showsClose());

    // Moving outside or leaving hides the close pill.
    try testing.expectEqual(widget.Outcome.redraw, widget.update(&state, .{ .pointer = .{ .over = .none, .x = 0, .y = 0 } }));
    try testing.expect(!state.showsClose());

    _ = widget.update(&state, .{ .pointer = .{ .over = .close, .x = 80, .y = 20 } });
    try testing.expect(state.showsClose());
    try testing.expectEqual(widget.Outcome.redraw, widget.update(&state, .leave));
    try testing.expect(!state.showsClose());
}

test "wellbeing_widget: buttons act on release over target and idle disables reset and skip" {
    var state: widget.State = .empty;
    _ = widget.update(&state, .toggle_visible);

    // Idle phase disables both reset and skip buttons.
    try testing.expectEqual(widget.Outcome.quiet, widget.update(&state, .{ .press = .{ .hit = .reset, .x = 10, .y = 10 } }));
    try testing.expectEqual(widget.Outcome.quiet, widget.update(&state, .{ .press = .{ .hit = .skip, .x = 10, .y = 10 } }));
    try testing.expect(!state.holdsPress());

    // Play/pause fires toggle on release over play_pause.
    _ = widget.update(&state, .{ .press = .{ .hit = .play_pause, .x = 10, .y = 10 } });
    try testing.expectEqual(widget.Outcome{ .action = .toggle }, widget.update(&state, .{ .release = .play_pause }));

    // Active task phase enables skip and reset, cancelling when released off target.
    _ = widget.update(&state, .{ .sync = .{ .phase = .task, .run = .running, .fraction = 0.5, .seconds = 300 } });
    _ = widget.update(&state, .{ .press = .{ .hit = .skip, .x = 10, .y = 10 } });
    try testing.expect(state.holdsPress());
    try testing.expectEqual(widget.Outcome.redraw, widget.update(&state, .{ .release = .card }));

    _ = widget.update(&state, .{ .press = .{ .hit = .skip, .x = 10, .y = 10 } });
    try testing.expectEqual(widget.Outcome{ .action = .skip }, widget.update(&state, .{ .release = .skip }));

    _ = widget.update(&state, .{ .press = .{ .hit = .reset, .x = 10, .y = 10 } });
    try testing.expectEqual(widget.Outcome{ .action = .reset }, widget.update(&state, .{ .release = .reset }));

    // Close button fires close action.
    _ = widget.update(&state, .{ .press = .{ .hit = .close, .x = 10, .y = 10 } });
    try testing.expectEqual(widget.Outcome{ .action = .close }, widget.update(&state, .{ .release = .close }));
}
