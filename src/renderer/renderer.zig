const std = @import("std");

const log = std.log.scoped(.renderer);

const gl = @import("gl.zig");

const Atlas = @import("Atlas.zig");
const Background = @import("Background.zig");
const buffer = @import("buffer.zig");
const Cell = @import("Cell.zig");
const Cursor = @import("Cursor.zig");
const Dimension = @import("dimension.zig").Dimension;
const FrameData = @import("frame.zig");
const Scrollbar = @import("Scrollbar.zig");
const Selection = @import("Selection.zig");
const Shader = @import("Shader.zig");

const TerminalOption = @import("../term/root.zig").term.Option;

pub const Option = struct {
    font_metrics: struct {
        ascender: i16,
        dimension: Dimension(f32),
    },
    background: Background.Option,
    cursor: Cursor.Option,
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

            return .{
                .background = background,
                .cell = cell,
                .cell_ascender = opt.font_metrics.ascender,
                .cell_dimension = opt.font_metrics.dimension,
                .cursor = cursor,
                .scrollbar = scrollbar,
                .selection = selection,
            };
        }

        pub fn deinit(self: *Self) void {
            self.cell.deinit();
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

            // Pass 1: background quads
            if (frame.dirty.cells or frame.dirty.blink or frame.dirty.selection) self.background.upload(frame.background_instances);
            self.background.draw(
                frame.background_instances.len,
                .{
                    .cell = self.cell_dimension,
                    .frame = frame_dimension,
                },
                background_color[3],
                cursor_state.blink_on,
                cursor_state.blink_rapid_on,
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

            self.cell.upload(frame.gray_instances, frame.color_instances);
            self.cell.draw(
                atlas,
                self.cell_ascender,
                .{
                    .blink_on = cursor_state.blink_on,
                    .blink_rapid_on = cursor_state.blink_rapid_on,
                },
                .{
                    .cell = self.cell_dimension,
                    .frame = frame_dimension,
                },
                .{
                    .gray = frame.gray_instances.len,
                    .color = frame.color_instances.len,
                },
            );

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

        /// Called unconditionally every frame before renderFrame().
        /// Returns true if any subsystem is still animating (caller sets needs_redraw).
        pub fn tick(self: *Self, dt_ms: u64) bool {
            if (!scrollback_visibility) return false;
            return self.scrollbar.tick(dt_ms);
        }
    };
}