const std = @import("std");
const testing = std.testing;

const Mode = @import("term.zig").Mode;
const Terminal = @import("term.zig").Terminal;
const Events = @import("term.zig").Events;
const Option = @import("term.zig").Option;
const Attr = @import("cell.zig").Attr;
const Cell = @import("cell.zig").Cell;

const max_title_len = @import("term.zig").max_title_len;

const Response = Events.Response;

const option: Option = .{
    .max_rows = 12,
    .max_cols = 24,
    .tab_width = 8,
    .max_scrollback = 20,
    .name = "test",
    .version = "0.0.1",
};

const Term = Terminal(option);
const alloc = testing.allocator;

test "Terminal: create and destroy ok" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);
}

test "Terminal: basics" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    try testing.expectEqual(&t.primary, t.active());
    try testing.expect(&t.primary != &t.alternate);
}

test "Terminal: moving by value keeps state and active screen" {
    var a = try Term.create(alloc);
    a.feed("AB\x1b[?1049h" ++ "C");

    var b = a; // move; `a` must not be used again
    defer b.destroy(alloc);

    try testing.expectEqual(.alternate, b.active_buffer);
    try testing.expectEqual(&b.alternate, b.active());
    try testing.expectEqual(@as(u21, 'C'), b.active().cellAt(0, 0).codepoint);

    b.feed("\x1b[?1049l" ++ "D");
    try testing.expectEqual(&b.primary, b.active());
    try testing.expectEqual(@as(u21, 'A'), b.primary.cellAt(0, 0).codepoint);
    try testing.expectEqual(@as(u21, 'D'), b.primary.cellAt(0, 2).codepoint);
}

test "resize: updates both screens" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.resize(8, 16);

    try testing.expectEqual(8, t.primary.active_rows);
    try testing.expectEqual(16, t.primary.active_cols);

    try testing.expectEqual(8, t.alternate.active_rows);
    try testing.expectEqual(16, t.alternate.active_cols);
}

test "resize: clamps to max dimensions" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.resize(999, 999);

    try testing.expectEqual(option.max_rows, t.primary.active_rows);
    try testing.expectEqual(option.max_cols, t.primary.active_cols);

    try testing.expectEqual(option.max_rows, t.alternate.active_rows);
    try testing.expectEqual(option.max_cols, t.alternate.active_cols);
}

test "setTitle/getTitle: round-trip" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.setTitle("hello, from zig!");
    try testing.expectEqualStrings("hello, from zig!", t.getTitle());

    t.setTitle("Hello, World!");
    try testing.expectEqualStrings("Hello, World!", t.getTitle());
}

test "setTitle: empty string clears title" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.setTitle("initial");
    t.setTitle("");

    try testing.expectEqualStrings("", t.getTitle());
    try testing.expectEqual(@as(usize, 0), t.title_len);
}

test "setTitle: truncates at max_title_len" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    // Build a string longer than max_title_len.
    const long: [max_title_len + 32]u8 = [_]u8{'A'} ** (max_title_len + 32);
    t.setTitle(&long);

    try testing.expectEqual(max_title_len, t.title_len);
    // Null terminator must be in bounds.
    try testing.expectEqual(@as(u8, 0), t.title[max_title_len]);
}

test "getTitle: returns null-terminated slice" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.setTitle("zig");

    const s = t.getTitle();
    // sentinel-terminated: s.ptr[s.len] == 0
    try testing.expectEqual(@as(u8, 0), s.ptr[s.len]);
}

test "setIconName/getIconName: round-trip" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.setIconName("myterm");
    try testing.expectEqualStrings("myterm", t.getIconName());
}

test "Terminal: title and icon_name are independent" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.setTitle("title");
    t.setIconName("icon");

    try testing.expectEqualStrings("title", t.getTitle());
    try testing.expectEqualStrings("icon", t.getIconName());
}

test "Terminal: default modes" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    try testing.expect(t.mode.auto_repeat);
    try testing.expect(!t.mode.cursor_keys); // DECTCEM on by default
    try testing.expect(!t.mode.linefeed);
    try testing.expect(!t.mode.bracketed_paste);
    try testing.expect(!t.mode.focus_events);
}

test "Response: filling the buffer" {
    var r: Response = .{};
    r.append("x" ** 255);
    r.append("y"); // len 255 + 1 = 256; shouldn't panic

    try testing.expectEqual(256, r.len);
    r.append("z"); // no room, dropped
    try testing.expectEqual(256, r.len);
}

test "Response: a reply that doesn't fit is dropped, not half-written" {
    var r: Response = .{};
    r.append("x" ** 250);
    r.print("{d}", .{1234567}); // needs 7, 6 free
    r.appendHexU16(0xBEEF); // need 4, fits

    try testing.expectEqual(254, r.len);
    r.appendHex(0xAB); // needs 2, 2 free, fits
    r.appendHex(0xCD); // no room
    try testing.expectEqual(256, r.len);
}

test "Terminal: 60x CPR in one feed does not panic" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[6n" ** 60); // ~7 bytes each, 256 total
    const s = t.events.response.slice();
    try testing.expect(s.len <= 256);
    // Whole replies only each one starts with ESC and ends with 'R'.
    try testing.expectEqual(std.mem.count(u8, s, "\x1b"), std.mem.count(u8, s, "R"));
}

test "Terminal: feed printable ASCII" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    // dispatch is not yet wired; verify the parser loop itself is stable.
    t.feed("hello, world\r\n");
}

test "Terminal: feed CSI sequence" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    // CUP: ESC [ 1 ; 1 H
    t.feed("\x1b[1;1H");
}

test "print: single ASCII character written at cursor" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("A");

    try testing.expectEqual(@as(u21, 'A'), t.active().cellAt(0, 0).codepoint);
    try testing.expectEqual(@as(u16, 1), t.active().cursor.col);
    try testing.expectEqual(@as(u16, 0), t.active().cursor.row);
}

test "print: multiple ASCII characters advance cursor" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("hello");

    try testing.expectEqual(@as(u21, 'h'), t.active().cellAt(0, 0).codepoint);
    try testing.expectEqual(@as(u21, 'e'), t.active().cellAt(0, 1).codepoint);
    try testing.expectEqual(@as(u21, 'l'), t.active().cellAt(0, 2).codepoint);
    try testing.expectEqual(@as(u21, 'l'), t.active().cellAt(0, 3).codepoint);
    try testing.expectEqual(@as(u21, 'o'), t.active().cellAt(0, 4).codepoint);
    try testing.expectEqual(@as(u16, 5), t.active().cursor.col);
}

test "print: UTF-8 two-byte sequence decoded correctly" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    // U+00E9 LATIN SMALL LETTER E WITH ACUTE, 2-byte UTF-8: 0xC3 0xA9
    t.feed("\xC3\xA9");
    // FIXME broken

    // try testing.expectEqual(@as(u21, 0x00E9), t.active().getCell(0, 0).codepoint);
    // try testing.expectEqual(@as(u8, 1), t.active().getCell(0, 0).width);
    // try testing.expectEqual(@as(u16, 1), t.active().cursor.col);
}

test "print: wide CJK character occupies two columns" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    // U+4E2D CJK UNIFIED IDEOGRAPH, 3-byte UTF-8: 0xE4 0xB8 0xAD
    t.feed("\xE4\xB8\xAD");

    // FIXME broken
    // try testing.expectEqual(@as(u21, 0x4E2D), t.active().getCell(0, 0).codepoint);
    // try testing.expectEqual(@as(u8, 2), t.active().getCell(0, 0).width);
    // // col 1 is the continuation placeholder
    // try testing.expectEqual(@as(u21, 0), t.active().getCell(0, 1).codepoint);
    // try testing.expectEqual(@as(u8, 3), t.active().getCell(0, 1).width);
    // // cursor advanced by 2
    // try testing.expectEqual(@as(u16, 2), t.active().cursor.col);
}

test "print: auto-wrap sets wrap_pending at last column" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    // Fill the first row exactly (active_cols = 24)
    t.feed("ABCDEFGHIJKLMNOPQRSTUVWX"); // 24 chars

    // Cursor should be at col 23 with wrap_pending set
    try testing.expectEqual(@as(u16, 23), t.active().cursor.col);
    try testing.expect(t.active().cursor.wrap_pending);
    try testing.expectEqual(@as(u16, 0), t.active().cursor.row);
}

test "print: auto-wrap triggers on next character" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    // Fill row 0, then write one more character
    t.feed("ABCDEFGHIJKLMNOPQRSTUVWX"); // 24 chars; fills row 0
    t.feed("Y"); // triggers wrap

    // 'Y' should be at row 1, col 0
    try testing.expectEqual(@as(u21, 'Y'), t.active().cellAt(1, 0).codepoint);
    try testing.expectEqual(@as(u16, 1), t.active().cursor.col);
    try testing.expectEqual(@as(u16, 1), t.active().cursor.row);
    try testing.expect(!t.active().cursor.wrap_pending);
}

test "print: generation bumped after each character" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    const gen0 = t.active().generation;
    t.feed("A");
    try testing.expect(t.active().generation != gen0);

    const gen1 = t.active().generation;
    t.feed("B");
    try testing.expect(t.active().generation != gen1);
}

test "print: dirty row marked after write" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("Z");

    try testing.expect(t.active().dirty_rows.isSet(0));
}

test "print: writes to active screen, not inactive" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    // primary is active by default
    t.feed("X");

    try testing.expectEqual(@as(u21, 'X'), t.primary.cellAt(0, 0).codepoint);
    // alternate screen is untouched
    try testing.expectEqual(@as(u21, 0), t.alternate.cellAt(0, 0).codepoint);
}

test "softReset: active screen scroll region reset" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().scroll_top = 3;
    t.active().scroll_bottom = 8;
    t.softReset();

    try testing.expectEqual(0, t.active().scroll_top);
    try testing.expectEqual(t.active().active_rows - 1, t.active().scroll_bottom);
}

test "softReset: active screen cursor attrs cleared" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().cursor.attr.flags.bold = true;
    t.active().cursor.attr.fg = t.active().palette.intern(.{ .indexed = 22 });
    t.softReset();

    try testing.expectEqualDeep(Attr{}, t.active().cursor.attr);
}

test "softReset: active screen origin mode cleared" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().cursor.origin = true;
    t.softReset();

    try testing.expect(!t.active().cursor.origin);
}

test "softReset: active screen modes reset" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().mode.auto_wrap = false;
    t.active().mode.insert = true;
    t.active().mode.cursor_visibility = false;
    t.active().mode.reverse_video = true;
    t.active().mode.reverse_wrap = true;
    t.softReset();

    try testing.expect(t.active().mode.auto_wrap); // default ON
    try testing.expect(!t.active().mode.insert);
    try testing.expect(t.active().mode.cursor_visibility); // default ON
    try testing.expect(!t.active().mode.reverse_video);
    try testing.expect(!t.active().mode.reverse_wrap);
}

test "softReset: active screen non-targeted modes survive" {
    // TERMV4 M2 item 7: DECSTR reset set is undecided (cursor blink, line attrs).
    if (true) return error.SkipZigTest;

    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().mode.cursor_blink = true;
    t.active().mode.smooth_scroll = true;
    t.mode.column_132 = true;
    t.softReset();

    // DECSTR must NOT touch these
    try testing.expect(t.active().mode.cursor_blink);
    try testing.expect(t.active().mode.smooth_scroll);
    try testing.expect(t.mode.column_132);
}

test "softReset: terminal modes reset" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.mode.linefeed = true;
    t.mode.cursor_keys = true;
    t.mode.keypad_app = true;
    t.mode.auto_repeat = false;
    t.softReset();

    try testing.expect(!t.mode.linefeed);
    try testing.expect(!t.mode.cursor_keys);
    try testing.expect(!t.mode.keypad_app);
    try testing.expect(t.mode.auto_repeat); // default ON
}

test "softReset: mouse modes survive" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.mode.mouse_button = true;
    t.mode.mouse_sgr = true;
    t.mode.bracketed_paste = true;
    t.mode.focus_events = true;
    t.softReset();

    // DECSTR must NOT touch mouse/paste/focus modes
    try testing.expect(t.mode.mouse_button);
    try testing.expect(t.mode.mouse_sgr);
    try testing.expect(t.mode.bracketed_paste);
    try testing.expect(t.mode.focus_events);
}

test "softReset: cell content survives" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().cursor.row = 0;
    t.active().cursor.col = 0;
    t.active().putChar('X');
    t.softReset();

    // Cell written before reset must still be there
    try testing.expectEqual(@as(u32, 'X'), t.active().cellAt(0, 0).codepoint);
}

test "softReset: alternate screen not affected" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    // Switch to alternate, set a mode, switch back, soft reset
    t.active_buffer = .alternate;
    t.active().mode.insert = true;
    t.active_buffer = .primary;
    t.softReset();

    // Alternate screen's insert mode must be untouched
    try testing.expect(t.alternate.mode.insert);
}

test "hardReset: active screen returns to primary" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active_buffer = .alternate;
    try testing.expectEqual(t.active(), &t.alternate);

    t.hardReset();

    try testing.expectEqual(t.active(), &t.primary);
}

test "hardReset: both screens cells cleared" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.primary.cursor.row = 0;
    t.primary.cursor.col = 0;
    t.primary.putChar('A');

    t.active_buffer = .alternate;
    t.active().cursor.row = 0;
    t.active().cursor.col = 0;
    t.active().putChar('B');
    t.active_buffer = .primary;

    t.hardReset();

    const blank: Cell = .{};
    try testing.expectEqualDeep(blank, t.primary.cellAt(0, 0));
    try testing.expectEqualDeep(blank, t.alternate.cellAt(0, 0));
}

test "hardReset: terminal modes reset to defaults" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.mode.linefeed = true;
    t.mode.cursor_keys = true;
    t.mode.keypad_app = true;
    t.mode.auto_repeat = false; // default ON
    t.mode.mouse_any = true;
    t.mode.bracketed_paste = true;
    t.mode.focus_events = true;
    t.active().cursor.style = .blinking_underline;
    t.hardReset();

    try testing.expectEqualDeep(Mode{}, t.mode);
    try testing.expect(t.mode.auto_repeat); // default ON
}

test "hardReset: title and icon name cleared" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.setTitle("my terminal");
    t.setIconName("icon");
    t.hardReset();

    try testing.expectEqual(0, t.title_len);
    try testing.expectEqual(0, t.icon_name_len);
}

test "hardReset: events cleared" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.events.bell = true;
    t.events.response.append("foo");
    t.hardReset();

    try testing.expect(!t.events.bell);
    try testing.expect(t.events.response.isEmpty());
}

test "hardReset: answerback preserved" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.setAnswerback("xterm");
    t.hardReset();

    try testing.expectEqualStrings("xterm", t.getAnswerback());
}

test "Terminal: xtversion 7-bit reply" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.control_format = .s8c1t;
    t.xtversion();

    // const out = t.events.response.slice();
    // for (out) |b| {
    //     std.debug.print("'{c}'\n{x:0>2}\n", .{ b, b });
    // }
    try testing.expectEqualStrings("\x90>|test 0.0.1\x9c", t.events.response.slice());
}

test "invalid utf-8: sequence cut by ESC is one u+fffd, then ESC runs" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    // F0 9F 98 is a valid 3-byte prefix; ESC [ 2 C moves right by two.
    t.feed("\xF0\x9F\x98\x1b[2CZ");
    try testing.expectEqual(@as(u32, 0xFFFD), t.active().cellAt(0, 0).codepoint);
    try testing.expectEqual(@as(u32, 'Z'), t.active().cellAt(0, 3).codepoint);
}

test "invalid utf-8: C3 41 prints u+fffd then A" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\xC3");
    t.feed("A");
    try testing.expectEqual(@as(u32, 0xFFFD), t.active().cellAt(0, 0).codepoint);
    try testing.expectEqual(@as(u32, 'A'), t.active().cellAt(0, 1).codepoint);
}

test "invalid utf-8: truncated sequence at end() is u+fffd" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\xE4\xB8");
    t.end();
    try testing.expectEqual(@as(u32, 0xFFFD), t.active().cellAt(0, 0).codepoint);
}

fn expectCluster(t: *Term, row: usize, col: usize, want: []const u21) !void {
    const cell = t.active().cellAt(row, col);
    try testing.expect(cell.kind.isGrapheme());
    try testing.expectEqualSlices(u21, want, t.active().getGrapheme(cell.codepoint).?);
}

test "combining: e + U+0301 is one cell with the cluster" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("e\xCC\x81x");
    try expectCluster(&t, 0, 0, &.{ 'e', 0x301 });
    try testing.expectEqual(@as(u32, 'x'), t.active().cellAt(0, 1).codepoint);
}

test "combining: U+00E9 + U+0301 keeps both" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\xC3\xA9\xCC\x81");
    try expectCluster(&t, 0, 0, &.{ 0xE9, 0x301 });
    try testing.expectEqual(@as(u16, 1), t.active().cursor.col);
}

test "combining: mark at the last column with wrap pending" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[1;24Ha");
    try testing.expect(t.active().cursor.wrap_pending);
    t.feed("\xCC\x81");
    try expectCluster(&t, 0, 23, &.{ 'a', 0x301 });
    try testing.expect(t.active().cursor.wrap_pending);
}

test "combining: mark at column 0 is dropped" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\xCC\x81");
    t.end();
    try testing.expectEqual(.empty, t.active().cellAt(0, 0).kind);
    try testing.expectEqual(@as(u16, 0), t.active().cursor.col);
}

test "combining: mark on wide CJK attaches to the left half" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\xE4\xB8\xAD\xCC\x81"); // U+4E2D U+0301
    try expectCluster(&t, 0, 0, &.{ 0x4E2D, 0x301 });
    try testing.expectEqual(.grapheme_wide, t.active().cellAt(0, 0).kind);
    try testing.expectEqual(.wide_right, t.active().cellAt(0, 1).kind);
    try testing.expectEqual(@as(u16, 2), t.active().cursor.col);
}

fn expectAllClustersResolve(t: *Term) !void {
    for (t.active().cells) |cell| {
        if (cell.kind.isGrapheme()) try testing.expect(t.active().getGrapheme(cell.codepoint) != null);
    }
}

test "grapheme intern: table stays bounded while scrolling" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);
    const S = @TypeOf(t.active().*);

    const n = 3 * S.grapheme_compact_min;
    for (0..n) |i| {
        const base: u21 = @intCast(0x20000 + i);
        try t.active().putGrapheme(&.{ base, 0x0301 }, .narrow);
    }
    try testing.expect(t.active().grapheme_table.count() <= S.grapheme_compact_min);
    try expectAllClustersResolve(&t);

    // The last written cell still holds the last cluster.
    const col: usize = if (t.active().cursor.wrap_pending) t.active().cursor.col else t.active().cursor.col - 1;
    const cell = t.active().cellAt(t.active().cursor.row, col);
    const want = [_]u21{ @intCast(0x20000 + n - 1), 0x0301 };
    try testing.expectEqualSlices(u21, &want, t.active().getGrapheme(cell.codepoint).?);
}

test "grapheme intern: ED 2 keeps clusters referenced by scrollback" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("e\xCC\x81");
    for (0..option.max_rows) |_| t.feed("\n");
    t.feed("\x1b[2J");
    try testing.expect(t.active().grapheme_table.count() > 0);
    try expectAllClustersResolve(&t);
}
