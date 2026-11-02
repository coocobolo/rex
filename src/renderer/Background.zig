const std = @import("std");
const log = std.log.scoped(.background);

const Flags = @import("frame.zig").Flags;
const gl = @import("gl.zig");
const Shader = @import("Shader.zig");
const Buffer = @import("buffer.zig").BgBuffer;
const Dimension = @import("dimension.zig").Dimension;

/// is already 16 bytes, with compact and cache-friendly, every decorated
/// cell has a background anyway. Splitting them into its own instance
/// means cells with both background and decoration apppear in two buffers
/// doubling CPU work in build background instance.
///
/// The decoration pass can't be skipped independently, they are always
/// drawn over the bg color in the same pixel region.
pub const Instance = extern struct {
    col: u16,
    row: u16,
    span: u16, // cell_span: how many columns this background covers

    // background color for decorations
    r: u8,
    g: u8,
    b: u8,
    a: u8,

    // foreground color for decorations
    fg_r: u8,
    fg_g: u8,
    fg_b: u8,
    fg_a: u8,

    flags: Flags,
    _pad: [1]u8 = .{0},
};

comptime {
    std.debug.assert(16 == @sizeOf(Instance));
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

pub fn draw(
    self: *Background,
    instance_length: usize,
    dimension: struct {
        cell: Dimension(f32),
        frame: Dimension(f32),
    },
    background_alpha: ?f32,
    blink_on: bool,
    blink_rapid_on: bool,
) void {
    if (instance_length == 0) return;
    self.shader.use();
    self.shader.set2f("u_cell_size", dimension.cell.width, dimension.cell.height);
    self.shader.set2f("u_screen_size", dimension.frame.width, dimension.frame.height);
    self.shader.set1f("u_bg_alpha", background_alpha orelse self.option.alpha);
    self.shader.set1i("u_blink_on", @intFromBool(blink_on));
    self.shader.set1i("u_blink_rapid_on", @intFromBool(blink_rapid_on));
    self.buffer.draw(instance_length);
}