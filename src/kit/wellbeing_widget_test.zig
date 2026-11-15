const std = @import("std");
const testing = std.testing;

const Theme = @import("Theme.zig");
const icons = @import("icons.zig");
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

test "wellbeing_widget: drag move and aspect-locked corner resize keep top-left anchored" {
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

    // Resizing along 2:1 scales horizontal grid cleanly up to max bounds.
    _ = widget.update(&state, .{ .press = .{ .hit = .resize, .x = state.x + state.width, .y = state.y + state.height } });
    try testing.expect(state.positioned);
    _ = widget.update(&state, .{ .pointer = .{ .over = .resize, .x = state.x + 320, .y = state.y + 160 } });
    try testing.expectEqual(@as(f32, 320), state.width);
    try testing.expectEqual(@as(f32, 160), state.height);
    try testing.expectEqual(anchored_x, state.x);
    try testing.expectEqual(anchored_y, state.y);

    // Pulling inward into square aspect switches cleanly to 1:1 grid.
    _ = widget.update(&state, .{ .pointer = .{ .over = .resize, .x = state.x + 140, .y = state.y + 140 } });
    try testing.expectEqual(@as(f32, 140), state.width);
    try testing.expectEqual(@as(f32, 140), state.height);

    // Dragging below minimum square bounds clamps cleanly to 96x96.
    _ = widget.update(&state, .{ .pointer = .{ .over = .resize, .x = state.x + 40, .y = state.y + 40 } });
    try testing.expectEqual(@as(f32, 96), state.width);
    try testing.expectEqual(@as(f32, 96), state.height);
    _ = widget.update(&state, .{ .release = .resize });

    // Card body drag moves the card without resizing it.
    _ = widget.update(&state, .{ .press = .{ .hit = .card, .x = 200, .y = 95 } });
    try testing.expect(state.holdsPress());
    try testing.expectEqual(widget.Outcome.redraw, widget.update(&state, .{ .pointer = .{ .over = .card, .x = 240, .y = 135 } }));
    try testing.expectEqual(anchored_x + 40, state.x);
    try testing.expectEqual(anchored_y + 40, state.y);
    _ = widget.update(&state, .{ .release = .card });
    try testing.expect(!state.holdsPress());

    // Out-of-bounds coordinates clamp inside the viewport.
    var fixture: Fixture = .{};
    var tree = fixture.tree();
    const root = (try widget.view(&state, &tree, &Theme.dark, 300, 200)).?;
    try layout(&tree, measurer, 300, 200);
    state.x = 999;
    state.y = 999;
    widget.place(&state, &tree, root, 300, 200);
    try testing.expectEqual(300 - 4 - @as(f32, 96), state.x);
    try testing.expectEqual(200 - 4 - @as(f32, 96), state.y);
}

test "wellbeing_widget: square mini scales cleanly and horizontal supports mini and normal" {
    const sizes = [_]struct {
        w: f32,
        h: f32,
        vw: f32,
        vh: f32,
        grid: widget.Grid,
        mode: widget.Mode,
    }{
        .{ .w = 96, .h = 96, .vw = 800, .vh = 600, .grid = .square, .mode = .mini },
        .{ .w = 160, .h = 160, .vw = 800, .vh = 600, .grid = .square, .mode = .mini },
        .{ .w = 144, .h = 72, .vw = 800, .vh = 600, .grid = .horizontal, .mode = .mini },
        .{ .w = 264, .h = 132, .vw = 800, .vh = 600, .grid = .horizontal, .mode = .normal },
        // Shrinking viewport folds large layouts cleanly into bounds.
        .{ .w = 264, .h = 132, .vw = 200, .vh = 100, .grid = .horizontal, .mode = .mini },
        .{ .w = 160, .h = 160, .vw = 130, .vh = 130, .grid = .square, .mode = .mini },
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
        try testing.expectEqual(case.grid, eff.grid);
        try testing.expectEqual(case.mode, eff.mode);

        for ([_]*const Theme{ &Theme.dark, &Theme.light }) |theme| {
            var fixture: Fixture = .{};
            var tree = fixture.tree();
            const root = (try widget.view(&state, &tree, theme, case.vw, case.vh)).?;
            try layout(&tree, measurer, case.vw, case.vh);
            widget.place(&state, &tree, root, case.vw, case.vh);

            const card_rect = tree.nodes[root].rect;
            try testing.expect(card_rect.w <= case.vw);
            try testing.expect(card_rect.h <= case.vh);

            // Corner resize handle uses handle-bottom-right and is reachable at bottom-right.
            const corner_hit = tree.hitTest(card_rect.x + card_rect.w - 4, card_rect.y + card_rect.h - 4);
            try testing.expectEqual(widget.resize_id, corner_hit);

            var saw_handle_icon = false;
            for (tree.nodes[0..tree.len]) |node| {
                switch (node.content) {
                    .icon => |ic| if (ic.codepoint == icons.handle_bottom_right) {
                        saw_handle_icon = true;
                    },
                    else => {},
                }
            }
            try testing.expect(saw_handle_icon);
        }
    }
}

test "wellbeing_widget: outer border hides when unfocused and stays neutral on focus and break" {
    var state: widget.State = .empty;
    _ = widget.update(&state, .toggle_visible);
    state.width = 264;
    state.height = 132;

    // Unfocused outer card hides its border completely.
    {
        var fixture: Fixture = .{};
        var tree = fixture.tree();
        const root = (try widget.view(&state, &tree, &Theme.dark, 800, 600)).?;
        try testing.expectEqual(Theme.Color.transparent, tree.nodes[root].box.border);
    }

    // Hovering inside card reveals the neutral outer border.
    try testing.expectEqual(widget.Outcome.redraw, widget.update(&state, .{ .pointer = .{ .over = .card, .x = 40, .y = 40 } }));
    {
        var fixture: Fixture = .{};
        var tree = fixture.tree();
        const root = (try widget.view(&state, &tree, &Theme.dark, 800, 600)).?;
        try testing.expectEqual(Theme.dark.border, tree.nodes[root].box.border);
    }
    try testing.expectEqual(widget.Outcome.redraw, widget.update(&state, .leave));

    for ([_]widget.Phase{ .task, .short_break }) |phase| {
        _ = widget.update(&state, .{ .sync = .{
            .phase = phase,
            .run = .running,
            .fraction = 0.5,
            .seconds = 300,
        } });
        _ = widget.update(&state, .{ .press = .{ .hit = .resize, .x = 10, .y = 10 } });

        var fixture: Fixture = .{};
        var tree = fixture.tree();
        const root = (try widget.view(&state, &tree, &Theme.dark, 800, 600)).?;
        try layout(&tree, measurer, 800, 600);
        widget.place(&state, &tree, root, 800, 600);

        // Resizing card border and tile border must never tint with blue info accent.
        try testing.expectEqual(Theme.dark.ring.alpha(70), tree.nodes[root].box.border);
        for (tree.nodes[0..tree.len]) |node| {
            if (node.box.id == widget.play_pause_id) {
                try testing.expectEqual(Theme.dark.border, node.box.border);
            }
        }
        _ = widget.update(&state, .{ .release = .resize });
    }
}

test "wellbeing_widget: hover tracks interactive targets cleanly" {
    var state: widget.State = .empty;
    _ = widget.update(&state, .toggle_visible);
    try testing.expectEqual(widget.Hit.none, state.hovered);

    try testing.expectEqual(widget.Outcome.redraw, widget.update(&state, .{ .pointer = .{ .over = .card, .x = 40, .y = 40 } }));
    try testing.expectEqual(widget.Outcome.quiet, widget.update(&state, .{ .pointer = .{ .over = .card, .x = 44, .y = 40 } }));
    try testing.expectEqual(widget.Outcome.redraw, widget.update(&state, .{ .pointer = .{ .over = .play_pause, .x = 60, .y = 60 } }));
    try testing.expectEqual(widget.Hit.play_pause, state.hovered);
    try testing.expectEqual(widget.Outcome.quiet, widget.update(&state, .{ .pointer = .{ .over = .play_pause, .x = 64, .y = 60 } }));
    try testing.expectEqual(widget.Outcome.redraw, widget.update(&state, .leave));
    try testing.expectEqual(widget.Hit.none, state.hovered);
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
}

test "wellbeing_widget: play_pause box drags past threshold and horizontal timer stays clear of dial" {
    var state: widget.State = .empty;
    _ = widget.update(&state, .toggle_visible);
    state.x = 100;
    state.y = 80;
    state.positioned = true;

    // Tiny jitter (<= 6px) still toggles on release.
    try testing.expectEqual(widget.Outcome.redraw, widget.update(&state, .{ .press = .{ .hit = .play_pause, .x = 50, .y = 50 } }));
    try testing.expectEqual(widget.Outcome.quiet, widget.update(&state, .{ .pointer = .{ .over = .play_pause, .x = 53, .y = 54 } }));
    try testing.expectEqual(widget.Outcome{ .action = .toggle }, widget.update(&state, .{ .release = .play_pause }));

    // Dragging beyond threshold promotes to move and suppresses accidental toggle.
    try testing.expectEqual(widget.Outcome.redraw, widget.update(&state, .{ .press = .{ .hit = .play_pause, .x = 50, .y = 50 } }));
    try testing.expectEqual(widget.Outcome.redraw, widget.update(&state, .{ .pointer = .{ .over = .play_pause, .x = 70, .y = 65 } }));
    try testing.expectEqual(widget.Outcome.redraw, widget.update(&state, .{ .release = .play_pause }));
    try testing.expectEqual(@as(f32, 120), state.x);
    try testing.expectEqual(@as(f32, 95), state.y);

    // Horizontal normal (264x132) keeps timer text strictly clear of the right-hand dial tile.
    _ = widget.update(&state, .{ .sync = .{ .phase = .task, .run = .running, .fraction = 0.25, .seconds = 145 } });
    state.width = 264;
    state.height = 132;
    var fixture: Fixture = .{};
    var tree = fixture.tree();
    const root = (try widget.view(&state, &tree, &Theme.dark, 800, 600)).?;
    try layout(&tree, measurer, 800, 600);
    widget.place(&state, &tree, root, 800, 600);

    const tile_rect = findNode(&tree, widget.play_pause_id).?;
    var saw_time = false;
    for (tree.nodes[0..tree.len]) |node| {
        switch (node.content) {
            .text => |t| if (std.mem.eql(u8, t.bytes, "02:25")) {
                try testing.expect(node.rect.x + node.rect.w <= tile_rect.x);
                saw_time = true;
                break;
            },
            else => {},
        }
    }
    try testing.expect(saw_time);
}

test "wellbeing_widget: mini uses full space for foreground time with phase-colored progress border" {
    var state: widget.State = .empty;
    _ = widget.update(&state, .toggle_visible);

    const cases = [_]struct {
        w: f32,
        h: f32,
        phase: widget.Phase,
        run: widget.Run,
        expected_color: Theme.Color,
        expected_border_color: Theme.Color,
        expected_style: text.Style,
        stacked: bool,
    }{
        .{ .w = 96, .h = 96, .phase = .task, .run = .running, .expected_color = Theme.dark.foreground, .expected_border_color = Theme.dark.info.alpha(92), .expected_style = .xl_semibold, .stacked = true },
        .{ .w = 112, .h = 112, .phase = .task, .run = .running, .expected_color = Theme.dark.foreground, .expected_border_color = Theme.dark.info.alpha(92), .expected_style = .display_sm, .stacked = true },
        .{ .w = 132, .h = 132, .phase = .task, .run = .running, .expected_color = Theme.dark.foreground, .expected_border_color = Theme.dark.info.alpha(92), .expected_style = .display_md, .stacked = true },
        .{ .w = 152, .h = 152, .phase = .task, .run = .running, .expected_color = Theme.dark.foreground, .expected_border_color = Theme.dark.info.alpha(92), .expected_style = .xxl_semibold, .stacked = true },
        .{ .w = 144, .h = 72, .phase = .short_break, .run = .running, .expected_color = Theme.dark.foreground, .expected_border_color = Theme.dark.success.alpha(92), .expected_style = .display_sm, .stacked = false },
        .{ .w = 164, .h = 82, .phase = .short_break, .run = .running, .expected_color = Theme.dark.foreground, .expected_border_color = Theme.dark.success.alpha(92), .expected_style = .display_md, .stacked = false },
        .{ .w = 212, .h = 106, .phase = .short_break, .run = .running, .expected_color = Theme.dark.foreground, .expected_border_color = Theme.dark.success.alpha(92), .expected_style = .xxl_semibold, .stacked = false },
        .{ .w = 212, .h = 106, .phase = .task, .run = .paused, .expected_color = Theme.dark.muted_foreground.alpha(55), .expected_border_color = Theme.dark.muted_foreground.alpha(55), .expected_style = .xxl_semibold, .stacked = false },
    };
    for (cases) |c| {
        _ = widget.update(&state, .{ .sync = .{
            .phase = c.phase,
            .run = c.run,
            .fraction = 0.5,
            .seconds = 1251,
            .tasks_in_cycle = 1,
            .tasks_before_long_break = 4,
        } });
        state.width = c.w;
        state.height = c.h;
        var fixture: Fixture = .{};
        var tree = fixture.tree();
        const root = (try widget.view(&state, &tree, &Theme.dark, 800, 600)).?;
        try layout(&tree, measurer, 800, 600);
        widget.place(&state, &tree, root, 800, 600);

        const play_rect = findNode(&tree, widget.play_pause_id).?;
        var arcs: usize = 0;
        var swept_border = false;
        var texts: usize = 0;
        var saw_mm = false;
        var saw_ss = false;
        var saw_full = false;
        for (tree.nodes[0..tree.len]) |node| {
            switch (node.content) {
                .arc => arcs += 1,
                .text => |t| {
                    texts += 1;
                    try testing.expectEqual(c.expected_color, t.color);
                    try testing.expectEqual(c.expected_style, t.style);
                    if (std.mem.eql(u8, t.bytes, "20")) saw_mm = true;
                    if (std.mem.eql(u8, t.bytes, "51")) saw_ss = true;
                    if (std.mem.eql(u8, t.bytes, "20:51")) saw_full = true;
                },
                .box => {
                    if (node.box.id == widget.play_pause_id) {
                        try testing.expectEqual(Theme.Color.transparent, node.box.fill);
                    }
                    if (node.box.border_sweep > 0 and
                        node.box.border_width >= 3 and
                        @abs(node.rect.h - play_rect.h) <= 1 and
                        @abs(node.rect.w - play_rect.w) <= 1)
                    {
                        try testing.expectEqual(c.expected_border_color, node.box.border);
                        swept_border = true;
                    }
                },
                else => {},
            }
        }
        try testing.expectEqual(@as(usize, 0), arcs);
        try testing.expect(swept_border);
        if (c.stacked) {
            try testing.expectEqual(@as(usize, 2), texts);
            try testing.expect(saw_mm and saw_ss);
        } else {
            try testing.expectEqual(@as(usize, 1), texts);
            try testing.expect(saw_full);
        }
    }
}

test "wellbeing_widget: hover tooltip shows phase and cycle only in mini while not dragging" {
    var state: widget.State = .empty;
    _ = widget.update(&state, .toggle_visible);
    _ = widget.update(&state, .{ .sync = .{
        .phase = .task,
        .run = .running,
        .fraction = 0.5,
        .seconds = 900,
        .tasks_in_cycle = 1,
        .tasks_before_long_break = 4,
    } });
    state.width = 120;
    state.height = 120;

    // Unfocused: no tooltip.
    {
        var fixture: Fixture = .{};
        var tree = fixture.tree();
        _ = (try widget.view(&state, &tree, &Theme.dark, 800, 600)).?;
        try testing.expectEqual(null, try widget.viewTooltip(&state, &tree, &Theme.dark, 800, 600));
    }

    // Hovered in mini: tooltip shows colored Focus badge + 2/4 cycle below card near top.
    _ = widget.update(&state, .{ .pointer = .{ .over = .play_pause, .x = 50, .y = 50 } });
    {
        var fixture: Fixture = .{};
        var tree = fixture.tree();
        const root = (try widget.view(&state, &tree, &Theme.dark, 800, 600)).?;
        const tip = (try widget.viewTooltip(&state, &tree, &Theme.dark, 800, 600)).?;
        try layout(&tree, measurer, 800, 600);
        widget.place(&state, &tree, root, 800, 600);
        widget.placeTooltip(&tree, root, tip, 800, 600);

        const card_rect = tree.nodes[root].rect;
        const tip_rect = tree.nodes[tip].rect;
        try testing.expect(tip_rect.y >= card_rect.y + card_rect.h);
        try testing.expect(tip_rect.x + tip_rect.w <= 800 - 8);

        var saw_label = false;
        var saw_value = false;
        var saw_badge = false;
        for (tree.nodes[tip..tree.len]) |node| {
            switch (node.content) {
                .text => |t| {
                    if (std.mem.eql(u8, t.bytes, "Focus") and std.meta.eql(t.color, Theme.dark.info_text)) saw_label = true;
                    if (std.mem.eql(u8, t.bytes, "2/4")) saw_value = true;
                },
                .box => {
                    if (std.meta.eql(node.box.fill, Theme.dark.info.alpha(16))) {
                        saw_badge = true;
                    }
                },
                else => {},
            }
        }
        try testing.expect(saw_label and saw_value and saw_badge);
    }

    // Card near bottom edge flips tooltip cleanly above card, and paused break shows Break paused pill + 1/4.
    state.positioned = true;
    state.x = 100;
    state.y = 470;
    _ = widget.update(&state, .{ .sync = .{
        .phase = .short_break,
        .run = .paused,
        .fraction = 0.25,
        .seconds = 180,
        .tasks_in_cycle = 1,
        .tasks_before_long_break = 4,
    } });
    {
        var fixture: Fixture = .{};
        var tree = fixture.tree();
        const root = (try widget.view(&state, &tree, &Theme.dark, 800, 600)).?;
        const tip = (try widget.viewTooltip(&state, &tree, &Theme.dark, 800, 600)).?;
        try layout(&tree, measurer, 800, 600);
        widget.place(&state, &tree, root, 800, 600);
        widget.placeTooltip(&tree, root, tip, 800, 600);

        const card_rect = tree.nodes[root].rect;
        const tip_rect = tree.nodes[tip].rect;
        try testing.expect(tip_rect.y + tip_rect.h <= card_rect.y);

        var saw_break = false;
        var saw_cycle = false;
        var saw_muted_badge = false;
        for (tree.nodes[tip..tree.len]) |node| {
            switch (node.content) {
                .text => |t| {
                    if (std.mem.eql(u8, t.bytes, "Break paused") and std.meta.eql(t.color, Theme.dark.muted_foreground)) saw_break = true;
                    if (std.mem.eql(u8, t.bytes, "1/4")) saw_cycle = true;
                },
                .box => {
                    if (std.meta.eql(node.box.fill, Theme.dark.muted)) saw_muted_badge = true;
                },
                else => {},
            }
        }
        try testing.expect(saw_break and saw_cycle and saw_muted_badge);
    }

    // Suppressed while resizing, and suppressed in normal mode (264x132).
    _ = widget.update(&state, .{ .press = .{ .hit = .resize, .x = 10, .y = 10 } });
    {
        var fixture: Fixture = .{};
        var tree = fixture.tree();
        _ = (try widget.view(&state, &tree, &Theme.dark, 800, 600)).?;
        try testing.expectEqual(null, try widget.viewTooltip(&state, &tree, &Theme.dark, 800, 600));
    }
    _ = widget.update(&state, .{ .release = .resize });
    state.width = 264;
    state.height = 132;
    {
        var fixture: Fixture = .{};
        var tree = fixture.tree();
        _ = (try widget.view(&state, &tree, &Theme.dark, 800, 600)).?;
        try testing.expectEqual(null, try widget.viewTooltip(&state, &tree, &Theme.dark, 800, 600));
    }
}

test "wellbeing_widget: tooltip picks below/above/left/right side cleanly with flush corner alignment" {
    var state: widget.State = .empty;
    state.visible = true;
    state.width = 96;
    state.height = 96;
    state.pointer_inside = true;
    _ = widget.update(&state, .{ .sync = .{
        .phase = .short_break,
        .run = .paused,
        .fraction = 0.5,
        .seconds = 200,
        .tasks_in_cycle = 1,
        .tasks_before_long_break = 4,
    } });

    const Case = struct {
        vw: f32,
        vh: f32,
        positioned: bool,
        x: f32,
        y: f32,
        side: enum { below, above, left, right },
        flush_right: bool = false,
        flush_left: bool = false,
    };
    const cases = [_]Case{
        // Top-right corner: below and flush with card right edge instead of sticking out into 8px margin.
        .{ .vw = 800, .vh = 600, .positioned = false, .x = 0, .y = 0, .side = .below, .flush_right = true },
        // Top-left corner: below and flush with card left edge.
        .{ .vw = 800, .vh = 600, .positioned = true, .x = 16, .y = 16, .side = .below, .flush_left = true },
        // Bottom-right corner: flips above and flush with card right edge.
        .{ .vw = 800, .vh = 600, .positioned = true, .x = 800 - 16 - 96, .y = 600 - 16 - 96, .side = .above, .flush_right = true },
        // Short viewport on right side: neither vertical side fits -> flips left cleanly.
        .{ .vw = 800, .vh = 130, .positioned = true, .x = 800 - 16 - 96, .y = 17, .side = .left },
        // Short viewport on left side: flips right cleanly.
        .{ .vw = 800, .vh = 130, .positioned = true, .x = 16, .y = 17, .side = .right },
    };

    for (cases) |c| {
        state.positioned = c.positioned;
        state.x = c.x;
        state.y = c.y;
        var fixture: Fixture = .{};
        var tree = fixture.tree();
        const root = (try widget.view(&state, &tree, &Theme.dark, c.vw, c.vh)).?;
        const tip = (try widget.viewTooltip(&state, &tree, &Theme.dark, c.vw, c.vh)).?;
        try layout(&tree, measurer, c.vw, c.vh);
        widget.place(&state, &tree, root, c.vw, c.vh);
        widget.placeTooltip(&tree, root, tip, c.vw, c.vh);

        const card_rect = tree.nodes[root].rect;
        const tip_rect = tree.nodes[tip].rect;
        try testing.expect(tip_rect.w > card_rect.w);
        try testing.expect(tip_rect.x >= 8);
        try testing.expect(tip_rect.y >= 8);
        try testing.expect(tip_rect.x + tip_rect.w <= c.vw - 8);
        try testing.expect(tip_rect.y + tip_rect.h <= c.vh - 8);
        switch (c.side) {
            .below => try testing.expect(tip_rect.y >= card_rect.y + card_rect.h + 6),
            .above => try testing.expect(tip_rect.y + tip_rect.h <= card_rect.y - 6),
            .left => try testing.expect(tip_rect.x + tip_rect.w <= card_rect.x - 6),
            .right => try testing.expect(tip_rect.x >= card_rect.x + card_rect.w + 6),
        }
        if (c.flush_right) try testing.expectApproxEqAbs(card_rect.x + card_rect.w, tip_rect.x + tip_rect.w, 0.5);
        if (c.flush_left) try testing.expectApproxEqAbs(card_rect.x, tip_rect.x, 0.5);
    }
}
