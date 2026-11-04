//! Checks that hold for a `Terminal` after any input, shared by the
//! terminal and strings targets.

const std = @import("std");
const testing = std.testing;

const term = @import("../term/term.zig");

/// Fails unless `t` (a `*Terminal(option)`) is in a sane state:
/// cursor and margins inside the active area of both screens, the reply
/// queue, string buffers and title within their capacity, parser counts
/// within their caps, and each grapheme intern table within its bound.
pub fn expectTerminal(t: anytype) !void {
    try expectScreen(&t.primary);
    try expectScreen(&t.alternate);
    try testing.expect(t.response.len <= term.Response.capacity);
    try testing.expect(t.osc_len <= t.osc_buf.len);
    try testing.expect(t.dcs_len <= t.dcs_buf.len);
    try testing.expect(t.title_len <= term.max_title_len);
    try testing.expect(t.icon_name_len <= term.max_title_len);
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
}

/// Fails unless `a` and `b` (two `*Terminal(option)`) show the same
/// thing: the same screen, rows, cells (graphemes compared by content),
/// cursors and title. Used to check that how bytes are split across
/// `feed` calls does not change the result.
pub fn expectSameTerminal(a: anytype, b: anytype) !void {
    try testing.expectEqual(a.active_buffer, b.active_buffer);
    try testing.expectEqualStrings(a.title[0..a.title_len], b.title[0..b.title_len]);
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
