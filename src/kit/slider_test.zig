const std = @import("std");
const testing = std.testing;

const Theme = @import("Theme.zig");
const text = @import("text.zig");
const Tree = @import("Tree.zig");
const slider = @import("slider.zig");

test "Slider: view builds track, thumb, and optional value label within node_max" {
    var nodes: [64]Tree.Node = undefined;
    var lines: [16]text.Line = undefined;
    var t: Tree = .init(&nodes, &lines);
    const theme = Theme.dark;

    try slider.view(&t, &theme, .{
        .id = Tree.Id.of("opacity"),
        .value = 0.5,
        .value_label = "50%",
        .focused = true,
    });
    try testing.expect(t.len <= slider.node_max);
    try testing.expectEqual(@as(usize, 8), t.len);
}

test "Slider: boundary values 0.0 and 1.0 omit empty track segment" {
    var nodes: [64]Tree.Node = undefined;
    var lines: [16]text.Line = undefined;
    const theme = Theme.dark;

    var t0: Tree = .init(&nodes, &lines);
    try slider.view(&t0, &theme, .{
        .id = Tree.Id.of("min"),
        .value = 0.0,
    });
    try testing.expectEqual(@as(usize, 5), t0.len);

    var t1: Tree = .init(&nodes, &lines);
    try slider.view(&t1, &theme, .{
        .id = Tree.Id.of("max"),
        .value = 1.0,
    });
    try testing.expectEqual(@as(usize, 5), t1.len);
}

test "Slider: ratioFromX clamps to [0, 1] across the thumb travel range" {
    const rect: Tree.Rect = .{
        .x = 100,
        .y = 20,
        .w = 180 + Theme.ring_width * 2,
        .h = slider.thumb_size + Theme.ring_width * 2,
    };
    const left_center = rect.x + Theme.ring_width + slider.thumb_size * 0.5;
    const right_center = rect.x + rect.w - Theme.ring_width - slider.thumb_size * 0.5;

    try testing.expectApproxEqAbs(@as(f32, 0.0), slider.ratioFromX(rect, left_center), 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0.0), slider.ratioFromX(rect, 0), 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0.5), slider.ratioFromX(rect, (left_center + right_center) * 0.5), 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 1.0), slider.ratioFromX(rect, right_center), 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 1.0), slider.ratioFromX(rect, 999), 1e-4);
}
