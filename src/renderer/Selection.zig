const std = @import("std");
const log = std.log.scoped(.selection);

const gl = @import("gl.zig");
const Shader = @import("Shader.zig");
const Dimension = @import("dimension.zig").Dimension;
const Kind = @import("../Selection.zig").Kind;
const Buffer = @import("buffer.zig").SelectionBuffer;

pub const State = struct {
    start_row: u16,
    start_col: u16,
    end_row: u16,
    end_col: u16,
    active: bool,
    fg: ?[3]u8,
    bg: ?[3]u8,
    kind: Kind,

    pub const empty: State = .{
        .active = false,
        .bg = null,
        .fg = null,
        .start_row = 0,
        .start_col = 0,
        .end_row = 0,
        .end_col = 0,
        .kind = .character,
    };

    fn normalized(self: State) struct {
        lo_row: u16,
        lo_col: u16,
        hi_row: u16,
        hi_col: u16,
    } {
        const start_before_end = self.start_row < self.end_row or
            (self.start_row == self.end_row and self.start_col <= self.end_col);

        if (start_before_end) {
            return .{
                .lo_row = self.start_row,
                .lo_col = self.start_col,
                .hi_row = self.end_row,
                .hi_col = self.end_col,
            };
        }

        return .{
            .lo_row = self.end_row,
            .lo_col = self.end_col,
            .hi_row = self.start_row,
            .hi_col = self.start_col,
        };
    }

    /// For block selection, columns are independent of row ordering each row uses the
    /// same [lo_col, hi_col] pair regardless of which endpoint (start..end) is above or below.
    fn normalizedBlock(self: State) struct {
        lo_row: u16,
        lo_col: u16,
        hi_row: u16,
        hi_col: u16,
    } {
        return .{
            .lo_row = @min(self.start_row, self.end_row),
            .hi_row = @max(self.start_row, self.end_row),
            .lo_col = @min(self.start_col, self.end_col),
            .hi_col = @max(self.start_col, self.end_col),
        };
    }

    /// Returns true if the cell is inside the selection (inclusive).
    pub fn contains(self: State, row: u16, col: u16) bool {
        if (!self.active) return false;

        if (self.kind == .block) {
            const sel = self.normalizedBlock();
            return row >= sel.lo_row and
                row <= sel.hi_row and
                col >= sel.lo_col and
                col <= sel.hi_col;
        }

        const sel = self.normalized();
        if (row < sel.lo_row or row > sel.hi_row) return false;
        if (sel.lo_row == sel.hi_row) return col >= sel.lo_col and col <= sel.hi_col;
        if (row == sel.lo_row) return col >= sel.lo_col;
        if (row == sel.hi_row) return col <= sel.hi_col;
        return true;
    }
};

pub const Instance = extern struct {
    col: u16,
    row: u16,
    span: u16,
    // bit 0 = draw+top,
    // bit 1 = draw_bottom
    // bit 2 = is_rectangular
    flags: u16 = 0,
    prev_col: u16 = 0, // previous row's start col (same as col if is_first)
    prev_span: u16 = 0, // previous row's span (same as span if is_first)
    next_col: u16 = 0, // next row's start col (same as col if is_last)
    next_span: u16 = 0, // next row's span (same as span if is_last)
};

comptime {
    std.debug.assert(16 == @sizeOf(Instance));
}

pub const Selection = @This();

pub const BorderStyle = enum(u1) {
    /// Each row gets its own full border rectangle.
    per_row = 0,
    /// All rows share a single outer perimeter — no internal row dividers.
    unified = 1,
};

pub const Option = struct {
    /// RGBA highlight color.
    /// `.a` is the base opacity multiplier for both border and fill.
    /// Fill is further scaled by `fill_opacity`.
    fill_color: [4]f32 = .{ 0.2, 0.2, 0.2, 1.0 },

    border_color: [4]f32 = .{ 0.4, 0.4, 0.4, 1.0 },

    /// Outline/border width in pixels.
    /// 0.0 = no visible border (fill only). 2.0+ = thick border.
    border_width: f32 = 1.5,

    border_style: BorderStyle = .unified,

    /// Corner radius in pixels applied to the top corners of the first row
    /// and the bottom corners of the last row.
    /// 0.0 = sharp corners.
    radius: f32 = 3.0,
};

shader: Shader,
buffer: Buffer,
option: Option,

pub fn init(capacity: usize, option: Option) !Selection {
    var shader = try Shader.init(
        @embedFile("shaders/selection.vert"),
        @embedFile("shaders/selection.frag"),
    );
    errdefer shader.deinit();

    const buffer = Buffer.init(capacity);

    return .{
        .buffer = buffer,
        .shader = shader,
        .option = option,
    };
}

pub fn deinit(self: *Selection) void {
    self.shader.deinit();
    self.buffer.deinit();
    self.* = undefined;
}

pub fn upload(self: *Selection, instances: []const Instance) void {
    if (instances.len > 0) self.buffer.upload(instances);
}

/// Draw the selection highlight for the current frame.
pub fn draw(
    self: *Selection,
    instances_len: usize,
    color_override: ?[3]u8,
    dimension: struct {
        cell: Dimension(f32),
        frame: Dimension(f32),
    },
) void {
    if (instances_len == 0) return;

    self.shader.use();
    self.shader.set2f("u_cell_size", dimension.cell.width, dimension.cell.height);
    self.shader.set2f("u_screen_size", dimension.frame.width, dimension.frame.height);

    const color = color_override orelse .{
        @as(u8, @intFromFloat(self.option.fill_color[0] * 255)),
        @as(u8, @intFromFloat(self.option.fill_color[1] * 255)),
        @as(u8, @intFromFloat(self.option.fill_color[2] * 255)),
    };

    self.shader.set4f(
        "u_color",
        @as(f32, @floatFromInt(color[0])) / 255.0,
        @as(f32, @floatFromInt(color[1])) / 255.0,
        @as(f32, @floatFromInt(color[2])) / 255.0,
        self.option.fill_color[3],
    );

    self.shader.set1f("u_radius", self.option.radius);

    self.shader.set4f(
        "u_border_color",
        self.option.border_color[0],
        self.option.border_color[1],
        self.option.border_color[2],
        self.option.border_color[3],
    );
    self.shader.set1f("u_border_width", self.option.border_width);
    self.shader.set1ui("u_border_style", @intFromEnum(self.option.border_style));
    self.buffer.draw(instances_len);
}
