const std = @import("std");

const root = @import("root.zig");

const ScreenType = @import("app.zig").ScreenType;
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
};

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

pub inline fn has_selection(self: *const Selection) bool {
    // if phase == .selected (not dragging) but start.col, dragged should still returns true.
    return self.phase == .dragging or self.phase == .selected;
}

pub inline fn dragged(self: *Selection) bool {
    return self.has_selection() and self.range.isExtended();
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
