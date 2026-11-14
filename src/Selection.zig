const std = @import("std");

const root = @import("root.zig");

const ScreenType = @import("App.zig").ScreenType;
const Classifier = root.unicode.Classifier;

/// A single selection endpoint with a fields row and column.
///
/// row is a viewport independent scroll anchor, not a display row.
/// At capture time, anchor=(dipslay_row - viewport_offset).
/// When rendering or using the position, convert it back with the current
/// viewport offset: display_row = (row + viewport_offset)
///
/// This keeps tthe position stable while scrolling. The row may be negative
/// when the endpoint is above the live view, so it's signed.
/// A viewport reset cause by new PTY output invalidates the position because
/// its anchor may refer to evicted scrollback.
pub const Position = struct {
    /// Viewport-independent scroll anchor.
    row: i32,

    /// Zero-based column within the active area.
    col: u16,

    /// Value of `Screen.total_lines_scrolled` when this position was captured.
    ///
    /// Used to detect scrolling or scrollback eviction before the position is
    /// resolved. Its type matches total_lines_scrolled so the difference can be
    /// calculated directly.
    captured_scroll_gen: i64 = 0,

    pub const empty: Position = .{ .col = 0, .row = 0 };

    /// Sets an anchor row and column.
    ///
    /// row must already be an anchor value, not a display row.
    pub fn set(self: *Position, row: i32, col: u16, scroll_gen: i64) void {
        self.row = row;
        self.col = col;
        self.captured_scroll_gen = scroll_gen;
    }

    /// Resolves this position's anchor row in scrollback history space, returning null if evicted.
    pub inline fn resolve(self: Position, total_lines_scrolled: i64, scrollback_used: i64) ?i64 {
        return resolveAnchor(self, total_lines_scrolled, scrollback_used);
    }
};

/// Resolves an anchor row in scrollback history space, returning null if evicted.
pub fn resolveAnchor(position: anytype, total_lines_scrolled: i64, scrollback_used: i64) ?i64 {
    const delta: i64 = total_lines_scrolled - position.captured_scroll_gen;
    const anchor_now: i64 = @as(i64, position.row) - delta;
    if (anchor_now < -scrollback_used) return null;
    return anchor_now;
}

/// Extracts UTF-8 text within `selection` from `screen` into `buf`.
/// Performs zero dynamic allocations; returns number of bytes written.
pub fn extractText(screen: anytype, selection: anytype, buf: []u8) usize {
    const total_lines_scrolled = screen.total_lines_scrolled;
    const scrollback_used = screen.scrollbackUsedAs(i64);

    const start_anchor = resolveAnchor(selection.range.start, total_lines_scrolled, scrollback_used) orelse return 0;
    const end_anchor = resolveAnchor(selection.range.end, total_lines_scrolled, scrollback_used) orelse return 0;

    const start_col: u16 = @intCast(selection.range.start.col);
    const end_col: u16 = @intCast(selection.range.end.col);

    const lo_anchor, const lo_col, const hi_anchor, const hi_col = blk: {
        if (start_anchor < end_anchor or (start_anchor == end_anchor and start_col <= end_col)) {
            break :blk .{ start_anchor, start_col, end_anchor, end_col };
        } else {
            break :blk .{ end_anchor, end_col, start_anchor, start_col };
        }
    };

    const active_rows: i64 = @intCast(screen.active_rows);
    const clamped_lo: i64 = std.math.clamp(lo_anchor, -scrollback_used, active_rows - 1);
    const clamped_hi: i64 = std.math.clamp(hi_anchor, -scrollback_used, active_rows - 1);
    if (clamped_hi < clamped_lo) return 0;

    const is_block = selection.kind == .block;
    const block_left = @min(start_col, end_col);
    const block_right = @min(@max(start_col, end_col), @max(screen.active_cols, 1) - 1);

    var pos: usize = 0;
    var anchor_row: i64 = clamped_lo;
    while (anchor_row <= clamped_hi) : (anchor_row += 1) {
        var col_start: usize = if (is_block) block_left else (if (anchor_row == clamped_lo) lo_col else 0);
        const col_end: usize = if (is_block) block_right else (if (anchor_row == clamped_hi) hi_col else @max(screen.active_cols, 1) - 1);

        if (col_start > 0) {
            const maybe_placeholder = screen.cellAtAnchor(anchor_row, col_start);
            if (maybe_placeholder.kind == .wide_right) col_start -= 1;
        }

        const row_start = pos;

        for (col_start..col_end + 1) |col| {
            const cell = screen.cellAtAnchor(anchor_row, col);
            if (pos + 4 > buf.len) break;

            switch (cell.kind) {
                .wide_right => continue,
                .empty => {
                    buf[pos] = ' ';
                    pos += 1;
                },
                .narrow, .wide_left => {
                    const cp: u21 = std.math.cast(u21, cell.codepoint) orelse ' ';
                    const len = std.unicode.utf8Encode(cp, buf[pos..][0..4]) catch continue;
                    pos += len;
                },
                .grapheme, .grapheme_wide => {
                    const cps = screen.getGrapheme(cell.codepoint) orelse continue;
                    for (cps) |cp| {
                        if (pos + 4 > buf.len) break;
                        const len = std.unicode.utf8Encode(cp, buf[pos..][0..4]) catch continue;
                        pos += len;
                    }
                },
            }
        }

        while (pos > row_start and buf[pos - 1] == ' ') pos -= 1;

        const is_wrapped = !is_block and (screen.active_cols > 0) and screen.cellAtAnchor(anchor_row, screen.active_cols - 1).wrapped;
        if (!is_wrapped and anchor_row < clamped_hi and pos < buf.len - 1) {
            buf[pos] = '\n';
            pos += 1;
        }
    }

    return pos;
}

pub const Phase = enum {
    /// Nothing selected.
    none,

    /// Left Mouse Button being held.
    dragging,

    /// Left Mouse Button released, selection persists.
    selected,
};

pub const Kind = enum {
    /// Single-click and drag, snaps to a single character.
    /// Single-click released, character selection ready for an action to handle.
    character,

    /// Double-click and drag, snaps to word boundaries.
    /// Double-click released, word selection ready for an action to handle.
    word,

    /// Triple-click and drag, snaps to full lines selection.
    /// Triple-click released, snaps to full lines selection.
    line,

    /// Alt+drag, snaps rectangular block selection.
    /// block selection ready.
    block,
};

pub const Range = struct {
    start: Position,
    end: Position,

    pub inline fn isExtended(self: *const Range) bool {
        return self.start.row != self.end.row or self.start.col != self.end.col;
    }

    pub fn set(self: *Range, comptime target: enum { start, end }, position: Position) bool {
        switch (target) {
            .start => {
                if (std.meta.eql(self.start, position)) return false;
                self.start = position;
            },
            .end => {
                if (std.meta.eql(self.end, position)) return false;
                self.end = position;
            },
        }

        return true;
    }
};

pub const Selection = @This();

kind: Kind,
phase: Phase,
range: Range,

pub const empty: Selection = .{
    .kind = .character,
    .phase = .none,
    .range = .{ .start = .empty, .end = .empty },
};

pub inline fn hasSelection(self: *const Selection) bool {
    // if phase == .selected (not dragging) but start.col, dragged should still returns true.
    return self.phase == .dragging or self.phase == .selected;
}

pub inline fn dragged(self: *Selection) bool {
    return self.hasSelection() and self.range.isExtended();
}

/// Sets the initial (zero-width or kind-snapped) range for a fresh press,
/// given the already-resolved anchor/col and this selection's kind.
pub fn beginPress(
    self: *Selection,
    screen: *const ScreenType,
    classifier: *const Classifier,
    anchor: i32,
    col: u16,
    scroll_gen: i64,
) void {
    switch (self.kind) {
        .character, .block => {
            self.range.start.set(anchor, col, scroll_gen);
            self.range.end.set(anchor, col, scroll_gen);
        },
        .word => {
            const left, const right = screen.wordsBoundsAt(classifier, anchor, col, classifier.option.join);
            self.range.start.set(anchor, left, scroll_gen);
            self.range.end.set(anchor, right, scroll_gen);
        },
        .line => {
            const last_col = screen.active_cols - 1;
            self.range.start.set(anchor, 0, scroll_gen);
            self.range.end.set(anchor, last_col, scroll_gen);
        },
    }
}
