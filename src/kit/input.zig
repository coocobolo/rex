//! Single-line text input: editing state (`State`) and stateless `view`.
//!
//! `State` owns a UTF-8 byte buffer (`ArrayListUnmanaged(u8)`), a byte
//! cursor offset, and a selection anchor offset (`anchor == cursor` means no
//! selection). Both offsets are always kept on valid UTF-8 codepoint
//! boundaries. Clipboard I/O stays with the caller (`selectedText` +
//! `deleteSelection` for cut, `insertSlice` for paste).

const std = @import("std");
const Allocator = std.mem.Allocator;

const Theme = @import("Theme.zig");
const tree_zig = @import("tree.zig");
const Tree = tree_zig.Tree;
const Id = tree_zig.Id;

pub const min_width: f32 = 160;
pub const caret_width: f32 = 1.5;
pub const caret_height: f32 = 16;

/// Worst-case nodes written by `view`: ring, face, clip row, before text,
/// caret, selection wrapper + selected text, after text.
pub const node_max = 8;

pub const Command = enum {
    backspace,
    delete,
    left,
    right,
    select_left,
    select_right,
    home,
    end,
    select_home,
    select_end,
    select_all,
};

pub const State = struct {
    buf: std.ArrayListUnmanaged(u8) = .empty,
    /// Byte offset into `buf.items`, always on a UTF-8 codepoint boundary.
    cursor: usize = 0,
    /// Selection anchor byte offset; equals `cursor` when nothing is selected.
    anchor: usize = 0,

    pub fn initText(gpa: Allocator, initial: []const u8) Allocator.Error!State {
        var state: State = .{};
        errdefer state.deinit(gpa);
        try state.setText(gpa, initial);
        return state;
    }

    pub fn deinit(self: *State, gpa: Allocator) void {
        self.buf.deinit(gpa);
        self.* = .{};
    }

    pub fn text(self: *const State) []const u8 {
        return self.buf.items;
    }

    pub fn setText(self: *State, gpa: Allocator, value: []const u8) Allocator.Error!void {
        self.buf.clearRetainingCapacity();
        try self.buf.appendSlice(gpa, value);
        self.cursor = value.len;
        self.anchor = value.len;
    }

    pub fn hasSelection(self: *const State) bool {
        return self.anchor != self.cursor;
    }

    pub fn selectionRange(self: *const State) struct { start: usize, end: usize } {
        return .{
            .start = @min(self.anchor, self.cursor),
            .end = @max(self.anchor, self.cursor),
        };
    }

    pub fn selectedText(self: *const State) []const u8 {
        const range = self.selectionRange();
        return self.buf.items[range.start..range.end];
    }

    /// Removes the active selection without allocating. Returns whether any
    /// bytes were removed.
    pub fn deleteSelection(self: *State) bool {
        if (!self.hasSelection()) return false;
        const range = self.selectionRange();
        self.buf.replaceRangeAssumeCapacity(range.start, range.end - range.start, &.{});
        self.cursor = range.start;
        self.anchor = range.start;
        return true;
    }

    /// Inserts a single printable Unicode codepoint at the cursor, replacing
    /// any active selection. ASCII control characters are ignored.
    pub fn insertChar(self: *State, gpa: Allocator, cp: u21) Allocator.Error!bool {
        if (cp < 0x20 or cp == 0x7f) return false;
        var enc: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cp, &enc) catch return false;
        try self.replaceSelectionWith(gpa, enc[0..len]);
        return true;
    }

    /// Inserts pasted UTF-8 text at the cursor, replacing any active
    /// selection and stripping ASCII control characters (including newlines).
    pub fn insertSlice(self: *State, gpa: Allocator, raw: []const u8) Allocator.Error!bool {
        if (raw.len == 0) return false;

        var filtered: std.ArrayListUnmanaged(u8) = .empty;
        defer filtered.deinit(gpa);

        var i: usize = 0;
        while (i < raw.len) {
            const seq_len = std.unicode.utf8ByteSequenceLength(raw[i]) catch {
                i += 1;
                continue;
            };
            if (i + seq_len > raw.len) break;
            const cp = std.unicode.utf8Decode(raw[i .. i + seq_len]) catch {
                i += 1;
                continue;
            };
            i += seq_len;
            if (cp < 0x20 or cp == 0x7f) continue;
            try filtered.appendSlice(gpa, raw[i - seq_len .. i]);
        }

        if (filtered.items.len == 0 and !self.hasSelection()) return false;
        try self.replaceSelectionWith(gpa, filtered.items);
        return true;
    }

    /// Applies a non-allocating navigation or deletion command.
    pub fn apply(self: *State, cmd: Command) bool {
        return switch (cmd) {
            .backspace => self.backspace(),
            .delete => self.deleteForward(),
            .left => self.moveLeft(false),
            .right => self.moveRight(false),
            .select_left => self.moveLeft(true),
            .select_right => self.moveRight(true),
            .home => self.moveHome(false),
            .end => self.moveEnd(false),
            .select_home => self.moveHome(true),
            .select_end => self.moveEnd(true),
            .select_all => self.selectAll(),
        };
    }

    fn replaceSelectionWith(self: *State, gpa: Allocator, slice: []const u8) Allocator.Error!void {
        const range = self.selectionRange();
        try self.buf.replaceRange(gpa, range.start, range.end - range.start, slice);
        const next = range.start + slice.len;
        self.cursor = next;
        self.anchor = next;
    }

    fn backspace(self: *State) bool {
        if (self.deleteSelection()) return true;
        if (self.cursor == 0) return false;
        const prev = prevBoundary(self.buf.items, self.cursor);
        self.buf.replaceRangeAssumeCapacity(prev, self.cursor - prev, &.{});
        self.cursor = prev;
        self.anchor = prev;
        return true;
    }

    fn deleteForward(self: *State) bool {
        if (self.deleteSelection()) return true;
        if (self.cursor >= self.buf.items.len) return false;
        const next = nextBoundary(self.buf.items, self.cursor);
        self.buf.replaceRangeAssumeCapacity(self.cursor, next - self.cursor, &.{});
        return true;
    }

    fn moveLeft(self: *State, extend: bool) bool {
        const before_cursor = self.cursor;
        const before_anchor = self.anchor;
        if (!extend and self.hasSelection()) {
            self.cursor = self.selectionRange().start;
            self.anchor = self.cursor;
        } else {
            self.cursor = prevBoundary(self.buf.items, self.cursor);
            if (!extend) self.anchor = self.cursor;
        }
        return self.cursor != before_cursor or self.anchor != before_anchor;
    }

    fn moveRight(self: *State, extend: bool) bool {
        const before_cursor = self.cursor;
        const before_anchor = self.anchor;
        if (!extend and self.hasSelection()) {
            self.cursor = self.selectionRange().end;
            self.anchor = self.cursor;
        } else {
            self.cursor = nextBoundary(self.buf.items, self.cursor);
            if (!extend) self.anchor = self.cursor;
        }
        return self.cursor != before_cursor or self.anchor != before_anchor;
    }

    fn moveHome(self: *State, extend: bool) bool {
        const before_cursor = self.cursor;
        const before_anchor = self.anchor;
        self.cursor = 0;
        if (!extend) self.anchor = 0;
        return self.cursor != before_cursor or self.anchor != before_anchor;
    }

    fn moveEnd(self: *State, extend: bool) bool {
        const before_cursor = self.cursor;
        const before_anchor = self.anchor;
        self.cursor = self.buf.items.len;
        if (!extend) self.anchor = self.cursor;
        return self.cursor != before_cursor or self.anchor != before_anchor;
    }

    fn selectAll(self: *State) bool {
        const before_cursor = self.cursor;
        const before_anchor = self.anchor;
        self.anchor = 0;
        self.cursor = self.buf.items.len;
        return self.cursor != before_cursor or self.anchor != before_anchor;
    }
};

fn prevBoundary(bytes: []const u8, pos: usize) usize {
    var i = @min(pos, bytes.len);
    if (i == 0) return 0;
    i -= 1;
    while (i > 0 and (bytes[i] & 0xC0) == 0x80) : (i -= 1) {}
    return i;
}

fn nextBoundary(bytes: []const u8, pos: usize) usize {
    const i = @min(pos, bytes.len);
    if (i >= bytes.len) return bytes.len;
    const len = std.unicode.utf8ByteSequenceLength(bytes[i]) catch 1;
    return @min(i + len, bytes.len);
}

pub const Options = struct {
    /// On the outer focus-ring wrapper, for `Tree.hitTest`.
    id: Id,
    /// Borrowed until the view is rebuilt.
    value: []const u8,
    /// Shown in muted text when `value` is empty.
    placeholder: []const u8 = "",
    cursor: usize = 0,
    anchor: usize = 0,
    width: tree_zig.Size = .{ .at_least = min_width },
    height: u8 = Theme.control_sm,
    hovered: bool = false,
    focused: bool = false,
    invalid: bool = false,
    disabled: bool = false,
};

pub fn view(tree: *Tree, theme: *const Theme, options: Options) tree_zig.Error!void {
    const presence: f32 = if (options.disabled) 0.5 else 1.0;
    const active = options.focused and !options.disabled;
    const ring_color = if (!active)
        Theme.Color.transparent
    else if (options.invalid)
        theme.destructive.alpha(Theme.ring_opacity)
    else
        theme.ring.alpha(Theme.ring_opacity);

    const border_color = if (options.invalid)
        theme.destructive.fade(presence)
    else if (active)
        theme.ring.fade(presence)
    else if (options.hovered and !options.disabled)
        theme.foreground.fade(0.35)
    else
        theme.input.fade(presence);

    const ring = try tree.open(.{
        .id = options.id,
        .pointer = if (options.disabled) .arrow else .text,
        .padding = .all(Theme.ring_width),
        .border = ring_color,
        .border_width = Theme.ring_width,
        .radius = Theme.radius_md + Theme.ring_width,
    });

    const face = try tree.open(.{
        .axis = .row,
        .width = options.width,
        .height = .{ .fixed = options.height },
        .padding = .symmetric(12, 0),
        .cross = .center,
        .fill = theme.background.fade(presence),
        .border = border_color,
        .border_width = Theme.border_width,
        .radius = Theme.radius_md,
    });

    const clip = try tree.open(.{
        .axis = .row,
        .width = .fill,
        .height = .fill,
        .cross = .center,
        .overflow = .clip,
    });

    const text_color = theme.foreground.fade(presence);
    if (options.value.len == 0) {
        if (active) try emitCaret(tree, theme);
        if (options.placeholder.len > 0) {
            _ = try tree.text(options.placeholder, .{
                .color = theme.muted_foreground.fade(presence),
            });
        }
    } else if (!active) {
        _ = try tree.text(options.value, .{ .color = text_color });
    } else {
        const cursor = @min(options.cursor, options.value.len);
        const anchor = @min(options.anchor, options.value.len);
        if (anchor == cursor) {
            if (cursor > 0) {
                _ = try tree.text(options.value[0..cursor], .{ .color = text_color });
            }
            try emitCaret(tree, theme);
            if (cursor < options.value.len) {
                _ = try tree.text(options.value[cursor..], .{ .color = text_color });
            }
        } else {
            const start = @min(anchor, cursor);
            const end = @max(anchor, cursor);
            if (start > 0) {
                _ = try tree.text(options.value[0..start], .{ .color = text_color });
            }
            if (cursor == start) try emitCaret(tree, theme);
            const sel_box = try tree.open(.{
                .fill = theme.primary.fade(0.25),
                .radius = 2,
            });
            _ = try tree.text(options.value[start..end], .{ .color = text_color });
            tree.close(sel_box);
            if (cursor == end) try emitCaret(tree, theme);
            if (end < options.value.len) {
                _ = try tree.text(options.value[end..], .{ .color = text_color });
            }
        }
    }

    tree.close(clip);
    tree.close(face);
    tree.close(ring);
}

fn emitCaret(tree: *Tree, theme: *const Theme) tree_zig.Error!void {
    const caret = try tree.open(.{
        .width = .{ .fixed = caret_width },
        .height = .{ .fixed = caret_height },
        .fill = theme.foreground,
    });
    tree.close(caret);
}
