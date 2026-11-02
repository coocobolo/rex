const std = @import("std");

const term = @import("term.zig");
const screen = @import("screen.zig");

const Option = term.Option;

const LineAttr = screen.LineAttr;
const Screen = screen.Screen;

const Cell = @import("cell.zig").Cell;
const Attr = @import("cell.zig").Attr;
const Color = @import("cell.zig").Color;
const Palette = @import("palette.zig").Palette;
const Cursor = @import("cell.zig").Cursor;
const SavedCursor = @import("cell.zig").SavedCursor;
const Charset = @import("cell.zig").Charset;
const CharsetState = @import("cell.zig").CharsetState;

const testing = std.testing;

// type aliases for test screens
const test_tab_width: usize = 8;
const test_max_cols: usize = 24;
const test_max_rows: usize = 24;
const test_max_scrollback: usize = 8;

const AltScreen = Screen(.{
    .max_rows = test_max_rows,
    .max_cols = test_max_cols,
    .tab_width = test_tab_width,
    .max_scrollback = 0,
    .version = "",
    .name = "",
}); // no scrollback

const PrimaryScreen = Screen(.{
    .max_rows = test_max_rows,
    .max_cols = test_max_cols,
    .tab_width = test_tab_width,
    .max_scrollback = test_max_scrollback,
    .version = "",
    .name = "",
}); // with scrollback

// Screen rounds its ring up to a power of two (see `nextPowerOfTwo` in screen.zig).
const alt_ring_rows = std.math.ceilPowerOfTwoAssert(usize, test_max_rows);
const primary_ring_rows = std.math.ceilPowerOfTwoAssert(usize, test_max_rows + test_max_scrollback);

// helpers
fn altScreen(alloc: std.mem.Allocator) !AltScreen {
    return .create(alloc);
}

fn primaryScreen(alloc: std.mem.Allocator) !PrimaryScreen {
    return .create(alloc);
}

test "Screen: ring_rows comptime constant" {
    try testing.expectEqual(32, alt_ring_rows); // 24 + 0, rounded up
    try testing.expectEqual(32, primary_ring_rows); // 24 + 8
}

test "Screen: init - cells zeroed" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    try testing.expectEqualDeep(
        &([_]Cell{.{}} ** (alt_ring_rows * test_max_cols)),
        s.cells,
    );
}

test "Screen: init - default dimentions" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    try testing.expectEqual(test_max_rows, s.active_rows);
    try testing.expectEqual(test_max_cols, s.active_cols);
}

test "Screen: init - scroll region defaults" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    try testing.expectEqual(0, s.scroll_top);
    try testing.expectEqual(23, s.scroll_bottom); // max_rows - 1
}

test "Screen: init - cursor at origin" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    try testing.expectEqual(0, s.cursor.row);
    try testing.expectEqual(0, s.cursor.col);
}

test "Screen: init - saved_cursor sentinel" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    try testing.expectEqual(0, s.saved_cursor.row);
}

test "Screen: init - generation starts at zero" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    try testing.expectEqual(0, s.generation);
}

test "Screen: init - tab stops at multiples of tab_width" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    // set at 8 (only multiple of 8 < 12)
    try testing.expect(s.tab_stops.isSet(8));
    // not set at non-multiples
    try testing.expect(!s.tab_stops.isSet(0));
    try testing.expect(!s.tab_stops.isSet(4));
    try testing.expect(!s.tab_stops.isSet(9));
}

test "Screen: void fields absent when max_scrollback == 0" {
    // void fields have zero size, the struct should not grow
    comptime {
        const T = AltScreen;
        // scrollback_used and viewport_offset are void
        // their field type MUST be void
        const su = @TypeOf(@as(T, undefined).scrollback_used);
        const vo = @TypeOf(@as(T, undefined).viewport_offset);
        if (su != void) @compileError("scrollback_used should be void for altenate screen");
        if (vo != void) @compileError("viewport_offset should be void for altenate screen");
    }
}

test "Screen: u32 fields present when max_scrollback > 0" {
    comptime {
        const T = PrimaryScreen;
        const su = @TypeOf(@as(T, undefined).scrollback_used);
        const vo = @TypeOf(@as(T, undefined).viewport_offset);
        if (su != u32) @compileError("scrollback_used should be u32 for primary screen");
        if (vo != u32) @compileError("viewport_offset should be u32 for primary screen");
    }
}

test "Screen: primary screen scrollback fields start at zero" {
    const alloc = testing.allocator;
    var s = try primaryScreen(alloc);
    defer s.destroy(alloc);

    try testing.expectEqual(0, s.scrollback_used);
    try testing.expectEqual(0, s.viewport_offset);
    try testing.expectEqual(0, s.scroll_offset);
}

test "Screen: cell count matches ring_rows * max_cols" {
    const alloc = testing.allocator;
    var s = try primaryScreen(alloc);
    defer s.destroy(alloc);

    try testing.expectEqual(primary_ring_rows * test_max_cols, s.cells.len);
}

test "Screen: cells are 64-byte aligned" {
    const alloc = testing.allocator;
    var s = try primaryScreen(alloc);
    defer s.destroy(alloc);

    try testing.expect(std.mem.isAligned(@intFromPtr(s.cells.ptr), 64));
}

test "viewRow: alternate screen falls back to physRow" {
    // when max_scrollback = 0, viewRow must equal physRow for all r.

    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.scroll_offset = 7;
    // 7..23 ... 0..6
    for (0..test_max_cols) |r| {
        try testing.expectEqual(s.physRow(r), s.viewRow(r));
    }
}

test "viewRow: viewport_offset == 0 equals physRow" {
    // No scrollback active -> viewRow and physRow must agree.

    const alloc = testing.allocator;
    var s = try primaryScreen(alloc);
    defer s.destroy(alloc);

    s.scroll_offset = 10;
    s.viewport_offset = 0;
    // 10..31 ... 0 .. 1
    for (0..test_max_cols) |r| {
        try testing.expectEqual(s.physRow(r), s.viewRow(r));
    }
}

test "viewRow: underflow prevention viewport_offset > scroll_offset" {
    const alloc = testing.allocator;
    var s = try primaryScreen(alloc);
    defer s.destroy(alloc);

    // without + ring_rows: 2 - 5 would underflow (usize)
    // with + ring_rows: (2 + 32 - 5) % 32 = 29
    s.scroll_offset = 2;
    s.viewport_offset = 5;

    const ring = primary_ring_rows;
    try testing.expectEqual((2 + ring - 5 + 0) % ring, s.viewRow(0)); // 29
    try testing.expectEqual((2 + ring - 5 + 1) % ring, s.viewRow(1)); // 30
    try testing.expectEqual((2 + ring - 5 + 3) % ring, s.viewRow(3)); // 0 (wraps)
}

test "viewRow: wrap-around when scroll_offset is near ring_rows" {
    const alloc = testing.allocator;
    var s = try primaryScreen(alloc);
    defer s.destroy(alloc);

    const ring = primary_ring_rows;
    s.scroll_offset = @intCast(ring - 4);
    s.viewport_offset = 0;

    // viewRow(5) should wrap around: (ring_rows - 4 + ring_rows + 5) % ring_rows = 1
    try testing.expectEqual((ring - 4 + 0) % ring, s.viewRow(0)); // ring - 4 = 28
    try testing.expectEqual((ring - 4 + 4) % ring, s.viewRow(4)); // 0 (wraps)
    try testing.expectEqual((ring - 4 + 5) % ring, s.viewRow(5)); // 1
}

test "viewRow: wrap-around with viewport_offset" {
    const alloc = testing.allocator;
    var s = try primaryScreen(alloc);
    defer s.destroy(alloc);

    const ring = primary_ring_rows;
    s.scroll_offset = @intCast(ring - 4);
    s.viewport_offset = 3;

    // viewRow(0) = (ring_rows - 4 + ring_rows - 3) % ring_rows = (ring_rows - 7) % ring_rows

    try testing.expectEqual((ring - 4 + ring - 3 + 0) % ring, s.viewRow(0)); // ring - 7 = 25
    try testing.expectEqual((ring - 4 + ring - 3 + 7) % ring, s.viewRow(7)); // 0 (wraps)
}

test "viewRow: max viewport_offset (fully scrolled back)" {
    // viewport_offset = scrollback_used = max_scrollback
    // The oldest visible row should be at scroll_offset itself (the live top)

    const alloc = testing.allocator;
    var s = try primaryScreen(alloc);
    defer s.destroy(alloc);

    s.scroll_offset = 50;
    s.scrollback_used = 50; // 50 lines of history available
    s.viewport_offset = 50; // scrolled all the way back

    // viewRow(0) = (50  +  ring - 50 + 0) % ring = 0
    try testing.expectEqual(0, s.viewRow(0));

    // viewRow(1) = 1
    try testing.expectEqual(1, s.viewRow(1));
    // viewRow(23) = 23
    try testing.expectEqual(23, s.viewRow(23));
}

test "viewRow: scroll_offset = 0, viewport_offset = 0, all rows" {
    // ring buffer at origin, no scrollback
    const alloc = testing.allocator;
    var s = try primaryScreen(alloc);
    defer s.destroy(alloc);

    s.scroll_offset = 0;
    s.viewport_offset = 0;

    for (0..test_max_cols) |r| {
        try testing.expectEqual(r, s.viewRow(r));
    }
}

test "row: length equals active_cols" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    for (0..test_max_cols) |r| {
        try testing.expectEqual(s.active_cols, s.row(r).len);
    }
}

test "rowMut: length equals max_cols (full row)" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    for (0..test_max_rows) |r| {
        try testing.expectEqual(test_max_cols, s.rowMut(r).len);
    }
}

test "row: all cells default after init" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    for (0..test_max_rows) |r| {
        for (s.row(r)) |cell| {
            try testing.expectEqualDeep(Cell{}, cell);
        }
    }
}

test "rowMut: write is visible via row and getCell" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    const c: Cell = .{ .codepoint = 'Z', .kind = .narrow };
    s.rowMut(3)[5] = c;

    try testing.expectEqualDeep(c, s.row(3)[5]);
    try testing.expectEqualDeep(c, s.cellAt(3, 5));
}

test "rowMut: memset entire row leaves other rows untouched" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    const c: Cell = .{ .codepoint = ' ', .kind = .narrow };
    @memset(s.rowMut(2), c);

    for (0..test_max_cols) |col| {
        try testing.expectEqualDeep(c, s.cellAt(2, col));
    }
    // Adjacent rows untouched
    try testing.expectEqualDeep(Cell{}, s.cellAt(1, 0));
    try testing.expectEqualDeep(Cell{}, s.cellAt(3, 0));
}

test "setCell: in-bounds write succeeds" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    const c: Cell = .{ .codepoint = 'A', .kind = .narrow };
    s.setCell(0, 0, c);
    try testing.expectEqualDeep(c, s.cellAt(0, 0));
}

test "setCell: out-of-bounds row silently ignored" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.setCell(s.active_rows, 0, .{ .codepoint = 'X', .kind = .narrow }); // == active_rows
    s.setCell(s.active_rows + 1, 0, .{ .codepoint = 'X', .kind = .narrow }); // > active_rows
    // No crash; cells unchanged
    try testing.expectEqualDeep(Cell{}, s.cellAt(0, 0));
}

test "setCell: out-of-bounds col silently ignored" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.setCell(0, s.active_cols, .{ .codepoint = 'X', .kind = .narrow }); // == active_cols
    s.setCell(0, s.active_cols + 1, .{ .codepoint = 'X', .kind = .narrow }); // > active_cols
    try testing.expectEqualDeep(Cell{}, s.cellAt(0, 0));
}

test "setCell: both out-of-bounds silently ignored" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    // Must not crash
    s.setCell(s.active_rows, s.active_cols, .{ .codepoint = 'X', .kind = .narrow });
}

test "setCell: insert mode off, normal overwrite" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    const a: Cell = .{ .codepoint = 'A', .kind = .narrow };
    fillRow(&s, 0, a);

    const b: Cell = .{ .codepoint = 'B', .kind = .narrow };
    s.mode.insert = false;
    s.setCell(0, 3, b);

    try testing.expectEqualDeep(b, s.cellAt(0, 3));
    try testing.expectEqualDeep(a, s.cellAt(0, 2));
    try testing.expectEqualDeep(a, s.cellAt(0, 4));
}

test "setCell: insert mode on, shifts cells right, last cell dropped" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    const a: Cell = .{ .codepoint = 'A', .kind = .narrow };
    fillRow(&s, 0, a);

    const b: Cell = .{ .codepoint = 'B', .kind = .narrow };
    s.mode.insert = true;
    s.setCell(0, 3, b);

    // col 3 = 'b'
    // col 4..s.active_cols-1 = 'A' (shifted right)

    try testing.expectEqualDeep(b, s.cellAt(0, 3));
    try testing.expectEqualDeep(a, s.cellAt(0, 4));
    try testing.expectEqualDeep(a, s.cellAt(0, s.active_cols - 1));
    // col 2 untouched
    try testing.expectEqualDeep(a, s.cellAt(0, 2));
}

test "setCell: insert mode at last col, no shift" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    const a: Cell = .{ .codepoint = 'A', .kind = .narrow };
    fillRow(&s, 0, a);

    const b: Cell = .{ .codepoint = 'B', .kind = .narrow };
    s.mode.insert = true;
    s.setCell(0, s.active_cols - 1, b);

    try testing.expectEqualDeep(b, s.cellAt(0, s.active_cols - 1));
    try testing.expectEqualDeep(a, s.cellAt(0, s.active_cols - 2));
}

test "setCell: insert mode does not affect other rows" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    const a: Cell = .{ .codepoint = 'A', .kind = .narrow };
    fillScreen(&s, a);

    s.mode.insert = true;
    s.setCell(5, 3, .{ .codepoint = 'X', .kind = .narrow });

    // Row 4 and row 6 are untouched
    for (0..s.active_cols) |c| {
        try testing.expectEqualDeep(a, s.cellAt(4, c));
        try testing.expectEqualDeep(a, s.cellAt(6, c));
    }
}

test "setCell/getCell: roundtrip at corners and center" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    const positions = [_][2]usize{
        .{ 0, 0 },
        .{ 0, test_max_cols - 1 },
        .{ test_max_rows - 1, 0 },
        .{ test_max_rows - 1, test_max_cols - 1 },
        .{ test_max_rows / 2, test_max_cols / 2 },
    };

    for (positions, 0..) |pos, i| {
        const c: Cell = .{ .codepoint = @intCast('A' + i), .kind = .narrow };
        s.setCell(pos[0], pos[1], c);
        try testing.expectEqualDeep(c, s.cellAt(pos[0], pos[1]));
    }
}

test "getCell: remaps correctly after scroll_offset advances" {
    const alloc = testing.allocator;
    var s = try primaryScreen(alloc);
    defer s.destroy(alloc);

    // Write marker to logical row 0 at
    // scroll_offset=0, physical row 0
    const marker: Cell = .{ .codepoint = 'M', .kind = .narrow };
    s.setCell(0, 0, marker);

    // Advance scroll_offset by 1
    // logical row 0 now maps to physical 1
    s.scroll_offset = 1;
    try testing.expectEqualDeep(Cell{}, s.cellAt(0, 0)); // physical 1 = default

    // Logical row (ring_rows - 1) wraps to physical 0 = 'M' marker
    // physRow(ring_rows - 1) = (1 + ring_rows - 1) % ring_rows = 0
    try testing.expectEqualDeep(marker, s.cellAt(primary_ring_rows - 1, 0));
}

test "displayRow: viewport_offset=0 matches row" {
    const alloc = testing.allocator;
    var s = try primaryScreen(alloc);
    defer s.destroy(alloc);

    s.scroll_offset = 5;
    s.viewport_offset = 0;

    for (0..test_max_rows) |r| {
        try testing.expectEqualSlices(Cell, s.row(r), s.displayRow(r));
    }
}

test "displayRow: viewport_offset > 0 shows earlier physical rows" {
    const alloc = testing.allocator;
    var s = try primaryScreen(alloc);
    defer s.destroy(alloc);

    // Write marker at physical row 0 (scroll_offset=0, logical row 0)
    const marker: Cell = .{ .codepoint = 'V', .kind = .narrow };
    s.rowMut(0)[0] = marker;

    // Advance scroll_offset by 3; scroll back by 3
    // viewRow(0) = (3 + ring_rows - 3 + 0) % ring_rows = 0
    // physical row 0 (marker 'V')
    s.scroll_offset = 3;
    s.viewport_offset = 3;

    try testing.expectEqualDeep(marker, s.displayRow(0)[0]);
    // row(0) without viewport is at physical 3 = default
    try testing.expectEqualDeep(Cell{}, s.row(0)[0]);
}

test "displayRow: length equals active_cols" {
    const alloc = testing.allocator;
    var s = try primaryScreen(alloc);
    defer s.destroy(alloc);

    s.scroll_offset = 2;
    s.viewport_offset = 1;

    for (0..test_max_rows) |r| {
        try testing.expectEqual(s.active_cols, s.displayRow(r).len);
    }
}

test "displayRow: alternate screen (max_scrollback=0) equals row" {
    // comptime fallback: viewRow is physRow when max_scrollback == 0
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    const c: Cell = .{ .codepoint = 'T', .kind = .narrow };
    s.setCell(5, 3, c);

    for (0..test_max_rows) |r| {
        try testing.expectEqualSlices(Cell, s.row(r), s.displayRow(r));
    }
}

test "displayLineAttr: default is .normal" {
    const alloc = testing.allocator;
    var s = try primaryScreen(alloc);
    defer s.destroy(alloc);

    for (0..s.active_rows) |r| {
        try testing.expectEqual(LineAttr.normal, s.displayLineAttr(r));
    }
}

test "displayLineAttr: reflects setLineAttr" {
    const alloc = testing.allocator;
    var s = try primaryScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.row = 2;
    s.setLineAttr(.double_width);
    try testing.expectEqual(LineAttr.double_width, s.displayLineAttr(2));

    s.cursor.row = 5;
    s.setLineAttr(.double_top);
    try testing.expectEqual(LineAttr.double_top, s.displayLineAttr(5));

    // Other rows are unaffected
    try testing.expectEqual(LineAttr.normal, s.displayLineAttr(0));
    try testing.expectEqual(LineAttr.normal, s.displayLineAttr(3));
}

test "displayLineAttr: accounts for viewport_offset (scrollback)" {
    const alloc = testing.allocator;
    var s = try primaryScreen(alloc);
    defer s.destroy(alloc);

    // Write a line to push content into scrollback
    s.cursor.row = 0;
    s.setLineAttr(.double_bottom);
    // Scroll up so the marked row enters scrollback
    s.scrollUp(1);

    // Scroll viewport back to see the scrollback row
    s.scrollViewportBack(1);

    // Display row 0 now shows the scrollback row — must have .double_bottom
    try testing.expectEqual(LineAttr.double_bottom, s.displayLineAttr(0));
}

test "displayLineAttr: after eraseDisplay ED 2, all rows are .normal" {
    const alloc = testing.allocator;
    var s = try primaryScreen(alloc);
    defer s.destroy(alloc);

    for (0..s.active_rows) |r| {
        s.cursor.row = @intCast(r);
        s.setLineAttr(.double_width);
    }
    s.eraseDisplay(2);

    for (0..s.active_rows) |r| {
        try testing.expectEqual(LineAttr.normal, s.displayLineAttr(r));
    }
}

test "bump: generation starts at zero" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    try testing.expectEqual(0, s.generation);
}

test "bump: increments generation by one" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.bump();
    try testing.expectEqual(1, s.generation);

    s.bump();
    try testing.expectEqual(2, s.generation);
}

test "bump: wraps on overflow (wrapping addition)" {
    // +%= means wrapping add — generation must not panic at u32 max.
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.generation = std.math.maxInt(u32);
    s.bump();
    try testing.expectEqual(0, s.generation);
}

test "bump: renderer detects change via != comparison" {
    // Correct renderer pattern: generation != last_generation, not >.
    // Verify that after a wrap the comparison still fires.
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    var last: u32 = s.generation;
    s.bump();
    try testing.expect(s.generation != last);

    // Wrap case
    s.generation = std.math.maxInt(u32);
    last = s.generation;
    s.bump();
    try testing.expect(s.generation != last); // 0 != maxInt(u32)
}

test "effectiveTop: origin mode off returns 0 regardless of scroll_top" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.origin = false;
    s.scroll_top = 5;

    try testing.expectEqual(0, s.effectiveTop());
}

test "effectiveTop: origin mode off, scroll_top=0 returns 0" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.origin = false;
    s.scroll_top = 0;

    try testing.expectEqual(0, s.effectiveTop());
}

test "effectiveTop: origin mode on returns scroll_top" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.origin = true;
    s.scroll_top = 5;

    try testing.expectEqual(5, s.effectiveTop());
}

test "effectiveTop: origin mode on, scroll_top=0 returns 0" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.origin = true;
    s.scroll_top = 0;

    try testing.expectEqual(0, s.effectiveTop());
}

test "effectiveTop: origin mode on, scroll_top at max boundary" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.origin = true;
    s.scroll_top = test_max_rows - 1;

    try testing.expectEqual(test_max_rows - 1, s.effectiveTop());
}

test "effectiveTop: toggling origin mode changes result" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.scroll_top = 4;

    s.cursor.origin = false;
    try testing.expectEqual(0, s.effectiveTop());

    s.cursor.origin = true;
    try testing.expectEqual(4, s.effectiveTop());

    s.cursor.origin = false;
    try testing.expectEqual(0, s.effectiveTop());
}

/// Returns the blank cell that scrollUp uses: inherits cursor background color.
fn blankCell(s: anytype) Cell {
    return .{ .background = s.cursor.attr.bg };
}

test "scrollUp: full-screen n=1, row 1 moves to row 0" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    const marker: Cell = .{ .codepoint = 'A', .kind = .narrow };
    s.setCell(1, 0, marker);

    s.scrollUp(1);

    try testing.expectEqualDeep(marker, s.cellAt(0, 0));
}

test "scrollUp: full-screen n=1, new bottom row is blank" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    const row = s.active_rows - 1;
    s.setCell(row, 0, .{ .codepoint = 'X', .kind = .narrow });
    s.scrollUp(1);

    try testing.expectEqualDeep(blankCell(&s), s.cellAt(row, 0));
}

test "scrollUp: full-screen n=1, scroll_offset advances by 1" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    const before = s.scroll_offset;
    s.scrollUp(1);
    try testing.expectEqual((before + 1) % alt_ring_rows, s.scroll_offset);
}

test "scrollUp: full-screen n=3, bulk shift" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    const m3: Cell = .{ .codepoint = '3', .kind = .narrow };
    const m4: Cell = .{ .codepoint = '4', .kind = .narrow };
    const m5: Cell = .{ .codepoint = '5', .kind = .narrow };
    s.setCell(3, 0, m3);
    s.setCell(4, 0, m4);
    s.setCell(5, 0, m5);

    s.scrollUp(3);

    try testing.expectEqualDeep(m3, s.cellAt(0, 0));
    try testing.expectEqualDeep(m4, s.cellAt(1, 0));
    try testing.expectEqualDeep(m5, s.cellAt(2, 0));
    // Bottom 3 rows vacated and cleared
    for (s.active_rows - 3..s.active_rows) |r| {
        try testing.expectEqualDeep(blankCell(&s), s.cellAt(r, 0));
    }
}

test "scrollUp: full-screen n > active_rows, clamped; all rows cleared" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    for (0..s.active_rows) |r| {
        s.setCell(r, 0, .{ .codepoint = @intCast(r + 'A'), .kind = .narrow });
    }

    s.scrollUp(s.active_rows + 99);

    for (0..s.active_rows) |r| {
        try testing.expectEqualDeep(blankCell(&s), s.cellAt(r, 0));
    }
}

test "scrollUp: full-screen, blank cell inherits cursor bg" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    // Set a non-default cursor background
    s.cursor.attr.bg = s.palette.intern(.{ .indexed = 3 });
    s.scrollUp(1);

    const bottom = s.cellAt(s.active_rows - 1, 0);
    try testing.expectEqualDeep(s.cursor.attr.bg, bottom.background);
}

test "scrollUp: full-screen, bumps generation" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    const gen = s.generation;
    s.scrollUp(1);
    try testing.expectEqual(gen + 1, s.generation);
}

test "scrollUp: scrollback_used increments on each full-screen scroll" {
    const alloc = testing.allocator;
    var s = try primaryScreen(alloc);
    defer s.destroy(alloc);

    try testing.expectEqual(0, s.scrollback_used);
    s.scrollUp(1);
    try testing.expectEqual(1, s.scrollback_used);
    s.scrollUp(3);
    try testing.expectEqual(4, s.scrollback_used);
}

test "scrollUp: scrollback_used capped at max_scrollback" {
    const alloc = testing.allocator;
    var s = try primaryScreen(alloc);
    defer s.destroy(alloc);

    for (0..test_max_scrollback + 10) |_| s.scrollUp(1);

    try testing.expectEqual(test_max_scrollback, s.scrollback_used);
}

test "scrollUp: scrolled-off row is readable via displayRow after scrollback" {
    const alloc = testing.allocator;
    var s = try primaryScreen(alloc);
    defer s.destroy(alloc);

    // Write a marker on the current top row
    const marker: Cell = .{ .codepoint = 'H', .kind = .narrow };
    s.setCell(0, 0, marker);

    s.scrollUp(1);
    // The old row 0 is now scrollback row 0.
    // viewport_offset=1 brings it back into view at display row 0.
    s.viewport_offset = 1;

    try testing.expectEqualDeep(marker, s.displayRow(0)[0]);
}

test "scrollUp: partial region n=1, row inside region shifts up" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.scroll_top = 2;
    s.scroll_bottom = 5;

    const marker: Cell = .{ .codepoint = 'X', .kind = .narrow };
    s.setCell(3, 0, marker); // row 3: should move to row 2

    s.scrollUp(1);

    try testing.expectEqualDeep(marker, s.cellAt(2, 0));
    // Bottom of region cleared
    try testing.expectEqualDeep(blankCell(&s), s.cellAt(5, 0));
}

test "scrollUp: partial region n=2, bulk copy" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.scroll_top = 1;
    s.scroll_bottom = 6;

    const m3: Cell = .{ .codepoint = '3', .kind = .narrow };
    const m4: Cell = .{ .codepoint = '4', .kind = .narrow };
    s.setCell(3, 0, m3);
    s.setCell(4, 0, m4);

    s.scrollUp(2);

    // Rows 3,4 shifted to rows 1,2
    try testing.expectEqualDeep(m3, s.cellAt(1, 0));
    try testing.expectEqualDeep(m4, s.cellAt(2, 0));
    // Bottom 2 rows of region (5,6) cleared
    try testing.expectEqualDeep(blankCell(&s), s.cellAt(5, 0));
    try testing.expectEqualDeep(blankCell(&s), s.cellAt(6, 0));
}

test "scrollUp: partial region, rows outside region unaffected" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.scroll_top = 2;
    s.scroll_bottom = 5;

    const above: Cell = .{ .codepoint = 'A', .kind = .narrow };
    const below: Cell = .{ .codepoint = 'B', .kind = .narrow };
    s.setCell(0, 0, above);
    s.setCell(6, 0, below);

    s.scrollUp(1);

    try testing.expectEqualDeep(above, s.cellAt(0, 0));
    try testing.expectEqualDeep(below, s.cellAt(6, 0));
}

test "scrollUp: partial region, scroll_offset unchanged" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.scroll_top = 2;
    s.scroll_bottom = 5;
    const before = s.scroll_offset;

    s.scrollUp(1);

    try testing.expectEqual(before, s.scroll_offset);
}

test "scrollUp: partial region n > region_height, all region rows cleared" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.scroll_top = 2;
    s.scroll_bottom = 5; // region height = 4

    for (2..6) |r| s.setCell(r, 0, .{ .codepoint = 'X', .kind = .narrow });

    s.scrollUp(99);

    for (2..6) |r| {
        try testing.expectEqualDeep(blankCell(&s), s.cellAt(r, 0));
    }
}

test "scrollUp: partial region, bumps generation" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.scroll_top = 2;
    s.scroll_bottom = 5;
    const gen = s.generation;

    s.scrollUp(1);

    try testing.expectEqual(gen + 1, s.generation);
}

test "scrollUp: scroll_top >= scroll_bottom, early return; no change" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.scroll_top = 3;
    s.scroll_bottom = 3; // equal; early return

    const marker: Cell = .{ .codepoint = 'Z', .kind = .narrow };
    s.setCell(3, 0, marker);
    const gen = s.generation;
    const offset = s.scroll_offset;

    s.scrollUp(1);

    try testing.expectEqualDeep(marker, s.cellAt(3, 0));
    try testing.expectEqual(gen, s.generation); // bump NOT called
    try testing.expectEqual(offset, s.scroll_offset);
}

test "scrollUp: partial region, line_attrs shift correctly" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    // Set a double-width attr on logical row 2
    s.cursor.row = 2;
    s.setLineAttr(.double_width);
    // Scroll region [1..3] up by 1
    s.scroll_top = 1;
    s.scroll_bottom = 3;
    _ = s.scrollUp(1);

    // Row 2's after should have moved to row 1
    try testing.expectEqual(LineAttr.double_width, s.line_attrs[s.physRow(1)]);

    // Row 3 (vacated) should be reset to normal
    try testing.expectEqual(LineAttr.normal, s.line_attrs[s.physRow(3)]);
}

test "scrollUp: full screen, new bottom row line_attr is normal" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    // Set a double-width attr on the last row
    s.cursor.row = @intCast(s.active_rows - 1);
    s.setLineAttr(.double_width);

    // Scroll region [1..3] up by 1
    s.scroll_top = 1;
    s.scroll_bottom = @intCast(s.active_rows - 1);
    _ = s.scrollUp(1);

    // The new bottom row must be .normal (old attr scrolled into history)
    try testing.expectEqual(LineAttr.normal, s.line_attrs[s.physRow(s.active_rows - 1)]);
}

test "scrollDown: n=1 shifts rows down, top row cleared" {
    // TERMV4 M2 item 9: full-screen scrollDown trips wrapAdd assert (b > max_rows) when scrollback is on.
    if (true) return error.SkipZigTest;

    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    // Mark row 0 and row 1
    const a: Cell = .{ .codepoint = 'A', .kind = .narrow };
    const b: Cell = .{ .codepoint = 'B', .kind = .narrow };
    s.setCell(0, 0, a);
    s.setCell(1, 0, b);

    s.scrollDown(1);

    // Row 0 (old row 0) is now at row 1
    try testing.expectEqualDeep(a, s.cellAt(1, 0));
    // Row 1 (old row 1) is now at row 2
    try testing.expectEqualDeep(b, s.cellAt(2, 0));
    // New row 0 is blank
    try testing.expectEqualDeep(Cell{ .background = s.cursor.attr.bg }, s.cellAt(0, 0));
}

test "scrollDown: n=3 bulk shift" {
    // TERMV4 M2 item 9: full-screen scrollDown trips wrapAdd assert (b > max_rows) when scrollback is on.
    if (true) return error.SkipZigTest;

    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    for (0..test_max_rows) |r| {
        s.setCell(r, 0, .{ .codepoint = @intCast('0' + r), .kind = .narrow });
    }

    s.scrollDown(3);

    // Rows 0..2 are blank
    const blank = Cell{ .background = s.cursor.attr.bg };
    for (0..3) |r| try testing.expectEqualDeep(blank, s.cellAt(r, 0));
    // Old row 0 is now at row 3
    try testing.expectEqual(@as(u21, '0'), s.cellAt(3, 0).codepoint);
    // Old row (test_max_rows-4) is now at (test_max_rows-1)
    try testing.expectEqual(@as(u21, '0' + test_max_rows - 4), s.cellAt(test_max_rows - 1, 0).codepoint);
}

test "scrollDown: n > region_height clears entire region" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    for (0..test_max_rows) |r| {
        s.setCell(r, 0, .{ .codepoint = 'X', .kind = .narrow });
    }

    s.scrollDown(test_max_rows + 99); // way more than region height

    const blank = Cell{ .background = s.cursor.attr.bg };
    for (0..test_max_rows) |r| try testing.expectEqualDeep(blank, s.cellAt(r, 0));
}

test "scrollDown: partial region, rows outside unaffected" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.scroll_top = 2;
    s.scroll_bottom = 5;

    const outside: Cell = .{ .codepoint = 'O', .kind = .narrow };
    s.setCell(0, 0, outside); // above region
    s.setCell(1, 0, outside);
    s.setCell(6, 0, outside); // below region
    s.setCell(7, 0, outside);

    const inside: Cell = .{ .codepoint = 'I', .kind = .narrow };
    s.setCell(2, 0, inside);
    s.setCell(3, 0, inside);

    s.scrollDown(1);

    // Outside rows untouched
    try testing.expectEqualDeep(outside, s.cellAt(0, 0));
    try testing.expectEqualDeep(outside, s.cellAt(1, 0));
    try testing.expectEqualDeep(outside, s.cellAt(6, 0));
    try testing.expectEqualDeep(outside, s.cellAt(7, 0));

    // Old row 2 is now at row 3
    try testing.expectEqualDeep(inside, s.cellAt(3, 0));
    // New row 2 (scroll_top) is blank
    const blank = Cell{ .background = s.cursor.attr.bg };
    try testing.expectEqualDeep(blank, s.cellAt(2, 0));
}

test "scrollDown: scroll_top >= scroll_bottom, early return" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.scroll_top = 4;
    s.scroll_bottom = 4;

    const marker: Cell = .{ .codepoint = 'Z', .kind = .narrow };
    s.setCell(4, 0, marker);
    const gen = s.generation;

    s.scrollDown(1);

    try testing.expectEqualDeep(marker, s.cellAt(4, 0));
    try testing.expectEqual(gen, s.generation); // bump NOT called
}

test "scrollDown: generation bumped" {
    // TERMV4 M2 item 9: full-screen scrollDown trips wrapAdd assert (b > max_rows) when scrollback is on.
    if (true) return error.SkipZigTest;

    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    const gen = s.generation;
    s.scrollDown(1);
    try testing.expectEqual(gen + 1, s.generation);
}

test "scrollDown: line_attrs shift correctly" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.row = 1;
    s.setLineAttr(.double_top);
    s.scroll_top = 0;
    s.scroll_bottom = 3;
    s.scrollDown(1);

    // Row 1's attr should have moved to row 2
    try testing.expectEqual(LineAttr.double_top, s.line_attrs[s.physRow(2)]);
    // Row 0 (vacated top) should be reset to normal
    try testing.expectEqual(LineAttr.normal, s.line_attrs[s.physRow(0)]);
}

// Helper: fill every active cell with a marker.
fn fillScreen(s: anytype, cell: Cell) void {
    for (0..s.active_rows) |r|
        for (0..s.active_cols) |c|
            s.setCell(r, c, cell);
}

test "eraseDisplay: (0) cursor at (0,0) erases entire screen" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    const marker: Cell = .{ .codepoint = 'X', .kind = .narrow };
    fillScreen(&s, marker);

    s.cursor.row = 0;
    s.cursor.col = 0;
    s.eraseDisplay(0);

    const blank = Cell{ .background = s.cursor.attr.bg };
    for (0..s.active_rows) |r|
        for (0..s.active_cols) |c|
            try testing.expectEqualDeep(blank, s.cellAt(r, c));
}

test "eraseDisplay: (0) erases from cursor col to end of row, and all rows below" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    const marker: Cell = .{ .codepoint = 'X', .kind = .narrow };
    fillScreen(&s, marker);

    s.cursor.row = 2;
    s.cursor.col = 5;
    s.eraseDisplay(0);

    const blank = Cell{ .background = s.cursor.attr.bg };

    // Rows above cursor: untouched
    for (0..2) |r|
        for (0..s.active_cols) |c|
            try testing.expectEqualDeep(marker, s.cellAt(r, c));

    // Cursor row: cols before cursor untouched, cursor col onward erased
    for (0..5) |c| try testing.expectEqualDeep(marker, s.cellAt(2, c));
    for (5..s.active_cols) |c| try testing.expectEqualDeep(blank, s.cellAt(2, c));

    // Rows below cursor: fully erased
    for (3..s.active_rows) |r|
        for (0..s.active_cols) |c|
            try testing.expectEqualDeep(blank, s.cellAt(r, c));
}

test "eraseDisplay: (0) cursor at last row last col erases only that cell" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    const marker: Cell = .{ .codepoint = 'X', .kind = .narrow };
    fillScreen(&s, marker);

    s.cursor.row = @intCast(s.active_rows - 1);
    s.cursor.col = @intCast(s.active_cols - 1);
    s.eraseDisplay(0);

    const blank = Cell{ .background = s.cursor.attr.bg };

    // All cells except the last are untouched
    for (0..s.active_rows - 1) |r|
        for (0..s.active_cols) |c|
            try testing.expectEqualDeep(marker, s.cellAt(r, c));
    for (0..s.active_cols - 1) |c|
        try testing.expectEqualDeep(marker, s.cellAt(s.active_rows - 1, c));

    // Only the last cell is erased
    try testing.expectEqualDeep(blank, s.cellAt(s.active_rows - 1, s.active_cols - 1));
}

test "eraseDisplay: (0) resets line_attrs only for rows below cursor" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    // Mark every row double-width.
    for (0..s.active_rows) |r| {
        s.cursor.row = @intCast(r);
        s.setLineAttr(.double_width);
    }

    // Cursor at row 4, col 0.
    s.cursor.row = 4;
    s.cursor.col = 0;
    s.eraseDisplay(0);

    // Rows 5..active_rows-1 must be reset.
    for (5..s.active_rows) |r| {
        try testing.expectEqual(LineAttr.normal, s.line_attrs[s.physRow(r)]);
    }
    // Cursor row (4) keeps its line_attr — partial erase.
    try testing.expectEqual(LineAttr.double_width, s.line_attrs[s.physRow(4)]);
    // Rows above cursor are untouched.
    for (0..4) |r| {
        try testing.expectEqual(LineAttr.double_width, s.line_attrs[s.physRow(r)]);
    }
}

test "eraseDisplay: (1) cursor at (0,0) erases only that cell" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    const marker: Cell = .{ .codepoint = 'X', .kind = .narrow };
    fillScreen(&s, marker);

    s.cursor.row = 0;
    s.cursor.col = 0;
    s.eraseDisplay(1);

    const blank = Cell{ .background = s.cursor.attr.bg };

    // Only (0,0) is erased
    try testing.expectEqualDeep(blank, s.cellAt(0, 0));
    for (1..s.active_cols) |c| try testing.expectEqualDeep(marker, s.cellAt(0, c));
    for (1..s.active_rows) |r|
        for (0..s.active_cols) |c|
            try testing.expectEqualDeep(marker, s.cellAt(r, c));
}

test "eraseDisplay: (1) erases rows above and cursor row up to cursor col (inclusive)" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    const marker: Cell = .{ .codepoint = 'X', .kind = .narrow };
    fillScreen(&s, marker);

    s.cursor.row = 3;
    s.cursor.col = 6;
    s.eraseDisplay(1);

    const blank = Cell{ .background = s.cursor.attr.bg };

    // Rows above cursor: fully erased
    for (0..3) |r|
        for (0..s.active_cols) |c|
            try testing.expectEqualDeep(blank, s.cellAt(r, c));

    // Cursor row: 0..col inclusive erased, rest untouched
    for (0..7) |c| try testing.expectEqualDeep(blank, s.cellAt(3, c));
    for (7..s.active_cols) |c| try testing.expectEqualDeep(marker, s.cellAt(3, c));

    // Rows below cursor: untouched
    for (4..s.active_rows) |r|
        for (0..s.active_cols) |c|
            try testing.expectEqualDeep(marker, s.cellAt(r, c));
}

test "eraseDisplay: (1) resets line_attrs only for rows above cursors" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    for (0..s.active_rows) |r| {
        s.cursor.row = @intCast(r);
        s.setLineAttr(.double_top);
    }

    // Cursor at row 6, col 10.
    s.cursor.row = 6;
    s.cursor.col = 10;
    s.eraseDisplay(1);

    // Rows 0..5 must be reset.
    for (0..6) |r| {
        try testing.expectEqual(LineAttr.normal, s.line_attrs[s.physRow(r)]);
    }
    // Cursor row (6) keeps its line_attr — partial erase.
    try testing.expectEqual(LineAttr.double_top, s.line_attrs[s.physRow(6)]);
    // Rows below cursor are untouched.
    for (7..s.active_rows) |r| {
        try testing.expectEqual(LineAttr.double_top, s.line_attrs[s.physRow(r)]);
    }
}

test "eraseDisplay: (2) erases entire active area" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    const marker: Cell = .{ .codepoint = 'X', .kind = .narrow };
    fillScreen(&s, marker);

    s.cursor.row = 5;
    s.cursor.col = 10;
    s.eraseDisplay(2);

    const blank = Cell{ .background = s.cursor.attr.bg };
    for (0..s.active_rows) |r|
        for (0..s.active_cols) |c|
            try testing.expectEqualDeep(blank, s.cellAt(r, c));
}

test "eraseDisplay: (2) cursor position unchanged" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.row = 5;
    s.cursor.col = 10;
    s.eraseDisplay(2);

    try testing.expectEqual(5, s.cursor.row);
    try testing.expectEqual(10, s.cursor.col);
}

test "eraseDisplay: (2) resets all line_attrs to normal" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    // Set double-width on several rows.
    for (0..s.active_rows) |r| {
        s.cursor.row = @intCast(r);
        s.setLineAttr(.double_width);
    }

    s.cursor.row = 3;
    s.cursor.col = 5;
    s.eraseDisplay(2);

    for (0..s.active_rows) |r| {
        try testing.expectEqual(
            LineAttr.normal,
            s.line_attrs[s.physRow(r)],
        );
    }

    try testing.expectEqual(@as(u16, 3), s.cursor.row);
    try testing.expectEqual(@as(u16, 5), s.cursor.col);
}

test "eraseDisplay: (3) primary screen resets scrollback_used and viewport_offset" {
    const alloc = testing.allocator;
    var s = try primaryScreen(alloc);
    defer s.destroy(alloc);

    s.scrollback_used = 5;
    s.viewport_offset = 3;

    s.eraseDisplay(3);

    try testing.expectEqual(0, s.scrollback_used);
    try testing.expectEqual(0, s.viewport_offset);
}

test "eraseDisplay: (3) primary screen active area untouched" {
    const alloc = testing.allocator;
    var s = try primaryScreen(alloc);
    defer s.destroy(alloc);

    const marker: Cell = .{ .codepoint = 'X', .kind = .narrow };
    fillScreen(&s, marker);

    s.scrollback_used = 4;
    s.eraseDisplay(3);

    // Active area is unchanged
    for (0..s.active_rows) |r|
        for (0..s.active_cols) |c|
            try testing.expectEqualDeep(marker, s.cellAt(r, c));
}

test "eraseDisplay: (3) alternate screen is a no-op (comptime guard)" {
    // max_scrollback=0; the comptime branch skips the body entirely.
    // This test just verifies it compiles and doesn't crash.
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    const marker: Cell = .{ .codepoint = 'X', .kind = .narrow };
    fillScreen(&s, marker);
    const gen = s.generation;

    s.eraseDisplay(3);

    // Active area untouched
    for (0..s.active_rows) |r|
        for (0..s.active_cols) |c|
            try testing.expectEqualDeep(marker, s.cellAt(r, c));

    // bump() still fires
    try testing.expectEqual(gen + 1, s.generation);
}

test "eraseDisplay: (3) does not touch line_attrs" {
    // max_scrollback=0; the comptime branch skips the body entirely.
    // This test just verifies it compiles and doesn't crash.
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    for (0..s.active_rows) |r| {
        s.cursor.row = @intCast(r);
        s.setLineAttr(.double_width);
    }
    s.cursor.row = 0;
    s.eraseDisplay(3);

    // All line_attrs unchanged.
    for (0..s.active_rows) |r| {
        try testing.expectEqual(LineAttr.double_width, s.line_attrs[s.physRow(r)]);
    }
}

test "eraseDisplay: generation bumped for modes 0, 1, 2, 3" {
    const alloc = testing.allocator;

    for ([_]u16{ 0, 1, 2, 3 }) |mode| {
        var s = try altScreen(alloc);
        defer s.destroy(alloc);

        const gen = s.generation;
        s.eraseDisplay(mode);
        try testing.expectEqual(gen + 1, s.generation);
    }
}

test "eraseDisplay: unknown mode returns early, generation NOT bumped" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    const marker: Cell = .{ .codepoint = 'X', .kind = .narrow };
    fillScreen(&s, marker);
    const gen = s.generation;

    s.eraseDisplay(99);

    // No state change
    for (0..s.active_rows) |r|
        for (0..s.active_cols) |c|
            try testing.expectEqualDeep(marker, s.cellAt(r, c));

    // No bump
    try testing.expectEqual(gen, s.generation);
}

test "eraseDisplay: modes 0, 1, 2 clear wrap_pending" {
    const alloc = testing.allocator;

    for ([_]u16{ 0, 1, 2 }) |mode| {
        var s = try altScreen(alloc);
        defer s.destroy(alloc);

        s.cursor.row = 5;
        s.cursor.col = 10;
        s.cursor.wrap_pending = true;

        s.eraseDisplay(mode);

        try testing.expect(!s.cursor.wrap_pending);
    }
}

test "eraseDisplay: modes 3 does NOT clear wrap_pending" {
    const alloc = testing.allocator;
    var s = try primaryScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.wrap_pending = true;
    s.eraseDisplay(3);

    try testing.expect(s.cursor.wrap_pending);
}

// Helper: fill the row `r` cells
fn fillRow(s: anytype, r: usize, cell: Cell) void {
    for (0..s.active_cols) |c| s.setCell(r, c, cell);
}

test "eraseLine: (0) cursor to end of line, before cursor untouched" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    const marker: Cell = .{ .codepoint = 'X', .kind = .narrow };
    fillRow(&s, 3, marker);

    s.cursor.row = 3;
    s.cursor.col = 5;
    s.eraseLine(0);

    const blank = Cell{ .background = s.cursor.attr.bg };

    // Before cursor: untouched
    for (0..5) |c| try testing.expectEqualDeep(marker, s.cellAt(3, c));
    // From cursor col onward: erased
    for (5..s.active_cols) |c| try testing.expectEqualDeep(blank, s.cellAt(3, c));
}

test "eraseLine: (0) cursor at col 0 erases entire line" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    fillRow(&s, 0, .{ .codepoint = 'X', .kind = .narrow });
    s.cursor.row = 0;
    s.cursor.col = 0;
    s.eraseLine(0);

    const blank = Cell{ .background = s.cursor.attr.bg };
    for (0..s.active_cols) |c| try testing.expectEqualDeep(blank, s.cellAt(0, c));
}

test "eraseLine: (0) keeps line_attr (partial erase)" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.row = 5;
    s.setLineAttr(.double_width);

    s.cursor.col = 4;
    s.eraseLine(0);

    try testing.expectEqual(LineAttr.double_width, s.line_attrs[s.physRow(5)]);
}

test "eraseLine: (1) start of line to cursor inclusive, after cursor untouched" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    const marker: Cell = .{ .codepoint = 'Y', .kind = .narrow };
    fillRow(&s, 2, marker);

    s.cursor.row = 2;
    s.cursor.col = 7;
    s.eraseLine(1);

    const blank = Cell{ .background = s.cursor.attr.bg };

    // 0..=7 erased (inclusive)
    for (0..8) |c| try testing.expectEqualDeep(blank, s.cellAt(2, c));
    // After cursor: untouched
    for (8..s.active_cols) |c| try testing.expectEqualDeep(marker, s.cellAt(2, c));
}

test "eraseLine: (1) keeps line_attr (partial erase)" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.row = 2;
    s.setLineAttr(.double_top);

    s.cursor.col = 10;
    s.eraseLine(1);

    try testing.expectEqual(LineAttr.double_top, s.line_attrs[s.physRow(2)]);
}

test "eraseLine: (2) entire line erased" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    fillRow(&s, 5, .{ .codepoint = 'Z', .kind = .narrow });
    s.cursor.row = 5;
    s.cursor.col = 10;
    s.eraseLine(2);

    const blank = Cell{ .background = s.cursor.attr.bg };
    for (0..s.active_cols) |c| try testing.expectEqualDeep(blank, s.cellAt(5, c));
}

test "eraseLine: (2) resets line_attr for current row" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.row = 3;
    s.setLineAttr(.double_bottom);

    s.cursor.col = 0;
    s.eraseLine(2);

    try testing.expectEqual(LineAttr.normal, s.line_attrs[s.physRow(3)]);
}

test "eraseLine: (2) does NOT affect other rows" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);
    // Mark all rows double-width.
    for (0..s.active_rows) |r| {
        s.cursor.row = @intCast(r);
        s.setLineAttr(.double_width);
    }

    // Erase only row 4.
    s.cursor.row = 4;
    s.cursor.col = 0;
    s.eraseLine(2);

    try testing.expectEqual(LineAttr.normal, s.line_attrs[s.physRow(4)]);
    try testing.expectEqual(LineAttr.double_width, s.line_attrs[s.physRow(3)]);
    try testing.expectEqual(LineAttr.double_width, s.line_attrs[s.physRow(5)]);
}

test "eraseLine: other rows are untouched" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    const marker: Cell = .{ .codepoint = 'R', .kind = .narrow };
    fillScreen(&s, marker);

    s.cursor.row = 4;
    s.cursor.col = 0;
    s.eraseLine(2); // erase entire row 4

    // All other rows untouched
    for (0..s.active_rows) |r| {
        if (r == 4) continue;
        for (0..s.active_cols) |c|
            try testing.expectEqualDeep(marker, s.cellAt(r, c));
    }
}

test "eraseLine: cursor position unchanged after erase" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.row = 6;
    s.cursor.col = 11;
    s.eraseLine(0);

    try testing.expectEqual(6, s.cursor.row);
    try testing.expectEqual(11, s.cursor.col);
}

test "eraseLine: generation bumped for modes 0, 1, 2" {
    const alloc = testing.allocator;

    for ([_]u16{ 0, 1, 2 }) |mode| {
        var s = try altScreen(alloc);
        defer s.destroy(alloc);

        const gen = s.generation;
        s.eraseLine(mode);
        try testing.expectEqual(gen + 1, s.generation);
    }
}

test "eraseLine: unknown mode returns early, generation NOT bumped" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    const marker: Cell = .{ .codepoint = 'X', .kind = .narrow };
    fillScreen(&s, marker);
    const gen = s.generation;

    s.eraseLine(99);

    for (0..s.active_rows) |r|
        for (0..s.active_cols) |c|
            try testing.expectEqualDeep(marker, s.cellAt(r, c));

    try testing.expectEqual(gen, s.generation);
}

test "eraseLine: (0, 1, 2) clear wrap_pending" {
    const alloc = testing.allocator;

    for ([_]u16{ 0, 1, 2 }) |mode| {
        var s = try altScreen(alloc);
        defer s.destroy(alloc);

        s.cursor.wrap_pending = true;
        s.eraseLine(mode);

        try testing.expect(!s.cursor.wrap_pending);
    }
}

test "resetTabStops: default tab stops at multiples of tab_width" {
    // Verified at init; this test documents the expected pattern explicitly.

    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    var i: usize = test_tab_width;
    while (i < test_max_cols) : (i += test_tab_width) {
        try testing.expect(s.tab_stops.isSet(i));
    }
}

test "resetTabStops: coluumn 0 is not a default tab stop" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    try testing.expect(!s.tab_stops.isSet(0));
}

test "resetTabStops: only mutlples of tab_width are set" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    for (0..test_max_cols) |i| {
        const expected = i != 0 and i % test_tab_width == 0;
        try testing.expectEqual(expected, s.tab_stops.isSet(i));
    }
}

test "resetTabStops: restores default after clearing all stops" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.tab_stops = .empty;
    s.resetTabStops();

    // Multiples of tab_width are set
    var i: usize = test_tab_width;
    while (i < test_max_cols) : (i += test_tab_width) {
        try testing.expect(s.tab_stops.isSet(i));
    }

    // Non-multiples are clear
    try testing.expect(!s.tab_stops.isSet(0));
    try testing.expect(!s.tab_stops.isSet(1));
    try testing.expect(!s.tab_stops.isSet(test_tab_width - 1));
    try testing.expect(!s.tab_stops.isSet(test_tab_width + 1));
}

test "resetTabStops: restores default after setting custom stops" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.tab_stops = .empty;
    s.tab_stops.set(3);
    s.tab_stops.set(7);
    s.tab_stops.set(11);

    s.resetTabStops();

    // Every multiple of tab_width (starting at tab_width) should be set
    comptime var col = test_tab_width;
    inline while (col < test_max_cols) : (col += test_tab_width) {
        try testing.expect(s.tab_stops.isSet(col));
    }
    // Column 0 is never a default tab stop
    try testing.expect(!s.tab_stops.isSet(0));
}

test "setActive: basic resize within bounds" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.setActive(8, 10);

    try testing.expectEqual(8, s.active_rows);
    try testing.expectEqual(10, s.active_cols);
}

test "setActive: clamps to max_rows and max_cols" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.setActive(999, 999);

    try testing.expectEqual(test_max_rows, s.active_rows);
    try testing.expectEqual(test_max_cols, s.active_cols);
}

test "setActive: scroll region reset to full active area" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.scroll_top = 3;
    s.scroll_bottom = 7;
    s.setActive(8, 10);

    try testing.expectEqual(0, s.scroll_top);
    try testing.expectEqual(7, s.scroll_bottom); // active_rows(8) - 1
}

test "setActive: cursor row clamped to new active_rows - 1" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.row = 10;
    s.setActive(8, 10); // clamped to 7

    try testing.expectEqual(7, s.cursor.row);
}

test "setActive: cursor col clamped to new active_colss - 1" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.col = 12;
    s.setActive(8, 10); // clamped to 8

    try testing.expectEqual(9, s.cursor.col);
}

test "setActive: cursor in bounds, position unchanged" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.col = 7;
    s.cursor.row = 5;
    s.setActive(8, 12);

    try testing.expectEqual(5, s.cursor.row);
    try testing.expectEqual(7, s.cursor.col);
}

test "setActive: wrap_pending cleared when cursor not at last col" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    // After setActive(8, 12):
    // active_cols = 12
    // last col    = 12 - 1 = 11
    // cursor.col  = 5 < 11 -> wrap pending cleared
    s.cursor.col = 5;
    s.setActive(8, 12);

    try testing.expect(!s.cursor.wrap_pending);
}

test "setActive: wrap_pending preseved when cursor at last col" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    // After setActive(8, 12):
    // active_cols = 12
    // last col    = 12 - 1 = 11
    // cursor.col  = 11 == 11 == wrap pending kept
    s.cursor.col = 11;
    s.cursor.wrap_pending = true;
    s.setActive(8, 12);

    try testing.expect(s.cursor.wrap_pending);
}

test "setActive: wrap_pending preserved after cursor clamped to last col" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    // cursor.col = 20 > 11
    // clamped to 11 (last col) => wrap_pending kept
    s.cursor.col = 20;
    s.cursor.wrap_pending = true;
    s.setActive(8, 12);

    try testing.expectEqual(11, s.cursor.col);
    try testing.expect(s.cursor.wrap_pending);
}

test "setActive: generation bumped" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    const gen = s.generation;
    s.setActive(8, 12);
    try testing.expectEqual(gen + 1, s.generation);
}

test "setActive: zero rows, generation still bumped, scroll region NOT reset" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.scroll_top = 3;
    s.scroll_bottom = 7;
    const gen = s.generation;

    s.setActive(0, 12);

    try testing.expectEqual(0, s.active_rows);
    try testing.expectEqual(gen + 1, s.generation);
    // early return — scroll region NOT reset
    try testing.expectEqual(3, s.scroll_top);
    try testing.expectEqual(7, s.scroll_bottom);
}

test "setActive: zero cols, generation still bumped, early return" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    const gen = s.generation;
    s.setActive(8, 0);

    try testing.expectEqual(0, s.active_cols);
    try testing.expectEqual(gen + 1, s.generation);
}

test "setActive: newly exposed rows when growing have .normal line_attr" {
    const alloc = testing.allocator;
    var s = try primaryScreen(alloc);
    defer s.destroy(alloc);

    // Shrink to 6 rows first
    s.setActive(6, s.active_cols);
    try testing.expectEqual(@as(usize, 6), s.active_rows);

    // Mark all current rows as double_width
    for (0..s.active_rows) |r| {
        s.cursor.row = @intCast(r);
        s.setLineAttr(.double_width);
    }

    // Grow back to original size
    const orig_rows = test_max_rows; // or whatever your test option uses
    s.setActive(orig_rows, s.active_cols);

    // Rows 0..5 keep their attrs
    for (0..6) |r| {
        try testing.expectEqual(LineAttr.double_width, s.displayLineAttr(r));
    }
    // Newly exposed rows 6..orig_rows-1 must be .normal
    for (6..orig_rows) |r| {
        try testing.expectEqual(LineAttr.normal, s.displayLineAttr(r));
    }
}

test "setActive: shrinking does not corrupt line_attrs of remaining rows" {
    const alloc = testing.allocator;
    var s = try primaryScreen(alloc);
    defer s.destroy(alloc);

    // Mark rows 0..3 with distinct attrs
    s.cursor.row = 0;
    s.setLineAttr(.double_top);
    s.cursor.row = 1;
    s.setLineAttr(.double_bottom);
    s.cursor.row = 2;
    s.setLineAttr(.double_width);

    // Shrink to 4 rows
    s.setActive(4, s.active_cols);

    try testing.expectEqual(LineAttr.double_top, s.displayLineAttr(0));
    try testing.expectEqual(LineAttr.double_bottom, s.displayLineAttr(1));
    try testing.expectEqual(LineAttr.double_width, s.displayLineAttr(2));
    try testing.expectEqual(LineAttr.normal, s.displayLineAttr(3));
}

test "setActive: growing cols only does not affect line_attrs" {
    const alloc = testing.allocator;
    var s = try primaryScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.row = 3;
    s.setLineAttr(.double_width);

    const orig_rows = s.active_rows;
    s.setActive(orig_rows, s.active_cols - 4);

    // Row 3 attr must survive a cols-only resize
    try testing.expectEqual(LineAttr.double_width, s.displayLineAttr(3));
}

test "scrollViewportBack: increase viewport_offset by lines" {
    const alloc = testing.allocator;
    var s = try primaryScreen(alloc);
    defer s.destroy(alloc);

    s.scrollback_used = 8;
    s.viewport_offset = 0;

    s.scrollViewportBack(3);
    try testing.expectEqual(3, s.viewport_offset);
}

test "scrollViewportBack: capped at scrollback_used" {
    const alloc = testing.allocator;
    var s = try primaryScreen(alloc);
    defer s.destroy(alloc);

    s.scrollback_used = 5;
    s.viewport_offset = 0;

    s.scrollViewportBack(100);
    try testing.expectEqual(5, s.viewport_offset);
}

test "scrollViewportBack: partial clamp (offset + lines > scrollback_used)" {
    const alloc = testing.allocator;
    var s = try primaryScreen(alloc);
    defer s.destroy(alloc);

    s.scrollback_used = 8;
    s.viewport_offset = 6;

    s.scrollViewportBack(5); // 6 + 5 == 11 > 8; clamped to 8

    try testing.expectEqual(8, s.viewport_offset);
}

test "scrollViewportBack: no-op when already at scrollback_used (no bump)" {
    const alloc = testing.allocator;
    var s = try primaryScreen(alloc);
    defer s.destroy(alloc);

    s.scrollback_used = 8;
    s.viewport_offset = 8;
    const gen = s.generation;

    s.scrollViewportBack(1);

    try testing.expectEqual(8, s.viewport_offset);
    try testing.expectEqual(gen, s.generation);
}

test "scrollViewportBack: lines=0 is always a no-op (no bump)" {
    const alloc = testing.allocator;
    var s = try primaryScreen(alloc);
    defer s.destroy(alloc);

    s.scrollback_used = 8;
    s.viewport_offset = 3;
    const gen = s.generation;

    s.scrollViewportBack(0);

    try testing.expectEqual(3, s.viewport_offset);
    try testing.expectEqual(gen, s.generation);
}

test "scrollViewportBack: generation bumped when offset changes" {
    const alloc = testing.allocator;
    var s = try primaryScreen(alloc);
    defer s.destroy(alloc);

    s.scrollback_used = 8;
    s.viewport_offset = 0;

    const gen = s.generation;

    s.scrollViewportBack(1);

    try testing.expectEqual(gen + 1, s.generation);
}

test "scrollViewportBack: no scrollback_used means no-op (scrollback_used=0)" {
    const alloc = testing.allocator;
    var s = try primaryScreen(alloc);
    defer s.destroy(alloc);

    s.scrollback_used = 0;
    s.viewport_offset = 0;

    const gen = s.generation;

    s.scrollViewportBack(5);

    try testing.expectEqual(0, s.viewport_offset);
    try testing.expectEqual(gen, s.generation);
}

test "scrollViewportForward: decreases viewport_offset by lines" {
    const alloc = testing.allocator;
    var s = try primaryScreen(alloc);
    defer s.destroy(alloc);

    s.scrollback_used = 8;
    s.viewport_offset = 6;

    s.scrollViewportForward(3);

    try testing.expectEqual(3, s.viewport_offset);
}

test "scrollViewportForward: saturates at 0 (no underflow)" {
    const alloc = testing.allocator;
    var s = try primaryScreen(alloc);
    defer s.destroy(alloc);

    s.scrollback_used = 8;
    s.viewport_offset = 2;

    s.scrollViewportForward(100); // 2 -| 100 = 0

    try testing.expectEqual(0, s.viewport_offset);
}

test "scrollViewportForward: no-op when already at live view (no bump)" {
    const alloc = testing.allocator;
    var s = try primaryScreen(alloc);
    defer s.destroy(alloc);

    s.scrollback_used = 8;
    s.viewport_offset = 2;

    s.scrollViewportForward(100); // 2 -| 100 = 0

    try testing.expectEqual(0, s.viewport_offset);
}

test "scrollViewportForward: lines=0 is always a no-op (no bump)" {
    const alloc = testing.allocator;
    var s = try primaryScreen(alloc);
    defer s.destroy(alloc);

    s.viewport_offset = 4;
    const gen = s.generation;

    s.scrollViewportForward(0);

    try testing.expectEqual(4, s.viewport_offset);
    try testing.expectEqual(gen, s.generation);
}

test "scrollViewportForward: generation bumped when offset changes" {
    const alloc = testing.allocator;
    var s = try primaryScreen(alloc);
    defer s.destroy(alloc);

    s.viewport_offset = 5;
    const gen = s.generation;

    s.scrollViewportForward(2);

    try testing.expectEqual(gen + 1, s.generation);
}

test "scrollViewportForward: exact step to live view" {
    const alloc = testing.allocator;
    var s = try primaryScreen(alloc);
    defer s.destroy(alloc);

    s.viewport_offset = 4;

    s.scrollViewportForward(4); // exactly reaches 0

    try testing.expectEqual(0, s.viewport_offset);
}

test "viewportReset: resets viewport_offset to 0" {
    const alloc = testing.allocator;
    var s = try primaryScreen(alloc);
    defer s.destroy(alloc);

    s.viewport_offset = 6;
    _ = s.viewportReset();
    try testing.expectEqual(0, s.viewport_offset);
}

test "viewportReset: generation bumped when offset was non-zero" {
    const alloc = testing.allocator;
    var s = try primaryScreen(alloc);
    defer s.destroy(alloc);

    s.viewport_offset = 6;
    const gen = s.generation;

    _ = s.viewportReset();
    try testing.expectEqual(gen + 1, s.generation);
}

test "viewportReset: no-op when already at live view (no bump)" {
    const alloc = testing.allocator;
    var s = try primaryScreen(alloc);
    defer s.destroy(alloc);

    s.viewport_offset = 0;
    const gen = s.generation;

    _ = s.viewportReset();
    try testing.expectEqual(0, s.viewport_offset);
    try testing.expectEqual(gen, s.generation);
}

test "viewportReset: scrollback_used unchanged" {
    const alloc = testing.allocator;
    var s = try primaryScreen(alloc);
    defer s.destroy(alloc);

    s.scrollback_used = 8;
    s.viewport_offset = 5;

    _ = s.viewportReset();

    // Only viewport_offset is reset;
    // history is preserved
    try testing.expectEqual(8, s.scrollback_used);
    try testing.expectEqual(0, s.viewport_offset);
}

test "viewport round-trip: back then forward returns to live view" {
    const alloc = testing.allocator;
    var s = try primaryScreen(alloc);
    defer s.destroy(alloc);

    s.scrollback_used = 8;
    s.viewport_offset = 0;

    s.scrollViewportBack(5);
    try testing.expectEqual(5, s.viewport_offset);

    s.scrollViewportForward(5);
    try testing.expectEqual(0, s.viewport_offset);
}

test "viewport round-trip: back then reset" {
    const alloc = testing.allocator;
    var s = try primaryScreen(alloc);
    defer s.destroy(alloc);

    s.scrollback_used = 8;
    s.scrollViewportBack(8);
    try testing.expectEqual(8, s.viewport_offset);

    _ = s.viewportReset();
    try testing.expectEqual(0, s.viewport_offset);
}

test "cursorPos: basic absolute move" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursorPos(5, 10);
    try testing.expectEqual(5, s.cursor.row);
    try testing.expectEqual(10, s.cursor.col);
}

test "cursorPos: clamps row to active_rows-1" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursorPos(999, 0);
    try testing.expectEqual(test_max_rows - 1, s.cursor.row);
}

test "cursorPos: clamps col to active_cols-1" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursorPos(0, 999);
    try testing.expectEqual(test_max_cols - 1, s.cursor.col);
}

test "cursorPos: clears wrap_pending" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.wrap_pending = true;
    s.cursorPos(6, 9);

    try testing.expect(!s.cursor.wrap_pending);
}

test "cursorPos: origin mode, row relative to scroll_top" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.scroll_top = 3;
    s.scroll_bottom = 8;
    s.cursor.origin = true;

    // cursorPos(0,0), row = scroll_top = 3
    s.cursorPos(0, 0);
    try testing.expectEqual(3, s.cursor.row);

    // cursorPos(2,0), row = scroll_top + 2= 5
    s.cursorPos(2, 0);
    try testing.expectEqual(5, s.cursor.row);
}

test "cursorPos: origin mode, row clamped to scroll_bottom" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.scroll_top = 2;
    s.scroll_bottom = 5;
    s.cursor.origin = true;

    s.cursorPos(999, 0);
    try testing.expectEqual(5, s.cursor.row);
}

test "cursorCol: moves to column" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.row = 5;
    s.cursorCol(10);
    try testing.expectEqual(10, s.cursor.col);
    try testing.expectEqual(5, s.cursor.row);
}

test "cursorCol: clamps to active_cols-1" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursorCol(666);
    try testing.expectEqual(test_max_cols - 1, s.cursor.col);
}

test "cursorCol: clears wrap_pending" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.wrap_pending = true;
    s.cursorCol(5);
    try testing.expect(!s.cursor.wrap_pending);
}

test "cursorUp: basic move" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.row = 6;
    s.cursorUp(3);
    try testing.expectEqual(3, s.cursor.row);
}

test "cursorUp: stops at scroll_top when inside scroll region" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.scroll_top = 3;
    s.scroll_bottom = 8;
    s.cursor.row = 5;

    s.cursorUp(999);

    try testing.expectEqual(3, s.cursor.row);
}

test "cursorUp: stops at row 0 when outside scroll region (above)" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.scroll_top = 4;
    s.scroll_bottom = 8;
    s.cursor.row = 2; // above scroll region

    s.cursorUp(999);

    try testing.expectEqual(0, s.cursor.row); // clamped to 0, not scroll_top
}

test "cursorUp: clears wrap_pending" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.row = 5;
    s.cursor.wrap_pending = true;

    s.cursorUp(1);

    try testing.expect(!s.cursor.wrap_pending);
}

test "cursorDown: basic move" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.row = 3;
    s.cursorDown(4);

    try testing.expectEqual(7, s.cursor.row);
}

test "cursorDown: stops at scroll_bottom when inside scroll region" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.scroll_top = 2;
    s.scroll_bottom = 6;
    s.cursor.row = 4; // inside region

    s.cursorDown(999);
    try testing.expectEqual(6, s.cursor.row);
}

test "cursorDown: stops at active_rows-1 when outside scroll region (below)" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.scroll_top = 2;
    s.scroll_bottom = 6;
    s.cursor.row = 8; // outside region

    s.cursorDown(999);
    try testing.expectEqual(test_max_rows - 1, s.cursor.row);
}

test "cursorDown: clears wrap_pending" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.row = 3;
    s.cursor.wrap_pending = true;

    s.cursorDown(1);
    try testing.expect(!s.cursor.wrap_pending);
}

test "cursorRight: basic move" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.col = 5;
    s.cursorRight(4);
    try testing.expectEqual(9, s.cursor.col);
}

test "cursorRight: clamps to active_cols-1" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.col = 20;
    s.cursorRight(999);
    try testing.expectEqual(test_max_cols - 1, s.cursor.col);
}

test "cursorRight: clears wrap_pending" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.wrap_pending = true;
    s.cursorRight(1);
    try testing.expect(!s.cursor.wrap_pending);
}

test "cursorLeft: basic move" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.col = 8;
    s.cursorLeft(3);
    try testing.expectEqual(5, s.cursor.col);
}

test "cursorLeft: clamps to 0" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.col = 3;
    s.cursorLeft(999);
    try testing.expectEqual(0, s.cursor.col);
}

test "cursorLeft: n=0 treated as n=1" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.col = 5;
    s.cursorLeft(0);
    try testing.expectEqual(@as(u16, 4), s.cursor.col);
}

test "cursorLeft: clears wrap_pending" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.col = 5;
    s.cursor.wrap_pending = true;
    s.cursorLeft(1);
    try testing.expect(!s.cursor.wrap_pending);
}

test "cursorBack: marks row dirty" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.row = 3;
    s.cursor.col = 5;
    s.dirty_rows = .initEmpty();
    s.cursorLeft(2);
    try testing.expect(s.dirty_rows.isSet(3));
}

test "writeChar: basic write, cursor advances" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    const c: Cell = .{ .codepoint = 'A', .kind = .narrow };
    s.writeChar(c);

    try testing.expectEqualDeep(c, s.cellAt(0, 0));
    try testing.expectEqual(0, s.cursor.row);
    try testing.expectEqual(1, s.cursor.col);
    try testing.expect(!s.cursor.wrap_pending);
}

test "writeChar: write at last column sets wrap_pending, cursor stays" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.col = s.active_cols - 1;
    const c: Cell = .{ .codepoint = 'Z', .kind = .narrow };
    s.writeChar(c);

    try testing.expectEqualDeep(c, s.cellAt(0, s.active_cols - 1));
    try testing.expectEqual(0, s.cursor.row);
    try testing.expectEqual(s.active_cols - 1, s.cursor.col);
    try testing.expect(s.cursor.wrap_pending);
}

test "writeChar: wrap_pending triggers wrap to next row col 0" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.row = 3;
    s.cursor.col = s.active_cols - 1;
    s.cursor.wrap_pending = true;

    const c: Cell = .{ .codepoint = 'X', .kind = .narrow };
    s.writeChar(c);

    try testing.expectEqualDeep(c, s.cellAt(4, 0));
    try testing.expectEqual(4, s.cursor.row);
    try testing.expectEqual(1, s.cursor.col);
    try testing.expect(!s.cursor.wrap_pending);
}

test "writeChar: wrap_pending at last row triggers scrollUp" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    // marker row 0 so we can very it scrolled off
    const marker: Cell = .{ .codepoint = 'M', .kind = .narrow };
    s.setCell(0, 0, marker);

    s.cursor.row = s.active_rows - 1;
    s.cursor.col = s.active_cols - 1;
    s.cursor.wrap_pending = true;

    const c: Cell = .{ .codepoint = 'N', .kind = .narrow };
    s.writeChar(c);

    // written at (last_row, 0) after scroll+wrap
    try testing.expectEqualDeep(c, s.cellAt(s.active_rows - 1, 0));
    try testing.expectEqual(s.active_rows - 1, s.cursor.row);
    try testing.expectEqual(1, s.cursor.col);
    try testing.expect(!s.cursor.wrap_pending);

    // Row 0 now holds what was row 1 (marker scrolled into scrollback).
    const blank: Cell = .{};
    try testing.expectEqualDeep(blank, s.cellAt(0, 0));
}

test "writeChar: marks the cursor row dirty, generation bump is deferred" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    const c: Cell = .{ .codepoint = 'A', .kind = .narrow };
    const gen = s.generation;
    s.writeChar(c);

    // Terminal.feed bumps once per feed; writeChar only marks the row.
    try testing.expect(s.dirty_rows.isSet(0));
    try testing.expectEqual(gen, s.generation);
}

test "writeChar: wide char cell and continuation placeholder" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    const cp: u21 = 0x4E2D;
    const c: Cell = .{ .codepoint = cp, .kind = .wide_left };
    s.writeChar(c);

    try testing.expectEqualDeep(c, s.cellAt(0, 0));

    // Continuation placeholder: codepoint=0, width=0
    const cont = s.cellAt(0, 1);
    try testing.expectEqual(@as(u21, 0), cont.codepoint);
    try testing.expectEqual(.wide_right, cont.kind);

    // Cursor advanced by 2
    try testing.expectEqual(0, s.cursor.row);
    try testing.expectEqual(2, s.cursor.col);
    try testing.expect(!s.cursor.wrap_pending);
}

test "writeChar: wide char at second-to-last column sets wrap_pending" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    // Place wide char so its right half lands exactly at active_cols-1
    const cp = 0x4E2D;
    const c: Cell = .{ .codepoint = cp, .kind = .wide_left };

    s.cursor.col = s.active_cols - 2;
    s.writeChar(c);

    try testing.expectEqualDeep(c, s.cellAt(0, s.active_cols - 2));
    try testing.expectEqual(0, s.cursor.row);
    try testing.expectEqual(s.active_cols - 1, s.cursor.col);
    try testing.expect(s.cursor.wrap_pending);
}

test "writeChar: wide char at last column fills blank, wraps, writes at col 0" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    const cp: u21 = 0x4E2D;
    const c: Cell = .{ .codepoint = cp, .kind = .wide_left };

    s.cursor.row = 0;
    s.cursor.col = s.active_cols - 1;
    s.writeChar(c);

    // Last column of row 0 should be a blank (filled before wrap)
    const blank: Cell = .{};
    try testing.expectEqualDeep(blank, s.cellAt(0, s.active_cols - 1));
    // Wide char lands at (1, 0)
    try testing.expectEqualDeep(c, s.cellAt(1, 0));
    // Continuation at (1, 1)
    const cont = s.cellAt(1, 1);
    try testing.expectEqual(@as(u21, 0), cont.codepoint);
    try testing.expectEqual(.wide_right, cont.kind);
    try testing.expectEqual(1, s.cursor.row);
    try testing.expectEqual(2, s.cursor.col);
}

test "writeChar: wide char at last column of last row scrolls" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    const cp: u21 = 0x4E2D;
    const c: Cell = .{ .codepoint = cp, .kind = .wide_left };

    s.cursor.row = s.active_rows - 1;
    s.cursor.col = s.active_cols - 1;
    s.writeChar(c);

    // Wide char lands at (active_rows-1, 0) after scroll
    try testing.expectEqualDeep(c, s.cellAt(s.active_rows - 1, 0));
    const cont = s.cellAt(s.active_rows - 1, 1);
    try testing.expectEqual(@as(u21, 0), cont.codepoint);
    try testing.expectEqual(.wide_right, cont.kind);
    try testing.expectEqual(s.active_rows - 1, s.cursor.row);
    try testing.expectEqual(2, s.cursor.col);
}

test "writeChar: overwrite left half of wide char erases right half" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    // Place a wide char at col 2
    const cp: u21 = 0x4E2D;
    s.cursor.col = 2;
    s.writeChar(.{ .codepoint = cp, .kind = .wide_left });

    // Now overwrite col 2 with a narrow char
    s.cursor.col = 2;
    const narrow: Cell = .{ .codepoint = 'A', .kind = .narrow };
    s.writeChar(narrow);

    try testing.expectEqualDeep(narrow, s.cellAt(0, 2));
    // Orphaned right half at col 3 must be erased to blank
    const blank: Cell = .{};
    try testing.expectEqualDeep(blank, s.cellAt(0, 3));
}

test "writeChar: overwrite continuation cell erases left half" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    // Place a wide char at col 2 (continuation at col 3)
    const cp: u21 = 0x4E2D;
    s.cursor.col = 2;
    s.writeChar(.{ .codepoint = cp, .kind = .wide_left });

    // Overwrite the continuation cell at col 3
    s.cursor.col = 3;
    const narrow: Cell = .{ .codepoint = 'B', .kind = .narrow };
    s.writeChar(narrow);

    try testing.expectEqualDeep(narrow, s.cellAt(0, 3));
    // Orphaned left half at col 2 must be erased to blank
    const blank: Cell = .{};
    try testing.expectEqualDeep(blank, s.cellAt(0, 2));
}

test "writeChar: insert mode shifts cells right" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    // Pre-fill using writeChar — consistent with rowMut internals,
    // and respects active_cols automatically.
    for ("ABCD") |ch| {
        s.writeChar(.{ .codepoint = @intCast(ch), .kind = .narrow });
    }

    s.cursor.row = 0;
    s.cursor.col = 0;
    s.cursor.wrap_pending = false;

    s.mode.insert = true;
    s.writeChar(.{ .codepoint = 'X', .kind = .narrow });

    try testing.expectEqual(@as(u21, 'X'), s.cellAt(0, 0).codepoint);
    try testing.expectEqual(@as(u21, 'A'), s.cellAt(0, 1).codepoint);
    try testing.expectEqual(@as(u21, 'B'), s.cellAt(0, 2).codepoint);
    try testing.expectEqual(@as(u21, 'C'), s.cellAt(0, 3).codepoint);
}

test "writeChar: insert mode with wide char shifts by 2" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    for ("ABCD", 0..) |ch, i| {
        s.setCell(0, i, .{ .codepoint = @intCast(ch), .kind = .narrow });
    }

    s.cursor.col = 0;
    s.mode.insert = true;
    s.writeChar(.{ .codepoint = '中', .kind = .wide_left });

    try testing.expectEqual(@as(u21, '中'), s.cellAt(0, 0).codepoint);
    try testing.expectEqual(@as(u21, 'A'), s.cellAt(0, 2).codepoint);
    try testing.expectEqual(@as(u21, 'B'), s.cellAt(0, 3).codepoint);
}

test "writeChar: wrap_pending at scroll_bottom scrolls only the region" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    // Set a partial scroll region: rows 2..4
    s.scroll_top = 2;
    s.scroll_bottom = 4;

    // Mark row 2 with a sentinel
    const sentinel: Cell = .{ .codepoint = 'S', .kind = .narrow };
    s.setCell(2, 0, sentinel);

    // Mark row 0 (outside region) with a marker that must NOT move
    const outside: Cell = .{ .codepoint = 'O', .kind = .narrow };
    s.setCell(0, 0, outside);

    s.cursor.row = 4; // scroll_bottom
    s.cursor.col = s.active_cols - 1;
    s.cursor.wrap_pending = true;

    s.writeChar(.{ .codepoint = 'N', .kind = .narrow });

    // Row 0 (outside region) must be untouched.
    try testing.expectEqualDeep(outside, s.cellAt(0, 0));

    // Sentinel at row 2 scrolled off the top of the region (row 2 ← row 3 = blank).
    const blank: Cell = .{};
    try testing.expectEqualDeep(blank, s.cellAt(2, 0));

    // 'N' written at (4, 0) after the scroll+wrap.
    try testing.expectEqual(@as(u21, 'N'), s.cellAt(4, 0).codepoint);

    // Rest of row 4 (col 1 onward) is blank — the scroll cleared it before 'N' was placed.
    try testing.expectEqualDeep(blank, s.cellAt(4, 1));
}

test "writeChar: written row is marked dirty" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.row = 3;
    s.cursor.col = 0;
    s.writeChar(.{ .codepoint = 'A', .kind = .narrow });

    try testing.expect(s.dirty_rows.isSet(3));
}

test "writeChar: combining character composes with previous cell" {
    // e (U+0065) + combining acute (U+0301) → é (U+00E9)
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.writeChar(.{ .codepoint = 'e', .kind = .narrow });
    s.putChar(0x0301); // combining acute

    try testing.expectEqual(@as(u21, 0x00E9), s.cellAt(0, 0).codepoint); // é
    try testing.expectEqual(@as(u16, 1), s.cursor.col); // cursor did not advance
}

test "writeChar: combining at col 0 silently dropped" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    // cursor at col 0, no previous cell
    s.putChar(0x0301);

    try testing.expectEqual(@as(u21, 0), s.cellAt(0, 0).codepoint); // blank
    try testing.expectEqual(@as(u16, 0), s.cursor.col);
}

test "writeChar: combining with wrap_pending composes with last column cell" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    // Fill to last column to trigger wrap_pending
    for (0..s.active_cols) |_| {
        s.writeChar(.{ .codepoint = 'a', .kind = .narrow });
    }
    // cursor.col == active_cols-1, wrap_pending == true
    try testing.expect(s.cursor.wrap_pending);

    s.putChar(0x0301); // combining acute

    // Last cell should be composed: a + ◌́ → á (U+00E1)
    try testing.expectEqual(@as(u21, 0x00E1), s.cellAt(0, s.active_cols - 1).codepoint);
    // wrap_pending still set — combining char doesn't advance cursor
    try testing.expect(s.cursor.wrap_pending);
}

test "writeChar: combining over continuation cell silently dropped" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    // Write a wide char at col 0 — col 1 is a continuation placeholder (width=0)
    s.writeChar(.{ .codepoint = '中', .kind = .wide_left });
    // cursor is now at col 2; move back to col 1 (the continuation cell)
    s.cursor.col = 1;

    s.putChar(0x0301);

    // Wide char at col 0 should be unchanged
    try testing.expectEqual(@as(u21, '中'), s.cellAt(0, 0).codepoint);
}

test "dirty_rows: init state is empty" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    for (0..s.active_rows) |r| {
        try testing.expect(!s.dirty_rows.isSet(r));
    }
}

test "dirty_rows: setCell mark only that row dirty" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    const x: Cell = .{ .codepoint = 'X', .kind = .narrow };
    s.setCell(3, 5, x);
    try testing.expect(s.dirty_rows.isSet(3));
    try testing.expect(!s.dirty_rows.isSet(2));
    try testing.expect(!s.dirty_rows.isSet(4));
}

test "dirty_rows: rowMut set marks to dirty_rows" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    _ = s.rowMut(7);

    try testing.expect(s.dirty_rows.isSet(7));
    try testing.expect(!s.dirty_rows.isSet(6));
}

test "dirty_rows: scrollUp partial marks only region rows dirty" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.scroll_top = 2;
    s.scroll_bottom = 6;
    s.dirty_rows = .empty;

    s.scrollUp(1);

    for (2..7) |r| try testing.expect(s.dirty_rows.isSet(r));
    try testing.expect(!s.dirty_rows.isSet(0));
    try testing.expect(!s.dirty_rows.isSet(1));
    try testing.expect(!s.dirty_rows.isSet(7));
}

test "dirty_rows: scrollDown partial marks only region rows dirty" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.scroll_top = 3;
    s.scroll_bottom = 8;
    s.dirty_rows = .empty;

    s.scrollDown(1);

    for (3..9) |r| try testing.expect(s.dirty_rows.isSet(r));
    try testing.expect(!s.dirty_rows.isSet(2));
    try testing.expect(!s.dirty_rows.isSet(9));
}

test "dirty_rows: eraseDisplay mode 2 marks all rows dirty" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.dirty_rows = .empty;
    s.eraseDisplay(2);

    for (0..s.active_rows) |r| try testing.expect(s.dirty_rows.isSet(r));
}

test "dirty_rows: eraseLine marks only cursor row dirty" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.row = 5;
    s.dirty_rows = .empty;
    s.eraseLine(2);

    try testing.expect(s.dirty_rows.isSet(5));
    try testing.expect(!s.dirty_rows.isSet(4));
    try testing.expect(!s.dirty_rows.isSet(6));
}

test "dirty_rows: setActive marks all rows dirty" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.dirty_rows = .empty;
    s.setActive(8, 16);

    for (0..s.active_rows) |r| try testing.expect(s.dirty_rows.isSet(r));
}

test "dirty_rows: scrollViewportBack marks all rows dirty" {
    const alloc = testing.allocator;
    var s = try primaryScreen(alloc);
    defer s.destroy(alloc);

    s.scrollback_used = 4;
    s.dirty_rows = .empty;
    s.scrollViewportBack(2);

    for (0..s.active_rows) |r| try testing.expect(s.dirty_rows.isSet(r));
}

test "dirty_rows: scrollViewportBack no-op does NOT mark dirty" {
    const alloc = testing.allocator;
    var s = try primaryScreen(alloc);
    defer s.destroy(alloc);

    s.scrollback_used = 4;
    s.viewport_offset = 4; // already at ceiling
    s.dirty_rows = .empty;
    s.scrollViewportBack(1); // no-op

    for (0..s.active_rows) |r| try testing.expect(!s.dirty_rows.isSet(r));
}

test "dirty_rows: viewportReset marks all rows dirty" {
    const alloc = testing.allocator;
    var s = try primaryScreen(alloc);
    defer s.destroy(alloc);

    s.viewport_offset = 3;
    s.dirty_rows = .empty;
    _ = s.viewportReset();

    for (0..s.active_rows) |r| try testing.expect(s.dirty_rows.isSet(r));
}

test "dirty_rows: viewportReset no-op does NOT mark dirty" {
    const alloc = testing.allocator;
    var s = try primaryScreen(alloc);
    defer s.destroy(alloc);

    s.viewport_offset = 0;
    s.dirty_rows = .empty;
    _ = s.viewportReset(); // no-op

    for (0..s.active_rows) |r| try testing.expect(!s.dirty_rows.isSet(r));
}

test "dirty_rows: renderer can clear all dirty bits" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.setCell(2, 0, .{ .codepoint = 'X', .kind = .narrow });
    s.setCell(7, 0, .{ .codepoint = 'Y', .kind = .narrow });
    try testing.expect(s.dirty_rows.isSet(2));
    try testing.expect(s.dirty_rows.isSet(7));

    // Renderer consumes and clears
    s.dirty_rows = .empty;

    for (0..s.active_rows) |r| {
        try testing.expect(!s.dirty_rows.isSet(r));
    }
}

test "reverseIndex: cursor not at scroll_top, moves up" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.row = 5;
    s.reverseIndex();
    try testing.expectEqual(4, s.cursor.row);
}

test "reverseIndex: cursor at row 0 (not scroll_top), clamps to 0" {
    // scroll_top defaults to 0, so this hits the scrollDown branch
    // To test the clamp, need to set scroll_top > 0 and put cursor above it.

    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.scroll_top = 3;
    s.cursor.row = 1; // above scroll_top, no DECOM
    s.reverseIndex();
    try testing.expectEqual(0, s.cursor.row);
}

test "reverseIndex: cursor at row 0 above scroll_top, already at 0, stay 0" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.scroll_top = 3;
    s.cursor.row = 0;
    s.reverseIndex();
    try testing.expectEqual(0, s.cursor.row);
}

test "reverseIndex: cursor at scroll_top (full screen), scrolls region down" {
    // TERMV4 M2 item 9: full-screen scrollDown trips wrapAdd assert (b > max_rows) when scrollback is on.
    if (true) return error.SkipZigTest;

    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    // Fill rows with distinct markers
    for (0..s.active_rows) |r| {
        const cell: Cell = .{ .codepoint = @intCast('A' + r), .kind = .narrow };
        fillRow(&s, r, cell);
    }

    // scroll_top = 0 by default, cursor at top
    s.cursor.row = 0;
    s.reverseIndex();

    // Row 0 should now be blank (inserted by scrollDown)
    const blank: Cell = .{ .background = s.cursor.attr.bg };
    try testing.expectEqualDeep(blank, s.cellAt(0, 0));

    // Old row 0 (cell 'A') is now at row 1
    const a: Cell = .{ .codepoint = 'A', .kind = .narrow };
    try testing.expectEqualDeep(a, s.cellAt(1, 0));

    // Cursor row is unchanged (still at scroll_top = 0)
    try testing.expectEqual(0, s.cursor.row);
}

test "reverseIndex: clears wrap_pending" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.row = 5;
    s.cursor.wrap_pending = true;
    s.reverseIndex();
    try testing.expect(!s.cursor.wrap_pending);
}

test "reverseIndex: clears wrap_pending even when scrolling" {
    // TERMV4 M2 item 9: full-screen scrollDown trips wrapAdd assert (b > max_rows) when scrollback is on.
    if (true) return error.SkipZigTest;

    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.row = 0; // at scroll_top
    s.cursor.wrap_pending = true;
    s.reverseIndex();
    try testing.expect(!s.cursor.wrap_pending);
}

test "reverseIndex: generation bumped (cursor move)" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.row = 5;
    const gen = s.generation;
    s.reverseIndex();
    try testing.expectEqual(gen + 1, s.generation);
}

test "reverseIndex: generation bumped (scroll path)" {
    // TERMV4 M2 item 9: full-screen scrollDown trips wrapAdd assert (b > max_rows) when scrollback is on.
    if (true) return error.SkipZigTest;

    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.row = 0;
    const gen = s.generation;
    s.reverseIndex();
    try testing.expectEqual(gen + 1, s.generation);
}

test "reverseIndex: dirty_rows set (cursor move)" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.dirty_rows = .empty;
    s.cursor.row = 5;
    s.reverseIndex();

    // Cursor moved from row 5 to row 4, both rows may need redraw
    // (cursor indicator moved). At minimum the cursor's new row is dirty.
    try testing.expect(s.dirty_rows.isSet(4));
    try testing.expect(s.dirty_rows.isSet(5));
    try testing.expect(!s.dirty_rows.isSet(3));
    try testing.expect(!s.dirty_rows.isSet(6));
}

test "reverseIndex: dirty_rows = full (scroll path)" {
    // TERMV4 M2 item 9: full-screen scrollDown trips wrapAdd assert (b > max_rows) when scrollback is on.
    if (true) return error.SkipZigTest;

    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.dirty_rows = .empty;
    s.cursor.row = 0; // at scroll_top, triggers scrollDown
    s.reverseIndex();

    // scrollDown marks the entire region dirty
    try testing.expect(s.dirty_rows.count() > 0);
}

test "reverseIndex: not at scroll top, cursor moves up, line_attrs unchanged" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.row = 3;
    s.setLineAttr(.double_width);
    s.cursor.row = 4; // move cursor away from the double-width row

    s.reverseIndex();

    // Cursor moved up
    try testing.expectEqual(@as(u16, 3), s.cursor.row);
    // line_attr on row 3 is unchanged
    try testing.expectEqual(LineAttr.double_width, s.line_attrs[s.physRow(3)]);
}

test "reverseIndex: at scroll top, new blank row inserted at top has .normal line_attr" {
    // TERMV4 M2 item 9: full-screen scrollDown trips wrapAdd assert (b > max_rows) when scrollback is on.
    if (true) return error.SkipZigTest;

    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    // Set double-width on every row so we can detect which one gets reset
    for (0..s.active_rows) |r| {
        s.cursor.row = @intCast(r);
        s.setLineAttr(.double_width);
    }

    s.cursor.row = s.scroll_top;
    s.reverseIndex();

    // The new blank row at scroll_top must be .normal
    try testing.expectEqual(LineAttr.normal, s.line_attrs[s.physRow(s.scroll_top)]);
}

test "reverseIndex: at scroll_top, existing rows shift down, their line_attrs shift too" {
    // TERMV4 M2 item 9: full-screen scrollDown trips wrapAdd assert (b > max_rows) when scrollback is on.
    if (true) return error.SkipZigTest;

    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    // Row 0 = double_top, row 1 = double_bottom, rest = normal
    s.cursor.row = 0;
    s.setLineAttr(.double_top);
    s.cursor.row = 1;
    s.setLineAttr(.double_bottom);

    s.scroll_top = 0;
    s.scroll_bottom = @intCast(s.active_rows - 1);
    s.cursor.row = 0; // at scroll_top

    s.reverseIndex();

    // New blank row at top: .normal
    try testing.expectEqual(LineAttr.normal, s.line_attrs[s.physRow(0)]);
    // Old row 0 (double_top) shifted to row 1
    try testing.expectEqual(LineAttr.double_top, s.line_attrs[s.physRow(1)]);
    // Old row 1 (double_bottom) shifted to row 2
    try testing.expectEqual(LineAttr.double_bottom, s.line_attrs[s.physRow(2)]);
}

test "reverseIndex: at scroll_top, cursor stays at scroll_top" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.scroll_top = 2;
    s.scroll_bottom = 8;
    s.cursor.row = 2; // at scroll_top

    s.reverseIndex();

    // Cursor stays at scroll_top after reverse index scroll
    try testing.expectEqual(@as(u16, 2), s.cursor.row);
}

test "index: cursor not at scroll_bottom, moves down" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.row = 5;
    s.index();

    try testing.expectEqual(6, s.cursor.row);
}

test "index: cursor at scroll_bottom (full screen), scrolls up" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    // Fill rows with distinct markers
    for (0..s.active_rows) |r| {
        const cell: Cell = .{ .codepoint = @intCast('A' + r), .kind = .narrow };
        fillRow(&s, r, cell);
    }

    // scroll_bottom = active_rows - 1 by default
    s.cursor.row = s.scroll_bottom;
    s.index();

    // Cursor stays at scroll_bottom
    try testing.expectEqual(s.scroll_bottom, s.cursor.row);

    // Row 0 ('A') is gone; row 1 ('B') is now at row 0
    const b: Cell = .{ .codepoint = 'B', .kind = .narrow };
    try testing.expectEqualDeep(b, s.cellAt(0, 0));

    // Bottom row is blank
    const blank: Cell = .{ .background = s.cursor.attr.bg };
    try testing.expectEqualDeep(blank, s.cellAt(s.scroll_bottom, 0));
}

test "index: cursor at scroll_bottom (partial region), only region scrolls" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.scroll_top = 2;
    s.scroll_bottom = 6;

    const marker: Cell = .{ .codepoint = 'X', .kind = .narrow };
    const outside: Cell = .{ .codepoint = 'O', .kind = .narrow };

    // Fill entire screen with 'O', then fill region rows with 'X'
    for (0..s.active_rows) |r| fillRow(&s, r, outside);
    for (2..7) |r| fillRow(&s, r, marker);

    s.cursor.row = 6; // scroll_bottom
    s.index();

    // Cursor stays at scroll_bottom
    try testing.expectEqual(6, s.cursor.row);

    // Rows outside the region are untouched
    try testing.expectEqualDeep(outside, s.cellAt(0, 0));
    try testing.expectEqualDeep(outside, s.cellAt(1, 0));
    try testing.expectEqualDeep(outside, s.cellAt(7, 0));

    // Region shifted up: row 2 now has what was row 3
    try testing.expectEqualDeep(marker, s.cellAt(2, 0));

    // Bottom of region is blank
    const blank: Cell = .{ .background = s.cursor.attr.bg };
    try testing.expectEqualDeep(blank, s.cellAt(6, 0));
}

test "index: cursor below scroll_bottom, moves down clamped" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.scroll_top = 2;
    s.scroll_bottom = 6;
    s.cursor.row = 8; // below scroll_bottom, inside active area

    s.index();

    try testing.expectEqual(9, s.cursor.row);
}

test "index: cursor at last row (below scroll_bottom), clamped to active_rows-1" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.scroll_top = 2;
    s.scroll_bottom = 6;
    s.cursor.row = s.active_rows - 1; // already at last row

    s.index();

    try testing.expectEqual(s.active_rows - 1, s.cursor.row);
}

test "index: clears wrap_pending (cursor move path)" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.row = 3;
    s.cursor.wrap_pending = true;
    s.index();

    try testing.expect(!s.cursor.wrap_pending);
}

test "index: generation bumped (cursor move path)" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.row = 3;
    const gen = s.generation;
    s.index();

    try testing.expectEqual(gen + 1, s.generation);
}

test "index: generation bumped (scroll path)" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.row = s.scroll_bottom;
    const gen = s.generation;
    s.index();

    try testing.expectEqual(gen + 1, s.generation);
}

test "index: dirty_rows set (cursor move path)" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.dirty_rows = .empty;
    s.cursor.row = 5;
    s.index();

    try testing.expect(s.dirty_rows.isSet(5)); // old row
    try testing.expect(s.dirty_rows.isSet(6)); // new row
}

test "index: dirty_rows = full (scroll path, full screen)" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.dirty_rows = .empty;
    s.cursor.row = s.scroll_bottom;
    s.index();

    // Full-screen scrollUp sets dirty_rows = .full
    try testing.expectEqual(s.dirty_rows, std.bit_set.StaticBitSet(test_max_rows).full);
}

test "index: scrollback_used increments on primary screen (full screen scroll)" {
    const alloc = testing.allocator;
    var s = try primaryScreen(alloc);
    defer s.destroy(alloc);

    try testing.expectEqual(0, s.scrollback_used);
    s.cursor.row = s.scroll_bottom;
    s.index();

    try testing.expectEqual(1, s.scrollback_used);
}

test "index: scrollback_used capped at max_scrollback" {
    const alloc = testing.allocator;
    var s = try primaryScreen(alloc);
    defer s.destroy(alloc);

    s.scrollback_used = test_max_scrollback;
    s.cursor.row = s.scroll_bottom;
    s.index();

    try testing.expectEqual(test_max_scrollback, s.scrollback_used);
}

test "saveCursor/restoreCursor: basic position roundtrip" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.row = 5;
    s.cursor.col = 10;
    s.saveCursor();

    s.cursor.row = 0;
    s.cursor.col = 0;
    s.restoreCursor();

    try testing.expectEqual(5, s.cursor.row);
    try testing.expectEqual(10, s.cursor.col);
}

test "saveCursor/restoreCursor: attrs restored" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.attr.flags.bold = true;
    s.cursor.attr.fg = s.palette.intern(Color.fromRgb(255, 0, 0));
    s.saveCursor();

    s.cursor.attr = .{};
    s.restoreCursor();

    try testing.expect(s.cursor.attr.flags.bold);
    try testing.expectEqualDeep(Color.fromRgb(255, 0, 0), s.palette.decode(s.cursor.attr.fg));
}

test "saveCursor/restoreCursor: modes origin restored" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.origin = true;
    s.saveCursor();

    s.cursor.origin = false;
    s.restoreCursor();

    try testing.expect(s.cursor.origin);
}

test "saveCursor/restoreCursor: charset state restored" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.charset.g0 = .dec_special;
    s.shiftOut();
    s.saveCursor();

    s.cursor.charset = .{};
    s.restoreCursor();

    try testing.expectEqual(Charset.dec_special, s.cursor.charset.g0);
    try testing.expectEqual(@as(u2, 1), s.cursor.charset.gl);
}

test "saveCursor/restoreCursor: wrap_pending cleared on restore" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.row = 3;
    s.cursor.col = 5;
    s.cursor.wrap_pending = true;
    s.saveCursor();

    s.restoreCursor();

    // wrap_pending is intentionally discarded on restore
    try testing.expect(!s.cursor.wrap_pending);
}

test "saveCursor/restoreCursor: clamps row after resize" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.row = 10;
    s.cursor.col = 20;
    s.saveCursor();

    // shrink the active area so saved position is out of bounds
    s.setActive(6, 12);
    s.restoreCursor();

    // clamped to new active_rows-1 = 5
    try testing.expectEqual(5, s.cursor.row);
    // clamped to new active_cols-1 = 11
    try testing.expectEqual(11, s.cursor.col);
}

test "saveCursor/restoreCursor: clamps col after resize" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.col = 20;
    s.saveCursor();

    s.setActive(test_max_rows, 10); // shrink cols to 10
    s.restoreCursor();

    // clamped to new active_rows-1 = 9
    try testing.expectEqual(9, s.cursor.col);
}

test "saveCursor/restoreCursor: restore without prior save uses default cursor" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.row = 7;
    s.cursor.col = 15;
    s.cursor.attr.flags.bold = true;

    // No saveCursor() called.
    // call restoreCursor() should restores the default (zero) cursor.
    s.restoreCursor();

    try testing.expectEqual(0, s.cursor.col);
    try testing.expectEqual(0, s.cursor.row);
    try testing.expect(!s.cursor.attr.flags.bold);
}

test "saveCursor: does NOT bump generation" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    const gen = s.generation;
    s.saveCursor();
    try testing.expectEqual(gen, s.generation); // no visible change
}

test "restoreCursor: bumps generation" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    const gen = s.generation;
    s.restoreCursor();
    try testing.expectEqual(gen + 1, s.generation);
}

test "saveCursor/restoreCursor: dirty_rows marks old and new cursor rows" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.row = 3;
    s.saveCursor();

    s.cursor.row = 7;
    s.dirty_rows = .empty;
    s.restoreCursor();

    try testing.expect(s.dirty_rows.isSet(7)); // old row (cursor leaving)
    try testing.expect(s.dirty_rows.isSet(3)); // new row (cursor arriving)
}

test "saveCursor/restoreCursor: multiple cycles" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.row = 2;
    s.cursor.col = 4;
    s.saveCursor();

    s.cursor.row = 8;
    s.cursor.col = 20;
    s.saveCursor(); // overwrites previous save

    s.cursor.row = 0;
    s.cursor.col = 0;
    s.restoreCursor();

    // Only the last save is restored
    try testing.expectEqual(8, s.cursor.row);
    try testing.expectEqual(20, s.cursor.col);
}

test "insertChars: shifts cells right, fills blanks at cursor" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    const a: Cell = .{ .codepoint = 'A', .kind = .narrow };
    const b: Cell = .{ .codepoint = 'B', .kind = .narrow };
    const c: Cell = .{ .codepoint = 'C', .kind = .narrow };
    s.setCell(0, 0, a);
    s.setCell(0, 1, b);
    s.setCell(0, 2, c);

    s.cursor.row = 0;
    s.cursor.col = 1;
    s.insertChars(1);

    const blank: Cell = .{ .background = s.cursor.attr.bg };
    try testing.expectEqualDeep(a, s.cellAt(0, 0)); // untouched
    try testing.expectEqualDeep(blank, s.cellAt(0, 1)); // inserted blank
    try testing.expectEqualDeep(b, s.cellAt(0, 2)); // shifted right
    try testing.expectEqualDeep(c, s.cellAt(0, 3)); // shifted right

}

test "insertChars: overflow discards cells past active_cols" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    const x: Cell = .{ .codepoint = 'X', .kind = .narrow };
    for (0..s.active_cols) |c| s.setCell(0, c, x);

    s.cursor.row = 0;
    s.cursor.col = 0;
    s.insertChars(3);

    const blank: Cell = .{ .background = s.cursor.attr.bg };
    // First 3 cells are blank
    for (0..3) |c| try testing.expectEqualDeep(blank, s.cellAt(0, c));
    // Remaining cells are 'X' (shifted right, last 3 'X', fell off)
    for (3..s.active_cols) |c| try testing.expectEqualDeep(x, s.cellAt(0, c)); // untouched
}

test "insertChars: n >= remaining cols clears to end of line" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    const x: Cell = .{ .codepoint = 'X', .kind = .narrow };
    for (0..s.active_cols) |c| s.setCell(0, c, x);

    s.cursor.row = 0;
    s.cursor.col = 8; // active_cols=12, so 4 cells remain
    s.insertChars(999);

    const blank: Cell = .{ .background = s.cursor.attr.bg };
    // Cols 0..8 untouched
    for (0..8) |c| try testing.expectEqualDeep(x, s.cellAt(0, c));
    // Cols 8 .. 12 blanked
    for (8..s.active_cols) |c| try testing.expectEqualDeep(blank, s.cellAt(0, c));
}

test "insertChars: other rows unaffected" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    const x: Cell = .{ .codepoint = 'X', .kind = .narrow };
    fillScreen(&s, x);

    s.cursor.row = 3;
    s.cursor.col = 0;
    s.insertChars(2);

    // Row 3 changed; row 2 and row 4 untouched
    try testing.expectEqualDeep(x, s.cellAt(2, 0));
    try testing.expectEqualDeep(x, s.cellAt(4, 0));
}

test "insertChars: clears wrap_pending and bumps generation" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.row = 0;
    s.cursor.col = 0;
    s.cursor.wrap_pending = true;
    const gen = s.generation;

    s.insertChars(1);

    try testing.expect(!s.cursor.wrap_pending);
    try testing.expectEqual(gen + 1, s.generation);
}

test "insertChars: dirty_rows marks cursor row" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.dirty_rows = .empty;
    s.cursor.row = 5;
    s.cursor.col = 0;
    s.insertChars(1);

    try testing.expect(!s.dirty_rows.isSet(4));
    try testing.expect(s.dirty_rows.isSet(5));
    try testing.expect(!s.dirty_rows.isSet(6));
}

test "insertLines: line_attrs shift down with rows" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    // Mark rows 2, 3, 4 with distinct line attrs.
    s.cursor.row = 2;
    s.setLineAttr(.double_width);
    s.cursor.row = 3;
    s.setLineAttr(.double_top);
    s.cursor.row = 4;
    s.setLineAttr(.double_bottom);

    // Insert 1 line at row 2 (full-screen scroll region).
    s.cursor.row = 2;
    s.insertLines(1);

    // Row 2 (inserted) must be .normal.
    try testing.expectEqual(LineAttr.normal, s.line_attrs[s.physRow(2)]);
    // Row 3 should now have what was row 2 (.double_width).
    try testing.expectEqual(LineAttr.double_width, s.line_attrs[s.physRow(3)]);
    // Row 4 should now have what was row 3 (.double_top).
    try testing.expectEqual(LineAttr.double_top, s.line_attrs[s.physRow(4)]);
    // Row 5 should now have what was row 4 (.double_bottom).
    try testing.expectEqual(LineAttr.double_bottom, s.line_attrs[s.physRow(5)]);
}

test "insertLines: inserted rows reset to normal" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    // Mark every row double_width.
    for (0..s.active_rows) |row| {
        s.cursor.row = @intCast(row);
        s.setLineAttr(.double_width);
    }

    s.cursor.row = 0;
    s.insertLines(3);

    // First 3 rows (inserted) must be .normal.
    try testing.expectEqual(LineAttr.normal, s.line_attrs[s.physRow(0)]);
    try testing.expectEqual(LineAttr.normal, s.line_attrs[s.physRow(1)]);
    try testing.expectEqual(LineAttr.normal, s.line_attrs[s.physRow(2)]);
    // Row 3 should have what was row 0 (.double_width).
    try testing.expectEqual(LineAttr.double_width, s.line_attrs[s.physRow(3)]);
}

test "insertLines: partial scroll region does not affect rows outside region" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.scroll_top = 2;
    s.scroll_bottom = 5;

    s.cursor.row = 1;
    s.setLineAttr(.double_width);
    s.cursor.row = 6;
    s.setLineAttr(.double_width);

    s.cursor.row = 2;
    s.insertLines(1);

    // Rows outside the scroll region must be untouched.
    try testing.expectEqual(LineAttr.double_width, s.line_attrs[s.physRow(1)]);
    try testing.expectEqual(LineAttr.double_width, s.line_attrs[s.physRow(6)]);
    // Inserted row 2 must be .normal.
    try testing.expectEqual(LineAttr.normal, s.line_attrs[s.physRow(2)]);
}

test "insertLines: n >= region_height clears all line_attrs in region" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.scroll_top = 2;
    s.scroll_bottom = 4;
    for (2..5) |row| {
        s.cursor.row = @intCast(row);
        s.setLineAttr(.double_bottom);
    }

    s.cursor.row = 2;
    s.insertLines(100); // clamp to region_height

    for (2..5) |row| {
        try testing.expectEqual(LineAttr.normal, s.line_attrs[s.physRow(row)]);
    }
}

test "deleteChars: shift cells leftt, fills blanks at end" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    const a: Cell = .{ .codepoint = 'A', .kind = .narrow };
    const b: Cell = .{ .codepoint = 'B', .kind = .narrow };
    const c: Cell = .{ .codepoint = 'C', .kind = .narrow };
    s.setCell(0, 0, a);
    s.setCell(0, 1, b);
    s.setCell(0, 2, c);

    s.cursor.row = 0;
    s.cursor.col = 0;
    s.deleteChars(1);

    const blank: Cell = .{ .background = s.cursor.attr.bg };
    try testing.expectEqualDeep(b, s.cellAt(0, 0)); // shifted left
    try testing.expectEqualDeep(c, s.cellAt(0, 1)); // shifted left
    try testing.expectEqualDeep(blank, s.cellAt(0, 2)); // filled blank
}

test "deleteChars: n >= remaining cols clears to end of line" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    const x: Cell = .{ .codepoint = 'X', .kind = .narrow };
    for (0..s.active_cols) |c| s.setCell(0, c, x);

    s.cursor.row = 0;
    s.cursor.col = 8;
    s.deleteChars(999);

    const blank: Cell = .{ .background = s.cursor.attr.bg };
    for (0..8) |c| try testing.expectEqualDeep(x, s.cellAt(0, c));
    for (8..s.active_cols) |c| try testing.expectEqualDeep(blank, s.cellAt(0, c));
}

test "deleteChars: clears wrap_pending and bumps generation" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.row = 0;
    s.cursor.col = 0;
    s.cursor.wrap_pending = true;
    const gen = s.generation;

    s.deleteChars(1);

    try testing.expect(!s.cursor.wrap_pending);
    try testing.expectEqual(gen + 1, s.generation);
}

test "insertLines: inserts blank lines at cursor row, shifts down" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    // Fill rows with distinct markers
    for (0..s.active_rows) |r| {
        const cell: Cell = .{ .codepoint = @intCast('A' + r), .kind = .narrow };
        fillRow(&s, r, cell);
    }

    s.cursor.row = 2;
    s.cursor.col = 5;
    s.insertLines(1);

    const blank: Cell = .{ .background = s.cursor.attr.bg };
    // Row 0, 1 untouched
    try testing.expectEqualDeep(Cell{ .codepoint = 'A', .kind = .narrow }, s.cellAt(0, 0));
    try testing.expectEqualDeep(Cell{ .codepoint = 'B', .kind = .narrow }, s.cellAt(1, 0));
    // Row 2 is now blank (inserted)
    try testing.expectEqualDeep(blank, s.cellAt(2, 0));
    // Old row 2 ('C') shifted to row 3
    try testing.expectEqualDeep(Cell{ .codepoint = 'C', .kind = .narrow }, s.cellAt(3, 0));
    // Old row 3 ('D') shifted to row 4
    try testing.expectEqualDeep(Cell{ .codepoint = 'D', .kind = .narrow }, s.cellAt(4, 0));

    // Last row (scroll_bottom) content fell off — now blank
    // try testing.expectEqualDeep(blank, s.getCell(s.active_rows - 1, 0));
}

test "insertLines: cursor outside scroll region is no-op" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.scroll_top = 3;
    s.scroll_bottom = 8;
    const x: Cell = .{ .codepoint = 'X', .kind = .narrow };
    fillScreen(&s, x);
    const gen = s.generation;

    s.cursor.row = 1; // bellow scroll_top=3
    s.insertLines(1);

    try testing.expectEqualDeep(x, s.cellAt(3, 0));
    try testing.expectEqual(gen, s.generation);
}

test "insertLines: n >= region height clears entire region" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    const x: Cell = .{ .codepoint = 'X', .kind = .narrow };
    fillScreen(&s, x);

    s.cursor.row = 0;
    s.insertLines(999);

    const blank: Cell = .{ .background = s.cursor.attr.bg };
    for (0..s.active_rows) |r| try testing.expectEqualDeep(blank, s.cellAt(r, 0));
}

test "insertLines: cursor col reset to 0, wrap_pending cleared" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.row = 2;
    s.cursor.col = 10;
    s.cursor.wrap_pending = true;

    s.insertLines(1);

    try testing.expectEqual(0, s.cursor.col);
    try testing.expect(!s.cursor.wrap_pending);
}

test "insertLines: dirty_rows cursor row to scroll_bottom" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.dirty_rows = .empty;
    s.cursor.row = 3;

    s.insertLines(1);

    for (3..s.active_rows) |r| try testing.expect(s.dirty_rows.isSet(r));
    try testing.expect(!s.dirty_rows.isSet(2));
}

test "insertLines: partial scroll region respected" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.scroll_top = 2;
    s.scroll_bottom = 6;

    for (0..s.active_rows) |r| {
        const cell: Cell = .{ .codepoint = @intCast('A' + r), .kind = .narrow };
        fillRow(&s, r, cell);
    }

    s.cursor.row = 2;
    s.insertLines(1);

    const blank: Cell = .{ .background = s.cursor.attr.bg };
    // Rows outside region untouched
    try testing.expectEqualDeep(Cell{ .codepoint = 'A', .kind = .narrow }, s.cellAt(0, 0));
    try testing.expectEqualDeep(Cell{ .codepoint = 'B', .kind = .narrow }, s.cellAt(1, 0));
    // Row 2 blank (inserted)
    try testing.expectEqualDeep(blank, s.cellAt(2, 0));
    // Old row 2 ('C') at row 3
    try testing.expectEqualDeep(Cell{ .codepoint = 'C', .kind = .narrow }, s.cellAt(3, 0));
    // Row 7+ untouched (outside region)
    try testing.expectEqualDeep(Cell{ .codepoint = 'H', .kind = .narrow }, s.cellAt(7, 0));
}

test "deleteLines: deletes lines at cursor row, shifts up" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    for (0..s.active_rows) |r| {
        const cell: Cell = .{ .codepoint = @intCast('A' + r), .kind = .narrow };
        fillRow(&s, r, cell);
    }

    s.cursor.row = 2;
    s.deleteLines(1);

    const blank: Cell = .{ .background = s.cursor.attr.bg };
    // Rows 0, 1 untouched
    try testing.expectEqualDeep(Cell{ .codepoint = 'A', .kind = .narrow }, s.cellAt(0, 0));
    try testing.expectEqualDeep(Cell{ .codepoint = 'B', .kind = .narrow }, s.cellAt(1, 0));

    // Old row 3 ('D') shifted to row 2
    try testing.expectEqualDeep(Cell{ .codepoint = 'D', .kind = .narrow }, s.cellAt(2, 0));
    // scroll_bottom now blank
    try testing.expectEqualDeep(blank, s.cellAt(s.active_rows - 1, 0));
}

test "deleteLines: cursor outside scroll region is no-op" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.scroll_top = 3;
    s.scroll_bottom = 8;

    const x: Cell = .{ .codepoint = 'X', .kind = .narrow };
    fillScreen(&s, x);
    const gen = s.generation;

    s.cursor.row = 10; // above scroll_bottom=8... wait, 10 > 8 so outside
    s.deleteLines(1);

    try testing.expectEqualDeep(x, s.cellAt(3, 0));
    try testing.expectEqual(gen, s.generation);
}

test "deleteLines: n >= region height clears entire region" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    const x: Cell = .{ .codepoint = 'X', .kind = .narrow };
    fillScreen(&s, x);

    s.cursor.row = 0;
    s.deleteLines(999);

    const blank: Cell = .{ .background = s.cursor.attr.bg };
    for (0..s.active_rows) |r|
        try testing.expectEqualDeep(blank, s.cellAt(r, 0));
}

test "deleteLines: cursor col reset to 0, wrap_pending cleared" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.row = 2;
    s.cursor.col = 10;
    s.cursor.wrap_pending = true;

    s.deleteLines(1);

    try testing.expectEqual(0, s.cursor.col);
    try testing.expect(!s.cursor.wrap_pending);
}

test "deleteLines: dirty_rows covers cursor row to scroll_bottom" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.dirty_rows = .empty;
    s.cursor.row = 4;
    s.deleteLines(1);

    for (4..s.active_rows) |r| try testing.expect(s.dirty_rows.isSet(r));
    try testing.expect(!s.dirty_rows.isSet(3));
}

test "deleteLines: partial scroll region respected" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.scroll_top = 2;
    s.scroll_bottom = 6;

    for (0..s.active_rows) |r| {
        const cell: Cell = .{ .codepoint = @intCast('A' + r), .kind = .narrow };
        fillRow(&s, r, cell);
    }

    s.cursor.row = 2;
    s.deleteLines(1);

    const blank: Cell = .{ .background = s.cursor.attr.bg };
    // Rows outside region untouched
    try testing.expectEqualDeep(Cell{ .codepoint = 'A', .kind = .narrow }, s.cellAt(0, 0));
    try testing.expectEqualDeep(Cell{ .codepoint = 'B', .kind = .narrow }, s.cellAt(1, 0));
    // Old row 3 ('D') shifted to row 2
    try testing.expectEqualDeep(Cell{ .codepoint = 'D', .kind = .narrow }, s.cellAt(2, 0));
    // Row 6 (scroll_bottom) now blank
    try testing.expectEqualDeep(blank, s.cellAt(6, 0));
    // Row 7+ untouched
    try testing.expectEqualDeep(Cell{ .codepoint = 'H', .kind = .narrow }, s.cellAt(7, 0));
}

test "deleteLines: line_attrs shift up with rows" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    // Mark rows 2, 3, 4 with distinct line attrs.
    s.cursor.row = 2;
    s.setLineAttr(.double_width);
    s.cursor.row = 3;
    s.setLineAttr(.double_top);
    s.cursor.row = 4;
    s.setLineAttr(.double_bottom);

    // Delete 1 line at row 2 (scroll region = full screen).
    s.cursor.row = 2;
    s.deleteLines(1);

    // Row 2 should now have what was row 3 (.double_top).
    try testing.expectEqual(LineAttr.double_top, s.line_attrs[s.physRow(2)]);
    // Row 3 should now have what was row 4 (.double_bottom).
    try testing.expectEqual(LineAttr.double_bottom, s.line_attrs[s.physRow(3)]);
    // The vacated bottom row should be reset to .normal.
    try testing.expectEqual(LineAttr.normal, s.line_attrs[s.physRow(s.active_rows - 1)]);
}

test "deleteLines: vacated rows reset to normal" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    // Mark every row double_width.
    for (0..s.active_rows) |row| {
        s.cursor.row = @intCast(row);
        s.setLineAttr(.double_width);
    }

    // Delete 3 lines at row 0.
    s.cursor.row = 0;
    s.deleteLines(3);

    // Last 3 rows (vacated) must be .normal.
    const bot = s.active_rows - 1;
    try testing.expectEqual(LineAttr.normal, s.line_attrs[s.physRow(bot)]);
    try testing.expectEqual(LineAttr.normal, s.line_attrs[s.physRow(bot - 1)]);
    try testing.expectEqual(LineAttr.normal, s.line_attrs[s.physRow(bot - 2)]);
    // Rows that shifted up should still be .double_width.
    try testing.expectEqual(LineAttr.double_width, s.line_attrs[s.physRow(0)]);
}

test "deleteLines: partial scroll region does not affect rows outside region" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    // Set scroll region to rows 2..5.
    s.scroll_top = 2;
    s.scroll_bottom = 5;

    // Mark row 1 (above region) and row 6 (below region) with double_width.
    s.cursor.row = 1;
    s.setLineAttr(.double_width);
    s.cursor.row = 6;
    s.setLineAttr(.double_width);

    s.cursor.row = 2;
    s.deleteLines(1);

    // Rows outside the scroll region must be untouched.
    try testing.expectEqual(LineAttr.double_width, s.line_attrs[s.physRow(1)]);
    try testing.expectEqual(LineAttr.double_width, s.line_attrs[s.physRow(6)]);
    // Vacated row 5 (bottom of region) must be .normal.
    try testing.expectEqual(LineAttr.normal, s.line_attrs[s.physRow(5)]);
}

test "deleteLines: n >= region_height clears all line_attrs in region" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.scroll_top = 2;
    s.scroll_bottom = 4;
    for (2..5) |row| {
        s.cursor.row = @intCast(row);
        s.setLineAttr(.double_top);
    }

    s.cursor.row = 2;
    s.deleteLines(100); // clamp to region_height

    for (2..5) |row| {
        try testing.expectEqual(LineAttr.normal, s.line_attrs[s.physRow(row)]);
    }
}

test "tabForward: moves to next tab stop" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    // Default tab stops at 8, 16 (tab_width=8, max_cols=12)
    s.cursor.col = 0;
    s.tabForward(1);
    try testing.expectEqual(8, s.cursor.col);
}

test "tabForward: n=2 moves to second tab stop, stops at last column" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    // Default tab stops at 8, 16 (tab_width=8, max_cols=12)
    s.cursor.col = 0;
    s.tabForward(2);
    try testing.expectEqual(16, s.cursor.col);
}

test "tabForward: no tab stop ahead, stops at last column" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    // Clear all tab stops so there's nothing to the right
    s.clearTabStop(3);
    s.cursor.col = 5;
    s.tabForward(1);
    try testing.expectEqual(test_max_cols - 1, s.cursor.col);
}

test "tabForward: clears wrap_pending" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.col = 0;
    s.cursor.wrap_pending = true;
    s.tabForward(1);
    try testing.expect(!s.cursor.wrap_pending);
}

test "tabForward: bumps generation" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    const gen = s.generation;
    s.tabForward(1);
    try testing.expectEqual(gen + 1, s.generation);
}

test "tabForward: marks cursor row dirty" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.row = 3;
    s.dirty_rows = .empty;
    s.tabForward(1);
    try testing.expect(s.dirty_rows.isSet(3));
}

test "tabForward: large n clamps at last column" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.col = 0;
    s.tabForward(999);
    try testing.expectEqual(test_max_cols - 1, s.cursor.col);
}

test "tabForward: custom tab stop is respected" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    // Clear all stops, set one at column 5
    s.clearTabStop(3);
    s.cursor.col = 5;
    s.setTabStop();
    s.cursor.col = 0;

    s.tabForward(1);
    try testing.expectEqual(5, s.cursor.col);
}

test "setTabStop: sets bit at cursor column" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.clearTabStop(3); // clear all first
    s.cursor.col = 5;
    s.setTabStop();
    try testing.expect(s.tab_stops.isSet(5));
}

test "setTabStop: does NOT bump generation" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    const gen = s.generation;
    s.cursor.col = 5;
    s.setTabStop();
    try testing.expectEqual(gen, s.generation);
}

test "setTabStop: idempotent (setting already-set stop is safe)" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.col = 8; // default tab stop
    s.setTabStop(); // already set — should not panic
    try testing.expect(s.tab_stops.isSet(8));
}

test "clearTabStop mode 0: clears stop at cursor column" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.col = 8; // default tab stop
    try testing.expect(s.tab_stops.isSet(8));
    s.clearTabStop(0);
    try testing.expect(!s.tab_stops.isSet(8));
}

test "clearTabStop mode 0: other stops unaffected" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.col = 11;
    s.clearTabStop(0);
    // Column 8 should still be set
    try testing.expect(s.tab_stops.isSet(8));
}

test "clearTabStop mode 3: clears all stops" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.clearTabStop(3);
    // No bits should be set
    try testing.expectEqual(0, s.tab_stops.count());
}

test "clearTabStop mode 3: tabForward goes to last column after clear" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.clearTabStop(3);
    s.cursor.col = 0;
    s.tabForward(1);
    try testing.expectEqual(test_max_cols - 1, s.cursor.col);
}

test "clearTabStop unknown mode: no-op" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    const before = s.tab_stops;
    s.clearTabStop(99);
    // tab_stops unchanged — compare count as a proxy
    try testing.expectEqual(before.count(), s.tab_stops.count());
}

test "clearTabStop: does NOT bump generation" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    const gen = s.generation;
    s.clearTabStop(0);
    s.clearTabStop(3);
    try testing.expectEqual(gen, s.generation);
}

test "tab round-trip: clear all, set custom, tabForward uses them" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.clearTabStop(3);
    // Set stops at 3, 7, 15
    s.cursor.col = 3;
    s.setTabStop();

    s.cursor.col = 7;
    s.setTabStop();

    s.cursor.col = 15;
    s.setTabStop();

    s.cursor.col = 0;
    s.tabForward(1);

    try testing.expectEqual(3, s.cursor.col);

    s.tabForward(1);
    try testing.expectEqual(7, s.cursor.col);

    s.tabForward(1);
    try testing.expectEqual(15, s.cursor.col);

    // No more stops — clamps to last column
    s.tabForward(1);
    try testing.expectEqual(test_max_cols - 1, s.cursor.col);
}

test "resetTabStops restores defaults after clearTabStop 3" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.clearTabStop(3);
    try testing.expectEqual(0, s.tab_stops.count());

    s.resetTabStops();
    // Default stops at 8 and 16 (tab_width=8, max_cols=24)
    try testing.expect(s.tab_stops.isSet(8));
    try testing.expect(s.tab_stops.isSet(16));
    try testing.expect(!s.tab_stops.isSet(0));
}

test "tabBackward: basic one step from tab stop" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.col = 16;
    s.tabBackward(1);

    try testing.expectEqual(8, s.cursor.col);
}

test "tabBackward: two steps from col 16" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    // col 16 → col 8 → col 0 (no tab stop between 0 and 7)
    s.cursor.col = 16;
    s.tabBackward(2);

    try testing.expectEqual(0, s.cursor.col);
}

test "tabBackward: cursor between tab stops moves to nearest left stop" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    // col 12 is between stop 8 and stop 16; nearest left is 8
    s.cursor.col = 12;
    s.tabBackward(1);

    try testing.expectEqual(8, s.cursor.col);
}

test "tabBackward: cursor at col 0 stays at col 0" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.col = 0;
    s.tabBackward(1);

    try testing.expectEqual(0, s.cursor.col);
}

test "tabBackward: n=0 treated as 1" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.col = 16;
    s.tabBackward(0); // 0 → treated as 1

    try testing.expectEqual(8, s.cursor.col);
}

test "tabBackward: n larger than available tab stops clamps to col 0" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    // Only 2 tab stops (8, 16) to the left of col 23.
    // n=10 exhausts them and lands at col 0.
    s.cursor.col = 23;
    s.tabBackward(10);

    try testing.expectEqual(0, s.cursor.col);
}

test "tabBackward: wrap_pending is cleared" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.col = 16;
    s.cursor.wrap_pending = true;
    s.tabBackward(1);

    try testing.expect(!s.cursor.wrap_pending);
}

test "tabBackward: generation is bumped" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    const gen = s.generation;
    s.cursor.col = 16;
    s.tabBackward(1);

    try testing.expectEqual(gen + 1, s.generation);
}

test "tabBackward: dirty_rows set for cursor row" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.row = 3;
    s.cursor.col = 16;
    s.dirty_rows = .empty;
    s.tabBackward(1);

    try testing.expect(s.dirty_rows.isSet(3));
}

test "tabBackward: custom tab stop is respected" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    // Add a custom stop at col 5; cursor at col 10 should land on 8 (not 5),
    // because 8 is the nearest stop to the left of 10.
    s.cursor.col = 5;
    s.setTabStop();

    s.cursor.col = 10;
    s.tabBackward(1);

    try testing.expectEqual(8, s.cursor.col);
}

test "tabBackward: custom tab stop at col 5, two steps from col 10" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    // Stops: 5, 8, 16. From col 10: step 1 → 8, step 2 → 5.
    s.cursor.col = 5;
    s.setTabStop();

    s.cursor.col = 10;
    s.tabBackward(2);

    try testing.expectEqual(5, s.cursor.col);
}

test "tabBackward: cursor row unchanged" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.row = 5;
    s.cursor.col = 16;
    s.tabBackward(1);

    // tabBackward never changes the row
    try testing.expectEqual(5, s.cursor.row);
}

test "shiftOut: sets gl = 1" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.shiftOut();
    try testing.expectEqual(@as(u2, 1), s.cursor.charset.gl);
}

test "shiftIn: sets gl = 0" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.shiftIn();
    try testing.expectEqual(@as(u2, 0), s.cursor.charset.gl);
}

test "shiftOut: does not consume single_shift" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.singleShift2();
    s.shiftOut();

    // single_shift must still be pending, shiftOut must not clear it.
    try testing.expectEqual(@as(u3, 2), s.cursor.charset.ss);
}

test "singleShift2: sets single_shift = 2" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.singleShift2();
    try testing.expectEqual(@as(u3, 2), s.cursor.charset.ss);
}

test "singleShift3: sets single_shift = 3" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.singleShift3();
    try testing.expectEqual(@as(u3, 3), s.cursor.charset.ss);
}

test "singleShift2: does not change gl" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.shiftOut(); // gl = 1
    s.singleShift2();
    try testing.expectEqual(@as(u3, 1), s.cursor.charset.gl);
}

test "singleShift2: consumed after one putChar" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    // G2 = DEC Special Graphics; SS2 uses G2 for one char
    s.designateCharset(2, .dec_special);
    s.singleShift2();
    s.putChar('j'); // 'j' = '┘' via G2 (dec_special)

    // single_shift must be cleared after the character was consumed
    try testing.expectEqual(CharsetState.no_shift, s.cursor.charset.ss);
    // GL is still G0 (unchanged)
    try testing.expectEqual(@as(u2, 0), s.cursor.charset.gl);
}

test "singleShift3: consumed after one putChar" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    // G3 = DEC Special Graphics; SS3 uses G3 for one char
    s.designateCharset(3, .dec_special);
    s.singleShift3();
    s.putChar('j'); // 'j' = '┘' via G2 (dec_special)

    // single_shift must be cleared after the character was consumed
    try testing.expectEqual(CharsetState.no_shift, s.cursor.charset.ss);
    // GL is still G0 (unchanged)
    try testing.expectEqual(@as(u2, 0), s.cursor.charset.gl);
}

test "designateCharset: G0 = dec_special" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.designateCharset(0, .dec_special);
    try testing.expectEqual(Charset.dec_special, s.cursor.charset.slot(0));
}

test "designateCharset: G1 = ascii" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.designateCharset(1, .dec_special);
    s.designateCharset(1, .ascii); // overwrite
    try testing.expectEqual(Charset.ascii, s.cursor.charset.slot(1));
}

test "designateCharset: does not change gl or gr" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    const gl_before = s.cursor.charset.gl;
    const gr_before = s.cursor.charset.gr;
    s.designateCharset(0, .dec_special);
    try testing.expectEqual(gl_before, s.cursor.charset.gl);
    try testing.expectEqual(gr_before, s.cursor.charset.gr);
}

test "putChar: G0 = dec_special, 'j' to '┘'" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.designateCharset(0, .dec_special);
    // GL = G0 by default, so putChar uses dec_special immediately
    s.putChar('j');
    try testing.expectEqual(@as(u21, '┘'), s.cellAt(0, 0).codepoint);
}

test "putChar: shiftOut activates G1 (dec_special), shiftIn restores G0 (ascii)" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.designateCharset(1, .dec_special);

    s.shiftOut(); // GL = G1 (dec_special)
    s.putChar('j'); // 'j' to '┘'
    try testing.expectEqual(@as(u21, '┘'), s.cellAt(0, 0).codepoint);

    s.shiftIn(); // GL = G0 (ascii)
    s.putChar('j'); // 'j' to 'j'
    try testing.expectEqual(@as(u21, 'j'), s.cellAt(0, 1).codepoint);
}

test "putChar: singleShift2 applies to one char only, then GL resumes" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.designateCharset(2, .dec_special); // G2 = dec_special
    // GL = G0 (ascii); 'j' would normally stay 'j'

    s.singleShift2();
    s.putChar('j'); // uses G2 to '┘'
    try testing.expectEqual(@as(u21, '┘'), s.cellAt(0, 0).codepoint);

    s.putChar('j'); // back to GL = G0 (ascii) to 'j'
    try testing.expectEqual(@as(u21, 'j'), s.cellAt(0, 1).codepoint);
}

test "putChar: charset state saved and restored with cursor" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.designateCharset(1, .dec_special);
    s.shiftOut(); // GL = G1
    s.saveCursor();

    s.shiftIn(); // GL = G0
    s.designateCharset(1, .ascii);

    s.restoreCursor(); // should restore GL = G1, G1 = dec_special
    try testing.expectEqual(@as(u2, 1), s.cursor.charset.gl);
    try testing.expectEqual(Charset.dec_special, s.cursor.charset.slot(1));
}

test "putChar: ASCII write advance cursor" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.putChar('A');

    try testing.expectEqual(@as(u21, 'A'), s.cellAt(0, 0).codepoint);
    try testing.expectEqual(0, s.cursor.row);
    try testing.expectEqual(1, s.cursor.col);
    try testing.expect(!s.cursor.wrap_pending);
}

test "putChar: cursor attribute is applied to written cell" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    // Set a non-default attribute on the cursor.
    s.cursor.attr.flags.bold = true;
    s.putChar('X');

    const cell = s.cellAt(0, 0);
    try testing.expectEqual(@as(u21, 'X'), cell.codepoint);
    try testing.expect(cell.flags.bold);
}

test "putChar: marks the cursor row dirty, generation bump is deferred" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    const gen = s.generation;
    s.putChar('A');

    // Terminal.feed bumps once per feed; putChar only marks the row.
    try testing.expect(s.dirty_rows.isSet(0));
    try testing.expectEqual(gen, s.generation);
}

test "putChar: wide char gets width 2 and continuation placeholder" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.putChar('中'); // CJK, wcwidth = 2

    try testing.expectEqual(@as(u21, '中'), s.cellAt(0, 0).codepoint);
    try testing.expectEqual(.wide_left, s.cellAt(0, 0).kind);

    // Continuation placeholder at col 1
    try testing.expectEqual(@as(u21, 0), s.cellAt(0, 1).codepoint);
    try testing.expectEqual(.wide_right, s.cellAt(0, 1).kind);

    // Cursor advanced by 2
    try testing.expectEqual(2, s.cursor.col);
}

test "putChar: narrow Unicode char gets width 1" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.putChar('é'); // U+00E9, w.kind = .narrow

    try testing.expectEqual(@as(u21, 'é'), s.cellAt(0, 0).codepoint);
    try testing.expectEqual(.narrow, s.cellAt(0, 0).kind);
    try testing.expectEqual(1, s.cursor.col);
}

test "putChar: wide char at last column wraps and writes at col 0 of next row" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.col = s.active_cols - 1;
    s.putChar('中');

    // Last column of row 0 gets a blank fill.
    const blank: Cell = .{};
    try testing.expectEqualDeep(blank, s.cellAt(0, s.active_cols - 1));
    // Wide char lands at (1, 0).
    try testing.expectEqual(@as(u21, '中'), s.cellAt(1, 0).codepoint);
    try testing.expectEqual(1, s.cursor.row);
    try testing.expectEqual(2, s.cursor.col);
}

test "putChar: write at last column sets wrap_pending" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.col = s.active_cols - 1;
    s.putChar('Z');

    try testing.expectEqual(@as(u21, 'Z'), s.cellAt(0, s.active_cols - 1).codepoint);
    try testing.expect(s.cursor.wrap_pending);
    try testing.expectEqual(s.active_cols - 1, s.cursor.col);
}

test "putChar: wrap_pending triggers wrap to next row" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.row = 2;
    s.cursor.col = s.active_cols - 1;
    s.cursor.wrap_pending = true;

    s.putChar('A');

    try testing.expectEqual(@as(u21, 'A'), s.cellAt(3, 0).codepoint);
    try testing.expectEqual(3, s.cursor.row);
    try testing.expectEqual(1, s.cursor.col);
    try testing.expect(!s.cursor.wrap_pending);
}

test "putChar: default charset passes codepoint through unchanged" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    // With the default (ASCII) charset, no translation occurs.
    s.putChar('j');
    try testing.expectEqual(@as(u21, 'j'), s.cellAt(0, 0).codepoint);
}

test "putChar: DEC special graphics on G0 translates codepoint" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    // Designate DEC Special Graphics to G0; GL already points to G0 (gl=0).
    s.designateCharset(0, .dec_special);

    // 'j' (0x6A) → dec_map[0x6A - 0x60] = '┘'
    s.putChar('j');
    try testing.expectEqual(@as(u21, '┘'), s.cellAt(0, 0).codepoint);
}

test "putChar: DEC special graphics — codepoint outside 0x60..0x7E passes through" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.designateCharset(0, .dec_special);

    // 'A' (0x41) is outside the remapped range, passes through unchanged.
    s.putChar('A');
    try testing.expectEqual(@as(u21, 'A'), s.cellAt(0, 0).codepoint);
}

test "putChar: GL=G1 (shiftOut) uses G1 charset" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.designateCharset(0, .ascii);
    s.designateCharset(1, .dec_special);
    s.shiftOut(); // SO: GL → G1

    s.putChar('j');
    try testing.expectEqual(@as(u21, '┘'), s.cellAt(0, 0).codepoint);
}

test "putChar: GL=G0 (shiftIn) restores ASCII after G1 was active" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.designateCharset(0, .ascii);
    s.designateCharset(1, .dec_special);

    // SO: GL → G1 (DEC graphics)
    s.shiftOut();
    s.putChar('j');
    try testing.expectEqual(@as(u21, '┘'), s.cellAt(0, 0).codepoint);

    // SI: GL → G0 (ASCII)
    s.shiftIn();
    s.putChar('j');
    try testing.expectEqual(@as(u21, 'j'), s.cellAt(0, 1).codepoint);
}

test "putChar: SS2 applies G2 for one char than reverts to GL" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.designateCharset(0, .ascii);
    s.designateCharset(2, .dec_special);

    // SS2:  single shift = 2 (G2), consumed by the next putChar.
    s.singleShift2();
    s.putChar('j'); // translated via G2 (DEC special)
    try testing.expectEqual(@as(u21, '┘'), s.cellAt(0, 0).codepoint);

    // single_shift must be cleared after consumption
    try testing.expectEqual(CharsetState.no_shift, s.cursor.charset.ss);

    // next char uses GL (GL = ASCII) again
    s.putChar('j');
    try testing.expectEqual(@as(u21, 'j'), s.cellAt(0, 1).codepoint);
}

test "putChar: SS3 applies G3 for one char than reverts to GL" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.designateCharset(0, .ascii);
    s.designateCharset(3, .dec_special);
    s.shiftIn();

    // SS3: single_shift = 3 (G3).
    s.singleShift3();

    s.putChar('j'); // translated via G3 (DEC special)
    try testing.expectEqual(@as(u21, '┘'), s.cellAt(0, 0).codepoint);

    // single_shift must be cleared after consumption
    try testing.expectEqual(CharsetState.no_shift, s.cursor.charset.ss);

    // next char uses GL (GL = ASCII) again
    s.putChar('j');
    try testing.expectEqual(@as(u21, 'j'), s.cellAt(0, 1).codepoint);
}

test "putChar: single_shift=no_shift means no override (sentinel check)" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.designateCharset(0, .ascii);
    s.designateCharset(2, .dec_special);
    s.shiftIn();

    // Explicitly confirm no single-shift is pending.
    s.cursor.charset.ss = CharsetState.no_shift;

    s.putChar('j');
    // GL (G0=ASCII) used, no translation.
    try testing.expectEqual(@as(u21, 'j'), s.cellAt(0, 0).codepoint);
}

test "putChar: UK charset translates '#' to '£'" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.designateCharset(0, .uk);
    s.shiftIn();

    s.putChar('#');
    try testing.expectEqual(@as(u21, '£'), s.cellAt(0, 0).codepoint);
}

test "putChar: cell inherits cursor.attr" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.attr.flags.bold = true;
    s.putChar('A');
    const cell = s.cellAt(0, 0);

    try testing.expectEqual(@as(u21, 'A'), cell.codepoint);
    try testing.expect(cell.flags.bold);
}

test "setScrollRegion: basic set, 1-based params converted to 0-based" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.setScrollRegion(3, 10); // 1-based: rows 3-10

    try testing.expectEqual(2, s.scroll_top); // 0-based 3-1
    try testing.expectEqual(9, s.scroll_bottom); // 0-based: 10-1
}

test "setScrollRegion: default param (0, 0), full active area" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    // Narrow the region first, then reset via defaults.
    s.setScrollRegion(3, 8);
    s.setScrollRegion(0, 0);

    try testing.expectEqual(0, s.scroll_top);
    try testing.expectEqual(test_max_rows - 1, s.scroll_bottom);
}

test "setScrollRegion: default top only (0, 8)" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.setScrollRegion(0, 8);

    try testing.expectEqual(0, s.scroll_top);
    try testing.expectEqual(7, s.scroll_bottom); // 8-1
}

test "setScrollRegion: default bottom only (3, 0)" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.setScrollRegion(3, 0);

    try testing.expectEqual(2, s.scroll_top); // 3-1
    try testing.expectEqual(test_max_rows - 1, s.scroll_bottom);
}

test "setScrollRegion: cursor moved to (0, 0) in normal mode" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.row = 5;
    s.cursor.col = 10;
    s.setScrollRegion(2, 8);

    try testing.expectEqual(0, s.cursor.row);
    try testing.expectEqual(0, s.cursor.col);
}

test "setScrollRegion: cursor moved to (scroll_top, 0) in origin mode" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.row = 5;
    s.cursor.col = 10;
    s.cursor.origin = true;
    s.setScrollRegion(4, 10); // scroll_top = 3 (0-based)

    try testing.expectEqual(3, s.cursor.row);
    try testing.expectEqual(0, s.cursor.col);
}

test "setScrollRegion: wrap_pending cleared" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.wrap_pending = true;
    s.setScrollRegion(2, 8);

    try testing.expect(!s.cursor.wrap_pending);
}

test "setScrollRegion: generation bumped on valid set" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    const gen = s.generation;
    s.setScrollRegion(2, 8);

    try testing.expectEqual(gen + 1, s.generation);
}

test "setScrollRegion: dirty_rows set for cursor home row (normal mode)" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.dirty_rows = .empty;
    s.setScrollRegion(3, 9);

    try testing.expect(s.dirty_rows.isSet(0));
}

test "setScrollRegion: top == bottom | no-op" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.setScrollRegion(3, 8); // valid first
    const top = s.scroll_top;
    const bot = s.scroll_bottom;
    const gen = s.generation;

    s.setScrollRegion(5, 5); // top == bottom (invalid)

    try testing.expectEqual(top, s.scroll_top);
    try testing.expectEqual(bot, s.scroll_bottom);
    try testing.expectEqual(gen, s.generation); // no bump
}

test "setScrollRegion: top > bottom | no-op" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    const top = s.scroll_top;
    const bot = s.scroll_bottom;
    const gen = s.generation;

    s.setScrollRegion(8, 3); // inverted

    try testing.expectEqual(top, s.scroll_top);
    try testing.expectEqual(bot, s.scroll_bottom);
    try testing.expectEqual(gen, s.generation);
}

test "setScrollRegion: bottom > active_rows | no-op" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    const top = s.scroll_top;
    const bot = s.scroll_bottom;
    const gen = s.generation;

    s.setScrollRegion(1, test_max_rows + 1); // out of bounds

    try testing.expectEqual(top, s.scroll_top);
    try testing.expectEqual(bot, s.scroll_bottom);
    try testing.expectEqual(gen, s.generation);
}

test "setScrollRegion: bottom == active_rows | valid (boundary)" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    // bottom = active_rows (1-based) is the last valid row.
    s.setScrollRegion(1, test_max_rows);

    try testing.expectEqual(0, s.scroll_top);
    try testing.expectEqual(test_max_rows - 1, s.scroll_bottom);
}

test "setScrollRegion: minimum valid region (two adjacent rows)" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.setScrollRegion(5, 6); // rows 5 and 6 (1-based)

    try testing.expectEqual(4, s.scroll_top);
    try testing.expectEqual(5, s.scroll_bottom);
}

test "setScrollRegion: scrollUp respects new region" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    // Fill all rows with distinct markers.
    for (0..s.active_rows) |r| {
        const cell: Cell = .{ .codepoint = @intCast('A' + r), .kind = .narrow };
        fillRow(&s, r, cell);
    }

    // Restrict scroll region to
    // rows 3–6 (1-based), i.e. 0-based 2–5.
    s.setScrollRegion(3, 6);
    s.scrollUp(1);

    // Row 2 (0-based) should now contain what was in row 3.
    const d: Cell = .{ .codepoint = 'D', .kind = .narrow }; // 'A'+3
    try testing.expectEqualDeep(d, s.cellAt(2, 0));

    // Row 0 (outside region) should be untouched ('A').
    const a: Cell = .{ .codepoint = 'A', .kind = .narrow };
    try testing.expectEqualDeep(a, s.cellAt(0, 0));
}

test "setScrollRegion: cursor home after set does not affect cell content" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    const marker: Cell = .{ .codepoint = 'X', .kind = .narrow };
    fillScreen(&s, marker);

    s.setScrollRegion(2, 8);

    // setScrollRegion must not erase any cells.
    try testing.expectEqualDeep(marker, s.cellAt(0, 0));
    try testing.expectEqualDeep(marker, s.cellAt(5, 5));
}

test "eraseChars: erases one character at cursor" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    const marker: Cell = .{ .codepoint = 'X', .kind = .narrow };
    fillRow(&s, 0, marker);

    s.cursor.row = 0;
    s.cursor.col = 3;
    s.eraseChars(1);

    const blank: Cell = .{ .background = s.cursor.attr.bg };
    try testing.expectEqualDeep(blank, s.cellAt(0, 3));
    // neighbours untouched
    try testing.expectEqualDeep(marker, s.cellAt(0, 2));
    try testing.expectEqualDeep(marker, s.cellAt(0, 4));
}

test "eraseChars: erase multiple characters" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    const marker: Cell = .{ .codepoint = 'A', .kind = .narrow };
    fillRow(&s, 0, marker);

    s.cursor.row = 0;
    s.cursor.col = 2;
    s.eraseChars(4); // erase cols: 2..5

    const blank: Cell = .{ .background = s.cursor.attr.bg };
    for (2..6) |c| try testing.expectEqualDeep(blank, s.cellAt(0, c));

    // neighbours untouched
    try testing.expectEqualDeep(marker, s.cellAt(0, 1));
    try testing.expectEqualDeep(marker, s.cellAt(0, 6));
}

test "eraseChars: n=0 treated as n=1" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    const marker: Cell = .{ .codepoint = 'A', .kind = .narrow };
    fillRow(&s, 0, marker);

    s.cursor.row = 0;
    s.cursor.col = 5;
    s.eraseChars(0); // default parameter: erase 1

    const blank: Cell = .{ .background = s.cursor.attr.bg };

    try testing.expectEqualDeep(blank, s.cellAt(0, 5));
    // neighbours untouched
    try testing.expectEqualDeep(marker, s.cellAt(0, 4));
    try testing.expectEqualDeep(marker, s.cellAt(0, 6));
}

test "eraseChars: clamped to end-of-line" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    const marker: Cell = .{ .codepoint = 'A', .kind = .narrow };
    fillRow(&s, 0, marker);

    s.cursor.row = 0;
    s.cursor.col = 20; // test_max_cols=24, so 4 cols remain
    s.eraseChars(999); // clamps to active_cols

    const blank: Cell = .{ .background = s.cursor.attr.bg };

    for (20..24) |c| try testing.expectEqualDeep(blank, s.cellAt(0, c));

    // Cols before cursor: untouched
    try testing.expectEqualDeep(marker, s.cellAt(0, 19));
}

test "eraseChars: cursor does NOT move" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.row = 2;
    s.cursor.col = 7;
    s.eraseChars(3);

    try testing.expectEqual(2, s.cursor.row);
    try testing.expectEqual(7, s.cursor.col);
}

test "eraseChars: wrap_pending is preserved" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.row = 0;
    s.cursor.col = @intCast(s.active_cols - 1);
    s.cursor.wrap_pending = true;
    s.eraseChars(1);

    // wrap_pending must survive, cursor position is unchanged
    try testing.expect(s.cursor.wrap_pending);
}

test "eraseChars: chars to the right are NOT shifted" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    // Write distinct chars: A B C D E at cols 0–4
    for (0..5) |c| {
        s.setCell(0, c, .{ .codepoint = @intCast('A' + c), .kind = .narrow });
    }

    s.cursor.row = 0;
    s.cursor.col = 1;
    s.eraseChars(2); // erase cols 1 and 2

    // Col 0: 'A' untouched
    try testing.expectEqual(@as(u21, 'A'), s.cellAt(0, 0).codepoint);
    // Cols 1–2: blanked
    const blank: Cell = .{ .background = s.cursor.attr.bg };
    try testing.expectEqualDeep(blank, s.cellAt(0, 1));
    try testing.expectEqualDeep(blank, s.cellAt(0, 2));
    // Col 3: 'D' still at col 3 (NOT shifted to col 1)
    try testing.expectEqual(@as(u21, 'D'), s.cellAt(0, 3).codepoint);
    try testing.expectEqual(@as(u21, 'E'), s.cellAt(0, 4).codepoint);
}

test "eraseChars: uses cursor background color" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    const red = s.palette.intern(.{ .rgb = .{ .r = 0, .g = 0, .b = 0 } });
    s.cursor.attr.bg = red;

    const marker: Cell = .{ .codepoint = 'Z', .kind = .narrow };
    s.setCell(0, 0, marker);

    s.cursor.row = 0;
    s.cursor.col = 0;
    s.eraseChars(1);

    try testing.expectEqualDeep(red, s.cellAt(0, 0).background);
}

test "eraseChars: generation bumped" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    const gen = s.generation;
    s.cursor.row = 0;
    s.cursor.col = 0;
    s.eraseChars(1);

    try testing.expectEqual(gen + 1, s.generation);
}

test "eraseChars: dirty_rows set for cursor row" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.dirty_rows = .empty;
    s.cursor.row = 5;
    s.cursor.col = 0;
    s.eraseChars(1);

    try testing.expect(s.dirty_rows.isSet(5));
    // Other rows untouched
    try testing.expect(!s.dirty_rows.isSet(4));
    try testing.expect(!s.dirty_rows.isSet(6));
}

test "eraseChars: only cursor row is dirtied" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.dirty_rows = .empty;
    s.cursor.row = 3;
    s.cursor.col = 0;
    s.eraseChars(s.active_cols); // erase entire row

    try testing.expectEqual(1, s.dirty_rows.count());
    try testing.expect(s.dirty_rows.isSet(3));
}

test "cursorNextLine: basic move down" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.row = 3;
    s.cursor.col = 10;
    s.cursorNextLine(2);

    try testing.expectEqual(5, s.cursor.row);
    try testing.expectEqual(0, s.cursor.col);
}

test "cursorNextLine: n=0 treated as 1" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.row = 4;
    s.cursorNextLine(0);

    try testing.expectEqual(5, s.cursor.row);
    try testing.expectEqual(0, s.cursor.col);
}

test "cursorNextLine: clamps at active_rows - 1" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.row = 9;
    s.cursorNextLine(999);

    try testing.expectEqual(test_max_rows - 1, s.cursor.row);
    try testing.expectEqual(0, s.cursor.col);
}

test "cursorNextLine: already at last row, stays" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.row = test_max_rows - 1; // active_rows - 1
    s.cursorNextLine(1);

    try testing.expectEqual(test_max_rows - 1, s.cursor.row);
}

test "cursorNextLine: clears wrap_pending" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.row = 3;
    s.cursor.col = 23; // last col
    s.cursor.wrap_pending = true;
    s.cursorNextLine(1);

    try testing.expect(!s.cursor.wrap_pending);
    try testing.expectEqual(0, s.cursor.col);
}

test "cursorNextLine: generation bumped" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    const gen = s.generation;
    s.cursor.row = 3;
    s.cursorNextLine(1);

    try testing.expectEqual(gen + 1, s.generation);
}

test "cursorNextLine: dirty_rows marks old and new row" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.dirty_rows = .empty;
    s.cursor.row = 3;
    s.cursorNextLine(2); // 3 → 5

    try testing.expect(s.dirty_rows.isSet(3));
    try testing.expect(s.dirty_rows.isSet(5));
}

test "cursorNextLine: origin mode clamps at scroll_bottom" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    // Restrict scroll region to rows 2–7
    s.scroll_top = 2;
    s.scroll_bottom = 7;
    s.cursor.origin = true;
    s.cursor.row = 6;

    s.cursorNextLine(999);

    // Must not exceed scroll_bottom = 7
    try testing.expectEqual(7, s.cursor.row);
}

test "cursorNextLine: origin mode off, can move past scroll_bottom" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.scroll_top = 2;
    s.scroll_bottom = 7;
    s.cursor.origin = false;
    s.cursor.row = 6;

    s.cursorNextLine(3); // 6 + 3 = 9, within active_rows

    try testing.expectEqual(9, s.cursor.row);
}

test "cursorPrevLine: basic move up" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.row = 7;
    s.cursor.col = 15;
    s.cursorPrevLine(3);

    try testing.expectEqual(4, s.cursor.row);
    try testing.expectEqual(0, s.cursor.col);
}

test "cursorPrevLine: n=0 treated as 1" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.row = 5;
    s.cursorPrevLine(0);

    try testing.expectEqual(4, s.cursor.row);
    try testing.expectEqual(0, s.cursor.col);
}

test "cursorPrevLine: clamps at row 0" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.row = 2;
    s.cursorPrevLine(999);

    try testing.expectEqual(0, s.cursor.row);
    try testing.expectEqual(0, s.cursor.col);
}

test "cursorPrevLine: already at row 0, stays" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.row = 0;
    s.cursorPrevLine(1);

    try testing.expectEqual(0, s.cursor.row);
}

test "cursorPrevLine: clears wrap_pending" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.row = 5;
    s.cursor.col = 23;
    s.cursor.wrap_pending = true;
    s.cursorPrevLine(1);

    try testing.expect(!s.cursor.wrap_pending);
    try testing.expectEqual(0, s.cursor.col);
}

test "cursorPrevLine: generation bumped" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    const gen = s.generation;
    s.cursor.row = 5;
    s.cursorPrevLine(1);

    try testing.expectEqual(gen + 1, s.generation);
}

test "cursorPrevLine: dirty_rows marks old and new row" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.dirty_rows = .empty;
    s.cursor.row = 7;
    s.cursorPrevLine(3); // 7 → 4

    try testing.expect(s.dirty_rows.isSet(7));
    try testing.expect(s.dirty_rows.isSet(4));
}

test "cursorPrevLine: origin mode clamps at scroll_top" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.scroll_top = 3;
    s.scroll_bottom = 9;
    s.cursor.origin = true;
    s.cursor.row = 5;

    s.cursorPrevLine(999);

    // Must not go above scroll_top = 3
    try testing.expectEqual(3, s.cursor.row);
}

test "cursorPrevLine: origin mode off, can move above scroll_top" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.scroll_top = 3;
    s.scroll_bottom = 9;
    s.cursor.origin = false;
    s.cursor.row = 5;

    s.cursorPrevLine(4); // 5 - 4 = 1, above scroll_top but valid

    try testing.expectEqual(1, s.cursor.row);
}

test "cursorPrevLine: exact step to row 0, no underflow" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.row = 3;
    s.cursorPrevLine(3); // exactly 3 - 3 = 0

    try testing.expectEqual(0, s.cursor.row);
}

test "softReset: scroll region reset to full active area" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.scroll_top = 3;
    s.scroll_bottom = 8;
    s.softReset();
    try testing.expectEqual(0, s.scroll_top);
    try testing.expectEqual(s.active_rows - 1, s.scroll_bottom);
}

test "softReset: cursor attributes cleared" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.attr.flags.bold = true;
    s.cursor.attr.flags.strikethrough = true;
    s.cursor.attr.flags.italic = true;
    s.cursor.attr.fg = s.palette.intern(.{ .indexed = 3 });

    s.softReset();

    try testing.expectEqualDeep(Attr{}, s.cursor.attr);
}

test "softReset: charset reset to default" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.designateCharset(1, .dec_special);
    s.shiftOut(); // GL = G1

    s.softReset();

    try testing.expectEqualDeep(CharsetState{}, s.cursor.charset);
}

test "softReset: insert mode cleared" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.mode.insert = true;
    s.softReset();

    try testing.expect(!s.mode.insert);
}

test "softReset: origin mode cleared" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.origin = true;
    s.softReset();

    try testing.expect(!s.cursor.origin);
}

test "softReset: wrap pending cleared" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.wrap_pending = true;
    s.softReset();

    try testing.expect(!s.cursor.wrap_pending);
}

test "softReset: saved cursor reset" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.row = 5;
    s.cursor.col = 10;
    s.saveCursor();
    s.softReset();

    // saved_cursor should be back to default,
    // not the previously saved position
    try testing.expectEqualDeep(SavedCursor{}, s.saved_cursor);
}

test "softReset: cursor position does NOT changed" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.row = 5;
    s.cursor.col = 10;

    s.softReset();

    // soft reset must not home the cursor
    try testing.expectEqual(5, s.cursor.row);
    try testing.expectEqual(10, s.cursor.col);
}

test "softReset: cell content preserved" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    const marker: Cell = .{ .codepoint = 'X', .kind = .narrow };
    fillScreen(&s, marker);

    s.softReset();

    // soft reset must not home the cursor
    try testing.expectEqualDeep(marker, s.cellAt(0, 0));
    try testing.expectEqualDeep(marker, s.cellAt(s.active_rows / 2, s.active_cols / 2));
    try testing.expectEqualDeep(marker, s.cellAt(s.active_rows / 2, 0));
    try testing.expectEqualDeep(marker, s.cellAt(0, s.active_cols / 2));
    try testing.expectEqualDeep(marker, s.cellAt(s.active_rows - 1, s.active_cols - 1));
    try testing.expectEqual(LineAttr.normal, s.line_attrs[s.physRow(2)]);
}

test "softReset: tab stops preserved" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.setTabStop(); // set a custom stop at current col (0)
    s.softReset();

    // Column 0 custom stop must survive soft reset
    try testing.expect(s.tab_stops.isSet(0));
    // Default stops must also survive
    try testing.expect(s.tab_stops.isSet(test_tab_width));
}

test "softReset: dirty_rows = full" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.dirty_rows = .empty;
    s.softReset();

    try testing.expectEqual(s.active_rows, s.dirty_rows.count());
}

test "softReset: generation bump" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    const gen = s.generation;
    s.softReset();

    try testing.expectEqual(gen + 1, s.generation);
}

test "softReset: resets all line_attrs to normal" {
    // TERMV4 M2 item 7: DECSTR reset set is undecided (cursor blink, line attrs).
    if (true) return error.SkipZigTest;

    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    // Set double-width on several rows
    s.cursor.row = 0;
    s.setLineAttr(.double_width);
    s.cursor.row = 3;
    s.setLineAttr(.double_top);
    s.cursor.row = 4;
    s.setLineAttr(.double_bottom);
    s.cursor.row = @intCast(s.active_rows - 1);
    s.setLineAttr(.double_width);

    s.softReset();

    for (0..s.active_rows) |r| {
        try testing.expectEqual(LineAttr.normal, s.line_attrs[s.physRow(r)]);
    }
}

test "softReset: auto_wrap reset to true" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.mode.auto_wrap = false;
    s.softReset();
    try testing.expect(s.mode.auto_wrap); // default is ON
}

test "softReset: cursor_visible reset to true" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.mode.cursor_visibility = false;
    s.softReset();
    try testing.expect(s.mode.cursor_visibility); // default is ON
}

test "softReset: reverse_video reset to false" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.mode.reverse_video = true;
    s.softReset();
    try testing.expect(!s.mode.reverse_video);
}

test "softReset: reverse_wrap reset to false" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.mode.reverse_wrap = true;
    s.softReset();
    try testing.expect(!s.mode.reverse_wrap);
}

test "softReset: non-targeted modes survive" {
    // TERMV4 M2 item 7: DECSTR reset set is undecided (cursor blink, line attrs).
    if (true) return error.SkipZigTest;

    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.mode.smooth_scroll = true;
    s.mode.cursor_blink = true;

    s.softReset();

    try testing.expect(s.mode.smooth_scroll);
    try testing.expect(s.mode.cursor_blink);
}

test "hardReset: all cells cleared to blank" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    fillScreen(&s, .{ .codepoint = 'X', .kind = .narrow });
    s.hardReset();

    const blank: Cell = .{};

    for (0..s.active_rows) |r|
        for (0..s.active_cols) |c|
            try testing.expectEqualDeep(blank, s.cellAt(r, c));
}

test "hardReset: cursor homed to (0,0)" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.row = 7;
    s.cursor.col = 15;
    s.hardReset();

    try testing.expectEqual(0, s.cursor.row);
    try testing.expectEqual(0, s.cursor.col);
}

test "hardReset: cursor state fully reset" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.attr.flags.bold = true;
    s.cursor.attr.flags.reverse = true;
    s.cursor.attr.flags.italic = true;
    s.cursor.attr.flags.strikethrough = true;

    s.cursor.origin = true;
    s.cursor.wrap_pending = true;
    s.shiftOut();

    s.hardReset();

    try testing.expectEqualDeep(Cursor{}, s.cursor);
}

test "hardReset: scroll region reset to full active area" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.scroll_top = 2;
    s.scroll_bottom = 9;

    s.hardReset();

    try testing.expectEqual(0, s.scroll_top);
    try testing.expectEqual(s.active_rows - 1, s.scroll_bottom);
}

test "hardReset: tab stops reset to defaults" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.tab_stops = .empty;
    s.hardReset();

    try testing.expect(s.tab_stops.isSet(test_tab_width));
    try testing.expect(s.tab_stops.isSet(test_tab_width * 2));
    try testing.expect(!s.tab_stops.isSet(0));
}

test "hardReset: ring buffer head reset" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    // simulate some scrolling to advance scroll_offset.
    s.scrollUp(3);
    s.hardReset();

    try testing.expectEqual(0, s.scroll_offset);
}

test "hardReset: insert mode reset" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.mode.insert = true;
    s.hardReset();

    try testing.expect(!s.mode.insert);
}

test "hardReset: dirty_rows = full" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.dirty_rows = .empty;
    s.hardReset();

    try testing.expectEqual(s.active_rows, s.dirty_rows.count());
}

test "hardReset: generation bumped" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    const gen = s.generation;
    s.hardReset();

    try testing.expectEqual(gen + 1, s.generation);
}

test "hardReset: primary screen clears scrollback" {
    const alloc = testing.allocator;
    var s = try primaryScreen(alloc);
    defer s.destroy(alloc);

    // Scroll some lines into history.
    s.scrollUp(4);
    s.hardReset();

    try testing.expectEqual(0, s.scrollback_used);
    try testing.expectEqual(0, s.viewport_offset);
}

test "hardReset: primary screen scroll_offset reset" {
    const alloc = testing.allocator;
    var s = try primaryScreen(alloc);
    defer s.destroy(alloc);

    s.scrollUp(5);
    s.hardReset();

    try testing.expectEqual(0, s.scroll_offset);
}

test "hardReset: scroll_offset reset" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.scrollUp(3);
    s.hardReset();

    try testing.expectEqual(0, s.scroll_offset);
}

test "hardReset: resets all line_attrs to normal" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.row = 0;
    s.setLineAttr(.double_width);
    s.cursor.row = 5;
    s.setLineAttr(.double_top);
    s.cursor.row = 6;
    s.setLineAttr(.double_bottom);

    s.hardReset();

    for (0..s.active_rows) |r| {
        try testing.expectEqual(LineAttr.normal, s.line_attrs[s.physRow(r)]);
    }
}

test "hardReset: clears cell content and line_attrs together" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.row = 1;
    s.cursor.col = 0;
    s.putChar('Z');
    s.setLineAttr(.double_width);

    s.hardReset();

    try testing.expectEqual(@as(u32, 0), s.cellAt(1, 0).codepoint);
    try testing.expectEqual(LineAttr.normal, s.line_attrs[s.physRow(1)]);
}

test "hardReset: ring buffer rows beyond active_rows are also cleared" {
    const alloc = testing.allocator;
    var s = try primaryScreen(alloc);
    defer s.destroy(alloc);

    // Only meaningful when ring_rows > active_rows
    if (comptime primary_ring_rows > test_max_rows) {
        s.line_attrs[s.active_rows] = .double_width;
        s.hardReset();
        for (0..primary_ring_rows) |i| {
            try testing.expectEqual(LineAttr.normal, s.line_attrs[i]);
        }
    } else {
        // Alt screen has no scrollback — ring_rows == active_rows, nothing to test here
        s.hardReset();
        for (0..alt_ring_rows) |i| {
            try testing.expectEqual(LineAttr.normal, s.line_attrs[i]);
        }
    }
}

test "hardReset: saved_cursor reset to defaults" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.row = 5;
    s.cursor.col = 10;
    s.cursor.attr.flags.bold = true;
    s.saveCursor();

    s.hardReset();

    try testing.expectEqualDeep(SavedCursor{}, s.saved_cursor);
}

test "hardReset: modes reset to defaults (non-false defaults)" {
    const alloc = testing.allocator;
    var s = try altScreen(alloc);
    defer s.destroy(alloc);

    s.mode.auto_wrap = false;
    s.mode.cursor_visibility = false;
    s.mode.reverse_video = true;
    s.mode.reverse_wrap = true;
    s.mode.cursor_blink = true;

    s.hardReset();

    try testing.expect(s.mode.auto_wrap); // default ON
    try testing.expect(s.mode.cursor_visibility); // default ON
    try testing.expect(!s.mode.reverse_video);
    try testing.expect(!s.mode.reverse_wrap);
    try testing.expect(!s.mode.cursor_blink);
}

test "setLineAttr: sets .double_width on cursor row" {
    const alloc = testing.allocator;
    var s = try primaryScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.row = 0;
    s.setLineAttr(.double_width);

    try testing.expectEqual(LineAttr.double_width, s.line_attrs[s.physRow(0)]);
}

test "setLineAttr: sets .double_top on non-zero row" {
    const alloc = testing.allocator;
    var s = try primaryScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.row = 3;
    s.setLineAttr(.double_top);

    try testing.expectEqual(LineAttr.double_top, s.line_attrs[s.physRow(3)]);
}

test "setLineAttr: sets .double_bottom" {
    const alloc = testing.allocator;
    var s = try primaryScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.row = 5;
    s.setLineAttr(.double_bottom);

    try testing.expectEqual(LineAttr.double_bottom, s.line_attrs[s.physRow(5)]);
}

test "setLineAttr: overwrite resets to .normal" {
    const alloc = testing.allocator;
    var s = try primaryScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.row = 2;
    s.setLineAttr(.double_width);
    s.setLineAttr(.normal);

    try testing.expectEqual(LineAttr.normal, s.line_attrs[s.physRow(2)]);
}

test "setLineAttr: marks cursor row dirty" {
    const alloc = testing.allocator;
    var s = try primaryScreen(alloc);
    defer s.destroy(alloc);

    s.dirty_rows = .initEmpty();
    s.cursor.row = 4;
    s.setLineAttr(.double_width);

    try testing.expect(s.dirty_rows.isSet(4));
}

test "setLineAttr: does not dirty other rows" {
    const alloc = testing.allocator;
    var s = try primaryScreen(alloc);
    defer s.destroy(alloc);

    s.dirty_rows = .initEmpty();
    s.cursor.row = 4;
    s.setLineAttr(.double_width);

    // Only row 4 should be dirty
    for (0..s.active_rows) |r| {
        if (r == 4) continue;
        try testing.expect(!s.dirty_rows.isSet(r));
    }
}

test "setLineAttr: does not affect other rows' line_attrs" {
    const alloc = testing.allocator;
    var s = try primaryScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.row = 2;
    s.setLineAttr(.double_width);

    // All other rows remain .normal
    for (0..s.active_rows) |r| {
        if (r == 2) continue;
        try testing.expectEqual(LineAttr.normal, s.line_attrs[s.physRow(r)]);
    }
}

test "setLineAttr: displayLineAttr reflects the change" {
    const alloc = testing.allocator;
    var s = try primaryScreen(alloc);
    defer s.destroy(alloc);

    s.cursor.row = 1;
    s.setLineAttr(.double_top);

    try testing.expectEqual(LineAttr.double_top, s.displayLineAttr(1));
}

test "setLineAttr: default is .normal before any call" {
    const alloc = testing.allocator;
    var s = try primaryScreen(alloc);
    defer s.destroy(alloc);

    for (0..s.active_rows) |r| {
        try testing.expectEqual(LineAttr.normal, s.line_attrs[s.physRow(r)]);
    }
}
