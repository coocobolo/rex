//! Instanced OpenGL overlay renderer for `kit.AsciiCanvas`. Draws a
//! fullscreen backdrop, crisp inset square tiles for full-block cells in
//! square aspect mode, and monospace ASCII glyphs from the terminal's gray
//! atlas in at most three draw calls with zero per-frame allocations once
//! glyphs are cached.

const AsciiOverlay = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const gl = @import("gl.zig");
const Atlas = @import("Atlas.zig");
const Background = @import("Background.zig");
const Cell = @import("Cell.zig");
const Shader = @import("Shader.zig");
const BgBuffer = @import("buffer.zig").BgBuffer;
const CellBuffer = @import("buffer.zig").CellBuffer;

const Rasterizer = @import("../freetype/Rasterizer.zig");
const AsciiCanvas = @import("../kit/AsciiCanvas.zig");
const Color = @import("../kit/Theme.zig").Color;

/// Fullscreen backdrop quad shader (`ascii_quad.vert` + `background.frag`).
quad_shader: Shader,
/// Monospace glyph shader (`cell.vert` + `cell.frag`).
cell_shader: Shader,
backdrop_buffer: BgBuffer,
tile_buffer: BgBuffer,
glyph_buffer: CellBuffer,

/// Reusable flat canvas and GPU staging arrays: allocated once with the
/// overlay so frame preparation performs zero heap allocations once glyphs
/// are in the atlas.
canvas: AsciiCanvas = .empty,
tile_instances: [AsciiCanvas.max_cells]Background.Instance = undefined,
glyph_instances: [AsciiCanvas.max_cells]Cell.Instance = undefined,

grid: Grid = .{},
backdrop: Color = .transparent,
ascender: f32 = 0,
tile_len: u32 = 0,
glyph_len: u32 = 0,

pub const CreateError = Allocator.Error || Shader.Error;

/// Pixel-snapped cell geometry computed for one viewport and font scale.
pub const Grid = struct {
    cols: u16 = 0,
    rows: u16 = 0,
    cell_w: f32 = 1,
    cell_h: f32 = 1,
    origin_x: f32 = 0,
    origin_y: f32 = 0,
    tile_inset: f32 = 0,
};

/// Inputs for preparing one overlay frame.
pub const PrepareArgs = struct {
    source: AsciiCanvas.Source,
    aspect: AsciiCanvas.CellAspect = .square,
    time_s: f32 = 0,
    progress: f32 = 0,
    palette: AsciiCanvas.Palette,
    backdrop: Color,
    screen_w: f32,
    screen_h: f32,
    bottom_reserve_px: f32 = 0,
};

/// Allocates and initializes the overlay on the heap so its fixed staging
/// buffers stay at a stable address. Requires a current GL context.
pub fn create(gpa: Allocator) CreateError!*AsciiOverlay {
    const self = try gpa.create(AsciiOverlay);
    errdefer gpa.destroy(self);

    var quad_shader: Shader = try .init(
        @embedFile("shaders/ascii_quad.vert"),
        @embedFile("shaders/background.frag"),
    );
    errdefer quad_shader.deinit();

    var cell_shader: Shader = try .init(
        @embedFile("shaders/cell.vert"),
        @embedFile("shaders/cell.frag"),
    );
    errdefer cell_shader.deinit();

    cell_shader.use();
    cell_shader.set1i("u_atlas_gray", 0);
    cell_shader.set1i("u_atlas_color", 1);

    const backdrop_buffer: BgBuffer = .init(1);
    const tile_buffer: BgBuffer = .init(AsciiCanvas.max_cells);
    const glyph_buffer: CellBuffer = .init(AsciiCanvas.max_cells);

    errdefer comptime unreachable;

    self.quad_shader = quad_shader;
    self.cell_shader = cell_shader;
    self.backdrop_buffer = backdrop_buffer;
    self.tile_buffer = tile_buffer;
    self.glyph_buffer = glyph_buffer;
    self.canvas = .empty;
    self.grid = .{};
    self.backdrop = .transparent;
    self.ascender = 0;
    self.tile_len = 0;
    self.glyph_len = 0;
    return self;
}

/// Releases all GL objects and frees the overlay. Requires a current GL context.
pub fn destroy(self: *AsciiOverlay, gpa: Allocator) void {
    self.glyph_buffer.deinit();
    self.tile_buffer.deinit();
    self.backdrop_buffer.deinit();
    self.cell_shader.deinit();
    self.quad_shader.deinit();
    gpa.destroy(self);
}

/// Computes the centered, pixel-snapped ASCII grid dimensions for `screen_w`
/// by `screen_h` physical pixels, reserving `bottom_reserve_px` at the bottom
/// for HUD controls.
pub fn computeGrid(
    screen_w: f32,
    screen_h: f32,
    metrics: Rasterizer.Metrics,
    aspect: AsciiCanvas.CellAspect,
    bottom_reserve_px: f32,
) Grid {
    const base_w: u16 = @max(1, metrics.cell_width);
    const base_h: u16 = @max(1, metrics.cell_height);
    const cell_w: f32 = switch (aspect) {
        .square => @floatFromInt(base_h),
        .terminal => @floatFromInt(base_w),
    };
    const cell_h: f32 = @floatFromInt(base_h);

    const avail_w: f32 = @max(0.0, screen_w);
    const avail_h: f32 = @max(0.0, screen_h - @max(0.0, bottom_reserve_px));

    const cols_f = @floor(avail_w / cell_w);
    const rows_f = @floor(avail_h / cell_h);
    const cols: u16 = if (cols_f <= 0) 0 else @min(AsciiCanvas.max_cols, @as(u16, @intFromFloat(cols_f)));
    const rows: u16 = if (rows_f <= 0) 0 else @min(AsciiCanvas.max_rows, @as(u16, @intFromFloat(rows_f)));

    const grid_w = @as(f32, @floatFromInt(cols)) * cell_w;
    const grid_h = @as(f32, @floatFromInt(rows)) * cell_h;
    const tile_inset: f32 = if (aspect == .square and cell_h >= 8.0)
        @max(1.0, @floor(cell_h * 0.06))
    else
        0.0;

    return .{
        .cols = cols,
        .rows = rows,
        .cell_w = cell_w,
        .cell_h = cell_h,
        .origin_x = @floor((avail_w - grid_w) * 0.5),
        .origin_y = @floor((avail_h - grid_h) * 0.5),
        .tile_inset = tile_inset,
    };
}

/// Renders the requested ASCII scene into the internal canvas and uploads
/// non-empty instances to the GPU buffers.
pub fn prepare(
    self: *AsciiOverlay,
    gpa: Allocator,
    atlas: *Atlas,
    rasterizer: *Rasterizer,
    args: PrepareArgs,
) Allocator.Error!void {
    const grid = computeGrid(args.screen_w, args.screen_h, rasterizer.metrics, args.aspect, args.bottom_reserve_px);
    self.grid = grid;
    self.backdrop = args.backdrop;
    self.ascender = @floatFromInt(rasterizer.metrics.ascender);
    self.tile_len = 0;
    self.glyph_len = 0;

    if (args.backdrop.a > 0) {
        const bg_inst = [1]Background.Instance{.{
            .col = 0,
            .row = 0,
            .span = 1,
            .r = args.backdrop.r,
            .g = args.backdrop.g,
            .b = args.backdrop.b,
            .a = args.backdrop.a,
        }};
        self.backdrop_buffer.upload(&bg_inst);
    }

    if (grid.cols == 0 or grid.rows == 0) {
        self.canvas.clear();
        return;
    }

    self.canvas.render(args.source, .{
        .cols = grid.cols,
        .rows = grid.rows,
        .time_s = args.time_s,
        .progress = args.progress,
        .aspect = args.aspect,
        .palette = args.palette,
    });

    var tiles: u32 = 0;
    var glyphs: u32 = 0;
    var row: u16 = 0;
    while (row < self.canvas.rows) : (row += 1) {
        const row_cells = self.canvas.rowSlice(row);
        for (row_cells, 0..) |cell, col_usize| {
            if (cell.codepoint == 0) continue;
            const col: u16 = @intCast(col_usize);

            if (args.aspect == .square and cell.codepoint == 0x2588) {
                self.tile_instances[tiles] = .{
                    .col = col,
                    .row = row,
                    .span = 1,
                    .r = cell.fg.r,
                    .g = cell.fg.g,
                    .b = cell.fg.b,
                    .a = cell.fg.a,
                };
                tiles += 1;
                continue;
            }

            const metric = atlas.get(gpa, rasterizer, cell.codepoint, .regular, .single) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => continue,
            };
            if (metric.width == 0 or metric.height == 0 or metric.kind != .gray) continue;

            const adv_f: f32 = @floatFromInt(metric.advance);
            const center_x: i16 = if (grid.cell_w > adv_f)
                @intFromFloat(@round((grid.cell_w - adv_f) * 0.5))
            else
                0;

            self.glyph_instances[glyphs] = .{
                .col = col,
                .row = row,
                .atlas_x = metric.atlas_x,
                .atlas_y = metric.atlas_y,
                .glyph_width = metric.width,
                .glyph_height = metric.height,
                .bearing_x = metric.bearing_x +| center_x,
                .bearing_y = metric.bearing_y,
                .fg_r = cell.fg.r,
                .fg_g = cell.fg.g,
                .fg_b = cell.fg.b,
                .fg_a = cell.fg.a,
                .flags = .{},
            };
            glyphs += 1;
        }
    }

    self.tile_len = tiles;
    self.glyph_len = glyphs;
    if (tiles > 0) self.tile_buffer.upload(self.tile_instances[0..tiles]);
    if (glyphs > 0) self.glyph_buffer.upload(self.glyph_instances[0..glyphs]);
}

/// Draws the last prepared frame into the currently bound framebuffer of
/// `screen_w` by `screen_h` physical pixels.
pub fn draw(self: *const AsciiOverlay, atlas: *const Atlas, screen_w: f32, screen_h: f32) void {
    if (self.backdrop.a == 0 and self.tile_len == 0 and self.glyph_len == 0) return;

    gl.enable(gl.BLEND);
    gl.blendFuncSeparate(
        gl.SRC_ALPHA,
        gl.ONE_MINUS_SRC_ALPHA,
        gl.ONE,
        gl.ONE_MINUS_SRC_ALPHA,
    );

    if (self.backdrop.a > 0) {
        self.quad_shader.use();
        self.quad_shader.set2f("u_cell_size", screen_w, screen_h);
        self.quad_shader.set2f("u_screen_size", screen_w, screen_h);
        self.quad_shader.set2f("u_grid_origin", 0.0, 0.0);
        self.quad_shader.set2f("u_inset", 0.0, 0.0);
        self.quad_shader.set1f("u_bg_alpha", 1.0);
        self.quad_shader.set1f("u_grayscale", 0.0);
        self.quad_shader.set3f("u_color_tint", 1.0, 1.0, 1.0);
        self.backdrop_buffer.draw(1);
    }

    if (self.tile_len > 0) {
        self.quad_shader.use();
        self.quad_shader.set2f("u_cell_size", self.grid.cell_w, self.grid.cell_h);
        self.quad_shader.set2f("u_screen_size", screen_w, screen_h);
        self.quad_shader.set2f("u_grid_origin", self.grid.origin_x, self.grid.origin_y);
        self.quad_shader.set2f("u_inset", self.grid.tile_inset, self.grid.tile_inset);
        self.quad_shader.set1f("u_bg_alpha", 1.0);
        self.quad_shader.set1f("u_grayscale", 0.0);
        self.quad_shader.set3f("u_color_tint", 1.0, 1.0, 1.0);
        self.tile_buffer.draw(self.tile_len);
    }

    if (self.glyph_len > 0) {
        self.cell_shader.use();
        self.cell_shader.set2f("u_atlas_size", @floatFromInt(atlas.width), @floatFromInt(atlas.height));
        atlas.bindTextures(gl.TEXTURE0, gl.TEXTURE1);
        self.cell_shader.set2f("u_cell_size", self.grid.cell_w, self.grid.cell_h);
        self.cell_shader.set2f("u_screen_size", screen_w, screen_h);
        self.cell_shader.set2f("u_grid_origin", self.grid.origin_x, self.grid.origin_y);
        self.cell_shader.set1f("u_ascender", self.ascender);
        self.cell_shader.set1i("u_is_color", 0);
        self.cell_shader.set1i("u_blink_on", 1);
        self.cell_shader.set1i("u_blink_rapid_on", 1);
        self.cell_shader.set1i("u_mask_mode", 0);
        self.cell_shader.set1f("u_grayscale", 0.0);
        self.cell_shader.set3f("u_color_tint", 1.0, 1.0, 1.0);
        self.glyph_buffer.draw(self.glyph_len);
    }
}
