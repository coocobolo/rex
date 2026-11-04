const std = @import("std");

const log = std.log.scoped(.renderer);

const gl = @import("gl.zig");

const Atlas = @import("Atlas.zig");
const Background = @import("Background.zig");
const buffer = @import("buffer.zig");
const Cell = @import("Cell.zig");
const Cursor = @import("Cursor.zig");
const Decoration = @import("Decoration.zig");
const Dimension = @import("dimension.zig").Dimension;
const FrameData = @import("Frame.zig");
const InkMask = @import("InkMask.zig");
const Scrollbar = @import("Scrollbar.zig");
const Selection = @import("Selection.zig");
const Shader = @import("Shader.zig");

const Rasterizer = @import("../freetype/root.zig").Rasterizer;
const TerminalOption = @import("../term/root.zig").term.Option;

pub const Option = struct {
    font_metrics: Rasterizer.Metrics,
    background: Background.Option,
    cursor: Cursor.Option,
    decoration: Decoration.Option,
    scrollbar: Scrollbar.Option,
    selection: Selection.Option,
};

pub fn Renderer(comptime option: TerminalOption) type {
    const max_cells = option.max_rows * option.max_cols;
    const scrollback_visibility = comptime option.max_scrollback > 0;

    return struct {
        const Self = @This();

        background: Background,
        cell: Cell,
        cell_ascender: i16,
        cell_dimension: Dimension(f32),
        cursor: Cursor,
        decoration: Decoration,
        decoration_metrics: Decoration.Metrics,
        ink_mask: InkMask,
        selection: Selection,
        scrollbar: Scrollbar,

        pub fn init(opt: Option) !Self {
            var background = try Background.init(max_cells, opt.background);
            errdefer background.deinit();

            var selection = try Selection.init(option.max_rows, opt.selection);
            errdefer selection.deinit();

            var scrollbar = try Scrollbar.init(opt.scrollbar);
            errdefer scrollbar.deinit();

            var cursor = try Cursor.init(opt.cursor);
            errdefer cursor.deinit();

            var cell = try Cell.init(max_cells);
            errdefer cell.deinit();

            var decoration = try Decoration.init(max_cells, opt.decoration);
            errdefer decoration.deinit();

            var self: Self = .{
                .background = background,
                .cell = cell,
                .cell_ascender = undefined,
                .cell_dimension = undefined,
                .cursor = cursor,
                .decoration = decoration,
                .decoration_metrics = undefined,
                .ink_mask = .init(),
                .scrollbar = scrollbar,
                .selection = selection,
            };
            self.setFontMetrics(opt.font_metrics);
            return self;
        }

        /// Takes the cell size and baseline from the font, and resolves
        /// the decoration lines from the font and the decoration option.
        /// Called at init and whenever the font size changes.
        pub fn setFontMetrics(self: *Self, font: Rasterizer.Metrics) void {
            self.cell_ascender = font.ascender;
            self.cell_dimension = .{
                .width = @floatFromInt(font.cell_width),
                .height = @floatFromInt(font.cell_height),
            };
            self.decoration_metrics = .resolve(font, self.decoration.option);
        }

        pub fn deinit(self: *Self) void {
            self.cell.deinit();
            self.decoration.deinit();
            self.ink_mask.deinit();
            self.background.deinit();
            self.scrollbar.deinit();
            self.selection.deinit();
            self.cursor.deinit();
            self.* = undefined;
        }

        pub fn draw(
            self: *Self,
            frame: FrameData,
            atlas: *const Atlas,
            frame_dimension: Dimension(f32),
            background_color: [4]f32,
            focused: bool,
            selection_bg: ?[3]u8,
            cursor_state: struct {
                blink_on: bool,
                blink_rapid_on: bool,
            },
        ) void {
            gl.enable(gl.BLEND);
            gl.clearColor(
                background_color[0],
                background_color[1],
                background_color[2],
                background_color[3],
            );
            gl.clear(gl.COLOR_BUFFER_BIT);
            gl.blendFuncSeparate(
                gl.SRC_ALPHA,
                gl.ONE_MINUS_SRC_ALPHA,
                gl.ONE,
                gl.ONE_MINUS_SRC_ALPHA,
            );

            // Pass 1: background quads (spliced sub-buffer upload when dirty range is bounded)
            if (frame.dirty.cells or frame.dirty.selection) {
                if (frame.bg_spliced_range) |spliced| {
                    self.background.uploadRange(frame.background_instances, spliced.offset, spliced.count);
                } else {
                    self.background.upload(frame.background_instances);
                }
            }
            self.background.draw(
                frame.background_instances.len,
                .{
                    .cell = self.cell_dimension,
                    .frame = frame_dimension,
                },
                background_color[3],
            );

            // Pass: 1.5: selection rendering
            if (frame.dirty.selection) self.selection.upload(frame.selection_instances);
            self.selection.draw(
                frame.selection_instances.len,
                selection_bg,
                .{
                    .cell = self.cell_dimension,
                    .frame = frame_dimension,
                },
            );

            // Pass 2 and 3: decorations and glyphs, in the configured order
            if (frame.dirty.cells) {
                self.cell.upload(frame.gray_instances, frame.color_instances);
                self.decoration.upload(frame.decoration_instances);
            }
            const glyphs: Cell.DrawArgs = .{
                .atlas = atlas,
                .ascender = @floatFromInt(self.cell_ascender),
                .blink_on = cursor_state.blink_on,
                .blink_rapid_on = cursor_state.blink_rapid_on,
                .cell = self.cell_dimension,
                .frame = frame_dimension,
                .gray_len = frame.gray_instances.len,
                .color_len = frame.color_instances.len,
            };
            const ink_mask = self.drawInkMask(frame, glyphs);
            const decorations_over_text = self.decoration.option.order == .over_text;
            if (!decorations_over_text) self.drawDecorations(frame, frame_dimension, ink_mask, cursor_state.blink_on, cursor_state.blink_rapid_on);
            self.cell.draw(glyphs);
            if (decorations_over_text) self.drawDecorations(frame, frame_dimension, ink_mask, cursor_state.blink_on, cursor_state.blink_rapid_on);

            // Pass 4: cursor
            if (frame.dirty.cursor) self.cursor.upload(frame.cursor_state);
            if (frame.cursor_state.shouldDraw()) {
                self.cursor.draw(
                    frame.cursor_state,
                    &self.cell.shader,
                    focused,
                    .{
                        .cell = self.cell_dimension,
                        .frame = frame_dimension,
                    },
                );
            }

            // Pass 5: scrollbar
            if (scrollback_visibility) {
                if (frame.dirty.scrollbar) {
                    self.scrollbar.upload(
                        frame_dimension,
                        frame.scrollbar_state.thumb_top_frac,
                        frame.scrollbar_state.thumb_height_frac,
                        frame.scrollbar_state.at_live_view,
                    );
                }
                self.scrollbar.draw();
            }
        }

        /// Draws the glyph coverage when some run has an underline that
        /// skips ink, and returns the mask for the decoration pass.
        fn drawInkMask(self: *Self, frame: FrameData, glyphs: Cell.DrawArgs) ?*const InkMask {
            if (self.decoration.option.skip_ink.styleBits() == 0) return null;
            if (!Decoration.anyUnderline(frame.decoration_instances)) return null;
            const width: u32 = @intFromFloat(glyphs.frame.width);
            const height: u32 = @intFromFloat(glyphs.frame.height);
            if (!self.ink_mask.begin(width, height)) return null;
            self.cell.drawInkMask(glyphs);
            self.ink_mask.end();
            return &self.ink_mask;
        }

        fn drawDecorations(
            self: *Self,
            frame: FrameData,
            frame_dimension: Dimension(f32),
            ink_mask: ?*const InkMask,
            blink_on: bool,
            blink_rapid_on: bool,
        ) void {
            self.decoration.draw(
                frame.decoration_instances.len,
                .{
                    .cell = self.cell_dimension,
                    .frame = frame_dimension,
                },
                self.decoration_metrics,
                ink_mask,
                blink_on,
                blink_rapid_on,
            );
        }

        /// Called unconditionally every frame before renderFrame().
        /// Returns true if any subsystem is still animating (caller sets needs_redraw).
        pub fn tick(self: *Self, dt_ms: u64) bool {
            if (!scrollback_visibility) return false;
            return self.scrollbar.tick(dt_ms);
        }
    };
}
