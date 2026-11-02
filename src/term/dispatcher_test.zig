const std = @import("std");
const testing = std.testing;

const Option = @import("term.zig").Option;
const Terminal = @import("term.zig").Terminal;
const Mode = @import("term.zig").Mode;

const Attr = @import("cell.zig").Attr;
const Cell = @import("cell.zig").Cell;
const CursorStyle = @import("cell.zig").CursorStyle;
const Color = @import("cell.zig").Color;
const SavedCursor = @import("cell.zig").SavedCursor;

const Palette = @import("palette.zig").Palette;

const max_title_len = @import("term.zig").max_title_len;

const O: Option = .{
    .max_rows = 12,
    .max_cols = 24,
    .tab_width = 8,
    .max_scrollback = 20,
    .name = "test",
    .version = "0.0.1",
};

const T = Terminal(O);
const alloc = testing.allocator;

// C0 / Execute

test "c0: NUL is ignored" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("A");
    t.feed("\x00"); // NUL
    t.feed("B");

    // Cursor should be at col 2 — NUL did not advance or move it
    try testing.expectEqual(@as(u16, 2), t.active.cursor.col);
    try testing.expectEqual(@as(u21, 'A'), t.active.cellAt(0, 0).codepoint);
    try testing.expectEqual(@as(u21, 'B'), t.active.cellAt(0, 1).codepoint);
}

test "c0: ENQ sends answerback" {
    const t = try T.create(testing.alloc);
    defer t.destroy(testing.alloc);

    t.setAnswerback("xterm");
    t.feed("\x05");

    try testing.expectEqualStrings("xterm", t.events.response.slice());
}

test "c0: ENQ with empty answerback sends nothing" {
    const t = try T.create(testing.alloc);
    defer t.destroy(testing.alloc);

    // answerback is empty by default
    t.feed("\x05");

    try testing.expectEqual(@as(usize, 0), t.events.response.len);
}

test "c0: ENQ multiple times concatenates into response buffer" {
    const t = try T.create(testing.alloc);
    defer t.destroy(testing.alloc);

    t.setAnswerback("ab");
    t.feed("\x05\x05");

    try testing.expectEqualStrings("abab", t.events.response.slice());
}

test "c0: BEL sets events.bell" {
    const t = try T.create(testing.alloc);
    defer t.destroy(testing.alloc);

    t.feed("\x07");

    try testing.expect(t.events.bell);
}

test "c0: BEL is deduplicated (multiple BELs : one flag)" {
    const t = try T.create(testing.alloc);
    defer t.destroy(testing.alloc);

    t.feed("\x07\x07\x07");

    try testing.expect(t.events.bell);
    // still just a bool; no count, no overflow
}

test "c0: BS moves cursor left by 1" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("AB");
    try testing.expectEqual(@as(u16, 2), t.active.cursor.col);

    t.feed("\x08"); // BS
    try testing.expectEqual(@as(u16, 1), t.active.cursor.col);
}

test "c0: BS at column 0 stays at column 0" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    try testing.expectEqual(@as(u16, 0), t.active.cursor.col);
    t.feed("\x08"); // BS at col 0
    try testing.expectEqual(@as(u16, 0), t.active.cursor.col);
}

test "c0: BS clears wrap_pending" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    // Fill the row to trigger wrap_pending
    t.feed("A" ** O.max_cols);
    try testing.expect(t.active.cursor.wrap_pending);

    t.feed("\x08"); // BS
    try testing.expect(!t.active.cursor.wrap_pending);
    // Cursor should be at last col - 1 (wrap_pending was at last col)
    try testing.expectEqual(@as(u16, O.max_cols - 2), t.active.cursor.col);
}

test "c0: HT advances to next tab stop" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    // Default tab stops every 8 columns; from col 0 : col 8
    try testing.expectEqual(@as(u16, 0), t.active.cursor.col);
    t.feed("\x09"); // HT
    try testing.expectEqual(@as(u16, 8), t.active.cursor.col);
}

test "c0: HT from mid-tab advances to next tab stop" {
    const t = try T.create(testing.alloc);
    defer t.destroy(testing.alloc);

    t.active.cursor.col = 3;
    t.feed("\x09");

    try testing.expectEqual(@as(u16, 8), t.active.cursor.col);
}

test "c0: HT clamps at last column when no tab stop fits" {
    const t = try T.create(testing.alloc);
    defer t.destroy(testing.alloc);

    // col 20 in a 24-col terminal, next tab stop (24) is past the edge
    t.active.cursor.col = 20;
    t.feed("\x09");

    try testing.expectEqual(@as(u16, O.max_cols - 1), t.active.cursor.col);
}

test "c0: LF moves cursor down one row" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("A");
    try testing.expectEqual(@as(u16, 0), t.active.cursor.row);

    t.feed("\x0A"); // LF
    try testing.expectEqual(@as(u16, 1), t.active.cursor.row);
    // Column unchanged
    try testing.expectEqual(@as(u16, 1), t.active.cursor.col);
}

test "c0: VT behaves like LF" {
    const t = try T.create(testing.alloc);
    defer t.destroy(testing.alloc);

    t.active.cursor.row = 0;
    t.feed("\x0B");

    try testing.expectEqual(@as(u16, 1), t.active.cursor.row);
}

test "c0: FF behaves like LF" {
    const t = try T.create(testing.alloc);
    defer t.destroy(testing.alloc);

    t.active.cursor.row = 0;
    t.feed("\x0C");

    try testing.expectEqual(@as(u16, 1), t.active.cursor.row);
}

test "c0: LF with newline mode also performs CR" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.mode.linefeed = true;
    t.feed("ABC"); // cursor at col 3
    try testing.expectEqual(@as(u16, 3), t.active.cursor.col);

    t.feed("\x0A"); // LF
    try testing.expectEqual(@as(u16, 1), t.active.cursor.row);
    try testing.expectEqual(@as(u16, 0), t.active.cursor.col); // CR performed
}

test "c0: LF without newline mode does not CR" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    // modes.newline defaults to false
    t.feed("ABC"); // cursor at col 3
    t.feed("\x0A"); // LF
    try testing.expectEqual(@as(u16, 1), t.active.cursor.row);
    try testing.expectEqual(@as(u16, 3), t.active.cursor.col); // col unchanged
}

test "c0: LF at scroll_bottom scrolls up" {
    const t = try T.create(testing.alloc);
    defer t.destroy(testing.alloc);

    // Move cursor to last row of scroll region
    t.active.cursor.row = @intCast(t.active.scroll_bottom);
    t.feed("A"); // write a char so we can verify scroll happened
    t.active.cursor.row = @intCast(t.active.scroll_bottom);
    t.feed("\x0A");

    // Cursor stays at scroll_bottom after scroll
    try testing.expectEqual(t.active.scroll_bottom, t.active.cursor.row);
}

test "c0: CR resets cursor to column 0" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("ABC");
    try testing.expectEqual(@as(u16, 3), t.active.cursor.col);

    t.feed("\x0D"); // CR
    try testing.expectEqual(@as(u16, 0), t.active.cursor.col);
    try testing.expectEqual(@as(u16, 0), t.active.cursor.row); // row unchanged
}

test "c0: CR clears wrap_pending" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("A" ** O.max_cols); // fill row : wrap_pending = true
    try testing.expect(t.active.cursor.wrap_pending);

    t.feed("\x0D"); // CR
    try testing.expect(!t.active.cursor.wrap_pending);
    try testing.expectEqual(@as(u16, 0), t.active.cursor.col);
}

test "c0: CR does not change row" {
    const t = try T.create(testing.alloc);
    defer t.destroy(testing.alloc);

    t.active.cursor.row = 5;
    t.active.cursor.col = 10;
    t.feed("\x0D");

    try testing.expectEqual(@as(u16, 5), t.active.cursor.row);
}

test "c0: CRLF moves to start of next line" {
    const t = try T.create(testing.alloc);
    defer t.destroy(testing.alloc);

    t.active.cursor.col = 10;
    t.active.cursor.row = 0;
    t.feed("\x0D\x0A");

    try testing.expectEqual(@as(u16, 0), t.active.cursor.col);
    try testing.expectEqual(@as(u16, 1), t.active.cursor.row);
}

test "c0: SO activates G1 charset" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x0E"); // SO
    try testing.expectEqual(@as(u2, 1), t.active.cursor.charset.gl);
}

test "c0: SI restores G0 charset" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x0E"); // SO : GL = G1
    t.feed("\x0F"); // SI : GL = G0
    try testing.expectEqual(@as(u2, 0), t.active.cursor.charset.gl);
}

test "c0: CR+LF sequence (classic newline)" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("Hello");
    t.feed("\x0D\x0A"); // CR LF
    try testing.expectEqual(@as(u16, 1), t.active.cursor.row);
    try testing.expectEqual(@as(u16, 0), t.active.cursor.col);
}

test "c0: CAN is ignored" {
    const t = try T.create(testing.alloc);
    defer t.destroy(testing.alloc);

    t.active.cursor.col = 5;
    t.feed("\x18");

    try testing.expectEqual(@as(u16, 5), t.active.cursor.col);
    try testing.expect(!t.events.any());
}

test "c0: SUB is ignored" {
    const t = try T.create(testing.alloc);
    defer t.destroy(testing.alloc);

    t.active.cursor.col = 5;
    t.feed("\x1A");

    try testing.expectEqual(@as(u16, 5), t.active.cursor.col);
    try testing.expect(!t.events.any());
}

test "c0: DEL is ignored" {
    const t = try T.create(testing.alloc);
    defer t.destroy(testing.alloc);

    t.active.cursor.col = 5;
    t.feed("\x7F");

    try testing.expectEqual(@as(u16, 5), t.active.cursor.col);
    try testing.expect(!t.events.any());
}

test "c0: events.clear resets bell and response" {
    const t = try T.create(testing.alloc);
    defer t.destroy(testing.alloc);

    t.setAnswerback("hi");
    t.feed("\x07\x05");

    try testing.expect(t.events.bell);
    try testing.expectEqualStrings("hi", t.events.response.slice());

    t.events.clear();

    try testing.expect(!t.events.bell);
    try testing.expectEqual(@as(usize, 0), t.events.response.len);
    try testing.expect(!t.events.any());
}

test "escape: ESC 7 saves cursor position" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.active.cursor.row = 3;
    t.active.cursor.col = 6;

    t.feed("\x1b7"); // DECSC
    try testing.expectEqual(3, t.active.saved_cursor.row);
    try testing.expectEqual(6, t.active.saved_cursor.col);
}

test "escape: ESC 8 restore cursor position" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.active.cursor.row = 5;
    t.active.cursor.col = 10;
    t.feed("\x1b7"); // save

    t.active.cursor.row = 0;
    t.active.cursor.col = 0;
    t.feed("\x1b8"); // restore

    try testing.expectEqual(5, t.active.cursor.row);
    try testing.expectEqual(10, t.active.cursor.col);
}

test "escape: ESC 7 saves cursor SGR attributes" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.active.cursor.attr.flags.bold = true;

    t.feed("\x1b7"); // DECSC
    try testing.expect(t.active.saved_cursor.attr.flags.bold);
}

test "escape: ESC 8 restore cursor SGR attributes" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.active.cursor.attr.flags.bold = true;
    t.feed("\x1b7"); // save

    t.active.cursor.attr = .{};
    t.feed("\x1b8"); // restore

    try testing.expect(t.active.cursor.attr.flags.bold);
}

test "escape: ESC 7/8 round-trip preserves origin mode" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.active.cursor.origin = true;
    t.feed("\x1b7"); // save

    t.active.cursor.origin = false;
    t.feed("\x1b8"); // restore

    try testing.expect(t.active.cursor.origin);
}

test "escape: ESC c DECSC all cells cleared" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("Hello, World!");
    t.feed("\x1bc");
    const row = t.active.row(0);
    for (row[0..13]) |cell| {
        try testing.expectEqual(0, cell.codepoint);
    }
}

test "escape: ESC c DECSC cursor reset to home" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[15;40H"); // CUP
    t.feed("\x1bc");
    try testing.expectEqual(0, t.active.cursor.row);
    try testing.expectEqual(0, t.active.cursor.col);
}

test "escape: ESC c DECSC cursor attr reset" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[1;3m"); // bold + italic
    t.feed("\x1bc");
    try testing.expectEqualDeep(Attr{}, t.active.cursor.attr);
}

test "escape: ESC c DECSC scroll margins reset" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[5;20r");
    t.feed("\x1bc");
    try testing.expectEqual(0, t.active.scroll_top);
    try testing.expectEqual(t.active.active_rows - 1, t.active.scroll_bottom);
}

test "escape: ESC c DECSC modes reset to defaults" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[?7l"); // DECAWM off
    t.feed("\x1b[4h"); // IRM on
    t.feed("\x1b[?6h"); // DECOM on
    t.feed("\x1bc");
    try testing.expect(t.active.mode.auto_wrap);
    try testing.expect(!t.active.mode.insert);
    try testing.expect(!t.active.cursor.origin);
}

test "escape: ESC c DECSC tab stops restored to defaults" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[3g"); // TBC — clear all tab stops
    t.feed("\x1bc");
    // Default tab stops are every 8 columns
    try testing.expect(t.active.tab_stops.isSet(8));
    try testing.expect(t.active.tab_stops.isSet(16));
    try testing.expect(!t.active.tab_stops.isSet(7));
}

test "escape: ESC c DECSC palette reset to ANSI defaults" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    // Intern an RGB color to occupy a dynamic slot
    const idx = t.active.palette.intern(.{ .rgb = .{ .r = 1, .g = 2, .b = 3 } });
    try testing.expect(idx >= Palette.dynamic_base);

    t.feed("\x1bc");

    // After reset, that dynamic slot should no longer hold our color
    const color_after = t.active.palette.resolve(idx);
    try testing.expect(!std.meta.eql(
        color_after,
        Color{ .rgb = .{ .r = 1, .g = 2, .b = 3 } },
    ));

    // ANSI slots must be intact
    try testing.expectEqual(Color{ .indexed = 0 }, t.active.palette.resolve(Palette.ansi_base));
    try testing.expectEqual(Color{ .indexed = 15 }, t.active.palette.resolve(Palette.ansi_base + 15));
}

test "escape: ESC c DECSC scroll_offset reset" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    // Fill screen to trigger scrollback
    for (0..t.active.active_rows + 5) |_| {
        t.feed("line\r\n");
    }
    t.feed("\x1bc");
    try testing.expectEqual(0, t.active.scroll_offset);
}

test "escape: ESC c DECSC dirty_rows covers full screen" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    // Clear dirty state manually
    t.active.dirty_rows = .empty;
    t.feed("\x1bc");
    // All rows should be dirty after hard reset
    for (0..t.active.active_rows) |r| {
        try testing.expect(t.active.dirty_rows.isSet(r));
    }
}

test "escape: ESC c DECSC saved_cursor reset" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[10;20H");
    t.feed("\x1b7"); // DECSC
    t.feed("\x1bc");
    try testing.expectEqualDeep(SavedCursor{}, t.active.saved_cursor);
}

test "escape: ESC D moves cursor down (IND)" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.active.cursor.row = 2;
    t.feed("\x1bD");

    try testing.expectEqual(3, t.active.cursor.row);
}

test "escape: ESC D at scroll_bottom scrolls up" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.active.cursor.row = t.active.scroll_bottom;
    const row_before = t.active.cursor.row;
    t.feed("\x1bD");

    // Cursor stays at scroll_bottom; content scrolled up
    try testing.expectEqual(row_before, t.active.cursor.row);
}

test "escape: ESC E moves cursor down and resets column (NEL)" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.active.cursor.row = 2;
    t.active.cursor.col = 15;
    t.feed("\x1bE");

    try testing.expectEqual(3, t.active.cursor.row);
    try testing.expectEqual(0, t.active.cursor.col);
}

test "escape: ESC E clears wrap_pending" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.active.cursor.wrap_pending = true;
    t.feed("\x1bE");

    try testing.expect(!t.active.cursor.wrap_pending);
}

test "escape: ESC H sets tab stop at cursor column" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.active.cursor.col = 13;
    t.feed("\x1bH");

    try testing.expect(t.active.tab_stops.isSet(13));
}

test "escape: ESC M moves cursor up (RI)" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.active.cursor.row = 5;
    t.feed("\x1bM");

    try testing.expectEqual(4, t.active.cursor.row);
}

test "escape: ESC M at scroll_top scrolls down" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.active.cursor.row = t.active.scroll_top;
    const row_before = t.active.cursor.row;
    t.feed("\x1bM");

    // Cursor stays at scroll_top; content scrolled down
    try testing.expectEqual(row_before, t.active.cursor.row);
}

test "escape: ESC = enables keypad application mode (DECKPAM)" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b=");

    try testing.expect(t.mode.keypad_app);
}

test "escape: ESC > disables keypad application mode (DECKPNM)" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.mode.keypad_app = true;
    t.feed("\x1b>");

    try testing.expect(!t.mode.keypad_app);
}

test "escape: DECKPAM/DECKPNM toggle" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b="); // on
    try testing.expect(t.mode.keypad_app);
    t.feed("\x1b>"); // off
    try testing.expect(!t.mode.keypad_app);
}

test "escape: ESC SP G enables 8-bit C1 (S8C1T)" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b G");
    try testing.expectEqual(.s8c1t, t.control_format);
}

test "escape: ESC SP F restores 7-bit C1 (S7C1T)" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.control_format = .s8c1t; // set initial state
    t.feed("\x1b F");
    try testing.expectEqual(.s7c1t, t.control_format);
}

test "escape: ESC SP L sets s7c1t and level1 (ANSI level 1)" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.control_format = .s8c1t; // set initial state
    t.feed("\x1b L"); // ESC SP L | DECSCL level 1

    try testing.expectEqual(.s7c1t, t.control_format);
    try testing.expectEqual(.level1_7bit, t.conformance_level); // ← also check conformance_level
}

test "escape: ESC SP M sets s8c1t and level2 (ANSI level 2)" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b M"); // ESC SP M | DECSCL level 2

    try testing.expectEqual(.s8c1t, t.control_format);
    try testing.expectEqual(.level2_8bit, t.conformance_level); // ← also check conformance_level
}

test "escape: ESC SP N sets s8c1t and level3 (ANSI level 3)" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b N"); // ESC SP N | DECSCL level 3

    try testing.expectEqual(.s8c1t, t.control_format);
    try testing.expectEqual(.level3_8bit, t.conformance_level); // ← also check conformance_level
}

test "escape: ESC # 8 fills screen with E (DECALN)" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b#8");

    // Every cell in the active area should be 'E'
    for (0..t.active.active_rows) |r| {
        for (0..t.active.active_cols) |c| {
            const cell = t.active.cellAt(r, c);
            try testing.expectEqual('E', cell.codepoint);
        }
    }
}

test "escape: ESC # 8 homes cursor" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.active.cursor.row = 5;
    t.active.cursor.col = 10;
    t.feed("\x1b#8");

    try testing.expectEqual(0, t.active.cursor.row);
    try testing.expectEqual(0, t.active.cursor.col);
}

test "escape: ESC # 8 marks all rows dirty" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.active.dirty_rows = .empty;
    t.feed("\x1b#8");

    try testing.expectEqual(t.active.active_rows, t.active.dirty_rows.count());
}

test "escape: ESC # 3 sets double_top on current row" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.active.cursor.row = 2;
    t.feed("\x1b#3");

    try testing.expectEqual(.double_top, t.active.line_attrs[t.active.physRow(2)]);
}

test "escape: ESC # 4 sets double_bottom on current row" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.active.cursor.row = 2;
    t.feed("\x1b#4");

    try testing.expectEqual(.double_bottom, t.active.line_attrs[t.active.physRow(2)]);
}

test "escape: ESC # 5 sets normal on current row" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.active.cursor.row = 2;
    t.active.setLineAttr(.double_width);
    t.feed("\x1b#5");

    try testing.expectEqual(.normal, t.active.line_attrs[t.active.physRow(2)]);
}

test "escape: ESC # 6 sets double_width on current row" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.active.cursor.row = 3;
    t.feed("\x1b#6");

    try testing.expectEqual(.double_width, t.active.line_attrs[t.active.physRow(3)]);
}

test "escape: ESC ( 0 designates G0 = DEC Special Graphics" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b(0");
    try testing.expectEqual(.dec_special, t.active.cursor.charset.g0);
}

test "escape: ESC ( B designates G0 = ASCII" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.active.cursor.charset.setSlot(0, .dec_special);
    t.feed("\x1b(B");

    try testing.expectEqual(.ascii, t.active.cursor.charset.g0);
}

test "escape: ESC ) 0 designates G1 = DEC Special Graphics" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b)0");
    try testing.expectEqual(.dec_special, t.active.cursor.charset.g1);
}

test "escape: ESC * A designates G2 = UK NRC" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b*A");
    try testing.expectEqual(.uk, t.active.cursor.charset.g2);
}

test "escape: ESC + B designates G3 = ASCII" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.active.cursor.charset.setSlot(0, .dec_special);
    t.feed("\x1b+B");

    try testing.expectEqual(.ascii, t.active.cursor.charset.g3);
}

test "escape: ESC - A designates G1 = iso_latin1" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b\x2d\x41"); // ESC - A
    try testing.expectEqual(.iso_latin1, t.active.cursor.charset.g1);
    // G0, G2, G3 must be untouched
    try testing.expectEqual(.ascii, t.active.cursor.charset.g0);
    try testing.expectEqual(.ascii, t.active.cursor.charset.g2);
    try testing.expectEqual(.ascii, t.active.cursor.charset.g3);
}

test "escape: ESC - B designates G1 = ascii (96-char)" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    // let's set G1 to something non-default so we can verify the change
    t.feed("\x1b\x2d\x41"); // ESC - A  : G1 = iso_latin1
    t.feed("\x1b\x2d\x42"); // ESC - B  : G1 = ascii
    try testing.expectEqual(.ascii, t.active.cursor.charset.g1);
}

test "escape: ESC - 0 designates G1 = dec_special (96-char)" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    // '0' is not a valid 96-char set final byte; falls back to .ascii
    // FIXME not implemented
    t.feed("\x1b-0");
    try testing.expectEqual(.ascii, t.active.cursor.charset.g1);
}

test "escape: ESC . A designates G2 = iso_latin1" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b\x2e\x41"); // ESC . A
    try testing.expectEqual(.iso_latin1, t.active.cursor.charset.g2);
    // G0, G1, G3 must be untouched
    try testing.expectEqual(.ascii, t.active.cursor.charset.g0);
    try testing.expectEqual(.ascii, t.active.cursor.charset.g1);
    try testing.expectEqual(.ascii, t.active.cursor.charset.g3);
}

test "escape: ESC . B designates G2 = ascii (96-char)" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b\x2e\x41"); // ESC . A  : G2 = iso_latin1
    t.feed("\x1b\x2e\x42"); // ESC . B  : G2 = ascii
    try testing.expectEqual(.ascii, t.active.cursor.charset.g2);
}

test "escape: ESC / A designates G3 = iso_latin1" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b\x2f\x41"); // ESC / A
    try testing.expectEqual(.iso_latin1, t.active.cursor.charset.g3);
    // G0, G1, G2 must be untouched
    try testing.expectEqual(.ascii, t.active.cursor.charset.g0);
    try testing.expectEqual(.ascii, t.active.cursor.charset.g1);
    try testing.expectEqual(.ascii, t.active.cursor.charset.g2);
}

test "escape: ESC / 0 designates G3 = dec_special (96-char)" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b-0"); // FIXME not implemented
    // t.feed("\x1b\x2f\x30"); // ESC / 0
    try testing.expectEqual(.ascii, t.active.cursor.charset.g3);
}

test "escape: 96-char designation does not change GL or GR" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    const gl_before = t.active.cursor.charset.gl;
    const gr_before = t.active.cursor.charset.gr;

    t.feed("\x1b\x2d\x41"); // ESC - A
    t.feed("\x1b\x2e\x41"); // ESC . A
    t.feed("\x1b\x2f\x41"); // ESC / A

    try testing.expectEqual(gl_before, t.active.cursor.charset.gl);
    try testing.expectEqual(gr_before, t.active.cursor.charset.gr);
}

test "escape: 96-char G1 designation overrides prior 94-char G1 designation" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b\x29\x30"); // ESC ) 0  : G1 = dec_special (94-char)
    try testing.expectEqual(.dec_special, t.active.cursor.charset.g1);

    t.feed("\x1b\x2d\x41"); // ESC - A  : G1 = iso_latin1 (96-char)
    try testing.expectEqual(.iso_latin1, t.active.cursor.charset.g1);
}

test "escape: 96-char G2 designation is per-screen" {
    // TODO: re-enable once CSI ? 1049 h/l alt-screen switch is implemented
    // const t = try T.create(alloc);
    // defer t.destroy(alloc);
    //
    // t.feed("\x1b\x2e\x41"); // ESC . A, primary G2 = iso_latin1
    // t.feed("\x1b[?1049h"); // switch to alt screen
    // // alt screen G2 should be default (ascii)
    // try testing.expectEqual(.ascii, t.active.cursor.charset.g2);
    //
    // t.feed("\x1b[?1049l"); // switch back to primary
    // try testing.expectEqual(.iso_latin1, t.active.cursor.charset.g2);
}

test "csi: ANSI SC save cursor" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.active.cursor.row = 5;
    t.active.cursor.col = 10;

    t.feed("\x1b[s"); // save

    t.active.cursor.row = 6;
    t.active.cursor.col = 8;

    try testing.expectEqual(6, t.active.cursor.row);
    try testing.expectEqual(8, t.active.cursor.col);

    try testing.expectEqual(5, t.active.saved_cursor.row);
    try testing.expectEqual(10, t.active.saved_cursor.col);
}

test "csi: ANSI RC save cursor" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.active.cursor.row = 5;
    t.active.cursor.col = 10;

    t.feed("\x1b[s"); // first, save

    t.active.cursor.row = 6;
    t.active.cursor.col = 8;

    try testing.expectEqual(6, t.active.cursor.row);
    try testing.expectEqual(8, t.active.cursor.col);

    t.feed("\x1b[u"); // restore

    try testing.expectEqual(5, t.active.cursor.row);
    try testing.expectEqual(10, t.active.cursor.col);
}

test "csi: CUU cursor up by n" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.active.cursor.row = 5;
    t.feed("\x1b[3A");
    try testing.expectEqual(2, t.active.cursor.row);
}

test "csi: CUU default param = 1" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.active.cursor.row = 3;
    t.feed("\x1b[A");
    try testing.expectEqual(2, t.active.cursor.row);
}

test "csi: CUU clamps at row 0" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.active.cursor.row = 1;
    t.feed("\x1b[99A");
    try testing.expectEqual(0, t.active.cursor.row);
}

test "csi: CUD cursor down by n" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.active.cursor.row = 2;
    t.feed("\x1b[3B");
    try testing.expectEqual(5, t.active.cursor.row);
}

test "csi: CUD default param = 1" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.active.cursor.row = 2;
    t.feed("\x1b[B");
    try testing.expectEqual(3, t.active.cursor.row);
}

test "csi: CUD clamps at last row" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.active.cursor.row = @intCast(t.active.active_rows - 2);
    t.feed("\x1b[99B");
    try testing.expectEqual(t.active.active_rows - 1, t.active.cursor.row);
}

test "csi: CUF cursor right by n" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.active.cursor.col = 2;
    t.feed("\x1b[4C");
    try testing.expectEqual(6, t.active.cursor.col);
}

test "csi: CUF default param = 1" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.active.cursor.col = 2;
    t.feed("\x1b[C");
    try testing.expectEqual(3, t.active.cursor.col);
}

test "csi: CUF clamps at last column" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.active.cursor.col = @intCast(t.active.active_cols - 2);
    t.feed("\x1b[99C");
    try testing.expectEqual(t.active.active_cols - 1, t.active.cursor.col);
}

test "csi: CUB cursor left by n" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.active.cursor.col = 8;
    t.feed("\x1b[3D");
    try testing.expectEqual(5, t.active.cursor.col);
}

test "csi: CUB default param = 1" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.active.cursor.col = 5;
    t.feed("\x1b[D");
    try testing.expectEqual(4, t.active.cursor.col);
}

test "csi: CUB clamps at column 0" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.active.cursor.col = 1;
    t.feed("\x1b[99D");
    try testing.expectEqual(0, t.active.cursor.col);
}

test "csi: CNL moves cursor down and reset column" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.active.cursor.row = 2;
    t.active.cursor.col = 7;

    t.feed("\x1b[2E");
    try testing.expectEqual(4, t.active.cursor.row);
    try testing.expectEqual(0, t.active.cursor.col);
}

test "csi: CNL default param = 1" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.active.cursor.row = 3;
    t.active.cursor.col = 5;

    t.feed("\x1b[E");
    try testing.expectEqual(4, t.active.cursor.row);
    try testing.expectEqual(0, t.active.cursor.col);
}

test "csi: CPL moves cursor up and resets column" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.active.cursor.row = 5;
    t.active.cursor.col = 7;

    t.feed("\x1b[2F");
    try testing.expectEqual(3, t.active.cursor.row);
    try testing.expectEqual(0, t.active.cursor.col);
}

test "csi: CPL default param = 1" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.active.cursor.row = 4;
    t.active.cursor.col = 5;

    t.feed("\x1b[F");
    try testing.expectEqual(3, t.active.cursor.row);
    try testing.expectEqual(0, t.active.cursor.col);
}

test "csi: CHA sets column (1-based)" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.active.cursor.col = 0;

    t.feed("\x1b[5G"); // column 5, internal 4
    try testing.expectEqual(4, t.active.cursor.col);
}

test "csi: CHA param 1, column 0" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.active.cursor.col = 10;

    t.feed("\x1b[1G");
    try testing.expectEqual(0, t.active.cursor.col);
}

test "csi: CHA default param = 1, column 0" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.active.cursor.col = 10;

    t.feed("\x1b[G");
    try testing.expectEqual(0, t.active.cursor.col);
}

test "csi: CHA clamps at last column" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[9999G");
    try testing.expectEqual(t.active.active_cols - 1, t.active.cursor.col);
}

test "csi: CUP positions cursor (1-based row and col)" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.active.cursor.row = 5;
    t.active.cursor.col = 5;

    t.feed("\x1b[H");

    try testing.expectEqual(0, t.active.cursor.row);
    try testing.expectEqual(0, t.active.cursor.col);
}

test "csi: CUP param 1;1, home (0,0)" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.active.cursor.row = 5;
    t.active.cursor.col = 5;

    t.feed("\x1b[1;1H");

    try testing.expectEqual(0, t.active.cursor.row);
    try testing.expectEqual(0, t.active.cursor.col);
}

test "csi: CUP clamps to active area" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[999;999H");

    try testing.expectEqual(t.active.active_rows - 1, t.active.cursor.row);
    try testing.expectEqual(t.active.active_cols - 1, t.active.cursor.col);
}

test "csi: HVP positioni cursor identically to CUP" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[3;6f"); // (3,6) = (2,5) for internal

    try testing.expectEqual(2, t.active.cursor.row);
    try testing.expectEqual(5, t.active.cursor.col);
}

test "csi: VPA sets row (1-based, ignores DECOM)" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.active.cursor.row = 0;
    t.feed("\x1b[5d"); // row 5, internal 4

    try testing.expectEqual(4, t.active.cursor.row);
}

test "csi: VPA param 1 = row 0" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.active.cursor.row = 5;
    t.feed("\x1b[1d");

    try testing.expectEqual(0, t.active.cursor.row);
}

test "csi: VPA default param = 1 = row 0" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.active.cursor.row = 5;
    t.feed("\x1b[d");

    try testing.expectEqual(0, t.active.cursor.row);
}

test "csi: VPR moves cursor down by n (relative)" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.active.cursor.row = 2;
    t.feed("\x1b[3e");

    try testing.expectEqual(5, t.active.cursor.row);
}

test "csi: HPA sets column (1-based)" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.active.cursor.col = 0;
    t.feed("\x1b[7`"); // col 7 = internal 6
    try testing.expectEqual(6, t.active.cursor.col);
}

test "csi: HPA param 1 = col 0" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.active.cursor.col = 5;
    t.feed("\x1b[1`");
    try testing.expectEqual(0, t.active.cursor.col);
}

test "csi: HPR moves cursor right by n (relative)" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.active.cursor.col = 3;
    t.feed("\x1b[4a");
    try testing.expectEqual(7, t.active.cursor.col);
}

test "csi: cursor movement clears wrap_pending" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.active.cursor.wrap_pending = true;
    t.feed("\x1b[A"); // any movement
    try testing.expect(!t.active.cursor.wrap_pending);
}

test "csi: DECSTR scroll margins reset to full screen" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    // Set non-default scroll margins via DECSTBM
    t.feed("\x1b[5;20r"); // top=5, bottom=20
    t.feed("\x1b[!p");
    try testing.expectEqual(0, t.active.scroll_top);
    try testing.expectEqual(t.active.active_rows - 1, t.active.scroll_bottom);
}

test "csi: DECSTR cursor attr reset to default" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[1;3;4m"); // bold + italic + underline
    t.feed("\x1b[38;2;255;0;0m"); // fg = rgb(255,0,0)
    t.feed("\x1b[!p");
    try testing.expectEqualDeep(Attr{}, t.active.cursor.attr);
}

test "csi: DECSTR cursor attr fg/bg reset to palette default_idx" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[38;5;196m"); // fg = indexed 196
    t.feed("\x1b[48;5;22m"); // bg = indexed 22
    t.feed("\x1b[!p");
    try testing.expectEqual(Palette.default_base, t.active.cursor.attr.fg);
    try testing.expectEqual(Palette.default_base, t.active.cursor.attr.bg);
}

test "csi: DECSTR origin mode cleared" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[?6h"); // DECOM on
    t.feed("\x1b[!p");
    try testing.expect(!t.active.cursor.origin);
}

test "csi: DECSTR auto_wrap restored to true" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[?7l"); // DECAWM off
    t.feed("\x1b[!p");
    try testing.expect(t.active.mode.auto_wrap);
}

test "csi: DECSTR insert mode cleared" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[4h"); // IRM on
    t.feed("\x1b[!p");
    try testing.expect(!t.active.mode.insert);
}

test "csi: DECSTR wrap_pending cleared" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.active.cursor.wrap_pending = true;
    t.feed("\x1b[!p");
    try testing.expect(!t.active.cursor.wrap_pending);
}

test "csi: DECSTR saved_cursor reset to default" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b7"); // DECSC — save current cursor
    t.active.cursor.row = 5;
    t.active.cursor.col = 10;
    t.feed("\x1b[!p");
    try testing.expectEqualDeep(SavedCursor{}, t.active.saved_cursor);
}

test "csi: DECSTR cell content preserved" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("Hello");
    t.feed("\x1b[!p");
    // Cursor moved but cells written before reset are still there
    const row = t.active.row(0);
    try testing.expectEqual('H', row[0].codepoint);
    try testing.expectEqual('e', row[1].codepoint);
}

test "csi: DECSTR cursor position preserved" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[10;20H"); // CUP row=10, col=20
    t.feed("\x1b[!p");
    // DECSTR does NOT reset cursor position
    try testing.expectEqual(9, t.active.cursor.row); // 0-indexed
    try testing.expectEqual(19, t.active.cursor.col);
}

test "csi: DECSTR tab stops preserved" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[3g"); // TBC; clear all tab stops
    t.feed("\x1b[!p");

    // Tab stops should still be cleared (softReset does not restore them)
    try testing.expect(!t.active.tab_stops.isSet(8));
}

test "csi: ED 0 erases cursor-to-end-of-screen" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    // Fill the entire screen with 'A'.
    for (0..t.active.active_rows) |r| {
        for (t.active.rowMut(r)[0..t.active.active_cols]) |*c| {
            c.* = .{ .codepoint = 'A', .kind = 1 };
        }
    }

    // Cursor at (2, 3) — erase from there to end of screen.
    t.active.cursor.row = 2;
    t.active.cursor.col = 3;
    t.feed("\x1b[J"); // CSI J = CSI 0 J

    // Rows before cursor row are untouched.
    for (0..2) |r| {
        for (t.active.row(r)[0..t.active.active_cols]) |c| {
            try testing.expectEqual(@as(u32, 'A'), c.codepoint);
        }
    }

    // Cursor row: cols before cursor are untouched, cursor col onward are blank.
    const row2 = t.active.row(2);
    for (0..3) |c| try testing.expectEqual(@as(u32, 'A'), row2[c].codepoint);
    for (3..t.active.active_cols) |c| try testing.expectEqual(@as(u32, 0), row2[c].codepoint);

    // Rows after cursor row are fully blank.
    for (3..t.active.active_rows) |r| {
        for (t.active.row(r)[0..t.active.active_cols]) |c| {
            try testing.expectEqual(@as(u32, 0), c.codepoint);
        }
    }

    // Cursor does not move.
    try testing.expectEqual(@as(u16, 2), t.active.cursor.row);
    try testing.expectEqual(@as(u16, 3), t.active.cursor.col);
    try testing.expect(!t.active.cursor.wrap_pending);
}

test "csi: ED 1 erases start-of-screen-to-cursor" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    for (0..t.active.active_rows) |r| {
        for (t.active.rowMut(r)[0..t.active.active_cols]) |*c| {
            c.* = .{ .codepoint = 'A', .kind = 1 };
        }
    }

    t.active.cursor.row = 2;
    t.active.cursor.col = 3;
    t.feed("\x1b[1J");

    // Rows before cursor row are fully blank.
    for (0..2) |r| {
        for (t.active.row(r)[0..t.active.active_cols]) |c| {
            try testing.expectEqual(@as(u32, 0), c.codepoint);
        }
    }
    // Cursor row: cols up to and including cursor are blank, rest untouched.
    const row2 = t.active.row(2);
    for (0..4) |c| try testing.expectEqual(@as(u32, 0), row2[c].codepoint);
    for (4..t.active.active_cols) |c| try testing.expectEqual(@as(u32, 'A'), row2[c].codepoint);
    // Rows after cursor row are untouched.
    for (3..t.active.active_rows) |r| {
        for (t.active.row(r)[0..t.active.active_cols]) |c| {
            try testing.expectEqual(@as(u32, 'A'), c.codepoint);
        }
    }
    try testing.expectEqual(@as(u16, 2), t.active.cursor.row);
    try testing.expectEqual(@as(u16, 3), t.active.cursor.col);
}

test "csi: ED 2 erases entire screen, cursor stays" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    for (0..t.active.active_rows) |r| {
        for (t.active.rowMut(r)[0..t.active.active_cols]) |*c| {
            c.* = .{ .codepoint = 'A', .kind = 1 };
        }
    }

    t.active.cursor.row = 3;
    t.active.cursor.col = 5;
    t.feed("\x1b[2J");

    for (0..t.active.active_rows) |r| {
        for (t.active.row(r)[0..t.active.active_cols]) |c| {
            try testing.expectEqual(@as(u32, 0), c.codepoint);
        }
    }
    // Cursor does NOT move on ED 2.
    try testing.expectEqual(@as(u16, 3), t.active.cursor.row);
    try testing.expectEqual(@as(u16, 5), t.active.cursor.col);
}

test "csi: ED uses current background color for blank cells" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    // Set a non-default background color.
    t.feed("\x1b[41m"); // SGR 41 = red background (indexed 1)
    const bg = t.active.cursor.attr.bg; // palette index for red

    t.active.cursor.row = 0;
    t.active.cursor.col = 0;
    t.feed("\x1b[2J"); // erase entire screen

    // All cells should have the current background color.
    for (t.active.row(0)[0..t.active.active_cols]) |c| {
        try testing.expectEqual(bg, c.background);
        try testing.expectEqual(@as(u32, 0), c.codepoint);
    }
}

test "csi: ED 0 clears wrap_pending" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.active.cursor.wrap_pending = true;
    t.feed("\x1b[J");
    try testing.expect(!t.active.cursor.wrap_pending);
}

test "csi: EL 0 erases cursor-to-end-of-line" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    for (t.active.rowMut(1)[0..t.active.active_cols]) |*c| {
        c.* = .{ .codepoint = 'B', .kind = 1 };
    }

    t.active.cursor.row = 1;
    t.active.cursor.col = 4;
    t.feed("\x1b[K"); // CSI K = CSI 0 K

    const row = t.active.row(1);
    // Cols before cursor are untouched.
    for (0..4) |c| try testing.expectEqual(@as(u32, 'B'), row[c].codepoint);
    // Cursor col onward are blank.
    for (4..t.active.active_cols) |c| try testing.expectEqual(@as(u32, 0), row[c].codepoint);
    // Cursor does not move.
    try testing.expectEqual(@as(u16, 1), t.active.cursor.row);
    try testing.expectEqual(@as(u16, 4), t.active.cursor.col);
}

test "csi: EL 1 erases start-of-line-to-cursor" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    for (t.active.rowMut(0)[0..t.active.active_cols]) |*c| {
        c.* = .{ .codepoint = 'B', .kind = 1 };
    }

    t.active.cursor.row = 0;
    t.active.cursor.col = 5;
    t.feed("\x1b[1K");

    const row = t.active.row(0);
    // Cols 0..=5 (inclusive) are blank.
    for (0..6) |c| try testing.expectEqual(@as(u32, 0), row[c].codepoint);
    // Cols after cursor are untouched.
    for (6..t.active.active_cols) |c| try testing.expectEqual(@as(u32, 'B'), row[c].codepoint);
}

test "csi: EL 2 erases entire line" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    for (t.active.rowMut(2)[0..t.active.active_cols]) |*c| {
        c.* = .{ .codepoint = 'C', .kind = 1 };
    }

    t.active.cursor.row = 2;
    t.active.cursor.col = 7;
    t.feed("\x1b[2K");

    for (t.active.row(2)[0..t.active.active_cols]) |c| {
        try testing.expectEqual(@as(u32, 0), c.codepoint);
    }
    // Cursor does not move.
    try testing.expectEqual(@as(u16, 2), t.active.cursor.row);
    try testing.expectEqual(@as(u16, 7), t.active.cursor.col);
}

test "csi: EL uses current background color for blank cells" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[42m"); // SGR 42 = green background
    const bg = t.active.cursor.attr.bg;

    t.active.cursor.row = 0;
    t.active.cursor.col = 0;
    t.feed("\x1b[2K");

    for (t.active.row(0)[0..t.active.active_cols]) |c| {
        try testing.expectEqual(bg, c.background);
    }
}

test "csi: EL does not affect other rows" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    for (0..t.active.active_rows) |r| {
        for (t.active.rowMut(r)[0..t.active.active_cols]) |*c| {
            c.* = .{ .codepoint = 'D', .kind = 1 };
        }
    }

    t.active.cursor.row = 1;
    t.active.cursor.col = 0;
    t.feed("\x1b[2K"); // erase entire line 1

    // Row 1 is blank.
    for (t.active.row(1)[0..t.active.active_cols]) |c| {
        try testing.expectEqual(@as(u32, 0), c.codepoint);
    }
    // Row 0 and row 2 are untouched.
    for (t.active.row(0)[0..t.active.active_cols]) |c| {
        try testing.expectEqual(@as(u32, 'D'), c.codepoint);
    }
    for (t.active.row(2)[0..t.active.active_cols]) |c| {
        try testing.expectEqual(@as(u32, 'D'), c.codepoint);
    }
}

test "csi: EL 0 clears wrap_pending" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.active.cursor.wrap_pending = true;
    t.feed("\x1b[K");
    try testing.expect(!t.active.cursor.wrap_pending);
}

test "csi: ECH erases n chars at cursor, cursor does not move" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    for (t.active.rowMut(0)[0..t.active.active_cols]) |*c| {
        c.* = .{ .codepoint = 'E', .kind = 1 };
    }

    t.active.cursor.row = 0;
    t.active.cursor.col = 3;
    t.feed("\x1b[4X"); // erase 4 chars starting at col 3

    const row = t.active.row(0);
    // Cols before cursor are untouched.
    for (0..3) |c| try testing.expectEqual(@as(u32, 'E'), row[c].codepoint);
    // Cols 3..6 are blank.
    for (3..7) |c| try testing.expectEqual(@as(u32, 0), row[c].codepoint);
    // Cols after erased region are untouched.
    for (7..t.active.active_cols) |c| try testing.expectEqual(@as(u32, 'E'), row[c].codepoint);
    // Cursor does not move.
    try testing.expectEqual(@as(u16, 0), t.active.cursor.row);
    try testing.expectEqual(@as(u16, 3), t.active.cursor.col);
}

test "csi: ECH 0 erases 1 char (default parameter rule)" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    for (t.active.rowMut(0)[0..t.active.active_cols]) |*c| {
        c.* = .{ .codepoint = 'F', .kind = 1 };
    }

    t.active.cursor.row = 0;
    t.active.cursor.col = 2;
    t.feed("\x1b[X"); // CSI X = CSI 0 X, default = 1

    const row = t.active.row(0);
    for (0..2) |c| try testing.expectEqual(@as(u32, 'F'), row[c].codepoint);
    try testing.expectEqual(@as(u32, 0), row[2].codepoint); // erased
    for (3..t.active.active_cols) |c| try testing.expectEqual(@as(u32, 'F'), row[c].codepoint);
}

test "csi: ECH clamps to end of line" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    for (t.active.rowMut(0)[0..t.active.active_cols]) |*c| {
        c.* = .{ .codepoint = 'G', .kind = 1 };
    }

    t.active.cursor.row = 0;
    t.active.cursor.col = @intCast(t.active.active_cols - 2);
    t.feed("\x1b[9999X"); // huge n — should clamp to end of line

    const row = t.active.row(0);
    const col: usize = t.active.active_cols - 2;
    for (0..col) |c| try testing.expectEqual(@as(u32, 'G'), row[c].codepoint);
    try testing.expectEqual(@as(u32, 0), row[col].codepoint);
    try testing.expectEqual(@as(u32, 0), row[col + 1].codepoint);
}

test "csi: ECH uses current background color" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[43m"); // SGR 43 = yellow background
    const bg = t.active.cursor.attr.bg;

    t.active.cursor.row = 0;
    t.active.cursor.col = 0;
    t.feed("\x1b[3X"); // erase 3 chars

    for (t.active.row(0)[0..3]) |c| {
        try testing.expectEqual(bg, c.background);
        try testing.expectEqual(@as(u32, 0), c.codepoint);
    }
}

test "csi: ECH does not shift remaining chars (unlike DCH)" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    // Write 'A','B','C','D','E' at cols 0-4.
    const row = t.active.rowMut(0);
    row[0] = .{ .codepoint = 'A', .kind = 1 };
    row[1] = .{ .codepoint = 'B', .kind = 1 };
    row[2] = .{ .codepoint = 'C', .kind = 1 };
    row[3] = .{ .codepoint = 'D', .kind = 1 };
    row[4] = .{ .codepoint = 'E', .kind = 1 };

    t.active.cursor.row = 0;
    t.active.cursor.col = 1;
    t.feed("\x1b[2X"); // erase cols 1 and 2

    const r = t.active.row(0);
    try testing.expectEqual(@as(u32, 'A'), r[0].codepoint); // untouched
    try testing.expectEqual(@as(u32, 0), r[1].codepoint); // erased
    try testing.expectEqual(@as(u32, 0), r[2].codepoint); // erased
    try testing.expectEqual(@as(u32, 'D'), r[3].codepoint); // NOT shifted — stays in place
    try testing.expectEqual(@as(u32, 'E'), r[4].codepoint); // NOT shifted
}

test "csi: ICH inserts blank cells and shifts right" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    // row 0: A B C D E at cols 0-4
    {
        const row = t.active.rowMut(0);
        row[0] = .{ .codepoint = 'A', .kind = 1 };
        row[1] = .{ .codepoint = 'B', .kind = 1 };
        row[2] = .{ .codepoint = 'C', .kind = 1 };
        row[3] = .{ .codepoint = 'D', .kind = 1 };
        row[4] = .{ .codepoint = 'E', .kind = 1 };
    }

    t.active.cursor.row = 0;
    t.active.cursor.col = 1;
    t.feed("\x1b[2@"); // ICH 2

    const r = t.active.row(0);
    try testing.expectEqual(@as(u32, 'A'), r[0].codepoint); // unchanged
    try testing.expectEqual(@as(u32, 0), r[1].codepoint); // blank
    try testing.expectEqual(@as(u32, 0), r[2].codepoint); // blank
    try testing.expectEqual(@as(u32, 'B'), r[3].codepoint); // shifted
    try testing.expectEqual(@as(u32, 'C'), r[4].codepoint); // shifted
    // D and E fell off the right edge
}

test "csi: ICH cursor does not move" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.active.cursor.row = 0;
    t.active.cursor.col = 3;
    t.feed("\x1b[2@");
    try testing.expectEqual(@as(u16, 3), t.active.cursor.col);
    try testing.expectEqual(@as(u16, 0), t.active.cursor.row);
}

test "csi: ICH n=0 treated as n=1" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    {
        const row = t.active.rowMut(0);
        row[0] = .{ .codepoint = 'A', .kind = 1 };
        row[1] = .{ .codepoint = 'B', .kind = 1 };
    }

    t.active.cursor.col = 0;
    t.feed("\x1b[0@"); // ICH 0 : treated as 1

    const r = t.active.row(0);
    try testing.expectEqual(@as(u32, 0), r[0].codepoint); // blank inserted
    try testing.expectEqual(@as(u32, 'A'), r[1].codepoint); // shifted
    try testing.expectEqual(@as(u32, 'B'), r[2].codepoint); // shifted
}

test "csi: ICH clears wrap_pending" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.active.cursor.wrap_pending = true;
    t.feed("\x1b[@");
    try testing.expect(!t.active.cursor.wrap_pending);
}

test "csi: ICH blank cells use current background color" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[41m"); // SGR 41 = bg indexed 1
    const bg_idx = t.active.cursor.attr.bg;

    t.active.cursor.col = 0;
    t.feed("\x1b[2@"); // ICH 2

    const r = t.active.row(0);
    try testing.expectEqual(@as(u32, 0), r[0].codepoint);
    try testing.expectEqual(@as(u32, 0), r[1].codepoint);
    try testing.expectEqual(bg_idx, r[0].background);
    try testing.expectEqual(bg_idx, r[1].background);
}

test "csi: ICH at last column replaces cell with blank" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    const last = t.active.active_cols - 1;
    t.active.rowMut(0)[last] = .{ .codepoint = 'Z', .kind = 1 };

    t.active.cursor.col = @intCast(last);
    t.feed("\x1b[@"); // ICH 1 — no room to shift, just blanks the cell

    try testing.expectEqual(@as(u32, 0), t.active.row(0)[last].codepoint);
}

test "csi: DCH deletes cells and shifts left" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    {
        const row = t.active.rowMut(0);
        row[0] = .{ .codepoint = 'A', .kind = 1 };
        row[1] = .{ .codepoint = 'B', .kind = 1 };
        row[2] = .{ .codepoint = 'C', .kind = 1 };
        row[3] = .{ .codepoint = 'D', .kind = 1 };
        row[4] = .{ .codepoint = 'E', .kind = 1 };
    }

    t.active.cursor.row = 0;
    t.active.cursor.col = 1;
    t.feed("\x1b[2P"); // DCH 2

    const r = t.active.row(0);
    try testing.expectEqual(@as(u32, 'A'), r[0].codepoint); // unchanged
    try testing.expectEqual(@as(u32, 'D'), r[1].codepoint); // shifted left
    try testing.expectEqual(@as(u32, 'E'), r[2].codepoint); // shifted left
    try testing.expectEqual(@as(u32, 0), r[3].codepoint); // blank (vacated)
    try testing.expectEqual(@as(u32, 0), r[4].codepoint); // blank (vacated)
}

test "csi: DCH cursor does not move" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.active.cursor.row = 0;
    t.active.cursor.col = 3;
    t.feed("\x1b[2P");
    try testing.expectEqual(@as(u16, 3), t.active.cursor.col);
    try testing.expectEqual(@as(u16, 0), t.active.cursor.row);
}

test "csi: DCH n=0 treated as n=1" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    {
        const row = t.active.rowMut(0);
        row[0] = .{ .codepoint = 'A', .kind = 1 };
        row[1] = .{ .codepoint = 'B', .kind = 1 };
        row[2] = .{ .codepoint = 'C', .kind = 1 };
    }

    t.active.cursor.col = 0;
    t.feed("\x1b[0P"); // DCH 0 : treated as 1

    const r = t.active.row(0);
    try testing.expectEqual(@as(u32, 'B'), r[0].codepoint); // shifted
    try testing.expectEqual(@as(u32, 'C'), r[1].codepoint); // shifted
    try testing.expectEqual(@as(u32, 0), r[2].codepoint); // blank
}

test "csi: DCH clears wrap_pending" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.active.cursor.wrap_pending = true;
    t.feed("\x1b[P");
    try testing.expect(!t.active.cursor.wrap_pending);
}

test "csi: DCH vacated cells use current background color" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[41m"); // SGR 41 = bg indexed 1
    const bg_idx = t.active.cursor.attr.bg;

    {
        const row = t.active.rowMut(0);
        row[0] = .{ .codepoint = 'A', .kind = 1 };
        row[1] = .{ .codepoint = 'B', .kind = 1 };
        row[2] = .{ .codepoint = 'C', .kind = 1 };
    }

    t.active.cursor.col = 0;
    t.feed("\x1b[2P"); // DCH 2 — vacates last 2 cols

    const cols = t.active.active_cols;
    const r = t.active.row(0);
    try testing.expectEqual(@as(u32, 0), r[cols - 2].codepoint);
    try testing.expectEqual(@as(u32, 0), r[cols - 1].codepoint);
    try testing.expectEqual(bg_idx, r[cols - 2].background);
    try testing.expectEqual(bg_idx, r[cols - 1].background);
}

test "csi: IL inserts blank line and shifts rows down" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    for (0..4) |r| {
        t.active.rowMut(r)[0] = .{ .codepoint = @intCast('0' + r), .kind = 1 };
    }

    t.active.cursor.row = 1;
    t.active.cursor.col = 5;
    t.feed("\x1b[L"); // IL 1

    try testing.expectEqual(@as(u32, '0'), t.active.row(0)[0].codepoint); // above: unchanged
    try testing.expectEqual(@as(u32, 0), t.active.row(1)[0].codepoint); // blank (inserted)
    try testing.expectEqual(@as(u32, '1'), t.active.row(2)[0].codepoint); // old row 1
    try testing.expectEqual(@as(u32, '2'), t.active.row(3)[0].codepoint); // old row 2
    // old row 3 ('3') fell off scroll_bottom
}

test "csi: IL cursor moves to column 0" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.active.cursor.row = 2;
    t.active.cursor.col = 7;
    t.feed("\x1b[L");
    try testing.expectEqual(@as(u16, 0), t.active.cursor.col);
    try testing.expectEqual(@as(u16, 2), t.active.cursor.row); // row unchanged
}

test "csi: IL n=0 treated as n=1" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.active.rowMut(0)[0] = .{ .codepoint = 'A', .kind = 1 };
    t.active.rowMut(1)[0] = .{ .codepoint = 'B', .kind = 1 };

    t.active.cursor.row = 0;
    t.feed("\x1b[0L"); // IL 0 : treated as 1

    try testing.expectEqual(@as(u32, 0), t.active.row(0)[0].codepoint); // blank
    try testing.expectEqual(@as(u32, 'A'), t.active.row(1)[0].codepoint); // shifted
    try testing.expectEqual(@as(u32, 'B'), t.active.row(2)[0].codepoint); // shifted
}

test "csi: IL respects scroll region, rows outside region unchanged" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    // Scroll region: rows 1-3 (0-based)
    t.active.scroll_top = 1;
    t.active.scroll_bottom = 3;

    for (0..5) |r| {
        t.active.rowMut(r)[0] = .{ .codepoint = @intCast('0' + r), .kind = 1 };
    }

    t.active.cursor.row = 1;
    t.feed("\x1b[L"); // IL 1

    try testing.expectEqual(@as(u32, '0'), t.active.row(0)[0].codepoint); // above: unchanged
    try testing.expectEqual(@as(u32, 0), t.active.row(1)[0].codepoint); // blank (inserted)
    try testing.expectEqual(@as(u32, '1'), t.active.row(2)[0].codepoint); // old row 1
    try testing.expectEqual(@as(u32, '2'), t.active.row(3)[0].codepoint); // old row 2 (old row 3 discarded)
    try testing.expectEqual(@as(u32, '4'), t.active.row(4)[0].codepoint); // below: unchanged
}

test "csi: IL outside scroll region is no-op" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.active.scroll_top = 2;
    t.active.scroll_bottom = 4;

    // Fill all rows with distinct codepoints.
    for (0..5) |r| {
        t.active.rowMut(r)[0].codepoint = @intCast('0' + r);
    }

    // Place cursor ABOVE the scroll region (row 0) and insert.
    t.active.cursor.row = 0;
    t.feed("\x1b[L"); // IL 1 — cursor is outside scroll region

    // Nothing should have changed.
    for (0..5) |r| {
        try testing.expectEqual(
            @as(u32, @intCast('0' + r)),
            t.active.row(r)[0].codepoint,
        );
    }

    // Place cursor BELOW the scroll region (row 5 if screen is tall enough) and insert.
    t.active.cursor.row = 5;
    t.feed("\x1b[L");

    for (0..5) |r| {
        try testing.expectEqual(
            @as(u32, @intCast('0' + r)),
            t.active.row(r)[0].codepoint,
        );
    }
}

test "csi: DL 1 delete one line at cursor" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    // Fill rows 0-4 with 'A'-'E'.
    for (0..5) |r| {
        t.active.rowMut(r)[0] = .{ .codepoint = @intCast('A' + r), .kind = 1 };
    }

    // Cursor at row 1; delete 1 line.
    t.active.cursor.row = 1;
    t.feed("\x1b[M"); // DL 1

    // Row 0 is above cursor — untouched.
    try testing.expectEqual(@as(u32, 'A'), t.active.row(0)[0].codepoint);
    // Rows 1-3 shifted up from old rows 2-4.
    try testing.expectEqual(@as(u32, 'C'), t.active.row(1)[0].codepoint);
    try testing.expectEqual(@as(u32, 'D'), t.active.row(2)[0].codepoint);
    try testing.expectEqual(@as(u32, 'E'), t.active.row(3)[0].codepoint);
    // Row 4 (bottom of region) is now blank.
    try testing.expectEqual(@as(u32, 0), t.active.row(4)[0].codepoint);
}

test "csi: DL 2 delete two lines" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    for (0..5) |r| {
        t.active.rowMut(r)[0] = .{ .codepoint = @intCast('0' + r), .kind = 1 };
    }

    t.active.cursor.row = 1;
    t.feed("\x1b[2M"); // DL 2

    try testing.expectEqual(@as(u32, '0'), t.active.row(0)[0].codepoint); // above: unchanged
    try testing.expectEqual(@as(u32, '3'), t.active.row(1)[0].codepoint); // old row 3
    try testing.expectEqual(@as(u32, '4'), t.active.row(2)[0].codepoint); // old row 4
    try testing.expectEqual(@as(u32, 0), t.active.row(3)[0].codepoint); // blank
    try testing.expectEqual(@as(u32, 0), t.active.row(4)[0].codepoint); // blank
}

test "csi: DL n=0 treated as n=1" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    for (0..5) |r| {
        t.active.rowMut(r)[0] = .{ .codepoint = @intCast('A' + r), .kind = 1 };
    }

    t.active.cursor.row = 0;
    t.feed("\x1b[0M"); // DL 0 → treated as DL 1

    try testing.expectEqual(@as(u32, 'B'), t.active.row(0)[0].codepoint); // old row 1 shifted up
    try testing.expectEqual(@as(u32, 0), t.active.row(4)[0].codepoint); // blank at bottom
}

test "csi: DL clamps when n > region height" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    for (0..5) |r| {
        t.active.rowMut(r)[0] = .{ .codepoint = @intCast('A' + r), .kind = 1 };
    }

    t.active.cursor.row = 1;
    t.feed("\x1b[99M"); // DL 99 — clamps to region height (4 rows: 1-4)

    try testing.expectEqual(@as(u32, 'A'), t.active.row(0)[0].codepoint); // above: unchanged
    // Rows 1-4 all blank.
    for (1..5) |r| {
        try testing.expectEqual(@as(u32, 0), t.active.row(r)[0].codepoint);
    }
}

test "csi: DL with scroll region" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.active.scroll_top = 1;
    t.active.scroll_bottom = 3;

    for (0..5) |r| {
        t.active.rowMut(r)[0] = .{ .codepoint = @intCast('0' + r), .kind = 1 };
    }

    t.active.cursor.row = 1;
    t.feed("\x1b[M"); // DL 1

    try testing.expectEqual(@as(u32, '0'), t.active.row(0)[0].codepoint); // above region: unchanged
    try testing.expectEqual(@as(u32, '2'), t.active.row(1)[0].codepoint); // old row 2 shifted up
    try testing.expectEqual(@as(u32, '3'), t.active.row(2)[0].codepoint); // old row 3 shifted up
    try testing.expectEqual(@as(u32, 0), t.active.row(3)[0].codepoint); // blank (bottom of region)
    try testing.expectEqual(@as(u32, '4'), t.active.row(4)[0].codepoint); // below region: unchanged
}

test "csi: DL outside scroll region is no-op" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.active.scroll_top = 2;
    t.active.scroll_bottom = 4;

    for (0..5) |r| {
        t.active.rowMut(r)[0] = .{ .codepoint = @intCast('0' + r), .kind = 1 };
    }

    // Cursor above scroll region.
    t.active.cursor.row = 1;
    t.feed("\x1b[M"); // DL 1 — no-op

    for (0..5) |r| {
        try testing.expectEqual(
            @as(u32, @intCast('0' + r)),
            t.active.row(r)[0].codepoint,
        );
    }
}

test "csi: DL blank lines use current background color" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[41m"); // SGR 41 = bg indexed 1
    const bg_idx = t.active.cursor.attr.bg;

    t.active.scroll_top = 0;
    t.active.scroll_bottom = 4;

    for (0..5) |r| {
        t.active.rowMut(r)[0] = .{ .codepoint = @intCast('A' + r), .kind = 1 };
    }

    t.active.cursor.row = 0;
    t.feed("\x1b[M"); // DL 1

    // New blank line at bottom of region carries current bg.
    try testing.expectEqual(bg_idx, t.active.row(4)[0].background);
    try testing.expectEqual(@as(u32, 0), t.active.row(4)[0].codepoint);
}

test "csi: DL cursor row preserved, col reset to 0" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.active.cursor.row = 2;
    t.active.cursor.col = 5;
    t.feed("\x1b[M"); // DL 1

    // Row is preserved; col is reset to 0 (xterm behavior).
    try testing.expectEqual(@as(u16, 2), t.active.cursor.row);
    try testing.expectEqual(@as(u16, 0), t.active.cursor.col);
}

test "csi: DL clears wrap_pending" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.active.cursor.row = 1;
    t.active.cursor.wrap_pending = true;
    t.feed("\x1b[M"); // DL 1

    try testing.expect(!t.active.cursor.wrap_pending);
}

test "csi: DL at bottom of scroll region deletes last line only" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.active.scroll_top = 1;
    t.active.scroll_bottom = 3;

    for (0..5) |r| {
        t.active.rowMut(r)[0] = .{ .codepoint = @intCast('0' + r), .kind = 1 };
    }

    // Cursor at scroll_bottom.
    t.active.cursor.row = 3;
    t.feed("\x1b[M"); // DL 1

    try testing.expectEqual(@as(u32, '0'), t.active.row(0)[0].codepoint);
    try testing.expectEqual(@as(u32, '1'), t.active.row(1)[0].codepoint);
    try testing.expectEqual(@as(u32, '2'), t.active.row(2)[0].codepoint);
    try testing.expectEqual(@as(u32, 0), t.active.row(3)[0].codepoint); // deleted
    try testing.expectEqual(@as(u32, '4'), t.active.row(4)[0].codepoint); // below: unchanged
}

test "csi: SU 1 scrolls content up, blank line at bottom" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    // Fill rows 0-4 with 'A'-'E'.
    for (0..5) |r| {
        t.active.rowMut(r)[0] = .{ .codepoint = @intCast('A' + r), .kind = 1 };
    }

    t.feed("\x1b[S"); // SU 1 (default)

    try testing.expectEqual(@as(u32, 'B'), t.active.row(0)[0].codepoint);
    try testing.expectEqual(@as(u32, 'C'), t.active.row(1)[0].codepoint);
    try testing.expectEqual(@as(u32, 'D'), t.active.row(2)[0].codepoint);
    try testing.expectEqual(@as(u32, 'E'), t.active.row(3)[0].codepoint);
    try testing.expectEqual(@as(u32, 0), t.active.row(4)[0].codepoint); // blank
}

test "csi: SU n=0 treated as n=1" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    for (0..5) |r| {
        t.active.rowMut(r)[0] = .{ .codepoint = @intCast('A' + r), .kind = 1 };
    }

    t.feed("\x1b[0S"); // SU 0 : treated as SU 1

    try testing.expectEqual(@as(u32, 'B'), t.active.row(0)[0].codepoint);
    try testing.expectEqual(@as(u32, 0), t.active.row(4)[0].codepoint);
}

test "csi: SU 2 scrolls up by 2" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    for (0..5) |r| {
        t.active.rowMut(r)[0] = .{ .codepoint = @intCast('A' + r), .kind = 1 };
    }

    t.feed("\x1b[2S"); // SU 2

    try testing.expectEqual(@as(u32, 'C'), t.active.row(0)[0].codepoint);
    try testing.expectEqual(@as(u32, 'D'), t.active.row(1)[0].codepoint);
    try testing.expectEqual(@as(u32, 'E'), t.active.row(2)[0].codepoint);
    try testing.expectEqual(@as(u32, 0), t.active.row(3)[0].codepoint);
    try testing.expectEqual(@as(u32, 0), t.active.row(4)[0].codepoint);
}

test "csi: SU n >= region height clears entire scroll region" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    for (0..5) |r| {
        t.active.rowMut(r)[0] = .{ .codepoint = @intCast('A' + r), .kind = 1 };
    }

    t.feed("\x1b[99S"); // SU 99 — larger than screen

    for (0..5) |r| {
        try testing.expectEqual(@as(u32, 0), t.active.row(r)[0].codepoint);
    }
}

test "csi: SU respects scroll region" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    // scroll region: rows 1-3
    t.active.scroll_top = 1;
    t.active.scroll_bottom = 3;

    for (0..5) |r| {
        t.active.rowMut(r)[0] = .{ .codepoint = @intCast('0' + r), .kind = 1 };
    }

    t.feed("\x1b[S"); // SU 1

    try testing.expectEqual(@as(u32, '0'), t.active.row(0)[0].codepoint); // above: unchanged
    try testing.expectEqual(@as(u32, '2'), t.active.row(1)[0].codepoint); // shifted up
    try testing.expectEqual(@as(u32, '3'), t.active.row(2)[0].codepoint); // shifted up
    try testing.expectEqual(@as(u32, 0), t.active.row(3)[0].codepoint); // blank (new)
    try testing.expectEqual(@as(u32, '4'), t.active.row(4)[0].codepoint); // below: unchanged
}

test "csi: SU blank lines use current background color" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[41m"); // SGR 41 = bg indexed 1
    const bg_idx = t.active.cursor.attr.bg;

    // Constrain scroll region to rows 0-4
    t.active.scroll_top = 0;
    t.active.scroll_bottom = 4;

    for (0..5) |r| {
        t.active.rowMut(r)[0] = .{ .codepoint = @intCast('A' + r), .kind = 1 };
    }

    t.feed("\x1b[S"); // SU 1

    // New blank line at bottom of scroll region (row 4) carries current bg.
    try testing.expectEqual(bg_idx, t.active.row(4)[0].background);
    try testing.expectEqual(@as(u32, 0), t.active.row(4)[0].codepoint);
}

test "csi: SU does not move cursor" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.active.cursor.row = 2;
    t.active.cursor.col = 5;

    t.feed("\x1b[S");

    try testing.expectEqual(@as(u16, 2), t.active.cursor.row);
    try testing.expectEqual(@as(u16, 5), t.active.cursor.col);
}

test "csi: SD 1 scrolls content down, blank line at top" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    for (0..5) |r| {
        t.active.rowMut(r)[0] = .{ .codepoint = @intCast('A' + r), .kind = 1 };
    }

    t.feed("\x1b[T"); // SD 1 (default)

    try testing.expectEqual(@as(u32, 0), t.active.row(0)[0].codepoint); // blank (new)
    try testing.expectEqual(@as(u32, 'A'), t.active.row(1)[0].codepoint);
    try testing.expectEqual(@as(u32, 'B'), t.active.row(2)[0].codepoint);
    try testing.expectEqual(@as(u32, 'C'), t.active.row(3)[0].codepoint);
    try testing.expectEqual(@as(u32, 'D'), t.active.row(4)[0].codepoint); // 'E' scrolled off
}

test "csi: SD n=0 treated as n=1" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    for (0..5) |r| {
        t.active.rowMut(r)[0] = .{ .codepoint = @intCast('A' + r), .kind = 1 };
    }

    t.feed("\x1b[0T"); // SD 0 : treated as SD 1

    try testing.expectEqual(@as(u32, 0), t.active.row(0)[0].codepoint);
    try testing.expectEqual(@as(u32, 'A'), t.active.row(1)[0].codepoint);
}

test "csi: SD 2 scrolls down by 2" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    for (0..5) |r| {
        t.active.rowMut(r)[0] = .{ .codepoint = @intCast('A' + r), .kind = 1 };
    }

    t.feed("\x1b[2T"); // SD 2

    try testing.expectEqual(@as(u32, 0), t.active.row(0)[0].codepoint);
    try testing.expectEqual(@as(u32, 0), t.active.row(1)[0].codepoint);
    try testing.expectEqual(@as(u32, 'A'), t.active.row(2)[0].codepoint);
    try testing.expectEqual(@as(u32, 'B'), t.active.row(3)[0].codepoint);
    try testing.expectEqual(@as(u32, 'C'), t.active.row(4)[0].codepoint);
}

test "csi: SD n >= region height clears entire scroll region" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    for (0..5) |r| {
        t.active.rowMut(r)[0] = .{ .codepoint = @intCast('A' + r), .kind = 1 };
    }

    t.feed("\x1b[99T"); // SD 99 — larger than screen

    for (0..5) |r| {
        try testing.expectEqual(@as(u32, 0), t.active.row(r)[0].codepoint);
    }
}

test "csi: SD respects scroll region" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    // scroll region: rows 1-3
    t.active.scroll_top = 1;
    t.active.scroll_bottom = 3;

    for (0..5) |r| {
        t.active.rowMut(r)[0] = .{ .codepoint = @intCast('0' + r), .kind = 1 };
    }

    t.feed("\x1b[T"); // SD 1

    try testing.expectEqual(@as(u32, '0'), t.active.row(0)[0].codepoint); // above: unchanged
    try testing.expectEqual(@as(u32, 0), t.active.row(1)[0].codepoint); // blank (new)
    try testing.expectEqual(@as(u32, '1'), t.active.row(2)[0].codepoint); // shifted down
    try testing.expectEqual(@as(u32, '2'), t.active.row(3)[0].codepoint); // shifted down ('3' scrolled off)
    try testing.expectEqual(@as(u32, '4'), t.active.row(4)[0].codepoint); // below: unchanged
}

test "csi: SD blank lines use current background color" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[42m"); // SGR 42 = bg indexed 2 (green)
    const bg_idx = t.active.cursor.attr.bg;

    for (0..5) |r| {
        t.active.rowMut(r)[0] = .{ .codepoint = @intCast('A' + r), .kind = 1 };
    }

    t.feed("\x1b[T"); // SD 1

    // New blank line at top should carry the current background.
    try testing.expectEqual(bg_idx, t.active.row(0)[0].background);
    try testing.expectEqual(@as(u32, 0), t.active.row(0)[0].codepoint);
}

test "csi: SD does not move cursor" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.active.cursor.row = 2;
    t.active.cursor.col = 5;

    t.feed("\x1b[T");

    try testing.expectEqual(@as(u16, 2), t.active.cursor.row);
    try testing.expectEqual(@as(u16, 5), t.active.cursor.col);
}

test "csi: SU then SD round-trips content" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    for (0..5) |r| {
        t.active.rowMut(r)[0] = .{ .codepoint = @intCast('A' + r), .kind = 1 };
    }

    t.feed("\x1b[2S"); // SU 2  'A','B' lost; 'C','D','E' at rows 0-2; rows 3-4 blank
    t.feed("\x1b[2T"); // SD 2  rows 3-4 blank shift down; 'C','D','E' at rows 2-4

    // 'A' and 'B' are gone, they scrolled off during SU.
    try testing.expectEqual(@as(u32, 0), t.active.row(0)[0].codepoint);
    try testing.expectEqual(@as(u32, 0), t.active.row(1)[0].codepoint);
    try testing.expectEqual(@as(u32, 'C'), t.active.row(2)[0].codepoint);
    try testing.expectEqual(@as(u32, 'D'), t.active.row(3)[0].codepoint);
    try testing.expectEqual(@as(u32, 'E'), t.active.row(4)[0].codepoint);
}

test "csi: DECSTBM sets scroll region" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[3;7r"); // top=3, bottom=7 (1-based) : 2, 6 (0-based)

    try testing.expectEqual(@as(u16, 2), t.active.scroll_top);
    try testing.expectEqual(@as(u16, 6), t.active.scroll_bottom);
}

test "csi: DECSTBM moves cursor to home" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.active.cursor.row = 3;
    t.active.cursor.col = 5;

    t.feed("\x1b[2;8r");

    try testing.expectEqual(@as(u16, 0), t.active.cursor.row);
    try testing.expectEqual(@as(u16, 0), t.active.cursor.col);
}

test "csi: DECSTBM clears wrap_pending" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.active.cursor.wrap_pending = true;

    t.feed("\x1b[2;8r");

    try testing.expect(!t.active.cursor.wrap_pending);
}

test "csi: DECSTBM no params resets to full screen" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    // First set a non-default region.
    t.feed("\x1b[3;7r");
    try testing.expectEqual(@as(u16, 2), t.active.scroll_top);

    // Reset with no params.
    t.feed("\x1b[r");

    try testing.expectEqual(@as(u16, 0), t.active.scroll_top);
    try testing.expectEqual(@as(u16, t.active.active_rows - 1), t.active.scroll_bottom);
}

test "csi: DECSTBM 0;0 resets to full screen" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[3;7r");
    t.feed("\x1b[0;0r"); // explicit zeros = same as no params

    try testing.expectEqual(@as(u16, 0), t.active.scroll_top);
    try testing.expectEqual(@as(u16, t.active.active_rows - 1), t.active.scroll_bottom);
}

test "csi: DECSTBM top >= bottom is ignored" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    // Set a valid region first.
    t.feed("\x1b[2;6r");
    const top_before = t.active.scroll_top;
    const bot_before = t.active.scroll_bottom;

    // Invalid: top == bottom (1-based 5;5 : 0-based 4;4).
    t.feed("\x1b[5;5r");

    try testing.expectEqual(top_before, t.active.scroll_top);
    try testing.expectEqual(bot_before, t.active.scroll_bottom);
}

test "csi: DECSTBM top > bottom is ignored" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[2;6r");
    const top_before = t.active.scroll_top;
    const bot_before = t.active.scroll_bottom;

    // Invalid: top > bottom (1-based 7;3).
    t.feed("\x1b[7;3r");

    try testing.expectEqual(top_before, t.active.scroll_top);
    try testing.expectEqual(bot_before, t.active.scroll_bottom);
}

test "csi: DECSTBM bottom clamped to active rows" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    // Request bottom beyond screen height.
    t.feed("\x1b[1;9999r");

    try testing.expectEqual(@as(u16, 0), t.active.scroll_top);
    try testing.expectEqual(@as(u16, t.active.active_rows - 1), t.active.scroll_bottom);
}

test "csi: DECSTBM scroll region is used by SU" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    // Fill rows 0-4 with 'A'-'E'.
    for (0..5) |r| {
        t.active.rowMut(r)[0] = .{ .codepoint = @intCast('A' + r), .kind = 1 };
    }

    // Constrain scroll region to rows 1-3.
    t.feed("\x1b[2;4r"); // 1-based 2;4 : 0-based 1;3

    t.feed("\x1b[S"); // SU 1 — scrolls within region only

    // Row 0: untouched (above region).
    try testing.expectEqual(@as(u32, 'A'), t.active.row(0)[0].codepoint);
    // Rows 1-2: shifted up from rows 2-3.
    try testing.expectEqual(@as(u32, 'C'), t.active.row(1)[0].codepoint);
    try testing.expectEqual(@as(u32, 'D'), t.active.row(2)[0].codepoint);
    // Row 3: new blank (bottom of region).
    try testing.expectEqual(@as(u32, 0), t.active.row(3)[0].codepoint);
    // Row 4: untouched (below region).
    try testing.expectEqual(@as(u32, 'E'), t.active.row(4)[0].codepoint);
}

test "csi: CHT moves to next tab stop" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.active.cursor.col = 0;
    t.feed("\x1b[I"); // CHT 1 (default)
    try testing.expectEqual(@as(u16, 8), t.active.cursor.col);
}

test "csi: CHT n=2 skips two tab stops" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.active.cursor.col = 0;
    t.feed("\x1b[2I"); // CHT 2
    try testing.expectEqual(@as(u16, 16), t.active.cursor.col);
}

test "csi: CHT from mid-column advances to next stop" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.active.cursor.col = 5;
    t.feed("\x1b[I");
    try testing.expectEqual(@as(u16, 8), t.active.cursor.col);
}

test "csi: CHT n=0 treated as n=1" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.active.cursor.col = 0;
    t.feed("\x1b[0I"); // CHT 0 : treated as 1
    try testing.expectEqual(@as(u16, 8), t.active.cursor.col);
}

test "csi: CHT past last tab stop clamps to last column" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    // Clear all tab stops so there is nothing to the right of the cursor.
    t.feed("\x1b[3g"); // TBC 3 — clear all

    t.active.cursor.col = 5;
    t.feed("\x1b[I"); // CHT 1
    try testing.expectEqual(
        @as(u16, @intCast(t.active.active_cols - 1)),
        t.active.cursor.col,
    );
}

test "csi: CHT does not change row" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.active.cursor.row = 3;
    t.active.cursor.col = 0;
    t.feed("\x1b[I");
    try testing.expectEqual(@as(u16, 3), t.active.cursor.row);
    try testing.expectEqual(@as(u16, 8), t.active.cursor.col);
}

test "csi: CHT clears wrap_pending" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.active.cursor.wrap_pending = true;
    t.active.cursor.col = 0;
    t.feed("\x1b[I");
    try testing.expect(!t.active.cursor.wrap_pending);
}

test "csi: CHT with custom tab stop" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    // Clear all tab stops, set one at col 5.
    t.feed("\x1b[3g"); // TBC 3 — clear all
    t.active.cursor.col = 5;
    t.feed("\x1bH"); // HTS — set tab at col 5

    t.active.cursor.col = 0;
    t.feed("\x1b[I");
    try testing.expectEqual(@as(u16, 5), t.active.cursor.col);
}

test "csi: CBT moves to previous tab stop" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.active.cursor.col = 16;
    t.feed("\x1b[Z"); // CBT 1 (default)
    try testing.expectEqual(@as(u16, 8), t.active.cursor.col);
}

test "csi: CBT n=2 skips two tab stops" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.active.cursor.col = 24;
    t.feed("\x1b[2Z"); // CBT 2
    try testing.expectEqual(@as(u16, 8), t.active.cursor.col);
}

test "csi: CBT from mid-column goes to previous stop" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    // col 5 is between tab stops 0 and 8; CBT should land on col 0
    // (no tab stop strictly left of col 5 except col 0 if it's a stop,
    // otherwise clamp to col 0).
    t.active.cursor.col = 5;
    t.feed("\x1b[Z");
    try testing.expectEqual(@as(u16, 0), t.active.cursor.col);
}

test "csi: CBT n=0 treated as n=1" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.active.cursor.col = 16;
    t.feed("\x1b[0Z"); // CBT 0 : treated as 1
    try testing.expectEqual(@as(u16, 8), t.active.cursor.col);
}

test "csi: CBT past first tab stop clamps to col 0" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    // From col 8 (first default tab stop), CBT 1 : no stop to the left : col 0.
    t.active.cursor.col = 8;
    t.feed("\x1b[Z");
    try testing.expectEqual(@as(u16, 0), t.active.cursor.col);
}

test "csi: CBT n larger than available stops clamps to col 0" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    // From col 16 there is only one tab stop to the left (col 8).
    // CBT 5 should clamp to col 0.
    t.active.cursor.col = 16;
    t.feed("\x1b[5Z");
    try testing.expectEqual(@as(u16, 0), t.active.cursor.col);
}

test "csi: CBT does not change row" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.active.cursor.row = 3;
    t.active.cursor.col = 16;
    t.feed("\x1b[Z");
    try testing.expectEqual(@as(u16, 3), t.active.cursor.row);
    try testing.expectEqual(@as(u16, 8), t.active.cursor.col);
}

test "csi: CBT clears wrap_pending" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.active.cursor.wrap_pending = true;
    t.active.cursor.col = 16;
    t.feed("\x1b[Z");
    try testing.expect(!t.active.cursor.wrap_pending);
}

test "csi: CBT at col 0 is a no-op (already at leftmost)" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.active.cursor.col = 0;
    t.feed("\x1b[Z");
    try testing.expectEqual(@as(u16, 0), t.active.cursor.col);
}

test "csi: CHT then CBT returns to original column" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.active.cursor.col = 8;
    t.feed("\x1b[I"); // CHT 1 : col 16
    t.feed("\x1b[Z"); // CBT 1 : col 8
    try testing.expectEqual(@as(u16, 8), t.active.cursor.col);
}

test "csi: DSR 5 reporting" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.control_format = .s7c1t;
    t.feed("\x1b[5n");

    try testing.expect(t.events.any());
    try testing.expectEqualStrings("\x1b[0n", t.events.response.slice());
}

test "csi: DSR 6 reporting" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.active.cursor.row = 5;
    t.active.cursor.col = 10;

    t.control_format = .s7c1t;
    t.feed("\x1b[6n");

    try testing.expect(t.events.any());
    try testing.expectEqualStrings("\x1b[6;11R", t.events.response.slice());
}

test "csi: DSR XTVERSION xterm name and version" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.control_format = .s7c1t;
    t.feed("\x1b[>0p");

    try testing.expect(t.events.any());
    try testing.expectEqualStrings("\x1bP>|test 0.0.1\x1b\\", t.events.response.slice());
}

test "csi: DECXCPR report cursor positioin" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.active.cursor.row = 5;
    t.active.cursor.col = 10;

    t.control_format = .s7c1t;
    t.feed("\x1b[?6n");

    try testing.expect(t.events.any());
    try testing.expectEqualStrings("\x1b[?6;11R", t.events.response.slice());
}

test "csi: DA1 send device attributes" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.active.cursor.row = 5;
    t.active.cursor.col = 10;

    t.control_format = .s7c1t;
    t.feed("\x1b[0c");

    try testing.expect(t.events.any());
    try testing.expectEqualStrings("\x1b[?62;22;52c", t.events.response.slice());
}

test "csi: DA2 send device attributes" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.active.cursor.row = 5;
    t.active.cursor.col = 10;

    t.control_format = .s7c1t;
    t.feed("\x1b[>0c");

    try testing.expect(t.events.any());
    try testing.expectEqualStrings("\x1b[>1;0;0c", t.events.response.slice());
}

test "csi: REP repeats last char" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("A"); // putChar 'A'
    t.feed("\x1b[3b"); // REP 3 repeat 'A' three more times

    // Cursor should be at col 4 (A + 3 repeats).
    try testing.expectEqual(@as(u16, 4), t.active.cursor.col);
    try testing.expectEqual(@as(u32, 'A'), t.active.row(0)[0].codepoint);
    try testing.expectEqual(@as(u32, 'A'), t.active.row(0)[1].codepoint);
    try testing.expectEqual(@as(u32, 'A'), t.active.row(0)[2].codepoint);
    try testing.expectEqual(@as(u32, 'A'), t.active.row(0)[3].codepoint);
}

test "csi: REP n=0 treated as n=1" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("B");
    t.feed("\x1b[0b"); // REP 0 treated as 1

    try testing.expectEqual(@as(u16, 2), t.active.cursor.col);
    try testing.expectEqual(@as(u32, 'B'), t.active.row(0)[1].codepoint);
}

test "csi: REP uses current SGR attributes, not original" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[31m"); // fg = indexed 1 (red)
    t.feed("X");
    t.feed("\x1b[32m"); // fg = indexed 2 (green) change attr BEFORE REP
    t.feed("\x1b[b"); // REP 1

    // Original 'X' at col 0 has red fg.
    const red_idx = t.active.palette.intern(.{ .indexed = 1 });
    try testing.expectEqual(red_idx, t.active.row(0)[0].foreground);

    // Repeated 'X' at col 1 has green fg (current attr at time of REP).
    const green_idx = t.active.palette.intern(.{ .indexed = 2 });
    try testing.expectEqual(green_idx, t.active.row(0)[1].foreground);
}

test "csi: REP no-op when no previous char" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    // No putChar called yet; last_char == 0.
    t.feed("\x1b[5b"); // REP 5; should be a no-op
    try testing.expectEqual(@as(u16, 0), t.active.cursor.col);
    try testing.expectEqual(@as(u32, 0), t.active.row(0)[0].codepoint);
}

test "csi: DECSCUSR sets cursor style" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[2 q"); // DECSCUSR 2 = steady block
    try testing.expectEqual(.steady_block, t.active.cursor.style);

    t.feed("\x1b[5 q"); // DECSCUSR 5 = blinking bar
    try testing.expectEqual(.blinking_beam, t.active.cursor.style);

    t.feed("\x1b[0 q"); // DECSCUSR 0 = blinking block (default)
    try testing.expectEqual(.blinking_block, t.active.cursor.style);
}

test "csi: DECSCUSR unknown value resets to default" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[2 q"); // set to steady block first
    t.feed("\x1b[99 q"); // unknown; reset to default
    try testing.expectEqual(CursorStyle.default, t.active.cursor.style);
}

test "escape: ESC c resets cursor style" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[6 q"); // steady bar
    t.feed("\x1bc"); // RIS hard reset
    try testing.expectEqual(CursorStyle.default, t.active.cursor.style);
}

test "sgr: empty params = reset" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.active.cursor.attr.flags.bold = true;
    t.active.cursor.attr.fg = t.active.palette.intern(.{ .indexed = 3 });

    t.feed("\x1b[m");
    try testing.expectEqualDeep(Attr{}, t.active.cursor.attr);
}

test "sgr: 0 explicit reset" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.active.cursor.attr.flags.bold = true;
    t.active.cursor.attr.fg = t.active.palette.intern(.{ .indexed = 5 });

    t.feed("\x1b[0m");
    try testing.expectEqualDeep(Attr{}, t.active.cursor.attr);
}

test "sgr: 0 in sequence resets then continues" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[0;1m"); // reset then bold
    try testing.expect(t.active.cursor.attr.flags.bold);
    try testing.expect(!t.active.cursor.attr.flags.italic);
}

test "sgr: 1 = bold on" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[1m");
    try testing.expect(t.active.cursor.attr.flags.bold);
}

test "sgr: 22 = bold off" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[1m");
    t.feed("\x1b[22m");
    try testing.expect(!t.active.cursor.attr.flags.bold);
}

test "sgr: 2 = dim on" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[2m");
    try testing.expect(t.active.cursor.attr.flags.dim);
}

test "sgr: 22 = dim off" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[2m");
    t.feed("\x1b[22m");
    try testing.expect(!t.active.cursor.attr.flags.dim);
}

test "sgr: 22 resets both bold and dim" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[1m");
    t.feed("\x1b[2m");
    t.feed("\x1b[22m");
    try testing.expect(!t.active.cursor.attr.flags.bold);
    try testing.expect(!t.active.cursor.attr.flags.dim);
}

test "sgr: 3 = italic on" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[3m");
    try testing.expect(t.active.cursor.attr.flags.italic);
}

test "sgr: 23 = italic off" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[3m");
    t.feed("\x1b[23m");
    try testing.expect(!t.active.cursor.attr.flags.italic);
}

test "sgr: 4 = single underline" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[4m");
    try testing.expectEqual(.single, t.active.cursor.attr.flags.underline);
}

test "sgr: 4:0 = underline off (sub-param)" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[4m");
    t.feed("\x1b[4:0m");
    try testing.expectEqual(.none, t.active.cursor.attr.flags.underline);
}

test "sgr: 4:1 = single underline (sub-param)" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[4:1m");
    try testing.expectEqual(.single, t.active.cursor.attr.flags.underline);
}

test "sgr: 4:2 = double underline (sub-param)" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[4:2m");
    try testing.expectEqual(.double, t.active.cursor.attr.flags.underline);
}

test "sgr: 4:3 = curly underline (sub-param)" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[4:3m");
    try testing.expectEqual(.curly, t.active.cursor.attr.flags.underline);
}

test "sgr: 4:4 = dotted underline (sub-param)" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[4:4m");
    try testing.expectEqual(.dotted, t.active.cursor.attr.flags.underline);
}

test "sgr: 4:5 = dashed underline (sub-param)" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[4:5m");
    try testing.expectEqual(.dashed, t.active.cursor.attr.flags.underline);
}

test "sgr: 21 = double underline (legacy)" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[21m");
    try testing.expectEqual(.double, t.active.cursor.attr.flags.underline);
}

test "sgr: 24 = underline off" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[4m");
    t.feed("\x1b[24m");
    try testing.expectEqual(.none, t.active.cursor.attr.flags.underline);
}

test "sgr: 5 = blink on" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[5m");
    try testing.expect(t.active.cursor.attr.flags.blink);
    try testing.expect(!t.active.cursor.attr.flags.blink_rapid);
}

test "sgr: 6 = rapid blink on" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[6m");
    try testing.expect(t.active.cursor.attr.flags.blink_rapid);
    try testing.expect(!t.active.cursor.attr.flags.blink);
}

test "sgr: 25 = blink off (clears both blink and blink_rapid)" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[5m");
    t.feed("\x1b[6m");
    t.feed("\x1b[25m");
    try testing.expect(!t.active.cursor.attr.flags.blink);
    try testing.expect(!t.active.cursor.attr.flags.blink_rapid);
}

test "sgr: 7 = reverse on" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[7m");
    try testing.expect(t.active.cursor.attr.flags.reverse);
}

test "sgr: 27 = reverse off" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[7m");
    t.feed("\x1b[27m");
    try testing.expect(!t.active.cursor.attr.flags.reverse);
}

test "sgr: 8 = invisible on" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[8m");
    try testing.expect(t.active.cursor.attr.flags.invisible);
}

test "sgr: 28 = invisible off" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[8m");
    t.feed("\x1b[28m");
    try testing.expect(!t.active.cursor.attr.flags.invisible);
}

test "sgr: 9 = strikethrough on" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[9m");
    try testing.expect(t.active.cursor.attr.flags.strikethrough);
}

test "sgr: 29 = strikethrough off" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[9m");
    t.feed("\x1b[29m");
    try testing.expect(!t.active.cursor.attr.flags.strikethrough);
}

test "sgr: 53 = overline on" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[53m");
    try testing.expect(t.active.cursor.attr.flags.overline);
}

test "sgr: 55 = overline off" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[53m");
    t.feed("\x1b[55m");
    try testing.expect(!t.active.cursor.attr.flags.overline);
}

test "sgr: 30 = fg black (indexed 0)" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[30m");
    try testing.expectEqual(
        Color{ .indexed = 0 },
        t.active.palette.resolve(t.active.cursor.attr.fg),
    );
}

test "sgr: 37 = fg white (indexed 7)" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[37m");
    try testing.expectEqual(
        Color{ .indexed = 7 },
        t.active.palette.resolve(t.active.cursor.attr.fg),
    );
}

test "sgr: 39 = fg default" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[31m"); // set red
    t.feed("\x1b[39m"); // reset to default
    try testing.expectEqual(
        Color.default,
        t.active.palette.resolve(t.active.cursor.attr.fg),
    );
    try testing.expectEqual(Palette.default_base, t.active.cursor.attr.fg);
}

test "sgr: 40 = bg black (indexed 0)" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[40m");
    try testing.expectEqual(
        Color{ .indexed = 0 },
        t.active.palette.resolve(t.active.cursor.attr.bg),
    );
}

test "sgr: 47 = bg white (indexed 7)" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[47m");
    try testing.expectEqual(
        Color{ .indexed = 7 },
        t.active.palette.resolve(t.active.cursor.attr.bg),
    );
}

test "sgr: 49 = bg default" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[41m");
    t.feed("\x1b[49m");
    try testing.expectEqual(
        Color.default,
        t.active.palette.resolve(t.active.cursor.attr.bg),
    );
    try testing.expectEqual(Palette.default_base, t.active.cursor.attr.bg);
}

test "sgr: 90 = fg bright black (indexed 8)" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[90m");
    try testing.expectEqual(
        Color{ .indexed = 8 },
        t.active.palette.resolve(t.active.cursor.attr.fg),
    );
}

test "sgr: 97 = fg bright white (indexed 15)" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[97m");
    try testing.expectEqual(
        Color{ .indexed = 15 },
        t.active.palette.resolve(t.active.cursor.attr.fg),
    );
}

test "sgr: 100 = bg bright black (indexed 8)" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[100m");
    try testing.expectEqual(
        Color{ .indexed = 8 },
        t.active.palette.resolve(t.active.cursor.attr.bg),
    );
}

test "sgr: 107 = bg bright white (indexed 15)" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[107m");
    try testing.expectEqual(
        Color{ .indexed = 15 },
        t.active.palette.resolve(t.active.cursor.attr.bg),
    );
}

test "sgr: 38;5;200 = fg indexed 200" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[38;5;200m");
    try testing.expectEqual(
        Color{ .indexed = 200 },
        t.active.palette.resolve(t.active.cursor.attr.fg),
    );
}

test "sgr: 38;5;0 = fg indexed 0" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[38;5;0m");
    try testing.expectEqual(
        Color{ .indexed = 0 },
        t.active.palette.resolve(t.active.cursor.attr.fg),
    );
}

test "sgr: 38;5;255 = fg indexed 255" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[38;5;255m");
    try testing.expectEqual(
        Color{ .indexed = 255 },
        t.active.palette.resolve(t.active.cursor.attr.fg),
    );
}

test "sgr: 38:5:200 = fg indexed 200 (colon form)" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[38:5:200m");
    try testing.expectEqual(
        Color{ .indexed = 200 },
        t.active.palette.resolve(t.active.cursor.attr.fg),
    );
}

test "sgr: 38;2;255;0;128 = fg rgb(255,0,128)" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[38;2;255;0;128m");
    try testing.expectEqual(
        Color{ .rgb = .{ .r = 255, .g = 0, .b = 128 } },
        t.active.palette.resolve(t.active.cursor.attr.fg),
    );
}

test "sgr: 38;2;0;0;0 = fg rgb(0,0,0)" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[38;2;0;0;0m");
    try testing.expectEqual(
        Color{ .rgb = .{ .r = 0, .g = 0, .b = 0 } },
        t.active.palette.resolve(t.active.cursor.attr.fg),
    );
}

test "sgr: 38:2:255:128:0 = fg rgb(255,128,0) (colon form)" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[38:2:255:128:0m");
    try testing.expectEqual(
        Color{ .rgb = .{ .r = 255, .g = 128, .b = 0 } },
        t.active.palette.resolve(t.active.cursor.attr.fg),
    );
}

test "sgr: 48;5;100 = bg indexed 100" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[48;5;100m");
    try testing.expectEqual(
        Color{ .indexed = 100 },
        t.active.palette.resolve(t.active.cursor.attr.bg),
    );
}

test "sgr: 48;2;10;20;30 = bg rgb(10,20,30)" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[48;2;10;20;30m");
    try testing.expectEqual(
        Color{ .rgb = .{ .r = 10, .g = 20, .b = 30 } },
        t.active.palette.resolve(t.active.cursor.attr.bg),
    );
}

test "sgr: same rgb color twice = same palette index" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[38;2;100;150;200m");
    const idx1 = t.active.cursor.attr.fg;

    t.feed("\x1b[39m"); // reset fg
    t.feed("\x1b[38;2;100;150;200m"); // same color again
    const idx2 = t.active.cursor.attr.fg;

    try testing.expectEqual(idx1, idx2);
}

test "sgr: combined bold + italic + fg in one sequence" {
    const t = try T.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[1;3;32m"); // bold + italic + fg green (indexed 2)
    try testing.expect(t.active.cursor.attr.flags.bold);
    try testing.expect(t.active.cursor.attr.flags.italic);
    try testing.expectEqual(
        Color{ .indexed = 2 },
        t.active.palette.resolve(t.active.cursor.attr.fg),
    );
}
