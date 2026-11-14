const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

const log = std.log.scoped(.framedata);

const renderer = @import("root.zig");

const gl = renderer.gl;
const Atlas = renderer.Atlas;

const Cell = renderer.Cell;
const Background = renderer.Background;
const Decoration = renderer.Decoration;
const Selection = renderer.Selection;
const Scrollbar = renderer.Scrollbar;
const Cursor = renderer.Cursor;
const DirtyFlags = renderer.DirtyFlags;

const ft = @import("../freetype/root.zig");
const Rasterizer = ft.Rasterizer;
const FaceKind = Rasterizer.FaceKind;

const term = @import("../term/root.zig");
const AttrFlags = term.cell.AttrFlags;
const UnderlineStyle = term.cell.UnderlineStyle;
const Mode = term.screen.Mode;
const Option = term.term.Option;
const Palette = term.Palette;
const TermFrame = term.Frame;

/// Returns the foreground and background `cell` is drawn with, given its
/// `style` (from the frame's table). SGR 7 and DECSCNM each swap them, so
/// the two together cancel out.
pub fn cellColors(palette: *const Palette, style: term.Style, cell: term.Cell, reverse_video: bool) [2][3]u8 {
    var foreground = palette.resolveKeyRgb(style.fg, .foreground);
    var background = palette.resolveKeyRgb(style.bg, .background);
    if (cell.flags.reverse != reverse_video) std.mem.swap([3]u8, &foreground, &background);
    return .{ foreground, background };
}

/// User settings of the frame builder.
pub const BuilderOption = struct {
    /// Opacity of SGR 2 (dim) text, 0.0 to 1.0. Decorations follow it
    /// unless Decoration.Option.dim is off.
    dim_alpha: f32 = 0.5,

    /// Colors, dim and blink rules for the decoration runs.
    decoration: Decoration.Option = .{},
};

/// Converts an opacity from 0.0 to 1.0 to a color byte, clamped.
pub fn alphaByte(alpha: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(alpha, 0.0, 1.0) * 255.0));
}

/// Returns the decoration run for one cell, or null when the cell has
/// no visible decoration. `foreground` is the text color after reverse
/// video and the selection override; `foreground_alpha` carries SGR 2.
/// `sgr_underline` is the cell's SGR 58 color, null when unset. The
/// underline takes it first, then the configured fixed color, then the
/// text color. Invisible (SGR 8) cells hide their decorations with the
/// text.
pub fn decorationInstance(
    option: *const Decoration.Option,
    cell: term.Cell,
    sgr_underline: ?[3]u8,
    foreground: [3]u8,
    foreground_alpha: u8,
    col: u16,
    row: u16,
    span: u16,
) ?Decoration.Instance {
    const flags = cell.flags;
    if (flags.invisible) return null;
    if (flags.underline == .none and !flags.strikethrough and !flags.overline) return null;

    const alpha: u8 = if (option.dim) foreground_alpha else 255;
    const color = option.color;
    return .{
        .col = col,
        .row = row,
        .span = span,
        .underline = rgba(sgr_underline orelse color.underline orelse foreground, alpha),
        .strikethrough = rgba(color.strikethrough orelse foreground, alpha),
        .overline = rgba(color.overline orelse foreground, alpha),
        .flags = .{
            .underline = flags.underline,
            .strikethrough = flags.strikethrough,
            .overline = flags.overline,
            .blink = option.blink and flags.blink,
            .blink_rapid = option.blink and flags.blink_rapid,
        },
    };
}

fn rgba(rgb: [3]u8, alpha: u8) [4]u8 {
    return .{ rgb[0], rgb[1], rgb[2], alpha };
}

/// Returns the cursor color: OSC 12 when set, else the default
/// foreground, as the OSC 12 query reports. The SGR pen does not
/// change it.
pub fn cursorColor(palette: *const Palette, osc_color: ?[3]u8) [3]u8 {
    return osc_color orelse palette.get(.foreground).toArray();
}

/// Replaces rows `min` through `max` (inclusive) of `buffer`.
/// `offsets[row]` is the first instance of that row and
/// `offsets[rows_limit]` is the instance count. `counts` has one entry
/// per replaced row and sums to `fresh.len`.
///
/// Returns true when the span's instance count is unchanged. The GPU
/// sub-range then starts at `offsets[min]` and the tail stays put. A
/// same-length span is copied in place; the tail is moved only when the
/// count changes.
pub fn spliceSpan(
    comptime T: type,
    gpa: Allocator,
    buffer: *ArrayListUnmanaged(T),
    offsets: []u32,
    min: usize,
    max: usize,
    rows_limit: usize,
    fresh: []const T,
    counts: []const u32,
) Allocator.Error!bool {
    std.debug.assert(max >= min and max < rows_limit);
    std.debug.assert(offsets.len >= rows_limit + 1);
    std.debug.assert(counts.len == max - min + 1);
    var sum: usize = 0;
    for (counts) |count| sum += count;
    std.debug.assert(sum == fresh.len);

    const start: usize = offsets[min];
    const old_end: usize = offsets[max + 1];
    std.debug.assert(old_end >= start and start + (old_end - start) <= buffer.items.len);
    const old_len = old_end - start;

    if (fresh.len == old_len) {
        if (fresh.len > 0) @memcpy(buffer.items[start..][0..fresh.len], fresh);
    } else {
        try buffer.replaceRange(gpa, start, old_len, fresh);
    }

    var cursor: u32 = offsets[min];
    for (counts, 0..) |count, i| {
        cursor += count;
        offsets[min + 1 + i] = cursor;
    }

    if (fresh.len != old_len) {
        const delta: isize = @as(isize, @intCast(fresh.len)) - @as(isize, @intCast(old_len));
        var row = max + 2;
        while (row <= rows_limit) : (row += 1) {
            offsets[row] = @intCast(@as(isize, @intCast(offsets[row])) + delta);
        }
    }
    std.debug.assert(buffer.items.len == offsets[rows_limit]);
    return fresh.len == old_len;
}

fn matchedSpan(start: u32, end: u32, old: ?[2]u32) ?SplicedRange {
    const saved = old orelse return null;
    if (start != saved[0] or end != saved[1] or end < start) return null;
    return .{ .offset = start, .count = end - start };
}

/// Bit layout (LSB first):
///   0: strikethrough
///   1: blink
///   2: overline
///   3: blink_rapid
///   4-6: underline style (UnderlineStyle)
///   7: reserved
pub const Flags = packed struct(u8) {
    strikethrough: bool = false,
    blink: bool = false, // SGR 5, Config.blink.half_period_ms
    overline: bool = false,
    blink_rapid: bool = false, // SGR 6, Config.blink.rapid_half_period_ms
    underline: UnderlineStyle = .none,
    _pad: u1 = 0,
};

// A terminal selection always produces a "staircase" polygon with
// at most 8 vertices (6 for the common case where top/bottom rows
// are partial and middle rows are full-width).
//
// For: row1=[40..80], row2=[0..80], row3=[0..40]
// Verticies (clockwise):
// A=(40,0)   B=(80,0)   top edge of row 1
// B=(80,0)   C=(80,2ch) right edge of rows 1+2
// C=(80,0)   D=(40,2ch) right staircase step
// D=(40,2ch) E=(40,3ch) right edge of row 3
// E=(40,3
// F=(0,3ch)  G=(0,ch)   left edge of rows 2+3
// G=(0,ch)   H=(40,ch)  left staircase step
// H=(40,ch)  A=(40,0)   left edge row 1
//
// The vertex count is always 4,6,or 8.
// A-B-C, A-C-D, A-D-E, A-E-F, A-F-G, A-G-H (6 triangles for 8 vertices)
// A-B-C, A-C-D, A-D-E, A-E-F               (4 triangles for 6 vertices)
// A-B-C, A-C-D                             (2 triangles for 4 vertices)
pub const SelectionVertex = extern struct {
    col: u16,
    row: u16,
};

pub const SelectionPolygon = extern struct {
    vertices: [8]SelectionVertex,
    count: u8,
    _pad: [3]u8 = .{0} ** 3,
};

pub const CursorCache = struct {
    row: u16,
    col: u16,
    glyph: ?Atlas.Metric,
    glyph_fg: [3]u8,

    const empty: CursorCache = .{
        .glyph = null,
        .glyph_fg = .{ 0, 0, 0 },
        .row = 0,
        .col = 0,
    };

    /// Refreshes the cache when the cursor has moved to a new cell.
    /// Returns true if the cursor moved (caller may need to re-render).
    pub fn refresh(
        self: *CursorCache,
        gpa: Allocator,
        rasterizer: *Rasterizer,
        atlas: *Atlas,
        cursor: anytype,
        palette: *const Palette,
        frame: anytype,
        cursor_cell: *const term.Cell,
    ) bool {
        const row = cursor.row;
        const col = cursor.col;
        const moved = row != self.row or col != self.col;
        if (!moved) return false;

        self.row = row;
        self.col = col;

        if (cursor.style.shape() != .block) {
            self.glyph = null;
            return false;
        }

        if (cursor_cell.codepoint == 0) {
            self.glyph = null;
            self.glyph_fg = .{ 0, 0, 0 };
            return true;
        }

        self.glyph = cellGlyph(gpa, rasterizer, atlas, frame, cursor_cell);

        const style = frame.styleOf(cursor_cell.*);
        var fg: u32 = palette.resolveKey(style.fg, .foreground);
        var bg: u32 = palette.resolveKey(style.bg, .background);
        if (cursor_cell.flags.reverse) std.mem.swap(u32, &fg, &bg);

        const bg_u = unpackRgb(bg);
        self.glyph_fg = .{ bg_u.r, bg_u.g, bg_u.b };
        return true;
    }

    /// Called at the end of a dirty rebuild, the loop already captured
    /// the metric, so no atlas lookup needed.
    pub fn set(
        self: *CursorCache,
        row: u16,
        col: u16,
        glyph: ?Atlas.Metric,
        glyph_fg: [3]u8,
    ) void {
        self.row = row;
        self.col = col;
        self.glyph = glyph;
        self.glyph_fg = glyph_fg;
    }
};

pub const FrameData = @This();

pub const SplicedRange = struct {
    offset: usize,
    count: usize,
};

/// Slices are views into FrameBuilder's pre-allocated buffers.
/// FrameData does not own the memory, do not free these slices.
gray_instances: []const Cell.Instance,
color_instances: []const Cell.Instance,
background_instances: []const Background.Instance,
decoration_instances: []const Decoration.Instance,
selection_instances: []const Selection.Instance,
scrollbar_state: Scrollbar.State,
cursor_state: Cursor.State,

/// Sub-range whose instance count matched the previous frame, or null
/// when that stream has to be uploaded whole. The offset is into the
/// instance slice.
bg_spliced_range: ?SplicedRange = null,
gray_spliced_range: ?SplicedRange = null,
color_spliced_range: ?SplicedRange = null,
decoration_spliced_range: ?SplicedRange = null,

/// Whether a modal scrim is active behind the UI kit overlay (drives backdrop blur).
overlay_has_modal: bool = false,

/// Set by FrameBuilder when instance data changed since the last build.
/// Renderer skips VBO re-upload when false, but always issues draw calls.
// dirty: bool,
dirty: DirtyFlags,

pub fn Builder(comptime option: Option) type {
    const FrameType = TermFrame(option);
    const max_cols = option.max_cols;
    const max_rows = option.max_rows;
    const max_cells = max_rows * max_cols;

    return struct {
        const Self = @This();

        gray_buffer: std.ArrayListUnmanaged(Cell.Instance),
        color_buffer: std.ArrayListUnmanaged(Cell.Instance),
        background_buffer: std.ArrayListUnmanaged(Background.Instance),
        decoration_buffer: std.ArrayListUnmanaged(Decoration.Instance),
        selection_buffer: std.ArrayListUnmanaged(Selection.Instance),
        /// Dirty-span scratch. One instance per cell at most, so each
        /// list's capacity is `max_cells` and a splice does not allocate.
        /// Not the slices FrameData returns.
        scratch_bg: std.ArrayListUnmanaged(Background.Instance),
        scratch_gray: std.ArrayListUnmanaged(Cell.Instance),
        scratch_color: std.ArrayListUnmanaged(Cell.Instance),
        scratch_decoration: std.ArrayListUnmanaged(Decoration.Instance),
        bg_row_offsets: [max_rows + 1]u32 = undefined,
        gray_row_offsets: [max_rows + 1]u32 = undefined,
        color_row_offsets: [max_rows + 1]u32 = undefined,
        decoration_row_offsets: [max_rows + 1]u32 = undefined,
        last_cursor: CursorCache,

        // last_polygon: ?SelectionPolygon,
        last_blink_on: bool = false,
        last_generation: ?u32,
        /// `seq` of the newest frame whose dirty rows the stored instances
        /// account for. A frame's dirty rows are a usable span only when
        /// its `seq` is one past this.
        last_seq: u32 = 0,
        /// Grid the row offsets describe. A partial rebuild requires both.
        last_rows: u16 = 0,
        last_cols: u16 = 0,
        /// Set once a full walk has filled the row offsets.
        span_ready: bool = false,
        last_scrollbar: Scrollbar.State,
        last_selection: ?Selection.State,
        /// Palette the instance colors were resolved with. Indexed colors
        /// change every cell, including rows that are not dirty.
        last_palette: Palette,

        /// Colors, dim and blink rules for the decoration runs.
        decoration: Decoration.Option,
        /// Alpha byte of SGR 2 (dim) text, from BuilderOption.dim_alpha.
        dim_alpha: u8,

        pub fn init(gpa: Allocator, builder_option: BuilderOption) !Self {
            var gray_buffer: std.ArrayListUnmanaged(Cell.Instance) = try .initCapacity(gpa, max_cells);
            errdefer gray_buffer.deinit(gpa);

            var color_buffer: std.ArrayListUnmanaged(Cell.Instance) = try .initCapacity(gpa, max_cells);
            errdefer color_buffer.deinit(gpa);

            var background_buffer: std.ArrayListUnmanaged(Background.Instance) = try .initCapacity(gpa, max_cells);
            errdefer background_buffer.deinit(gpa);

            var decoration_buffer: std.ArrayListUnmanaged(Decoration.Instance) = try .initCapacity(gpa, max_cells);
            errdefer decoration_buffer.deinit(gpa);

            var selection_buffer: ArrayListUnmanaged(Selection.Instance) = try .initCapacity(gpa, max_rows);
            errdefer selection_buffer.deinit(gpa);

            var scratch_bg: std.ArrayListUnmanaged(Background.Instance) = try .initCapacity(gpa, max_cells);
            errdefer scratch_bg.deinit(gpa);
            var scratch_gray: std.ArrayListUnmanaged(Cell.Instance) = try .initCapacity(gpa, max_cells);
            errdefer scratch_gray.deinit(gpa);
            var scratch_color: std.ArrayListUnmanaged(Cell.Instance) = try .initCapacity(gpa, max_cells);
            errdefer scratch_color.deinit(gpa);
            var scratch_decoration: std.ArrayListUnmanaged(Decoration.Instance) = try .initCapacity(gpa, max_cells);
            errdefer scratch_decoration.deinit(gpa);

            return .{
                .background_buffer = background_buffer,
                .decoration = builder_option.decoration,
                .dim_alpha = alphaByte(builder_option.dim_alpha),
                .decoration_buffer = decoration_buffer,
                .gray_buffer = gray_buffer,
                .color_buffer = color_buffer,
                .selection_buffer = selection_buffer,
                .scratch_bg = scratch_bg,
                .scratch_gray = scratch_gray,
                .scratch_color = scratch_color,
                .scratch_decoration = scratch_decoration,

                .last_cursor = .empty,
                .last_scrollbar = .empty,
                .last_selection = null,
                .last_generation = null,
                .last_palette = .empty,
            };
        }

        pub fn deinit(self: *Self, gpa: Allocator) void {
            self.gray_buffer.deinit(gpa);
            self.color_buffer.deinit(gpa);
            self.background_buffer.deinit(gpa);
            self.decoration_buffer.deinit(gpa);
            self.selection_buffer.deinit(gpa);
            self.scratch_bg.deinit(gpa);
            self.scratch_gray.deinit(gpa);
            self.scratch_color.deinit(gpa);
            self.scratch_decoration.deinit(gpa);
        }

        fn buildSelectionInstances(self: *Self, active_cols: u16, sel: Selection.State) void {
            const top_row = @min(sel.start_row, sel.end_row);
            const bot_row = @max(sel.start_row, sel.end_row);
            const cols_limit: u16 = @min(active_cols, max_cols);

            const is_block = sel.kind == .block;
            const block_left: u16 = @min(sel.start_col, sel.end_col);
            const block_right: u16 = @min(@max(sel.start_col, sel.end_col) + 1, cols_limit);

            // Normalize: anchor vs active end
            const top_col: u16 = if (sel.start_row < sel.end_row) sel.start_col else if (sel.start_row > sel.end_row) sel.end_col else @min(sel.start_col, sel.end_col); // same row: normalize
            const bot_col: u16 = if (sel.start_row < sel.end_row) sel.end_col else if (sel.start_row > sel.end_row) sel.start_col else @max(sel.start_col, sel.end_col); // same row: normalize

            var prev_col: u16 = 0;
            var prev_span: u16 = 0;
            var pending: ?Selection.Instance = null;
            for (top_row..bot_row + 1) |r_idx| {
                const r: u16 = @intCast(r_idx);
                const span_start: u16 = if (is_block) block_left else (if (r == top_row) top_col else 0);
                const span_end: u16 = if (is_block) block_right else (if (r == bot_row) bot_col + 1 else cols_limit);
                if (span_end <= span_start) continue;

                const cur_span = span_end - span_start;
                const is_first: u16 = @intFromBool(r == top_row);
                const is_last: u16 = @intFromBool(r == bot_row);

                const prev_end = prev_col + prev_span;

                // Flush the previous pending instance: we now know the next row,
                // so we can set bottom-corner convex step bits.
                if (pending) |*p| {
                    const next_end = span_start + cur_span; // current row interval [span_start, next_end)

                    // Bottom-left/bottom-right on previous row using current row interval [span_start, next_end)
                    const step_BL: u16 = @intFromBool(p.col < span_start or p.col >= next_end);
                    const step_BR: u16 = @intFromBool(p.col + p.span > next_end or p.col + p.span <= span_start);

                    p.flags |= (step_BL << 5) | (step_BR << 6);

                    p.next_col = span_start;
                    p.next_span = cur_span;
                    self.selection_buffer.appendAssumeCapacity(p.*);
                }

                // create the new pending instance for current row.
                // We already know the previous row, so we can set top-corner convex step bits.

                const step_TL: u16 = @intFromBool(is_first == 0 and (span_start < prev_col or span_start >= prev_end));
                const step_TR: u16 = @intFromBool(is_first == 0 and (span_end > prev_end or span_end <= prev_col));

                pending = .{
                    .col = span_start,
                    .row = r,
                    .span = cur_span,
                    .flags = is_first | (is_last << 1) | (step_TL << 3) | (step_TR << 4),

                    .prev_col = prev_col,
                    .prev_span = prev_span,
                    // next_* defaults to this span, which is right for the last row.
                    .next_col = span_start,
                    .next_span = cur_span,
                };

                prev_col = span_start;
                prev_span = cur_span;
            }

            // Flush the last pending instance (is_last row, next_* already set to self)
            if (pending) |p| self.selection_buffer.appendAssumeCapacity(p);
        }

        pub fn build(
            self: *Self,
            gpa: Allocator,
            frame: *const FrameType,
            atlas: *Atlas,
            rasterizer: *Rasterizer,
            blink_on: bool,
            selection_state: ?Selection.State,
            cursor_color_override: ?[3]u8,
        ) !FrameData {
            const palette = &frame.palette;
            const cursor = &frame.cursor;
            const cursor_visiblity = cursor.visible;
            const cursor_row, const cursor_col = cursor.position();
            const cursor_cell = frame.cellAt(cursor_row, cursor_col);
            const cursor_color = cursor_color_override orelse frame.cursor_color;

            const selection_changed = !std.meta.eql(selection_state, self.last_selection);
            // zig fmt: off
            const fg_override_changed = selection_changed and
                ((selection_state    != null and selection_state.?.fg       != null) or
                (self.last_selection != null and self.last_selection.?.fg   != null));
            // zig fmt: on

            const cells_dirty = if (self.last_generation) |gen|
                gen != frame.generation or fg_override_changed or selection_changed
            else
                true;

            const blink_changed = blink_on != self.last_blink_on;
            self.last_blink_on = blink_on;

            // Dirty rows are relative to the previous snapshot. After a
            // skipped frame, or for a frame already consumed, they miss rows.
            const next_in_sequence = frame.seq == self.last_seq +% 1;
            const dirty_range: ?FrameType.DirtyRange = if (next_in_sequence) frame.dirtyRange() else null;
            // A frame that changed no rows is consumed by paths 1 and 2
            // too; one with dirty rows leaves a gap and the next build walks.
            if (next_in_sequence and dirty_range == null) self.last_seq = frame.seq;

            // path 1: nothing changed
            if (!cells_dirty and !selection_changed) {
                const cursor_changed = self.last_cursor.refresh(
                    gpa,
                    rasterizer,
                    atlas,
                    cursor,
                    palette,
                    frame,
                    &cursor_cell,
                );

                const new_scrollbar = buildScrollbar(frame);
                const scrollbar_changed = !std.meta.eql(new_scrollbar, self.last_scrollbar);
                self.last_scrollbar = new_scrollbar;

                // reuse existing buffer contents, only update cursor/Scrollbar
                return .{
                    .background_instances = self.background_buffer.items,
                    .bg_spliced_range = null,
                    .decoration_instances = self.decoration_buffer.items,
                    .gray_instances = self.gray_buffer.items,
                    .color_instances = self.color_buffer.items,
                    .cursor_state = buildCursor(
                        palette,
                        cursor,
                        selection_state,
                        blink_on,
                        cursor_visiblity,
                        cursor_color,
                        self.last_cursor.glyph,
                        self.last_cursor.glyph_fg,
                    ),
                    .dirty = .{
                        .blink = blink_changed,
                        .scrollbar = scrollbar_changed,
                        .cursor = cursor_changed or blink_changed,
                    },
                    .scrollbar_state = new_scrollbar,
                    .selection_instances = self.selection_buffer.items,
                };
            }

            // path 2: only selection changed
            if (!cells_dirty and selection_changed) {
                // only selection changed, rebuild selection_buf, reuse cell buffers
                self.selection_buffer.clearRetainingCapacity();
                if (selection_state) |sel| self.buildSelectionInstances(frame.active_cols, sel);
                self.last_selection = selection_state;

                const cursor_changed = self.last_cursor.refresh(
                    gpa,
                    rasterizer,
                    atlas,
                    cursor,
                    palette,
                    frame,
                    &cursor_cell,
                );

                const new_scrollbar = buildScrollbar(frame);
                const scrollbar_changed = !std.meta.eql(new_scrollbar, self.last_scrollbar);
                self.last_scrollbar = new_scrollbar;

                // reuse existing buffer contents, only update cursor/Scrollbar
                return .{
                    .background_instances = self.background_buffer.items,
                    .bg_spliced_range = null,
                    .decoration_instances = self.decoration_buffer.items,
                    .gray_instances = self.gray_buffer.items,
                    .color_instances = self.color_buffer.items,
                    .scrollbar_state = new_scrollbar,
                    .selection_instances = self.selection_buffer.items,
                    .cursor_state = buildCursor(
                        palette,
                        cursor,
                        selection_state,
                        blink_on,
                        cursor_visiblity,
                        cursor_color,
                        self.last_cursor.glyph,
                        self.last_cursor.glyph_fg,
                    ),
                    .dirty = .{
                        .selection = true,
                        .blink = blink_changed,
                        .scrollbar = scrollbar_changed,
                        .cursor = cursor_changed or blink_changed,
                    },
                };
            }

            // path 3: cells changed. Rebuild the dirty span when every row
            // outside it is still the instances already stored. Otherwise
            // walk the grid. The GPU sub-range is valid only when that
            // span's instance count, and its prefix, did not move.
            const cols_limit: u16 = @min(frame.active_cols, max_cols);
            const rows_limit: u16 = @min(frame.active_rows, max_rows);
            const reverse_video = frame.reverse_video;
            const palette_changed = !std.meta.eql(frame.palette, self.last_palette);
            const geometry_same = self.span_ready and self.last_rows == rows_limit and self.last_cols == cols_limit;
            // A selection foreground recolors glyphs on rows outside the span.
            const allow_gpu_splice = geometry_same and self.last_generation != null and !palette_changed and !fg_override_changed;

            var splices: Splices = .{};
            if (self.spanToSplice(selection_changed, palette_changed, cols_limit, rows_limit, dirty_range)) |span| {
                splices = try self.rebuildSpan(gpa, frame, atlas, rasterizer, span, cols_limit, rows_limit, reverse_video, selection_state);
            } else {
                splices = self.rebuildAll(gpa, frame, atlas, rasterizer, cols_limit, rows_limit, reverse_video, selection_state, if (allow_gpu_splice) dirty_range else null);
            }
            self.last_seq = frame.seq;

            if (palette_changed) self.last_palette = frame.palette;
            self.last_rows = rows_limit;
            self.last_cols = cols_limit;
            self.span_ready = true;
            self.last_generation = frame.generation;
            self.last_selection = selection_state;
            self.captureCursor(gpa, rasterizer, atlas, frame, cols_limit, rows_limit, reverse_video);

            const new_scrollbar = buildScrollbar(frame);
            const scrollbar_changed = !std.meta.eql(new_scrollbar, self.last_scrollbar);
            self.last_scrollbar = new_scrollbar;

            return .{
                .gray_instances = self.gray_buffer.items,
                .color_instances = self.color_buffer.items,
                .background_instances = self.background_buffer.items,
                .decoration_instances = self.decoration_buffer.items,
                .bg_spliced_range = splices.bg,
                .gray_spliced_range = splices.gray,
                .color_spliced_range = splices.color,
                .decoration_spliced_range = splices.decoration,
                .scrollbar_state = new_scrollbar,
                .selection_instances = self.selection_buffer.items,
                .cursor_state = buildCursor(
                    palette,
                    cursor,
                    selection_state,
                    blink_on,
                    cursor_visiblity,
                    cursor_color,
                    self.last_cursor.glyph,
                    self.last_cursor.glyph_fg,
                ),
                .dirty = .{
                    .cells = true,
                    .blink = blink_changed,
                    .cursor = true,
                    .selection = selection_changed,
                    .scrollbar = scrollbar_changed,
                },
            };
        }

        const Splices = struct {
            bg: ?FrameData.SplicedRange = null,
            gray: ?FrameData.SplicedRange = null,
            color: ?FrameData.SplicedRange = null,
            decoration: ?FrameData.SplicedRange = null,
        };

        /// Partial rebuild is valid when rows outside `range` still match
        /// the stored instances. A null generation means the atlas was
        /// dropped (`App` clears `last_generation` on a font change). A
        /// palette change recolors indexed cells on clean rows too.
        fn spanToSplice(
            self: *const Self,
            selection_changed: bool,
            palette_changed: bool,
            cols_limit: u16,
            rows_limit: u16,
            range: ?FrameType.DirtyRange,
        ) ?FrameType.DirtyRange {
            if (!self.span_ready or self.last_generation == null) return null;
            if (selection_changed or palette_changed) return null;
            if (self.last_rows != rows_limit or self.last_cols != cols_limit) return null;
            const span = range orelse return null;
            if (rows_limit == 0 or span.max >= rows_limit) return null;
            // The whole grid is the same work as a full walk.
            if (span.min == 0 and span.max + 1 == rows_limit) return null;
            return span;
        }

        /// Walks every row. `range` is the span whose GPU sub-upload may
        /// replace a whole upload, or null when every stream uploads whole;
        /// rows outside it must be unchanged since the last upload.
        fn rebuildAll(
            self: *Self,
            gpa: Allocator,
            frame: *const FrameType,
            atlas: *Atlas,
            rasterizer: *Rasterizer,
            cols_limit: u16,
            rows_limit: u16,
            reverse_video: bool,
            selection_state: ?Selection.State,
            range: ?FrameType.DirtyRange,
        ) Splices {
            var old_bg: ?[2]u32 = null;
            var old_gray: ?[2]u32 = null;
            var old_color: ?[2]u32 = null;
            var old_decoration: ?[2]u32 = null;
            if (range) |span| {
                if (span.max < rows_limit) {
                    old_bg = .{ self.bg_row_offsets[span.min], self.bg_row_offsets[span.max + 1] };
                    old_gray = .{ self.gray_row_offsets[span.min], self.gray_row_offsets[span.max + 1] };
                    old_color = .{ self.color_row_offsets[span.min], self.color_row_offsets[span.max + 1] };
                    old_decoration = .{ self.decoration_row_offsets[span.min], self.decoration_row_offsets[span.max + 1] };
                }
            }

            self.background_buffer.clearRetainingCapacity();
            self.decoration_buffer.clearRetainingCapacity();
            self.gray_buffer.clearRetainingCapacity();
            self.color_buffer.clearRetainingCapacity();
            self.selection_buffer.clearRetainingCapacity();
            if (selection_state) |sel| self.buildSelectionInstances(frame.active_cols, sel);

            var row: u16 = 0;
            while (row < rows_limit) : (row += 1) {
                self.bg_row_offsets[row] = @intCast(self.background_buffer.items.len);
                self.gray_row_offsets[row] = @intCast(self.gray_buffer.items.len);
                self.color_row_offsets[row] = @intCast(self.color_buffer.items.len);
                self.decoration_row_offsets[row] = @intCast(self.decoration_buffer.items.len);
                self.appendRow(gpa, frame, atlas, rasterizer, row, cols_limit, reverse_video, selection_state, &self.background_buffer, &self.gray_buffer, &self.color_buffer, &self.decoration_buffer);
            }
            self.bg_row_offsets[rows_limit] = @intCast(self.background_buffer.items.len);
            self.gray_row_offsets[rows_limit] = @intCast(self.gray_buffer.items.len);
            self.color_row_offsets[rows_limit] = @intCast(self.color_buffer.items.len);
            self.decoration_row_offsets[rows_limit] = @intCast(self.decoration_buffer.items.len);

            var splices: Splices = .{};
            if (range) |span| {
                if (span.max < rows_limit) {
                    splices.bg = matchedSpan(self.bg_row_offsets[span.min], self.bg_row_offsets[span.max + 1], old_bg);
                    splices.gray = matchedSpan(self.gray_row_offsets[span.min], self.gray_row_offsets[span.max + 1], old_gray);
                    splices.color = matchedSpan(self.color_row_offsets[span.min], self.color_row_offsets[span.max + 1], old_color);
                    splices.decoration = matchedSpan(self.decoration_row_offsets[span.min], self.decoration_row_offsets[span.max + 1], old_decoration);
                }
            }
            return splices;
        }

        fn rebuildSpan(
            self: *Self,
            gpa: Allocator,
            frame: *const FrameType,
            atlas: *Atlas,
            rasterizer: *Rasterizer,
            span: FrameType.DirtyRange,
            cols_limit: u16,
            rows_limit: u16,
            reverse_video: bool,
            selection_state: ?Selection.State,
        ) Allocator.Error!Splices {
            self.scratch_bg.clearRetainingCapacity();
            self.scratch_gray.clearRetainingCapacity();
            self.scratch_color.clearRetainingCapacity();
            self.scratch_decoration.clearRetainingCapacity();

            var counts_bg: [max_rows]u32 = undefined;
            var counts_gray: [max_rows]u32 = undefined;
            var counts_color: [max_rows]u32 = undefined;
            var counts_decoration: [max_rows]u32 = undefined;
            const n: usize = @as(usize, span.max - span.min) + 1;
            var row: u16 = span.min;
            for (0..n) |i| {
                const bg_before = self.scratch_bg.items.len;
                const gray_before = self.scratch_gray.items.len;
                const color_before = self.scratch_color.items.len;
                const decoration_before = self.scratch_decoration.items.len;
                self.appendRow(gpa, frame, atlas, rasterizer, row, cols_limit, reverse_video, selection_state, &self.scratch_bg, &self.scratch_gray, &self.scratch_color, &self.scratch_decoration);
                counts_bg[i] = @intCast(self.scratch_bg.items.len - bg_before);
                counts_gray[i] = @intCast(self.scratch_gray.items.len - gray_before);
                counts_color[i] = @intCast(self.scratch_color.items.len - color_before);
                counts_decoration[i] = @intCast(self.scratch_decoration.items.len - decoration_before);
                row += 1;
            }

            const min: usize = span.min;
            const max: usize = span.max;
            const rows: usize = rows_limit;
            const bg_stable = try spliceSpan(Background.Instance, gpa, &self.background_buffer, &self.bg_row_offsets, min, max, rows, self.scratch_bg.items, counts_bg[0..n]);
            const gray_stable = try spliceSpan(Cell.Instance, gpa, &self.gray_buffer, &self.gray_row_offsets, min, max, rows, self.scratch_gray.items, counts_gray[0..n]);
            const color_stable = try spliceSpan(Cell.Instance, gpa, &self.color_buffer, &self.color_row_offsets, min, max, rows, self.scratch_color.items, counts_color[0..n]);
            const decoration_stable = try spliceSpan(Decoration.Instance, gpa, &self.decoration_buffer, &self.decoration_row_offsets, min, max, rows, self.scratch_decoration.items, counts_decoration[0..n]);
            return .{
                .bg = if (bg_stable) .{ .offset = self.bg_row_offsets[min], .count = self.scratch_bg.items.len } else null,
                .gray = if (gray_stable) .{ .offset = self.gray_row_offsets[min], .count = self.scratch_gray.items.len } else null,
                .color = if (color_stable) .{ .offset = self.color_row_offsets[min], .count = self.scratch_color.items.len } else null,
                .decoration = if (decoration_stable) .{ .offset = self.decoration_row_offsets[min], .count = self.scratch_decoration.items.len } else null,
            };
        }

        fn appendRow(
            self: *Self,
            gpa: Allocator,
            frame: *const FrameType,
            atlas: *Atlas,
            rasterizer: *Rasterizer,
            row: u16,
            cols_limit: u16,
            reverse_video: bool,
            selection_state: ?Selection.State,
            background: *ArrayListUnmanaged(Background.Instance),
            gray: *ArrayListUnmanaged(Cell.Instance),
            color: *ArrayListUnmanaged(Cell.Instance),
            decoration: *ArrayListUnmanaged(Decoration.Instance),
        ) void {
            const palette = &frame.palette;
            const has_selection = selection_state != null;
            const cells = frame.displayRow(row);
            var col: u16 = 0;
            while (col < cols_limit) : (col += 1) {
                const c = cells[col];
                // Right half of a wide character: the left half's span covers it.
                if (c.kind == .wide_right) continue;
                const span: u16 = c.kind.columnSpan();

                // Selection is an overlay. Text keeps its colors; a
                // selection foreground, when set, replaces the glyph color.
                const style = frame.styleOf(c);
                var foreground, const background_rgb = cellColors(palette, style, c, reverse_video);
                if (c.flags.invisible) foreground = background_rgb;

                const in_selection = has_selection and selection_state.?.contains(row, col);
                if (in_selection) {
                    if (selection_state.?.fg) |sel_fg| foreground = sel_fg;
                }

                const foreground_alpha: u8 = if (c.flags.dim) self.dim_alpha else 255;
                background.appendAssumeCapacity(.{
                    .col = col,
                    .row = row,
                    .span = span,
                    .r = background_rgb[0],
                    .g = background_rgb[1],
                    .b = background_rgb[2],
                    .a = 255,
                });

                const sgr_underline: ?[3]u8 = if (style.underline == term.Style.default_key)
                    null
                else
                    palette.resolveKeyRgb(style.underline, .foreground);
                if (decorationInstance(&self.decoration, c, sgr_underline, foreground, foreground_alpha, col, row, span)) |run| {
                    Decoration.appendRun(decoration, run);
                }

                if (c.kind == .empty) continue;
                const metric = cellGlyph(gpa, rasterizer, atlas, frame, &c) orelse continue;
                if (metric.width == 0 or metric.height == 0) continue;

                const inst: Cell.Instance = .{
                    .col = col,
                    .row = row,
                    .atlas_x = metric.atlas_x,
                    .atlas_y = metric.atlas_y,
                    .bearing_x = metric.bearing_x,
                    .bearing_y = metric.bearing_y,
                    .fg_r = foreground[0],
                    .fg_g = foreground[1],
                    .fg_b = foreground[2],
                    .fg_a = foreground_alpha,
                    .glyph_width = metric.width,
                    .glyph_height = metric.height,
                    .flags = .{
                        .blink = c.flags.blink,
                        .blink_rapid = c.flags.blink_rapid,
                    },
                };
                switch (metric.kind) {
                    .color => color.appendAssumeCapacity(inst),
                    .gray => gray.appendAssumeCapacity(inst),
                }
            }
        }

        /// Block-cursor glyph for the cursor cell. `glyph_fg` is the cell
        /// background after reverse video. Selection recolors it later, in
        /// `buildCursor`. Empty, wide-right and zero-size glyphs draw none.
        fn captureCursor(
            self: *Self,
            gpa: Allocator,
            rasterizer: *Rasterizer,
            atlas: *Atlas,
            frame: *const FrameType,
            cols_limit: u16,
            rows_limit: u16,
            reverse_video: bool,
        ) void {
            const row = frame.cursor.row;
            const col = frame.cursor.col;
            const none: [3]u8 = .{ 0, 0, 0 };
            if (frame.cursor.style.shape() != .block or row >= rows_limit or col >= cols_limit) {
                self.last_cursor.set(row, col, null, none);
                return;
            }
            const cell = &frame.displayRow(row)[col];
            if (cell.kind == .empty or cell.kind == .wide_right) {
                self.last_cursor.set(row, col, null, none);
                return;
            }
            const metric = cellGlyph(gpa, rasterizer, atlas, frame, cell) orelse {
                self.last_cursor.set(row, col, null, none);
                return;
            };
            if (metric.width == 0 or metric.height == 0) {
                self.last_cursor.set(row, col, null, none);
                return;
            }
            const style = frame.styleOf(cell.*);
            const colors = cellColors(&frame.palette, style, cell.*, reverse_video);
            self.last_cursor.set(row, col, metric, colors[1]);
        }

        fn buildScrollbar(frame: *const FrameType) Scrollbar.State {
            if (comptime option.max_scrollback == 0) return .{ .visibility = false, .thumb_top_frac = 0, .thumb_height_frac = 1 };
            if (frame.scrollback_used == 0 or frame.is_alternate) return .{
                .visibility = false,
                .at_live_view = true,
                .thumb_top_frac = 0,
                .thumb_height_frac = 1.0,
            };

            const fracs: Scrollbar.Fractions = .of(frame.active_rows, frame.scrollback_used, frame.viewport_offset);
            return .{
                .visibility = true,
                .at_live_view = frame.viewport_offset == 0,
                .thumb_height_frac = fracs.height,
                .thumb_top_frac = fracs.top,
            };
        }

        fn buildCursor(
            palette: *const Palette,
            cursor: anytype,
            selection_state: ?Selection.State,
            blink_on: bool,
            visibility: bool,
            color: ?[3]u8,
            glyph: ?Atlas.Metric,
            glyph_fg: [3]u8,
        ) Cursor.State {
            const in_selection = if (selection_state) |sel| sel.contains(cursor.row, cursor.col) else false;
            const resolved_rgb = cursorColor(palette, color);

            var glyph_fg_final = glyph_fg;
            if (in_selection) {
                if (selection_state.?.bg) |sel_bg| glyph_fg_final = sel_bg;
                // glyph_fg = sel_bg so the glyph contrasts against the cursor block,
                // which sits on top of the sel_bg-colored cell background
            }

            return .{
                .blink_on = blink_on,
                .col = cursor.col,
                .color = resolved_rgb,
                .glyph = glyph,
                .glyph_fg = glyph_fg_final,
                .row = cursor.row,
                .style = cursor.style,
                .visibility = visibility,
            };
        }
    };
}

/// Returns the atlas glyph for a non-empty cell, sized from the width
/// the terminal stored in `cell.kind`, or null if it has none.
fn cellGlyph(
    gpa: Allocator,
    rasterizer: *Rasterizer,
    atlas: *Atlas,
    frame: anytype,
    cell: *const term.Cell,
) ?Atlas.Metric {
    const face = faceKindFromCell(cell.flags);
    const span: Rasterizer.Span = switch (cell.kind) {
        .empty, .wide_right => return null,
        .narrow, .grapheme => .single,
        .wide_left, .grapheme_wide => .double,
    };
    if (cell.kind.isGrapheme()) {
        // A cluster the frame's table had no room for draws as U+FFFD
        // instead of a blank cell (`max_frame_graphemes`).
        const cps = frame.getGrapheme(cell.codepoint) orelse
            return atlas.get(gpa, rasterizer, 0xFFFD, face, span) catch null;
        return atlas.getSequence(gpa, rasterizer, cps, face, span) catch null;
    }
    // narrow and wide_left cells always hold a valid scalar value.
    return atlas.get(gpa, rasterizer, @intCast(cell.codepoint), face, span) catch null;
}

fn faceKindFromCell(flags: AttrFlags) FaceKind {
    if (flags.bold and flags.italic) return .bold_italic;
    if (flags.bold) return .bold;
    if (flags.italic) return .italic;
    return .regular;
    // emoji face is selected by the atlas based on codepoint range, not cell flags
}

fn unpackRgb(packed_color: u32) struct { r: u8, g: u8, b: u8 } {
    return .{
        .r = @truncate(packed_color >> 24),
        .g = @truncate(packed_color >> 16),
        .b = @truncate(packed_color >> 8),
        // bits 7-0 are alpha (always 0xFF from resolve)
    };
}
