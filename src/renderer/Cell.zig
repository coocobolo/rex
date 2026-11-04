const std = @import("std");

const gl = @import("gl.zig");
const Atlas = @import("Atlas.zig");
const Shader = @import("Shader.zig");

const Buffer = @import("buffer.zig").CellBuffer;
const Flags = @import("Frame.zig").Flags;
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

pub fn draw(
    self: *Cell,
    atlas: *const Atlas,
    ascender: f32,
    cursor_state: struct { blink_on: bool, blink_rapid_on: bool },
    dimension: struct { cell: Dimension(f32), frame: Dimension(f32) },
    instance_len: struct { gray: usize, color: usize },
) void {
    self.shader.use();
    self.shader.set2f(
        "u_atlas_size",
        @floatFromInt(Atlas.texture_width),
        @floatFromInt(Atlas.texture_height),
    );
    atlas.bindTextures(gl.TEXTURE0, gl.TEXTURE1);
    self.shader.set2f("u_cell_size", dimension.cell.width, dimension.cell.height);
    self.shader.set2f("u_screen_size", dimension.frame.width, dimension.frame.height);
    self.shader.set1f("u_ascender", ascender);
    self.shader.set1i("u_is_color", 0);
    self.shader.set1i("u_blink_on", @intFromBool(cursor_state.blink_on));
    self.shader.set1i("u_blink_rapid_on", @intFromBool(cursor_state.blink_rapid_on));
    self.gray_buffer.draw(instance_len.gray);

    // Pass 3: color emoji (premultiplied alpha)
    gl.blendFuncSeparate(
        gl.ONE,
        gl.ONE_MINUS_SRC_ALPHA, // RGB: premultiplied
        gl.ONE,
        gl.ONE_MINUS_SRC_ALPHA, // alpha: same
    );
    self.shader.set1i("u_is_color", 1);
    self.color_buffer.draw(instance_len.color);
    gl.blendFuncSeparate(
        gl.SRC_ALPHA,
        gl.ONE_MINUS_SRC_ALPHA,
        gl.ONE,
        gl.ONE_MINUS_SRC_ALPHA,
    );
}
