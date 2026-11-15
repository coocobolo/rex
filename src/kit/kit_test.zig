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
    try testing.expectEqual(120, @sizeOf(Tree));
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

/// A 100-high clipping region over three rows of 60: 80 of content below.
fn scrolled(fixture: *Fixture, offset: f32) !Tree {
    var tree = fixture.tree();
    const region = try tree.open(.{ .width = .{ .fixed = 50 }, .height = .{ .fixed = 100 }, .overflow = .clip });
    tree.scrollRegion(region, offset);
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
    try testing.expectEqual(80, tree.scroll_max);
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
    tree.scrollRegion(region, 30);
    _ = try tree.leaf(.{ .width = .fill, .height = .{ .fixed = 60 } });
    tree.close(region);
    try tree.layout(measurer, 400, 400);
    try testing.expectEqual(0, tree.scroll_max);
    try expectRect(&tree, 1, 0, 0, 50, 60);
    tree.reset();
    try testing.expectEqual(Tree.none, tree.scroll_index);
}

test "layout: in a scroll region a fill child keeps its content's height" {
    var fixture: Fixture = .{};
    var tree = fixture.tree();
    const region = try tree.open(.{ .width = .{ .fixed = 50 }, .height = .{ .fixed = 100 }, .overflow = .clip });
    tree.scrollRegion(region, 0);
    _ = try tree.leaf(.{ .width = .fill, .height = .{ .fixed = 70 } });
    const grows = try tree.open(.{ .width = .fill, .height = .fill });
    _ = try tree.leaf(.{ .width = .fill, .height = .{ .fixed = 60 } });
    tree.close(grows);
    tree.close(region);
    try tree.layout(measurer, 400, 400);
    // 30 is left for it, but its content needs 60: it scrolls instead.
    try expectRect(&tree, 2, 0, 70, 50, 60);
    try testing.expectEqual(30, tree.scroll_max);
}

test "layout: in a scroll region a fill child still takes the room left" {
    var fixture: Fixture = .{};
    var tree = fixture.tree();
    const region = try tree.open(.{ .width = .{ .fixed = 50 }, .height = .{ .fixed = 100 }, .overflow = .clip });
    tree.scrollRegion(region, 0);
    _ = try tree.leaf(.{ .width = .fill, .height = .fill });
    tree.close(region);
    try tree.layout(measurer, 400, 400);
    try expectRect(&tree, 1, 0, 0, 50, 100);
    try testing.expectEqual(0, tree.scroll_max);
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
    tree.scrollRegion(scroll_box, 30);
    try tree.layout(measurer, 800, 600);
    try expectRect(&tree, scroll_box, 0, 0, 200, 120);
    try testing.expectEqual(@as(f32, 180), tree.scroll_max);

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
