const std = @import("std");
const testing = std.testing;

const Terminal = @import("term.zig").Terminal;
const Mode = @import("term.zig").Mode;
const DecModeReport = @import("term.zig").DecModeReport;

const Attr = @import("cell.zig").Attr;
const Cell = @import("cell.zig").Cell;
const CursorStyle = @import("cell.zig").CursorStyle;
const Color = @import("cell.zig").Color;
const SavedCursor = @import("cell.zig").SavedCursor;

const Palette = @import("Palette.zig").Palette;
const Rgb = Color.Rgb;
const ansi = @import("../color/ansi.zig");
const Theme = @import("../color/Theme.zig");

const max_title_len = @import("term.zig").max_title_len;

const test_option = @import("test_fixtures.zig").test_option;

const Term = Terminal(test_option);
const alloc = testing.allocator;

// C0 / Execute

test "c0: NUL is ignored" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("A");
    t.feed("\x00"); // NUL
    t.feed("B");

    // Cursor should be at col 2 — NUL did not advance or move it
    try testing.expectEqual(@as(u16, 2), t.active().cursor.col);
    try testing.expectEqual(@as(u21, 'A'), t.active().cellAt(0, 0).codepoint);
    try testing.expectEqual(@as(u21, 'B'), t.active().cellAt(0, 1).codepoint);
}

test "c0: ENQ sends answerback" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.setAnswerback("xterm");
    t.feed("\x05");

    try testing.expectEqualStrings("xterm", t.events.response.slice());
}

test "c0: ENQ with empty answerback sends nothing" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    // answerback is empty by default
    t.feed("\x05");

    try testing.expectEqual(@as(usize, 0), t.events.response.len);
}

test "c0: ENQ multiple times concatenates into response buffer" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.setAnswerback("ab");
    t.feed("\x05\x05");

    try testing.expectEqualStrings("abab", t.events.response.slice());
}

test "c0: BEL sets events.bell" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x07");

    try testing.expect(t.events.bell);
}

test "c0: BEL is deduplicated (multiple BELs : one flag)" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x07\x07\x07");

    try testing.expect(t.events.bell);
    // still just a bool; no count, no overflow
}

test "c0: BS moves cursor left by 1" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("AB");
    try testing.expectEqual(@as(u16, 2), t.active().cursor.col);

    t.feed("\x08"); // BS
    try testing.expectEqual(@as(u16, 1), t.active().cursor.col);
}

test "c0: BS at column 0 stays at column 0" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    try testing.expectEqual(@as(u16, 0), t.active().cursor.col);
    t.feed("\x08"); // BS at col 0
    try testing.expectEqual(@as(u16, 0), t.active().cursor.col);
}

test "c0: BS clears wrap_pending" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    // Fill the row to trigger wrap_pending
    t.feed("A" ** test_option.max_cols);
    try testing.expect(t.active().cursor.wrap_pending);

    t.feed("\x08"); // BS
    try testing.expect(!t.active().cursor.wrap_pending);
    // Cursor should be at last col - 1 (wrap_pending was at last col)
    try testing.expectEqual(@as(u16, test_option.max_cols - 2), t.active().cursor.col);
}

test "c0: HT advances to next tab stop" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    // Default tab stops every 8 columns; from col 0 : col 8
    try testing.expectEqual(@as(u16, 0), t.active().cursor.col);
    t.feed("\x09"); // HT
    try testing.expectEqual(@as(u16, 8), t.active().cursor.col);
}

test "c0: HT from mid-tab advances to next tab stop" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().cursor.col = 3;
    t.feed("\x09");

    try testing.expectEqual(@as(u16, 8), t.active().cursor.col);
}

test "c0: HT clamps at last column when no tab stop fits" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    // col 20 in a 24-col terminal, next tab stop (24) is past the edge
    t.active().cursor.col = 20;
    t.feed("\x09");

    try testing.expectEqual(@as(u16, test_option.max_cols - 1), t.active().cursor.col);
}

test "c0: LF moves cursor down one row" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("A");
    try testing.expectEqual(@as(u16, 0), t.active().cursor.row);

    t.feed("\x0A"); // LF
    try testing.expectEqual(@as(u16, 1), t.active().cursor.row);
    // Column unchanged
    try testing.expectEqual(@as(u16, 1), t.active().cursor.col);
}

test "c0: VT behaves like LF" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().cursor.row = 0;
    t.feed("\x0B");

    try testing.expectEqual(@as(u16, 1), t.active().cursor.row);
}

test "c0: FF behaves like LF" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().cursor.row = 0;
    t.feed("\x0C");

    try testing.expectEqual(@as(u16, 1), t.active().cursor.row);
}

test "c0: LF with newline mode also performs CR" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.mode.linefeed = true;
    t.feed("ABC"); // cursor at col 3
    try testing.expectEqual(@as(u16, 3), t.active().cursor.col);

    t.feed("\x0A"); // LF
    try testing.expectEqual(@as(u16, 1), t.active().cursor.row);
    try testing.expectEqual(@as(u16, 0), t.active().cursor.col); // CR performed
}

test "c0: LF without newline mode does not CR" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    // modes.newline defaults to false
    t.feed("ABC"); // cursor at col 3
    t.feed("\x0A"); // LF
    try testing.expectEqual(@as(u16, 1), t.active().cursor.row);
    try testing.expectEqual(@as(u16, 3), t.active().cursor.col); // col unchanged
}

test "c0: LF at scroll_bottom scrolls up" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    // Move cursor to last row of scroll region
    t.active().cursor.row = @intCast(t.active().scroll_bottom);
    t.feed("A"); // write a char so we can verify scroll happened
    t.active().cursor.row = @intCast(t.active().scroll_bottom);
    t.feed("\x0A");

    // Cursor stays at scroll_bottom after scroll
    try testing.expectEqual(t.active().scroll_bottom, t.active().cursor.row);
}

test "c0: CR resets cursor to column 0" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("ABC");
    try testing.expectEqual(@as(u16, 3), t.active().cursor.col);

    t.feed("\x0D"); // CR
    try testing.expectEqual(@as(u16, 0), t.active().cursor.col);
    try testing.expectEqual(@as(u16, 0), t.active().cursor.row); // row unchanged
}

test "c0: CR clears wrap_pending" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("A" ** test_option.max_cols); // fill row : wrap_pending = true
    try testing.expect(t.active().cursor.wrap_pending);

    t.feed("\x0D"); // CR
    try testing.expect(!t.active().cursor.wrap_pending);
    try testing.expectEqual(@as(u16, 0), t.active().cursor.col);
}

test "c0: CR does not change row" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().cursor.row = 5;
    t.active().cursor.col = 10;
    t.feed("\x0D");

    try testing.expectEqual(@as(u16, 5), t.active().cursor.row);
}

test "c0: CRLF moves to start of next line" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().cursor.col = 10;
    t.active().cursor.row = 0;
    t.feed("\x0D\x0A");

    try testing.expectEqual(@as(u16, 0), t.active().cursor.col);
    try testing.expectEqual(@as(u16, 1), t.active().cursor.row);
}

test "c0: SO activates G1 charset" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x0E"); // SO
    try testing.expectEqual(@as(u2, 1), t.active().cursor.charset.gl);
}

test "c0: SI restores G0 charset" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x0E"); // SO : GL = G1
    t.feed("\x0F"); // SI : GL = G0
    try testing.expectEqual(@as(u2, 0), t.active().cursor.charset.gl);
}

test "c0: CR+LF sequence (classic newline)" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("Hello");
    t.feed("\x0D\x0A"); // CR LF
    try testing.expectEqual(@as(u16, 1), t.active().cursor.row);
    try testing.expectEqual(@as(u16, 0), t.active().cursor.col);
}

test "c0: CAN is ignored" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().cursor.col = 5;
    t.feed("\x18");

    try testing.expectEqual(@as(u16, 5), t.active().cursor.col);
    try testing.expect(!t.events.any());
}

test "c0: SUB is ignored" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().cursor.col = 5;
    t.feed("\x1A");

    try testing.expectEqual(@as(u16, 5), t.active().cursor.col);
    try testing.expect(!t.events.any());
}

test "c0: DEL is ignored" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().cursor.col = 5;
    t.feed("\x7F");

    try testing.expectEqual(@as(u16, 5), t.active().cursor.col);
    try testing.expect(!t.events.any());
}

test "c0: events.clear resets bell and response" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

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
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().cursor.row = 3;
    t.active().cursor.col = 6;

    t.feed("\x1b7"); // DECSC
    try testing.expectEqual(3, t.active().saved_cursor.row);
    try testing.expectEqual(6, t.active().saved_cursor.col);
}

test "escape: ESC 8 restore cursor position" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().cursor.row = 5;
    t.active().cursor.col = 10;
    t.feed("\x1b7"); // save

    t.active().cursor.row = 0;
    t.active().cursor.col = 0;
    t.feed("\x1b8"); // restore

    try testing.expectEqual(5, t.active().cursor.row);
    try testing.expectEqual(10, t.active().cursor.col);
}

test "escape: ESC 7 saves cursor SGR attributes" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().cursor.attr.flags.bold = true;

    t.feed("\x1b7"); // DECSC
    try testing.expect(t.active().saved_cursor.attr.flags.bold);
}

test "escape: ESC 8 restore cursor SGR attributes" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().cursor.attr.flags.bold = true;
    t.feed("\x1b7"); // save

    t.active().cursor.attr = .{};
    t.feed("\x1b8"); // restore

    try testing.expect(t.active().cursor.attr.flags.bold);
}

test "escape: ESC 7/8 round-trip preserves origin mode" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().cursor.origin = true;
    t.feed("\x1b7"); // save

    t.active().cursor.origin = false;
    t.feed("\x1b8"); // restore

    try testing.expect(t.active().cursor.origin);
}

test "escape: ESC c DECSC all cells cleared" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("Hello, World!");
    t.feed("\x1bc");
    const row = t.active().row(0);
    for (row[0..13]) |cell| {
        try testing.expectEqual(0, cell.codepoint);
    }
}

test "escape: ESC c DECSC cursor reset to home" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[15;40H"); // CUP
    t.feed("\x1bc");
    try testing.expectEqual(0, t.active().cursor.row);
    try testing.expectEqual(0, t.active().cursor.col);
}

test "escape: ESC c DECSC cursor attr reset" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[1;3m"); // bold + italic
    t.feed("\x1bc");
    try testing.expectEqualDeep(Attr{}, t.active().cursor.attr);
}

test "escape: ESC c DECSC scroll margins reset" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[5;20r");
    t.feed("\x1bc");
    try testing.expectEqual(0, t.active().scroll_top);
    try testing.expectEqual(t.active().active_rows - 1, t.active().scroll_bottom);
}

test "escape: ESC c DECSC modes reset to defaults" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[?7l"); // DECAWM off
    t.feed("\x1b[4h"); // IRM on
    t.feed("\x1b[?6h"); // DECOM on
    t.feed("\x1bc");
    try testing.expect(t.active().mode.auto_wrap);
    try testing.expect(!t.active().mode.insert);
    try testing.expect(!t.active().cursor.origin);
}

test "escape: ESC c DECSC tab stops restored to defaults" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[3g"); // TBC — clear all tab stops
    t.feed("\x1bc");
    // Default tab stops are every 8 columns
    try testing.expect(t.active().tab_stops.isSet(8));
    try testing.expect(t.active().tab_stops.isSet(16));
    try testing.expect(!t.active().tab_stops.isSet(7));
}

test "escape: ESC c DECSC palette reset to ANSI defaults" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    // Intern an RGB color to occupy a dynamic slot
    const idx = t.active().palette.intern(.{ .rgb = .{ .r = 1, .g = 2, .b = 3 } });
    try testing.expect(idx >= Palette.dynamic_base);

    t.feed("\x1bc");

    // After reset, that dynamic slot should no longer hold our color
    const color_after = t.active().palette.decode(idx);
    try testing.expect(!std.meta.eql(
        color_after,
        Color{ .rgb = .{ .r = 1, .g = 2, .b = 3 } },
    ));

    // ANSI slots must be intact
    try testing.expectEqual(Color{ .indexed = 0 }, t.active().palette.decode(Palette.ansi_base));
    try testing.expectEqual(Color{ .indexed = 15 }, t.active().palette.decode(Palette.ansi_base + 15));
}

test "escape: ESC c DECSC scroll_offset reset" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    // Fill screen to trigger scrollback
    for (0..t.active().active_rows + 5) |_| {
        t.feed("line\r\n");
    }
    t.feed("\x1bc");
    try testing.expectEqual(0, t.active().scroll_offset);
}

test "escape: ESC c DECSC dirty_rows covers full screen" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    // Clear dirty state manually
    t.active().dirty_rows = .empty;
    t.feed("\x1bc");
    // All rows should be dirty after hard reset
    for (0..t.active().active_rows) |r| {
        try testing.expect(t.active().dirty_rows.isSet(r));
    }
}

test "escape: ESC c DECSC saved_cursor reset" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[10;20H");
    t.feed("\x1b7"); // DECSC
    t.feed("\x1bc");
    try testing.expectEqualDeep(SavedCursor{}, t.active().saved_cursor);
}

test "escape: ESC D moves cursor down (IND)" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().cursor.row = 2;
    t.feed("\x1bD");

    try testing.expectEqual(3, t.active().cursor.row);
}

test "escape: ESC D at scroll_bottom scrolls up" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().cursor.row = t.active().scroll_bottom;
    const row_before = t.active().cursor.row;
    t.feed("\x1bD");

    // Cursor stays at scroll_bottom; content scrolled up
    try testing.expectEqual(row_before, t.active().cursor.row);
}

test "escape: ESC E moves cursor down and resets column (NEL)" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().cursor.row = 2;
    t.active().cursor.col = 15;
    t.feed("\x1bE");

    try testing.expectEqual(3, t.active().cursor.row);
    try testing.expectEqual(0, t.active().cursor.col);
}

test "escape: ESC E clears wrap_pending" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().cursor.wrap_pending = true;
    t.feed("\x1bE");

    try testing.expect(!t.active().cursor.wrap_pending);
}

test "escape: ESC H sets tab stop at cursor column" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().cursor.col = 13;
    t.feed("\x1bH");

    try testing.expect(t.active().tab_stops.isSet(13));
}

test "escape: ESC M moves cursor up (RI)" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().cursor.row = 5;
    t.feed("\x1bM");

    try testing.expectEqual(4, t.active().cursor.row);
}

test "escape: ESC M at scroll_top scrolls down" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().cursor.row = t.active().scroll_top;
    const row_before = t.active().cursor.row;
    t.feed("\x1bM");

    // Cursor stays at scroll_top; content scrolled down
    try testing.expectEqual(row_before, t.active().cursor.row);
}

test "escape: ESC = enables keypad application mode (DECKPAM)" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b=");

    try testing.expect(t.mode.keypad_app);
}

test "escape: ESC > disables keypad application mode (DECKPNM)" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.mode.keypad_app = true;
    t.feed("\x1b>");

    try testing.expect(!t.mode.keypad_app);
}

test "escape: DECKPAM/DECKPNM toggle" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b="); // on
    try testing.expect(t.mode.keypad_app);
    t.feed("\x1b>"); // off
    try testing.expect(!t.mode.keypad_app);
}

test "escape: ESC SP G enables 8-bit C1 (S8C1T)" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b G");
    try testing.expectEqual(.s8c1t, t.control_format);
}

test "escape: ESC SP F restores 7-bit C1 (S7C1T)" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.control_format = .s8c1t; // set initial state
    t.feed("\x1b F");
    try testing.expectEqual(.s7c1t, t.control_format);
}

test "escape: ESC SP L sets s7c1t and level1 (ANSI level 1)" {
    // ANSI conformance levels (ESC SP L/M/N) are not implemented; single xterm profile.
    if (true) return error.SkipZigTest;

    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.control_format = .s8c1t; // set initial state
    t.feed("\x1b L"); // ESC SP L | DECSCL level 1

    try testing.expectEqual(.s7c1t, t.control_format);
    try testing.expectEqual(.level1, t.conformance_level); // ← also check conformance_level
}

test "escape: ESC SP M sets s8c1t and level2 (ANSI level 2)" {
    // ANSI conformance levels (ESC SP L/M/N) are not implemented; single xterm profile.
    if (true) return error.SkipZigTest;

    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b M"); // ESC SP M | DECSCL level 2

    try testing.expectEqual(.s8c1t, t.control_format);
    try testing.expectEqual(.level2, t.conformance_level); // ← also check conformance_level
}

test "escape: ESC SP N sets s8c1t and level3 (ANSI level 3)" {
    // ANSI conformance levels (ESC SP L/M/N) are not implemented; single xterm profile.
    if (true) return error.SkipZigTest;

    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b N"); // ESC SP N | DECSCL level 3

    try testing.expectEqual(.s8c1t, t.control_format);
    try testing.expectEqual(.level3, t.conformance_level); // ← also check conformance_level
}

test "escape: ESC # 8 fills screen with E (DECALN)" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b#8");

    // Every cell in the active area should be 'E'
    for (0..t.active().active_rows) |r| {
        for (0..t.active().active_cols) |c| {
            const cell = t.active().cellAt(r, c);
            try testing.expectEqual('E', cell.codepoint);
        }
    }
}

test "escape: ESC # 8 homes cursor" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().cursor.row = 5;
    t.active().cursor.col = 10;
    t.feed("\x1b#8");

    try testing.expectEqual(0, t.active().cursor.row);
    try testing.expectEqual(0, t.active().cursor.col);
}

test "escape: ESC # 8 marks all rows dirty" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().dirty_rows = .empty;
    t.feed("\x1b#8");

    try testing.expectEqual(t.active().active_rows, t.active().dirty_rows.count());
}

test "escape: ESC # 3 sets double_top on current row" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().cursor.row = 2;
    t.feed("\x1b#3");

    try testing.expectEqual(.double_top, t.active().line_attrs[t.active().physRow(2)]);
}

test "escape: ESC # 4 sets double_bottom on current row" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().cursor.row = 2;
    t.feed("\x1b#4");

    try testing.expectEqual(.double_bottom, t.active().line_attrs[t.active().physRow(2)]);
}

test "escape: ESC # 5 sets normal on current row" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().cursor.row = 2;
    t.active().setLineAttr(.double_width);
    t.feed("\x1b#5");

    try testing.expectEqual(.normal, t.active().line_attrs[t.active().physRow(2)]);
}

test "escape: ESC # 6 sets double_width on current row" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().cursor.row = 3;
    t.feed("\x1b#6");

    try testing.expectEqual(.double_width, t.active().line_attrs[t.active().physRow(3)]);
}

test "escape: ESC ( 0 designates G0 = DEC Special Graphics" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b(0");
    try testing.expectEqual(.dec_special, t.active().cursor.charset.g0);
}

test "escape: ESC ( B designates G0 = ASCII" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().cursor.charset.setSlot(0, .dec_special);
    t.feed("\x1b(B");

    try testing.expectEqual(.ascii, t.active().cursor.charset.g0);
}

test "escape: ESC ) 0 designates G1 = DEC Special Graphics" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b)0");
    try testing.expectEqual(.dec_special, t.active().cursor.charset.g1);
}

test "escape: ESC * A designates G2 = UK NRC" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b*A");
    try testing.expectEqual(.uk, t.active().cursor.charset.g2);
}

test "escape: ESC + B designates G3 = ASCII" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().cursor.charset.setSlot(0, .dec_special);
    t.feed("\x1b+B");

    try testing.expectEqual(.ascii, t.active().cursor.charset.g3);
}

test "escape: ESC - A designates G1 = iso_latin1" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b\x2d\x41"); // ESC - A
    try testing.expectEqual(.iso_latin1, t.active().cursor.charset.g1);
    // G0, G2, G3 must be untouched
    try testing.expectEqual(.ascii, t.active().cursor.charset.g0);
    try testing.expectEqual(.ascii, t.active().cursor.charset.g2);
    try testing.expectEqual(.ascii, t.active().cursor.charset.g3);
}

test "escape: ESC - B designates G1 = ascii (96-char)" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    // let's set G1 to something non-default so we can verify the change
    t.feed("\x1b\x2d\x41"); // ESC - A  : G1 = iso_latin1
    t.feed("\x1b\x2d\x42"); // ESC - B  : G1 = ascii
    try testing.expectEqual(.ascii, t.active().cursor.charset.g1);
}

test "escape: ESC - 0 designates G1 = dec_special (96-char)" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    // '0' is not a valid 96-char set final byte; falls back to .ascii
    // FIXME not implemented
    t.feed("\x1b-0");
    try testing.expectEqual(.ascii, t.active().cursor.charset.g1);
}

test "escape: ESC . A designates G2 = iso_latin1" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b\x2e\x41"); // ESC . A
    try testing.expectEqual(.iso_latin1, t.active().cursor.charset.g2);
    // G0, G1, G3 must be untouched
    try testing.expectEqual(.ascii, t.active().cursor.charset.g0);
    try testing.expectEqual(.ascii, t.active().cursor.charset.g1);
    try testing.expectEqual(.ascii, t.active().cursor.charset.g3);
}

test "escape: ESC . B designates G2 = ascii (96-char)" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b\x2e\x41"); // ESC . A  : G2 = iso_latin1
    t.feed("\x1b\x2e\x42"); // ESC . B  : G2 = ascii
    try testing.expectEqual(.ascii, t.active().cursor.charset.g2);
}

test "escape: ESC / A designates G3 = iso_latin1" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b\x2f\x41"); // ESC / A
    try testing.expectEqual(.iso_latin1, t.active().cursor.charset.g3);
    // G0, G1, G2 must be untouched
    try testing.expectEqual(.ascii, t.active().cursor.charset.g0);
    try testing.expectEqual(.ascii, t.active().cursor.charset.g1);
    try testing.expectEqual(.ascii, t.active().cursor.charset.g2);
}

test "escape: ESC / 0 designates G3 = dec_special (96-char)" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b-0"); // FIXME not implemented
    // t.feed("\x1b\x2f\x30"); // ESC / 0
    try testing.expectEqual(.ascii, t.active().cursor.charset.g3);
}

test "escape: 96-char designation does not change GL or GR" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    const gl_before = t.active().cursor.charset.gl;
    const gr_before = t.active().cursor.charset.gr;

    t.feed("\x1b\x2d\x41"); // ESC - A
    t.feed("\x1b\x2e\x41"); // ESC . A
    t.feed("\x1b\x2f\x41"); // ESC / A

    try testing.expectEqual(gl_before, t.active().cursor.charset.gl);
    try testing.expectEqual(gr_before, t.active().cursor.charset.gr);
}

test "escape: 96-char G1 designation overrides prior 94-char G1 designation" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b\x29\x30"); // ESC ) 0  : G1 = dec_special (94-char)
    try testing.expectEqual(.dec_special, t.active().cursor.charset.g1);

    t.feed("\x1b\x2d\x41"); // ESC - A  : G1 = iso_latin1 (96-char)
    try testing.expectEqual(.iso_latin1, t.active().cursor.charset.g1);
}

test "escape: 96-char G2 designation is per-screen" {
    // TODO: re-enable once CSI ? 1049 h/l alt-screen switch is implemented
    // const t = try Term.create(alloc);
    // defer t.destroy(alloc);
    //
    // t.feed("\x1b\x2e\x41"); // ESC . A, primary G2 = iso_latin1
    // t.feed("\x1b[?1049h"); // switch to alt screen
    // // alt screen G2 should be default (ascii)
    // try testing.expectEqual(.ascii, t.active().cursor.charset.g2);
    //
    // t.feed("\x1b[?1049l"); // switch back to primary
    // try testing.expectEqual(.iso_latin1, t.active().cursor.charset.g2);
}

test "csi: ANSI SC save cursor" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().cursor.row = 5;
    t.active().cursor.col = 10;

    t.feed("\x1b[s"); // save

    t.active().cursor.row = 6;
    t.active().cursor.col = 8;

    try testing.expectEqual(6, t.active().cursor.row);
    try testing.expectEqual(8, t.active().cursor.col);

    try testing.expectEqual(5, t.active().saved_cursor.row);
    try testing.expectEqual(10, t.active().saved_cursor.col);
}

test "csi: ANSI RC save cursor" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().cursor.row = 5;
    t.active().cursor.col = 10;

    t.feed("\x1b[s"); // first, save

    t.active().cursor.row = 6;
    t.active().cursor.col = 8;

    try testing.expectEqual(6, t.active().cursor.row);
    try testing.expectEqual(8, t.active().cursor.col);

    t.feed("\x1b[u"); // restore

    try testing.expectEqual(5, t.active().cursor.row);
    try testing.expectEqual(10, t.active().cursor.col);
}

test "csi: CUU cursor up by n" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().cursor.row = 5;
    t.feed("\x1b[3A");
    try testing.expectEqual(2, t.active().cursor.row);
}

test "csi: CUU default param = 1" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().cursor.row = 3;
    t.feed("\x1b[A");
    try testing.expectEqual(2, t.active().cursor.row);
}

test "csi: CUU clamps at row 0" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().cursor.row = 1;
    t.feed("\x1b[99A");
    try testing.expectEqual(0, t.active().cursor.row);
}

test "csi: CUD cursor down by n" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().cursor.row = 2;
    t.feed("\x1b[3B");
    try testing.expectEqual(5, t.active().cursor.row);
}

test "csi: CUD default param = 1" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().cursor.row = 2;
    t.feed("\x1b[B");
    try testing.expectEqual(3, t.active().cursor.row);
}

test "csi: CUD clamps at last row" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().cursor.row = @intCast(t.active().active_rows - 2);
    t.feed("\x1b[99B");
    try testing.expectEqual(t.active().active_rows - 1, t.active().cursor.row);
}

test "csi: CUF cursor right by n" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().cursor.col = 2;
    t.feed("\x1b[4C");
    try testing.expectEqual(6, t.active().cursor.col);
}

test "csi: CUF default param = 1" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().cursor.col = 2;
    t.feed("\x1b[C");
    try testing.expectEqual(3, t.active().cursor.col);
}

test "csi: CUF clamps at last column" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().cursor.col = @intCast(t.active().active_cols - 2);
    t.feed("\x1b[99C");
    try testing.expectEqual(t.active().active_cols - 1, t.active().cursor.col);
}

test "csi: CUB cursor left by n" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().cursor.col = 8;
    t.feed("\x1b[3D");
    try testing.expectEqual(5, t.active().cursor.col);
}

test "csi: CUB default param = 1" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().cursor.col = 5;
    t.feed("\x1b[D");
    try testing.expectEqual(4, t.active().cursor.col);
}

test "csi: CUB clamps at column 0" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().cursor.col = 1;
    t.feed("\x1b[99D");
    try testing.expectEqual(0, t.active().cursor.col);
}

test "csi: CNL moves cursor down and reset column" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().cursor.row = 2;
    t.active().cursor.col = 7;

    t.feed("\x1b[2E");
    try testing.expectEqual(4, t.active().cursor.row);
    try testing.expectEqual(0, t.active().cursor.col);
}

test "csi: CNL default param = 1" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().cursor.row = 3;
    t.active().cursor.col = 5;

    t.feed("\x1b[E");
    try testing.expectEqual(4, t.active().cursor.row);
    try testing.expectEqual(0, t.active().cursor.col);
}

test "csi: CPL moves cursor up and resets column" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().cursor.row = 5;
    t.active().cursor.col = 7;

    t.feed("\x1b[2F");
    try testing.expectEqual(3, t.active().cursor.row);
    try testing.expectEqual(0, t.active().cursor.col);
}

test "csi: CPL default param = 1" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().cursor.row = 4;
    t.active().cursor.col = 5;

    t.feed("\x1b[F");
    try testing.expectEqual(3, t.active().cursor.row);
    try testing.expectEqual(0, t.active().cursor.col);
}

test "csi: CHA sets column (1-based)" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().cursor.col = 0;

    t.feed("\x1b[5G"); // column 5, internal 4
    try testing.expectEqual(4, t.active().cursor.col);
}

test "csi: CHA param 1, column 0" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().cursor.col = 10;

    t.feed("\x1b[1G");
    try testing.expectEqual(0, t.active().cursor.col);
}

test "csi: CHA default param = 1, column 0" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().cursor.col = 10;

    t.feed("\x1b[G");
    try testing.expectEqual(0, t.active().cursor.col);
}

test "csi: CHA clamps at last column" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[9999G");
    try testing.expectEqual(t.active().active_cols - 1, t.active().cursor.col);
}

test "csi: CUP positions cursor (1-based row and col)" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().cursor.row = 5;
    t.active().cursor.col = 5;

    t.feed("\x1b[H");

    try testing.expectEqual(0, t.active().cursor.row);
    try testing.expectEqual(0, t.active().cursor.col);
}

test "csi: CUP param 1;1, home (0,0)" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().cursor.row = 5;
    t.active().cursor.col = 5;

    t.feed("\x1b[1;1H");

    try testing.expectEqual(0, t.active().cursor.row);
    try testing.expectEqual(0, t.active().cursor.col);
}

test "csi: CUP clamps to active area" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[999;999H");

    try testing.expectEqual(t.active().active_rows - 1, t.active().cursor.row);
    try testing.expectEqual(t.active().active_cols - 1, t.active().cursor.col);
}

test "csi: HVP positioni cursor identically to CUP" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[3;6f"); // (3,6) = (2,5) for internal

    try testing.expectEqual(2, t.active().cursor.row);
    try testing.expectEqual(5, t.active().cursor.col);
}

test "csi: VPA sets row (1-based, ignores DECOM)" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().cursor.row = 0;
    t.feed("\x1b[5d"); // row 5, internal 4

    try testing.expectEqual(4, t.active().cursor.row);
}

test "csi: VPA param 1 = row 0" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().cursor.row = 5;
    t.feed("\x1b[1d");

    try testing.expectEqual(0, t.active().cursor.row);
}

test "csi: VPA default param = 1 = row 0" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().cursor.row = 5;
    t.feed("\x1b[d");

    try testing.expectEqual(0, t.active().cursor.row);
}

test "csi: VPR moves cursor down by n (relative)" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().cursor.row = 2;
    t.feed("\x1b[3e");

    try testing.expectEqual(5, t.active().cursor.row);
}

test "csi: HPA sets column (1-based)" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().cursor.col = 0;
    t.feed("\x1b[7`"); // col 7 = internal 6
    try testing.expectEqual(6, t.active().cursor.col);
}

test "csi: HPA param 1 = col 0" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().cursor.col = 5;
    t.feed("\x1b[1`");
    try testing.expectEqual(0, t.active().cursor.col);
}

test "csi: HPR moves cursor right by n (relative)" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().cursor.col = 3;
    t.feed("\x1b[4a");
    try testing.expectEqual(7, t.active().cursor.col);
}

test "csi: cursor movement clears wrap_pending" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().cursor.wrap_pending = true;
    t.feed("\x1b[A"); // any movement
    try testing.expect(!t.active().cursor.wrap_pending);
}

test "csi: DECSTR scroll margins reset to full screen" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    // Set non-default scroll margins via DECSTBM
    t.feed("\x1b[5;20r"); // top=5, bottom=20
    t.feed("\x1b[!p");
    try testing.expectEqual(0, t.active().scroll_top);
    try testing.expectEqual(t.active().active_rows - 1, t.active().scroll_bottom);
}

test "csi: DECSTR cursor attr reset to default" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[1;3;4m"); // bold + italic + underline
    t.feed("\x1b[38;2;255;0;0m"); // fg = rgb(255,0,0)
    t.feed("\x1b[!p");
    try testing.expectEqualDeep(Attr{}, t.active().cursor.attr);
}

test "csi: DECSTR cursor attr fg/bg reset to palette default_idx" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[38;5;196m"); // fg = indexed 196
    t.feed("\x1b[48;5;22m"); // bg = indexed 22
    t.feed("\x1b[!p");
    try testing.expectEqual(Palette.default_base, t.active().cursor.attr.fg);
    try testing.expectEqual(Palette.default_base, t.active().cursor.attr.bg);
}

test "csi: DECSTR origin mode cleared" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[?6h"); // DECOM on
    t.feed("\x1b[!p");
    try testing.expect(!t.active().cursor.origin);
}

test "csi: DECSTR turns auto_wrap off (VT510 DECSTR table)" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    try testing.expect(t.active().mode.auto_wrap); // power-on default
    t.feed("\x1b[!p");
    try testing.expect(!t.active().mode.auto_wrap);
}

test "csi: DECSTR insert mode cleared" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[4h"); // IRM on
    t.feed("\x1b[!p");
    try testing.expect(!t.active().mode.insert);
}

test "csi: DECSTR wrap_pending cleared" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().cursor.wrap_pending = true;
    t.feed("\x1b[!p");
    try testing.expect(!t.active().cursor.wrap_pending);
}

test "csi: DECSTR saved_cursor reset to default" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b7"); // DECSC — save current cursor
    t.active().cursor.row = 5;
    t.active().cursor.col = 10;
    t.feed("\x1b[!p");
    try testing.expectEqualDeep(SavedCursor{}, t.active().saved_cursor);
}

test "csi: DECSTR cell content preserved" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("Hello");
    t.feed("\x1b[!p");
    // Cursor moved but cells written before reset are still there
    const row = t.active().row(0);
    try testing.expectEqual('H', row[0].codepoint);
    try testing.expectEqual('e', row[1].codepoint);
}

test "csi: DECSTR cursor position preserved" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[10;20H"); // CUP row=10, col=20
    t.feed("\x1b[!p");
    // DECSTR does NOT reset cursor position
    try testing.expectEqual(9, t.active().cursor.row); // 0-indexed
    try testing.expectEqual(19, t.active().cursor.col);
}

test "csi: DECSTR tab stops preserved" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[3g"); // TBC; clear all tab stops
    t.feed("\x1b[!p");

    // Tab stops should still be cleared (softReset does not restore them)
    try testing.expect(!t.active().tab_stops.isSet(8));
}

test "csi: ED 0 erases cursor-to-end-of-screen" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    // Fill the entire screen with 'A'.
    for (0..t.active().active_rows) |r| {
        for (t.active().rowMut(r)[0..t.active().active_cols]) |*c| {
            c.* = .{ .codepoint = 'A', .kind = .narrow };
        }
    }

    // Cursor at (2, 3) — erase from there to end of screen.
    t.active().cursor.row = 2;
    t.active().cursor.col = 3;
    t.feed("\x1b[J"); // CSI J = CSI 0 J

    // Rows before cursor row are untouched.
    for (0..2) |r| {
        for (t.active().row(r)[0..t.active().active_cols]) |c| {
            try testing.expectEqual(@as(u32, 'A'), c.codepoint);
        }
    }

    // Cursor row: cols before cursor are untouched, cursor col onward are blank.
    const row2 = t.active().row(2);
    for (0..3) |c| try testing.expectEqual(@as(u32, 'A'), row2[c].codepoint);
    for (3..t.active().active_cols) |c| try testing.expectEqual(@as(u32, 0), row2[c].codepoint);

    // Rows after cursor row are fully blank.
    for (3..t.active().active_rows) |r| {
        for (t.active().row(r)[0..t.active().active_cols]) |c| {
            try testing.expectEqual(@as(u32, 0), c.codepoint);
        }
    }

    // Cursor does not move.
    try testing.expectEqual(@as(u16, 2), t.active().cursor.row);
    try testing.expectEqual(@as(u16, 3), t.active().cursor.col);
    try testing.expect(!t.active().cursor.wrap_pending);
}

test "csi: ED 1 erases start-of-screen-to-cursor" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    for (0..t.active().active_rows) |r| {
        for (t.active().rowMut(r)[0..t.active().active_cols]) |*c| {
            c.* = .{ .codepoint = 'A', .kind = .narrow };
        }
    }

    t.active().cursor.row = 2;
    t.active().cursor.col = 3;
    t.feed("\x1b[1J");

    // Rows before cursor row are fully blank.
    for (0..2) |r| {
        for (t.active().row(r)[0..t.active().active_cols]) |c| {
            try testing.expectEqual(@as(u32, 0), c.codepoint);
        }
    }
    // Cursor row: cols up to and including cursor are blank, rest untouched.
    const row2 = t.active().row(2);
    for (0..4) |c| try testing.expectEqual(@as(u32, 0), row2[c].codepoint);
    for (4..t.active().active_cols) |c| try testing.expectEqual(@as(u32, 'A'), row2[c].codepoint);
    // Rows after cursor row are untouched.
    for (3..t.active().active_rows) |r| {
        for (t.active().row(r)[0..t.active().active_cols]) |c| {
            try testing.expectEqual(@as(u32, 'A'), c.codepoint);
        }
    }
    try testing.expectEqual(@as(u16, 2), t.active().cursor.row);
    try testing.expectEqual(@as(u16, 3), t.active().cursor.col);
}

test "csi: ED 2 erases entire screen, cursor stays" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    for (0..t.active().active_rows) |r| {
        for (t.active().rowMut(r)[0..t.active().active_cols]) |*c| {
            c.* = .{ .codepoint = 'A', .kind = .narrow };
        }
    }

    t.active().cursor.row = 3;
    t.active().cursor.col = 5;
    t.feed("\x1b[2J");

    for (0..t.active().active_rows) |r| {
        for (t.active().row(r)[0..t.active().active_cols]) |c| {
            try testing.expectEqual(@as(u32, 0), c.codepoint);
        }
    }
    // Cursor does NOT move on ED 2.
    try testing.expectEqual(@as(u16, 3), t.active().cursor.row);
    try testing.expectEqual(@as(u16, 5), t.active().cursor.col);
}

test "csi: ED uses current background color for blank cells" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    // Set a non-default background color.
    t.feed("\x1b[41m"); // SGR 41 = red background (indexed 1)
    const bg = t.active().cursor.attr.bg; // palette index for red

    t.active().cursor.row = 0;
    t.active().cursor.col = 0;
    t.feed("\x1b[2J"); // erase entire screen

    // All cells should have the current background color.
    for (t.active().row(0)[0..t.active().active_cols]) |c| {
        try testing.expectEqual(bg, c.background);
        try testing.expectEqual(@as(u32, 0), c.codepoint);
    }
}

test "csi: ED 0 clears wrap_pending" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().cursor.wrap_pending = true;
    t.feed("\x1b[J");
    try testing.expect(!t.active().cursor.wrap_pending);
}

test "csi: EL 0 erases cursor-to-end-of-line" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    for (t.active().rowMut(1)[0..t.active().active_cols]) |*c| {
        c.* = .{ .codepoint = 'B', .kind = .narrow };
    }

    t.active().cursor.row = 1;
    t.active().cursor.col = 4;
    t.feed("\x1b[K"); // CSI K = CSI 0 K

    const row = t.active().row(1);
    // Cols before cursor are untouched.
    for (0..4) |c| try testing.expectEqual(@as(u32, 'B'), row[c].codepoint);
    // Cursor col onward are blank.
    for (4..t.active().active_cols) |c| try testing.expectEqual(@as(u32, 0), row[c].codepoint);
    // Cursor does not move.
    try testing.expectEqual(@as(u16, 1), t.active().cursor.row);
    try testing.expectEqual(@as(u16, 4), t.active().cursor.col);
}

test "csi: EL 1 erases start-of-line-to-cursor" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    for (t.active().rowMut(0)[0..t.active().active_cols]) |*c| {
        c.* = .{ .codepoint = 'B', .kind = .narrow };
    }

    t.active().cursor.row = 0;
    t.active().cursor.col = 5;
    t.feed("\x1b[1K");

    const row = t.active().row(0);
    // Cols 0..=5 (inclusive) are blank.
    for (0..6) |c| try testing.expectEqual(@as(u32, 0), row[c].codepoint);
    // Cols after cursor are untouched.
    for (6..t.active().active_cols) |c| try testing.expectEqual(@as(u32, 'B'), row[c].codepoint);
}

test "csi: EL 2 erases entire line" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    for (t.active().rowMut(2)[0..t.active().active_cols]) |*c| {
        c.* = .{ .codepoint = 'C', .kind = .narrow };
    }

    t.active().cursor.row = 2;
    t.active().cursor.col = 7;
    t.feed("\x1b[2K");

    for (t.active().row(2)[0..t.active().active_cols]) |c| {
        try testing.expectEqual(@as(u32, 0), c.codepoint);
    }
    // Cursor does not move.
    try testing.expectEqual(@as(u16, 2), t.active().cursor.row);
    try testing.expectEqual(@as(u16, 7), t.active().cursor.col);
}

test "csi: EL uses current background color for blank cells" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[42m"); // SGR 42 = green background
    const bg = t.active().cursor.attr.bg;

    t.active().cursor.row = 0;
    t.active().cursor.col = 0;
    t.feed("\x1b[2K");

    for (t.active().row(0)[0..t.active().active_cols]) |c| {
        try testing.expectEqual(bg, c.background);
    }
}

test "csi: EL does not affect other rows" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    for (0..t.active().active_rows) |r| {
        for (t.active().rowMut(r)[0..t.active().active_cols]) |*c| {
            c.* = .{ .codepoint = 'D', .kind = .narrow };
        }
    }

    t.active().cursor.row = 1;
    t.active().cursor.col = 0;
    t.feed("\x1b[2K"); // erase entire line 1

    // Row 1 is blank.
    for (t.active().row(1)[0..t.active().active_cols]) |c| {
        try testing.expectEqual(@as(u32, 0), c.codepoint);
    }
    // Row 0 and row 2 are untouched.
    for (t.active().row(0)[0..t.active().active_cols]) |c| {
        try testing.expectEqual(@as(u32, 'D'), c.codepoint);
    }
    for (t.active().row(2)[0..t.active().active_cols]) |c| {
        try testing.expectEqual(@as(u32, 'D'), c.codepoint);
    }
}

test "csi: EL 0 clears wrap_pending" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().cursor.wrap_pending = true;
    t.feed("\x1b[K");
    try testing.expect(!t.active().cursor.wrap_pending);
}

test "csi: ECH erases n chars at cursor, cursor does not move" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    for (t.active().rowMut(0)[0..t.active().active_cols]) |*c| {
        c.* = .{ .codepoint = 'E', .kind = .narrow };
    }

    t.active().cursor.row = 0;
    t.active().cursor.col = 3;
    t.feed("\x1b[4X"); // erase 4 chars starting at col 3

    const row = t.active().row(0);
    // Cols before cursor are untouched.
    for (0..3) |c| try testing.expectEqual(@as(u32, 'E'), row[c].codepoint);
    // Cols 3..6 are blank.
    for (3..7) |c| try testing.expectEqual(@as(u32, 0), row[c].codepoint);
    // Cols after erased region are untouched.
    for (7..t.active().active_cols) |c| try testing.expectEqual(@as(u32, 'E'), row[c].codepoint);
    // Cursor does not move.
    try testing.expectEqual(@as(u16, 0), t.active().cursor.row);
    try testing.expectEqual(@as(u16, 3), t.active().cursor.col);
}

test "csi: ECH 0 erases 1 char (default parameter rule)" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    for (t.active().rowMut(0)[0..t.active().active_cols]) |*c| {
        c.* = .{ .codepoint = 'F', .kind = .narrow };
    }

    t.active().cursor.row = 0;
    t.active().cursor.col = 2;
    t.feed("\x1b[X"); // CSI X = CSI 0 X, default = 1

    const row = t.active().row(0);
    for (0..2) |c| try testing.expectEqual(@as(u32, 'F'), row[c].codepoint);
    try testing.expectEqual(@as(u32, 0), row[2].codepoint); // erased
    for (3..t.active().active_cols) |c| try testing.expectEqual(@as(u32, 'F'), row[c].codepoint);
}

test "csi: ECH clamps to end of line" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    for (t.active().rowMut(0)[0..t.active().active_cols]) |*c| {
        c.* = .{ .codepoint = 'G', .kind = .narrow };
    }

    t.active().cursor.row = 0;
    t.active().cursor.col = @intCast(t.active().active_cols - 2);
    t.feed("\x1b[9999X"); // huge n — should clamp to end of line

    const row = t.active().row(0);
    const col: usize = t.active().active_cols - 2;
    for (0..col) |c| try testing.expectEqual(@as(u32, 'G'), row[c].codepoint);
    try testing.expectEqual(@as(u32, 0), row[col].codepoint);
    try testing.expectEqual(@as(u32, 0), row[col + 1].codepoint);
}

test "csi: ECH uses current background color" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[43m"); // SGR 43 = yellow background
    const bg = t.active().cursor.attr.bg;

    t.active().cursor.row = 0;
    t.active().cursor.col = 0;
    t.feed("\x1b[3X"); // erase 3 chars

    for (t.active().row(0)[0..3]) |c| {
        try testing.expectEqual(bg, c.background);
        try testing.expectEqual(@as(u32, 0), c.codepoint);
    }
}

test "csi: ECH does not shift remaining chars (unlike DCH)" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    // Write 'A','B','C','D','E' at cols 0-4.
    const row = t.active().rowMut(0);
    row[0] = .{ .codepoint = 'A', .kind = .narrow };
    row[1] = .{ .codepoint = 'B', .kind = .narrow };
    row[2] = .{ .codepoint = 'C', .kind = .narrow };
    row[3] = .{ .codepoint = 'D', .kind = .narrow };
    row[4] = .{ .codepoint = 'E', .kind = .narrow };

    t.active().cursor.row = 0;
    t.active().cursor.col = 1;
    t.feed("\x1b[2X"); // erase cols 1 and 2

    const r = t.active().row(0);
    try testing.expectEqual(@as(u32, 'A'), r[0].codepoint); // untouched
    try testing.expectEqual(@as(u32, 0), r[1].codepoint); // erased
    try testing.expectEqual(@as(u32, 0), r[2].codepoint); // erased
    try testing.expectEqual(@as(u32, 'D'), r[3].codepoint); // NOT shifted — stays in place
    try testing.expectEqual(@as(u32, 'E'), r[4].codepoint); // NOT shifted
}

test "csi: ICH inserts blank cells and shifts right" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    // row 0: A B C D E at cols 0-4
    {
        const row = t.active().rowMut(0);
        row[0] = .{ .codepoint = 'A', .kind = .narrow };
        row[1] = .{ .codepoint = 'B', .kind = .narrow };
        row[2] = .{ .codepoint = 'C', .kind = .narrow };
        row[3] = .{ .codepoint = 'D', .kind = .narrow };
        row[4] = .{ .codepoint = 'E', .kind = .narrow };
    }

    t.active().cursor.row = 0;
    t.active().cursor.col = 1;
    t.feed("\x1b[2@"); // ICH 2

    const r = t.active().row(0);
    try testing.expectEqual(@as(u32, 'A'), r[0].codepoint); // unchanged
    try testing.expectEqual(@as(u32, 0), r[1].codepoint); // blank
    try testing.expectEqual(@as(u32, 0), r[2].codepoint); // blank
    try testing.expectEqual(@as(u32, 'B'), r[3].codepoint); // shifted
    try testing.expectEqual(@as(u32, 'C'), r[4].codepoint); // shifted
    // D and E fell off the right edge
}

test "csi: ICH cursor does not move" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().cursor.row = 0;
    t.active().cursor.col = 3;
    t.feed("\x1b[2@");
    try testing.expectEqual(@as(u16, 3), t.active().cursor.col);
    try testing.expectEqual(@as(u16, 0), t.active().cursor.row);
}

test "csi: ICH n=0 treated as n=1" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    {
        const row = t.active().rowMut(0);
        row[0] = .{ .codepoint = 'A', .kind = .narrow };
        row[1] = .{ .codepoint = 'B', .kind = .narrow };
    }

    t.active().cursor.col = 0;
    t.feed("\x1b[0@"); // ICH 0 : treated as 1

    const r = t.active().row(0);
    try testing.expectEqual(@as(u32, 0), r[0].codepoint); // blank inserted
    try testing.expectEqual(@as(u32, 'A'), r[1].codepoint); // shifted
    try testing.expectEqual(@as(u32, 'B'), r[2].codepoint); // shifted
}

test "csi: ICH clears wrap_pending" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().cursor.wrap_pending = true;
    t.feed("\x1b[@");
    try testing.expect(!t.active().cursor.wrap_pending);
}

test "csi: ICH blank cells use current background color" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[41m"); // SGR 41 = bg indexed 1
    const bg_idx = t.active().cursor.attr.bg;

    t.active().cursor.col = 0;
    t.feed("\x1b[2@"); // ICH 2

    const r = t.active().row(0);
    try testing.expectEqual(@as(u32, 0), r[0].codepoint);
    try testing.expectEqual(@as(u32, 0), r[1].codepoint);
    try testing.expectEqual(bg_idx, r[0].background);
    try testing.expectEqual(bg_idx, r[1].background);
}

test "csi: ICH at last column replaces cell with blank" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    const last = t.active().active_cols - 1;
    t.active().rowMut(0)[last] = .{ .codepoint = 'Z', .kind = .narrow };

    t.active().cursor.col = @intCast(last);
    t.feed("\x1b[@"); // ICH 1 — no room to shift, just blanks the cell

    try testing.expectEqual(@as(u32, 0), t.active().row(0)[last].codepoint);
}

test "csi: DCH deletes cells and shifts left" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    {
        const row = t.active().rowMut(0);
        row[0] = .{ .codepoint = 'A', .kind = .narrow };
        row[1] = .{ .codepoint = 'B', .kind = .narrow };
        row[2] = .{ .codepoint = 'C', .kind = .narrow };
        row[3] = .{ .codepoint = 'D', .kind = .narrow };
        row[4] = .{ .codepoint = 'E', .kind = .narrow };
    }

    t.active().cursor.row = 0;
    t.active().cursor.col = 1;
    t.feed("\x1b[2P"); // DCH 2

    const r = t.active().row(0);
    try testing.expectEqual(@as(u32, 'A'), r[0].codepoint); // unchanged
    try testing.expectEqual(@as(u32, 'D'), r[1].codepoint); // shifted left
    try testing.expectEqual(@as(u32, 'E'), r[2].codepoint); // shifted left
    try testing.expectEqual(@as(u32, 0), r[3].codepoint); // blank (vacated)
    try testing.expectEqual(@as(u32, 0), r[4].codepoint); // blank (vacated)
}

test "csi: DCH cursor does not move" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().cursor.row = 0;
    t.active().cursor.col = 3;
    t.feed("\x1b[2P");
    try testing.expectEqual(@as(u16, 3), t.active().cursor.col);
    try testing.expectEqual(@as(u16, 0), t.active().cursor.row);
}

test "csi: DCH n=0 treated as n=1" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    {
        const row = t.active().rowMut(0);
        row[0] = .{ .codepoint = 'A', .kind = .narrow };
        row[1] = .{ .codepoint = 'B', .kind = .narrow };
        row[2] = .{ .codepoint = 'C', .kind = .narrow };
    }

    t.active().cursor.col = 0;
    t.feed("\x1b[0P"); // DCH 0 : treated as 1

    const r = t.active().row(0);
    try testing.expectEqual(@as(u32, 'B'), r[0].codepoint); // shifted
    try testing.expectEqual(@as(u32, 'C'), r[1].codepoint); // shifted
    try testing.expectEqual(@as(u32, 0), r[2].codepoint); // blank
}

test "csi: DCH clears wrap_pending" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().cursor.wrap_pending = true;
    t.feed("\x1b[P");
    try testing.expect(!t.active().cursor.wrap_pending);
}

test "csi: DCH vacated cells use current background color" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[41m"); // SGR 41 = bg indexed 1
    const bg_idx = t.active().cursor.attr.bg;

    {
        const row = t.active().rowMut(0);
        row[0] = .{ .codepoint = 'A', .kind = .narrow };
        row[1] = .{ .codepoint = 'B', .kind = .narrow };
        row[2] = .{ .codepoint = 'C', .kind = .narrow };
    }

    t.active().cursor.col = 0;
    t.feed("\x1b[2P"); // DCH 2 — vacates last 2 cols

    const cols = t.active().active_cols;
    const r = t.active().row(0);
    try testing.expectEqual(@as(u32, 0), r[cols - 2].codepoint);
    try testing.expectEqual(@as(u32, 0), r[cols - 1].codepoint);
    try testing.expectEqual(bg_idx, r[cols - 2].background);
    try testing.expectEqual(bg_idx, r[cols - 1].background);
}

test "csi: IL inserts blank line and shifts rows down" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    for (0..4) |r| {
        t.active().rowMut(r)[0] = .{ .codepoint = @intCast('0' + r), .kind = .narrow };
    }

    t.active().cursor.row = 1;
    t.active().cursor.col = 5;
    t.feed("\x1b[L"); // IL 1

    try testing.expectEqual(@as(u32, '0'), t.active().row(0)[0].codepoint); // above: unchanged
    try testing.expectEqual(@as(u32, 0), t.active().row(1)[0].codepoint); // blank (inserted)
    try testing.expectEqual(@as(u32, '1'), t.active().row(2)[0].codepoint); // old row 1
    try testing.expectEqual(@as(u32, '2'), t.active().row(3)[0].codepoint); // old row 2
    // old row 3 ('3') fell off scroll_bottom
}

test "csi: IL cursor moves to column 0" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().cursor.row = 2;
    t.active().cursor.col = 7;
    t.feed("\x1b[L");
    try testing.expectEqual(@as(u16, 0), t.active().cursor.col);
    try testing.expectEqual(@as(u16, 2), t.active().cursor.row); // row unchanged
}

test "csi: IL n=0 treated as n=1" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().rowMut(0)[0] = .{ .codepoint = 'A', .kind = .narrow };
    t.active().rowMut(1)[0] = .{ .codepoint = 'B', .kind = .narrow };

    t.active().cursor.row = 0;
    t.feed("\x1b[0L"); // IL 0 : treated as 1

    try testing.expectEqual(@as(u32, 0), t.active().row(0)[0].codepoint); // blank
    try testing.expectEqual(@as(u32, 'A'), t.active().row(1)[0].codepoint); // shifted
    try testing.expectEqual(@as(u32, 'B'), t.active().row(2)[0].codepoint); // shifted
}

test "csi: IL respects scroll region, rows outside region unchanged" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    // Scroll region: rows 1-3 (0-based)
    t.active().scroll_top = 1;
    t.active().scroll_bottom = 3;

    for (0..5) |r| {
        t.active().rowMut(r)[0] = .{ .codepoint = @intCast('0' + r), .kind = .narrow };
    }

    t.active().cursor.row = 1;
    t.feed("\x1b[L"); // IL 1

    try testing.expectEqual(@as(u32, '0'), t.active().row(0)[0].codepoint); // above: unchanged
    try testing.expectEqual(@as(u32, 0), t.active().row(1)[0].codepoint); // blank (inserted)
    try testing.expectEqual(@as(u32, '1'), t.active().row(2)[0].codepoint); // old row 1
    try testing.expectEqual(@as(u32, '2'), t.active().row(3)[0].codepoint); // old row 2 (old row 3 discarded)
    try testing.expectEqual(@as(u32, '4'), t.active().row(4)[0].codepoint); // below: unchanged
}

test "csi: IL outside scroll region is no-op" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().scroll_top = 2;
    t.active().scroll_bottom = 4;

    // Fill all rows with distinct codepoints.
    for (0..5) |r| {
        t.active().rowMut(r)[0].codepoint = @intCast('0' + r);
    }

    // Place cursor ABOVE the scroll region (row 0) and insert.
    t.active().cursor.row = 0;
    t.feed("\x1b[L"); // IL 1 — cursor is outside scroll region

    // Nothing should have changed.
    for (0..5) |r| {
        try testing.expectEqual(
            @as(u32, @intCast('0' + r)),
            t.active().row(r)[0].codepoint,
        );
    }

    // Place cursor BELOW the scroll region (row 5 if screen is tall enough) and insert.
    t.active().cursor.row = 5;
    t.feed("\x1b[L");

    for (0..5) |r| {
        try testing.expectEqual(
            @as(u32, @intCast('0' + r)),
            t.active().row(r)[0].codepoint,
        );
    }
}

test "csi: DL 1 delete one line at cursor" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    // Fill rows 0-4 with 'A'-'E'.
    for (0..5) |r| {
        t.active().rowMut(r)[0] = .{ .codepoint = @intCast('A' + r), .kind = .narrow };
    }

    // Cursor at row 1; delete 1 line.
    t.active().cursor.row = 1;
    t.feed("\x1b[M"); // DL 1

    // Row 0 is above cursor — untouched.
    try testing.expectEqual(@as(u32, 'A'), t.active().row(0)[0].codepoint);
    // Rows 1-3 shifted up from old rows 2-4.
    try testing.expectEqual(@as(u32, 'C'), t.active().row(1)[0].codepoint);
    try testing.expectEqual(@as(u32, 'D'), t.active().row(2)[0].codepoint);
    try testing.expectEqual(@as(u32, 'E'), t.active().row(3)[0].codepoint);
    // Row 4 (bottom of region) is now blank.
    try testing.expectEqual(@as(u32, 0), t.active().row(4)[0].codepoint);
}

test "csi: DL 2 delete two lines" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    for (0..5) |r| {
        t.active().rowMut(r)[0] = .{ .codepoint = @intCast('0' + r), .kind = .narrow };
    }

    t.active().cursor.row = 1;
    t.feed("\x1b[2M"); // DL 2

    try testing.expectEqual(@as(u32, '0'), t.active().row(0)[0].codepoint); // above: unchanged
    try testing.expectEqual(@as(u32, '3'), t.active().row(1)[0].codepoint); // old row 3
    try testing.expectEqual(@as(u32, '4'), t.active().row(2)[0].codepoint); // old row 4
    try testing.expectEqual(@as(u32, 0), t.active().row(3)[0].codepoint); // blank
    try testing.expectEqual(@as(u32, 0), t.active().row(4)[0].codepoint); // blank
}

test "csi: DL n=0 treated as n=1" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    for (0..5) |r| {
        t.active().rowMut(r)[0] = .{ .codepoint = @intCast('A' + r), .kind = .narrow };
    }

    t.active().cursor.row = 0;
    t.feed("\x1b[0M"); // DL 0 → treated as DL 1

    try testing.expectEqual(@as(u32, 'B'), t.active().row(0)[0].codepoint); // old row 1 shifted up
    try testing.expectEqual(@as(u32, 0), t.active().row(4)[0].codepoint); // blank at bottom
}

test "csi: DL clamps when n > region height" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    for (0..5) |r| {
        t.active().rowMut(r)[0] = .{ .codepoint = @intCast('A' + r), .kind = .narrow };
    }

    t.active().cursor.row = 1;
    t.feed("\x1b[99M"); // DL 99 — clamps to region height (4 rows: 1-4)

    try testing.expectEqual(@as(u32, 'A'), t.active().row(0)[0].codepoint); // above: unchanged
    // Rows 1-4 all blank.
    for (1..5) |r| {
        try testing.expectEqual(@as(u32, 0), t.active().row(r)[0].codepoint);
    }
}

test "csi: DL with scroll region" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().scroll_top = 1;
    t.active().scroll_bottom = 3;

    for (0..5) |r| {
        t.active().rowMut(r)[0] = .{ .codepoint = @intCast('0' + r), .kind = .narrow };
    }

    t.active().cursor.row = 1;
    t.feed("\x1b[M"); // DL 1

    try testing.expectEqual(@as(u32, '0'), t.active().row(0)[0].codepoint); // above region: unchanged
    try testing.expectEqual(@as(u32, '2'), t.active().row(1)[0].codepoint); // old row 2 shifted up
    try testing.expectEqual(@as(u32, '3'), t.active().row(2)[0].codepoint); // old row 3 shifted up
    try testing.expectEqual(@as(u32, 0), t.active().row(3)[0].codepoint); // blank (bottom of region)
    try testing.expectEqual(@as(u32, '4'), t.active().row(4)[0].codepoint); // below region: unchanged
}

test "csi: DL outside scroll region is no-op" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().scroll_top = 2;
    t.active().scroll_bottom = 4;

    for (0..5) |r| {
        t.active().rowMut(r)[0] = .{ .codepoint = @intCast('0' + r), .kind = .narrow };
    }

    // Cursor above scroll region.
    t.active().cursor.row = 1;
    t.feed("\x1b[M"); // DL 1 — no-op

    for (0..5) |r| {
        try testing.expectEqual(
            @as(u32, @intCast('0' + r)),
            t.active().row(r)[0].codepoint,
        );
    }
}

test "csi: DL blank lines use current background color" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[41m"); // SGR 41 = bg indexed 1
    const bg_idx = t.active().cursor.attr.bg;

    t.active().scroll_top = 0;
    t.active().scroll_bottom = 4;

    for (0..5) |r| {
        t.active().rowMut(r)[0] = .{ .codepoint = @intCast('A' + r), .kind = .narrow };
    }

    t.active().cursor.row = 0;
    t.feed("\x1b[M"); // DL 1

    // New blank line at bottom of region carries current bg.
    try testing.expectEqual(bg_idx, t.active().row(4)[0].background);
    try testing.expectEqual(@as(u32, 0), t.active().row(4)[0].codepoint);
}

test "csi: DL cursor row preserved, col reset to 0" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().cursor.row = 2;
    t.active().cursor.col = 5;
    t.feed("\x1b[M"); // DL 1

    // Row is preserved; col is reset to 0 (xterm behavior).
    try testing.expectEqual(@as(u16, 2), t.active().cursor.row);
    try testing.expectEqual(@as(u16, 0), t.active().cursor.col);
}

test "csi: DL clears wrap_pending" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().cursor.row = 1;
    t.active().cursor.wrap_pending = true;
    t.feed("\x1b[M"); // DL 1

    try testing.expect(!t.active().cursor.wrap_pending);
}

test "csi: DL at bottom of scroll region deletes last line only" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().scroll_top = 1;
    t.active().scroll_bottom = 3;

    for (0..5) |r| {
        t.active().rowMut(r)[0] = .{ .codepoint = @intCast('0' + r), .kind = .narrow };
    }

    // Cursor at scroll_bottom.
    t.active().cursor.row = 3;
    t.feed("\x1b[M"); // DL 1

    try testing.expectEqual(@as(u32, '0'), t.active().row(0)[0].codepoint);
    try testing.expectEqual(@as(u32, '1'), t.active().row(1)[0].codepoint);
    try testing.expectEqual(@as(u32, '2'), t.active().row(2)[0].codepoint);
    try testing.expectEqual(@as(u32, 0), t.active().row(3)[0].codepoint); // deleted
    try testing.expectEqual(@as(u32, '4'), t.active().row(4)[0].codepoint); // below: unchanged
}

test "csi: SU 1 scrolls content up, blank line at bottom" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    // Fill rows 0-4 with 'A'-'E'.
    for (0..5) |r| {
        t.active().rowMut(r)[0] = .{ .codepoint = @intCast('A' + r), .kind = .narrow };
    }

    t.feed("\x1b[S"); // SU 1 (default)

    try testing.expectEqual(@as(u32, 'B'), t.active().row(0)[0].codepoint);
    try testing.expectEqual(@as(u32, 'C'), t.active().row(1)[0].codepoint);
    try testing.expectEqual(@as(u32, 'D'), t.active().row(2)[0].codepoint);
    try testing.expectEqual(@as(u32, 'E'), t.active().row(3)[0].codepoint);
    try testing.expectEqual(@as(u32, 0), t.active().row(4)[0].codepoint); // blank
}

test "csi: SU n=0 treated as n=1" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    for (0..5) |r| {
        t.active().rowMut(r)[0] = .{ .codepoint = @intCast('A' + r), .kind = .narrow };
    }

    t.feed("\x1b[0S"); // SU 0 : treated as SU 1

    try testing.expectEqual(@as(u32, 'B'), t.active().row(0)[0].codepoint);
    try testing.expectEqual(@as(u32, 0), t.active().row(4)[0].codepoint);
}

test "csi: SU 2 scrolls up by 2" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    for (0..5) |r| {
        t.active().rowMut(r)[0] = .{ .codepoint = @intCast('A' + r), .kind = .narrow };
    }

    t.feed("\x1b[2S"); // SU 2

    try testing.expectEqual(@as(u32, 'C'), t.active().row(0)[0].codepoint);
    try testing.expectEqual(@as(u32, 'D'), t.active().row(1)[0].codepoint);
    try testing.expectEqual(@as(u32, 'E'), t.active().row(2)[0].codepoint);
    try testing.expectEqual(@as(u32, 0), t.active().row(3)[0].codepoint);
    try testing.expectEqual(@as(u32, 0), t.active().row(4)[0].codepoint);
}

test "csi: SU n >= region height clears entire scroll region" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    for (0..5) |r| {
        t.active().rowMut(r)[0] = .{ .codepoint = @intCast('A' + r), .kind = .narrow };
    }

    t.feed("\x1b[99S"); // SU 99 — larger than screen

    for (0..5) |r| {
        try testing.expectEqual(@as(u32, 0), t.active().row(r)[0].codepoint);
    }
}

test "csi: SU respects scroll region" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    // scroll region: rows 1-3
    t.active().scroll_top = 1;
    t.active().scroll_bottom = 3;

    for (0..5) |r| {
        t.active().rowMut(r)[0] = .{ .codepoint = @intCast('0' + r), .kind = .narrow };
    }

    t.feed("\x1b[S"); // SU 1

    try testing.expectEqual(@as(u32, '0'), t.active().row(0)[0].codepoint); // above: unchanged
    try testing.expectEqual(@as(u32, '2'), t.active().row(1)[0].codepoint); // shifted up
    try testing.expectEqual(@as(u32, '3'), t.active().row(2)[0].codepoint); // shifted up
    try testing.expectEqual(@as(u32, 0), t.active().row(3)[0].codepoint); // blank (new)
    try testing.expectEqual(@as(u32, '4'), t.active().row(4)[0].codepoint); // below: unchanged
}

test "csi: SU blank lines use current background color" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[41m"); // SGR 41 = bg indexed 1
    const bg_idx = t.active().cursor.attr.bg;

    // Constrain scroll region to rows 0-4
    t.active().scroll_top = 0;
    t.active().scroll_bottom = 4;

    for (0..5) |r| {
        t.active().rowMut(r)[0] = .{ .codepoint = @intCast('A' + r), .kind = .narrow };
    }

    t.feed("\x1b[S"); // SU 1

    // New blank line at bottom of scroll region (row 4) carries current bg.
    try testing.expectEqual(bg_idx, t.active().row(4)[0].background);
    try testing.expectEqual(@as(u32, 0), t.active().row(4)[0].codepoint);
}

test "csi: SU does not move cursor" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().cursor.row = 2;
    t.active().cursor.col = 5;

    t.feed("\x1b[S");

    try testing.expectEqual(@as(u16, 2), t.active().cursor.row);
    try testing.expectEqual(@as(u16, 5), t.active().cursor.col);
}

test "csi: SD 1 scrolls content down, blank line at top" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    for (0..5) |r| {
        t.active().rowMut(r)[0] = .{ .codepoint = @intCast('A' + r), .kind = .narrow };
    }

    t.feed("\x1b[T"); // SD 1 (default)

    try testing.expectEqual(@as(u32, 0), t.active().row(0)[0].codepoint); // blank (new)
    try testing.expectEqual(@as(u32, 'A'), t.active().row(1)[0].codepoint);
    try testing.expectEqual(@as(u32, 'B'), t.active().row(2)[0].codepoint);
    try testing.expectEqual(@as(u32, 'C'), t.active().row(3)[0].codepoint);
    try testing.expectEqual(@as(u32, 'D'), t.active().row(4)[0].codepoint); // 'E' scrolled off
}

test "csi: SD n=0 treated as n=1" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    for (0..5) |r| {
        t.active().rowMut(r)[0] = .{ .codepoint = @intCast('A' + r), .kind = .narrow };
    }

    t.feed("\x1b[0T"); // SD 0 : treated as SD 1

    try testing.expectEqual(@as(u32, 0), t.active().row(0)[0].codepoint);
    try testing.expectEqual(@as(u32, 'A'), t.active().row(1)[0].codepoint);
}

test "csi: SD 2 scrolls down by 2" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    for (0..5) |r| {
        t.active().rowMut(r)[0] = .{ .codepoint = @intCast('A' + r), .kind = .narrow };
    }

    t.feed("\x1b[2T"); // SD 2

    try testing.expectEqual(@as(u32, 0), t.active().row(0)[0].codepoint);
    try testing.expectEqual(@as(u32, 0), t.active().row(1)[0].codepoint);
    try testing.expectEqual(@as(u32, 'A'), t.active().row(2)[0].codepoint);
    try testing.expectEqual(@as(u32, 'B'), t.active().row(3)[0].codepoint);
    try testing.expectEqual(@as(u32, 'C'), t.active().row(4)[0].codepoint);
}

test "csi: SD n >= region height clears entire scroll region" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    for (0..5) |r| {
        t.active().rowMut(r)[0] = .{ .codepoint = @intCast('A' + r), .kind = .narrow };
    }

    t.feed("\x1b[99T"); // SD 99 — larger than screen

    for (0..5) |r| {
        try testing.expectEqual(@as(u32, 0), t.active().row(r)[0].codepoint);
    }
}

test "csi: SD respects scroll region" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    // scroll region: rows 1-3
    t.active().scroll_top = 1;
    t.active().scroll_bottom = 3;

    for (0..5) |r| {
        t.active().rowMut(r)[0] = .{ .codepoint = @intCast('0' + r), .kind = .narrow };
    }

    t.feed("\x1b[T"); // SD 1

    try testing.expectEqual(@as(u32, '0'), t.active().row(0)[0].codepoint); // above: unchanged
    try testing.expectEqual(@as(u32, 0), t.active().row(1)[0].codepoint); // blank (new)
    try testing.expectEqual(@as(u32, '1'), t.active().row(2)[0].codepoint); // shifted down
    try testing.expectEqual(@as(u32, '2'), t.active().row(3)[0].codepoint); // shifted down ('3' scrolled off)
    try testing.expectEqual(@as(u32, '4'), t.active().row(4)[0].codepoint); // below: unchanged
}

test "csi: SD blank lines use current background color" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[42m"); // SGR 42 = bg indexed 2 (green)
    const bg_idx = t.active().cursor.attr.bg;

    for (0..5) |r| {
        t.active().rowMut(r)[0] = .{ .codepoint = @intCast('A' + r), .kind = .narrow };
    }

    t.feed("\x1b[T"); // SD 1

    // New blank line at top should carry the current background.
    try testing.expectEqual(bg_idx, t.active().row(0)[0].background);
    try testing.expectEqual(@as(u32, 0), t.active().row(0)[0].codepoint);
}

test "csi: SD does not move cursor" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().cursor.row = 2;
    t.active().cursor.col = 5;

    t.feed("\x1b[T");

    try testing.expectEqual(@as(u16, 2), t.active().cursor.row);
    try testing.expectEqual(@as(u16, 5), t.active().cursor.col);
}

test "csi: SU then SD round-trips content" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    for (0..5) |r| {
        t.active().rowMut(r)[0] = .{ .codepoint = @intCast('A' + r), .kind = .narrow };
    }

    t.feed("\x1b[2S"); // SU 2  'A','B' lost; 'C','D','E' at rows 0-2; rows 3-4 blank
    t.feed("\x1b[2T"); // SD 2  rows 3-4 blank shift down; 'C','D','E' at rows 2-4

    // 'A' and 'B' are gone, they scrolled off during SU.
    try testing.expectEqual(@as(u32, 0), t.active().row(0)[0].codepoint);
    try testing.expectEqual(@as(u32, 0), t.active().row(1)[0].codepoint);
    try testing.expectEqual(@as(u32, 'C'), t.active().row(2)[0].codepoint);
    try testing.expectEqual(@as(u32, 'D'), t.active().row(3)[0].codepoint);
    try testing.expectEqual(@as(u32, 'E'), t.active().row(4)[0].codepoint);
}

test "csi: DECSTBM sets scroll region" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[3;7r"); // top=3, bottom=7 (1-based) : 2, 6 (0-based)

    try testing.expectEqual(@as(u16, 2), t.active().scroll_top);
    try testing.expectEqual(@as(u16, 6), t.active().scroll_bottom);
}

test "csi: DECSTBM moves cursor to home" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().cursor.row = 3;
    t.active().cursor.col = 5;

    t.feed("\x1b[2;8r");

    try testing.expectEqual(@as(u16, 0), t.active().cursor.row);
    try testing.expectEqual(@as(u16, 0), t.active().cursor.col);
}

test "csi: DECSTBM clears wrap_pending" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().cursor.wrap_pending = true;

    t.feed("\x1b[2;8r");

    try testing.expect(!t.active().cursor.wrap_pending);
}

test "csi: DECSTBM no params resets to full screen" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    // First set a non-default region.
    t.feed("\x1b[3;7r");
    try testing.expectEqual(@as(u16, 2), t.active().scroll_top);

    // Reset with no params.
    t.feed("\x1b[r");

    try testing.expectEqual(@as(u16, 0), t.active().scroll_top);
    try testing.expectEqual(@as(u16, t.active().active_rows - 1), t.active().scroll_bottom);
}

test "csi: DECSTBM 0;0 resets to full screen" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[3;7r");
    t.feed("\x1b[0;0r"); // explicit zeros = same as no params

    try testing.expectEqual(@as(u16, 0), t.active().scroll_top);
    try testing.expectEqual(@as(u16, t.active().active_rows - 1), t.active().scroll_bottom);
}

test "csi: DECSTBM top >= bottom is ignored" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    // Set a valid region first.
    t.feed("\x1b[2;6r");
    const top_before = t.active().scroll_top;
    const bot_before = t.active().scroll_bottom;

    // Invalid: top == bottom (1-based 5;5 : 0-based 4;4).
    t.feed("\x1b[5;5r");

    try testing.expectEqual(top_before, t.active().scroll_top);
    try testing.expectEqual(bot_before, t.active().scroll_bottom);
}

test "csi: DECSTBM top > bottom is ignored" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[2;6r");
    const top_before = t.active().scroll_top;
    const bot_before = t.active().scroll_bottom;

    // Invalid: top > bottom (1-based 7;3).
    t.feed("\x1b[7;3r");

    try testing.expectEqual(top_before, t.active().scroll_top);
    try testing.expectEqual(bot_before, t.active().scroll_bottom);
}

test "csi: DECSTBM bottom clamped to active rows" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    // Request bottom beyond screen height.
    t.feed("\x1b[1;9999r");

    try testing.expectEqual(@as(u16, 0), t.active().scroll_top);
    try testing.expectEqual(@as(u16, t.active().active_rows - 1), t.active().scroll_bottom);
}

test "csi: DECSTBM scroll region is used by SU" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    // Fill rows 0-4 with 'A'-'E'.
    for (0..5) |r| {
        t.active().rowMut(r)[0] = .{ .codepoint = @intCast('A' + r), .kind = .narrow };
    }

    // Constrain scroll region to rows 1-3.
    t.feed("\x1b[2;4r"); // 1-based 2;4 : 0-based 1;3

    t.feed("\x1b[S"); // SU 1 — scrolls within region only

    // Row 0: untouched (above region).
    try testing.expectEqual(@as(u32, 'A'), t.active().row(0)[0].codepoint);
    // Rows 1-2: shifted up from rows 2-3.
    try testing.expectEqual(@as(u32, 'C'), t.active().row(1)[0].codepoint);
    try testing.expectEqual(@as(u32, 'D'), t.active().row(2)[0].codepoint);
    // Row 3: new blank (bottom of region).
    try testing.expectEqual(@as(u32, 0), t.active().row(3)[0].codepoint);
    // Row 4: untouched (below region).
    try testing.expectEqual(@as(u32, 'E'), t.active().row(4)[0].codepoint);
}

test "csi: CHT moves to next tab stop" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().cursor.col = 0;
    t.feed("\x1b[I"); // CHT 1 (default)
    try testing.expectEqual(@as(u16, 8), t.active().cursor.col);
}

test "csi: CHT n=2 skips two tab stops" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().cursor.col = 0;
    t.feed("\x1b[2I"); // CHT 2
    try testing.expectEqual(@as(u16, 16), t.active().cursor.col);
}

test "csi: CHT from mid-column advances to next stop" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().cursor.col = 5;
    t.feed("\x1b[I");
    try testing.expectEqual(@as(u16, 8), t.active().cursor.col);
}

test "csi: CHT n=0 treated as n=1" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().cursor.col = 0;
    t.feed("\x1b[0I"); // CHT 0 : treated as 1
    try testing.expectEqual(@as(u16, 8), t.active().cursor.col);
}

test "csi: CHT past last tab stop clamps to last column" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    // Clear all tab stops so there is nothing to the right of the cursor.
    t.feed("\x1b[3g"); // TBC 3 — clear all

    t.active().cursor.col = 5;
    t.feed("\x1b[I"); // CHT 1
    try testing.expectEqual(
        @as(u16, @intCast(t.active().active_cols - 1)),
        t.active().cursor.col,
    );
}

test "csi: CHT does not change row" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().cursor.row = 3;
    t.active().cursor.col = 0;
    t.feed("\x1b[I");
    try testing.expectEqual(@as(u16, 3), t.active().cursor.row);
    try testing.expectEqual(@as(u16, 8), t.active().cursor.col);
}

test "csi: CHT clears wrap_pending" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().cursor.wrap_pending = true;
    t.active().cursor.col = 0;
    t.feed("\x1b[I");
    try testing.expect(!t.active().cursor.wrap_pending);
}

test "csi: CHT with custom tab stop" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    // Clear all tab stops, set one at col 5.
    t.feed("\x1b[3g"); // TBC 3 — clear all
    t.active().cursor.col = 5;
    t.feed("\x1bH"); // HTS — set tab at col 5

    t.active().cursor.col = 0;
    t.feed("\x1b[I");
    try testing.expectEqual(@as(u16, 5), t.active().cursor.col);
}

test "csi: CBT moves to previous tab stop" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().cursor.col = 16;
    t.feed("\x1b[Z"); // CBT 1 (default)
    try testing.expectEqual(@as(u16, 8), t.active().cursor.col);
}

test "csi: CBT n=2 skips two tab stops" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().cursor.col = 24;
    t.feed("\x1b[2Z"); // CBT 2
    try testing.expectEqual(@as(u16, 8), t.active().cursor.col);
}

test "csi: CBT from mid-column goes to previous stop" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    // col 5 is between tab stops 0 and 8; CBT should land on col 0
    // (no tab stop strictly left of col 5 except col 0 if it's a stop,
    // otherwise clamp to col 0).
    t.active().cursor.col = 5;
    t.feed("\x1b[Z");
    try testing.expectEqual(@as(u16, 0), t.active().cursor.col);
}

test "csi: CBT n=0 treated as n=1" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().cursor.col = 16;
    t.feed("\x1b[0Z"); // CBT 0 : treated as 1
    try testing.expectEqual(@as(u16, 8), t.active().cursor.col);
}

test "csi: CBT past first tab stop clamps to col 0" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    // From col 8 (first default tab stop), CBT 1 : no stop to the left : col 0.
    t.active().cursor.col = 8;
    t.feed("\x1b[Z");
    try testing.expectEqual(@as(u16, 0), t.active().cursor.col);
}

test "csi: CBT n larger than available stops clamps to col 0" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    // From col 16 there is only one tab stop to the left (col 8).
    // CBT 5 should clamp to col 0.
    t.active().cursor.col = 16;
    t.feed("\x1b[5Z");
    try testing.expectEqual(@as(u16, 0), t.active().cursor.col);
}

test "csi: CBT does not change row" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().cursor.row = 3;
    t.active().cursor.col = 16;
    t.feed("\x1b[Z");
    try testing.expectEqual(@as(u16, 3), t.active().cursor.row);
    try testing.expectEqual(@as(u16, 8), t.active().cursor.col);
}

test "csi: CBT clears wrap_pending" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().cursor.wrap_pending = true;
    t.active().cursor.col = 16;
    t.feed("\x1b[Z");
    try testing.expect(!t.active().cursor.wrap_pending);
}

test "csi: CBT at col 0 is a no-op (already at leftmost)" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().cursor.col = 0;
    t.feed("\x1b[Z");
    try testing.expectEqual(@as(u16, 0), t.active().cursor.col);
}

test "csi: CHT then CBT returns to original column" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().cursor.col = 8;
    t.feed("\x1b[I"); // CHT 1 : col 16
    t.feed("\x1b[Z"); // CBT 1 : col 8
    try testing.expectEqual(@as(u16, 8), t.active().cursor.col);
}

test "csi: DSR 5 reporting" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.control_format = .s7c1t;
    t.feed("\x1b[5n");

    try testing.expect(t.events.any());
    try testing.expectEqualStrings("\x1b[0n", t.events.response.slice());
}

test "csi: DSR 6 reporting" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().cursor.row = 5;
    t.active().cursor.col = 10;

    t.control_format = .s7c1t;
    t.feed("\x1b[6n");

    try testing.expect(t.events.any());
    try testing.expectEqualStrings("\x1b[6;11R", t.events.response.slice());
}

test "csi: DSR XTVERSION xterm name and version" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.control_format = .s7c1t;
    t.feed("\x1b[>0p");

    try testing.expect(t.events.any());
    try testing.expectEqualStrings("\x1bP>|test 0.0.1\x1b\\", t.events.response.slice());
}

test "csi: DECXCPR report cursor position" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().cursor.row = 5;
    t.active().cursor.col = 10;

    t.control_format = .s7c1t;
    t.feed("\x1b[?6n");

    try testing.expect(t.events.any());
    try testing.expectEqualStrings("\x1b[?6;11R", t.events.response.slice());
}

test "csi: DA1 reports a VT220 with colour and clipboard" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.control_format = .s7c1t;
    t.feed("\x1b[0c");

    try testing.expect(t.events.any());
    try testing.expectEqualStrings("\x1b[?62;22;52c", t.events.response.slice());
}

test "esc: DECID answers exactly like DA1" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[c");
    const da1 = try alloc.dupe(u8, t.events.response.slice());
    defer alloc.free(da1);
    t.events.response.clear();

    t.feed("\x1bZ");
    try testing.expectEqualStrings(da1, t.events.response.slice());
}

test "esc: DECID answers with 8-bit controls under s8c1t" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.control_format = .s8c1t;
    t.feed("\x1bZ");
    try testing.expectEqualStrings("\x9b?62;22;52c", t.events.response.slice());
}

test "csi: DA2 reports the terminal type and version" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.control_format = .s7c1t;
    t.feed("\x1b[>0c");

    try testing.expect(t.events.any());
    try testing.expectEqualStrings("\x1b[>1;0;0c", t.events.response.slice());
}

test "csi: REP repeats last char" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("A"); // putChar 'A'
    t.feed("\x1b[3b"); // REP 3 repeat 'A' three more times

    // Cursor should be at col 4 (A + 3 repeats).
    try testing.expectEqual(@as(u16, 4), t.active().cursor.col);
    try testing.expectEqual(@as(u32, 'A'), t.active().row(0)[0].codepoint);
    try testing.expectEqual(@as(u32, 'A'), t.active().row(0)[1].codepoint);
    try testing.expectEqual(@as(u32, 'A'), t.active().row(0)[2].codepoint);
    try testing.expectEqual(@as(u32, 'A'), t.active().row(0)[3].codepoint);
}

test "csi: REP keeps the width the character was printed with" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    // UTF-8 input and REP share one width table: ❤ is one cell both ways.
    t.feed("\u{2764}\x1b[2b");
    try testing.expectEqual(@as(u16, 3), t.active().cursor.col);
    for (0..3) |c| try testing.expectEqual(.narrow, t.active().row(0)[c].kind);

    t.feed("\r\x1b[K\u{4E2D}\x1b[b"); // 中 is two cells both ways
    try testing.expectEqual(@as(u16, 4), t.active().cursor.col);
    try testing.expectEqual(.wide_left, t.active().row(0)[0].kind);
    try testing.expectEqual(.wide_left, t.active().row(0)[2].kind);
}

test "csi: REP n=0 treated as n=1" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("B");
    t.feed("\x1b[0b"); // REP 0 treated as 1

    try testing.expectEqual(@as(u16, 2), t.active().cursor.col);
    try testing.expectEqual(@as(u32, 'B'), t.active().row(0)[1].codepoint);
}

test "csi: REP uses current SGR attributes, not original" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[31m"); // fg = indexed 1 (red)
    t.feed("X");
    t.feed("\x1b[32m"); // fg = indexed 2 (green) change attr BEFORE REP
    t.feed("\x1b[b"); // REP 1

    // Original 'X' at col 0 has red fg.
    const red_idx = t.active().palette.intern(.{ .indexed = 1 });
    try testing.expectEqual(red_idx, t.active().row(0)[0].foreground);

    // Repeated 'X' at col 1 has green fg (current attr at time of REP).
    const green_idx = t.active().palette.intern(.{ .indexed = 2 });
    try testing.expectEqual(green_idx, t.active().row(0)[1].foreground);
}

test "csi: REP no-op when no previous char" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    // No putChar called yet; last_char == 0.
    t.feed("\x1b[5b"); // REP 5; should be a no-op
    try testing.expectEqual(@as(u16, 0), t.active().cursor.col);
    try testing.expectEqual(@as(u32, 0), t.active().row(0)[0].codepoint);
}

test "csi: DECSCUSR sets cursor style" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[2 q"); // DECSCUSR 2 = steady block
    try testing.expectEqual(.steady_block, t.active().cursor.style);

    t.feed("\x1b[5 q"); // DECSCUSR 5 = blinking bar
    try testing.expectEqual(.blinking_beam, t.active().cursor.style);

    t.feed("\x1b[0 q"); // DECSCUSR 0 = blinking block (default)
    try testing.expectEqual(.blinking_block, t.active().cursor.style);
}

test "csi: DECSCUSR unknown value resets to default" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[2 q"); // set to steady block first
    t.feed("\x1b[99 q"); // unknown; reset to default
    try testing.expectEqual(CursorStyle.default, t.active().cursor.style);
}

test "escape: ESC c resets cursor style" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[6 q"); // steady bar
    t.feed("\x1bc"); // RIS hard reset
    try testing.expectEqual(CursorStyle.default, t.active().cursor.style);
}

test "sgr: empty params = reset" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().cursor.attr.flags.bold = true;
    t.active().cursor.attr.fg = t.active().palette.intern(.{ .indexed = 3 });

    t.feed("\x1b[m");
    try testing.expectEqualDeep(Attr{}, t.active().cursor.attr);
}

test "sgr: 0 explicit reset" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.active().cursor.attr.flags.bold = true;
    t.active().cursor.attr.fg = t.active().palette.intern(.{ .indexed = 5 });

    t.feed("\x1b[0m");
    try testing.expectEqualDeep(Attr{}, t.active().cursor.attr);
}

test "sgr: 0 in sequence resets then continues" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[0;1m"); // reset then bold
    try testing.expect(t.active().cursor.attr.flags.bold);
    try testing.expect(!t.active().cursor.attr.flags.italic);
}

test "sgr: 1 = bold on" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[1m");
    try testing.expect(t.active().cursor.attr.flags.bold);
}

test "sgr: 22 = bold off" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[1m");
    t.feed("\x1b[22m");
    try testing.expect(!t.active().cursor.attr.flags.bold);
}

test "sgr: 2 = dim on" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[2m");
    try testing.expect(t.active().cursor.attr.flags.dim);
}

test "sgr: 22 = dim off" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[2m");
    t.feed("\x1b[22m");
    try testing.expect(!t.active().cursor.attr.flags.dim);
}

test "sgr: 22 resets both bold and dim" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[1m");
    t.feed("\x1b[2m");
    t.feed("\x1b[22m");
    try testing.expect(!t.active().cursor.attr.flags.bold);
    try testing.expect(!t.active().cursor.attr.flags.dim);
}

test "sgr: 3 = italic on" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[3m");
    try testing.expect(t.active().cursor.attr.flags.italic);
}

test "sgr: 23 = italic off" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[3m");
    t.feed("\x1b[23m");
    try testing.expect(!t.active().cursor.attr.flags.italic);
}

test "sgr: 4 = single underline" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[4m");
    try testing.expectEqual(.single, t.active().cursor.attr.flags.underline);
}

test "sgr: 4:0 = underline off (sub-param)" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[4m");
    t.feed("\x1b[4:0m");
    try testing.expectEqual(.none, t.active().cursor.attr.flags.underline);
}

test "sgr: 4:1 = single underline (sub-param)" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[4:1m");
    try testing.expectEqual(.single, t.active().cursor.attr.flags.underline);
}

test "sgr: 4:2 = double underline (sub-param)" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[4:2m");
    try testing.expectEqual(.double, t.active().cursor.attr.flags.underline);
}

test "sgr: 4:3 = curly underline (sub-param)" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[4:3m");
    try testing.expectEqual(.curly, t.active().cursor.attr.flags.underline);
}

test "sgr: 4:4 = dotted underline (sub-param)" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[4:4m");
    try testing.expectEqual(.dotted, t.active().cursor.attr.flags.underline);
}

test "sgr: 4:5 = dashed underline (sub-param)" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[4:5m");
    try testing.expectEqual(.dashed, t.active().cursor.attr.flags.underline);
}

test "sgr: 21 = double underline (legacy)" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[21m");
    try testing.expectEqual(.double, t.active().cursor.attr.flags.underline);
}

test "sgr: 24 = underline off" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[4m");
    t.feed("\x1b[24m");
    try testing.expectEqual(.none, t.active().cursor.attr.flags.underline);
}

test "sgr: 9 and 29 set and clear strikethrough" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[9m");
    try testing.expect(t.active().cursor.attr.flags.strikethrough);
    t.feed("\x1b[29m");
    try testing.expect(!t.active().cursor.attr.flags.strikethrough);
}

test "sgr: 53 and 55 set and clear overline" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[53m");
    try testing.expect(t.active().cursor.attr.flags.overline);
    t.feed("\x1b[55m");
    try testing.expect(!t.active().cursor.attr.flags.overline);
}

test "sgr: decorations land in printed cells" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[4:3;9;53mA\x1b[0mB");
    const row = t.active().row(0);
    try testing.expectEqual(.curly, row[0].flags.underline);
    try testing.expect(row[0].flags.strikethrough and row[0].flags.overline);
    try testing.expectEqual(.none, row[1].flags.underline);
    try testing.expect(!row[1].flags.strikethrough and !row[1].flags.overline);
}

test "sgr: 4 with an unknown style falls back to single" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[4:9m");
    try testing.expectEqual(.single, t.active().cursor.attr.flags.underline);
}

fn expectUnderlineColor(seq: []const u8, expected: Color) !void {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed(seq);
    try testing.expectEqual(expected, t.active().cursor.attr.underline_color);
}

test "sgr: 58 sets the underline color in every 38 form" {
    const rgb: Color = .fromRgb(255, 128, 0);
    try expectUnderlineColor("\x1b[58;2;255;128;0m", rgb);
    try expectUnderlineColor("\x1b[58:2:255:128:0m", rgb);
    try expectUnderlineColor("\x1b[58:2::255:128:0m", rgb);
    try expectUnderlineColor("\x1b[58:2:0:255:128:0m", rgb);
    try expectUnderlineColor("\x1b[58;5;196m", .{ .indexed = 196 });
    try expectUnderlineColor("\x1b[58:5:196m", .{ .indexed = 196 });
}

test "sgr: 58 leaves fg, bg and the palette alone" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    const before = t.active().palette.entries;
    t.feed("\x1b[58:2::1:2:3m");
    const attr = t.active().cursor.attr;
    try testing.expectEqual(0, attr.fg);
    try testing.expectEqual(0, attr.bg);
    try testing.expectEqual(before, t.active().palette.entries);
}

test "sgr: 59 and 0 reset the underline color" {
    try expectUnderlineColor("\x1b[58;5;1m\x1b[59m", .default);
    try expectUnderlineColor("\x1b[58;5;1m\x1b[0m", .default);
    try expectUnderlineColor("\x1b[58;5;1m\x1b[m", .default);
}

test "sgr: 58 consumes its parameters, the codes after it still apply" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[4:3;58:2::255:0:0;1m");
    const attr = t.active().cursor.attr;
    try testing.expectEqual(.curly, attr.flags.underline);
    try testing.expect(attr.flags.bold);
    try testing.expect(!attr.flags.dim);
    try testing.expectEqual(Color.fromRgb(255, 0, 0), attr.underline_color);
}

test "sgr: sub-parameters of an unknown code are skipped" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    // Without the skip, the trailing :0 would reset the pen and :1 set bold.
    t.feed("\x1b[4m\x1b[99:1:0m");
    const attr = t.active().cursor.attr;
    try testing.expectEqual(.single, attr.flags.underline);
    try testing.expect(!attr.flags.bold);
}

test "sgr: 5 = blink on" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[5m");
    try testing.expect(t.active().cursor.attr.flags.blink);
    try testing.expect(!t.active().cursor.attr.flags.blink_rapid);
}

test "sgr: 6 = rapid blink on" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[6m");
    try testing.expect(t.active().cursor.attr.flags.blink_rapid);
    try testing.expect(!t.active().cursor.attr.flags.blink);
}

test "sgr: 25 = blink off (clears both blink and blink_rapid)" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[5m");
    t.feed("\x1b[6m");
    t.feed("\x1b[25m");
    try testing.expect(!t.active().cursor.attr.flags.blink);
    try testing.expect(!t.active().cursor.attr.flags.blink_rapid);
}

test "sgr: 7 = reverse on" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[7m");
    try testing.expect(t.active().cursor.attr.flags.reverse);
}

test "sgr: 27 = reverse off" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[7m");
    t.feed("\x1b[27m");
    try testing.expect(!t.active().cursor.attr.flags.reverse);
}

test "sgr: 8 = invisible on" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[8m");
    try testing.expect(t.active().cursor.attr.flags.invisible);
}

test "sgr: 28 = invisible off" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[8m");
    t.feed("\x1b[28m");
    try testing.expect(!t.active().cursor.attr.flags.invisible);
}

test "sgr: 9 = strikethrough on" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[9m");
    try testing.expect(t.active().cursor.attr.flags.strikethrough);
}

test "sgr: 29 = strikethrough off" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[9m");
    t.feed("\x1b[29m");
    try testing.expect(!t.active().cursor.attr.flags.strikethrough);
}

test "sgr: 53 = overline on" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[53m");
    try testing.expect(t.active().cursor.attr.flags.overline);
}

test "sgr: 55 = overline off" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[53m");
    t.feed("\x1b[55m");
    try testing.expect(!t.active().cursor.attr.flags.overline);
}

test "sgr: 30 = fg black (indexed 0)" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[30m");
    try testing.expectEqual(
        Color{ .indexed = 0 },
        t.active().palette.decode(t.active().cursor.attr.fg),
    );
}

test "sgr: 37 = fg white (indexed 7)" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[37m");
    try testing.expectEqual(
        Color{ .indexed = 7 },
        t.active().palette.decode(t.active().cursor.attr.fg),
    );
}

test "sgr: 39 = fg default" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[31m"); // set red
    t.feed("\x1b[39m"); // reset to default
    try testing.expectEqual(
        Color.default,
        t.active().palette.decode(t.active().cursor.attr.fg),
    );
    try testing.expectEqual(Palette.default_base, t.active().cursor.attr.fg);
}

test "sgr: 40 = bg black (indexed 0)" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[40m");
    try testing.expectEqual(
        Color{ .indexed = 0 },
        t.active().palette.decode(t.active().cursor.attr.bg),
    );
}

test "sgr: 47 = bg white (indexed 7)" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[47m");
    try testing.expectEqual(
        Color{ .indexed = 7 },
        t.active().palette.decode(t.active().cursor.attr.bg),
    );
}

test "sgr: 49 = bg default" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[41m");
    t.feed("\x1b[49m");
    try testing.expectEqual(
        Color.default,
        t.active().palette.decode(t.active().cursor.attr.bg),
    );
    try testing.expectEqual(Palette.default_base, t.active().cursor.attr.bg);
}

test "sgr: 90 = fg bright black (indexed 8)" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[90m");
    try testing.expectEqual(
        Color{ .indexed = 8 },
        t.active().palette.decode(t.active().cursor.attr.fg),
    );
}

test "sgr: 97 = fg bright white (indexed 15)" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[97m");
    try testing.expectEqual(
        Color{ .indexed = 15 },
        t.active().palette.decode(t.active().cursor.attr.fg),
    );
}

test "sgr: 100 = bg bright black (indexed 8)" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[100m");
    try testing.expectEqual(
        Color{ .indexed = 8 },
        t.active().palette.decode(t.active().cursor.attr.bg),
    );
}

test "sgr: 107 = bg bright white (indexed 15)" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[107m");
    try testing.expectEqual(
        Color{ .indexed = 15 },
        t.active().palette.decode(t.active().cursor.attr.bg),
    );
}

test "sgr: 38;5;200 = fg indexed 200" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[38;5;200m");
    try testing.expectEqual(
        Color{ .indexed = 200 },
        t.active().palette.decode(t.active().cursor.attr.fg),
    );
}

test "sgr: 38;5;0 = fg indexed 0" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[38;5;0m");
    try testing.expectEqual(
        Color{ .indexed = 0 },
        t.active().palette.decode(t.active().cursor.attr.fg),
    );
}

test "sgr: 38;5;255 = fg indexed 255" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[38;5;255m");
    try testing.expectEqual(
        Color{ .indexed = 255 },
        t.active().palette.decode(t.active().cursor.attr.fg),
    );
}

test "sgr: 38:5:200 = fg indexed 200 (colon form)" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[38:5:200m");
    try testing.expectEqual(
        Color{ .indexed = 200 },
        t.active().palette.decode(t.active().cursor.attr.fg),
    );
}

test "sgr: 38;2;255;0;128 = fg rgb(255,0,128)" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[38;2;255;0;128m");
    try testing.expectEqual(
        Color{ .rgb = .{ .r = 255, .g = 0, .b = 128 } },
        t.active().palette.decode(t.active().cursor.attr.fg),
    );
}

test "sgr: 38;2;0;0;0 = fg rgb(0,0,0)" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[38;2;0;0;0m");
    try testing.expectEqual(
        Color{ .rgb = .{ .r = 0, .g = 0, .b = 0 } },
        t.active().palette.decode(t.active().cursor.attr.fg),
    );
}

test "sgr: 38:2:255:128:0 = fg rgb(255,128,0) (colon form)" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[38:2:255:128:0m");
    try testing.expectEqual(
        Color{ .rgb = .{ .r = 255, .g = 128, .b = 0 } },
        t.active().palette.decode(t.active().cursor.attr.fg),
    );
}

test "sgr: 48;5;100 = bg indexed 100" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[48;5;100m");
    try testing.expectEqual(
        Color{ .indexed = 100 },
        t.active().palette.decode(t.active().cursor.attr.bg),
    );
}

test "sgr: 48;2;10;20;30 = bg rgb(10,20,30)" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[48;2;10;20;30m");
    try testing.expectEqual(
        Color{ .rgb = .{ .r = 10, .g = 20, .b = 30 } },
        t.active().palette.decode(t.active().cursor.attr.bg),
    );
}

test "sgr: same rgb color twice = same palette index" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[38;2;100;150;200m");
    const idx1 = t.active().cursor.attr.fg;

    t.feed("\x1b[39m"); // reset fg
    t.feed("\x1b[38;2;100;150;200m"); // same color again
    const idx2 = t.active().cursor.attr.fg;

    try testing.expectEqual(idx1, idx2);
}

test "sgr: combined bold + italic + fg in one sequence" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[1;3;32m"); // bold + italic + fg green (indexed 2)
    try testing.expect(t.active().cursor.attr.flags.bold);
    try testing.expect(t.active().cursor.attr.flags.italic);
    try testing.expectEqual(
        Color{ .indexed = 2 },
        t.active().palette.decode(t.active().cursor.attr.fg),
    );
}

// Regressions: each failed before its fix.

test "m2: CUU after DECRC above the region in origin mode stays in range" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    // Save at row 1 under DECOM, move the region below it, restore, go up.
    t.feed("\x1b[2;10r\x1b[?6h\x1b7\x1b[6;11r\x1b8\x1b[A");
    try testing.expectEqual(5, t.active().cursor.row);
    t.feed("\x1b[B");
    try testing.expectEqual(6, t.active().cursor.row);
}

test "m2: ASCII run past the margin with DECAWM off stays on the row" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[?7l" ++ "A" ** 29 ++ "B");
    const s = t.active();
    try testing.expectEqual(0, s.cursor.row);
    try testing.expectEqual(test_option.max_cols - 1, s.cursor.col);
    try testing.expectEqual('A', s.row(0)[test_option.max_cols - 2].codepoint);
    try testing.expectEqual('B', s.row(0)[test_option.max_cols - 1].codepoint);
    try testing.expectEqual(0, s.row(1)[0].codepoint);
}

test "m2: wide char at the last column with DECAWM off stays on the row" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    const last = test_option.max_cols - 1;
    t.feed("\x1b[?7l" ++ "A" ** (test_option.max_cols - 1) ++ "中");
    const s = t.active();
    try testing.expectEqual(0, s.cursor.row);
    try testing.expectEqual(last, s.cursor.col);
    try testing.expectEqual('A', s.row(0)[last - 1].codepoint);
    try testing.expectEqual(0, s.row(0)[last].codepoint); // dropped, not split
    try testing.expectEqual(0, s.row(1)[0].codepoint);
}

test "m2: RI at the top of a full screen keeps scrollback" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    // 14 numbered lines plus the final LF on 12 rows: 0 to 2 scroll off.
    for (0..14) |i| {
        var buf: [8]u8 = undefined;
        t.feed(std.fmt.bufPrint(&buf, "{d}\r\n", .{i}) catch unreachable);
    }
    const s = t.active();
    const used = s.scrollback_used;
    const scrolled = s.total_lines_scrolled;

    t.feed("\x1b[H\x1bM");
    try testing.expectEqual(used, s.scrollback_used);
    try testing.expectEqual(scrolled, s.total_lines_scrolled);
    try testing.expectEqual(0, s.row(0)[0].codepoint); // blank line inserted

    s.scrollViewportBack(1);
    try testing.expectEqual('2', s.displayRow(0)[0].codepoint); // newest history line intact
}

test "m2: CAN or SUB inside OSC cancels it, the title is kept" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b]2;kept\x07");
    t.feed("\x1b]2;lost\x18");
    t.feed("\x1b]0;lost too\x1a");
    try testing.expectEqualStrings("kept", t.getTitle());
}

test "m2: ESC then a non-ST byte inside OSC drops it and runs the escape" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b]2;kept\x07");
    // ESC 7 inside the string is DECSC, as in xterm, not a terminator.
    t.feed("\x1b[5;6H\x1b]2;lost\x1b7\x1b[H\x1b8");
    try testing.expectEqualStrings("kept", t.getTitle());
    try testing.expectEqual(@as(u16, 4), t.active().cursor.row);
    try testing.expectEqual(@as(u16, 5), t.active().cursor.col);

    // ESC \\ split across feeds still ends it.
    t.feed("\x1b]2;split\x1b");
    t.feed("\\");
    try testing.expectEqualStrings("split", t.getTitle());
}

test "m2: DECSTR resets each item in the VT510 DECSTR table" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    // DECTCEM off, IRM on, DECSTBM 2;5, DECOM on, DECAWM on (default),
    // DECCKM, DECKPAM, G0 = DEC graphics + SO, SGR bold red, DECSC.
    t.feed("\x1b[?25l\x1b[4h\x1b[2;5r\x1b[?6h\x1b[?1h\x1b=\x1b(0\x0e\x1b[1;31m\x1b[3;4H\x1b7");
    t.feed("\x1b[!p");

    const s = t.active();
    try testing.expect(s.mode.cursor_visibility); // DECTCEM: visible
    try testing.expect(!s.mode.insert); // IRM: replace
    try testing.expect(!s.cursor.origin); // DECOM: absolute
    try testing.expect(!s.mode.auto_wrap); // DECAWM: no autowrap
    try testing.expect(!t.mode.cursor_keys); // DECCKM: normal
    try testing.expect(!t.mode.keypad_app); // DECNKM: numeric
    try testing.expectEqual(0, s.scroll_top); // DECSTBM: full page
    try testing.expectEqual(test_option.max_rows - 1, s.scroll_bottom);
    try testing.expect(s.charset_is_identity); // G0-G3, GL, GR: default
    try testing.expectEqualDeep(Attr{}, s.cursor.attr); // SGR: normal
    try testing.expectEqualDeep(SavedCursor{}, s.saved_cursor); // DECSC: home, defaults
}

test "m2: DECSTR leaves everything outside the VT510 DECSTR table alone" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    // DECSCNM, cursor blink (?12) and style (DECSCUSR), LNM, DECARM,
    // reverse wrap, modifyOtherKeys, a tab stop, text, line attribute.
    t.feed("\x1b[?5h\x1b[4 q\x1b[?12h\x1b[20h\x1b[?8l\x1b[3g\x1b[1;5H\x1bH");
    t.feed("\x1b[H\x1b#6AB\x1b[2;3H");
    t.active().mode.cursor_blink = true;
    t.feed("\x1b[?45h");
    t.mode.modify_other_keys = 2;
    const style = t.active().cursor.style;
    t.feed("\x1b[!p");

    const s = t.active();
    try testing.expect(s.mode.reverse_video);
    try testing.expect(s.mode.cursor_blink);
    try testing.expectEqual(style, s.cursor.style);
    try testing.expect(t.mode.linefeed);
    try testing.expect(!t.mode.auto_repeat);
    try testing.expect(s.mode.reverse_wrap);
    try testing.expectEqual(2, t.mode.modify_other_keys);
    try testing.expect(s.tab_stops.isSet(4));
    try testing.expect(!s.tab_stops.isSet(8));
    try testing.expectEqual('A', s.row(0)[0].codepoint);
    try testing.expectEqual(.double_width, s.line_attrs[s.physRow(0)]);
    try testing.expectEqual(1, s.cursor.row);
    try testing.expectEqual(2, s.cursor.col);
}

test "color: OSC 4 on 16-255 applies to text drawn after it" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b]4;100;#0a0b0c;255;#010203\x07");
    t.feed("\x1b[38;5;100mX\x1b[48;5;255mY");
    const p = &t.active().palette;
    const row = t.active().row(0);
    try testing.expectEqual([3]u8{ 10, 11, 12 }, p.resolveRgb(row[0].foreground, .foreground));
    try testing.expectEqual([3]u8{ 1, 2, 3 }, p.resolveRgb(row[1].background, .background));
}

test "color: OSC 104 with no argument resets all 256 indices" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b]4;1;#010101;200;#020202;255;#030303\x07");
    t.feed("\x1b]104\x07");
    const p = &t.active().palette;
    for ([_]u8{ 1, 200, 255 }) |n| {
        try testing.expectEqual(Rgb.fromU32(ansi.indexed(n)), p.getIndexed(n));
    }
}

test "color: OSC 104 resets each index in its list" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b]4;1;#010101;2;#020202;200;#030303\x07");
    t.feed("\x1b]104;1;200\x07");
    const p = &t.active().palette;
    try testing.expectEqual(Rgb.fromU32(ansi.indexed(1)), p.getIndexed(1));
    try testing.expectEqual(Rgb{ .r = 2, .g = 2, .b = 2 }, p.getIndexed(2));
    try testing.expectEqual(Rgb.fromU32(ansi.indexed(200)), p.getIndexed(200));
}

/// A theme whose colors differ from every built-in default.
const test_theme: Theme = blk: {
    var t = Theme.graphite;
    t.background = .{ .r = 0x10, .g = 0x20, .b = 0x30 };
    t.foreground = .{ .r = 0xE0, .g = 0xD0, .b = 0xC0 };
    t.selection_background = .{ .r = 0x11, .g = 0x22, .b = 0x33 };
    t.selection_foreground = .{ .r = 0x44, .g = 0x55, .b = 0x66 };
    for (&t.ansi, 0..) |*c, n| c.* = .{ .r = @intCast(n), .g = 0x42, .b = 0x24 };
    break :blk t;
};

test "color: the theme applies to both screens" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.setTheme(test_theme);
    t.feed("\x1b[?1049h");
    const p = &t.active().palette;
    try testing.expectEqual(test_theme.background, p.get(.background));
    try testing.expectEqual(test_theme.foreground, p.get(.foreground));
    try testing.expectEqual(test_theme.ansi[1], p.getIndexed(1));
}

test "color: OSC 12 survives a screen switch" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b]12;#123456\x07\x1b[?1049h");
    try testing.expectEqual(Rgb{ .r = 0x12, .g = 0x34, .b = 0x56 }, t.cursor_color.?);
    t.feed("\x1b[?1049l");
    try testing.expectEqual(Rgb{ .r = 0x12, .g = 0x34, .b = 0x56 }, t.cursor_color.?);
}

test "color: OSC 17 and 19 queries fall back to the theme" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.setTheme(test_theme);
    t.feed("\x1b]17;?\x07");
    try testing.expect(std.mem.indexOf(u8, t.events.response.slice(), "17;rgb:1111/2222/3333") != null);
    t.events.clear();
    t.feed("\x1b]19;?\x07");
    try testing.expect(std.mem.indexOf(u8, t.events.response.slice(), "19;rgb:4444/5555/6666") != null);
}

test "color: OSC 117 and 119 reset the selection colors" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b]17;#010203\x07\x1b]19;#040506\x07");
    try testing.expect(t.selection_background != null and t.selection_foreground != null);
    t.feed("\x1b]117\x07");
    try testing.expectEqual(null, t.selection_background);
    t.feed("\x1b]119\x07");
    try testing.expectEqual(null, t.selection_foreground);
}

// DEC private mode 45, reverse wraparound (xterm ctlseqs).

/// Prints one more character than the row holds, so row 0 soft-wraps
/// into row 1 and the cursor ends at row 1, column 1.
fn feedSoftWrappedLine(t: *Term) void {
    const cols = t.active().active_cols;
    var i: usize = 0;
    while (i <= cols) : (i += 1) t.feed("x");
}

test "mode 45: set and reset reach the active screen" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    try testing.expect(!t.active().mode.reverse_wrap); // power-on default
    t.feed("\x1b[?45h");
    try testing.expect(t.active().mode.reverse_wrap);
    try testing.expectEqual(DecModeReport.set, t.decModeReport(45));
    t.feed("\x1b[?45l");
    try testing.expect(!t.active().mode.reverse_wrap);
    try testing.expectEqual(DecModeReport.reset, t.decModeReport(45));
}

test "mode 45: BS at column 0 goes to the end of a soft-wrapped row above" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);
    const last_col = t.active().active_cols - 1;

    t.feed("\x1b[?45h");
    feedSoftWrappedLine(&t);
    t.feed("\x08\x08"); // to column 0, then across the wrap
    try testing.expectEqual(@as(u16, 0), t.active().cursor.row);
    try testing.expectEqual(@as(u16, @intCast(last_col)), t.active().cursor.col);
}

test "mode 45: CUB crosses soft wraps one column per step" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);
    const last_col = t.active().active_cols - 1;

    t.feed("\x1b[?45h");
    feedSoftWrappedLine(&t);
    t.feed("\x1b[3D"); // column 1, 0, then the last column of row 0
    try testing.expectEqual(@as(u16, 0), t.active().cursor.row);
    try testing.expectEqual(@as(u16, @intCast(last_col - 1)), t.active().cursor.col);
}

test "mode 45: no reverse wrap across a hard line break" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[?45h");
    t.feed("ab\r\ncd");
    t.feed("\x1b[5D");
    try testing.expectEqual(@as(u16, 1), t.active().cursor.row);
    try testing.expectEqual(@as(u16, 0), t.active().cursor.col);
}

test "mode 45: stops at the top of the screen" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[?45h");
    t.feed("\x08\x08");
    try testing.expectEqual(@as(u16, 0), t.active().cursor.row);
    try testing.expectEqual(@as(u16, 0), t.active().cursor.col);
}

test "mode 45: BS with a pending wrap only cancels it" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);
    const cols = t.active().active_cols;

    t.feed("\x1b[?45h");
    var i: usize = 0;
    while (i < cols) : (i += 1) t.feed("x");
    try testing.expect(t.active().cursor.wrap_pending);
    t.feed("\x08");
    try testing.expect(!t.active().cursor.wrap_pending);
    try testing.expectEqual(@as(u16, @intCast(cols - 1)), t.active().cursor.col);
}

test "mode 45: needs DECAWM, and is off without it" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    feedSoftWrappedLine(&t);
    t.feed("\x08\x08"); // mode 45 off: clamps
    try testing.expectEqual(@as(u16, 1), t.active().cursor.row);
    try testing.expectEqual(@as(u16, 0), t.active().cursor.col);

    t.feed("\x1b[?45h\x1b[?7l\x08"); // DECAWM off: still clamps
    try testing.expectEqual(@as(u16, 1), t.active().cursor.row);
    try testing.expectEqual(@as(u16, 0), t.active().cursor.col);
}

test "mode 45: DECSTR keeps it (VT510 DECSTR table)" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[?45h\x1b[!p");
    try testing.expect(t.active().mode.reverse_wrap);
}

test "mode 45: erasing the wrapped row ends the soft wrap" {
    var t = try Term.create(alloc);
    defer t.destroy(alloc);

    t.feed("\x1b[?45h");
    feedSoftWrappedLine(&t);
    t.feed("\x1b[A\x1b[2K\x1b[B\x08\x08");
    try testing.expectEqual(@as(u16, 1), t.active().cursor.row);
    try testing.expectEqual(@as(u16, 0), t.active().cursor.col);
}
