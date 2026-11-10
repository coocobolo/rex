//! Pure viewport snapshot of visible terminal cells and metadata.
//!
//! A `Frame` is plain data. It holds no pointers into the terminal or screen
//! ring buffers and can be safely handed to another thread.
//!
//! Viewport rows are normalized to row 0 (so scrollback offsets are resolved
//! at snapshot time). Cells are stored in a flat contiguous buffer with 64-byte
//! cache-line alignment.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Cell = @import("cell.zig").Cell;
const Cursor = @import("Cursor.zig");
const Palette = @import("Palette.zig").Palette;
const Style = @import("Style.zig");
const Option = @import("term.zig").Option;
const Classifier = @import("../unicode/Classifier.zig");

/// Maximum number of codepoints per grapheme cluster. Matches `Screen.max_cluster_len`.
pub const max_cluster_len = 16;

/// Bounded capacity for grapheme clusters visible within a single frame.
pub const max_frame_graphemes = 256;

/// Single grapheme entry in the frame's side-table.
pub const GraphemeEntry = struct {
    id: u32,
    len: u8,
    cps: [max_cluster_len]u21,
};

/// Cursor state captured for a viewport frame.
pub const CursorSnapshot = struct {
    row: u16 = 0,
    col: u16 = 0,
    style: Cursor.Style = .default,
    visible: bool = true,

    pub inline fn position(self: CursorSnapshot) struct { u16, u16 } {
        return .{ self.row, self.col };
    }
};

/// A pure viewport snapshot parameterized by terminal capacity `Option`.
pub fn Frame(comptime option: Option) type {
    const max_rows = option.max_rows;
    const max_cols = option.max_cols;
    const max_cells = max_rows * max_cols;

    return struct {
        const Self = @This();

        /// Flat viewport cells buffer, 64-byte aligned (matching CPU cache lines).
        /// Display row `r` begins at `r * max_cols`.
        cells: []align(64) Cell,

        /// Active viewport dimensions (<= max_rows, <= max_cols).
        active_rows: u16 = @intCast(max_rows),
        active_cols: u16 = @intCast(max_cols),

        /// Bitset of display rows modified since the last snapshot.
        dirty_rows: std.bit_set.StaticBitSet(max_rows) = .empty,

        /// Monotonic generation counter corresponding to terminal/screen generation.
        generation: u32 = 0,

        /// Active color palette for this viewport snapshot.
        palette: Palette = Palette.empty,

        /// Copy of the active screen's style table: `styles[0..style_len]`
        /// resolves every cell's `style`. Owned, allocated by `init` at full
        /// capacity (192 KiB) so copies never allocate (ADR 0005).
        styles: *[Style.Table.capacity]Style,
        style_len: u16 = 1,
        /// The table's `generation` when copied. With `is_alternate` it tells
        /// whether a copy is still exact.
        style_generation: u32 = 0,

        /// Cursor state mapped to viewport coordinates.
        cursor: CursorSnapshot = .{},

        /// Optional OSC 12 cursor color override.
        cursor_color: ?[3]u8 = null,

        /// Optional OSC 19 selection foreground override (RGB).
        selection_foreground: ?[3]u8 = null,

        /// Optional OSC 17 selection background override (RGB).
        selection_background: ?[3]u8 = null,

        /// Reverse video mode (DECSCNM).
        reverse_video: bool = false,

        /// Whether the alternate screen buffer is active.
        is_alternate: bool = false,

        /// Scrollback lines available in terminal history.
        scrollback_used: u32 = 0,

        /// Viewport offset (0 = live view at bottom, >0 = viewing history).
        viewport_offset: u32 = 0,

        /// Total lines scrolled into history since startup.
        total_lines_scrolled: i64 = 0,

        /// Grapheme side-table for interned grapheme sequences visible in this frame.
        graphemes: [max_frame_graphemes]GraphemeEntry = undefined,
        grapheme_count: u16 = 0,

        pub const DirtyRange = struct {
            min: u16,
            max: u16, // inclusive
        };

        /// Returns the bounding range [min, max] of dirty display rows, or null if no rows are dirty.
        pub fn dirtyRange(self: *const Self) ?DirtyRange {
            const min = self.dirty_rows.findFirstSet() orelse return null;
            const max = self.dirty_rows.findLastSet() orelse min;
            return .{ .min = @intCast(min), .max = @intCast(max) };
        }

        /// Allocates cell memory with 64-byte alignment. Free with `deinit`.
        pub fn init(allocator: Allocator) !Self {
            const cells = try allocator.alignedAlloc(Cell, .@"64", max_cells);
            errdefer allocator.free(cells);
            @memset(cells, Cell{});
            const styles = try allocator.create([Style.Table.capacity]Style);
            styles[Style.Table.default_id] = .default;
            return .{
                .cells = cells,
                .styles = styles,
                .dirty_rows = .empty,
            };
        }

        /// Releases the memory allocated by `init`.
        pub fn deinit(self: *Self, allocator: Allocator) void {
            allocator.free(self.cells);
            allocator.destroy(self.styles);
        }

        /// Replaces the style table copy with `entries` (a table's
        /// `entries[0..high]`) taken at `generation`.
        pub fn copyStyles(self: *Self, entries: []const Style, generation: u32) void {
            @memcpy(self.styles[0..entries.len], entries);
            self.style_len = @intCast(entries.len);
            self.style_generation = generation;
        }

        /// The colors `cell` is drawn with.
        pub inline fn styleOf(self: *const Self, cell: Cell) Style {
            std.debug.assert(cell.style < self.style_len);
            return self.styles[cell.style];
        }

        /// Const slice of `active_cols` cells for viewport display row `r`.
        pub inline fn displayRow(self: *const Self, r: usize) []const Cell {
            std.debug.assert(r < max_rows);
            return self.cells[r * max_cols ..][0..self.active_cols];
        }

        /// Copies all cells and viewport metadata from `src` into `self`.
        pub fn copyFrom(self: *Self, src: *const Self) void {
            self.active_rows = src.active_rows;
            self.active_cols = src.active_cols;
            self.dirty_rows = src.dirty_rows;
            self.generation = src.generation;
            self.palette = src.palette;
            self.cursor = src.cursor;
            self.cursor_color = src.cursor_color;
            self.selection_foreground = src.selection_foreground;
            self.selection_background = src.selection_background;
            self.reverse_video = src.reverse_video;
            if (self.style_generation != src.style_generation or self.is_alternate != src.is_alternate) {
                self.copyStyles(src.styles[0..src.style_len], src.style_generation);
            }
            self.is_alternate = src.is_alternate;
            self.scrollback_used = src.scrollback_used;
            self.viewport_offset = src.viewport_offset;
            self.total_lines_scrolled = src.total_lines_scrolled;
            self.grapheme_count = src.grapheme_count;
            @memcpy(self.graphemes[0..src.grapheme_count], src.graphemes[0..src.grapheme_count]);
            const num_cells = @as(usize, src.active_rows) * max_cols;
            @memcpy(self.cells[0..num_cells], src.cells[0..num_cells]);
        }

        /// Returns cell at viewport row `r` and column `c`.
        pub inline fn cellAt(self: *const Self, r: usize, c: usize) Cell {
            if (r >= self.active_rows or c >= self.active_cols) return .{};
            return self.cells[r * max_cols + c];
        }

        /// Resolves the primary codepoint for classification or character display.
        pub fn resolveCodepoint(self: *const Self, cell: Cell) u21 {
            return switch (cell.kind) {
                .empty => ' ',
                .narrow, .wide_left, .wide_right => std.math.cast(u21, cell.codepoint) orelse ' ',
                .grapheme, .grapheme_wide => blk: {
                    if (self.getGrapheme(cell.codepoint)) |cps| {
                        if (cps.len > 0) break :blk cps[0];
                    }
                    break :blk ' ';
                },
                .shaped => ' ',
            };
        }

        /// Finds word boundary columns [left, right] on display row `r` at column `col`.
        pub fn wordsBoundsAt(
            self: *const Self,
            classifier: *const Classifier,
            r: usize,
            col: u16,
            join_option: Classifier.JoinOption,
        ) struct { u16, u16 } {
            if (r >= self.active_rows or col >= self.active_cols) return .{ 0, 0 };
            const row_cells = self.displayRow(r);

            const origin_col: u16 = if (row_cells[col].kind == .wide_right and col > 0) col - 1 else col;
            const origin_cp = self.resolveCodepoint(row_cells[origin_col]);
            const origin_class = classifier.classify(origin_cp);

            var left: u16 = origin_col;
            while (left > 0) {
                if (row_cells[left - 1].kind == .wide_right) {
                    left -= 1;
                    continue;
                }
                const cp = self.resolveCodepoint(row_cells[left - 1]);
                const class = classifier.classify(cp);
                if (!origin_class.canJoin(class, join_option)) break;
                left -= 1;
            }

            const max_col = self.active_cols - 1;
            var right: u16 = origin_col;
            while (right < max_col) {
                if (row_cells[right + 1].kind == .wide_right) {
                    right += 1;
                    continue;
                }
                const cp = self.resolveCodepoint(row_cells[right + 1]);
                const class = classifier.classify(cp);
                if (!origin_class.canJoin(class, join_option)) break;
                right += 1;
            }

            return .{ left, right };
        }

        /// Looks up an interned grapheme sequence by synthetic id.
        pub fn getGrapheme(self: *const Self, id: u32) ?[]const u21 {
            for (self.graphemes[0..self.grapheme_count]) |*entry| {
                if (entry.id == id) return entry.cps[0..entry.len];
            }
            return null;
        }

        /// Inserts or updates a grapheme entry in the side-table.
        pub fn addGrapheme(self: *Self, id: u32, cps: []const u21) void {
            for (self.graphemes[0..self.grapheme_count]) |*entry| {
                if (entry.id == id) {
                    const len: u8 = @intCast(@min(cps.len, max_cluster_len));
                    entry.len = len;
                    @memcpy(entry.cps[0..len], cps[0..len]);
                    return;
                }
            }
            if (self.grapheme_count < max_frame_graphemes) {
                const len: u8 = @intCast(@min(cps.len, max_cluster_len));
                var entry: GraphemeEntry = .{
                    .id = id,
                    .len = len,
                    .cps = undefined,
                };
                @memcpy(entry.cps[0..len], cps[0..len]);
                self.graphemes[self.grapheme_count] = entry;
                self.grapheme_count += 1;
            }
        }
    };
}

test "Frame: init, alignment and deinit" {
    const testing = std.testing;
    const test_option = @import("test_fixtures.zig").test_option;
    const TestFrame = Frame(test_option);

    var frame = try TestFrame.init(testing.allocator);
    defer frame.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), @intFromPtr(frame.cells.ptr) % 64);
    try testing.expectEqual(test_option.max_rows * test_option.max_cols, frame.cells.len);
    try testing.expectEqual(.empty, frame.cellAt(0, 0).kind);
}

test "Frame: displayRow and cellAt" {
    const testing = std.testing;
    const test_option = @import("test_fixtures.zig").test_option;
    const TestFrame = Frame(test_option);

    var frame = try TestFrame.init(testing.allocator);
    defer frame.deinit(testing.allocator);

    frame.cells[2 * test_option.max_cols + 5] = .{
        .codepoint = 'Z',
        .kind = .narrow,
    };

    const row = frame.displayRow(2);
    try testing.expectEqual('Z', row[5].codepoint);
    try testing.expectEqual('Z', frame.cellAt(2, 5).codepoint);
    try testing.expectEqual(.empty, frame.cellAt(999, 999).kind);
}

test "Frame: grapheme side-table" {
    const testing = std.testing;
    const test_option = @import("test_fixtures.zig").test_option;
    const TestFrame = Frame(test_option);

    var frame = try TestFrame.init(testing.allocator);
    defer frame.deinit(testing.allocator);

    const cluster = [_]u21{ 'e', 0x0301 };
    frame.addGrapheme(0x110001, &cluster);

    const found = frame.getGrapheme(0x110001);
    try testing.expect(found != null);
    try testing.expectEqualSlices(u21, &cluster, found.?);
    try testing.expectEqual(null, frame.getGrapheme(0x110002));
}

test "Frame: dirtyRange bounding range calculation" {
    const testing = std.testing;
    const test_option = @import("test_fixtures.zig").test_option;
    const TestFrame = Frame(test_option);

    var frame = try TestFrame.init(testing.allocator);
    defer frame.deinit(testing.allocator);

    try testing.expectEqual(@as(?TestFrame.DirtyRange, null), frame.dirtyRange());

    frame.dirty_rows.set(5);
    try testing.expectEqual(TestFrame.DirtyRange{ .min = 5, .max = 5 }, frame.dirtyRange().?);

    frame.dirty_rows.set(11);
    try testing.expectEqual(TestFrame.DirtyRange{ .min = 5, .max = 11 }, frame.dirtyRange().?);

    frame.dirty_rows.set(2);
    try testing.expectEqual(TestFrame.DirtyRange{ .min = 2, .max = 11 }, frame.dirtyRange().?);
}
