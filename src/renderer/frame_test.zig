//! Tests for the pure color and decoration helpers in Frame.zig.

const std = @import("std");
const testing = std.testing;

const Frame = @import("Frame.zig");
const term = @import("../term/root.zig");
const test_option = @import("../term/test_fixtures.zig").test_option;

const Term = term.term.Terminal(test_option);

test "cellColors: SGR 7 and DECSCNM each swap, together they cancel" {
    var t = try Term.init(testing.allocator);
    defer t.deinit(testing.allocator);

    t.feed("\x1b]10;#111111\x07\x1b]11;#222222\x07A\x1b[7mB");
    const screen = t.active();
    const row = screen.row(0);
    const fg: [3]u8 = .{ 0x11, 0x11, 0x11 };
    const bg: [3]u8 = .{ 0x22, 0x22, 0x22 };

    try testing.expectEqual([2][3]u8{ fg, bg }, Frame.cellColors(&t.palette, screen.styles.get(row[0].style), row[0], false));
    try testing.expectEqual([2][3]u8{ bg, fg }, Frame.cellColors(&t.palette, screen.styles.get(row[1].style), row[1], false));
    try testing.expectEqual([2][3]u8{ bg, fg }, Frame.cellColors(&t.palette, screen.styles.get(row[0].style), row[0], true));
    try testing.expectEqual([2][3]u8{ fg, bg }, Frame.cellColors(&t.palette, screen.styles.get(row[1].style), row[1], true));
}

test "cursorColor: without OSC 12 the cursor is the default foreground" {
    var t = try Term.init(testing.allocator);
    defer t.deinit(testing.allocator);

    t.feed("\x1b]10;#111111\x07\x1b[31m");
    try testing.expectEqual([3]u8{ 0x11, 0x11, 0x11 }, Frame.cursorColor(&t.palette, null));
    try testing.expectEqual([3]u8{ 1, 2, 3 }, Frame.cursorColor(&t.palette, .{ 1, 2, 3 }));
}

const Decoration = @import("Decoration.zig");
const Cell = term.Cell;

const text: [3]u8 = .{ 10, 20, 30 };

fn decorated(flags: term.cell.AttrFlags) Cell {
    return .{ .codepoint = 'A', .kind = .narrow, .flags = flags };
}

test "decorationInstance: only decorated, visible cells produce a run" {
    const option: Decoration.Option = .{};
    try testing.expectEqual(null, Frame.decorationInstance(&option, decorated(.{ .bold = true }), null, text, 255, 0, 0, 1));
    try testing.expectEqual(null, Frame.decorationInstance(&option, decorated(.{ .underline = .single, .invisible = true }), null, text, 255, 0, 0, 1));

    const run = Frame.decorationInstance(&option, decorated(.{ .underline = .curly, .strikethrough = true }), null, text, 255, 3, 2, 2).?;
    try testing.expectEqual(3, run.col);
    try testing.expectEqual(2, run.row);
    try testing.expectEqual(2, run.span);
    try testing.expectEqual(.curly, run.flags.underline);
    try testing.expect(run.flags.strikethrough);
    try testing.expect(!run.flags.overline);
    try testing.expectEqual([4]u8{ 10, 20, 30, 255 }, run.underline);
    try testing.expectEqual([4]u8{ 10, 20, 30, 255 }, run.strikethrough);
    try testing.expectEqual([4]u8{ 10, 20, 30, 255 }, run.overline);
}

test "decorationInstance: dim and blink follow the option" {
    const cell = decorated(.{ .overline = true, .blink = true, .blink_rapid = true });

    const follow: Decoration.Option = .{};
    const a = Frame.decorationInstance(&follow, cell, null, text, 128, 0, 0, 1).?;
    try testing.expectEqual(128, a.overline[3]);
    try testing.expect(a.flags.blink and a.flags.blink_rapid);

    const steady: Decoration.Option = .{ .dim = false, .blink = false };
    const b = Frame.decorationInstance(&steady, cell, null, text, 128, 0, 0, 1).?;
    try testing.expectEqual(255, b.overline[3]);
    try testing.expect(!b.flags.blink and !b.flags.blink_rapid);
}

test "decorationInstance: per kind colors override the text color" {
    const option: Decoration.Option = .{ .color = .{ .underline = .{ 255, 0, 0 }, .overline = .{ 0, 0, 255 } } };
    const run = Frame.decorationInstance(&option, decorated(.{ .underline = .single, .overline = true, .strikethrough = true }), null, text, 128, 0, 0, 1).?;
    try testing.expectEqual([4]u8{ 255, 0, 0, 128 }, run.underline);
    try testing.expectEqual([4]u8{ 10, 20, 30, 128 }, run.strikethrough);
    try testing.expectEqual([4]u8{ 0, 0, 255, 128 }, run.overline);
}

test "appendRun: merges adjacent matching cells, splits on any difference" {
    var storage: [8]Decoration.Instance = undefined;
    var runs: std.ArrayListUnmanaged(Decoration.Instance) = .initBuffer(&storage);
    const option: Decoration.Option = .{};
    const single = decorated(.{ .underline = .single });

    // Columns 0, 1 and a wide cell at 2..3 merge into one run of 4.
    Decoration.appendRun(&runs, Frame.decorationInstance(&option, single, null, text, 255, 0, 0, 1).?);
    Decoration.appendRun(&runs, Frame.decorationInstance(&option, single, null, text, 255, 1, 0, 1).?);
    Decoration.appendRun(&runs, Frame.decorationInstance(&option, single, null, text, 255, 2, 0, 2).?);
    // A gap at column 4.
    Decoration.appendRun(&runs, Frame.decorationInstance(&option, single, null, text, 255, 5, 0, 1).?);
    // Another style.
    Decoration.appendRun(&runs, Frame.decorationInstance(&option, decorated(.{ .underline = .double }), null, text, 255, 6, 0, 1).?);
    // Another color.
    Decoration.appendRun(&runs, Frame.decorationInstance(&option, single, null, .{ 1, 1, 1 }, 255, 7, 0, 1).?);
    // The next row, even though its column follows on.
    Decoration.appendRun(&runs, Frame.decorationInstance(&option, single, null, .{ 1, 1, 1 }, 255, 8, 1, 1).?);

    try testing.expectEqual(5, runs.items.len);
    const expected = [_][3]u16{ .{ 0, 0, 4 }, .{ 5, 0, 1 }, .{ 6, 0, 1 }, .{ 7, 0, 1 }, .{ 8, 1, 1 } };
    for (expected, runs.items) |want, run| {
        try testing.expectEqual(want, [3]u16{ run.col, run.row, run.span });
    }
}

test "build: SGR text produces merged decoration runs" {
    var t = try Term.init(testing.allocator);
    defer t.deinit(testing.allocator);

    // "ab" underlined, a plain space, then "cd" struck through.
    t.feed("\x1b[4mab\x1b[0m \x1b[9mcd\x1b[0m");
    const screen = t.active();
    const row = screen.row(0);
    const option: Decoration.Option = .{};

    var storage: [8]Decoration.Instance = undefined;
    var runs: std.ArrayListUnmanaged(Decoration.Instance) = .initBuffer(&storage);
    for (row[0..6], 0..) |cell, col| {
        const colors = Frame.cellColors(&t.palette, screen.styles.get(cell.style), cell, false);
        if (Frame.decorationInstance(&option, cell, null, colors[0], 255, @intCast(col), 0, 1)) |run| {
            Decoration.appendRun(&runs, run);
        }
    }
    try testing.expectEqual(2, runs.items.len);
    try testing.expectEqual(.single, runs.items[0].flags.underline);
    try testing.expectEqual(2, runs.items[0].span);
    try testing.expect(runs.items[1].flags.strikethrough);
    try testing.expectEqual(3, runs.items[1].col);
    try testing.expectEqual(2, runs.items[1].span);
}

test "alphaByte: rounds and clamps an opacity to a color byte" {
    try testing.expectEqual(128, Frame.alphaByte(0.5));
    try testing.expectEqual(0, Frame.alphaByte(-1.0));
    try testing.expectEqual(255, Frame.alphaByte(2.0));
    try testing.expectEqual(64, Frame.alphaByte(0.25));
}

test "decorationInstance: SGR 53 reaches the shader's overline bit on narrow, wide and last column cells" {
    var t = try Term.init(testing.allocator);
    defer t.deinit(testing.allocator);

    const cols = t.active().active_cols;
    var buf: [64]u8 = undefined;
    // Overline alone, a wide char, then the last column on row 2.
    t.feed("\x1b[53mA\xe4\xb8\xad\x1b[0m");
    t.feed(try std.fmt.bufPrint(&buf, "\x1b[2;{d}H\x1b[53mZ\x1b[0m", .{cols}));

    const screen = t.active();
    const option: Decoration.Option = .{};
    const cases = [_]struct { row: u16, col: u16, span: u16 }{
        .{ .row = 0, .col = 0, .span = 1 },
        .{ .row = 0, .col = 1, .span = 2 },
        .{ .row = 1, .col = cols - 1, .span = 1 },
    };
    for (cases) |case| {
        const c = screen.row(case.row)[case.col];
        try testing.expectEqual(case.span, c.kind.columnSpan());
        const run = Frame.decorationInstance(&option, c, null, text, 255, case.col, case.row, case.span).?;
        try testing.expect(run.flags.overline);
        // decoration.frag reads the overline as bit 2 (FLAG_OVERLINE = 4u).
        try testing.expectEqual(4, @as(u8, @bitCast(run.flags)));
        try testing.expectEqual(case.span, run.span);
    }
}

test "decorationInstance: SGR 58 colors the underline before the configured color" {
    const ink: [3]u8 = .{ 9, 9, 9 };
    const cell: Cell = .{ .codepoint = 'a', .kind = .narrow, .flags = .{ .underline = .single, .strikethrough = true } };
    var option: Decoration.Option = .{};

    // Neither: the text color.
    try testing.expectEqual([4]u8{ 9, 9, 9, 255 }, Frame.decorationInstance(&option, cell, null, ink, 255, 0, 0, 1).?.underline);
    // The configured fixed color.
    option.color.underline = .{ 1, 2, 3 };
    try testing.expectEqual([4]u8{ 1, 2, 3, 255 }, Frame.decorationInstance(&option, cell, null, ink, 255, 0, 0, 1).?.underline);
    // SGR 58 wins, and only for the underline.
    const run = Frame.decorationInstance(&option, cell, .{ 200, 100, 50 }, ink, 255, 0, 0, 1).?;
    try testing.expectEqual([4]u8{ 200, 100, 50, 255 }, run.underline);
    try testing.expectEqual([4]u8{ 9, 9, 9, 255 }, run.strikethrough);
}

test "spliceSpan: same count keeps the tail and reports a stable range" {
    var buf: std.ArrayListUnmanaged(u8) = try .initCapacity(testing.allocator, 8);
    defer buf.deinit(testing.allocator);
    buf.appendSliceAssumeCapacity(&.{ 0, 1, 2, 3, 4, 5 });
    var offsets = [_]u32{ 0, 2, 5, 6 };
    const fresh = [_]u8{ 9, 9, 9 };
    const counts = [_]u32{3};
    const stable = try Frame.spliceSpan(u8, testing.allocator, &buf, &offsets, 1, 1, 3, &fresh, &counts);
    try testing.expect(stable);
    try testing.expectEqualSlices(u8, &.{ 0, 1, 9, 9, 9, 5 }, buf.items);
    try testing.expectEqual([4]u32{ 0, 2, 5, 6 }, offsets);
}

test "spliceSpan: a shorter middle shifts the tail" {
    var buf: std.ArrayListUnmanaged(u8) = try .initCapacity(testing.allocator, 8);
    defer buf.deinit(testing.allocator);
    buf.appendSliceAssumeCapacity(&.{ 0, 1, 2, 3, 4, 5 });
    var offsets = [_]u32{ 0, 2, 5, 6 };
    const fresh = [_]u8{ 9, 9 };
    const counts = [_]u32{2};
    const stable = try Frame.spliceSpan(u8, testing.allocator, &buf, &offsets, 1, 1, 3, &fresh, &counts);
    try testing.expect(!stable);
    try testing.expectEqualSlices(u8, &.{ 0, 1, 9, 9, 5 }, buf.items);
    try testing.expectEqual([4]u32{ 0, 2, 4, 5 }, offsets);
}

test "spliceSpan: a longer middle shifts the tail" {
    var buf: std.ArrayListUnmanaged(u8) = try .initCapacity(testing.allocator, 8);
    defer buf.deinit(testing.allocator);
    buf.appendSliceAssumeCapacity(&.{ 0, 1, 2, 3, 4, 5 });
    var offsets = [_]u32{ 0, 2, 5, 6 };
    const fresh = [_]u8{ 7, 7, 7, 7 };
    const counts = [_]u32{4};
    const stable = try Frame.spliceSpan(u8, testing.allocator, &buf, &offsets, 1, 1, 3, &fresh, &counts);
    try testing.expect(!stable);
    try testing.expectEqualSlices(u8, &.{ 0, 1, 7, 7, 7, 7, 5 }, buf.items);
    try testing.expectEqual([4]u32{ 0, 2, 6, 7 }, offsets);
}

test "spliceSpan: a count trade inside the span keeps the tail" {
    var buf: std.ArrayListUnmanaged(u8) = try .initCapacity(testing.allocator, 8);
    defer buf.deinit(testing.allocator);
    buf.appendSliceAssumeCapacity(&.{ 0, 1, 2, 3, 4, 5, 6, 7 });
    var offsets = [_]u32{ 0, 2, 5, 8 };
    const fresh = [_]u8{ 9, 9, 9, 8, 8 };
    const counts = [_]u32{ 3, 2 };
    const stable = try Frame.spliceSpan(u8, testing.allocator, &buf, &offsets, 0, 1, 3, &fresh, &counts);
    try testing.expect(stable);
    try testing.expectEqualSlices(u8, &.{ 9, 9, 9, 8, 8, 5, 6, 7 }, buf.items);
    try testing.expectEqual([4]u32{ 0, 3, 5, 8 }, offsets);
}

test "build: SGR 58 reaches the underline through the cell's style" {
    var t = try Term.init(testing.allocator);
    defer t.deinit(testing.allocator);

    t.feed("\x1b[4;58:2::200:100:50mA\x1b[59mB");
    const screen = t.active();
    const row = screen.row(0);
    const a = screen.styles.get(row[0].style);
    const b = screen.styles.get(row[1].style);
    try testing.expectEqual([3]u8{ 200, 100, 50 }, t.palette.resolveKeyRgb(a.underline, .foreground));
    try testing.expectEqual(term.Style.default_key, b.underline);
}
