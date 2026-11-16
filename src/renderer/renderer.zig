const std = @import("std");

const log = std.log.scoped(.renderer);

const gl = @import("gl.zig");

const Atlas = @import("Atlas.zig");
const Background = @import("Background.zig");
const Blur = @import("Blur.zig");
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
    modal_blur: bool = false,
    modal_blur_radius: u8 = 12,
    inactive_blur: bool = false,
    inactive_blur_radius: u8 = 8,
    inactive_dim_alpha: u8 = 0,
};

pub fn Renderer(comptime option: TerminalOption) type {
    const max_cells = option.max_rows * option.max_cols;
    const scrollback_visibility = comptime option.max_scrollback > 0;

    return struct {
        const Self = @This();

        background: Background,
        blur: Blur,
        selection_blur: Blur,
        cell: Cell,
        cell_ascender: i16,
        cell_dimension: Dimension(f32),
        cursor: Cursor,
        decoration: Decoration,
        decoration_metrics: Decoration.Metrics,
        ink_mask: InkMask,
        selection: Selection,
        scrollbar: Scrollbar,

        grayscale: f32 = 0.0,
        color_tint: [3]f32 = .{ 1.0, 1.0, 1.0 },
        modal_blur: bool = false,
        modal_blur_radius: u8 = 12,
        inactive_blur: bool = false,
        inactive_blur_radius: u8 = 8,
        inactive_dim_alpha: u8 = 0,

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

            var blur = try Blur.init();
            errdefer blur.deinit();

            var selection_blur = try Blur.init();
            errdefer selection_blur.deinit();

            var self: Self = .{
                .background = background,
                .blur = blur,
                .selection_blur = selection_blur,
                .cell = cell,
                .cell_ascender = undefined,
                .cell_dimension = undefined,
                .cursor = cursor,
                .decoration = decoration,
                .decoration_metrics = undefined,
                .ink_mask = .init(),
                .scrollbar = scrollbar,
                .selection = selection,
                .modal_blur = opt.modal_blur,
                .modal_blur_radius = opt.modal_blur_radius,
                .inactive_blur = opt.inactive_blur,
                .inactive_blur_radius = opt.inactive_blur_radius,
                .inactive_dim_alpha = opt.inactive_dim_alpha,
            };
            self.setFontMetrics(opt.font_metrics);
            return self;
        }

        /// Updates modal backdrop blur settings and invalidates any cached blur
        /// pyramid when they change.
        pub fn setModalBlur(self: *Self, enabled: bool, radius: u8) void {
            if (self.modal_blur == enabled and self.modal_blur_radius == radius) return;
            self.modal_blur = enabled;
            self.modal_blur_radius = radius;
            self.blur.invalidate();
        }

        /// Updates unfocused window blur and dim settings and invalidates any
        /// cached blur pyramid when they change.
        pub fn setInactiveEffects(self: *Self, blur: bool, blur_radius: u8, dim_alpha: u8) void {
            if (self.inactive_blur == blur and self.inactive_blur_radius == blur_radius and self.inactive_dim_alpha == dim_alpha) return;
            self.inactive_blur = blur;
            self.inactive_blur_radius = blur_radius;
            self.inactive_dim_alpha = dim_alpha;
            self.blur.invalidate();
        }

        /// Updates selection appearance options and invalidates cached blur
        /// pyramids when needed.
        pub fn setSelectionOption(self: *Self, opt: Selection.Option) void {
            if (std.meta.eql(self.selection.option, opt)) return;
            if (self.selection.option.blur_radius != opt.blur_radius) {
                self.selection_blur.invalidate();
            }
            self.selection.option = opt;
            self.blur.invalidate();
        }

        pub fn setScrollbarOption(self: *Self, opt: Scrollbar.Option) void {
            if (std.meta.eql(self.scrollbar.option, opt)) return;
            self.scrollbar.setOption(opt);
            self.blur.invalidate();
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
            self.blur.invalidate();
            self.selection_blur.invalidate();
        }

        pub fn deinit(self: *Self) void {
            self.blur.deinit();
            self.selection_blur.deinit();
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
            const modal_blur_active = frame.overlay_has_modal and self.modal_blur and self.modal_blur_radius > 0;
            const inactive_blur_active = !focused and self.inactive_blur and self.inactive_blur_radius > 0;
            const blur_active = modal_blur_active or inactive_blur_active;
            const active_blur_radius: u8 = if (modal_blur_active) self.modal_blur_radius else self.inactive_blur_radius;
            const active_dim_alpha: u8 = if (!focused and !frame.overlay_has_modal) self.inactive_dim_alpha else 0;
            const fb_w: u32 = @intFromFloat(frame_dimension.width);
            const fb_h: u32 = @intFromFloat(frame_dimension.height);
            const scene_key: Blur.SceneKey = .{
                .background = background_color,
                .color_tint = self.color_tint,
                .width = fb_w,
                .height = fb_h,
                .grayscale = self.grayscale,
                .scrollbar_alpha = self.scrollbar.last_alpha,
                .selection_bg = selection_bg,
                .blur_radius = active_blur_radius,
                .dim_alpha = active_dim_alpha,
                .focused = focused,
                .scrollbar_hover = self.scrollbar.hover,
                .blink_rapid_on = cursor_state.blink_rapid_on,
            };
            const terminal_dirty = frame.dirty.cells or frame.dirty.selection or frame.dirty.cursor or frame.dirty.scrollbar or frame.dirty.blink;
            if (!blur_active or terminal_dirty) {
                self.blur.invalidate();
            } else if (self.blur.hasCachedPyramid(scene_key)) {
                gl.enable(gl.BLEND);
                gl.blendFuncSeparate(
                    gl.SRC_ALPHA,
                    gl.ONE_MINUS_SRC_ALPHA,
                    gl.ONE,
                    gl.ONE_MINUS_SRC_ALPHA,
                );
                self.blur.compositeCached(fb_w, fb_h, active_blur_radius, active_dim_alpha, scrimColor(background_color));
                return;
            }

            gl.enable(gl.BLEND);

            // Upload dirty GPU instance buffers once before any offscreen capture pass.
            if (frame.dirty.cells or frame.dirty.selection) {
                if (frame.bg_spliced_range) |spliced| {
                    self.background.uploadRange(frame.background_instances, spliced.offset, spliced.count);
                } else {
                    self.background.upload(frame.background_instances);
                }
            }
            if (frame.dirty.selection) self.selection.upload(frame.selection_instances);
            if (frame.dirty.cells) {
                self.cell.uploadRanges(
                    frame.gray_instances,
                    frame.color_instances,
                    frame.gray_spliced_range,
                    frame.color_spliced_range,
                );
                if (frame.decoration_spliced_range) |spliced| {
                    self.decoration.uploadRange(frame.decoration_instances, spliced.offset, spliced.count);
                } else {
                    self.decoration.upload(frame.decoration_instances);
                }
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
                .grayscale = self.grayscale,
                .color_tint = self.color_tint,
            };

            // Compute ink mask before binding offscreen scene FBOs (InkMask.end binds FBO 0).
            const ink_mask = self.drawInkMask(frame, glyphs);

            const selection_backdrop = self.prepareSelectionBackdrop(
                frame,
                frame_dimension,
                fb_w,
                fb_h,
                background_color,
                focused,
                glyphs,
                ink_mask,
                cursor_state.blink_on,
                cursor_state.blink_rapid_on,
            );

            if (blur_active) {
                self.blur.beginScene(fb_w, fb_h);
            } else {
                gl.bindFramebuffer(gl.FRAMEBUFFER, 0);
                gl.viewport(0, 0, @intCast(fb_w), @intCast(fb_h));
            }

            self.clearScene(background_color);

            // Pass 1: background quads
            self.background.draw(
                frame.background_instances.len,
                .{
                    .cell = self.cell_dimension,
                    .frame = frame_dimension,
                },
                background_color[3],
                self.grayscale,
                self.color_tint,
            );

            // Pass 1.5: selection rendering
            self.selection.draw(
                frame.selection_instances.len,
                selection_bg,
                selection_backdrop,
                .{
                    .cell = self.cell_dimension,
                    .frame = frame_dimension,
                },
            );

            // Pass 2 and 3: decorations and glyphs, in the configured order.
            self.drawTextPasses(frame, frame_dimension, glyphs, ink_mask, cursor_state.blink_on, cursor_state.blink_rapid_on);

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
            if (scrollback_visibility and frame.scrollbar_state.visibility) {
                self.scrollbar.upload(
                    frame_dimension,
                    frame.scrollbar_state.thumb_top_frac,
                    frame.scrollbar_state.thumb_height_frac,
                    frame.scrollbar_state.at_live_view,
                );
                self.scrollbar.draw();
            }

            // Pass 6: Frosted backdrop blur or unfocused window blur/dim.
            if (blur_active) {
                self.blur.renderBlur(
                    fb_w,
                    fb_h,
                    active_blur_radius,
                    active_dim_alpha,
                    scrimColor(background_color),
                );
                self.blur.markCached(scene_key);
            } else if (active_dim_alpha > 0) {
                self.blur.drawDimScrim(
                    fb_w,
                    fb_h,
                    active_dim_alpha,
                    scrimColor(background_color),
                );
            }
        }

        fn clearScene(self: *const Self, background_color: [4]f32) void {
            const r_in = background_color[0] * self.color_tint[0];
            const g_in = background_color[1] * self.color_tint[1];
            const b_in = background_color[2] * self.color_tint[2];
            const luma = r_in * 0.2126 + g_in * 0.7152 + b_in * 0.0722;
            const r_out = r_in + (luma - r_in) * self.grayscale;
            const g_out = g_in + (luma - g_in) * self.grayscale;
            const b_out = b_in + (luma - b_in) * self.grayscale;
            gl.clearColor(r_out, g_out, b_out, background_color[3]);
            gl.clear(gl.COLOR_BUFFER_BIT);
            gl.blendFuncSeparate(
                gl.SRC_ALPHA,
                gl.ONE_MINUS_SRC_ALPHA,
                gl.ONE,
                gl.ONE_MINUS_SRC_ALPHA,
            );
        }

        fn drawTextPasses(
            self: *Self,
            frame: FrameData,
            frame_dimension: Dimension(f32),
            glyphs: Cell.DrawArgs,
            ink_mask: ?*const InkMask,
            blink_on: bool,
            blink_rapid_on: bool,
        ) void {
            const decorations_over_text = self.decoration.option.order == .over_text;
            if (!decorations_over_text) self.drawDecorations(frame, frame_dimension, ink_mask, blink_on, blink_rapid_on);
            self.cell.draw(glyphs);
            if (decorations_over_text) self.drawDecorations(frame, frame_dimension, ink_mask, blink_on, blink_rapid_on);
        }

        fn prepareSelectionBackdrop(
            self: *Self,
            frame: FrameData,
            frame_dimension: Dimension(f32),
            fb_w: u32,
            fb_h: u32,
            background_color: [4]f32,
            focused: bool,
            glyphs: Cell.DrawArgs,
            ink_mask: ?*const InkMask,
            blink_on: bool,
            blink_rapid_on: bool,
        ) ?gl.GLuint {
            const blur_radius = self.selection.option.blur_radius;
            if (blur_radius == 0 or frame.selection_instances.len == 0) {
                self.selection_blur.invalidate();
                return null;
            }

            const key: Blur.SceneKey = .{
                .background = background_color,
                .color_tint = self.color_tint,
                .width = fb_w,
                .height = fb_h,
                .blur_radius = blur_radius,
                .grayscale = self.grayscale,
                .focused = focused,
                .blink_rapid_on = blink_rapid_on,
            };

            if (frame.dirty.cells or frame.dirty.blink or !self.selection_blur.hasCachedPyramid(key)) {
                self.selection_blur.beginScene(fb_w, fb_h);
                self.clearScene(background_color);
                self.background.draw(
                    frame.background_instances.len,
                    .{
                        .cell = self.cell_dimension,
                        .frame = frame_dimension,
                    },
                    background_color[3],
                    self.grayscale,
                    self.color_tint,
                );
                self.drawTextPasses(frame, frame_dimension, glyphs, ink_mask, blink_on, blink_rapid_on);
                self.selection_blur.filterPyramid(blur_radius);
                self.selection_blur.markCached(key);
            }

            return self.selection_blur.blurredTexture();
        }

        fn scrimColor(bg: [4]f32) [3]u8 {
            return .{
                @intFromFloat(@min(255.0, @max(0.0, bg[0] * 255.0))),
                @intFromFloat(@min(255.0, @max(0.0, bg[1] * 255.0))),
                @intFromFloat(@min(255.0, @max(0.0, bg[2] * 255.0))),
            };
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
