const std = @import("std");
const kit = @import("root.zig");
const input = kit.input;
const layout = kit.layout;
const Theme = kit.Theme;
const Tree = kit.tree.Tree;
const Id = kit.tree.Id;
const Node = kit.tree.Node;
const Line = kit.text.Line;

fn measure(_: *anyopaque, bytes: []const u8, _: kit.text.Style, _: kit.text.Figures) f32 {
    return @as(f32, @floatFromInt(bytes.len)) * 8.0;
}

var dummy: u8 = 0;
const measurer: kit.text.Measurer = .{ .context = &dummy, .widthFn = measure };

test "input state: insert, UTF-8 navigation, and deletion" {
    const gpa = std.testing.allocator;
    var state = try input.State.initText(gpa, "aéb");
    defer state.deinit(gpa);

    try std.testing.expectEqualStrings("aéb", state.text());
    try std.testing.expectEqual(@as(usize, 4), state.cursor);

    // Control characters are ignored.
    try std.testing.expect(!(try state.insertChar(gpa, '\n')));
    try std.testing.expect(!(try state.insertChar(gpa, 0x03)));
    try std.testing.expectEqualStrings("aéb", state.text());

    // Move left over 'b' then over 2-byte 'é'.
    try std.testing.expect(state.apply(.left));
    try std.testing.expectEqual(@as(usize, 3), state.cursor);
    try std.testing.expect(state.apply(.left));
    try std.testing.expectEqual(@as(usize, 1), state.cursor);

    // Insert 4-byte emoji at cursor, then backspace it.
    try std.testing.expect(try state.insertChar(gpa, '🚀'));
    try std.testing.expectEqualStrings("a🚀éb", state.text());
    try std.testing.expectEqual(@as(usize, 5), state.cursor);

    try std.testing.expect(state.apply(.backspace));
    try std.testing.expectEqualStrings("aéb", state.text());
    try std.testing.expectEqual(@as(usize, 1), state.cursor);

    // Delete forward removes the entire 2-byte 'é'.
    try std.testing.expect(state.apply(.delete));
    try std.testing.expectEqualStrings("ab", state.text());
    try std.testing.expectEqual(@as(usize, 1), state.cursor);

    // Home and End.
    try std.testing.expect(state.apply(.home));
    try std.testing.expectEqual(@as(usize, 0), state.cursor);
    try std.testing.expect(!state.apply(.left));
    try std.testing.expect(state.apply(.end));
    try std.testing.expectEqual(@as(usize, 2), state.cursor);
    try std.testing.expect(!state.apply(.right));
}

test "input state: selection, replace, and paste filtering" {
    const gpa = std.testing.allocator;
    var state = try input.State.initText(gpa, "hello world");
    defer state.deinit(gpa);

    try std.testing.expect(state.apply(.select_home));
    try std.testing.expectEqualStrings("hello world", state.selectedText());

    // Left without Shift collapses selection to start.
    try std.testing.expect(state.apply(.left));
    try std.testing.expect(!state.hasSelection());
    try std.testing.expectEqual(@as(usize, 0), state.cursor);

    // Select "hello" and replace via insertSlice with newlines stripped.
    for (0..5) |_| _ = state.apply(.select_right);
    try std.testing.expectEqualStrings("hello", state.selectedText());
    try std.testing.expect(try state.insertSlice(gpa, "hi\r\nthere\x00"));
    try std.testing.expectEqualStrings("hithere world", state.text());
    try std.testing.expect(!state.hasSelection());

    // Select all and deleteSelection.
    try std.testing.expect(state.apply(.select_all));
    try std.testing.expectEqualStrings("hithere world", state.selectedText());
    try std.testing.expect(state.deleteSelection());
    try std.testing.expectEqualStrings("", state.text());
    try std.testing.expect(!state.deleteSelection());
}

test "input view: node budget, layout, focus, selection, and invalid/disabled states" {
    const theme = Theme.dark;
    var nodes: [64]Node = undefined;
    var lines: [64]Line = undefined;
    var tree = Tree.init(&nodes, &lines);

    const root = try tree.open(.{ .width = .{ .fixed = 300 }, .height = .{ .fixed = 200 } });
    try input.view(&tree, &theme, .{
        .id = Id.of("in-focus"),
        .value = "hello world",
        .cursor = 5,
        .anchor = 2,
        .focused = true,
        .width = .{ .fixed = 200 },
    });
    try std.testing.expect(tree.len <= 1 + input.node_max);
    try input.view(&tree, &theme, .{
        .id = Id.of("in-invalid"),
        .value = "",
        .placeholder = "Type...",
        .focused = true,
        .invalid = true,
    });
    try input.view(&tree, &theme, .{
        .id = Id.of("in-disabled"),
        .value = "locked",
        .focused = true,
        .disabled = true,
    });
    tree.close(root);

    try layout.layout(&tree, measurer, 300, 200);

    const focused_ring = tree.nodes[1];
    try std.testing.expectEqual(kit.tree.PointerShape.text, focused_ring.box.pointer);
    try std.testing.expect(focused_ring.box.border.a > 0);
    const expected_h: f32 = @floatFromInt(Theme.control_sm + 2 * Theme.ring_width);
    try std.testing.expectEqual(expected_h, focused_ring.rect.h);

    // Invalid focused ring uses destructive color.
    const invalid_ring_idx = 1 + 8; // focused view with selection emitted 8 nodes
    try std.testing.expectEqual(Id.of("in-invalid"), tree.nodes[invalid_ring_idx].box.id);
    try std.testing.expectEqual(theme.destructive.r, tree.nodes[invalid_ring_idx].box.border.r);

    // Disabled input shows arrow cursor and suppresses ring.
    const disabled_ring_idx = invalid_ring_idx + 5; // ring, face, clip, caret, placeholder
    try std.testing.expectEqual(Id.of("in-disabled"), tree.nodes[disabled_ring_idx].box.id);
    try std.testing.expectEqual(kit.tree.PointerShape.arrow, tree.nodes[disabled_ring_idx].box.pointer);
    try std.testing.expectEqual(@as(u8, 0), tree.nodes[disabled_ring_idx].box.border.a);
}
