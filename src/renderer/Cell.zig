const std = @import("std");

const gl = @import("gl.zig");
const Atlas = @import("Atlas.zig");
const Shader = @import("Shader.zig");

const Buffer = @import("buffer.zig").CellBuffer;
const Flags = @import("Frame.zig").Flags;
const SplicedRange = @import("Frame.zig").SplicedRange;
const Dimension = @import("dimension.zig").Dimension;

pub const Option = struct {};

pub const Instance = extern struct {
    col: u16, // grid column
    row: u16, // grid row

    // glyph to-left in atlas
    atlas_x: u16,
    atlas_y: u16,

    // glyph bitmap dimension
    glyph_width: u16,
    glyph_height: u16,
    bearing_x: i16,
    bearing_y: i16,
    fg_r: u8,
    fg_g: u8,
    fg_b: u8,
    fg_a: u8,
    flags: Flags,
    _pad: [3]u8 = .{0} ** 3, // keep 24-byte stride
};

comptime {
    std.debug.assert(24 == @sizeOf(Instance));
}

pub const Cell = @This();

color_buffer: Buffer,
gray_buffer: Buffer,
shader: Shader,

pub fn init(size: usize) !Cell {
    const shader = try Shader.init(
        @embedFile("shaders/cell.vert"),
        @embedFile("shaders/cell.frag"),
    );
    errdefer shader.deinit();

    var gray_buffer = Buffer.init(size);
    errdefer gray_buffer.deinit();

    var color_buffer = Buffer.init(size);
    errdefer color_buffer.deinit();

    shader.use();
    shader.set1i("u_atlas_gray", 0); // TEXTURE_0
    shader.set1i("u_atlas_color", 1); // TEXTURE_1

    return .{
        .color_buffer = color_buffer,
        .gray_buffer = gray_buffer,
        .shader = shader,
    };
}

pub fn deinit(self: *Cell) void {
    self.color_buffer.deinit();
    self.gray_buffer.deinit();
    self.shader.deinit();
}

/// Upload both color and gray buffers instances if its non-zeros.
pub fn upload(self: *Cell, gray: []const Instance, color: []const Instance) void {
    if (gray.len > 0) self.gray_buffer.upload(gray);
    if (color.len > 0) self.color_buffer.upload(color);
}

/// Uploads each glyph stream. A range updates that sub-range in place;
/// null uploads the whole stream, and an empty whole stream is skipped.
pub fn uploadRanges(
    self: *Cell,
    gray: []const Instance,
    color: []const Instance,
    gray_range: ?SplicedRange,
    color_range: ?SplicedRange,
) void {
    if (gray_range) |range| {
        self.gray_buffer.uploadRange(gray, range.offset, range.count);
    } else if (gray.len > 0) {
        self.gray_buffer.upload(gray);
    }
    if (color_range) |range| {
        self.color_buffer.uploadRange(color, range.offset, range.count);
    } else if (color.len > 0) {
        self.color_buffer.upload(color);
    }
}

/// What a glyph draw needs: the atlas, the font baseline, the blink
/// phases, the cell and frame sizes and the instance counts.
pub const DrawArgs = struct {
    atlas: *const Atlas,
    ascender: f32,
    blink_on: bool,
    blink_rapid_on: bool,
    cell: Dimension(f32),
    frame: Dimension(f32),
    gray_len: usize,
    color_len: usize,
    grayscale: f32 = 0.0,
    color_tint: [3]f32 = .{ 1.0, 1.0, 1.0 },
};

pub fn draw(self: *Cell, args: DrawArgs) void {
    self.setup(args, false);
    self.shader.set1i("u_is_color", 0);
    self.gray_buffer.draw(args.gray_len);

    // Pass 3: color emoji (premultiplied alpha)
    gl.blendFuncSeparate(
        gl.ONE,
        gl.ONE_MINUS_SRC_ALPHA, // RGB: premultiplied
        gl.ONE,
        gl.ONE_MINUS_SRC_ALPHA, // alpha: same
    );
    self.shader.set1i("u_is_color", 1);
    self.color_buffer.draw(args.color_len);
    gl.blendFuncSeparate(
        gl.SRC_ALPHA,
        gl.ONE_MINUS_SRC_ALPHA,
        gl.ONE,
        gl.ONE_MINUS_SRC_ALPHA,
    );
}

pub fn drawExternal(self: *Cell, gray_buffer: *Buffer, color_buffer: *Buffer, args: DrawArgs) void {
    self.setup(args, false);
    if (args.gray_len > 0) {
        self.shader.set1i("u_is_color", 0);
        gray_buffer.draw(args.gray_len);
    }
    if (args.color_len > 0) {
        gl.blendFuncSeparate(
            gl.ONE,
            gl.ONE_MINUS_SRC_ALPHA,
            gl.ONE,
            gl.ONE_MINUS_SRC_ALPHA,
        );
        self.shader.set1i("u_is_color", 1);
        color_buffer.draw(args.color_len);
        gl.blendFuncSeparate(
            gl.SRC_ALPHA,
            gl.ONE_MINUS_SRC_ALPHA,
            gl.ONE,
            gl.ONE_MINUS_SRC_ALPHA,
        );
    }
}

/// Draws the coverage of every glyph, gray and color, into the bound
/// framebuffer, keeping the highest coverage where glyphs overlap. The
/// decoration pass reads it to skip the underline where ink is.
pub fn drawInkMask(self: *Cell, args: DrawArgs) void {
    self.setup(args, true);
    gl.blendEquation(gl.MAX);
    gl.blendFuncSeparate(gl.ONE, gl.ONE, gl.ONE, gl.ONE);
    self.shader.set1i("u_is_color", 0);
    self.gray_buffer.draw(args.gray_len);
    self.shader.set1i("u_is_color", 1);
    self.color_buffer.draw(args.color_len);
    self.shader.set1i("u_mask_mode", 0);
    gl.blendEquation(gl.FUNC_ADD);
    gl.blendFuncSeparate(
        gl.SRC_ALPHA,
        gl.ONE_MINUS_SRC_ALPHA,
        gl.ONE,
        gl.ONE_MINUS_SRC_ALPHA,
    );
}

fn setup(self: *Cell, args: DrawArgs, mask: bool) void {
    self.shader.use();
    self.shader.set2f(
        "u_atlas_size",
        @floatFromInt(args.atlas.width),
        @floatFromInt(args.atlas.height),
    );
    args.atlas.bindTextures(gl.TEXTURE0, gl.TEXTURE1);
    self.shader.set2f("u_cell_size", args.cell.width, args.cell.height);
    self.shader.set2f("u_screen_size", args.frame.width, args.frame.height);
    self.shader.set1f("u_ascender", args.ascender);
    self.shader.set1i("u_blink_on", @intFromBool(args.blink_on));
    self.shader.set1i("u_blink_rapid_on", @intFromBool(args.blink_rapid_on));
    self.shader.set1i("u_mask_mode", @intFromBool(mask));
    self.shader.set1f("u_grayscale", args.grayscale);
    self.shader.set3f("u_color_tint", args.color_tint[0], args.color_tint[1], args.color_tint[2]);
}
