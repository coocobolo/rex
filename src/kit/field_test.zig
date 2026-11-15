const std = @import("std");
const testing = std.testing;

const Theme = @import("Theme.zig");
const field = @import("field.zig");
const switch_control = @import("switch.zig");
const text = @import("text.zig");
const Tree = @import("Tree.zig");

fn measure(_: *anyopaque, bytes: []const u8, _: text.Style, _: text.Figures) f32 {
    return @floatFromInt(bytes.len * 8);
}

var no_state: u8 = 0;
const measurer: text.Measurer = .{ .context = &no_state, .widthFn = measure };

test "field: responsive orientation switches between row and column and renders badge and error" {
    var nodes: [32]Tree.Node = undefined;
    var lines: [16]text.Line = undefined;
    const theme = &Theme.dark;

    // Wide (compact = false): control sits to the right of the label block.
    {
        var tree = Tree.init(&nodes, &lines);
        const f = try field.open(&tree, theme, .{
            .id = .of("field"),
            .label = "Font Size",
            .description = "Point size of the terminal font.",
            .badge = "Restart required",
            .err = "enter a number",
            .orientation = .responsive,
            .compact = false,
        });
        try switch_control.view(&tree, theme, .{ .id = .of("ctrl"), .checked = true });
        try field.close(&tree, theme, f);
        try tree.layout(measurer, 700, 200);

        const ctrl = tree.find(.of("ctrl")).?;
        try testing.expect(ctrl.rect.x > 200);

        var saw_err = false;
        for (tree.items()) |node| {
            if (node.content == .text and std.mem.eql(u8, node.content.text.bytes, "enter a number")) {
                try testing.expectEqual(theme.destructive, node.content.text.color);
                saw_err = true;
            }
        }
        try testing.expect(saw_err);
    }

    // Narrow (compact = true): control stacks below the label block.
    {
        var tree = Tree.init(&nodes, &lines);
        const f = try field.open(&tree, theme, .{
            .id = .of("field"),
            .label = "Font Size",
            .description = "Point size of the terminal font.",
            .orientation = .responsive,
            .compact = true,
        });
        try switch_control.view(&tree, theme, .{ .id = .of("ctrl"), .checked = true });
        try field.close(&tree, theme, f);
        try tree.layout(measurer, 360, 200);

        const ctrl = tree.find(.of("ctrl")).?;
        try testing.expectEqual(@as(f32, 0), ctrl.rect.x);
        try testing.expect(ctrl.rect.y > 0);
    }
}
