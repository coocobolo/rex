//! Text decorations: underline, strikethrough and overline, drawn in
//! their own pass from one instance per run of decorated cells.

const std = @import("std");

const Buffer = @import("buffer.zig").DecorationBuffer;
const Dimension = @import("dimension.zig").Dimension;
const Flags = @import("Frame.zig").Flags;
const Rasterizer = @import("../freetype/root.zig").Rasterizer;
const Shader = @import("Shader.zig");

pub const Decoration = @This();

/// One run of horizontally adjacent cells on a row that share the same
/// decorations and colors. The colors are resolved by the frame builder
/// and carry the dim alpha.
pub const Instance = extern struct {
    col: u16,
    row: u16,
    /// Number of columns the run covers.
    span: u16,
    underline: [4]u8,
    strikethrough: [4]u8,
    overline: [4]u8,
    flags: Flags,
    _pad: [1]u8 = .{0},

    /// True when `next` continues this run: the same row, starting where
    /// this run ends, with the same flags and colors.
    pub fn continuedBy(self: Instance, next: Instance) bool {
        return self.row == next.row and
            self.col + self.span == next.col and
            @as(u8, @bitCast(self.flags)) == @as(u8, @bitCast(next.flags)) and
            std.mem.eql(u8, &self.underline, &next.underline) and
            std.mem.eql(u8, &self.strikethrough, &next.strikethrough) and
            std.mem.eql(u8, &self.overline, &next.overline);
    }
};

comptime {
    std.debug.assert(20 == @sizeOf(Instance));
}

/// Appends `instance` to `runs`, or widens the last run when `instance`
/// continues it. `runs` must have room for one more instance.
pub fn appendRun(runs: *std.ArrayListUnmanaged(Instance), instance: Instance) void {
    if (runs.items.len > 0) {
        const last = &runs.items[runs.items.len - 1];
        if (last.continuedBy(instance)) {
            last.span += instance.span;
            return;
        }
    }
    runs.appendAssumeCapacity(instance);
}

/// Adjusts one decoration line. Pixels are measured down from the top
/// of the cell. Every field left at its default keeps the font's line.
pub const Line = struct {
    /// Top of the line, replacing the font's position. null keeps the
    /// font's position.
    y: ?f32 = null,

    /// Added to the position after `y`, positive moves the line down.
    /// Unlike `y` it keeps following the font when the size changes.
    offset: f32 = 0,

    /// Thickness, replacing the font's. null keeps the font's.
    thickness: ?f32 = null,

    /// Multiplies the thickness after `thickness`.
    thickness_scale: f32 = 1.0,

    /// Applies the adjustments to the font line `font`, then rounds and
    /// clamps the result into a cell `cell_height` pixels tall.
    pub fn resolve(self: Line, font: Rasterizer.Line, cell_height: u16) Rasterizer.Line {
        const top = (self.y orelse font.y) + self.offset;
        const thickness = (self.thickness orelse font.thickness) * self.thickness_scale;
        return .fit(top, thickness, cell_height);
    }
};

/// Whether decorations are drawn over or under the glyphs.
pub const Order = enum {
    /// Lines cross the glyphs, descenders do not hide the underline.
    over_text,
    /// Glyphs cover the lines, as in the background pass.
    under_text,
};

/// User settings for decorations. The defaults draw every line where
/// the font puts it, in the text color.
pub const Option = struct {
    underline: Line = .{},

    /// Gap between the two lines of a double underline, in pixels.
    /// null uses the underline thickness.
    double_gap: ?f32 = null,

    strikethrough: Line = .{},

    /// Fonts have no overline metric: by default it sits at the top of
    /// the cell, as thick as the resolved underline.
    overline: Line = .{},

    /// Fixed color for each kind of line. null draws it in the text
    /// color, after SGR 7, DECSCNM and the selection text color.
    color: struct {
        underline: ?[3]u8 = null,
        strikethrough: ?[3]u8 = null,
        overline: ?[3]u8 = null,
    } = .{},

    /// Opacity of every line, 0.0 to 1.0, on top of the dim alpha.
    alpha: f32 = 1.0,

    /// Lines of SGR 2 (dim) text are dimmed like the text.
    dim: bool = true,

    /// Lines of SGR 5 and 6 (blink) text blink with the text.
    blink: bool = true,

    order: Order = .over_text,
};

/// Where each decoration line sits, in whole pixels down from the top
/// of the cell, as the shaders read it.
pub const Metrics = struct {
    underline_y: f32,
    underline_thickness: f32,
    /// Top of the upper line of a double underline. The lower line is
    /// the underline itself.
    double_y: f32,
    strikethrough_y: f32,
    strikethrough_thickness: f32,
    overline_y: f32,
    overline_thickness: f32,

    /// Resolves the font's lines through the user's `option`.
    pub fn resolve(font: Rasterizer.Metrics, option: Option) Metrics {
        const height = font.cell_height;
        const underline = option.underline.resolve(.{
            .y = font.underline_y,
            .thickness = font.underline_thickness,
        }, height);
        const strikethrough = option.strikethrough.resolve(.{
            .y = font.strikethrough_y,
            .thickness = font.strikethrough_thickness,
        }, height);
        const overline = option.overline.resolve(.{
            .y = 0,
            .thickness = underline.thickness,
        }, height);
        const gap = @round(@max(0, option.double_gap orelse underline.thickness));
        return .{
            .underline_y = underline.y,
            .underline_thickness = underline.thickness,
            .double_y = @max(0, underline.y - gap - underline.thickness),
            .strikethrough_y = strikethrough.y,
            .strikethrough_thickness = strikethrough.thickness,
            .overline_y = overline.y,
            .overline_thickness = overline.thickness,
        };
    }

    /// Sets the `u_underline_*`, `u_double_y`, `u_strikethrough_*` and
    /// `u_overline_*` uniforms on the bound `shader`.
    pub fn apply(self: Metrics, shader: Shader) void {
        shader.set1f("u_underline_y", self.underline_y);
        shader.set1f("u_underline_thickness", self.underline_thickness);
        shader.set1f("u_double_y", self.double_y);
        shader.set1f("u_strikethrough_y", self.strikethrough_y);
        shader.set1f("u_strikethrough_thickness", self.strikethrough_thickness);
        shader.set1f("u_overline_y", self.overline_y);
        shader.set1f("u_overline_thickness", self.overline_thickness);
    }
};

shader: Shader,
buffer: Buffer,
option: Option,

pub fn init(capacity: usize, option: Option) !Decoration {
    var shader: Shader = try .init(
        @embedFile("shaders/decoration.vert"),
        @embedFile("shaders/decoration.frag"),
    );
    errdefer shader.deinit();

    return .{
        .buffer = .init(capacity),
        .option = option,
        .shader = shader,
    };
}

pub fn deinit(self: *Decoration) void {
    self.shader.deinit();
    self.buffer.deinit();
    self.* = undefined;
}

pub fn upload(self: *Decoration, instances: []const Instance) void {
    if (instances.len > 0) self.buffer.upload(instances);
}

pub fn draw(
    self: *Decoration,
    instance_length: usize,
    dimension: struct {
        cell: Dimension(f32),
        frame: Dimension(f32),
    },
    metrics: Metrics,
    blink_on: bool,
    blink_rapid_on: bool,
) void {
    if (instance_length == 0) return;
    self.shader.use();
    self.shader.set2f("u_cell_size", dimension.cell.width, dimension.cell.height);
    self.shader.set2f("u_screen_size", dimension.frame.width, dimension.frame.height);
    self.shader.set1f("u_alpha", std.math.clamp(self.option.alpha, 0.0, 1.0));
    self.shader.set1i("u_blink_on", @intFromBool(blink_on));
    self.shader.set1i("u_blink_rapid_on", @intFromBool(blink_rapid_on));
    metrics.apply(self.shader);
    self.buffer.draw(instance_length);
}

test {
    _ = @import("decoration_test.zig");
}
