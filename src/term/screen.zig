//! One terminal buffer (primary or alternate): `Screen(option)` is a
//! ring of cell rows with scrollback, cursor, margins, line attributes
//! and per-row dirty tracking.

const std = @import("std");
const builtin = @import("builtin");
const optimize_mode = builtin.mode;

const log = std.log.scoped(.screen);

const Cell = @import("cell.zig").Cell;
const CellKind = @import("cell.zig").Kind;
const Cursor = @import("cell.zig").Cursor;
const SavedCursor = @import("cell.zig").SavedCursor;
const Color = @import("cell.zig").Color;
const Attr = @import("cell.zig").Attr;
const Charset = @import("cell.zig").Charset;
const CharsetState = @import("cell.zig").CharsetState;

const Palette = @import("Palette.zig").Palette;
const Style = @import("Style.zig");
const Option = @import("term.zig").Option;

const wc = @import("../unicode/wcwidth.zig");
const Classifier = @import("../unicode/Classifier.zig");

// extern fn memset(dest: ?*anyopaque, c: c_int, n: usize) ?*anyopaque;
// extern fn memmove(dest: ?*anyopaque, src: ?*const anyopaque, n: usize) ?*anyopaque;

// With enum(u8), the backing type matches the storage size exactly.
// @memset(self.line_attrs[start..end], .normal) now clearly maps to
// memset(ptr, 0, count), so the compiler can `emit rep stosb` or a
// vectorized zero-fill.
//
// enum(u8) is the idiomatic choice when each element occupies a full
// byte anyway. enum(u2) only saves memory in a packed struct;
// in a plain array it still uses 1 byte per element, so the u2
// backing type gives no benefit and only confuses the compiler.
pub const LineAttr = enum(u8) {
    normal = 0, // single-width, single-height (default)
    double_width = 1, // ESC # 6 — DECDWL
    double_top = 2, // ESC # 3 — DECDHL top half
    double_bottom = 3, // ESC # 4 — DECDHL bottom half
};

/// Per screen, each screen has its own copy
pub const Mode = packed struct {
    auto_wrap: bool = true, // DECAWM / CSI ? 7 h/l
    insert: bool = false, // IRM / CSI 4 h/l     (ANSI mode 4)
    cursor_visibility: bool = true, // DECTCEM  CSI ? 25 h/l
    cursor_blink: bool = false, // xterm     CSI ? 12 h/l
    reverse_video: bool = false, // DECSCNM  CSI ? 5 h/l
    smooth_scroll: bool = false, // DECSCLM  CSI ? 4 h/l   (DEC private mode 4)
    reverse_wrap: bool = false, // xterm reverse wraparound  CSI ? 45 h/l
    _pad: u7 = 0, // 11 bits used; pad to 16 bits
};

/// Sets `n` cells at `dest` to `Cell{}`, the blank with default colors.
/// `Cell{}` is all zero bits (see the assert below), so this is a byte
/// fill, which lowers to a `memset` call: in Rex's executables that is
/// `src/memset.zig` (#78), about 16 ns for a 220-cell row on a Ryzen 3
/// 3300X, against 67 ns for a fill with a `Cell` value the compiler can't
/// see is zero.
pub fn zeroRow(dest: [*]Cell, n: usize) void {
    @memset(dest[0..n], Cell{});
}

comptime {
    // `zeroRow` writes zero bytes for `Cell{}`.
    std.debug.assert(@as(u64, @bitCast(Cell{})) == 0);
}

fn nextPowerOfTwo(comptime n: usize) usize {
    if (n <= 1) return 1;

    var result: usize = 1;
    while (result < n) : (result <<= 1) {}

    return result;
}

/// A terminal screen backed bya ring-buffer cell grid with scrollback history.
///
/// [Memory Layout]
///
/// Cells are stored in a flat heap-allocated array of `ring_rows * max_cols`
/// elements, where `ring_rows = max_rows + max_scrollback`. The array is
/// treated as a circular buffer: logical row `r` maps to physical index
/// `(scroll_offset + r) % ring_rows`.
///
/// [Scrollback]
///
/// On a full-screen scroll-up, `scroll_offset` advances by one in O(1).
/// The row that "falls off" the top is preserved in the ring buffer as
/// scrollback history. `scrollback_used` tracks how many lines are available
/// (capped at `max_scrollback`)..
///
/// `viewport_offset = 0` -> live view (normal terminal operation).
/// `viewport_offset = N` -> user has scrolled back N lines.
///
/// [Comptime Parameters]
/// `max_rows` / `max_cols` are capacity bounds. The actual active dimensions
/// are `active_rows` / `active_cols` (runtime, <= the comptime maxima).
///
/// `max_cols` stays comptime because the atlas glyph cache and the renderer
/// instance buffer are sized from it at compile time.
///
/// Maximum scrollback lines retained above the active area.
/// Increase this for more history; each line costs `max_cols * @sizeOf(Cell)` bytes.
pub fn Screen(comptime option: Option) type {
    const max_rows = option.max_rows;
    const max_cols = option.max_cols;
    const tab_width = option.tab_width;
    const max_scrollback = option.max_scrollback;

    const is_scrollback_used = max_scrollback > 0;

    const default_scroll_bottom: u16 = @intCast(max_rows -| 1);
    const max_usize = std.math.maxInt(usize);
    comptime {
        if (max_rows == 0) {
            @compileError("max_rows must be greater than zero");
        }

        if (max_scrollback > max_usize - max_rows) {
            @compileError("max_rows + max_scrollback overflows usize");
        }

        const logical = max_rows + max_scrollback;
        if (logical > max_usize / 2 + 1) {
            @compileError("logical_ring_rows is too large for the next power of two");
        }
    }

    comptime {
        const logical = max_rows + max_scrollback;
        const ring_rows = std.math.ceilPowerOfTwo(usize, logical) catch {
            @compileError("logical_ring_rows is too large for power-of-two calculation");
        };

        // Calculate memory waste percentage: (wasted rows / total ring rows) * 100
        const wasted_rows = ring_rows - logical;
        const waste_percent = (wasted_rows * 100) / ring_rows;

        // If more than 40% of the allocated ring buffer sits empty, fail at compile time
        if (waste_percent > 40) {
            @compileError(std.fmt.comptimePrint(
                \\Inefficient buffer configuration detected!
                \\  - Logical rows requested: {d} (max_rows: {d} + max_scrollback: {d})
                \\  - Resulting ring_rows:    {d} (next power of two)
                \\  - Wasted allocation:     {d}% ({d} empty rows)
                \\Please adjust `max_scrollback` to sit closer to a power-of-two boundary (e.g., 4096, 8192, 16384).
            , .{ logical, max_rows, max_scrollback, ring_rows, waste_percent, wasted_rows }));
        }
    }

    // Total rows in the ring buffer (active capacity + scrollback capacity)
    const logical_ring_rows = max_rows + max_scrollback;
    const ring_rows = nextPowerOfTwo(logical_ring_rows);
    const ring_mask = ring_rows - 1;

    const max_u16: usize = std.math.maxInt(u16);
    comptime {
        if (ring_rows == 0) {
            @compileError("ring_rows must be greater than zero");
        }

        if (ring_rows < max_rows) {
            @compileError("ring_rows must be >= max_rows");
        }

        if (ring_rows > max_u16) {
            @compileError("ring_rows must fit in u16");
        }

        if (!std.math.isPowerOfTwo(ring_rows)) {
            @compileError("ring_rows must be a power of two");
        }
    }

    return struct {
        const Self = @This();

        // Instrumentation only, gated so release builds pay nothing.
        pub const instrument = optimize_mode == .Debug or @hasDecl(option, "instrument_calls");

        pub const Rotation = enum { left, right };

        inline fn wrapAdd(a: usize, b: usize) usize {
            std.debug.assert(a < ring_rows);
            std.debug.assert(b <= max_rows);
            return (a + b) & ring_mask;
        }

        pub const ViewportPosition = enum { bottom, top };

        // Heap storage

        /// Flat cell buffer: `ring_rows * max_cols` cells.
        /// Never indexing the cells directly, always use `viewRow`.
        ///
        /// Cache-Line (8x8 = 64 bytes)
        ///  -----------------------------------------------------------------------
        /// | Cell 0 | Cell 1 | Cell 2 | Cell 3 | Cell 4 | Cell 5 | Cell 6 | Cell 7 |
        ///  -----------------------------------------------------------------------
        cells: []align(64) Cell,

        /// Pre-allocated secondary scratch buffer for zero-allocation reflow.
        scratch_cells: if (is_scrollback_used) []align(64) Cell else void,

        // Ring buffer
        // The ring buffer is a single flat allocation. No pointer chasing, cache-friendly.

        /// Physical index of logical row 0 (top of the active area).
        /// Advances by 1 on each full-screen scroll-up (O(1) scroll).
        scroll_offset: u32 = 0,

        // Scrollback

        /// Number of scrollback lines currently available (0..max_scrollback).
        /// Incremented by full-screen scrollUp; capped at max_scrollback.
        scrollback_used: if (is_scrollback_used) u32 else void,

        /// How many lines the user has scrolled back from the live view.
        /// 0 = live view (normal terminal operation).
        /// N = viewing N lines above the current active area.
        viewport_offset: if (is_scrollback_used) u32 else void,

        // Active dimensions

        /// Current active rows (<= max_rows). Updated by `setActive`.
        active_rows: u16 = @intCast(max_rows),

        /// Current active columns (<= max_cols). Updated by `setActive`.
        active_cols: u16 = @intCast(max_cols),

        // Cursor
        cursor: Cursor = .{},

        /// Saved cursor state for DECSC (ESC 7) / DECRC (ESC 8).
        saved_cursor: SavedCursor = .{},

        // Scroll region
        scroll_top: u16 = 0,

        // Default initialized to `max_rows - 1`,where a scroll
        // region of [0,0] mean only one row, which will break `scrollUp` / `scrollDown`.
        scroll_bottom: u16,

        // Tab stops

        /// Tab stops positions.
        /// "may generate inefficient code for larger sets, especially in debug mode"
        /// [bit_set.zig:11-14](https://github.com/ziglang/zig/blob/738d2be9/lib/std/bit_set.zig#L11-L14)
        tab_stops: std.bit_set.StaticBitSet(max_cols),

        // Dirty tracking

        /// Monotonically increasing generation counter. Incremented by `bump()`
        /// on any visible state change. The renderer compares this against
        /// `last_generation` to decide whether to rebuild the instance buffer.
        ///
        /// [NOTE!]
        /// The renderer that used `generation` > `last_generation` to detact
        /// changes, it will break on u32 wraparound after ~4 billion increments.
        /// Use `generation != last_generation` instead.
        generation: u32 = 0,

        mode: Mode = .{},

        /// Bitmask of logical rows (0..max_rows-1) that have been mutated since
        /// the renderer last consumed this set. The renderer reads this, redraws
        /// only the marked rows, then clears it.
        ///
        /// Full-viewport shifts (full-screen scroll, resize, viewport scroll)
        /// set all bits via `.full` because the entire visible area changes.
        ///
        /// IMPORTANT Screen owns dirty_rows as a write-only set.
        /// It never reads or clears it. This is the only invariant Screen needs
        /// to uphold.
        dirty_rows: std.bit_set.StaticBitSet(max_rows) = .empty,

        line_attrs: [ring_rows]LineAttr = std.mem.zeroes([ring_rows]LineAttr),

        // Title stack buffer moved in App/Terminal instead, because
        // it's window terminal behavior.
        palette: Palette,

        /// Colors of this screen's cells, the pen's `id` and `blank_id`
        /// (ADR 0005). Owned; 288 KiB allocated by `create`.
        styles: Style.Table,

        // FIXME not a screen state
        // moved to terminal
        last_char: u21 = 0, // last graphic char written by putChar; 0 = none

        /// Logical-to-physical row remapping for O(region_height) region scroll.
        /// row_map[r] is the offset added to scroll_offset to get the physical index.
        /// Invariant: row_map is a permutation of 0..active_rows-1.
        row_map: []u16,

        row_map_generation: u32 = 0,

        row_map_lo: u16 = 0,
        row_map_hi: u16 = 0, // inclusive; only meaningful when row_map_is_identity == false

        /// Owns the codepoint slices for interned grapheme sequences.
        grapheme_arena: std.heap.ArenaAllocator,

        /// Maps synthetic ID, original codepoint sequence.
        /// IDs start at 0x110001 (one above Unicode max 0x10FFFF).
        grapheme_table: std.AutoHashMap(u32, []const u21),

        grapheme_reverse: std.AutoHashMap(u64, u32), // wyhash(cps) to id

        /// Next synthetic ID to assign. IDs are never reused, so a cell's ID
        /// stays valid across compaction.
        next_grapheme_id: u32,

        /// `grapheme_table` size that triggers the next `compactGraphemes`.
        grapheme_compact_at: u32 = grapheme_compact_min,

        cached_row_phys: u16 = std.math.maxInt(u16),
        cached_row_slice: []Cell = &.{},

        // batching: bool = false,

        /// updated whenever charset state changes
        charset_is_identity: bool = true,
        row_map_is_identity: bool = false,

        /// Net number of lines the ring head has advanced (full-screen
        /// scroll up) since screen creation. Region scrolls and reverse
        /// scrolls rotate `row_map` instead and do not change it.
        ///
        /// Used to detect scrollback drift or eviction when resolving stable selection
        /// anchors caputred earlier.
        total_lines_scrolled: i64 = 0,

        // FIXME
        // For max_scrollback = 10_000 and max_cols = 500:
        // So, `10_500 rows × 500 cols × @sizeOf(Cell) bytes = ?`
        pub fn create(gpa: std.mem.Allocator) !Self {
            const cells = try gpa.alignedAlloc(Cell, .@"64", ring_rows * max_cols);
            @memset(cells, Cell{});
            errdefer gpa.free(cells);

            const scratch_cells = if (comptime is_scrollback_used) blk: {
                const sc = try gpa.alignedAlloc(Cell, .@"64", ring_rows * max_cols);
                @memset(sc, Cell{});
                break :blk sc;
            } else {};
            errdefer if (comptime is_scrollback_used) gpa.free(scratch_cells);

            var row_map = try gpa.alloc(u16, ring_rows);
            errdefer gpa.free(row_map);
            for (0..ring_rows) |i| row_map[i] = @intCast(i);

            const styles: Style.Table = try .init(gpa);

            return .{
                .styles = styles,
                .row_map = row_map,
                .cells = cells,
                .scratch_cells = scratch_cells,
                .palette = .empty,
                .tab_stops = comptime defaultTabStops(),
                .scroll_bottom = default_scroll_bottom,
                .scrollback_used = if (is_scrollback_used) 0 else {},
                .viewport_offset = if (is_scrollback_used) 0 else {},
                .grapheme_arena = std.heap.ArenaAllocator.init(gpa),
                .grapheme_table = .init(gpa),
                .grapheme_reverse = .init(gpa),
                .next_grapheme_id = 0x110000,
            };
        }

        pub fn destroy(self: *Self, allocator: std.mem.Allocator) void {
            allocator.free(self.cells);
            if (comptime is_scrollback_used) allocator.free(self.scratch_cells);
            allocator.free(self.row_map);
            self.styles.deinit(allocator);
            self.grapheme_table.deinit();
            self.grapheme_reverse.deinit();
            self.grapheme_arena.deinit();
        }

        /// Maps logical row `r` (0 = top of active area) to a physical index
        /// in the ring buffer. It does not account for `viewport_offset`.
        ///
        /// Use `viewRow` in the renderer so scrollback is visible when
        /// user has scrolled up.
        pub inline fn physRow(self: *const Self, logical_row: usize) usize {
            const offset = if (self.row_map_is_identity or
                logical_row < self.row_map_lo or
                logical_row > self.row_map_hi)
                logical_row
            else
                self.row_map[logical_row];

            return (self.scroll_offset + offset) & ring_mask;
        }

        /// Maps display row `r` to a physical ring-buffer index, accounting
        /// for `viewport_offset`.
        ///
        /// When `viewport_offset = 0`, equivalent to `physRow(r)`.
        /// When `viewport_offset = N`, the display origin is N rows before
        /// `scroll_offset`, so the user sees scrollback history.
        pub inline fn viewRow(self: *const Self, r: usize) usize {
            // With no scrollback, the viewport cannot be offset.
            if (comptime max_scrollback == 0) {
                return self.physRow(r);
            }

            const viewport_offset = self.viewport_offset;

            if (viewport_offset > 0 and r < viewport_offset) {
                // Displaying scrollback. The oldest visible row is
                // viewport_offset rows before scroll_offset.
                //
                // scroll_offset + ring_rows - viewport_offset + r
                // is equivalent to:
                //
                // scroll_offset - viewport_offset + r (mod ring_rows)
                return (self.scroll_offset +
                    ring_rows -
                    viewport_offset +
                    r) & ring_mask;
            }

            // This subtraction is safe because the branch above handled
            // every r < viewport_offset case.
            const logical = r - viewport_offset;

            // The active-area portion must use the normal logical-row mapping.
            return self.physRow(logical);
        }

        /// Const slice of `active_cols` cells for logical row `r`.
        /// For terminal logic (cursor movement, erase, etc.).
        pub inline fn row(self: *const Self, r: usize) []const Cell {
            return self.cells[self.physRow(r) * max_cols ..][0..self.active_cols];
        }

        /// Shared mutable row accessor.
        /// `mark_dirty = true`  → marks row `r` dirty (normal write path).
        /// `mark_dirty = false` → skips dirty mark (caller handles it, e.g. `dirty_rows = .full`).
        /// Full `max_cols` width is returned so callers can `@memset` the entire row.
        inline fn rowMutBase(self: *Self, r: usize, comptime mark_dirty: bool) []Cell {
            if (comptime mark_dirty) self.dirty_rows.set(r);
            return self.cells[self.physRow(r) * max_cols ..][0..max_cols];
        }

        /// Mutable slice of `max_cols` cells for logical row `r`. Marks row dirty.
        pub inline fn rowMut(self: *Self, r: usize) []Cell {
            return self.rowMutBase(r, true);
        }

        /// Mutable slice for logical row `r` without marking it dirty.
        /// Use only when the caller will mark the screen dirty via another
        /// mechanism (e.g. `dirty_rows = .full`). Never use this as the
        /// general write path, missing a dirty mark causes the renderer
        /// to skip the row silently.
        inline fn rowMutRaw(self: *Self, r: usize) []Cell {
            return self.rowMutBase(r, false);
        }

        /// Const slice of `active_cols` cells for display row `r`,
        /// accounting for `viewport_offset`. Used by `buildInstances`.
        pub inline fn displayRow(self: *const Self, r: usize) []const Cell {
            return self.cells[self.viewRow(r) * max_cols ..][0..self.active_cols];
        }

        /// Returns the LineAttr for display row `r` (accounting for viewport_offset).
        pub inline fn displayLineAttr(self: *const Self, r: usize) LineAttr {
            return self.line_attrs[self.viewRow(r)];
        }

        /// Shift In (SI / 0x0F): map GL to G0.
        ///
        /// Restores the default 7-bit character set mapping. Paired with `shiftOut`.
        /// Does NOT consume a pending single-shift — SS2/SS3 remain active until
        /// the next printable character is written.
        pub fn shiftIn(self: *Self) void {
            self.lockingShift(0, .gl);
        }

        /// Shift Out (SO / 0x0E): map GL to G1.
        ///
        /// Activates the G1 charset for 7-bit output. Commonly used to switch to
        /// DEC Special Graphics (box-drawing) when G1 is designated as `.dec_special`.
        /// Paired with `shiftIn`.
        pub fn shiftOut(self: *Self) void {
            self.lockingShift(1, .gl);
        }

        /// Single Shift 2 (SS2 / ESC N): use G2 for the next character only.
        ///
        /// Overrides GL for exactly one printable character, then reverts.
        /// `CharsetState.translate` consumes `single_shift` on the first call after
        /// this is set. Does not alter the persistent `gl` mapping.
        pub fn singleShift2(self: *Self) void {
            self.cursor.charset.ss = 2;
            self.charset_is_identity = false;
        }

        /// Single Shift 3 (SS3 / ESC O): use G3 for the next character only.
        ///
        /// Overrides GL for exactly one printable character, then reverts.
        /// `CharsetState.translate` consumes `single_shift` on the first call after
        /// this is set. Does not alter the persistent `gl` mapping.
        pub fn singleShift3(self: *Self) void {
            self.cursor.charset.ss = 3;
            self.charset_is_identity = false;
        }

        /// Locking shift: set GL or GR to the given slot (0–3 = G0–G3).
        pub fn lockingShift(self: *Self, slot: u2, comptime side: enum { gl, gr }) void {
            switch (side) {
                .gl => self.cursor.charset.gl = slot,
                .gr => self.cursor.charset.gr = slot,
            }
            self.charset_is_identity = self.cursor.charset.isIdentity();
        }

        /// Designate Charset (ESC ( X / ESC ) X / ESC * X / ESC + X).
        ///
        /// Assigns charset `cs` to slot `slot`:
        ///   0 = G0  (ESC ( X)
        ///   1 = G1  (ESC ) X)
        ///   2 = G2  (ESC * X)
        ///   3 = G3  (ESC + X)
        ///
        /// Does not change the active GL/GR mapping — call `shiftIn`/`shiftOut`
        /// or `singleShift2`/`singleShift3` to activate the newly designated charset.
        /// The new designation is saved/restored by `saveCursor`/`restoreCursor`
        /// because `CharsetState` is part of `Cursor`.
        pub fn designateCharset(self: *Self, slot: u2, cs: Charset) void {
            self.cursor.charset.setSlot(slot, cs);
            self.charset_is_identity = self.cursor.charset.isIdentity();
        }

        pub fn setLineAttr(self: *Self, attr: LineAttr) void {
            const phys = self.physRow(self.cursor.row);
            self.line_attrs[phys] = attr;
            self.dirty_rows.set(self.cursor.row);
        }

        /// DECALN (ESC # 8): fill the entire active area with 'E' for alignment testing.
        /// Resets cursor to home (0, 0) and marks all rows dirty.
        pub fn decaln(self: *Self) void {
            const fill = Cell{ .codepoint = 'E', .kind = .narrow };
            for (0..self.active_rows) |row_idx| {
                const r = self.rowMutRaw(@intCast(row_idx));
                @memset(r[0..self.active_cols], fill);
                self.dirty_rows.set(row_idx);
            }

            self.cursor.row = 0;
            self.cursor.col = 0;
            self.cursor.wrap_pending = false;
            self.bump();
        }

        /// Called by when Terminal.flushGrapheme() for multi-codepoint cluster (ZWJ sequences).
        /// Interns the sequences, assigns a synthetic ID > 0x10FFFF, stores it in the cell.
        pub fn putGrapheme(self: *Self, cps: []const u21, kind: CellKind) !void {
            const grapheme_id = try self.internGrapheme(cps);
            const stored_kind: CellKind = switch (kind) {
                .wide_left => .grapheme_wide,
                else => .grapheme,
            };
            self.writeChar(.{
                .kind = stored_kind,
                .codepoint = grapheme_id,
                .style = self.cursor.attr.id,
                .flags = self.cursor.attr.flags,
            });
        }

        /// Smallest intern table size at which compaction runs.
        pub const grapheme_compact_min: u32 = 4096;

        /// Hash key of a code point sequence in `grapheme_reverse`.
        pub fn graphemeKey(cps: []const u21) u64 {
            return std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(cps));
        }

        /// Returns the synthetic ID for `cps`, reusing an existing one when
        /// the stored sequence is equal. A hash hit is only a candidate: on
        /// a collision the newcomer gets an ID of its own with no reverse
        /// entry, so it is not deduplicated but never aliases the other.
        ///
        /// Table growth is bounded by `compactGraphemes`, which runs here
        /// before a new entry once the table reaches `grapheme_compact_at`.
        fn internGrapheme(self: *Self, cps: []const u21) !u32 {
            if (self.grapheme_table.count() >= self.grapheme_compact_at) self.compactGraphemes();
            const gop = try self.grapheme_reverse.getOrPut(graphemeKey(cps));
            if (gop.found_existing) {
                const stored = self.grapheme_table.get(gop.value_ptr.*) orelse {
                    // Stale reverse entry: take it over.
                    gop.value_ptr.* = try self.addGrapheme(cps);
                    return gop.value_ptr.*;
                };
                if (std.mem.eql(u21, stored, cps)) return gop.value_ptr.*;
                return self.addGrapheme(cps); // collision
            }
            errdefer self.grapheme_reverse.removeByPtr(gop.key_ptr);
            gop.value_ptr.* = try self.addGrapheme(cps);
            return gop.value_ptr.*;
        }

        /// Bounds the intern table: rebuilds it from the clusters still
        /// referenced by a cell anywhere in the ring (screen and scrollback),
        /// keeping their IDs, and frees everything else. The next run is
        /// set at twice the live count (at least `grapheme_compact_min`), so
        /// the table stays within 2x the live clusters and the O(cells) scan
        /// is amortized over at least as many new interns. On allocation
        /// failure the old table is kept and the next try is postponed.
        fn compactGraphemes(self: *Self) void {
            self.rebuildGraphemes() catch {
                self.grapheme_compact_at = self.grapheme_table.count() *| 2;
                return;
            };
            self.grapheme_compact_at = @max(grapheme_compact_min, self.grapheme_table.count() *| 2);
        }

        fn rebuildGraphemes(self: *Self) !void {
            const gpa = self.grapheme_table.allocator;
            var arena = std.heap.ArenaAllocator.init(self.grapheme_arena.child_allocator);
            errdefer arena.deinit();
            var table = std.AutoHashMap(u32, []const u21).init(gpa);
            errdefer table.deinit();
            var reverse = std.AutoHashMap(u64, u32).init(gpa);
            errdefer reverse.deinit();

            for (self.cells) |cell| {
                if (!cell.kind.isGrapheme()) continue;
                const cps = self.grapheme_table.get(cell.codepoint) orelse continue;
                const gop = try table.getOrPut(cell.codepoint);
                if (gop.found_existing) continue;
                gop.value_ptr.* = try arena.allocator().dupe(u21, cps);
                const rev = try reverse.getOrPut(graphemeKey(cps));
                if (!rev.found_existing) rev.value_ptr.* = cell.codepoint;
            }

            self.grapheme_table.deinit();
            self.grapheme_reverse.deinit();
            self.grapheme_arena.deinit();
            self.grapheme_table = table;
            self.grapheme_reverse = reverse;
            self.grapheme_arena = arena;
        }

        /// Stores a copy of `cps` under a fresh ID, without a reverse entry.
        fn addGrapheme(self: *Self, cps: []const u21) !u32 {
            const owned = try self.grapheme_arena.allocator().dupe(u21, cps);
            const id = self.next_grapheme_id;
            try self.grapheme_table.put(id, owned);
            self.next_grapheme_id += 1;
            return id;
        }

        /// The ID of `style` in this screen's table. When the table is full,
        /// sweeps it if due and retries, else falls back to the nearest
        /// live style, so no ID in use ever changes (ADR 0005).
        pub fn internStyle(self: *Self, style: Style) Style.Id {
            if (self.styles.intern(style)) |id| return id;
            if (self.styles.sweepDue()) {
                self.sweepStyles();
                if (self.styles.intern(style)) |id| return id;
            }
            return self.styles.nearest(style);
        }

        /// Refreshes the pen's cached IDs from `cursor.attr.colors`. Call
        /// after every change to the colors (SGR, DECRC).
        pub fn internPen(self: *Self) void {
            const attr = &self.cursor.attr;
            // Default colors (SGR 0, a default background) are common and
            // need no lookup; checked here so they cost no call (measured
            // with `bench-term`, ADR 0005). `id` is stored before the
            // second intern, so a sweep in it keeps the new ID.
            attr.id = if (attr.colors.isDefault()) Style.Table.default_id else self.internStyle(attr.colors);
            attr.blank_id = if (attr.colors.bg == Style.default_key) Style.Table.default_id else self.internStyle(.{ .bg = attr.colors.bg });
        }

        /// The background-only style of `id`, for a blank written next to
        /// a cell drawn with `id` (splitting a wide character). Usually the
        /// pen's own.
        fn blankFor(self: *Self, id: Style.Id) Style.Id {
            if (id == self.cursor.attr.id) return self.cursor.attr.blank_id;
            return self.internStyle(.{ .bg = self.styles.get(id).bg });
        }

        /// Frees every style no cell (screen and scrollback) and no pen ID
        /// refers to. O(cells): about 0.5 ms for the default ring.
        fn sweepStyles(self: *Self) void {
            var in_use: Style.Table.InUse = .initEmpty();
            for (self.cells) |cell| in_use.set(cell.style);
            in_use.set(self.cursor.attr.id);
            in_use.set(self.cursor.attr.blank_id);
            _ = self.styles.sweep(&in_use);
        }

        pub fn getGrapheme(self: *const Self, id: u32) ?[]const u21 {
            std.debug.assert(id > 0x10FFFF); // synthetic IDs only
            return self.grapheme_table.get(id);
        }

        /// Longest cluster `attachCombining` builds; matches InputEngine.
        pub const max_cluster_len = 16;

        /// Appends a zero-width code point (combining mark, ZWJ, variation
        /// selector) to the cluster of the cell written last, interning the
        /// result as a grapheme. The cell is the one left of the cursor, or
        /// the cursor cell itself while a wrap is pending; a `wide_right`
        /// half resolves to its `wide_left`. The cell keeps its width, colors
        /// and attributes; the cursor does not move.
        ///
        /// Dropped when there is no previous cell (column 0 with no pending
        /// wrap), the cell is empty, the cluster already holds
        /// `max_cluster_len` code points, or interning fails.
        pub fn attachCombining(self: *Self, cp: u21) void {
            const prev_col: usize = if (self.cursor.wrap_pending)
                self.cursor.col
            else if (self.cursor.col > 0)
                self.cursor.col - 1
            else
                return;

            const row_mut = self.rowMutRaw(self.cursor.row);
            var col = prev_col;
            if (row_mut[col].kind == .wide_right and col > 0) col -= 1;
            const prev = &row_mut[col];

            var buf: [max_cluster_len]u21 = undefined;
            var len: usize = 0;
            switch (prev.kind) {
                .narrow, .wide_left => {
                    buf[0] = std.math.cast(u21, prev.codepoint) orelse return;
                    len = 1;
                },
                .grapheme, .grapheme_wide => {
                    const cps = self.getGrapheme(prev.codepoint) orelse return;
                    if (cps.len >= buf.len) return;
                    @memcpy(buf[0..cps.len], cps);
                    len = cps.len;
                },
                .empty, .wide_right, .shaped => return,
            }
            if (len >= buf.len) return;
            buf[len] = cp;
            len += 1;

            const id = self.internGrapheme(buf[0..len]) catch return;
            prev.kind = if (prev.kind.isWideLeft()) .grapheme_wide else .grapheme;
            prev.codepoint = id;
            self.markDirty(self.cursor.row);
        }

        /// Resolves a Cell to the single codepoint that should represent it for
        /// word-classification and text-extraction purposes. This is the one place
        /// that knows how to interpret from cell.codepoint differently depending on
        /// cell.kind, nothing else should branch on cell.kind for this purposes.
        fn resolveCodepoint(self: *const Self, cell: Cell) u21 {
            const fallback = ' ';
            return switch (cell.kind) {
                .empty => fallback,
                .narrow, .wide_left => std.math.cast(u21, cell.codepoint) orelse fallback,
                .grapheme, .grapheme_wide => blk: {
                    const cps = self.getGrapheme(cell.codepoint) orelse break :blk fallback;
                    // Use the cluster's base codepoint (first cp) for classification/copy
                    // combining marks/ZWJ-joined codepoints after it don't change word-ness.
                    break :blk if (cps.len > 0) cps[0] else fallback;
                },
                // Second half of a wide character: carries no independent codepoint.
                // Treat as automatically joining whatever the .wide_left classified as,
                // by returning a sentinel the caller special-cases, OR simply return
                // the same class as blank so it never breaks a run on its own.
                .wide_right => fallback,

                // FIXME! Not yet implemented upstream, same gap as copySelectionToClipboard.
                .shaped => fallback,
            };
        }

        /// Cell width of `cp`, with the same table and ambiguous-width
        /// policy as the UTF-8 path (`InputEngine`), so a code point gets
        /// the same width however it reaches the screen.
        inline fn width(cp: u21) wc.Width {
            if (cp < 0x80) return .narrow; // printable ASCII; C0 never gets here
            return wc.wcwidth(cp, option.ambiguous_width);
        }

        /// Write a raw codepoint from the PTY stream at the cursor position.
        ///
        /// This is the dispatcher's entry point for printable characters. It applies the active
        /// charset translation (G0–G3 via GL, or a pending single-shift) before delegating to
        /// writeChar().
        ///
        /// The dispatcher must not call writeChar directly for printable characters, charset state
        /// is fully encapsulated here. The dispatcher is responsible for calling the charset-
        /// designating methods (designateCharset, shiftIn, shiftOut, singleShift2, singleShift3)
        /// for the corresponding escape sequences.
        pub inline fn putChar(self: *Self, cp: u21) void {
            const translated: u21 = blk: {
                if (self.charset_is_identity) {
                    @branchHint(.likely);
                    break :blk cp;
                } else break :blk self.cursor.charset.translate(cp);
            };

            if (self.cursor.charset.ss != CharsetState.no_shift) {
                self.cursor.charset.ss = CharsetState.no_shift;
                self.charset_is_identity = self.cursor.charset.isIdentity(); // may become true again
            }
            const kind: CellKind = switch (width(translated)) {
                .wide => .wide_left,
                // Unassigned and other non-printing code points still take
                // a cell, so the cursor and the app agree on the column.
                .narrow, .control => .narrow,
                .zero => {
                    // Zero-width: extend the previous cell's cluster.
                    // NOTE: last_char is NOT updated, REP repeats graphic chars only.
                    self.attachCombining(translated);
                    return;
                },
            };
            self.writeChar(.{
                .kind = kind,
                .codepoint = translated,
                .style = self.cursor.attr.id,
                .flags = self.cursor.attr.flags,
            });
            self.last_char = translated;
        }

        pub inline fn putChars(self: *Self, bytes: []const u8) void {
            // Bulk path only valid when every byte maps 1:1 to a narrow ASCII cell:
            // charset identity, no pending single-shift, no insert-mode shifting.
            if (self.charset_is_identity and
                self.cursor.charset.ss == CharsetState.no_shift and
                !self.mode.insert)
            {
                @branchHint(.likely);
                self.putCharsFast(bytes);
                return;
            }

            // Slow path: translation, single-shift, or insert-mode semantics may
            // vary per byte (e.g. ss only applies to the *first* character then
            // resets) -- fall back to the fully general per-char logic.
            for (bytes) |b| self.putChar(b);
        }

        /// Marks the cursor row as continuing onto the next one. Called
        /// just before every automatic wrap.
        inline fn markSoftWrap(self: *Self) void {
            self.rowMutRaw(self.cursor.row)[self.active_cols - 1].wrapped = true;
        }

        inline fn resolveDeferredWrap(self: *Self) void {
            self.markSoftWrap();
            self.cursor.wrap_pending = false;
            self.cursor.col = 0;

            const cr = @as(usize, self.cursor.row);
            if (cr == @as(usize, self.scroll_bottom)) {
                _ = self.scrollUpImpl(1);
            } else if (cr + 1 < self.active_rows) {
                self.cursor.row = @intCast(cr + 1);
            }
        }

        fn putCharsFast(self: *Self, bytes_in: []const u8) void {
            var bytes = bytes_in;

            while (bytes.len > 0) {
                // Deferred wrap must still be resolved before this row is valid,
                // exactly like writeChar does for a single cell.
                if (self.cursor.wrap_pending) {
                    self.resolveDeferredWrap(); // extracted from writeChar, see below
                }

                const row_mut = self.rowMutRaw(self.cursor.row);
                const cursor_col = @as(usize, self.cursor.col);
                const avail = self.active_cols - cursor_col;
                const n = @min(bytes.len, avail);

                // Boundary guard: only the *first* cell of this batch can be
                // overwriting an orphaned wide-right placeholder from a
                // pre-existing wide char to its left.
                if (row_mut[cursor_col].kind == .wide_right and cursor_col > 0) {
                    row_mut[cursor_col - 1] = Cell{ .style = self.cursor.attr.blank_id };
                }

                const flags = self.cursor.attr.flags;

                const base_cell = Cell{
                    .kind = .narrow,
                    .codepoint = 0,
                    .style = self.cursor.attr.id,
                    .flags = flags,
                    .wrapped = false,
                };
                const base_u64: u64 = @bitCast(base_cell);
                const vector_len = 8;
                const CellVector = @Vector(vector_len, u64);
                const base_vec: CellVector = @splat(base_u64);

                var k: usize = 0;
                while (k + vector_len <= n) : (k += vector_len) {
                    const chunk_bytes: @Vector(vector_len, u8) = bytes[k..][0..vector_len].*;
                    const codepoints: CellVector = chunk_bytes;
                    const cells_u64: CellVector = codepoints | base_vec;
                    const dest_ptr: *[vector_len]Cell = row_mut[cursor_col + k ..][0..vector_len];
                    @as(*align(@alignOf(Cell)) [vector_len]u64, @ptrCast(dest_ptr)).* = cells_u64;
                }

                while (k < n) : (k += 1) {
                    const b = bytes[k];
                    row_mut[cursor_col + k] = @bitCast(base_u64 | @as(u64, b));
                }

                // If the cell just past the written range was a wide-left's
                // right-half placeholder, and we didn't overwrite it, it's now
                // orphaned from the left -- blank it. Only check the single
                // boundary cell, not every interior cell.
                if (cursor_col + n < self.active_cols and
                    row_mut[cursor_col + n].kind == .wide_right)
                {
                    row_mut[cursor_col + n] = Cell{ .style = self.cursor.attr.blank_id };
                }

                self.dirty_rows.set(self.cursor.row); // once per row, not once per byte
                self.last_char = bytes[n - 1];

                bytes = bytes[n..];

                if (n == avail) {
                    // Filled the row exactly (or ran out of room): set wrap_pending
                    // instead of eagerly wrapping, matching writeChar's boundary
                    // behavior when next_col > active_cols.
                    self.cursor.col = @intCast(self.active_cols - 1);
                    self.cursor.wrap_pending = self.mode.auto_wrap;
                    if (bytes.len == 0) return;

                    if (!self.mode.auto_wrap) {
                        // DECAWM off: every remaining byte overwrites the
                        // last column in turn, so only the final one stays.
                        const last = bytes[bytes.len - 1];
                        row_mut[self.active_cols - 1].codepoint = last;
                        self.last_char = last;
                        return;
                    }
                    // More bytes remain: force the wrap now so the loop can continue
                    // writing into the next row on the next iteration.
                    self.resolveDeferredWrap();
                } else {
                    self.cursor.col = @intCast(cursor_col + n);
                }
            }
        }

        // Called when width is already known (avoids wcwidth binary search)
        pub inline fn putCharKind(self: *Self, cp: u21, kind: CellKind) void {
            const translated: u21 = if (self.charset_is_identity) cp else self.cursor.charset.translate(cp);
            if (self.cursor.charset.ss != CharsetState.no_shift) {
                self.cursor.charset.ss = CharsetState.no_shift;
                self.charset_is_identity = self.cursor.charset.isIdentity();
            }
            // wc == 0 (combining) is impossible for CJK/ASCII callers, skip that branch
            self.writeChar(.{
                .kind = kind,
                .codepoint = translated,
                .style = self.cursor.attr.id,
                .flags = self.cursor.attr.flags,
            });
            self.last_char = translated;
        }

        inline fn currentRow(self: *Self) []Cell {
            if (self.cursor.row != self.cached_row_phys) {
                self.cached_row_phys = self.cursor.row;
                self.cached_row_slice = self.rowMut(self.cursor.row);
            }
            return self.cached_row_slice;
        }

        /// Write a pre-built cell at the cursor position and advance the cursor.
        ///
        /// This is the internal write path. Callers must supply a fully resolved
        /// `Cell` (codepoint, width, attr). For PTY printable characters, use
        /// `putChar` instead, it handles charset translation and `wcwidth` lookup.
        ///
        /// Handles combining characters, deferred wraps, insert mode shifts,
        /// split wide character guards, end-of-row wrapping, and continuation placeholders.
        pub inline fn writeChar(self: *Self, cell: Cell) void {
            std.debug.assert(cell.kind != .empty and cell.kind != .wide_right);

            // Deferred wrap
            if (self.cursor.wrap_pending) {
                self.dirty_rows.set(self.cursor.row); // erase cursor from old row
                self.markSoftWrap();
                self.cursor.wrap_pending = false;
                self.cursor.col = 0;

                const cr = @as(usize, self.cursor.row);
                if (cr == @as(usize, self.scroll_bottom)) {
                    _ = self.scrollUpImpl(1);
                    // cursor.row_mut stays at scroll_bottom after scrollUp
                } else if (cr + 1 < self.active_rows) {
                    self.cursor.row = @intCast(cr + 1);
                }

                // If below scroll_bottom (outside scroll region): just move down.
                // If at the last row_mut outside the scroll region: don't move, don't scroll.
            }

            const kind: CellKind = cell.kind;
            const cursor_col = @as(usize, self.cursor.col);

            // Fetch row_mut AFTER deferred wrap, cursor.row may have changed.
            const row_mut = self.currentRow();

            if (self.mode.insert) {
                const shift = kind.columnSpan();
                if (cursor_col + shift < self.active_cols) {
                    std.mem.copyBackwards(
                        Cell,
                        row_mut[cursor_col + shift .. self.active_cols],
                        row_mut[cursor_col .. self.active_cols - shift],
                    );
                }
            }

            const self_kind = row_mut[cursor_col].kind;
            const is_wide = kind.isWideLeft();

            const needs_blank_left_half = (self_kind == .wide_right and cursor_col > 0);

            // Wide char or grapheme wide at last column
            const wide_at_end = (is_wide and cursor_col + 1 >= self.active_cols);

            // DECAWM off: a wide char has no room and may not wrap, so it is
            // dropped and the cursor stays (xterm).
            if (wide_at_end and !self.mode.auto_wrap) return;

            // Split-wide-char: right slot currently contains left-half of another wide char
            const needs_blank_right_of_right: bool = blk: {
                // the wide_at_end guard in the blk is technically redundant since the
                // if (wide_at_end) { ... return; } fires before needs_blank_right_of_right
                // is ever used. But it's a good defensive guard, it prevents the load even
                // if the code is ever reordered. So Keep it.
                if (!is_wide or wide_at_end) break :blk false; // defer the load
                if (cursor_col + 2 >= self.active_cols) break :blk false;
                const right_kind = row_mut[cursor_col + 1].kind; // only loaded when is_wide
                break :blk right_kind.isWideLeft();
            };

            const needs_blank_right_of_self: bool = blk: {
                if (is_wide) break :blk false; // mutually exclusive with wide path
                break :blk (self_kind.isWideLeft() and cursor_col + 1 < self.active_cols);
            };

            // Stores only after predicates are ready

            // Split-wide-char guard: overwriting a right-half placeholder
            // Blank the orphaned left half so the renderer doesn't see a
            // dangling wide cell.
            if (needs_blank_left_half) {
                row_mut[cursor_col - 1] = Cell{ .style = self.blankFor(cell.style) };
            }

            // Wide char or grapheme wide at last column
            // No room for the right-half placeholder, fill this column with a blank,
            // wrap inline, then place the wide char at column 0 of the new row_mut.
            if (wide_at_end) {
                const old_row = self.cursor.row;
                row_mut[cursor_col] = Cell{ .style = self.blankFor(cell.style), .wrapped = true };

                // Wrap/scroll logic (same logic as deferred wrap above).
                self.cursor.col = 0;
                if (self.cursor.row == self.scroll_bottom) {
                    _ = self.scrollUpImpl(1);
                } else if (self.cursor.row + 1 < self.active_rows) {
                    self.cursor.row = @intCast(self.cursor.row + 1);
                }

                // Re-fetch row_mut after potential scroll (ring buffer may have advanced).
                const new_row_mut = self.rowMutBase(self.cursor.row, false);
                new_row_mut[0] = cell;
                new_row_mut[1] = Cell{
                    .codepoint = 0,
                    .kind = .wide_right, // always, regardless of left-half kind
                    .flags = cell.flags,
                    .style = cell.style,
                };

                self.dirty_rows.set(old_row); // old row got a blank
                self.dirty_rows.set(self.cursor.row); // new row got the wide char

                // bounds-check cursor advance, after writing the wide char at col 0
                // and right-half at col 1, if active_cols == 2, col 2 is out of bounds
                // and wrap_pending should be set (same pattern as the normal cursor
                // advance at the bottom of the function).
                const next: usize = 2;
                if (next >= self.active_cols) {
                    self.cursor.col = @intCast(self.active_cols - 1);
                    self.cursor.wrap_pending = self.mode.auto_wrap;
                } else {
                    self.cursor.col = 2;
                    self.cursor.wrap_pending = false;
                }
                return;
            }

            // Split-wide-char guard our right-half slot contains a left-half
            // of another wide char, blank its orphaned right half.
            if (needs_blank_right_of_right) {
                @branchHint(.unlikely);
                row_mut[cursor_col + 2] = Cell{ .style = self.blankFor(cell.style) };
            }

            if (needs_blank_right_of_self) {
                @branchHint(.unlikely);
                row_mut[cursor_col + 1] = Cell{ .style = self.blankFor(cell.style) };
            }

            // Write the cell
            row_mut[cursor_col] = cell;
            self.dirty_rows.set(self.cursor.row);

            if (is_wide) {
                row_mut[cursor_col + 1] = Cell{
                    .codepoint = 0,
                    .kind = .wide_right, // always, regardless of left-half kind
                    .flags = cell.flags,
                    .style = cell.style,
                };
            }

            // Advance cursor
            const next_col = cursor_col + cell.kind.columnSpan();
            if (next_col >= self.active_cols) {
                self.cursor.col = @intCast(self.active_cols - 1);
                self.cursor.wrap_pending = self.mode.auto_wrap;
            } else {
                self.cursor.col = @intCast(next_col);
            }
        }

        /// Repeat the last graphic character n times (REP / CSI Ps b).
        ///
        /// Repeats the last character written by `putChar`, using the **current**
        /// cursor attributes (not the attributes of the original character).
        /// n=0 is treated as n=1 (ECMA-48 default parameter rule).
        /// No-op if no character has been written yet (last_char == 0).
        /// Does NOT update last_char only putChar does.
        pub fn repeatChar(self: *Self, n: usize) void {
            if (self.last_char == 0) return;

            // last_char is always a plain codepoint, never a grapheme ID.
            // putChar sets self.last_char = translated where translated is
            // the charset-translated codepoint.
            //
            // Grapheme sequences (ZWJ etc.) go through a different path and
            // don't update last_char. So repeatChar only ever produces
            // .narrow or .wide_left cells, .grapheme and .grapheme_wide
            // are never needed here.
            //
            // This matches the ECMA-48 REP spec (repeats the last graphic character,
            // not a composed sequence).
            const kind: CellKind = switch (width(self.last_char)) {
                .wide => .wide_left,
                .narrow => .narrow,
                // guard: combining or non-printable (last_char should never be these)
                .zero, .control => return,
            };
            const count = @max(n, 1);

            for (0..count) |_| {
                self.writeChar(.{
                    .kind = kind,
                    .codepoint = self.last_char,
                    .style = self.cursor.attr.id,
                    .flags = self.cursor.attr.flags,
                });
            }

            // FIXME called bump every writeChar bad for hot-paths.
            // This case can be addressed later by batching the writes.

            // NOTE last_char is intentionally NOT updated here.
            // NOTE writeChar calls bump() each iteration that's fine.
        }

        /// Scans left/right from `col` on the given anchor's row, extending while
        /// `canJoin` holds against the clicked cell's class. Returns the inclusive
        /// `[left, right]` column bounds.
        pub fn wordsBoundsAt(
            self: *const Self,
            classifier: *const Classifier,
            anchor: i64,
            col: u16,
            join_option: Classifier.JoinOption,
        ) struct { u16, u16 } {
            const row_cells = self.rowCellsAtAnchor(anchor);

            // If click landed on the right half of a wide char, snap to its left half so origin
            // classification reflects the actual glyph, not a meaningless placeholder.
            const origin_col: u16 = if (row_cells[col].kind == .wide_right and col > 0) col - 1 else col;
            const origin_cp = self.resolveCodepoint(row_cells[origin_col]);
            const origin_class = classifier.classify(origin_cp);

            var left: u16 = origin_col;
            while (left > 0) {
                // .wide_right is never an independent boundary — it's transparent,
                // always paired with the .wide_left immediately before it.
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

        /// Write a cell. Bounds-checked; silently ignores out-of-range writes.
        /// Does NOT handle `wrap_pending` or insert_mode, use `writeChar()` for that.
        pub inline fn setCell(self: *Self, r: usize, c: usize, cell: Cell) void {
            if (r >= self.active_rows or c >= self.active_cols) {
                @branchHint(.cold);
                return;
            }
            self.rowMut(r)[c] = cell;
        }

        /// Returns the `max_cols`-wide cell slice for the given anchor row, where
        /// anchor space is defined the same way as Position.row:
        ///
        /// anchor = display_row_at_capture - viewport_offset_at_capture
        ///
        /// i.e. anchor 0 is the top of the *live* active area (viewport_offset == 0),
        /// negative anchors reach into scrollback.
        ///
        /// Unlike `rowMut`/`row` (which take a logical row bounded to the active area)
        /// or `displayRow` (which is viewport-relative and bounded to `active_rows`),
        /// this accessor is independent of both `viewport_offset` and `active_rows`,
        /// it resolves directly against `scroll_offset`, so it stays correct regardless
        /// of where the user has currently scrolled to.
        ///
        /// Caller must ensure `anchor >= -scrollback_used_signed` (i.e. not requesting an
        /// already-evicted row), this is not checked here; use `resolveAnchor`'s eviction
        /// guard before calling this.
        inline fn rowCellsAtAnchor(self: *const Self, anchor: i64) []const Cell {
            if (anchor >= 0) {
                std.debug.assert(anchor < @as(i64, @intCast(max_rows)));
                return self.cells[self.physRow(@intCast(anchor)) * max_cols ..][0..max_cols];
            } else if (comptime is_scrollback_used) {
                const back_i64 = -anchor;

                std.debug.assert(
                    back_i64 <= @as(i64, @intCast(self.scrollback_used)),
                );

                const back: usize = @intCast(back_i64);

                // Negative anchors bypass row_map because scrollback is in
                // fixed physical ring order.
                const phys = (self.scroll_offset -% back) & ring_mask;
                return self.cells[phys * max_cols ..][0..max_cols];
            } else {
                unreachable;
            }
        }

        /// Single-cell accessor built on `rowCellsAtAnchor`, mirroring `cellAt`'s
        /// signature but in anchor space instead of active-area-relative space.
        pub inline fn cellAtAnchor(self: *const Self, anchor: i64, c: usize) Cell {
            return self.rowCellsAtAnchor(anchor)[c];
        }

        /// Read a cell. Caller must ensure `row` and `col` are in bounds.
        pub inline fn cellAt(self: *const Self, r: usize, c: usize) Cell {
            return self.cells[self.physRow(r) * max_cols + c];
        }

        /// Signal that visible state has changed. The renderer rebuilds the
        /// instance buffer on the next frame when it sees a new generation.
        pub inline fn bump(self: *Self) void {
            self.generation +%= 1;
        }

        /// Mark a single logical row dirty and bump generation.
        /// Use this for single-row mutations (cursor move, cell write, etc.).
        /// For bulk operations, call dirty_rows.set() in a loop then bump() once.
        pub inline fn markDirty(self: *Self, r: usize) void {
            self.dirty_rows.set(r);
            self.bump();
        }

        /// Returns the effective top row for cursor positioning.
        /// In DECOM (origin mode), the cursor is relative to `scroll_top`.
        pub inline fn effectiveTop(self: *const Self) usize {
            return if (self.cursor.origin) self.scroll_top else 0;
        }

        // Callers build `blank` from the style alone, so the default style
        // means `Cell{}`, which `zeroRow` fills fastest.
        inline fn clearRow(self: *Self, r: usize, blank: Cell) void {
            const row_mut = self.rowMutRaw(r)[0..self.active_cols];
            if (blank.style == Style.Table.default_id) {
                zeroRow(row_mut.ptr, row_mut.len);
            } else {
                @memset(row_mut, blank);
            }
        }

        fn setDirtyAll(self: *Self) void {
            if (comptime max_rows <= @bitSizeOf(usize)) {
                self.dirty_rows.mask = ~@as(std.meta.Int(.unsigned, max_rows), 0);
            } else {
                inline for (0..self.dirty_rows.masks.len) |i| {
                    self.dirty_rows.masks[i] = if (i < self.dirty_rows.masks.len - 1)
                        std.math.maxInt(usize)
                    else
                        @TypeOf(self.dirty_rows).last_item_mask;
                }
            }
        }

        /// Rotates `row_map[lo..hi+1]` by `amount` in the given direction.
        ///
        /// `left`  : element at `lo + amount` becomes the new first element
        ///           (matches `std.mem.rotate`'s native semantics — used by
        ///           scrollUp/deleteLines, which shift content toward `lo`).
        /// `right` : mirror image — used by scrollDown/insertLines, which shift
        ///           content toward `hi`.
        ///
        /// Also lazily materializes the full identity map on first mutation
        /// (once per lifecycle, not once per call) and bumps `row_map_generation`
        /// exactly once per actual permutation. No-op rotations (amount == 0 or
        /// amount % len == 0) skip both the identity materialization and the
        /// generation bump entirely.
        fn rotateRowMapRegion(
            self: *Self,
            affected_lo: usize,
            affected_hi: usize,
            amount: usize,
            comptime direction: Rotation,
        ) void {
            std.debug.assert(affected_lo <= affected_hi);
            std.debug.assert(affected_hi < self.active_rows);

            const len = affected_hi - affected_lo + 1;
            const normalized = amount % len;

            // no-op rotation: skip initialization + generation bump
            if (normalized == 0) return;

            // Materialize the full identity map (not just[lo..hi]) on first use,
            // exactly once per lifecycle/reset, this only runs while
            // row_map_is_identity is still true, so repeated calls are free.
            if (self.row_map_is_identity) {
                for (0..self.active_rows) |i| self.row_map[i] = @intCast(i);
                self.row_map_is_identity = false;

                self.row_map_lo = @intCast(affected_lo);
                self.row_map_hi = @intCast(affected_hi);
            } else {
                self.row_map_lo = @min(self.row_map_lo, @as(u16, @intCast(affected_lo)));
                self.row_map_hi = @max(self.row_map_hi, @as(u16, @intCast(affected_hi)));
            }

            const slice = self.row_map[affected_lo .. affected_hi + 1];

            // Number of elements that need to be temporarily saved.
            const k = @min(normalized, len - normalized);

            // Whether the optimized operation should be a left rotation.
            //
            // Examples:
            //   left by 1  -> left by 1
            //   left by 22 in len 23 -> right by 1
            //   right by 1 -> right by 1
            //   right by 22 in len 23 -> left by 1

            const use_left_rotation = switch (direction) {
                .left => normalized <= len / 2,
                .right => normalized > len / 2,
            };

            const small_k_threshold = 64;
            if (k <= small_k_threshold) {
                var scratch: [small_k_threshold]u16 = undefined;

                if (use_left_rotation) {
                    // Rotate left by k:
                    //
                    // [A B C D] -> [C D A B]
                    //
                    // Save A B, shift C D forward, restore A B at the end.
                    @memcpy(
                        scratch[0..k],
                        slice[0..k],
                    );

                    @memmove(
                        slice[0 .. len - k],
                        slice[k..len],
                    );

                    @memcpy(
                        slice[len - k .. len],
                        scratch[0..k],
                    );
                } else {
                    // Rotate right by k:
                    //
                    // [A B C D] -> [C D A B]
                    //
                    // Save C D, shift A B backward, restore C D at the front.
                    @memcpy(
                        scratch[0..k],
                        slice[len - k .. len],
                    );

                    @memmove(
                        slice[k..len],
                        slice[0 .. len - k],
                    );

                    @memcpy(
                        slice[0..k],
                        scratch[0..k],
                    );
                }
            } else {
                const left_amount = switch (direction) {
                    .left => normalized,
                    .right => len - normalized,
                };

                std.mem.rotate(u16, slice, left_amount);
            }

            self.row_map_generation +%= 1;
        }

        /// Slow path for canonicalizing a non-identity row_map.
        ///
        /// This function is intentionally noinline because it allocates the
        /// row-sized scratch buffer on its stack.
        noinline fn canonicalizeRowMapImpl(self: *Self) void {
            // The inline wrapper guarantees this.
            std.debug.assert(!self.row_map_is_identity);
            std.debug.assert(self.active_rows <= max_rows);

            // A non-identity map must have a valid affected range.
            std.debug.assert(self.row_map_lo <= self.row_map_hi);
            std.debug.assert(self.row_map_hi < self.active_rows);

            const lo = self.row_map_lo;
            const end = self.row_map_hi + 1; // Inclusive hi .. exclusive end.

            var visited: std.bit_set.StaticBitSet(max_rows) = .empty;
            var scratch: [max_cols]Cell = undefined;
            var scratch_attr: LineAttr = undefined;

            // Apply the permutation in place using cycle decomposition.
            // Only rows in the affected range can participate in non-trivial cycles.
            for (lo..end) |start| {
                if (visited.isSet(start)) continue;

                var i = start;

                if (self.row_map[i] == i) {
                    visited.set(i);
                    continue;
                }

                // Save the row at start's physical slot.
                const start_phys = wrapAdd(self.scroll_offset, start);

                @memcpy(
                    &scratch,
                    self.cells[start_phys * max_cols ..][0..max_cols],
                );
                scratch_attr = self.line_attrs[start_phys];

                while (true) {
                    std.debug.assert(i >= lo);
                    std.debug.assert(i < end);
                    std.debug.assert(!visited.isSet(i));

                    visited.set(i);

                    const src_logical = self.row_map[i];

                    // Every member of a non-trivial cycle must stay in the affected range.
                    std.debug.assert(src_logical >= lo);
                    std.debug.assert(src_logical < end);

                    const dst_phys = wrapAdd(self.scroll_offset, i);

                    if (src_logical == start) {
                        // Close the cycle with the saved first row.
                        @memcpy(
                            self.cells[dst_phys * max_cols ..][0..max_cols],
                            &scratch,
                        );
                        self.line_attrs[dst_phys] = scratch_attr;
                        break;
                    }

                    const src_phys = wrapAdd(self.scroll_offset, src_logical);
                    @memcpy(
                        self.cells[dst_phys * max_cols ..][0..max_cols],
                        self.cells[src_phys * max_cols ..][0..max_cols],
                    );
                    self.line_attrs[dst_phys] = self.line_attrs[src_phys];

                    i = src_logical;
                }
            }

            // Only rows in the affected range can participate in non-trivial cycles.
            for (lo..end) |r| self.row_map[r] = @intCast(r);

            // Set the physical rows and logical map are canonical again.
            self.row_map_is_identity = true;
            self.row_map_lo = 0;
            self.row_map_hi = 0;
            self.row_map_generation +%= 1;
        }

        /// Physically reorders rows when a non-identity row_map is pending.
        ///
        /// The identity case stays inline so callers avoid a function call and
        /// avoid reserving the canonicalization scratch buffer in their stack frame.
        inline fn canonicalizeRowMap(self: *Self) void {
            if (self.row_map_is_identity) return;
            self.canonicalizeRowMapImpl();
        }

        fn scrollUpImpl(self: *Self, n: usize) bool {
            // A degenerate region (top >= bottom) has nothing to scroll.
            if (self.scroll_top >= self.scroll_bottom) return false;

            const blank: Cell = .{ .style = self.cursor.attr.blank_id };
            const region_top: usize = self.scroll_top;
            const region_bottom: usize = self.scroll_bottom;
            const region_height: usize = region_bottom - region_top + 1;

            // Clamp, scrolling more than the region height is equivalent to
            // scrolling exactly region_height lines.
            const count: usize = @min(@max(n, 1), region_height);

            if (self.active_rows == 0) return false;
            const is_full_screen = self.scroll_top == 0 and self.scroll_bottom == self.active_rows - 1;

            if (is_full_screen) {
                std.debug.assert(self.active_rows <= max_rows);
                std.debug.assert(self.scroll_offset < ring_rows);
                std.debug.assert(count <= self.active_rows);

                self.canonicalizeRowMap();

                const next_scroll_offset = wrapAdd(
                    @as(usize, self.scroll_offset),
                    count,
                );

                // Advance scroll_offset by count in one step
                self.scroll_offset = @intCast(next_scroll_offset);
                self.total_lines_scrolled += @intCast(count);

                //   phys_start =
                //       (old_scroll_offset + active_rows) % ring_rows
                //
                // because:
                //
                //   next_scroll_offset + active_rows - count
                //       = old_scroll_offset + count + active_rows - count
                //       = old_scroll_offset + active_rows
                const phys_start = wrapAdd(
                    next_scroll_offset,
                    self.active_rows - count,
                );
                const phys_end_total = phys_start + count;

                // clear cells
                var r = phys_start;
                var remaining = count;

                while (remaining > 0) : (remaining -= 1) {
                    const row_start = r * max_cols;
                    const row_cells =
                        self.cells[row_start .. row_start + self.active_cols];

                    if (blank.style == Style.Table.default_id) {
                        zeroRow(row_cells.ptr, row_cells.len);
                    } else {
                        @branchHint(.unlikely);
                        @memset(row_cells, blank);
                    }

                    r = (r + 1) & ring_mask;
                }

                if (phys_end_total <= ring_rows) {
                    for (self.line_attrs[phys_start .. phys_start + count]) |*a| a.* = .normal;
                } else {
                    for (self.line_attrs[phys_start..ring_rows]) |*a| a.* = .normal;
                    for (self.line_attrs[0 .. phys_end_total - ring_rows]) |*a| a.* = .normal;
                }

                if (comptime is_scrollback_used) {
                    self.scrollback_used = @min(self.scrollback_used + count, max_scrollback);
                    if (self.viewport_offset > 0) {
                        self.viewport_offset = @min(self.viewport_offset + @as(u32, @intCast(count)), self.scrollback_used);
                    }
                }

                self.setDirtyAll();
            } else {
                // Partial scroll region, use single bulk-copy pass.
                //
                // Shift rows [region_top+count .. region_bottom] up to
                // [region_top .. region_bottom-count] in one forward pass.
                // A forward (ascending) pass is correct because the destination
                // index is always strictly less than the source index, so there
                // is no overlap that would corrupt data.
                //
                // The previous implementation used a nested loop:
                //   outer: count iterations, inner: region_height copies
                self.rotateRowMapRegion(region_top, region_bottom, count, .left);

                // Clear the count vacated rows at the bottom of the region.
                // Their row_map entries now point to the evicted physical slots.
                for (region_bottom + 1 - count..region_bottom + 1) |r| {
                    const phys = self.physRow(r);
                    // pass phys directly to avoid recomputing inside clearRow
                    const row_mut = self.cells[phys * max_cols ..][0..self.active_cols];
                    if (blank.style == Style.Table.default_id) {
                        zeroRow(row_mut.ptr, row_mut.len);
                    } else {
                        // most terminals use default background tho
                        @branchHint(.unlikely);
                        @memset(row_mut, blank);
                    }
                    self.line_attrs[phys] = .normal;
                }

                // Mark the entire region dirty in one operation
                self.dirty_rows.setRangeValue(.{ .start = region_top, .end = region_bottom + 1 }, true);
            }

            self.cached_row_phys = max_u16; // ring buffer rotated, cache is stale
            return true;
        }

        /// Scroll the scroll region up by `n` lines.
        ///
        /// Handles:
        /// Full-screen scroll (scroll_top=0, scroll_bottom=active_rows-1):
        ///    O(count), advances the ring buffer head pointer once per line.
        ///    The row that falls off the top is preserved as scrollback history.
        ///    Clearing the newly exposed bottom row is unavoidable.
        ///
        /// Partial-region scroll:
        ///    O(region_height × active_cols), a single forward bulk-copy pass
        ///    shifts all rows up by `count` positions, then clears the vacated
        ///    bottom rows. This is optimal for a flat cell array; avoiding the
        ///    copy entirely would require a row-indirection table at the cost of
        ///    an extra pointer chase on every cell access.
        ///
        /// In both cases `count = min(n, region_height)` so over-scrolling is safe.
        pub inline fn scrollUp(self: *Self, n: usize) void {
            if (self.scrollUpImpl(n)) self.bump();
        }

        /// Scroll the scroll region down by `n` lines (reverse scroll / RI).
        /// Lines that scroll off the bottom are discarded.
        ///
        /// Always a row_map rotation, O(region_height), full screen
        /// included. Moving the ring head back instead would overwrite the
        /// newest scrollback lines, and xterm leaves scrollback untouched
        /// on reverse scroll. Reverse scroll is rare (RI, SD), so the
        /// canonicalize cost on the next full-screen scrollUp is fine.
        pub noinline fn scrollDown(self: *Self, n: usize) void {
            if (self.scroll_top >= self.scroll_bottom) return;

            const region_top: usize = self.scroll_top;
            const region_bot: usize = self.scroll_bottom;
            const region_height = region_bot - region_top + 1;

            const count: usize = @min(@max(n, 1), region_height);
            const blank: Cell = .{ .style = self.cursor.attr.blank_id };

            self.rotateRowMapRegion(region_top, region_bot, count, .right);

            // Clear the count vacated rows at the TOP of the region
            for (region_top..region_top + count) |r| {
                const phys = self.physRow(r);
                const row_mut = self.cells[phys * max_cols ..][0..self.active_cols];
                if (blank.style == Style.Table.default_id) {
                    zeroRow(row_mut.ptr, row_mut.len);
                } else {
                    @memset(row_mut, blank);
                }
                self.line_attrs[phys] = .normal;
            }

            self.dirty_rows.setRangeValue(.{ .start = region_top, .end = region_bot + 1 }, true);
            self.cached_row_phys = max_u16; // row_map rotated, cache is stale
            self.bump();
        }

        /// Set Scroll Region (DECSTBM / CSI Ps; Ps r).
        ///
        /// Sets the top and bottom margins of the scroll region used by
        /// `scrollUp`, `scrollDown`, `index`, `reverseIndex`, `insertLines`,
        /// and `deleteLines`.
        ///
        /// Parameters are 1-based (matching the raw CSI values from the parser).
        /// A value of 0 is treated as default: 1 for `top`, `active_rows` for `bottom`.
        ///
        /// Validation rules (per xterm / ECMA-48 S8.3.192):
        ///   - `top` must be strictly less than `bottom` (1-based).
        ///   - `bottom` must be ≤ `active_rows`.
        ///   - Any violation is silently ignored; no state is changed.
        ///
        /// On a valid set the cursor is moved to the "home" position:
        ///   - Normal mode (DECOM off): absolute (0, 0).
        ///   - Origin mode (DECOM on) : (scroll_top, 0) the top of the new region.
        ///
        /// `wrap_pending` is always cleared on a valid set.
        pub fn setScrollRegion(self: *Self, top: usize, bottom: usize) void {
            // Resolve defaults: 0 to canonical default value.
            const t: usize = if (top == 0) 1 else top;
            const b: usize = if (bottom == 0) self.active_rows else bottom;

            // Validate, t is always >= 1 after default resolution.
            if (t >= b or b > self.active_rows) {
                @branchHint(.cold);
                return;
            }

            self.scroll_top = @intCast(t - 1);
            self.scroll_bottom = @intCast(b - 1);
            self.cursorPos(0, 0);
        }

        /// Erase display (ED / CSI Ps J).
        ///
        ///   0 = cursor to end of screen
        ///   1 = start of screen to cursor
        ///   2 = entire screen (cursor stays)
        ///   3 = erase scrollback (xterm extension, CSI 3 J)
        ///
        /// Clears `wrap_pending`.
        pub fn eraseDisplay(self: *Self, mode: u16) void {
            const blank: Cell = .{ .style = self.cursor.attr.blank_id };

            switch (mode) {
                0 => { // cursor to end
                    // Cursor row: partial erase; keep its line_attr.
                    @memset(self.rowMut(self.cursor.row)[self.cursor.col..self.active_cols], blank);

                    // Rows below cursor: fully erased; reset line_attrs.
                    var r: usize = @as(usize, self.cursor.row) + 1;
                    while (r < self.active_rows) : (r += 1) {
                        @memset(self.rowMut(r)[0..self.active_cols], blank);
                        self.line_attrs[self.physRow(r)] = .normal;
                    }
                },
                1 => { // start to cursor
                    // Rows above cursor: fully erased; reset line_attrs.
                    var r: usize = 0;
                    while (r < self.cursor.row) : (r += 1) {
                        @memset(self.rowMut(r)[0..self.active_cols], blank);
                        self.line_attrs[self.physRow(r)] = .normal;
                    }

                    // Cursor row: partial erase; keep its line_attr.
                    @memset(self.rowMut(self.cursor.row)[0 .. @as(usize, self.cursor.col) + 1], blank);
                },
                2 => {
                    // Entire active area erased; reset ALL line_attrs.
                    self.dirty_rows = .full;
                    var r: usize = 0;
                    while (r < self.active_rows) : (r += 1) {
                        const phys = self.physRow(r);
                        @memset(self.cells[phys * max_cols ..][0..self.active_cols], blank);
                        self.line_attrs[phys] = .normal;
                        //                         @memset(self.rowMutRaw(r)[0..self.active_cols], blank);
                        //                         self.line_attrs[self.physRow(r)] = .normal;
                    }
                    // The intern table is not reset here: scrollback cells
                    // still reference it. `compactGraphemes` reclaims it.
                },
                3 => {
                    // Erase scrollback history without touching the active area.
                    // On alternate screen (max_scrollback=0) this is a no-op; correct per xterm behavior.
                    if (comptime is_scrollback_used) {
                        self.scrollback_used = 0;
                        self.viewport_offset = 0;
                        self.dirty_rows = .full;
                        // No line_attr reset, scrollback rows have no line attrs
                    }
                },
                else => return, // Unknown mode; no state change, no bump.
            }

            if (mode != 3) self.cursor.wrap_pending = false;
            // Content was dropped, so a full style table may free a lot.
            if (mode >= 2) self.styles.requestSweep();
            self.bump();
        }

        /// Erase line (EL / CSI Ps K).
        ///
        ///   0 = cursor to end of line   (most common — used by shells on every prompt)
        ///   1 = start of line to cursor (inclusive)
        ///   2 = entire line
        ///
        /// The cursor position is not changed by any mode.
        /// Does not interact with scrollback. Clears `wrap_pending`.
        pub fn eraseLine(self: *Self, mode: u16) void {
            const blank: Cell = .{ .style = self.cursor.attr.blank_id };
            const r = @as(usize, self.cursor.row);
            const c = @as(usize, self.cursor.col);
            switch (mode) {
                0 => @memset(self.rowMut(r)[c..self.active_cols], blank), // partial; keep line_attr
                1 => @memset(self.rowMut(r)[0 .. c + 1], blank), // partial; keep line_attr
                2 => { // full erase; reset line_attr
                    @memset(self.rowMut(r)[0..self.active_cols], blank);
                    self.line_attrs[self.physRow(r)] = .normal;
                },
                else => return, // Unknown mode; no state change, no bump.
            }
            self.cursor.wrap_pending = false;
            self.bump();
        }

        /// Resize the active area to `row_size x col_size`.
        ///
        /// Clamps to `max_rows` / `max_cols`. Resets the scroll region
        /// to the full active area and clams the cursor to the new bounds.
        /// Clears `wrap_pending` if the cursor is no longer at the last column.
        pub fn setActive(self: *Self, row_size: usize, col_size: usize) void {
            const new_rows: usize = @min(row_size, max_rows);
            const new_cols: usize = @min(col_size, max_cols);

            const old_rows = self.active_rows;
            const old_cols = self.active_cols;

            const was_empty = old_rows == 0 or old_cols == 0;

            // Must happen before changing active_rows.
            //
            // This is unconditional because the code below may rewrite row_map when
            // was_empty is true, even if the row count itself does not change.
            // canonicalizeRowMap() returns immediately when the map is already identity.
            self.canonicalizeRowMap();

            if (new_rows == 0 or new_cols == 0) {
                self.active_rows = @intCast(new_rows);
                self.active_cols = @intCast(new_cols);
                self.bump();
                return;
            }

            if (!was_empty) {
                if (new_rows < old_rows) { // Height decrease
                    // If the cursor would fall outside the new viewport, scroll the screen up
                    // so the cursor and current line stay visible, pushing top rows to scrollback.
                    if (self.cursor.row >= new_rows) {
                        const scroll_count = self.cursor.row - (new_rows - 1);
                        // Advance scroll_offset to scroll the viewport down
                        self.scroll_offset = @intCast(wrapAdd(self.scroll_offset, scroll_count));
                        self.total_lines_scrolled += @intCast(scroll_count);

                        if (comptime is_scrollback_used) {
                            self.scrollback_used = @min(self.scrollback_used + scroll_count, max_scrollback);
                        }

                        self.cursor.row = @intCast(new_rows - 1);
                        self.saved_cursor.row = self.saved_cursor.row -| @as(u16, @intCast(scroll_count));
                    }
                } else if (new_rows > old_rows) { // Height increase
                    // Pull lines back down from scrollback if available, keeping bottom content anchored.
                    var pull: usize = 0;
                    if (comptime is_scrollback_used) {
                        pull = @min(new_rows - old_rows, self.scrollback_used);
                        if (pull > 0) {
                            self.scroll_offset = @intCast((self.scroll_offset + ring_rows - pull) & ring_mask);
                            self.scrollback_used -= @intCast(pull);
                            self.total_lines_scrolled -= @intCast(pull);
                            self.cursor.row = @min(self.cursor.row + @as(u16, @intCast(pull)), @as(u16, @intCast(new_rows - 1)));
                            self.saved_cursor.row = @min(self.saved_cursor.row + @as(u16, @intCast(pull)), @as(u16, @intCast(new_rows - 1)));
                        }
                    }

                    // Only clear rows that are still newly exposed beyond what was pulled from scrollback
                    const clear_from = old_rows + pull;
                    for (clear_from..new_rows) |r| {
                        self.clearRow(r, .{});
                        self.line_attrs[self.physRow(r)] = .normal;
                    }
                }
            } else {
                // Initial setup or restoring from zero size: clear full active area
                for (0..new_rows) |r| {
                    self.clearRow(r, .{});
                    self.line_attrs[self.physRow(r)] = .normal;
                }
            }

            self.active_rows = @intCast(new_rows);
            self.active_cols = @intCast(new_cols);

            self.dirty_rows = .full;
            self.scroll_top = 0;
            self.scroll_bottom = self.active_rows - 1;

            self.cursor.row = @min(self.cursor.row, self.active_rows - 1);
            self.cursor.col = @min(self.cursor.col, self.active_cols - 1);

            if (self.cursor.col < self.active_cols - 1) {
                self.cursor.wrap_pending = false;
            }

            self.cached_row_phys = max_u16;
            self.bump();
        }

        /// Reflows the entire screen history and active area to `new_rows x new_cols`.
        pub fn reflowBuffer(self: *Self, new_rows: usize, new_cols: usize) void {
            // Precondition: alternate screen / zero-scrollback never reflow (TUI
            // apps manage their own grid).
            if (comptime !is_scrollback_used) return;

            // No-op if columns haven't changed or dimensions are empty
            if (new_cols == self.active_cols) return;
            if (new_rows == 0 or new_cols == 0) return;
            if (self.active_rows == 0 or self.active_cols == 0) return;
            if (new_rows > max_rows or new_cols > max_cols) return;

            const scratch = self.scratch_cells;

            // Identify active content boundary and cursor source positions
            // Trailing unwritten empty rows below the cursor must NOT be reflowed as content,
            // otherwise they would be pushed into scrollback as empty lines!
            var active_content_rows: usize = @min(self.active_rows, @max(@as(usize, self.cursor.row) + 1, @as(usize, self.saved_cursor.row) + 1));
            var check_r: usize = self.active_rows;
            while (check_r > active_content_rows) : (check_r -= 1) {
                const r_idx = check_r - 1;
                const phys = self.physRow(r_idx);
                const row_cells = self.cells[phys * max_cols ..][0..self.active_cols];
                var empty = true;
                for (row_cells) |*c| {
                    if (c.kind != .empty or c.style != Style.Table.default_id or c.wrapped) {
                        empty = false;
                        break;
                    }
                }
                if (!empty) {
                    active_content_rows = r_idx + 1;
                    break;
                }
            }

            const cursor_phys = self.physRow(self.cursor.row);
            const saved_cursor_phys = self.physRow(self.saved_cursor.row);
            const scrollback_count: usize = self.scrollback_used;
            const total_valid_rows = scrollback_count + active_content_rows;

            var new_cursor_row: usize = 0;
            var new_cursor_col: usize = 0;
            const new_cursor_wrap: bool = self.cursor.wrap_pending;
            var new_saved_row: usize = 0;
            var new_saved_col: usize = 0;
            var dst_row: usize = 0;
            var dst_col: usize = 0;
            // Where the right half of the last wide character was written. A
            // cursor on a right half maps there: once the pair ends a
            // destination row, the row has already wrapped and `dst_col - 1`
            // would point before column 0.
            var right_half_row: usize = 0;
            var right_half_col: usize = 0;

            // Lazily clear the first row in scratch
            @memset(scratch[0..max_cols], Cell{});

            // Sequential streaming pass
            for (0..total_valid_rows) |stream_idx| {
                const is_history = stream_idx < self.scrollback_used;
                const src_phys = if (is_history)
                    (self.scroll_offset + ring_rows - self.scrollback_used + stream_idx) & ring_mask
                else
                    self.physRow(stream_idx - self.scrollback_used);
                const src_row_cells = self.cells[src_phys * max_cols ..][0..self.active_cols];
                const is_cursor_row = !is_history and (src_phys == cursor_phys);
                const is_saved_row = !is_history and (src_phys == saved_cursor_phys);

                // Check if this row soft-wrapped into the next
                const is_soft_wrap = src_row_cells[self.active_cols - 1].wrapped;

                // Content length for this row:
                var valid_cols: usize = self.active_cols;
                if (is_soft_wrap) {
                    // Check if last cell was padding for a wide char that wrapped
                    if (src_row_cells[self.active_cols - 1].kind == .empty) {
                        valid_cols = self.active_cols - 1;
                    }
                } else {
                    // Hard break: trim trailing default empty cells
                    while (valid_cols > 0 and
                        src_row_cells[valid_cols - 1].kind == .empty and
                        src_row_cells[valid_cols - 1].style == Style.Table.default_id) : (valid_cols -= 1)
                    {}
                }

                var cursor_tracked = false;
                var saved_cursor_tracked = false;

                // Stream cells into scratch buffer
                for (src_row_cells[0..valid_cols], 0..) |c, src_col| {
                    // Skip wide_right placeholder since it's already written with
                    // wide_left. A right half without its left half before it
                    // breaks the pair invariant; a cursor on it maps to the
                    // next free position instead of trusting the record.
                    if (c.kind == .wide_right) {
                        const paired = src_col > 0 and src_row_cells[src_col - 1].kind.isWideLeft();
                        const half_row = if (paired) right_half_row else dst_row;
                        const half_col = if (paired) right_half_col else dst_col;
                        if (is_cursor_row and src_col == self.cursor.col) {
                            new_cursor_row = half_row;
                            new_cursor_col = half_col;
                            cursor_tracked = true;
                        }
                        if (is_saved_row and src_col == self.saved_cursor.col) {
                            new_saved_row = half_row;
                            new_saved_col = half_col;
                            saved_cursor_tracked = true;
                        }
                        continue;
                    }

                    const is_wide = c.kind.isWideLeft();
                    const span: usize = if (is_wide) 2 else 1;

                    // Wide character margin check: cannot fit 2-cell character at line end
                    if (is_wide and dst_col == new_cols - 1) {
                        scratch[(dst_row & ring_mask) * max_cols + dst_col] = Cell{ .kind = .empty, .wrapped = true };
                        dst_row += 1;
                        dst_col = 0;
                        const next_p = dst_row & ring_mask;
                        @memset(scratch[next_p * max_cols .. (next_p + 1) * max_cols], Cell{});
                    }

                    // Track cursor position on-the-fly (after margin wrap so cursor stays with glyph)
                    if (is_cursor_row and src_col == self.cursor.col) {
                        new_cursor_row = dst_row;
                        new_cursor_col = dst_col;
                        cursor_tracked = true;
                    }
                    if (is_saved_row and src_col == self.saved_cursor.col) {
                        new_saved_row = dst_row;
                        new_saved_col = dst_col;
                        saved_cursor_tracked = true;
                    }

                    var cell_to_write = c;
                    cell_to_write.wrapped = false; // reset wrapped flag on interior cells
                    scratch[(dst_row & ring_mask) * max_cols + dst_col] = cell_to_write;

                    if (is_wide) {
                        right_half_row = dst_row;
                        right_half_col = dst_col + 1;
                        scratch[(dst_row & ring_mask) * max_cols + dst_col + 1] = Cell{
                            .codepoint = 0,
                            .kind = .wide_right,
                            .flags = c.flags,
                            .style = c.style,
                            .wrapped = false,
                        };
                    }

                    dst_col += span;
                    if (dst_col >= new_cols) {
                        const has_more = (src_col + span < valid_cols) or is_soft_wrap;
                        if (has_more) {
                            scratch[(dst_row & ring_mask) * max_cols + (new_cols - 1)].wrapped = true;
                            dst_row += 1;
                            dst_col = 0;
                            const next_p = dst_row & ring_mask;
                            @memset(scratch[next_p * max_cols .. (next_p + 1) * max_cols], Cell{});
                        }
                    }
                }

                if (is_cursor_row and !cursor_tracked) {
                    new_cursor_row = dst_row;
                    const delta = self.cursor.col -| @as(u16, @intCast(valid_cols));
                    new_cursor_col = dst_col + delta;
                }
                if (is_saved_row and !saved_cursor_tracked) {
                    new_saved_row = dst_row;
                    const delta = self.saved_cursor.col -| @as(u16, @intCast(valid_cols));
                    new_saved_col = dst_col + delta;
                }

                // If hard break, finalize current row and advance to next row
                if (!is_soft_wrap) {
                    if (dst_col > 0 or valid_cols == 0) {
                        dst_row += 1;
                        dst_col = 0;
                        const next_p = dst_row & ring_mask;
                        @memset(scratch[next_p * max_cols .. (next_p + 1) * max_cols], Cell{});
                    }
                }
            }

            // Include the final row if it has content
            const total_emitted_rows = if (dst_col > 0) dst_row + 1 else dst_row;

            // Re-partition into Active Screen and Scrollback Ring
            if (total_emitted_rows <= new_rows) {
                // Fits entirely within active screen starting at physical row 0
                self.scrollback_used = 0;
                self.scroll_offset = 0;
                self.total_lines_scrolled = 0;
                for (total_emitted_rows..new_rows) |r| {
                    @memset(scratch[r * max_cols .. (r + 1) * max_cols], Cell{});
                }
                self.cursor.row = @intCast(new_cursor_row);
                self.saved_cursor.row = @intCast(new_saved_row);
            } else {
                // Bottom new_rows belong to active screen; excess goes into scrollback
                const active_start_row = total_emitted_rows - new_rows;
                const hist_count = active_start_row;
                const kept_history: usize = @min(hist_count, max_scrollback);
                self.scrollback_used = @intCast(kept_history);
                self.scroll_offset = @intCast(active_start_row & ring_mask);
                self.total_lines_scrolled = @intCast(kept_history);
                self.cursor.row = @intCast(new_cursor_row -| active_start_row);
                self.saved_cursor.row = @intCast(new_saved_row -| active_start_row);
            }

            // O(1) buffer pointer swap: scratch buffer becomes the primary cells buffer!
            std.mem.swap([]align(64) Cell, &self.cells, &self.scratch_cells);

            self.cursor.row = @min(self.cursor.row, @as(u16, @intCast(new_rows - 1)));
            self.saved_cursor.row = @min(self.saved_cursor.row, @as(u16, @intCast(new_rows - 1)));

            if (new_cursor_col >= new_cols) {
                self.cursor.wrap_pending = true;
                self.cursor.col = @intCast(new_cols - 1);
            } else {
                self.cursor.wrap_pending = (new_cursor_col == new_cols - 1) and new_cursor_wrap;
                self.cursor.col = @intCast(new_cursor_col);
            }
            self.saved_cursor.col = @min(@as(u16, @intCast(new_saved_col)), @as(u16, @intCast(new_cols - 1)));

            self.active_rows = @intCast(new_rows);
            self.active_cols = @intCast(new_cols);
            self.scroll_top = 0;
            self.scroll_bottom = self.active_rows - 1;
            self.viewport_offset = 0;

            self.row_map_is_identity = true;
            for (0..ring_rows) |i| self.row_map[i] = @intCast(i);
            @memset(&self.line_attrs, .normal);
            self.cached_row_phys = max_u16;
            self.dirty_rows = .full;
            self.bump();
        }

        pub fn resetTabStops(self: *Self) void {
            self.tab_stops = comptime defaultTabStops();
        }

        fn defaultTabStops() std.StaticBitSet(max_cols) {
            var bs: std.bit_set.StaticBitSet(max_cols) = .empty;
            var i: usize = tab_width;
            while (i < max_cols) : (i += tab_width) bs.set(i);
            return bs;
        }

        // Comptime assertion helper, call at the top of any scrollback-only method.
        inline fn requireScrollback() void {
            comptime if (max_scrollback == 0) {
                @compileError("This method requires scrollback support; " ++
                    "use Screen with max_scrollback > 0");
            };
        }

        pub fn scrollbackIsUsed(self: *const Self) bool {
            comptime requireScrollback();
            return self.scrollback_used > 0;
        }

        inline fn valueAs(comptime T: type, value: anytype) T {
            if (comptime @TypeOf(value) == void) return 0;
            comptime {
                switch (@typeInfo(T)) {
                    .int => {},
                    else => @compileError("valueAs expects an integer destination type"),
                }
            }
            return @intCast(value);
        }

        /// Returns `scrollback_used` converted to `T`.
        ///
        /// Returns zero when this `Screen` instantiation has no scrollback support
        /// and `scrollback_used` is `void`. The conversion and `void` handling are
        /// resolved at comptime.
        pub inline fn scrollbackUsedAs(self: *const Self, comptime T: type) T {
            return valueAs(T, self.scrollback_used);
        }

        /// Returns `viewport_offset` converted to `T`.
        ///
        /// Returns zero when this `Screen` instantiation has no scrollback support
        /// and `viewport_offset` is `void`. The conversion and `void` handling are
        /// resolved at comptime.
        pub inline fn viewportOffsetAs(self: *const Self, comptime T: type) T {
            return valueAs(T, self.viewport_offset);
        }

        /// Scroll the viewport back (toward history) by `lines`.
        /// Capped at `scrollback_used` - cannot scroll past the oldest history
        /// tho. No-op (and no redraw) if already at the oldest visible line.
        pub fn scrollViewportBack(self: *Self, lines: u32) void {
            comptime requireScrollback();
            const new_offset = @min(self.viewport_offset +| lines, self.scrollback_used);
            if (new_offset == self.viewport_offset) return;
            self.viewport_offset = new_offset;
            self.dirty_rows = .full;
            self.bump();
        }

        /// Scroll the viewport forward (toward live view) by `lines`.
        /// Saturating substraction, cannot go bellow 0.
        /// No-op (and no redraw) if already at live view.
        pub fn scrollViewportForward(self: *Self, lines: u32) void {
            comptime requireScrollback();
            const new_offset = self.viewport_offset -| lines;
            if (new_offset == self.viewport_offset) return;
            self.viewport_offset = new_offset;
            self.dirty_rows = .full;
            self.bump();
        }

        /// Snap the viewport back to live view (`viewport_offset = 0`).
        /// Returns true if the viewport was actually moved, false if already at live view.
        pub fn viewportReset(self: *Self) bool {
            comptime requireScrollback();
            if (self.viewport_offset == 0) return false;
            self.viewport_offset = 0;
            self.dirty_rows = .full;
            self.bump();
            return true;
        }

        pub inline fn isAt(self: *const Self, comptime position: ViewportPosition) bool {
            comptime requireScrollback();
            return switch (position) {
                .bottom => self.viewport_offset == 0,
                .top => self.viewport_offset == self.scrollback_used,
            };
        }

        /// Move cursor to absolute 0-based (row_pos, col_pos).
        ///
        /// In origin mode (DECOM), row is relative to scroll_top and clamped
        /// to [scroll_top, scroll_bottom]. In normal mode, clamped to [0, active_rows-1].
        ///
        /// Column always clamped to [0, active_cols-1]. Clears `wrap_pending`.
        ///
        /// Example:
        /// The escape sequence layer, receives 1-based coordinates and should call:
        /// CSI row ; col H  (1-based from PTY)
        /// screen.cursorPos(row - 1, col - 1);
        ///
        /// CSI n G  (1-based from PTY)
        /// screen.cursorCol(col - 1);
        pub fn cursorPos(self: *Self, row_pos: usize, col_pos: usize) void {
            // in origin mode, cursorPos(0, 0) moves to scroll_topm not row 0.
            // The effectiveTop() called handles this. top + row where top = scroll_top mode is on.
            const top = self.effectiveTop();
            const bottom: usize = if (self.cursor.origin)
                self.scroll_bottom
            else
                self.active_rows - 1;

            const target_row: u16 = @intCast(@min(top + row_pos, bottom));
            const target_col: u16 = @intCast(@min(col_pos, self.active_cols - 1));

            if (self.cursor.row != target_row) {
                self.dirty_rows.set(self.cursor.row);
                self.dirty_rows.set(target_row);
            } else {
                self.dirty_rows.set(target_row);
            }

            self.cursor.row = target_row;
            self.cursor.col = target_col;
            self.cursor.wrap_pending = false;
            self.bump();
        }

        /// Move cursor to absolute 0-based column.
        /// CSI n G (CHA). Clamps to [0, active_cols-1]. Clears `wrap_pending`.
        ///
        /// Example:
        /// The escape sequence layer, receives 1-based coordinates and should call:
        /// CSI n G  (1-based from PTY)
        /// screen.cursorCol(col - 1);
        pub fn cursorCol(self: *Self, n: u16) void {
            self.cursor.col = @min(n, self.active_cols - 1);
            self.cursor.wrap_pending = false;
            self.markDirty(self.cursor.row);
        }

        // cursorRow: move to absolute row (0-based), clamp to active_rows-1
        // Does NOT respect DECOM — VPA is always absolute.
        pub fn cursorRow(self: *Self, n: u16) void {
            const target_row: u16 = @min(n, self.active_rows - 1);
            if (self.cursor.row != target_row) {
                self.dirty_rows.set(self.cursor.row);
                self.dirty_rows.set(target_row);
            } else {
                self.dirty_rows.set(target_row);
            }
            self.cursor.row = target_row;
            self.cursor.wrap_pending = false;
            self.bump();
        }

        /// Move cursor up by `n` rows (CSI n A - CUU).
        /// Stops at `scroll_top` if the cursor is at or below it, or at
        /// row 0 if the cursor is above it (as xterm does, origin mode or
        /// not). Clears `wrap_pending`.
        pub fn cursorUp(self: *Self, n: usize) void {
            const cursor_row: usize = self.cursor.row;
            const top: usize = if (cursor_row >= self.scroll_top) self.scroll_top else 0;
            const target_row: u16 = @intCast(@max(cursor_row -| n, top));

            if (self.cursor.row != target_row) {
                self.dirty_rows.set(cursor_row);
                self.dirty_rows.set(target_row);
            } else {
                self.dirty_rows.set(target_row);
            }
            self.cursor.row = target_row;
            self.cursor.wrap_pending = false;
            self.bump();
        }

        /// Move cursor down by `n` rows (CSI n B - CUD).
        /// Stops at `scroll_bottom` if the cursor is at or above it, or at
        /// `active_rows - 1` if the cursor is below it (as xterm does,
        /// origin mode or not). Clears `wrap_pending`.
        pub fn cursorDown(self: *Self, n: usize) void {
            const cursor_row: usize = self.cursor.row;
            const bottom: usize = if (cursor_row <= self.scroll_bottom)
                self.scroll_bottom
            else
                self.active_rows - 1;
            const target_row: u16 = @intCast(@min(cursor_row + n, bottom));

            if (self.cursor.row != target_row) {
                self.dirty_rows.set(cursor_row);
                self.dirty_rows.set(target_row);
            } else {
                self.dirty_rows.set(target_row);
            }
            self.cursor.row = target_row;
            self.cursor.wrap_pending = false;
            self.bump();
        }

        /// Move cursor right by `n` columns (CSI n C / CUF).
        /// Clamps to `active_cols-1`. Does not respect scroll region.
        /// Clears `wrap_pending`.
        pub fn cursorRight(self: *Self, n: usize) void {
            self.cursor.col = @intCast(@min(@as(usize, self.cursor.col) + n, self.active_cols - 1));
            self.cursor.wrap_pending = false;
            self.markDirty(self.cursor.row);
        }

        /// Moves the cursor left by `n` columns (CUB / CSI Ps D, and BS).
        /// `n = 0` counts as 1. Clears `wrap_pending`.
        ///
        /// Without reverse wraparound the cursor stops at column 0. With
        /// it (mode 45 and DECAWM both set), this follows xterm's
        /// CursorBack: a pending wrap uses up one step without moving,
        /// and moving left of column 0 goes to the last column of the
        /// row above, but only if that row soft-wrapped into this one.
        /// Otherwise the cursor stops at column 0 of the current row.
        /// The scroll region is not a boundary; the top of the screen is.
        pub fn cursorLeft(self: *Self, n: usize) void {
            const count = @max(n, 1);
            if (!(self.mode.reverse_wrap and self.mode.auto_wrap)) {
                self.cursor.col = @intCast(self.cursor.col -| count);
                self.cursor.wrap_pending = false;
                self.markDirty(self.cursor.row);
                return;
            }
            self.reverseWrapLeft(count);
        }

        fn reverseWrapLeft(self: *Self, count: usize) void {
            const last_col = self.active_cols - 1;
            const start_row = self.cursor.row;
            var target_row: usize = start_row;
            var col: usize = self.cursor.col;

            // A pending wrap means the cursor is logically past the last
            // column, so the first step only cancels it.
            var steps = if (self.cursor.wrap_pending) count - 1 else count;
            while (steps > 0) : (steps -= 1) {
                if (col > 0) {
                    col -= 1;
                    continue;
                }
                if (target_row == 0 or !self.row(target_row - 1)[last_col].wrapped) break;
                target_row -= 1;
                col = last_col;
            }

            self.cursor.row = @intCast(target_row);
            self.cursor.col = @intCast(col);
            self.cursor.wrap_pending = false;
            self.markDirty(start_row);
            self.markDirty(target_row);
        }

        /// Moves the cursor down one line within the scroll region (IND / ESC D).
        ///
        /// Cases:
        /// Cursor at `scroll_bottom`, the scroll region scrolls up by one line
        ///    (top line discarded, blank line inserted at bottom). Cursor stays at
        ///    `scroll_bottom`. On the primary screen this adds one line of scrollback.
        /// Cursor below `scroll_bottom`, moves down, clamped to `active_rows - 1`.
        /// Otherwise, cursor moves down one row.
        ///
        /// This is the counterpart of `reverseIndex` (RI / ESC M).
        pub inline fn index(self: *Self) void {
            if (self.cursor.row == self.scroll_bottom) {
                // At the bottom of the scroll region, scroll the region up.
                // scrollUp handles dirty_rows (.full on full-screen, per-row on partial)
                // and call bump().
                self.scrollUp(1);
            } else {
                // Outside or above the bottom, just move the cursor down.
                self.dirty_rows.set(self.cursor.row);
                self.cursor.row = @min(self.cursor.row + 1, self.active_rows - 1);
                self.cursor.wrap_pending = false;
                self.dirty_rows.set(self.cursor.row);
                self.bump();
            }
        }

        /// Moves the cursor up one (RI / ESC M).
        ///
        /// If the cursor is at the top margin of the scroll region (`scroll_top`),
        /// the scroll region scrolls **down** by one line: content shifts down,
        /// a blank line is inserted at `scroll_top`, and the bottom line of the
        /// scroll region is discarded. This is the inverse of Index (IND / ESC D).
        ///
        /// The new blank line at `scroll_top` has its `line_attr` reset to `.normal`.
        ///
        /// Used by applications to insert lines above the cursor (e.g., vim scrolling up
        /// in insert mode, `less` padding backward, reverse-scroll in the alternate screen).
        ///
        /// Clears `wrap_pending`; moving up cancels any pending wrap.
        pub fn reverseIndex(self: *Self) void {
            self.cursor.wrap_pending = false;
            if (self.cursor.row == self.scroll_top) {
                // At the top margin, scroll the region down to insert a blank line.
                // scrollDown handles bump() and dirty_rows internally.
                self.scrollDown(1);
            } else {
                // Not at the top margin, just move up one row.
                // redraws both the old and new cursor rows dirty so the renderer
                // Saturating substraction handles the edge case where the cursor is
                // above scroll_top (valid without DECOM, where cursor can roam freely).
                self.dirty_rows.set(self.cursor.row);
                self.cursor.row -|= 1;
                self.dirty_rows.set(self.cursor.row);
                self.cached_row_phys = max_u16;
                self.bump();
            }
        }

        /// Save cursor state (DECSC / ESC 7).
        ///
        /// Saves the full cursor state: position, SGR attributes, charset state,
        /// and origin mode. Does NOT save cursor_color, wrap_pending, cursor state
        /// per DECSC semantics.
        ///
        /// Does not bump generation: saving the cursor changes no visible state.
        pub fn saveCursor(self: *Self) void {
            self.saved_cursor = .{
                .row = self.cursor.row,
                .col = self.cursor.col,
                .flags = self.cursor.attr.flags,
                .colors = self.cursor.attr.colors,
                .origin = self.cursor.origin,
                .charset = self.cursor.charset,
                .charset_is_identity = self.charset_is_identity,
                // wrap_pending intentianally NOT saved per DECSC spec
            };
        }

        /// Restore cursor state (DECRC / ESC 8).
        ///
        /// Restores the cursor saved by the last `saveCursor`. If `saveCursor` was
        /// never called, restores the default cursor (row=0, col=0, default attrs).
        ///
        /// After restore:
        ///   - Position is clamped to the current active area in case the terminal
        ///     was resized since the save.
        ///   - `wrap_pending` is cleared. The saved wrap state is intentionally
        ///     discarded: restoring a pending wrap would cause the next character
        ///     to wrap before writing, which is almost never the intended behavior.
        ///   - `origin_mode` is restored from the saved state, so row/col are
        ///     interpreted in the same coordinate space they were saved in.
        ///
        /// Marks the old and new cursor rows dirty and bumps generation.
        pub fn restoreCursor(self: *Self) void {
            // Mark the current cursor row dirty before moving (cursor indicator leaves).
            if (self.active_rows > 0) self.dirty_rows.set(self.cursor.row);

            self.cursor.row = self.saved_cursor.row;
            self.cursor.col = self.saved_cursor.col;
            self.cursor.origin = self.saved_cursor.origin;
            // The table may have been swept or reset since DECSC, so the
            // saved colors are interned again.
            self.cursor.attr.flags = self.saved_cursor.flags;
            self.cursor.attr.colors = self.saved_cursor.colors;
            self.internPen();
            self.cursor.charset = self.saved_cursor.charset;
            self.charset_is_identity = self.cursor.charset.isIdentity();
            // wrap_pending always cleared on restore, see doc comment.
            self.cursor.wrap_pending = false;

            // Clamp to the current active area, which may have been resized
            // since the save, and under DECOM to the current scroll region,
            // which may have moved since the save.
            self.cursor.row = @min(self.cursor.row, self.active_rows -| 1);
            self.cursor.col = @min(self.cursor.col, self.active_cols -| 1);
            if (self.cursor.origin) {
                self.cursor.row = std.math.clamp(self.cursor.row, self.scroll_top, self.scroll_bottom);
            }

            // Mark the new cursor row dirty (cursor indicator arrives).
            if (self.active_rows > 0) self.dirty_rows.set(self.cursor.row);
            self.bump();
        }

        /// Insert Characters (ICH / CSI Ps @).
        ///
        /// Insert `n` blank cells at the cursor column on the current row.
        /// Existing cells from the cursor to the end of the line shift right by `n`;
        /// cells that fall off the right (beyond `active_cols`) are discarded.
        ///
        /// The cursor does not move. `wrap_pending` is cleared.
        /// Only the cursor row is marked dirty.
        pub fn insertChars(self: *Self, n: usize) void {
            const cr = self.cursor.row;
            const cc = @as(usize, self.cursor.col);
            const blank: Cell = .{ .style = self.cursor.attr.blank_id };

            const count = @min(@max(n, 1), self.active_cols -| cc);
            if (count == 0) return;

            const r = self.rowMut(cr);

            // Shift [cc .. active_cols-count] right by `count` (right-to-left to avoid
            // overwriting source data before it is copied).
            var i: usize = self.active_cols - 1;
            while (i >= cc + count) : (i -= 1) {
                r[i] = r[i - count];
            }

            // Fill the vacated cells with blanks.
            @memset(r[cc..][0..count], blank);

            self.cursor.wrap_pending = false;
            self.bump();
        }

        /// Delete Characters (DCH / CSI Ps P).
        ///
        /// Delete `n` cells at the cursor column on the current row.
        /// Remaining cells from cursor+n to end of line shift left by `n`;
        /// blank cells fill from the right edge.
        ///
        /// The cursor does not move. `wrap_pending` is cleared.
        /// Only the cursor row is marked dirty.
        pub fn deleteChars(self: *Self, n: usize) void {
            const cr = self.cursor.row;
            const cc = @as(usize, self.cursor.col);
            const blank: Cell = .{ .style = self.cursor.attr.blank_id };

            if (cc >= self.active_cols) return;
            // n=0 is treated as n=1 per ECMA-48 default parameter rule.
            const count = @min(@max(n, 1), self.active_cols - cc);
            const r = self.rowMut(cr);

            // Shift [cc+count .. active_cols] left by `count` (left-to-right is safe
            // here because destination is always to the left of source).
            const src_start = cc + count;
            const src_len = self.active_cols - src_start;
            std.mem.copyForwards(
                Cell,
                r[cc..][0..src_len],
                r[src_start..][0..src_len],
            );

            // Fill the vacated tail with blanks.
            @memset(r[self.active_cols - count ..][0..count], blank);

            self.cursor.wrap_pending = false;
            self.dirty_rows.set(cr);
            self.bump();
        }

        /// Insert Lines (IL / CSI Ps L).
        ///
        /// Inserts `n` blank lines at the cursor row within the scroll region.
        /// Lines from the cursor row to `scroll_bottom` shift down by `n`;
        /// lines that fall off `scroll_bottom` are discarded.
        ///
        /// No-op if the cursor is outside [scroll_top, scroll_bottom].
        /// The cursor column is reset to 0 (xterm behavior). `wrap_pending` is cleared.
        /// All rows from cursor.row to scroll_bottom are marked dirty.
        pub fn insertLines(self: *Self, n: usize) void {
            const r = @as(usize, self.cursor.row);
            if (r < self.scroll_top or r > self.scroll_bottom) return;

            const blank: Cell = .{ .style = self.cursor.attr.blank_id };
            const region_bottom = @as(usize, self.scroll_bottom);
            const region_height = region_bottom - r + 1;
            const count = @min(@max(n, 1), region_height);

            // Initialize row_map before permuting (same as partial-region scroll)
            // if (self.row_map_is_identity) {
            //     for (0..self.active_rows) |i| self.row_map[i] = @intCast(i);
            //     self.row_map_is_identity = false;
            // }

            // Rotate RIGHT by count = LEFT by (region_height - count).
            // Brings evicted bottom rows to [r .. r+count-1];
            // shifts [r .. region_bottom-count] down to [r+count .. region_bottom].

            // std.mem.rotate(u16, self.row_map[r .. region_bottom + 1], region_height - count);
            self.rotateRowMapRegion(r, region_bottom, count, .right);

            // Shift rows [r .. region_bottom-count] down to [r+count .. region_bottom]
            // bottom-up to avoid overwriting source rows before they are copied.
            // Also shift line_attrs in lockstep.
            // if (count < region_height) {
            //     var dst: usize = region_bottom;
            //     while (dst >= r + count) : (dst -= 1) {
            //         const src_logical = dst - count;
            //         @memcpy(
            //             self.rowMut(dst)[0..self.active_cols],
            //             self.row(src_logical)[0..self.active_cols],
            //         );
            //         self.line_attrs[self.physRow(dst)] = self.line_attrs[self.physRow(src_logical)];
            //     }
            // }

            // Fill the newly inserted lines with blanks;  reset line_attrs to .normal.
            for (r..r + count) |blank_r| {
                //  @memset(self.rowMut(blank_r)[0..self.active_cols], blank);
                self.clearRow(blank_r, blank);
                self.line_attrs[self.physRow(blank_r)] = .normal;
            }

            // xterm resets cursor column to 0 on IL.
            self.cursor.col = 0;
            self.cursor.wrap_pending = false;

            // Mark all affected rows dirty
            self.dirty_rows.setRangeValue(.{ .start = r, .end = region_bottom + 1 }, true);
            self.cached_row_phys = max_u16;
            self.bump();
        }

        /// Delete Lines (DL / CSI Ps M).
        ///
        /// Deletes `n` lines at the cursor row within the scroll region.
        /// Lines below the cursor shift up by `n`; blank lines fill from
        /// `scroll_bottom` upward.
        ///
        /// No-op if the cursor is outside [scroll_top, scroll_bottom].
        /// The cursor column is reset to 0 (xterm behavior). `wrap_pending` is cleared.
        /// All rows from cursor.row to scroll_bottom are marked dirty.
        pub fn deleteLines(self: *Self, n: usize) void {
            const r: usize = @intCast(self.cursor.row);
            const region_bottom = @as(usize, self.scroll_bottom);

            // Cursor outside the scroll region (no-op).
            if (r < self.scroll_top or r > region_bottom) {
                @branchHint(.cold);
                return;
            }

            // ECMA-48 S8.3.42: Ps defaults to 1; treat 0 as 1.
            const blank: Cell = .{ .style = self.cursor.attr.blank_id };
            const region_height = region_bottom - r + 1;
            const count = @min(@max(n, 1), region_height);

            // if (self.row_map_is_identity) {
            //     for (0..self.active_rows) |i| self.row_map[i] = @intCast(i);
            //     self.row_map_is_identity = false;
            // }

            self.rotateRowMapRegion(r, region_bottom, count, .left);

            // Rotate LEFT by count.
            // Shifts [r+count .. region_bottom] up to [r .. region_bottom-count];
            // brings evicted top rows to [region_bottom-count+1 .. region_bottom].
            // std.mem.rotate(u16, self.row_map[r .. region_bottom + 1], count);

            // Move rows upward
            // Bulk-copy: shift rows [r+count .. region_bottom] up to
            // [r .. region_bottom-count] (top-down is safe: dst < src always).
            // Also shift line_attrs in lockstep.
            // const move_count = region_height - count;
            // for (0..move_count) |i| {
            //     const src_logical = r + count + i;
            //     const dst_logical = r + i;
            //     @memcpy(
            //         self.rowMut(dst_logical)[0..self.active_cols],
            //         self.row(src_logical)[0..self.active_cols],
            //     );
            //     self.line_attrs[self.physRow(dst_logical)] = self.line_attrs[self.physRow(src_logical)];
            // }

            // Fill the vacated tail with blanks; reset line_attrs to .normal.
            const blank_start = region_bottom + 1 - count;
            for (blank_start..region_bottom + 1) |blank_r| {
                // @memset(self.rowMut(blank_r)[0..self.active_cols], blank);
                self.clearRow(blank_r, blank);
                self.line_attrs[self.physRow(blank_r)] = .normal;
            }

            self.cursor.col = 0;
            self.cursor.wrap_pending = false;
            self.dirty_rows.setRangeValue(.{ .start = r, .end = region_bottom + 1 }, true);
            // for (r..region_bottom + 1) |dirty_r| self.dirty_rows.set(dirty_r);
            self.cached_row_phys = max_u16;
            self.bump();
        }

        /// Advance the cursor to the next tab stop, up to `n` times (HT / CHT / CSI Ps I).
        ///
        /// Each step moves the cursor to the next set bit in `tab_stops`.
        /// If no tab stop exists to the right of the cursor, the cursor stop
        /// at the last column (`active_cols-1`). A tab never triggers a line
        /// wrap, also the `wrap_pending` is always cleared.
        pub fn tabForward(self: *Self, n: usize) void {
            const times: usize = if (n == 0) 1 else n;
            const old_col = self.cursor.col;
            var col = @as(usize, self.cursor.col);
            var i: usize = 0;
            while (i < times) : (i += 1) {
                if (col >= self.active_cols - 1) break; // already at last column

                // Scan right for the next set tab stop.
                // Stop at active cols - 1 even if no tab stop is found there,
                // the cursor must not go out-of-bounds.
                var next = col + 1;
                while (next < self.active_cols - 1 and !self.tab_stops.isSet(next)) : (next += 1) {}
                col = next;
            }

            self.cursor.wrap_pending = false;
            self.cursor.col = @intCast(col);
            if (self.cursor.col != old_col) {
                self.dirty_rows.set(@as(usize, self.cursor.row));
                self.bump();
            }
        }

        /// Cursor Backward Tabulation (CBT / CSI Ps Z).
        ///
        /// Moves the cursor to the previous tab stop, `n` times.
        /// A parameter of 0 is treated as 1 (ECMA-48 S8.3.16).
        ///
        /// If no tab stop exists to the left of the current column, the cursor
        /// moves to column 0. The cursor never moves to a column to the right
        /// of its current position and never scrolls.
        ///
        /// `wrap_pending` is cleared — a pending wrap is cancelled by any
        /// horizontal cursor movement. The cursor row is marked dirty.
        pub fn tabBackward(self: *Self, n: usize) void {
            const times: usize = if (n == 0) 1 else n;
            const old_col = self.cursor.col;
            var col = @as(usize, self.cursor.col);

            for (0..times) |_| {
                if (col == 0) break; // already at leftmost column

                // Scan left from col-1 for the nearest set tab stop.
                // If none is found, the loop exits at prev=0 (column 0 is the
                // implicit left margin — always a valid landing position).
                var prev = col - 1;
                while (prev > 0 and !self.tab_stops.isSet(prev)) : (prev -= 1) {}
                col = prev;
            }

            self.cursor.col = @intCast(col);
            self.cursor.wrap_pending = false;
            if (self.cursor.col != old_col) {
                self.dirty_rows.set(@as(usize, self.cursor.row));
                self.bump();
            }
        }

        /// Set a tab stop at the current cursor column (HTS / ESC H).
        ///
        /// Tab stops are stored in `tab_stops` as a bit set indexed by column.
        /// Setting a sto that is already set is a no-op.
        ///
        /// Tab stops do not affect visible cell content, so no need to emit bump.
        pub fn setTabStop(self: *Self) void {
            self.tab_stops.set(@as(usize, self.cursor.col));
        }

        /// Clear tab stops (TBC / CSI Ps g).
        ///
        ///    0 = clear the tab stop at the current cursor column.
        ///    3 = clear all tab stops (reset to empty).
        ///
        /// Other values are silently ignored. Tab stops do not affect visible
        /// cell content, no bump is emmited.
        pub fn clearTabStop(self: *Self, mode: u16) void {
            switch (mode) {
                0 => self.tab_stops.unset(@as(usize, self.cursor.col)),
                3 => self.tab_stops = .empty,
                else => {},
            }
        }

        /// Erase Characters (ECH / CSI Ps X).
        ///
        /// Replaces `n` characters starting at the cursor position with blank cells
        /// using the current background color. The cursor does NOT move, and
        /// characters to the right of the erased region are NOT shifted (unlike
        /// DCH / `deleteChars`, which shifts remaining character left).
        ///
        /// `n==0` is treated as `n=1` (ECMA-48 S8.3.38 default parameter rule).
        /// The erase region is clamped to `[cursor.col, active_cols]`
        /// so over-large values are safe.
        pub fn eraseChars(self: *Self, n: usize) void {
            const count = @max(n, 1);
            const col = @as(usize, self.cursor.col);
            const end = @min(col + count, @as(usize, self.active_cols));
            const blank: Cell = .{ .style = self.cursor.attr.blank_id };

            const r = self.rowMut(self.cursor.row);

            // If erasing starts mid-wide-char (right-half), clear the left half too.
            if (col > 0 and r[col].kind.columnSpan() == 3) r[col - 1] = blank;
            // If erasing ends mid-wide-char (left half), clear the right half too.
            if (end < self.active_cols and r[end - 1].kind.columnSpan() == 2) r[end] = blank;

            @memset(r[col..end], blank);
            self.bump();
        }

        /// Cursor Next Line (CNL / CSI Ps E).
        ///
        /// Moves the cursor down `n` lines and resets the column to 0.
        /// Does NOT scroll the cursor clamps at `active_rows-1`
        /// (or `scroll_bottom` when origin mode is active).
        ///
        /// `n=0` is treated as `n=1` (ECMA-48 S8.3.36 default parameter rule).
        /// `wrap_pending` is cleared. Old and new cursor rows are marked dirty.
        pub fn cursorNextLine(self: *Self, n: usize) void {
            const count = if (n == 0) 1 else n;
            const limit: usize = if (self.cursor.origin) self.scroll_bottom else self.active_rows - 1;

            const old_row: usize = self.cursor.row;
            const new_row: usize = @min(old_row + count, limit);

            self.dirty_rows.set(old_row);
            self.cursor.row = @intCast(new_row);
            self.cursor.col = 0;
            self.cursor.wrap_pending = false;
            self.dirty_rows.set(new_row);
            self.bump();
        }

        /// Cursor Previous Line (CPL / CSI Ps F).
        ///
        /// Moves the cursor up `n` lines and resets the column to 0.
        /// Does NOT scroll — the cursor clamps at row 0
        /// (or `scroll_top` when origin mode is active).
        ///
        /// `n = 0` is treated as `n = 1` (ECMA-48 §8.3.55 default parameter rule).
        /// `wrap_pending` is cleared. Old and new cursor rows are marked dirty.
        pub fn cursorPrevLine(self: *Self, n: usize) void {
            const count = if (n == 0) @as(usize, 1) else n;
            const limit: usize = if (self.cursor.origin) self.scroll_top else 0;
            const old_row: usize = self.cursor.row;
            // Saturating subtraction prevents underflow; @max enforces
            // the lower bound when origin mode is active (limit = scroll_top > 0).
            const new_row: usize = @max(old_row -| count, limit);

            self.dirty_rows.set(old_row);
            self.cursor.row = @intCast(new_row);
            self.cursor.col = 0;
            self.cursor.wrap_pending = false;
            self.dirty_rows.set(new_row);
            self.bump();
        }

        /// Soft Terminal Reset (DECSTR / CSI ! p), screen part.
        ///
        /// Resets exactly the screen items of the VT510 DECSTR table
        /// (DEC STD 070): DECTCEM visible, IRM replace, DECOM absolute,
        /// DECAWM off, DECSTBM full page, G0-G3/GL/GR default, SGR normal,
        /// and the DECSC save slot to home with default attributes and
        /// charsets. Everything else stays, including DECSCNM, cursor
        /// blink and style, tab stops, cells, line attributes and the
        /// cursor position. `Terminal.softReset` does the terminal items.
        pub fn softReset(self: *Self) void {
            self.scroll_top = 0;
            self.scroll_bottom = @intCast(self.active_rows - 1);

            self.canonicalizeRowMap();

            self.cursor.attr = .{};
            self.cursor.charset = .{};
            self.cursor.origin = false;
            self.cursor.wrap_pending = false; // DECAWM goes off below

            self.mode.cursor_visibility = true;
            self.mode.insert = false;
            self.mode.auto_wrap = false;

            self.saved_cursor = .{};
            self.charset_is_identity = true;

            self.cached_row_phys = max_u16;
            self.setDirtyAll();
            self.bump();
        }

        /// Hard Reset (RIS | ESC c).
        ///
        /// Full factory reset. Clears the entire active area, resets all terminal state to
        /// power-on defaults, and (on the primary screen) clears the scrollback buffer and
        /// snaps the viewport to the live view.
        ///
        /// This is the nuclear option. Use `softReset` when only state needs resetting without
        /// disturbing cell content or history.
        pub fn hardReset(self: *Self) void {
            // .{} restores all defaults:
            //   auto_wrap=true, cursor_visible=true, allow_col_132=true,
            //   auto_repeat=true, everything else false.
            self.mode = .{};

            self.cursor = .{};
            self.saved_cursor = .{};

            self.scroll_top = 0;
            self.scroll_bottom = @intCast(self.active_rows - 1);

            self.resetTabStops();

            // Reset palette before clearing cells (cells reference palette indices).
            self.palette.reset();
            self.last_char = 0;

            // Content is about to be wiped unconditionally below, so there is
            // nothing to canonicalize. Just force identity directly.
            self.row_map_is_identity = true;
            self.row_map_lo = 0;
            self.row_map_hi = 0;

            @memset(&self.line_attrs, .normal);
            @memset(self.cells, Cell{});
            self.scroll_offset = 0;
            // Every cell and the pen are default now.
            self.styles.reset();

            _ = self.grapheme_arena.reset(.retain_capacity);
            self.grapheme_table.clearRetainingCapacity();
            self.grapheme_reverse.clearRetainingCapacity();
            self.next_grapheme_id = 0x110000;
            self.grapheme_compact_at = grapheme_compact_min;

            if (comptime is_scrollback_used) {
                self.scrollback_used = 0;
                self.viewport_offset = 0;
            }

            self.charset_is_identity = true;
            self.cached_row_phys = max_u16;
            self.setDirtyAll();
            self.bump();

            self.debugDumpLineAttrs();
        }

        pub fn debugDumpLineAttrs(self: *const Self) void {
            for (0..self.active_rows) |r| {
                const phys = self.physRow(@intCast(r));
                const attr = self.line_attrs[phys];
                if (attr != .normal) {
                    log.debug("row {} (phys {}) has line_attr: {}\n", .{ r, phys, attr });
                }
            }
        }
    };
}
