//! Instanced GPU renderer for analytic Signed Distance Field (SDF) rounded rectangles and UI cards.

const Card = @This();

const std = @import("std");
const gl = @import("gl.zig");
const Shader = @import("Shader.zig");
const Buffer = @import("buffer.zig").CardBuffer;
const Dimension = @import("dimension.zig").Dimension;

pub const default_capacity: usize = 64;

pub const BorderShape = enum {
    rounded,
    sharp,
};

pub const BorderStyle = enum {
    semantic,
    subtle,
};

pub const Option = struct {
    corner_radius: f32 = 8.0,
    border_width: f32 = 1.0,
    border_shape: BorderShape = .rounded,
    border_style: BorderStyle = .semantic,

    pub inline fn effectiveRadius(self: Option) f32 {
        return switch (self.border_shape) {
            .rounded => self.corner_radius,
            .sharp => 0.0,
        };
    }
};

/// Single card instance aligned to 64 bytes (one CPU cache line) for instanced GPU upload.
pub const Instance = extern struct {
    col: u16,
    row: u16,
    width: u16,
    height: u16,
    offset_x: f32 = 0.0,
    offset_y: f32 = 0.0,
    bg_color: [4]f32,
    border_color: [4]f32,
    radius: f32 = 8.0,
    border_width: f32 = 1.0,
    _pad: [2]f32 = .{ 0.0, 0.0 },
};

comptime {
    std.debug.assert(@sizeOf(Instance) == 64);
}

shader: Shader,
buffer: Buffer,

pub fn init() !Card {
    return initWithCapacity(default_capacity);
}

pub fn initWithCapacity(capacity: usize) !Card {
    var shader = try Shader.init(
        @embedFile("shaders/card.vert"),
        @embedFile("shaders/card.frag"),
    );
    errdefer shader.deinit();

    var buffer = Buffer.init(capacity);
    errdefer buffer.deinit();

    return .{
        .shader = shader,
        .buffer = buffer,
    };
}

pub fn deinit(self: *Card) void {
    self.shader.deinit();
    self.buffer.deinit();
    self.* = undefined;
}

pub fn upload(self: *Card, instances: []const Instance) void {
    if (instances.len > 0) self.buffer.upload(instances);
}

pub fn draw(
    self: *Card,
    instances: []const Instance,
    frame_dimension: Dimension(f32),
    cell_dimension: Dimension(f32),
) void {
    if (instances.len == 0) return;

    self.buffer.upload(instances);
    self.shader.use();
    self.shader.set2f("u_fb", frame_dimension.width, frame_dimension.height);
    self.shader.set2f("u_cell_size", cell_dimension.width, cell_dimension.height);
    self.buffer.draw(instances.len);
    self.shader.unbind();
}

test "Card: Instance layout is 64-byte cache-line sized and Option resolves sharp vs rounded radius" {
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(Instance));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(Instance, "col"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(Instance, "offset_x"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(Instance, "bg_color"));
    try std.testing.expectEqual(@as(usize, 32), @offsetOf(Instance, "border_color"));
    try std.testing.expectEqual(@as(usize, 48), @offsetOf(Instance, "radius"));

    const rounded_opt: Option = .{ .corner_radius = 10.0, .border_shape = .rounded };
    const sharp_opt: Option = .{ .corner_radius = 10.0, .border_shape = .sharp };
    try std.testing.expectEqual(@as(f32, 10.0), rounded_opt.effectiveRadius());
    try std.testing.expectEqual(@as(f32, 0.0), sharp_opt.effectiveRadius());
}
