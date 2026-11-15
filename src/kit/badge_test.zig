const std = @import("std");
const testing = std.testing;

const Theme = @import("Theme.zig");
const badge = @import("badge.zig");
const icons = @import("icons.zig");
const text = @import("text.zig");
const Tree = @import("Tree.zig");

fn measurer() text.Measurer {
    const Fixed = struct {
        var unused: u8 = 0;
        fn width(_: *anyopaque, bytes: []const u8, _: text.Style, _: text.Figures) f32 {
            return @floatFromInt(bytes.len * 7);
        }
    };
    return .{ .context = &Fixed.unused, .widthFn = Fixed.width };
}

test "badge: variants map cleanly to theme tokens and respect node_max" {
    const variants = [_]badge.Variant{ .default, .secondary, .muted, .outline, .destructive, .info, .success, .warning };
    const theme = &Theme.dark;

    for (variants) |variant| {
        var nodes: [badge.node_max]Tree.Node = undefined;
        var lines: [1]text.Line = undefined;
        var tree = Tree.init(&nodes, &lines);
        try badge.view(&tree, theme, .{
            .label = "Focus",
            .icon = icons.info,
            .variant = variant,
        });
        try testing.expectEqual(@as(usize, badge.node_max), tree.len);
        try tree.layout(measurer(), 200, 100);
        try testing.expect(tree.nodes[0].rect.w > 0);
        try testing.expectEqual(Theme.radius_sm, tree.nodes[0].box.radius);

        switch (variant) {
            .default => {
                try testing.expectEqual(theme.primary, tree.nodes[0].box.fill);
                try testing.expectEqual(theme.primary_foreground, tree.nodes[2].content.text.color);
            },
            .secondary => {
                try testing.expectEqual(theme.secondary, tree.nodes[0].box.fill);
                try testing.expectEqual(theme.foreground, tree.nodes[2].content.text.color);
            },
            .muted => {
                try testing.expectEqual(theme.muted, tree.nodes[0].box.fill);
                try testing.expectEqual(theme.muted_foreground, tree.nodes[2].content.text.color);
            },
            .outline => {
                try testing.expectEqual(Theme.Color.transparent, tree.nodes[0].box.fill);
                try testing.expectEqual(theme.border, tree.nodes[0].box.border);
                try testing.expectEqual(theme.foreground, tree.nodes[2].content.text.color);
            },
            .destructive => {
                try testing.expectEqual(theme.destructive, tree.nodes[0].box.fill);
                try testing.expectEqual(theme.destructive_foreground, tree.nodes[2].content.text.color);
            },
            .info => {
                try testing.expectEqual(theme.info.alpha(16), tree.nodes[0].box.fill);
                try testing.expectEqual(theme.info_text, tree.nodes[2].content.text.color);
            },
            .success => {
                try testing.expectEqual(theme.success.alpha(16), tree.nodes[0].box.fill);
                try testing.expectEqual(theme.success, tree.nodes[2].content.text.color);
            },
            .warning => {
                try testing.expectEqual(theme.warning.alpha(16), tree.nodes[0].box.fill);
                try testing.expectEqual(theme.warning, tree.nodes[2].content.text.color);
            },
        }
    }
}

test "badge: sizes step padding and typography" {
    var nodes: [badge.node_max * 3]Tree.Node = undefined;
    var lines: [4]text.Line = undefined;
    var tree = Tree.init(&nodes, &lines);

    try badge.view(&tree, &Theme.dark, .{ .label = "Small", .size = .sm });
    try badge.view(&tree, &Theme.dark, .{ .label = "Default", .size = .default });
    try badge.view(&tree, &Theme.dark, .{ .label = "Large", .size = .lg });
    try testing.expectEqual(@as(usize, 6), tree.len);

    try testing.expectEqual(text.Style.xs, tree.nodes[1].content.text.style);
    try testing.expectEqual(text.Style.xs, tree.nodes[3].content.text.style);
    try testing.expectEqual(text.Style.sm_medium, tree.nodes[5].content.text.style);
    try testing.expectEqual(@as(u8, 6), tree.nodes[0].box.padding.left);
    try testing.expectEqual(@as(u8, 8), tree.nodes[2].box.padding.left);
    try testing.expectEqual(@as(u8, 10), tree.nodes[4].box.padding.left);
}
