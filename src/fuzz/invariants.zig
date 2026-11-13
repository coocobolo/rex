//! Checks that hold for a `Terminal` after any input, shared by the
//! terminal and strings targets.

const std = @import("std");
const testing = std.testing;

const term = @import("../term/term.zig");

/// Fails unless `t` (a `*Terminal(option)`) is in a sane state:
/// cursor and margins inside the active area of both screens, the reply
/// queue, string buffers and title within their capacity, parser counts
/// within their caps, each grapheme intern table within its bound,
/// every style ID in a live cell live in its screen's table, and no wide
/// character in the active area missing one of its halves.
pub fn expectTerminal(t: anytype) !void {
    try expectScreen(&t.primary);
    try expectScreen(&t.alternate);
    try testing.expect(t.response.len <= term.Response.capacity);
    try testing.expect(t.osc_len <= t.osc_buf.len);
    try testing.expect(t.dcs_len <= t.dcs_buf.len);
    try testing.expect(t.getTitle().len <= term.max_title_len);
    try testing.expect(t.getIconName().len <= term.max_title_len);
    try testing.expect(t.answerback_len <= term.max_answerback_len);
    try testing.expect(t.parser.param_len <= t.parser.params.len);
    try testing.expect(t.parser.intermediate_len <= t.parser.intermediates.len);
}

fn expectScreen(s: anytype) !void {
    const Screen = @TypeOf(s.*);
    if (s.active_rows > 0 and s.active_cols > 0) {
        try testing.expect(s.cursor.row < s.active_rows);
        try testing.expect(s.cursor.col < s.active_cols);
        try testing.expect(s.scroll_top <= s.scroll_bottom);
        try testing.expect(s.scroll_bottom < s.active_rows);
    }
    // The intern table compacts before it passes `grapheme_compact_at`,
    // which is twice the live clusters, and no more clusters can be live
    // than there are cells.
    const count = s.grapheme_table.count();
    try testing.expect(count <= s.grapheme_compact_at);
    try testing.expect(s.grapheme_compact_at <= @max(Screen.grapheme_compact_min, 2 * s.cells.len));
    try expectStyles(s);
    try expectWidePairs(s);
}

/// In every active row, a wide character's left half is followed by its
/// right half and a right half follows a left half (#67). A row narrower
/// than two columns can't hold both halves; reflow keeps the character
/// there so a wider size shows it again.
fn expectWidePairs(s: anytype) !void {
    if (s.active_cols < 2) return;
    for (0..s.active_rows) |r| {
        const cells = s.row(r)[0..s.active_cols];
        for (cells, 0..) |cell, i| {
            if (cell.kind.isWideLeft()) {
                try testing.expect(i + 1 < cells.len and cells[i + 1].kind == .wide_right);
            }
            if (cell.kind == .wide_right) {
                try testing.expect(i > 0 and cells[i - 1].kind.isWideLeft());
            }
        }
    }
}

/// Every live cell (`liveRows`: scrollback and active area, active
/// columns) and the pen hold a live style ID (ADR 0005): no ID in use
/// was swept or reset. Dead cells are cleared before they are shown, so
/// their IDs are not checked; a row shown without that clear fails here
/// once its styles are swept. The pen's IDs match its colors unless the
/// table is full, when `internStyle` falls back to the nearest live
/// style; its blank style is background-only either way, or the default.
fn expectStyles(s: anytype) !void {
    const table = &s.styles;
    var rows = s.liveRows();
    while (rows.next()) |cells| for (cells) |cell| try expectLive(table, cell.style);
    const attr = s.cursor.attr;
    try expectLive(table, attr.id);
    try expectLive(table, attr.blank_id);
    const full = table.count() == @TypeOf(table.*).capacity - 1;
    if (!full) {
        try testing.expect(table.get(attr.id).eql(attr.colors));
        try testing.expect(table.get(attr.blank_id).eql(.{ .bg = attr.colors.bg }));
    }
}

fn expectLive(table: anytype, id: anytype) !void {
    if (id == 0) return;
    try testing.expect(id < table.high);
    try testing.expect(table.live.isSet(id));
}

/// Fails unless `a` and `b` (two `*Terminal(option)`) show the same
/// thing: the same screen, rows, cells (graphemes compared by content),
/// cursors and title. Used to check that how bytes are split across
/// `feed` calls does not change the result.
pub fn expectSameTerminal(a: anytype, b: anytype) !void {
    try testing.expectEqual(a.active_buffer, b.active_buffer);
    try testing.expectEqualStrings(a.getTitle(), b.getTitle());
    try expectSameScreen(&a.primary, &b.primary);
    try expectSameScreen(&a.alternate, &b.alternate);
}

fn expectSameScreen(a: anytype, b: anytype) !void {
    try testing.expectEqual(a.active_rows, b.active_rows);
    try testing.expectEqual(a.active_cols, b.active_cols);
    try testing.expectEqual(a.cursor, b.cursor);
    try testing.expectEqual(a.saved_cursor, b.saved_cursor);
    try testing.expectEqual(a.scroll_top, b.scroll_top);
    try testing.expectEqual(a.scroll_bottom, b.scroll_bottom);
    for (0..a.active_rows) |r| {
        for (a.row(r), b.row(r)) |ca, cb| {
            if (ca.kind.isGrapheme() and cb.kind.isGrapheme()) {
                try testing.expectEqual(@as(u64, @bitCast(withCodepoint(ca, 0))), @as(u64, @bitCast(withCodepoint(cb, 0))));
                try testing.expectEqualSlices(u21, a.getGrapheme(ca.codepoint) orelse &.{}, b.getGrapheme(cb.codepoint) orelse &.{});
            } else {
                try testing.expectEqual(@as(u64, @bitCast(ca)), @as(u64, @bitCast(cb)));
            }
        }
    }
}

fn withCodepoint(cell: anytype, cp: u32) @TypeOf(cell) {
    var c = cell;
    c.codepoint = cp;
    return c;
}
