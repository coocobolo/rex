//! Instanced GPU renderer for analytic Signed Distance Field (SDF) UI primitives.
//!
//! Renders cache-line-aligned 64-byte instances supporting rounded rectangle cards,
//! sub-pixel horizontal progress pills, sub-pixel vertical chart columns, circular
//! countdown rings, and step indicator pips in a single instanced draw call.

const Card = @This();

const std = @import("std");

const window_config = @import("../config/window.zig");
const gl = @import("gl.zig");
const Shader = @import("Shader.zig");
const Buffer = @import("buffer.zig").CardBuffer;
const Dimension = @import("dimension.zig").Dimension;

pub const default_capacity: usize = 64;

pub const BorderShape = Option.BorderShape;

pub const BorderStyle = Option.BorderStyle;

/// Analytic SDF shape primitive selector encoded in `Instance.kind`.
pub const Kind = enum(u32) {
    box = 0,
    bar_h = 1,
    bar_v = 2,
    ring = 3,
    pip = 4,
};

pub const Option = window_config.Surface;

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
    progress: f32 = 1.0,
    kind: Kind = .box,
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
