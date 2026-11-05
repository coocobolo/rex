const std = @import("std");
const log = std.log.scoped(.background);

const gl = @import("gl.zig");
const Shader = @import("Shader.zig");
const Buffer = @import("buffer.zig").BgBuffer;
const Dimension = @import("dimension.zig").Dimension;

/// The background color of one cell, or of both halves of a wide one.
/// Decorations are drawn by the Decoration pass.
pub const Instance = extern struct {
    col: u16,
    row: u16,
    span: u16, // cell_span: how many columns this background covers

    r: u8,
    g: u8,
    b: u8,
    a: u8,

    _pad: [2]u8 = .{0} ** 2,
};

comptime {
    std.debug.assert(12 == @sizeOf(Instance));
}

pub const Background = @This();

pub const Option = struct {
    /// Global background opacity multiplier (0.0-1.0).
    alpha: f32 = 1.0,
};

shader: Shader,
buffer: Buffer,
option: Option,

pub fn init(capacity: usize, option: Option) !Background {
    const shader: Shader = try .init(
        @embedFile("shaders/background.vert"),
        @embedFile("shaders/background.frag"),
    );
    errdefer shader.deinit();

    var buffer: Buffer = .init(capacity);
    errdefer buffer.deinit();

    return .{
        .buffer = buffer,
        .option = option,
        .shader = shader,
    };
}

pub fn deinit(self: *Background) void {
    self.shader.deinit();
    self.buffer.deinit();
    self.* = undefined;
}

pub fn upload(self: *Background, instances: []const Instance) void {
    if (instances.len > 0) self.buffer.upload(instances);
}

pub fn uploadRange(self: *Background, instances: []const Instance, offset: usize, count: usize) void {
    if (count > 0) self.buffer.uploadRange(instances, offset, count);
}

pub fn draw(
    self: *Background,
    instance_length: usize,
    dimension: struct {
        cell: Dimension(f32),
        frame: Dimension(f32),
    },
    background_alpha: ?f32,
    grayscale: f32,
    color_tint: [3]f32,
) void {
    if (instance_length == 0) return;
    self.shader.use();
    self.shader.set2f("u_cell_size", dimension.cell.width, dimension.cell.height);
    self.shader.set2f("u_screen_size", dimension.frame.width, dimension.frame.height);
    self.shader.set1f("u_bg_alpha", background_alpha orelse self.option.alpha);
    self.shader.set1f("u_grayscale", grayscale);
    self.shader.set3f("u_color_tint", color_tint[0], color_tint[1], color_tint[2]);
    self.buffer.draw(instance_length);
}
