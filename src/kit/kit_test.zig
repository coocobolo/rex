const std = @import("std");
const testing = std.testing;

const Theme = @import("Theme.zig");
const focus = @import("focus.zig");
const motion = @import("motion.zig");
const text = @import("text.zig");
const Tree = @import("Tree.zig");
const Node = Tree.Node;
const Id = Tree.Id;
const layout = @import("layout.zig");

/// A measurer where every byte is 7 pixels wide, so expected sizes can be
/// worked out by hand.
const byte_width = 7;

fn fixedWidth(_: *anyopaque, bytes: []const u8, _: text.Style, _: text.Figures) f32 {
    return @floatFromInt(bytes.len * byte_width);
}

/// `fixedWidth` keeps no state.
var no_state: u8 = 0;
const measurer: text.Measurer = .{ .context = &no_state, .widthFn = fixedWidth };

const Fixture = struct {
    nodes: [64]Node = undefined,
    lines: [64]text.Line = undefined,

    fn tree(self: *Fixture) Tree {
        return .init(&self.nodes, &self.lines);
    }
};

fn expectRect(tree: *const Tree, index: Tree.Index, x: f32, y: f32, w: f32, h: f32) !void {
    const rect = tree.nodes[index].rect;
    errdefer std.debug.print("node {d}: got {d} {d} {d} {d}\n", .{ index, rect.x, rect.y, rect.w, rect.h });
    try testing.expectEqual(x, rect.x);
    try testing.expectEqual(y, rect.y);
    try testing.expectEqual(w, rect.w);
    try testing.expectEqual(h, rect.h);
}

test "Theme: the variant follows how bright the terminal background is" {
    try testing.expectEqual(.dark, Theme.variantFor(.{ 0x10, 0x10, 0x14 }));
    try testing.expectEqual(.dark, Theme.variantFor(.{ 0x00, 0x2b, 0x36 })); // Solarized dark
    try testing.expectEqual(.light, Theme.variantFor(.{ 0xfd, 0xf6, 0xe3 })); // Solarized light
    try testing.expectEqual(.light, Theme.variantFor(.{ 0xff, 0xff, 0xff }));
    // Mid gray is already bright enough for dark text.
    try testing.expectEqual(.light, Theme.variantFor(.{ 0x80, 0x80, 0x80 }));
    try testing.expectEqual(&Theme.dark, Theme.Variant.dark.theme());
    try testing.expectEqual(&Theme.light, Theme.Variant.light.theme());
}

test "Theme: colors and alpha" {
    const c = Theme.Color.rgb(0x2b7fff);
    try testing.expectEqual(0x2b, c.r);
    try testing.expectEqual(0x7f, c.g);
    try testing.expectEqual(0xff, c.b);
    try testing.expectEqual(255, c.a);
    // White at 10%, the dark hairline.
    try testing.expectEqual(26, Theme.dark.border.a);
    try testing.expectEqual(128, Theme.dark.scrim.a);
    try testing.expectEqual(0, Theme.Color.transparent.a);
}

test "Id: names are stable, distinct and never none" {
    try testing.expectEqual(Id.of("toast"), Id.of("toast"));
    try testing.expect(Id.of("toast") != Id.of("dialog"));
    try testing.expect(Id.of("toast") != .none);
    const stack = Id.of("toast");
    try testing.expect(stack.item(0) != stack.item(1));
    try testing.expect(stack.item(0) != stack);
    try testing.expectEqual(stack.item(3), stack.item(3));
}

test "Tree: nodes know their parent and where their descendants end" {
    var fixture: Fixture = .{};
    var tree = fixture.tree();
    const outer = try tree.open(.{});
    const first = try tree.text("a", .{ .color = Theme.dark.foreground });
    const inner = try tree.open(.{});
    const nested = try tree.leaf(.{});
    tree.close(inner);
    tree.close(outer);
    const second_root = try tree.leaf(.{});

    try testing.expectEqual(5, tree.len);
    try testing.expectEqual(Tree.none, tree.nodes[outer].parent);
    try testing.expectEqual(outer, tree.nodes[first].parent);
    try testing.expectEqual(inner, tree.nodes[nested].parent);
    try testing.expectEqual(4, tree.nodes[outer].end);
    try testing.expectEqual(4, tree.nodes[inner].end);
    try testing.expectEqual(2, tree.nodes[first].end);
    try testing.expectEqual(Tree.none, tree.nodes[second_root].parent);
    try testing.expectEqual(Tree.none, tree.current);

    tree.reset();
    try testing.expectEqual(0, tree.len);
}

test "Tree: a full array is an error, not a missing node" {
    var nodes: [2]Node = undefined;
    var lines: [1]text.Line = undefined;
    var tree: Tree = .init(&nodes, &lines);
    _ = try tree.leaf(.{});
    _ = try tree.leaf(.{});
    try testing.expectError(error.OutOfNodes, tree.leaf(.{}));
    try testing.expectError(error.OutOfNodes, tree.text("x", .{ .color = Theme.dark.foreground }));
    try testing.expectEqual(2, tree.len);
}

test "wrap: breaks at spaces and line feeds" {
    var buffer: [8]text.Line = undefined;
    var lines: text.Lines = .init(&buffer);

    // 11 bytes at 7 px is 77 px: fits in 80, not in 70.
    try testing.expectEqual(1, try text.wrap(measurer, "hello world", .sm, .proportional, 80, &lines));
    try testing.expectEqual(text.Line{ .start = 0, .end = 11, .width = 77 }, buffer[0]);

    lines.len = 0;
    try testing.expectEqual(2, try text.wrap(measurer, "hello world", .sm, .proportional, 70, &lines));
    try testing.expectEqual(text.Line{ .start = 0, .end = 5, .width = 35 }, buffer[0]);
    try testing.expectEqual(text.Line{ .start = 6, .end = 11, .width = 35 }, buffer[1]);

    lines.len = 0;
    try testing.expectEqual(3, try text.wrap(measurer, "ab\n\ncd", .sm, .proportional, 1000, &lines));
    try testing.expectEqual(text.Line{ .start = 0, .end = 2, .width = 14 }, buffer[0]);
    try testing.expectEqual(text.Line{ .start = 3, .end = 3, .width = 0 }, buffer[1]);
    try testing.expectEqual(text.Line{ .start = 4, .end = 6, .width = 14 }, buffer[2]);
}

test "wrap: an empty text is one line, and a long word overflows alone" {
    var buffer: [8]text.Line = undefined;
    var lines: text.Lines = .init(&buffer);

    try testing.expectEqual(1, try text.wrap(measurer, "", .sm, .proportional, 100, &lines));
    try testing.expectEqual(text.Line{ .start = 0, .end = 0, .width = 0 }, buffer[0]);

    lines.len = 0;
    try testing.expectEqual(3, try text.wrap(measurer, "a incomprehensible b", .sm, .proportional, 40, &lines));
    try testing.expectEqual(text.Line{ .start = 0, .end = 1, .width = 7 }, buffer[0]);
    try testing.expectEqual(text.Line{ .start = 2, .end = 18, .width = 112 }, buffer[1]);
    try testing.expectEqual(text.Line{ .start = 19, .end = 20, .width = 7 }, buffer[2]);
}

test "wrap: running out of lines is an error" {
    var buffer: [1]text.Line = undefined;
    var lines: text.Lines = .init(&buffer);
    try testing.expectError(error.OutOfLines, text.wrap(measurer, "aa bb", .sm, .proportional, 20, &lines));
}

test "layout: a toast sizes its text column and wraps the description" {
    var fixture: Fixture = .{};
    var tree = fixture.tree();
    const theme = &Theme.dark;

    // A toast: 356 wide, 16 padding, an icon, then title over description.
    const toast = try tree.open(.{ .axis = .row, .width = .{ .fixed = 356 }, .padding = .all(16), .gap = 10, .fill = theme.popover });
    const icon = try tree.icon(.{ .codepoint = @import("icons.zig").info, .color = theme.info, .size = 16 });
    const body = try tree.open(.{ .axis = .column, .width = .fill });
    const title = try tree.text("Copied 3 lines", .{ .color = theme.foreground, .style = .sm_medium });
    // 49 bytes is 343 px, wider than the 298 px column: wraps to two lines.
    const description = try tree.text("Selection is on the clipboard and in the primary.", .{ .color = theme.muted_foreground, .width = .fill });
    tree.close(body);
    tree.close(toast);

    try tree.layout(measurer, 800, 600);

    // Column: 356 - 2*16 padding - 16 icon - 10 gap.
    try expectRect(&tree, body, 42, 16, 298, 60);
    try expectRect(&tree, icon, 16, 16, 16, 16);
    try expectRect(&tree, title, 42, 16, 98, 20);
    try expectRect(&tree, description, 42, 36, 298, 40);
    // Height: three 20 px lines plus padding.
    try expectRect(&tree, toast, 0, 0, 356, 92);

    const wrapped = tree.nodes[description].content.text;
    try testing.expectEqual(2, wrapped.line_count);
    const lines = tree.lines.slice(wrapped.first_line, wrapped.line_count);
    try testing.expectEqualStrings("Selection is on the clipboard and in the", wrapped.bytes[lines[0].start..lines[0].end]);
    try testing.expectEqualStrings("primary.", wrapped.bytes[lines[1].start..lines[1].end]);
}

test "layout: a root that fills the viewport anchors a toast stack bottom right" {
    var fixture: Fixture = .{};
    var tree = fixture.tree();

    const overlay = try tree.open(.{ .width = .fill, .height = .fill, .axis = .column, .main = .end, .cross = .end, .padding = .all(24), .gap = 14 });
    const older = try tree.leaf(.{ .width = .{ .fixed = 356 }, .height = .{ .fixed = 60 } });
    const newer = try tree.leaf(.{ .width = .{ .fixed = 356 }, .height = .{ .fixed = 80 } });
    tree.close(overlay);

    try tree.layout(measurer, 1000, 700);

    try expectRect(&tree, overlay, 0, 0, 1000, 700);
    // Bottom edge at 700 - 24; right edge at 1000 - 24.
    try expectRect(&tree, newer, 620, 596, 356, 80);
    try expectRect(&tree, older, 620, 522, 356, 60);
}

test "layout: a dialog is centered over a scrim, with its actions right-aligned" {
    var fixture: Fixture = .{};
    var tree = fixture.tree();
    const theme = &Theme.light;

    const scrim = try tree.open(.{ .width = .fill, .height = .fill, .main = .center, .cross = .center, .fill = theme.scrim });
    const dialog = try tree.open(.{ .width = .{ .fixed = 420 }, .padding = .all(24), .gap = 16, .fill = theme.popover, .radius = Theme.radius });
    const title = try tree.text("Close this window?", .{ .color = theme.foreground, .style = .lg_semibold });
    const actions = try tree.open(.{ .axis = .row, .width = .fill, .main = .end, .gap = 8 });
    const cancel = try tree.leaf(.{ .width = .{ .fixed = 90 }, .height = .{ .fixed = Theme.control }, .id = .of("cancel") });
    const confirm = try tree.leaf(.{ .width = .{ .fixed = 120 }, .height = .{ .fixed = Theme.control }, .id = .of("confirm") });
    tree.close(actions);
    tree.close(dialog);
    tree.close(scrim);

    try tree.layout(measurer, 1000, 600);

    // Height: 24 + 28 title + 16 gap + 36 actions + 24 = 128.
    try expectRect(&tree, dialog, 290, 236, 420, 128);
    try expectRect(&tree, title, 314, 260, 126, 28);
    try expectRect(&tree, actions, 314, 304, 372, 36);
    // Right-aligned: confirm ends at 314 + 372.
    try expectRect(&tree, confirm, 566, 304, 120, 36);
    try expectRect(&tree, cancel, 468, 304, 90, 36);

    try testing.expectEqual(Id.of("confirm"), tree.hitTest(600, 320));
    try testing.expectEqual(Id.of("cancel"), tree.hitTest(470, 305));
    // Between the buttons, and on the scrim: nothing with an id.
    try testing.expectEqual(Id.none, tree.hitTest(562, 320));
    try testing.expectEqual(Id.none, tree.hitTest(10, 10));
}

test "layout: fill children share what fixed and fit children leave" {
    var fixture: Fixture = .{};
    var tree = fixture.tree();

    const row = try tree.open(.{ .axis = .row, .width = .{ .fixed = 300 }, .height = .{ .fixed = 40 }, .gap = 10, .cross = .center });
    const fixed = try tree.leaf(.{ .width = .{ .fixed = 60 }, .height = .{ .fixed = 20 } });
    const first = try tree.leaf(.{ .width = .fill, .height = .fill });
    const second = try tree.leaf(.{ .width = .fill, .height = .{ .fixed = 10 } });
    tree.close(row);

    try tree.layout(measurer, 800, 600);

    // 300 - 60 - 2 gaps of 10 leaves 220 for two.
    try expectRect(&tree, fixed, 0, 10, 60, 20);
    try expectRect(&tree, first, 70, 0, 110, 40);
    try expectRect(&tree, second, 190, 15, 110, 10);
}

test "layout: a long text in a row gives way and wraps" {
    var fixture: Fixture = .{};
    var tree = fixture.tree();

    const row = try tree.open(.{ .axis = .row, .width = .{ .fixed = 200 }, .gap = 8 });
    const dot = try tree.leaf(.{ .width = .{ .fixed = 8 }, .height = .{ .fixed = 8 } });
    // 30 bytes is 210 px; the row has 200 - 8 - 8 = 184 left.
    const message = try tree.text("Unknown key font.sizee line 14", .{ .color = Theme.dark.foreground });
    tree.close(row);

    try tree.layout(measurer, 800, 600);

    try expectRect(&tree, dot, 0, 0, 8, 8);
    try expectRect(&tree, message, 16, 0, 184, 40);
    try expectRect(&tree, row, 0, 0, 200, 40);
}

test "layout: a root never grows past the viewport" {
    var fixture: Fixture = .{};
    var tree = fixture.tree();
    const banner = try tree.open(.{ .padding = .symmetric(16, 12) });
    const message = try tree.text("a" ** 100, .{ .color = Theme.dark.foreground });
    tree.close(banner);

    try tree.layout(measurer, 320, 200);

    try expectRect(&tree, banner, 0, 0, 320, 44);
    // One unbreakable word: it overflows its 288 px box instead of vanishing.
    try expectRect(&tree, message, 16, 12, 288, 20);
}

test "layout: an at-most size is fixed until its parent is smaller" {
    var fixture: Fixture = .{};
    var tree = fixture.tree();
    const scrim = try tree.open(.{ .width = .fill, .height = .fill, .padding = .all(16), .main = .center, .cross = .center });
    const card = try tree.open(.{ .width = .{ .at_most = 420 }, .padding = .all(24) });
    const body = try tree.text("a" ** 20 ++ " " ++ "b" ** 20, .{ .color = Theme.dark.foreground, .width = .fill });
    tree.close(card);
    tree.close(scrim);

    try tree.layout(measurer, 800, 600);
    try expectRect(&tree, card, 190, 266, 420, 68);
    try expectRect(&tree, body, 214, 290, 372, 20);

    // Narrower than the card: it keeps the scrim's padding on both sides
    // and its text wraps to what is left.
    try tree.layout(measurer, 300, 600);
    try expectRect(&tree, card, 16, 256, 268, 88);
    try expectRect(&tree, body, 40, 280, 220, 40);
}

test "layout: tabular figures are measured with the tabular width" {
    const Figured = struct {
        var unused: u8 = 0;
        fn width(_: *anyopaque, bytes: []const u8, _: text.Style, figures: text.Figures) f32 {
            const each: usize = if (figures == .tabular) 10 else 4;
            return @floatFromInt(bytes.len * each);
        }
    };
    const figured: text.Measurer = .{ .context = &Figured.unused, .widthFn = Figured.width };

    var fixture: Fixture = .{};
    var tree = fixture.tree();
    const value = try tree.text("12", .{ .color = Theme.dark.foreground, .style = .xl_semibold, .figures = .tabular });
    try tree.layout(figured, 800, 600);
    // Two digits at 10 px, and the 24 / 32 card style.
    try expectRect(&tree, value, 0, 0, 20, 32);
}

test "layout: an at-least size follows its content down to a minimum" {
    var fixture: Fixture = .{};
    var tree = fixture.tree();
    const row = try tree.open(.{ .axis = .row, .gap = 4 });
    const narrow = try tree.open(.{ .width = .{ .at_least = 20 }, .padding = .symmetric(6, 2), .cross = .center });
    const letter = try tree.text("P", .{ .color = Theme.dark.foreground });
    tree.close(narrow);
    const wide = try tree.open(.{ .width = .{ .at_least = 20 }, .padding = .symmetric(6, 2) });
    _ = try tree.text("Shift", .{ .color = Theme.dark.foreground });
    tree.close(wide);
    tree.close(row);

    try tree.layout(measurer, 800, 600);

    // 7 + 12 = 19 is under the minimum; the letter is centered in the 20.
    try expectRect(&tree, narrow, 0, 0, 20, 24);
    try expectRect(&tree, letter, 6.5, 2, 7, 20);
    try expectRect(&tree, wide, 24, 0, 47, 24);
}

test "layout: an at-most child in a row gives way like a fit child" {
    var fixture: Fixture = .{};
    var tree = fixture.tree();
    const row = try tree.open(.{ .axis = .row, .width = .{ .fixed = 300 }, .gap = 10 });
    const label = try tree.leaf(.{ .width = .{ .fixed = 100 }, .height = .{ .fixed = 20 } });
    const field = try tree.leaf(.{ .width = .{ .at_most = 240 }, .height = .{ .fixed = 20 } });
    tree.close(row);

    try tree.layout(measurer, 800, 600);

    try expectRect(&tree, label, 0, 0, 100, 20);
    try expectRect(&tree, field, 110, 0, 190, 20);
}

test "layout: shrink = false keeps a box at its intrinsic size on overflow" {
    var fixture: Fixture = .{};
    var tree = fixture.tree();

    // Badge-sized non-shrinking pill is wider (80) than the sibling text (49),
    // yet overflow (129 + 8 - 100 = 37) must come from the shrinkable text.
    const row = try tree.open(.{ .axis = .row, .width = .{ .fixed = 100 }, .gap = 8 });
    const pill = try tree.open(.{ .axis = .row, .padding = .symmetric(8, 2), .shrink = false });
    const pill_text = try tree.text("FocusOk", .{ .color = Theme.dark.foreground }); // 49 + 16 = 65
    tree.close(pill);
    const label = try tree.text("Status", .{ .color = Theme.dark.foreground }); // 42
    tree.close(row);

    try tree.layout(measurer, 400, 400);

    try expectRect(&tree, pill, 0, 0, 65, 24);
    try expectRect(&tree, pill_text, 8, 2, 49, 20);
    // 100 - 65 - 8 = 27 left for "Status" (42 -> 27).
    try expectRect(&tree, label, 73, 0, 27, 20);
}

test "layout: when all overflowing children have shrink = false none compress" {
    var fixture: Fixture = .{};
    var tree = fixture.tree();

    const row = try tree.open(.{ .axis = .row, .width = .{ .fixed = 80 }, .height = .{ .fixed = 16 }, .gap = 8 });
    const a = try tree.open(.{ .padding = .symmetric(6, 2), .shrink = false });
    _ = try tree.text("First", .{ .color = Theme.dark.foreground }); // 35 + 12 = 47, h = 24
    tree.close(a);
    const b = try tree.open(.{ .padding = .symmetric(6, 2), .shrink = false });
    _ = try tree.text("Second", .{ .color = Theme.dark.foreground }); // 42 + 12 = 54, h = 24
    tree.close(b);
    tree.close(row);

    try tree.layout(measurer, 400, 400);

    // Neither main-axis (47 + 8 + 54 > 80) nor cross-axis (24 > 16) compresses.
    try expectRect(&tree, a, 0, 0, 47, 24);
    try expectRect(&tree, b, 55, 0, 54, 24);
}

test "snap: shared edges stay shared and hairlines stay visible at fractional scales" {
    const left: Tree.Rect = .{ .x = 0, .y = 0, .w = 10.5, .h = 13 };
    const right: Tree.Rect = .{ .x = 10.5, .y = 0, .w = 10.5, .h = 13 };
    for ([_]f32{ 1, 1.25, 1.5, 1.75, 2 }) |scale| {
        const a = layout.snap(left, scale);
        const b = layout.snap(right, scale);
        try testing.expectEqual(a.x + a.w, b.x);
        try testing.expectEqual(1, layout.strokePixels(1, scale) / @as(u32, @intFromFloat(@round(scale))));
    }
    try testing.expectEqual(layout.PixelRect{ .x = 5, .y = 3, .w = 445, .h = 115 }, layout.snap(.{ .x = 4, .y = 2, .w = 356, .h = 92 }, 1.25));
    try testing.expectEqual(1, layout.strokePixels(1, 1.25));
    try testing.expectEqual(2, layout.strokePixels(1, 1.5));
    try testing.expectEqual(4, layout.strokePixels(3, 1.25));
    try testing.expectEqual(0, layout.strokePixels(0, 2));
}

test "sizes of the kit's types" {
    // Reported in the ticket; a change here is a layout change to look at.
    try testing.expectEqual(4, @sizeOf(Theme.Color));
    try testing.expectEqual(108, @sizeOf(Theme));
    try testing.expectEqual(12, @sizeOf(text.Line));
    try testing.expectEqual(104, @sizeOf(Node));
    try testing.expectEqual(8, @alignOf(Node));
    try testing.expectEqual(44, @sizeOf(Tree.Box));
    try testing.expectEqual(32, @sizeOf(Tree.Text));
    try testing.expectEqual(40, @sizeOf(Tree.Node.Content));
    try testing.expectEqual(16, @sizeOf(Tree.Rect));
    try testing.expectEqual(8, @sizeOf(Tree.Size));
    try testing.expectEqual(24, @sizeOf(Tree.Scroll.Region));
    try testing.expectEqual(16, @sizeOf(Tree.Anchor));
    try testing.expectEqual(304, @sizeOf(Tree));
}

test "tree: a node a clipping ancestor cuts away is not hit there" {
    var nodes: [4]Tree.Node = undefined;
    var lines: [1]text.Line = undefined;
    var tree = Tree.init(&nodes, &lines);
    const inner = Tree.Id.of("test.inner");
    const outer = Tree.Id.of("test.outer");
    const box = try tree.open(.{ .id = outer, .width = .{ .fixed = 50 }, .height = .{ .fixed = 50 }, .overflow = .clip });
    _ = try tree.leaf(.{ .id = inner, .width = .{ .fixed = 200 }, .height = .{ .fixed = 20 } });
    tree.close(box);
    try tree.layout(measurer, 400, 400);
    try testing.expectEqual(inner, tree.hitTest(10, 10));
    try testing.expectEqual(Tree.Id.none, tree.hitTest(100, 10));

    tree.nodes[box].box.overflow = .visible;
    try testing.expectEqual(inner, tree.hitTest(100, 10));
}

test "tree: hitTest centers arc testing vertically by rect.h rather than rect.w" {
    var nodes: [4]Node = undefined;
    var lines: [1]text.Line = undefined;
    var tree = Tree.init(&nodes, &lines);
    const id = Id.of("test.arc");
    const root = try tree.open(.{ .width = .{ .fixed = 100 }, .height = .{ .fixed = 200 } });
    // Rect is 100x200 so center is (50, 100), not (50, 50). Ring r in [15, 25].
    _ = try tree.arc(
        .{ .fill = Theme.dark.accent, .radius = 25, .thickness = 10, .sweep = std.math.tau },
        .{ .id = id, .width = .{ .fixed = 100 }, .height = .{ .fixed = 200 } },
    );
    tree.close(root);
    try tree.layout(measurer, 400, 400);

    // Point on top of ring around (50, 100): y = 100 - 20 = 80.
    try testing.expectEqual(id, tree.hitTest(50, 80));
    // Point at y = 30 would be inside a ring centered at (50, 50), outside (50, 100).
    try testing.expectEqual(Id.none, tree.hitTest(50, 30));
}

/// A 100-high clipping region over three rows of 60: 80 of content below.
fn scrolled(fixture: *Fixture, offset: f32) !Tree {
    var tree = fixture.tree();
    const region = try tree.open(.{ .width = .{ .fixed = 50 }, .height = .{ .fixed = 100 }, .overflow = .clip });
    try tree.scrollRegion(region, .{ .y = offset });
    for (0..3) |index| {
        _ = try tree.leaf(.{ .id = Id.of("row").item(@intCast(index)), .width = .fill, .height = .{ .fixed = 60 } });
    }
    tree.close(region);
    try tree.layout(measurer, 400, 400);
    return tree;
}

test "layout: a scroll region moves its content up, capped at what is below" {
    var fixture: Fixture = .{};
    var tree = try scrolled(&fixture, 50);
    try testing.expectEqual(80, tree.scrollMax(.none).y);
    try expectRect(&tree, 0, 0, 0, 50, 100);
    try expectRect(&tree, 1, 0, -50, 50, 60);
    try expectRect(&tree, 3, 0, 70, 50, 60);
    // The first row is cut at the region's top edge: no hit above it.
    try testing.expectEqual(Id.of("row").item(0), tree.hitTest(10, 5));
    try testing.expectEqual(Id.none, tree.hitTest(10, -20));

    tree = try scrolled(&fixture, 500);
    try expectRect(&tree, 1, 0, -80, 50, 60);
    tree = try scrolled(&fixture, -10);
    try expectRect(&tree, 1, 0, 0, 50, 60);
}

test "layout: content shorter than its region does not scroll" {
    var fixture: Fixture = .{};
    var tree = fixture.tree();
    const region = try tree.open(.{ .width = .{ .fixed = 50 }, .height = .{ .fixed = 100 }, .overflow = .clip });
    try tree.scrollRegion(region, .{ .y = 30 });
    _ = try tree.leaf(.{ .width = .fill, .height = .{ .fixed = 60 } });
    tree.close(region);
    try tree.layout(measurer, 400, 400);
    try testing.expectEqual(0, tree.scrollMax(.none).y);
    try expectRect(&tree, 1, 0, 0, 50, 60);
    tree.reset();
    try testing.expectEqual(0, tree.scroll_len);
}

test "layout: in a scroll region a fill child keeps its content's height" {
    var fixture: Fixture = .{};
    var tree = fixture.tree();
    const region = try tree.open(.{ .width = .{ .fixed = 50 }, .height = .{ .fixed = 100 }, .overflow = .clip });
    try tree.scrollRegion(region, .{});
    _ = try tree.leaf(.{ .width = .fill, .height = .{ .fixed = 70 } });
    const grows = try tree.open(.{ .width = .fill, .height = .fill });
    _ = try tree.leaf(.{ .width = .fill, .height = .{ .fixed = 60 } });
    tree.close(grows);
    tree.close(region);
    try tree.layout(measurer, 400, 400);
    // 30 is left for it, but its content needs 60: it scrolls instead.
    try expectRect(&tree, 2, 0, 70, 50, 60);
    try testing.expectEqual(30, tree.scrollMax(.none).y);
}

test "layout: in a scroll region a fill child still takes the room left" {
    var fixture: Fixture = .{};
    var tree = fixture.tree();
    const region = try tree.open(.{ .width = .{ .fixed = 50 }, .height = .{ .fixed = 100 }, .overflow = .clip });
    try tree.scrollRegion(region, .{});
    _ = try tree.leaf(.{ .width = .fill, .height = .fill });
    tree.close(region);
    try tree.layout(measurer, 400, 400);
    try expectRect(&tree, 1, 0, 0, 50, 100);
    try testing.expectEqual(0, tree.scrollMax(.none).y);
}

test "Theme: ColorScheme auto follows the background, others force a variant" {
    const white = [3]u8{ 255, 255, 255 };
    const black = [3]u8{ 0, 0, 0 };
    try testing.expectEqual(Theme.Variant.light, Theme.ColorScheme.auto.variant(white));
    try testing.expectEqual(Theme.Variant.dark, Theme.ColorScheme.auto.variant(black));
    try testing.expectEqual(Theme.Variant.dark, Theme.ColorScheme.dark.variant(white));
    try testing.expectEqual(Theme.Variant.light, Theme.ColorScheme.light.variant(black));
}

test "Theme: relativeLuminance matches WCAG 2.x benchmarks" {
    try testing.expectEqual(0, Theme.relativeLuminance(.{ 0, 0, 0 }));
    try testing.expectApproxEqAbs(1, Theme.relativeLuminance(.{ 255, 255, 255 }), 1e-4);
    // Mid gray #808080 is about 0.216.
    try testing.expectApproxEqAbs(0.2159, Theme.relativeLuminance(.{ 0x80, 0x80, 0x80 }), 1e-3);
}

test "focus: move wraps at ends and enters cleanly from none" {
    const none = 3;
    try testing.expectEqual(0, focus.move(none, 3, .next));
    try testing.expectEqual(2, focus.move(none, 3, .previous));
    try testing.expectEqual(1, focus.move(0, 3, .next));
    try testing.expectEqual(0, focus.move(2, 3, .next));
    try testing.expectEqual(2, focus.move(0, 3, .previous));
    try testing.expectEqual(1, focus.move(2, 3, .previous));
    try testing.expectEqual(0, focus.move(0, 1, .next));
    try testing.expectEqual(0, focus.move(0, 1, .previous));
}

test "motion: progress eases out for full motion and snaps for none" {
    try testing.expectEqual(0, motion.progress(.full, 0));
    try testing.expectEqual(0.875, motion.progress(.full, Theme.duration / 2));
    try testing.expectEqual(1, motion.progress(.full, Theme.duration));
    try testing.expectEqual(1, motion.progress(.full, 60_000));
    try testing.expectEqual(1, motion.progress(.none, 0));
    try testing.expectEqual(0, motion.duration(.none));
}

test "layout: fit_at_most hugs smaller content, caps at max, and gives way to a tighter parent" {
    var fixture: Fixture = .{};
    var tree = fixture.tree();

    // Small content (40x24 + padding 16 = 56x40) hugs below the 200x120 cap.
    const small = try tree.open(.{ .width = .{ .fit_at_most = 200 }, .height = .{ .fit_at_most = 120 }, .padding = .all(8) });
    _ = try tree.leaf(.{ .width = .{ .fixed = 40 }, .height = .{ .fixed = 24 } });
    tree.close(small);
    try tree.layout(measurer, 800, 600);
    try expectRect(&tree, small, 0, 0, 56, 40);

    // Tall/wide scroll content (300x300) caps at 200x120 and reports scroll_max = 180.
    tree = fixture.tree();
    const scroll_box = try tree.open(.{
        .width = .{ .fit_at_most = 200 },
        .height = .{ .fit_at_most = 120 },
        .overflow = .clip,
    });
    _ = try tree.leaf(.{ .width = .{ .fixed = 300 }, .height = .{ .fixed = 300 } });
    tree.close(scroll_box);
    try tree.scrollRegion(scroll_box, .{ .y = 30 });
    try tree.layout(measurer, 800, 600);
    try expectRect(&tree, scroll_box, 0, 0, 200, 120);
    try testing.expectEqual(@as(f32, 180), tree.scrollMax(.none).y);
    try testing.expectEqual(@as(f32, 100), tree.scrollMax(.none).x);

    // Parent narrower than the hugged/capped size shrinks it unless shrink = false.
    tree = fixture.tree();
    const row = try tree.open(.{ .axis = .row, .width = .{ .fixed = 100 }, .gap = 10 });
    const left = try tree.leaf(.{ .width = .{ .fixed = 60 }, .height = .{ .fixed = 20 } });
    const right = try tree.open(.{ .width = .{ .fit_at_most = 200 }, .height = .{ .fixed = 20 } });
    _ = try tree.leaf(.{ .width = .{ .fixed = 80 }, .height = .{ .fixed = 20 } });
    tree.close(right);
    tree.close(row);
    try tree.layout(measurer, 800, 600);
    try expectRect(&tree, left, 0, 0, 60, 20);
    try expectRect(&tree, right, 70, 0, 30, 20);
}

test "layout: fit_at_most text hugs short strings and wraps once past max" {
    var fixture: Fixture = .{};
    var tree = fixture.tree();
    const col = try tree.open(.{});
    // 4 bytes * 7 = 28 px < 100 cap -> single line of width 28.
    const short = try tree.text("okay", .{ .color = Theme.dark.foreground, .width = .{ .fit_at_most = 100 } });
    // Two 10-byte words = 147 px > 100 cap -> capped at 100 and wrapped to 2 lines (40 px high).
    const long = try tree.text("a" ** 10 ++ " " ++ "b" ** 10, .{ .color = Theme.dark.foreground, .width = .{ .fit_at_most = 100 } });
    tree.close(col);
    try tree.layout(measurer, 800, 600);
    try expectRect(&tree, short, 0, 0, 28, 20);
    try expectRect(&tree, long, 0, 20, 100, 40);
}

test "text: wrapNone keeps spaces on one line and splits only on newlines" {
    var buffer: [8]text.Line = undefined;
    var lines = text.Lines.init(&buffer);
    try testing.expectEqual(2, try text.wrapNone(measurer, "one two three\nfour five", .sm, .proportional, &lines));
    const got = lines.slice(0, 2);
    try testing.expectEqualStrings("one two three", "one two three\nfour five"[got[0].start..got[0].end]);
    try testing.expectEqual(@as(f32, 13 * 7), got[0].width);
    try testing.expectEqualStrings("four five", "one two three\nfour five"[got[1].start..got[1].end]);
    try testing.expectEqual(@as(f32, 9 * 7), got[1].width);
}

test "text: wrapEllipsis truncates at UTF-8 codepoint boundaries and avoids overdraw when narrower than ellipsis" {
    // Fake measurer counting 10 px per decoded UTF-8 codepoint.
    const CodepointMeasurer = struct {
        var unused: u8 = 0;
        fn width(_: *anyopaque, bytes: []const u8, _: text.Style, _: text.Figures) f32 {
            var iter = text.Codepoints.init(bytes);
            var count: usize = 0;
            while (iter.next()) |_| count += 1;
            return @floatFromInt(count * 10);
        }
    };
    const cp_measurer: text.Measurer = .{ .context = &CodepointMeasurer.unused, .widthFn = CodepointMeasurer.width };

    var buffer: [8]text.Line = undefined;
    var lines = text.Lines.init(&buffer);

    // Fits without truncation -> end == len.
    try testing.expectEqual(1, try text.wrapEllipsis(cp_measurer, "abc", .sm, .proportional, 30, &lines));
    try testing.expectEqual(@as(u32, 3), lines.slice(0, 1)[0].end);

    // Multi-byte UTF-8: "a\u{1F600}bc" is 4 glyphs (40 px). At max_width = 30,
    // budget after "…" (10 px) is 20 px -> keeps "a\u{1F600}" (5 bytes) without splitting U+1F600.
    lines.len = 0;
    const utf8_sample = "a\u{1F600}bc";
    try testing.expectEqual(1, try text.wrapEllipsis(cp_measurer, utf8_sample, .sm, .proportional, 30, &lines));
    const trunc = lines.slice(0, 1)[0];
    try testing.expectEqualStrings("a\u{1F600}", utf8_sample[trunc.start..trunc.end]);
    try testing.expectEqual(@as(f32, 30), trunc.width);

    // Explicit newline forces truncation even when first line fits easily.
    lines.len = 0;
    try testing.expectEqual(1, try text.wrapEllipsis(cp_measurer, "ok\nnext", .sm, .proportional, 100, &lines));
    const nl_trunc = lines.slice(0, 1)[0];
    try testing.expectEqualStrings("ok", "ok\nnext"[nl_trunc.start..nl_trunc.end]);
    try testing.expectEqual(@as(f32, 30), nl_trunc.width);

    // Narrower than "…" (10 px): emits empty 0-width line so no overdraw occurs.
    lines.len = 0;
    try testing.expectEqual(1, try text.wrapEllipsis(cp_measurer, "hello", .sm, .proportional, 5, &lines));
    const tiny = lines.slice(0, 1)[0];
    try testing.expectEqual(@as(u32, 0), tiny.end);
    try testing.expectEqual(@as(f32, 0), tiny.width);
}

test "layout: text wrap = .none and .ellipsis stay single-line in constrained boxes" {
    var fixture: Fixture = .{};
    var tree = fixture.tree();

    const col = try tree.open(.{ .width = .{ .fixed = 70 } });
    const t_none = try tree.text("alpha beta gamma", .{ .color = Theme.dark.foreground, .wrap = .none, .width = .fill });
    const t_ell = try tree.text("alpha beta gamma", .{ .color = Theme.dark.foreground, .wrap = .ellipsis, .width = .fill });
    tree.close(col);

    try tree.layout(measurer, 400, 200);
    try expectRect(&tree, t_none, 0, 0, 70, 20);
    try expectRect(&tree, t_ell, 0, 20, 70, 20);
    try testing.expectEqual(@as(u32, 1), tree.nodes[t_none].content.text.line_count);
    try testing.expectEqual(@as(u32, 1), tree.nodes[t_ell].content.text.line_count);
    const ell_line = tree.lines.slice(tree.nodes[t_ell].content.text.first_line, 1)[0];
    try testing.expect(ell_line.width <= 70);
}

test "layout: Box.wrap breaks row items across lines, sums line heights, and aligns per line" {
    var fixture: Fixture = .{};
    var tree = fixture.tree();

    const row = try tree.open(.{
        .axis = .row,
        .wrap = true,
        .width = .{ .fixed = 120 },
        .padding = .all(10), // inner_w = 100
        .gap = 8,
        .main = .end,
        .cross = .center,
    });
    const ov = try tree.leaf(.{ .overlay = true, .width = .{ .fixed = 10 }, .height = .{ .fixed = 10 } });
    // Line 1: 40 + 8 + 50 = 98 <= 100 (line height 30; item a vertically centered -> y + 5).
    const a = try tree.leaf(.{ .width = .{ .fixed = 40 }, .height = .{ .fixed = 20 } });
    const b = try tree.leaf(.{ .width = .{ .fixed = 50 }, .height = .{ .fixed = 30 } });
    // Line 2: 98 + 8 + 45 > 100 -> breaks; 45 + 8 + 30 = 83 <= 100 (line height 24).
    const c = try tree.leaf(.{ .width = .{ .fixed = 45 }, .height = .{ .fixed = 24 } });
    const d = try tree.leaf(.{ .width = .{ .fixed = 30 }, .height = .{ .fixed = 16 } });
    tree.close(row);

    try tree.layout(measurer, 400, 400);

    // Height: 10 + 30 + 8 + 24 + 10 = 82.
    try expectRect(&tree, row, 0, 0, 120, 82);
    try expectRect(&tree, ov, 10, 10, 100, 62);
    // Line 1 right-aligned within [10, 110]: free = 100 - 98 = 2 -> starts at 12.
    try expectRect(&tree, a, 12, 15, 40, 20);
    try expectRect(&tree, b, 60, 10, 50, 30);
    // Line 2 starts at y = 10 + 30 + 8 = 48; right-aligned: free = 100 - 83 = 17 -> starts at 27.
    try expectRect(&tree, c, 27, 48, 45, 24);
    try expectRect(&tree, d, 80, 52, 30, 16);
}

test "layout: Box.wrap keeps fill children full-width and wraps shrinkable long text" {
    var fixture: Fixture = .{};
    var tree = fixture.tree();

    const row = try tree.open(.{
        .axis = .row,
        .wrap = true,
        .width = .{ .fixed = 100 },
        .gap = 6,
    });
    const tag = try tree.open(.{ .padding = .symmetric(4, 2), .shrink = false });
    _ = try tree.text("Tag", .{ .color = Theme.dark.foreground, .wrap = .none }); // 21 + 8 = 29, h = 24
    tree.close(tag);
    // 10 * 7 + 7 + 10 * 7 = 147 > 100 -> breaks to line 2, clamps to 100, and wraps to 2 lines (h = 40).
    const note = try tree.text("a" ** 10 ++ " " ++ "b" ** 10, .{ .color = Theme.dark.foreground });
    // .fill child receives full 100 width on its own line 3.
    const rule = try tree.leaf(.{ .width = .fill, .height = .{ .fixed = 2 } });
    tree.close(row);

    try tree.layout(measurer, 400, 400);

    try expectRect(&tree, row, 0, 0, 100, 24 + 6 + 40 + 6 + 2);
    try expectRect(&tree, tag, 0, 0, 29, 24);
    try expectRect(&tree, note, 0, 30, 100, 40);
    try expectRect(&tree, rule, 0, 76, 100, 2);
}

test "layout: multi-region x/y scroll isolates offsets, stacks nested regions, and rejects overflow capacity" {
    var fixture: Fixture = .{};
    var tree = fixture.tree();

    const outer_id = Id.of("scroll.outer");
    const inner_id = Id.of("scroll.inner");
    const child_id = Id.of("scroll.child");

    const outer = try tree.open(.{
        .id = outer_id,
        .width = .{ .fixed = 200 },
        .height = .{ .fixed = 150 },
        .overflow = .clip,
    });
    _ = try tree.leaf(.{ .width = .{ .fixed = 100 }, .height = .{ .fixed = 100 } });
    const inner = try tree.open(.{
        .id = inner_id,
        .axis = .row,
        .width = .{ .fixed = 180 },
        .height = .{ .fixed = 120 },
        .overflow = .clip,
    });
    const wide_child = try tree.leaf(.{
        .id = child_id,
        .width = .{ .fixed = 300 },
        .height = .{ .fixed = 50 },
    });
    tree.close(inner);
    try tree.scrollRegion(inner, .{ .x = 40 });
    tree.close(outer);
    // Registered after close(outer): insertion keeps ascending node order.
    try tree.scrollRegion(outer, .{ .y = 30 });

    try tree.layout(measurer, 400, 400);

    try testing.expectEqual(@as(f32, 0), tree.scrollMax(outer_id).x);
    try testing.expectEqual(@as(f32, 70), tree.scrollMax(outer_id).y);
    try testing.expectEqual(@as(f32, 120), tree.scrollMax(inner_id).x);
    try testing.expectEqual(@as(f32, 0), tree.scrollMax(inner_id).y);

    // Outer shifted y by -30; inner's child shifted both outer (-30 y) and inner (-40 x).
    try expectRect(&tree, inner, 0, 70, 180, 120);
    try expectRect(&tree, wide_child, -40, 70, 300, 50);

    // Registering beyond Scroll.max returns OutOfScrollRegions cleanly.
    tree = fixture.tree();
    const root = try tree.open(.{ .width = .fill, .height = .fill });
    for (0..Tree.Scroll.max) |i| {
        const box = try tree.open(.{ .id = Id.of("cap").item(@intCast(i)), .width = .{ .fixed = 20 }, .height = .{ .fixed = 20 }, .overflow = .clip });
        tree.close(box);
        try tree.scrollRegion(box, .{});
    }
    const extra = try tree.open(.{ .id = Id.of("cap.extra"), .width = .{ .fixed = 20 }, .height = .{ .fixed = 20 }, .overflow = .clip });
    tree.close(extra);
    try testing.expectError(error.OutOfScrollRegions, tree.scrollRegion(extra, .{}));
    tree.close(root);
}

test "tree: scrollTargetAt picks deepest unoccluded region, chains orthogonal axes, and blocks behind scrims" {
    var fixture: Fixture = .{};
    var tree = fixture.tree();

    const outer_id = Id.of("target.outer");
    const strip_id = Id.of("target.strip");
    const scrim_id = Id.of("target.scrim");

    // Root 0: vertical outer region with a nested horizontal strip.
    const outer = try tree.open(.{
        .id = outer_id,
        .width = .{ .fixed = 200 },
        .height = .{ .fixed = 150 },
        .overflow = .clip,
    });
    const strip = try tree.open(.{
        .id = strip_id,
        .axis = .row,
        .width = .{ .fixed = 160 },
        .height = .{ .fixed = 50 },
        .overflow = .clip,
    });
    _ = try tree.leaf(.{ .width = .{ .fixed = 300 }, .height = .{ .fixed = 40 } });
    tree.close(strip);
    _ = try tree.leaf(.{ .width = .fill, .height = .{ .fixed = 200 } });
    tree.close(outer);
    try tree.scrollRegion(outer, .{});
    try tree.scrollRegion(strip, .{});
    try tree.layout(measurer, 400, 400);

    // Horizontal wheel over nested strip hits strip; vertical wheel chains out to outer.
    try testing.expectEqual(strip_id, tree.scrollTargetAt(40, 20, 48, 0).?.id);
    try testing.expectEqual(outer_id, tree.scrollTargetAt(40, 20, 0, 48).?.id);
    // Vertical wheel below strip hits outer; zero delta returns null.
    try testing.expectEqual(outer_id, tree.scrollTargetAt(40, 100, 0, 48).?.id);
    try testing.expectEqual(@as(?Tree.Scroll.Region, null), tree.scrollTargetAt(40, 100, 0, 0));

    // A non-interactive tooltip (id == .none) above outer does not block wheel scrolling.
    tree = fixture.tree();
    const page = try tree.open(.{ .id = outer_id, .width = .{ .fixed = 200 }, .height = .{ .fixed = 150 }, .overflow = .clip });
    _ = try tree.leaf(.{ .width = .fill, .height = .{ .fixed = 300 } });
    tree.close(page);
    try tree.scrollRegion(page, .{});
    const tip = try tree.open(.{ .width = .{ .fixed = 100 }, .height = .{ .fixed = 60 } });
    tree.close(tip);
    try tree.layout(measurer, 400, 400);
    try testing.expectEqual(outer_id, tree.scrollTargetAt(50, 30, 0, 48).?.id);

    // An interactive overlay scrim (id != .none) drawn after page occludes wheel events on it.
    tree = fixture.tree();
    const bg = try tree.open(.{ .id = outer_id, .width = .{ .fixed = 200 }, .height = .{ .fixed = 150 }, .overflow = .clip });
    _ = try tree.leaf(.{ .width = .fill, .height = .{ .fixed = 300 } });
    tree.close(bg);
    try tree.scrollRegion(bg, .{});
    _ = try tree.leaf(.{ .id = scrim_id, .width = .fill, .height = .fill });
    try tree.layout(measurer, 400, 400);
    try testing.expectEqual(@as(?Tree.Scroll.Region, null), tree.scrollTargetAt(50, 30, 0, 48));
}

test "tree: ensureVisible brings targets into padded bounds and handles narrow or oversized targets" {
    // 1D axis checks.
    try testing.expectEqual(@as(f32, 100), Tree.Scroll.ensureVisibleAxis(100, 300, 0, 200, 50, 40, 24));
    try testing.expectEqual(@as(f32, 64), Tree.Scroll.ensureVisibleAxis(100, 300, 0, 200, -12, 40, 24));
    try testing.expectEqual(@as(f32, 184), Tree.Scroll.ensureVisibleAxis(100, 300, 0, 200, 220, 40, 24));
    // Oversized item (500 px inside 200 px viewport) aligns start without jumping past it.
    try testing.expectEqual(@as(f32, 0), Tree.Scroll.ensureVisibleAxis(0, 400, 0, 200, 0, 500, 24));
    try testing.expectEqual(@as(f32, 40), Tree.Scroll.ensureVisibleAxis(0, 400, 0, 200, 40, 500, 24));
    // Unknown limit (null) allows positive scrolling before first wheel event; known limit clamps.
    try testing.expectEqual(@as(f32, 444), Tree.Scroll.ensureVisibleAxis(100, null, 0, 200, 480, 40, 24));
    try testing.expectEqual(@as(f32, 250), Tree.Scroll.ensureVisibleAxis(100, 250, 0, 200, 480, 40, 24));

    // Tree.ensureVisible against laid-out 2D region.
    var fixture: Fixture = .{};
    var tree = fixture.tree();
    const reg_id = Id.of("vis.region");
    const tgt_id = Id.of("vis.target");
    const region = try tree.open(.{ .id = reg_id, .axis = .row, .width = .{ .fixed = 100 }, .height = .{ .fixed = 100 }, .overflow = .clip });
    _ = try tree.leaf(.{ .width = .{ .fixed = 120 }, .height = .{ .fixed = 200 } });
    _ = try tree.leaf(.{ .id = tgt_id, .width = .{ .fixed = 60 }, .height = .{ .fixed = 30 } });
    tree.close(region);
    try tree.scrollRegion(region, .{});
    try tree.layout(measurer, 400, 400);

    // Target sits at x = [120, 180] in a 100-wide viewport (max.x = 80), margin 10 -> aligns x + w to 90 -> shift 80 (capped).
    const next = tree.ensureVisible(reg_id, tgt_id, 10).?;
    try testing.expectEqual(@as(f32, 80), next.x);
    try testing.expectEqual(@as(f32, 0), next.y);

    // A wrapping horizontal scroll region computes max.x from max wrapped line width, not single-line sum.
    tree = fixture.tree();
    const wrap_id = Id.of("vis.wrap_scroll");
    const wrap_reg = try tree.open(.{
        .id = wrap_id,
        .axis = .row,
        .wrap = true,
        .width = .{ .fixed = 100 },
        .height = .{ .fixed = 80 },
        .gap = 8,
        .overflow = .clip,
    });
    _ = try tree.leaf(.{ .width = .{ .fixed = 160 }, .height = .{ .fixed = 20 }, .shrink = false });
    _ = try tree.leaf(.{ .width = .{ .fixed = 40 }, .height = .{ .fixed = 20 } });
    tree.close(wrap_reg);
    try tree.scrollRegion(wrap_reg, .{});
    try tree.layout(measurer, 400, 400);
    try testing.expectEqual(@as(f32, 60), tree.scrollMax(wrap_id).x);
}

test "focus: ringColor, controlColors, and openRing handle focus, disabled, invalid, and radius clamping" {
    const t = &Theme.dark;

    // ringColor: focused / disabled / invalid / show_invalid_ring / presence.
    try testing.expectEqual(Theme.Color.transparent, focus.ringColor(t, .{}));
    try testing.expectEqual(t.ring.alpha(Theme.ring_opacity), focus.ringColor(t, .{ .focused = true }));
    try testing.expectEqual(Theme.Color.transparent, focus.ringColor(t, .{ .focused = true, .disabled = true }));
    try testing.expectEqual(Theme.Color.transparent, focus.ringColor(t, .{ .invalid = true }));
    try testing.expectEqual(t.destructive.alpha(Theme.ring_opacity), focus.ringColor(t, .{ .invalid = true, .show_invalid_ring = true }));
    try testing.expectEqual(t.destructive.alpha(Theme.ring_opacity), focus.ringColor(t, .{ .focused = true, .invalid = true }));
    try testing.expectEqual(t.ring.alpha(Theme.ring_opacity).fade(0.5), focus.ringColor(t, .{ .focused = true, .presence = 0.5 }));

    // controlColors: invalid > focused > hovered > input, with disabled suppression & 0.5 border fade.
    const rest = focus.controlColors(t, .{});
    try testing.expectEqual(Theme.Color.transparent, rest.ring);
    try testing.expectEqual(t.input, rest.border);

    const hovered = focus.controlColors(t, .{ .hovered = true });
    try testing.expectEqual(Theme.Color.transparent, hovered.ring);
    try testing.expectEqual(t.foreground.fade(0.35), hovered.border);

    const focused = focus.controlColors(t, .{ .focused = true });
    try testing.expectEqual(t.ring.alpha(Theme.ring_opacity), focused.ring);
    try testing.expectEqual(t.ring, focused.border);

    const disabled = focus.controlColors(t, .{ .focused = true, .hovered = true, .disabled = true });
    try testing.expectEqual(Theme.Color.transparent, disabled.ring);
    try testing.expectEqual(t.input.fade(0.5), disabled.border);

    const invalid_unfocused = focus.controlColors(t, .{ .invalid = true });
    try testing.expectEqual(Theme.Color.transparent, invalid_unfocused.ring);
    try testing.expectEqual(t.destructive, invalid_unfocused.border);

    const invalid_group = focus.controlColors(t, .{ .invalid = true, .show_invalid_ring = true });
    try testing.expectEqual(t.destructive.alpha(Theme.ring_opacity), invalid_group.ring);
    try testing.expectEqual(t.destructive, invalid_group.border);

    // openRing: padding, border_width, radius clamping (radius_md + 3 and 255 -> 255), id/shrink forwarding.
    var fixture: Fixture = .{};
    var tree = fixture.tree();
    const id_a = Id.of("focus.ring.a");
    const a = try focus.openRing(&tree, .{
        .id = id_a,
        .pointer = .hand,
        .border = focused.ring,
        .shrink = false,
    });
    tree.close(a);
    const b = try focus.openRing(&tree, .{
        .border = focused.ring,
        .inner_radius = 255,
    });
    tree.close(b);

    try testing.expectEqual(id_a, tree.nodes[a].box.id);
    try testing.expectEqual(Tree.PointerShape.hand, tree.nodes[a].box.pointer);
    try testing.expectEqual(Theme.ring_width, tree.nodes[a].box.border_width);
    try testing.expectEqual(Tree.Edges.all(Theme.ring_width), tree.nodes[a].box.padding);
    try testing.expectEqual(@as(u8, Theme.radius_md + Theme.ring_width), tree.nodes[a].box.radius);
    try testing.expectEqual(false, tree.nodes[a].box.shrink);

    try testing.expectEqual(Id.none, tree.nodes[b].box.id);
    try testing.expectEqual(@as(u8, 255), tree.nodes[b].box.radius);
    try testing.expectEqual(true, tree.nodes[b].box.shrink);
}

test "layout: placeAxis room_before and placeAnchored 4-side alignment and overlap fallback" {
    // Reproduces the prior room_before sign bug: target at y=[160..196] in 270px viewport,
    // own.h = 110. Room below is 62px; room above is 148px (fits completely).
    var fixture: Fixture = .{};
    var tree = fixture.tree();
    const tgt_id = Id.of("anchor.tgt");
    const page = try tree.open(.{ .width = .fill, .height = .fill, .padding = .{ .left = 40, .top = 160 } });
    _ = try tree.leaf(.{ .id = tgt_id, .width = .{ .fixed = 200 }, .height = .{ .fixed = 36 } });
    tree.close(page);
    const pop = try tree.open(.{ .width = .{ .fixed = 80 }, .height = .{ .fixed = 110 } });
    try tree.anchorToWith(pop, tgt_id, .{ .side = .below, .match_anchor_width = false });
    tree.close(pop);
    try tree.layout(measurer, 400, 270);
    // Must flip above to [46..156], not clamp on top of the trigger below.
    try testing.expectEqual(Tree.Rect{ .x = 40, .y = 46, .w = 80, .h = 110 }, tree.nodes[pop].rect);

    // Cross-axis alignments along .below and .left.
    const tgt: Tree.Rect = .{ .x = 100, .y = 100, .w = 80, .h = 40 };
    const own: Tree.Rect = .{ .x = 0, .y = 0, .w = 40, .h = 20 };
    try testing.expectEqual(
        @as(f32, 120),
        layout.placeAnchored(own, tgt, 400, 400, .{ .side = .below, .alignment = .center }).x,
    );
    try testing.expectEqual(
        @as(f32, 140),
        layout.placeAnchored(own, tgt, 400, 400, .{ .side = .below, .alignment = .end }).x,
    );
    const on_left = layout.placeAnchored(own, tgt, 400, 400, .{ .side = .left, .alignment = .center });
    try testing.expectEqual(@as(f32, 56), on_left.x);
    try testing.expectEqual(@as(f32, 110), on_left.y);

    // Cramped viewport where all 4 sides overlap picks the minimum-overlap side (.right: 28x80 < 48x80/80x68).
    const cramped_tgt: Tree.Rect = .{ .x = 40, .y = 40, .w = 80, .h = 80 };
    const cramped_own: Tree.Rect = .{ .x = 0, .y = 0, .w = 80, .h = 80 };
    const cramped = layout.placeAnchored(cramped_own, cramped_tgt, 180, 140, .{ .side = .auto, .gap = 6, .margin = 8 });
    try testing.expectEqual(@as(f32, 92), cramped.x);
    try testing.expectEqual(@as(f32, 40), cramped.y);
}
