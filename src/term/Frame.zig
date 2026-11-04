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
const Option = @import("term.zig").Option;

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

        /// Cursor state mapped to viewport coordinates.
        cursor: CursorSnapshot = .{},

        /// Optional OSC 12 cursor color override.
        cursor_color: ?[3]u8 = null,

        /// Reverse video mode (DECSCNM).
        reverse_video: bool = false,

        /// Whether the alternate screen buffer is active.
        is_alternate: bool = false,

        /// Scrollback lines available in terminal history.
        scrollback_used: u32 = 0,

        /// Viewport offset (0 = live view at bottom, >0 = viewing history).
        viewport_offset: u32 = 0,

        /// Grapheme side-table for interned grapheme sequences visible in this frame.
        graphemes: [max_frame_graphemes]GraphemeEntry = undefined,
        grapheme_count: u16 = 0,

        /// Allocates cell memory with 64-byte alignment. Free with `deinit`.
        pub fn init(allocator: Allocator) !Self {
            const cells = try allocator.alignedAlloc(Cell, .@"64", max_cells);
            @memset(cells, Cell{});
            return .{
                .cells = cells,
                .dirty_rows = .empty,
            };
        }

        /// Initializes a Frame borrowing a pre-allocated 64-byte aligned buffer.
        pub fn initWithBuffer(buffer: []align(64) Cell) Self {
            std.debug.assert(buffer.len >= max_cells);
            @memset(buffer[0..max_cells], Cell{});
            return .{
                .cells = buffer[0..max_cells],
                .dirty_rows = .empty,
            };
        }

        /// Releases cell memory allocated by `init`.
        pub fn deinit(self: *Self, allocator: Allocator) void {
            allocator.free(self.cells);
        }

        /// Const slice of `active_cols` cells for viewport display row `r`.
        pub inline fn displayRow(self: *const Self, r: usize) []const Cell {
            std.debug.assert(r < max_rows);
            return self.cells[r * max_cols ..][0..self.active_cols];
        }

        /// Returns cell at viewport row `r` and column `c`.
        pub inline fn cellAt(self: *const Self, r: usize, c: usize) Cell {
            if (r >= self.active_rows or c >= self.active_cols) return .{};
            return self.cells[r * max_cols + c];
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
