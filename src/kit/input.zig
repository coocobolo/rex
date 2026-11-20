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
const focus = @import("focus.zig");
const text_mod = @import("text.zig");
const Tree = @import("Tree.zig");
const Id = Tree.Id;

pub const min_width: f32 = 160;
pub const caret_width: f32 = 1.5;
pub const caret_height: f32 = 16;

/// Worst-case nodes written by `view`: ring, face, clip, content,
/// selection overlay (layer, prefix, box, text), visible text, and caret
/// overlay (layer, prefix, caret).
pub const node_max = 12;

pub const Command = enum {
    backspace,
    delete,
    delete_word_backward,
    delete_word_forward,
    delete_to_start,
    delete_to_end,
    left,
    right,
    select_left,
    select_right,
    word_left,
    word_right,
    select_word_left,
    select_word_right,
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
            .delete_word_backward => self.deleteWordBackward(),
            .delete_word_forward => self.deleteWordForward(),
            .delete_to_start => self.deleteToStart(),
            .delete_to_end => self.deleteToEnd(),
            .left => self.moveLeft(false),
            .right => self.moveRight(false),
            .select_left => self.moveLeft(true),
            .select_right => self.moveRight(true),
            .word_left => self.moveWordLeft(false),
            .word_right => self.moveWordRight(false),
            .select_word_left => self.moveWordLeft(true),
            .select_word_right => self.moveWordRight(true),
            .home => self.moveHome(false),
            .end => self.moveEnd(false),
            .select_home => self.moveHome(true),
            .select_end => self.moveEnd(true),
            .select_all => self.selectAll(),
        };
    }

    /// Moves the cursor to the UTF-8 boundary at or before `offset`.
    /// Keeps `anchor` when `extend` is true; otherwise collapses any selection.
    pub fn setCursor(self: *State, offset: usize, extend: bool) bool {
        const before_cursor = self.cursor;
        const before_anchor = self.anchor;
        const next = snapBoundary(self.buf.items, offset);
        self.cursor = next;
        if (!extend) self.anchor = next;
        return self.cursor != before_cursor or self.anchor != before_anchor;
    }

    /// Selects the contiguous word, punctuation, or whitespace run containing
    /// `offset` (used on double-click).
    pub fn selectWordAt(self: *State, offset: usize) bool {
        const before_cursor = self.cursor;
        const before_anchor = self.anchor;
        const range = wordRangeAt(self.buf.items, offset);
        self.anchor = range.start;
        self.cursor = range.end;
        return self.cursor != before_cursor or self.anchor != before_anchor;
    }

    /// Extends a double-click word selection from `[base_start, base_end]` to
    /// cover the word run at `offset`.
    pub fn extendWordSelection(self: *State, base_start: usize, base_end: usize, offset: usize) bool {
        const before_cursor = self.cursor;
        const before_anchor = self.anchor;
        const clamped_start = snapBoundary(self.buf.items, @min(base_start, base_end));
        const clamped_end = snapBoundary(self.buf.items, @max(base_start, base_end));
        const range = wordRangeAt(self.buf.items, offset);
        if (range.start < clamped_start) {
            self.anchor = clamped_end;
            self.cursor = range.start;
        } else if (range.end > clamped_end) {
            self.anchor = clamped_start;
            self.cursor = range.end;
        } else {
            self.anchor = clamped_start;
            self.cursor = clamped_end;
        }
        return self.cursor != before_cursor or self.anchor != before_anchor;
    }

    /// Returns the nearest UTF-8 codepoint boundary to `local_x` (logical
    /// pixels from the start of the text), using `measurer` with `.sm` style.
    pub fn offsetAtX(self: *const State, measurer: text_mod.Measurer, local_x: f32) usize {
        const bytes = self.buf.items;
        if (bytes.len == 0 or local_x <= 0) return 0;
        const full_w = measurer.width(bytes, .sm, .proportional);
        if (local_x >= full_w) return bytes.len;

        // Binary-search the largest codepoint boundary whose prefix width <= local_x.
        var lo: usize = 0;
        var hi: usize = bytes.len;
        while (lo < hi) {
            const raw_mid = lo + (hi - lo + 1) / 2;
            const mid = snapBoundary(bytes, raw_mid);
            const probe = if (mid <= lo) nextBoundary(bytes, lo) else mid;
            if (probe >= hi) break;
            if (measurer.width(bytes[0..probe], .sm, .proportional) <= local_x) {
                lo = probe;
            } else {
                hi = probe;
            }
        }
        const next = nextBoundary(bytes, lo);
        if (next == lo) return lo;
        const lo_w = if (lo == 0) 0 else measurer.width(bytes[0..lo], .sm, .proportional);
        const next_w = measurer.width(bytes[0..next], .sm, .proportional);
        return if (local_x - lo_w <= next_w - local_x) lo else next;
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

    fn deleteWordBackward(self: *State) bool {
        if (self.deleteSelection()) return true;
        if (self.cursor == 0) return false;
        const prev = prevWordBoundary(self.buf.items, self.cursor);
        self.buf.replaceRangeAssumeCapacity(prev, self.cursor - prev, &.{});
        self.cursor = prev;
        self.anchor = prev;
        return true;
    }

    fn deleteWordForward(self: *State) bool {
        if (self.deleteSelection()) return true;
        if (self.cursor >= self.buf.items.len) return false;
        const next = nextWordBoundary(self.buf.items, self.cursor);
        self.buf.replaceRangeAssumeCapacity(self.cursor, next - self.cursor, &.{});
        return true;
    }

    fn deleteToStart(self: *State) bool {
        if (self.deleteSelection()) return true;
        if (self.cursor == 0) return false;
        self.buf.replaceRangeAssumeCapacity(0, self.cursor, &.{});
        self.cursor = 0;
        self.anchor = 0;
        return true;
    }

    fn deleteToEnd(self: *State) bool {
        if (self.deleteSelection()) return true;
        if (self.cursor >= self.buf.items.len) return false;
        self.buf.replaceRangeAssumeCapacity(self.cursor, self.buf.items.len - self.cursor, &.{});
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

    fn moveWordLeft(self: *State, extend: bool) bool {
        const before_cursor = self.cursor;
        const before_anchor = self.anchor;
        self.cursor = prevWordBoundary(self.buf.items, self.cursor);
        if (!extend) self.anchor = self.cursor;
        return self.cursor != before_cursor or self.anchor != before_anchor;
    }

    fn moveWordRight(self: *State, extend: bool) bool {
        const before_cursor = self.cursor;
        const before_anchor = self.anchor;
        self.cursor = nextWordBoundary(self.buf.items, self.cursor);
        if (!extend) self.anchor = self.cursor;
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

const CharClass = enum(u2) {
    space,
    word,
    punct,
};

fn charClassAt(bytes: []const u8, pos: usize) CharClass {
    const b = bytes[pos];
    if (b >= 0x80) return .word;
    if (b == ' ' or b == '\t') return .space;
    if ((b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z') or (b >= '0' and b <= '9') or b == '_') {
        return .word;
    }
    return .punct;
}

fn snapBoundary(bytes: []const u8, pos: usize) usize {
    var i = @min(pos, bytes.len);
    while (i > 0 and i < bytes.len and (bytes[i] & 0xC0) == 0x80) : (i -= 1) {}
    return i;
}

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

fn prevWordBoundary(bytes: []const u8, pos: usize) usize {
    var i = snapBoundary(bytes, pos);
    while (i > 0) {
        const prev = prevBoundary(bytes, i);
        if (charClassAt(bytes, prev) != .space) break;
        i = prev;
    }
    if (i == 0) return 0;
    const cls = charClassAt(bytes, prevBoundary(bytes, i));
    while (i > 0) {
        const prev = prevBoundary(bytes, i);
        if (charClassAt(bytes, prev) != cls) break;
        i = prev;
    }
    return i;
}

fn nextWordBoundary(bytes: []const u8, pos: usize) usize {
    var i = snapBoundary(bytes, pos);
    while (i < bytes.len and charClassAt(bytes, i) == .space) {
        i = nextBoundary(bytes, i);
    }
    if (i >= bytes.len) return bytes.len;
    const cls = charClassAt(bytes, i);
    while (i < bytes.len and charClassAt(bytes, i) == cls) {
        i = nextBoundary(bytes, i);
    }
    return i;
}

fn wordRangeAt(bytes: []const u8, pos: usize) struct { start: usize, end: usize } {
    if (bytes.len == 0) return .{ .start = 0, .end = 0 };
    var idx = snapBoundary(bytes, pos);
    if (idx >= bytes.len) idx = prevBoundary(bytes, bytes.len);
    const cls = charClassAt(bytes, idx);
    var start = idx;
    while (start > 0) {
        const prev = prevBoundary(bytes, start);
        if (charClassAt(bytes, prev) != cls) break;
        start = prev;
    }
    var end = nextBoundary(bytes, idx);
    while (end < bytes.len and charClassAt(bytes, end) == cls) {
        end = nextBoundary(bytes, end);
    }
    return .{ .start = start, .end = end };
}

/// Returns the laid-out screen-space `x` coordinate of byte `0` for the input
/// built with `id` in `tree` (accounting for alignment and horizontal scroll),
/// or `null` if `id` is not present.
pub fn textOriginX(tree: *const Tree, id: Id) ?f32 {
    for (tree.items(), 0..) |node, i| {
        if (node.box.id != id) continue;
        // `view` emits ring -> face -> clip -> content (for non-empty text).
        const clip_idx = i + 2;
        if (clip_idx >= tree.len) return null;
        const clip = tree.nodes[clip_idx];
        const first_idx = clip_idx + 1;
        if (first_idx >= clip.end) return clip.rect.x;
        return tree.nodes[first_idx].rect.x;
    }
    return null;
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
    width: Tree.Size = .{ .at_least = min_width },
    height: u8 = Theme.control_sm,
    hovered: bool = false,
    focused: bool = false,
    invalid: bool = false,
    disabled: bool = false,
    center: bool = false,
    borderless: bool = false,
};

pub fn view(tree: *Tree, theme: *const Theme, options: Options) Tree.Error!void {
    const presence: f32 = if (options.disabled) 0.5 else 1.0;
    const active = options.focused and !options.disabled;
    const colors = focus.controlColors(theme, .{
        .focused = options.focused,
        .hovered = options.hovered,
        .invalid = options.invalid,
        .disabled = options.disabled,
    });

    const ring = if (options.borderless) try tree.open(.{
        .id = options.id,
        .width = if (options.width == .fill) .fill else .fit,
        .pointer = if (options.disabled) .arrow else .text,
    }) else try focus.openRing(tree, .{
        .id = options.id,
        .width = if (options.width == .fill) .fill else .fit,
        .pointer = if (options.disabled) .arrow else .text,
        .border = colors.ring,
    });

    const face = try tree.open(.{
        .axis = .row,
        .width = options.width,
        .height = .{ .fixed = options.height },
        .padding = .symmetric(12, 0),
        .cross = .center,
        .fill = if (options.borderless) .transparent else theme.background.fade(presence),
        .border = if (options.borderless) Theme.Color.transparent else colors.border,
        .border_width = if (options.borderless) 0 else Theme.border_width,
        .radius = if (options.borderless) 0 else Theme.radius_md,
    });

    const clip = try tree.open(.{
        .axis = .row,
        .width = .fill,
        .height = .fill,
        .main = if (options.center) .center else .start,
        .cross = .center,
        .overflow = .clip,
    });

    const text_color = theme.foreground.fade(presence);
    var caret_index: Tree.Index = Tree.none;
    if (options.value.len == 0) {
        if (active) caret_index = try emitCaret(tree, theme);
        if (options.placeholder.len > 0) {
            _ = try tree.text(options.placeholder, .{
                .color = theme.muted_foreground.fade(presence),
                .wrap = .none,
            });
        }
    } else {
        const content = try tree.open(.{
            .axis = .row,
            .width = .fit,
            .height = .fill,
            .padding = if (options.center) .zero else .{ .right = 2 },
            .cross = .center,
            .shrink = false,
        });
        const cursor = @min(options.cursor, options.value.len);
        const anchor = @min(options.anchor, options.value.len);

        // Selection highlight renders in an overlay behind the single unsplit
        // text node so moving the caret or changing selection never shifts
        // surrounding glyphs or breaks pair kerning.
        if (active and anchor != cursor) {
            const start = @min(anchor, cursor);
            const end = @max(anchor, cursor);
            const sel_layer = try tree.open(.{
                .axis = .row,
                .height = .fill,
                .cross = .center,
                .overlay = true,
            });
            if (start > 0) {
                _ = try tree.text(options.value[0..start], .{
                    .color = .transparent,
                    .wrap = .none,
                    .shrink = false,
                });
            }
            const sel_box = try tree.open(.{
                .fill = theme.primary.fade(0.25),
                .radius = 2,
                .shrink = false,
            });
            _ = try tree.text(options.value[start..end], .{
                .color = .transparent,
                .wrap = .none,
                .shrink = false,
            });
            tree.close(sel_box);
            tree.close(sel_layer);
        }

        _ = try tree.text(options.value, .{
            .color = text_color,
            .wrap = .none,
            .shrink = false,
        });

        if (active) {
            const caret_layer = try tree.open(.{
                .axis = .row,
                .height = .fill,
                .cross = .center,
                .overlay = true,
            });
            if (cursor > 0) {
                _ = try tree.text(options.value[0..cursor], .{
                    .color = .transparent,
                    .wrap = .none,
                    .shrink = false,
                });
            }
            caret_index = try emitCaret(tree, theme);
            tree.close(caret_layer);
        }
        tree.close(content);
    }

    tree.close(clip);
    if (active and caret_index != Tree.none) {
        try tree.scrollRegion(clip, .{});
        tree.scrollFollow(caret_index);
    }
    tree.close(face);
    tree.close(ring);
}

fn emitCaret(tree: *Tree, theme: *const Theme) Tree.Error!Tree.Index {
    const caret = try tree.open(.{
        .width = .{ .fixed = caret_width },
        .height = .{ .fixed = caret_height },
        .fill = theme.foreground,
        .shrink = false,
    });
    tree.close(caret);
    return caret;
}
