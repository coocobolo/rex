const std = @import("std");
const kit = @import("root.zig");
const input = kit.input;
const Theme = kit.Theme;
const Tree = kit.Tree;
const Id = kit.Tree.Id;
const Node = kit.Tree.Node;
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

    try tree.layout(measurer, 300, 200);

    const focused_ring = tree.nodes[1];
    try std.testing.expectEqual(kit.Tree.PointerShape.text, focused_ring.box.pointer);
    try std.testing.expect(focused_ring.box.border.a > 0);
    const expected_h: f32 = @floatFromInt(Theme.control_sm + 2 * Theme.dark.ring_width);
    try std.testing.expectEqual(expected_h, focused_ring.rect.h);

    // Invalid focused ring uses destructive color.
    const invalid_ring_idx = 1 + input.node_max; // focused view with selection emitted 12 nodes
    try std.testing.expectEqual(Id.of("in-invalid"), tree.nodes[invalid_ring_idx].box.id);
    try std.testing.expectEqual(theme.destructive.r, tree.nodes[invalid_ring_idx].box.border.r);

    // Disabled input shows arrow cursor and suppresses ring.
    const disabled_ring_idx = invalid_ring_idx + 5; // ring, face, clip, caret, placeholder
    try std.testing.expectEqual(Id.of("in-disabled"), tree.nodes[disabled_ring_idx].box.id);
    try std.testing.expectEqual(kit.Tree.PointerShape.arrow, tree.nodes[disabled_ring_idx].box.pointer);
    try std.testing.expectEqual(@as(u8, 0), tree.nodes[disabled_ring_idx].box.border.a);
}

test "input view: long focused text scrolls horizontally to keep caret visible" {
    const theme = Theme.dark;
    const long_path = "/home/user/.config/rex/ascii/orbital-crystal-animation.txt";
    var nodes: [64]Node = undefined;
    var lines: [64]Line = undefined;

    // Caret at end: text shifts left so the caret lands inside the clip box.
    {
        var tree = Tree.init(&nodes, &lines);
        const root = try tree.open(.{ .width = .{ .fixed = 220 }, .height = .{ .fixed = 60 } });
        try input.view(&tree, &theme, .{
            .id = Id.of("path-end"),
            .value = long_path,
            .cursor = long_path.len,
            .anchor = long_path.len,
            .focused = true,
            .width = .{ .fixed = 200 },
        });
        tree.close(root);
        try tree.layout(measurer, 220, 60);

        const caret = tree.nodes[tree.scroll_follow].rect;
        const clip = tree.nodes[3].rect; // root(0), ring(1), face(2), clip(3)
        try std.testing.expect(caret.x >= clip.x);
        try std.testing.expect(caret.x + caret.w <= clip.x + clip.w + 0.5);
        const content = tree.nodes[4].rect;
        try std.testing.expect(content.x < clip.x);
    }

    // Caret at start (Home): scroll returns to 0 so the start of the path is visible.
    {
        var tree = Tree.init(&nodes, &lines);
        const root = try tree.open(.{ .width = .{ .fixed = 220 }, .height = .{ .fixed = 60 } });
        try input.view(&tree, &theme, .{
            .id = Id.of("path-home"),
            .value = long_path,
            .cursor = 0,
            .anchor = 0,
            .focused = true,
            .width = .{ .fixed = 200 },
        });
        tree.close(root);
        try tree.layout(measurer, 220, 60);

        const caret = tree.nodes[tree.scroll_follow].rect;
        const clip = tree.nodes[3].rect;
        try std.testing.expectApproxEqAbs(clip.x, caret.x, 0.5);
    }
}

test "input state: word navigation, word selection, and word/line deletion" {
    const gpa = std.testing.allocator;
    var state = try input.State.initText(gpa, "/home/user/foo.txt");
    defer state.deinit(gpa);

    // Jump backward by word/punctuation runs.
    try std.testing.expect(state.apply(.word_left));
    try std.testing.expectEqual(@as(usize, 15), state.cursor); // before "txt"
    try std.testing.expect(state.apply(.word_left));
    try std.testing.expectEqual(@as(usize, 14), state.cursor); // before "."
    try std.testing.expect(state.apply(.word_left));
    try std.testing.expectEqual(@as(usize, 11), state.cursor); // before "foo"

    // Select word right from "foo".
    try std.testing.expect(state.apply(.select_word_right));
    try std.testing.expectEqualStrings("foo", state.selectedText());

    // Delete active selection with delete_word_backward.
    try std.testing.expect(state.apply(.delete_word_backward));
    try std.testing.expectEqualStrings("/home/user/.txt", state.text());

    // Delete word backward removes "/" then "user".
    try std.testing.expect(state.apply(.delete_word_backward));
    try std.testing.expectEqualStrings("/home/user.txt", state.text());
    try std.testing.expect(state.apply(.delete_word_backward));
    try std.testing.expectEqualStrings("/home/.txt", state.text());

    // Delete to start removes "/home/".
    try std.testing.expect(state.apply(.delete_to_start));
    try std.testing.expectEqualStrings(".txt", state.text());
    try std.testing.expectEqual(@as(usize, 0), state.cursor);

    // Delete word forward removes ".", then delete_to_end removes "txt".
    try std.testing.expect(state.apply(.delete_word_forward));
    try std.testing.expectEqualStrings("txt", state.text());
    try std.testing.expect(state.apply(.delete_to_end));
    try std.testing.expectEqualStrings("", state.text());
    try std.testing.expect(!state.apply(.delete_to_end));

    // Whitespace and multi-byte UTF-8 word movement.
    try state.setText(gpa, "café   résumé");
    try std.testing.expect(state.apply(.word_left));
    try std.testing.expectEqualStrings("résumé", state.text()[state.cursor..]);
    try std.testing.expect(state.apply(.select_word_left));
    try std.testing.expectEqualStrings("café   ", state.selectedText());
    try std.testing.expect(state.apply(.home));
    try std.testing.expect(state.apply(.word_right));
    try std.testing.expectEqualStrings("café", state.text()[0..state.cursor]);
}

test "input state: pointer offsetAtX, setCursor, and double-click word drag" {
    const gpa = std.testing.allocator;
    var state = try input.State.initText(gpa, "hello world");
    defer state.deinit(gpa);

    // Fake measurer is 8 px per byte.
    try std.testing.expectEqual(@as(usize, 0), state.offsetAtX(measurer, -5));
    try std.testing.expectEqual(@as(usize, 0), state.offsetAtX(measurer, 0));
    try std.testing.expectEqual(@as(usize, 0), state.offsetAtX(measurer, 3.9));
    try std.testing.expectEqual(@as(usize, 1), state.offsetAtX(measurer, 4.1));
    try std.testing.expectEqual(@as(usize, 5), state.offsetAtX(measurer, 40));
    try std.testing.expectEqual(@as(usize, 11), state.offsetAtX(measurer, 200));

    // Click and drag selection.
    try std.testing.expect(state.setCursor(2, false));
    try std.testing.expect(!state.hasSelection());
    try std.testing.expect(state.setCursor(5, true));
    try std.testing.expectEqualStrings("llo", state.selectedText());

    // Double-click selects "world"; dragging left extends to cover "hello".
    try std.testing.expect(state.selectWordAt(8));
    try std.testing.expectEqualStrings("world", state.selectedText());
    const base = state.selectionRange();
    try std.testing.expect(state.extendWordSelection(base.start, base.end, 1));
    try std.testing.expectEqualStrings("hello world", state.selectedText());

    // Multi-byte UTF-8: offsetAtX snaps strictly to codepoint boundaries.
    try state.setText(gpa, "aéb"); // bytes: 'a'(0), 'é'(1..3), 'b'(3..4)
    const mid_e = state.offsetAtX(measurer, 15.0);
    try std.testing.expect(mid_e == 1 or mid_e == 3);
    try std.testing.expectEqual(@as(usize, 1), state.offsetAtX(measurer, 10.0));
    try std.testing.expectEqual(@as(usize, 3), state.offsetAtX(measurer, 22.0));
}

test "input view: textOriginX tracks unfocused, caret-at-0, centered, and scrolled text" {
    const theme = Theme.dark;
    const long_path = "/home/user/.config/rex/ascii/orbital-crystal-animation.txt";
    var nodes: [64]Node = undefined;
    var lines: [64]Line = undefined;

    // 1. Focused at end (horizontally scrolled left): textOriginX < clip.x.
    {
        var tree = Tree.init(&nodes, &lines);
        const root = try tree.open(.{ .width = .{ .fixed = 220 }, .height = .{ .fixed = 60 } });
        try input.view(&tree, &theme, .{
            .id = Id.of("origin-scroll"),
            .value = long_path,
            .cursor = long_path.len,
            .anchor = long_path.len,
            .focused = true,
            .width = .{ .fixed = 200 },
        });
        tree.close(root);
        try tree.layout(measurer, 220, 60);

        const origin = input.textOriginX(&tree, Id.of("origin-scroll")).?;
        const clip = tree.nodes[3].rect;
        try std.testing.expect(origin < clip.x);
        // Clicking near the right edge of the clip box resolves near the end of long_path.
        var st = try input.State.initText(std.testing.allocator, long_path);
        defer st.deinit(std.testing.allocator);
        const hit_end = st.offsetAtX(measurer, (clip.x + clip.w) - origin);
        try std.testing.expect(hit_end >= long_path.len - 2);
    }

    // 2. Focused at byte 0: visible text stays anchored at byte 0 and never shifts
    // as the caret moves across the string.
    {
        var prev_text_rect: ?Tree.Rect = null;
        for ([_]usize{ 0, 1, 2, 3 }) |cur| {
            var tree = Tree.init(&nodes, &lines);
            const root = try tree.open(.{ .width = .{ .fixed = 220 }, .height = .{ .fixed = 60 } });
            try input.view(&tree, &theme, .{
                .id = Id.of("origin-zero"),
                .value = "abc",
                .cursor = cur,
                .anchor = cur,
                .focused = true,
                .width = .{ .fixed = 160 },
            });
            tree.close(root);
            try tree.layout(measurer, 220, 60);

            const origin = input.textOriginX(&tree, Id.of("origin-zero")).?;
            const text_node = tree.nodes[5].rect; // root(0), ring(1), face(2), clip(3), content(4), text(5)
            try std.testing.expectApproxEqAbs(text_node.x, origin, 0.01);
            if (prev_text_rect) |prev| {
                try std.testing.expectEqual(prev, text_node);
            }
            prev_text_rect = text_node;
            // Caret overlays at exact prefix width without pushing text.
            const caret = tree.nodes[tree.scroll_follow].rect;
            try std.testing.expectApproxEqAbs(origin + @as(f32, @floatFromInt(cur)) * 8.0, caret.x, 0.01);
        }
    }

    // 3. Centered unfocused input: origin matches centered text, not left clip edge.
    {
        var tree = Tree.init(&nodes, &lines);
        const root = try tree.open(.{ .width = .{ .fixed = 220 }, .height = .{ .fixed = 60 } });
        try input.view(&tree, &theme, .{
            .id = Id.of("origin-center"),
            .value = "42",
            .focused = false,
            .center = true,
            .width = .{ .fixed = 160 },
        });
        tree.close(root);
        try tree.layout(measurer, 220, 60);

        const origin = input.textOriginX(&tree, Id.of("origin-center")).?;
        const clip = tree.nodes[3].rect;
        try std.testing.expect(origin > clip.x + 20);
    }
}
