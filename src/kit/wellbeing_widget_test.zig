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

test "wellbeing_widget: hidden produces no nodes and sync updates only on change" {
    var state: widget.State = .empty;
    var fixture: Fixture = .{};
    var tree = fixture.tree();
    try testing.expectEqual(null, try widget.view(&state, &tree, &Theme.dark));

    const snap: widget.Snapshot = .{ .phase = .task, .run = .running, .fraction = 0.25, .seconds = 975 };
    try testing.expectEqual(widget.Outcome.redraw, widget.update(&state, .{ .sync = snap }));
    try testing.expectEqualStrings("16:15", state.timeText());
    // Same snapshot is a no-op.
    try testing.expectEqual(widget.Outcome.quiet, widget.update(&state, .{ .sync = snap }));

    try testing.expectEqual(widget.Outcome.redraw, widget.update(&state, .toggle_visible));
    try testing.expect(state.visible);
    const root = (try widget.view(&state, &tree, &Theme.dark)).?;
    try layout(&tree, measurer, 800, 600);
    widget.place(&state, &tree, root, 800, 600);
    // Default position sits near the top-right corner.
    try testing.expect(tree.nodes[root].rect.x > 400);
    try testing.expectEqual(@as(f32, 16), tree.nodes[root].rect.y);
}

test "wellbeing_widget: drag move and resize update geometry and clamp inside viewport" {
    var state: widget.State = .empty;
    _ = widget.update(&state, .toggle_visible);
    state.x = 100;
    state.y = 80;
    state.positioned = true;

    _ = widget.update(&state, .{ .press = .{ .hit = .card, .x = 120, .y = 95 } });
    try testing.expect(state.holdsPress());
    try testing.expectEqual(widget.Outcome.redraw, widget.update(&state, .{ .pointer = .{ .over = .card, .x = 180, .y = 135 } }));
    try testing.expectEqual(@as(f32, 160), state.x);
    try testing.expectEqual(@as(f32, 120), state.y);
    _ = widget.update(&state, .{ .release = .card });
    try testing.expect(!state.holdsPress());

    // Resize below compact threshold switches to compact pill without error.
    _ = widget.update(&state, .{ .press = .{ .hit = .resize, .x = state.width, .y = state.height } });
    _ = widget.update(&state, .{ .pointer = .{ .over = .resize, .x = 50, .y = 20 } });
    try testing.expectEqual(widget.min_width, state.width);
    try testing.expectEqual(widget.min_height, state.height);
    _ = widget.update(&state, .{ .release = .resize });

    var fixture: Fixture = .{};
    var tree = fixture.tree();
    const root = (try widget.view(&state, &tree, &Theme.dark)).?;
    try layout(&tree, measurer, 300, 200);
    // Force an out-of-bounds coordinate and verify place clamps it back in.
    state.x = 999;
    state.y = 999;
    widget.place(&state, &tree, root, 300, 200);
    try testing.expectEqual(300 - 4 - widget.min_width, state.x);
    try testing.expectEqual(200 - 4 - widget.min_height, state.y);
}

test "wellbeing_widget: buttons act on release over target and disabled reset is ignored" {
    var state: widget.State = .empty;
    _ = widget.update(&state, .toggle_visible);

    // Idle phase disables reset button.
    try testing.expectEqual(widget.Outcome.quiet, widget.update(&state, .{ .press = .{ .hit = .reset, .x = 10, .y = 10 } }));
    try testing.expect(!state.holdsPress());

    // Play/pause fires toggle on release over play_pause.
    _ = widget.update(&state, .{ .press = .{ .hit = .play_pause, .x = 10, .y = 10 } });
    try testing.expectEqual(widget.Outcome{ .action = .toggle }, widget.update(&state, .{ .release = .play_pause }));

    // Dragging off target before release cancels action.
    _ = widget.update(&state, .{ .press = .{ .hit = .skip, .x = 10, .y = 10 } });
    try testing.expectEqual(widget.Outcome.redraw, widget.update(&state, .{ .release = .card }));

    // Close button fires close action.
    _ = widget.update(&state, .{ .press = .{ .hit = .close, .x = 10, .y = 10 } });
    try testing.expectEqual(widget.Outcome{ .action = .close }, widget.update(&state, .{ .release = .close }));
}
