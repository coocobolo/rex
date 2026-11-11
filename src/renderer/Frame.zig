const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

const log = std.log.scoped(.framedata);

const renderer = @import("root.zig");

const gl = renderer.gl;
const Atlas = renderer.Atlas;

const Cell = renderer.Cell;
const Background = renderer.Background;
const Card = renderer.Card;
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

/// Spliced sub-buffer range for background quad updates, or null if full upload needed.
bg_spliced_range: ?SplicedRange = null,

/// Visual overlay instances (for toasts, break lock screen, and dashboard modal)
overlay_background_instances: []const Background.Instance = &.{},
overlay_card_instances: []const Card.Instance = &.{},
overlay_gray_instances: []const Cell.Instance = &.{},
overlay_color_instances: []const Cell.Instance = &.{},
overlay_has_modal: bool = false,
modal_blur: bool = false,
modal_blur_radius: u8 = 12,
modal_dim_alpha: u8 = 180,

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
        bg_row_offsets: [max_rows + 1]u32 = undefined,
        last_bg_len: usize = 0,
        last_cursor: CursorCache,

        // last_polygon: ?SelectionPolygon,
        last_blink_on: bool = false,
        last_generation: ?u32,
        last_scrollbar: Scrollbar.State,
        last_selection: ?Selection.State,

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

            return .{
                .background_buffer = background_buffer,
                .decoration = builder_option.decoration,
                .dim_alpha = alphaByte(builder_option.dim_alpha),
                .decoration_buffer = decoration_buffer,
                .gray_buffer = gray_buffer,
                .color_buffer = color_buffer,
                .selection_buffer = selection_buffer,

                .last_cursor = .empty,
                .last_scrollbar = .empty,
                .last_selection = null,
                .last_generation = null,
                .last_bg_len = 0,
            };
        }

        pub fn deinit(self: *Self, gpa: Allocator) void {
            self.gray_buffer.deinit(gpa);
            self.color_buffer.deinit(gpa);
            self.background_buffer.deinit(gpa);
            self.decoration_buffer.deinit(gpa);
            self.selection_buffer.deinit(gpa);
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

            // path 3: full rebuild
            self.background_buffer.clearRetainingCapacity();
            self.decoration_buffer.clearRetainingCapacity();
            self.gray_buffer.clearRetainingCapacity();
            self.color_buffer.clearRetainingCapacity();
            self.selection_buffer.clearRetainingCapacity();

            // const cols_limit: u16 = @min(screen.active_cols, max_cols);
            const reverse_video = frame.reverse_video;
            const has_selection = selection_state != null;

            if (selection_state) |sel| self.buildSelectionInstances(frame.active_cols, sel);

            const is_cursor_block = cursor.style.shape() == .block;
            var cursor_glyph: ?Atlas.Metric = null;
            var cursor_glyph_fg: [3]u8 = .{ 0, 0, 0 };

            // std.debug.print("+", .{});
            const cols_limit: u16 = @min(frame.active_cols, max_cols);
            const rows_limit: u16 = @min(frame.active_rows, max_rows);

            var row: u16 = 0;
            while (row < rows_limit) : (row += 1) {
                self.bg_row_offsets[row] = @intCast(self.background_buffer.items.len);

                const is_cursor_row = row == cursor_row;
                const cells = frame.displayRow(row);

                var col: u16 = 0;
                while (col < cols_limit) : (col += 1) {
                    const c = cells[col];

                    // 0 = empty cell, skip, no glyph to draw
                    // 1 = narrow char, draw at col
                    // 2 = wide char (left-half), draw at col, advance col +=2 (or just += 1 and let width == 3 skip the next)
                    // 3 = wide char (right-half), skip, already drawn by the width == 2 cell
                    if (c.kind == .wide_right) continue; // right-half of wide char: background covered by left-half span=2
                    const span: u16 = c.kind.columnSpan();

                    // const do_reverse = (cell.flags.reverse or reverse_video) != in_selection;

                    // Drop the do_reverse logic in build, with the overlay approach, text colors
                    // are unchanged and the semi-transparent highlight provides the visual selection.
                    // This is simpler and looks better than color inversion.
                    const style = frame.styleOf(c);
                    var foreground, const background = cellColors(palette, style, c, reverse_video);

                    // Invisible text (SGR 8): hide glyph by matching fg to bg
                    if (c.flags.invisible) foreground = background;

                    const in_selection = has_selection and selection_state.?.contains(row, col);
                    if (in_selection) {
                        if (selection_state.?.fg) |sel_fg| foreground = sel_fg;
                    }

                    const foreground_alpha: u8 = if (c.flags.dim) self.dim_alpha else 255;

                    // Background instance (always, even for empty cells)
                    self.background_buffer.appendAssumeCapacity(.{
                        .col = col,
                        .row = row,
                        .span = span,
                        .r = background[0],
                        .g = background[1],
                        .b = background[2],
                        .a = 255,
                    });

                    const sgr_underline: ?[3]u8 = if (style.underline == term.Style.default_key)
                        null
                    else
                        palette.resolveKeyRgb(style.underline, .foreground);
                    if (decorationInstance(&self.decoration, c, sgr_underline, foreground, foreground_alpha, col, row, span)) |run| {
                        Decoration.appendRun(&self.decoration_buffer, run);
                    }

                    if (c.kind == .empty) continue;
                    const metric = cellGlyph(gpa, rasterizer, atlas, frame, &c) orelse continue;

                    // Skip zero-size glyphs (space, combining marks with no bitmap)
                    if (metric.width == 0 or metric.height == 0) continue;

                    const is_cursor_cell = is_cursor_block and is_cursor_row and col == cursor_col;
                    if (is_cursor_cell) {
                        cursor_glyph = metric;
                        cursor_glyph_fg = background;
                    }

                    const inst: Cell.Instance = .{
                        .col = col,
                        .row = @intCast(row),
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
                        // Decorations are drawn by the Decoration pass.
                        .flags = .{
                            .blink = c.flags.blink,
                            .blink_rapid = c.flags.blink_rapid,
                        },
                    };

                    switch (metric.kind) {
                        .color => self.color_buffer.appendAssumeCapacity(inst),
                        .gray => self.gray_buffer.appendAssumeCapacity(inst),
                    }
                }
            }
            self.bg_row_offsets[rows_limit] = @intCast(self.background_buffer.items.len);

            var bg_spliced_range: ?FrameData.SplicedRange = null;
            if (self.last_generation != null and self.background_buffer.items.len == self.last_bg_len) {
                if (frame.dirtyRange()) |range| {
                    if (range.min < rows_limit and range.max < rows_limit) {
                        const start_offset = self.bg_row_offsets[range.min];
                        const end_offset = self.bg_row_offsets[range.max + 1];
                        if (end_offset >= start_offset) {
                            bg_spliced_range = .{
                                .offset = start_offset,
                                .count = end_offset - start_offset,
                            };
                        }
                    }
                }
            }
            self.last_bg_len = self.background_buffer.items.len;

            self.last_generation = frame.generation;
            self.last_selection = selection_state;
            self.last_cursor.set(cursor_row, cursor_col, cursor_glyph, cursor_glyph_fg);

            const new_scrollbar = buildScrollbar(frame);
            const scrollbar_changed = !std.meta.eql(new_scrollbar, self.last_scrollbar);
            self.last_scrollbar = new_scrollbar;

            return .{
                .gray_instances = self.gray_buffer.items,
                .color_instances = self.color_buffer.items,
                .background_instances = self.background_buffer.items,
                .bg_spliced_range = bg_spliced_range,
                .decoration_instances = self.decoration_buffer.items,
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
        .empty, .wide_right, .shaped => return null, // shaped needs HarfBuzz
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
