const std = @import("std");
const log = std.log.scoped(.cursor);

const gl = @import("gl.zig");

const Shader = @import("Shader.zig");
const Atlas = @import("Atlas.zig");
const Dimension = @import("dimension.zig").Dimension;
const cellOff = @import("buffer.zig").cellOff;
const CellBuffer = @import("buffer.zig").CellBuffer;
const CellInstance = @import("Cell.zig").Instance;

const f32_size = @sizeOf(f32);
const cell_instance_size = @sizeOf(CellInstance);

const term = @import("../term/root.zig");
const CursorStyle = term.cell.CursorStyle;

pub const State = struct {
    col: u16,
    row: u16,

    /// Cursor shape + blink mode as reported by the terminal (\e[N q).
    style: CursorStyle = .default,

    /// Current blink phase. Only meaningful when style is a blinking variant.
    /// Toggled by the App timer tick; ignored for steady styles.
    blink_on: bool = true,

    /// Whether the cursor is visible at all (\e[?25l / \e[?25h).
    visibility: bool = true,

    color: [3]u8,

    /// metric for the glyph under the cursor
    glyph: ?Atlas.Metric = null,

    /// inverted fg (= bg color of cursor cell)
    glyph_fg: [3]u8 = .{ 0, 0, 0 },

    /// Returns true if the cursor should be drawn this frame.
    pub fn shouldDraw(self: State) bool {
        if (!self.visibility) return false;
        const is_blinking = self.style.blink() == .on;
        return !is_blinking or self.blink_on;
    }
};

pub const Cursor = @This();

pub const Option = struct {
    radius: f32 = 5.0,
    underline_frac: f32 = 0.16,
    bar_frac: f32 = 0.16,
    bar_offset_y: f32 = 1.0,
    alpha: f32 = 1.0,
    /// outline width when unfocused; 0 = always filled
    hollow_border_width: f32 = 3.0,
};

shader: Shader,
vao: gl.GLuint,
glyph_inst_vbo: gl.GLuint,
quad_vbo: gl.GLuint,
option: Option,

const quad_verts = [8]f32{
    0.0, 0.0, 1.0, 0.0,
    0.0, 1.0, 1.0, 1.0,
};

const quad_verts_size = @sizeOf(@TypeOf(quad_verts));

pub fn init(option: Option) !Cursor {
    const shader = try Shader.init(
        @embedFile("shaders/cursor.vert"),
        @embedFile("shaders/cursor.frag"),
    );
    errdefer shader.deinit();

    var vao: gl.GLuint = undefined;
    var quad_vbo: gl.GLuint = undefined;
    var glyph_inst_vbo: gl.GLuint = undefined;

    gl.genVertexArrays(1, &vao);
    gl.genBuffers(1, &quad_vbo);
    gl.genBuffers(1, &glyph_inst_vbo);

    errdefer {
        gl.deleteVertexArrays(1, &vao);
        gl.deleteBuffers(1, &quad_vbo);
        gl.deleteBuffers(1, &glyph_inst_vbo);
    }

    gl.bindVertexArray(vao);

    // loc 0: quad vertices (static, shared by cursor block and glyph passes)
    gl.bindBuffer(gl.ARRAY_BUFFER, quad_vbo);
    gl.bufferData(gl.ARRAY_BUFFER, quad_verts_size, &quad_verts, gl.STATIC_DRAW);
    gl.enableVertexAttribArray(0);
    gl.vertexAttribPointer(0, 2, gl.FLOAT, gl.FALSE, 2 * f32_size, null);

    // instance VBO (dynamic, per cell)
    gl.bindBuffer(gl.ARRAY_BUFFER, glyph_inst_vbo);
    gl.bufferData(gl.ARRAY_BUFFER, @as(gl.GLsizeiptr, cell_instance_size), null, gl.DYNAMIC_DRAW);

    const stride: gl.GLsizei = cell_instance_size;

    // loc 1: uvec2 a_cell col, row
    gl.enableVertexAttribArray(1);
    gl.vertexAttribIPointer(1, 2, gl.UNSIGNED_SHORT, stride, cellOff("col"));
    gl.vertexAttribDivisor(1, 1);

    // loc 2: uvec2 a_atlas_pos atlas_x, atlas_y
    gl.enableVertexAttribArray(2);
    gl.vertexAttribIPointer(2, 2, gl.UNSIGNED_SHORT, stride, cellOff("atlas_x"));
    gl.vertexAttribDivisor(2, 1);

    // loc 3: uvec2 a_glyph_size glyph_width, glyph_height
    gl.enableVertexAttribArray(3);
    gl.vertexAttribIPointer(3, 2, gl.UNSIGNED_SHORT, stride, cellOff("glyph_width"));
    gl.vertexAttribDivisor(3, 1);

    // loc 4: ivec2 a_bearing bearing_x, bearing_y
    gl.enableVertexAttribArray(4);
    gl.vertexAttribIPointer(4, 2, gl.SHORT, stride, cellOff("bearing_x"));
    gl.vertexAttribDivisor(4, 1);

    // loc 5: uvec4 a_fg fg_r, fg_g, fg_b, fg_a (4 consecutive bytes)
    gl.enableVertexAttribArray(5);
    gl.vertexAttribPointer(5, 4, gl.UNSIGNED_BYTE, gl.TRUE, stride, cellOff("fg_r"));
    gl.vertexAttribDivisor(5, 1);

    // loc 6: uint a_flags Flags packed byte
    gl.enableVertexAttribArray(6);
    gl.vertexAttribIPointer(6, 1, gl.UNSIGNED_BYTE, stride, cellOff("flags"));
    gl.vertexAttribDivisor(6, 1);

    gl.bindVertexArray(0);
    gl.bindBuffer(gl.ARRAY_BUFFER, 0);

    return .{
        .glyph_inst_vbo = glyph_inst_vbo,
        .option = option,
        .quad_vbo = quad_vbo,
        .shader = shader,
        .vao = vao,
    };
}

pub fn deinit(self: *Cursor) void {
    self.shader.deinit();

    gl.deleteVertexArrays(1, &self.vao);
    gl.deleteBuffers(1, &self.quad_vbo);
    gl.deleteBuffers(1, &self.glyph_inst_vbo);
}

pub fn upload(self: *Cursor, state: State) void {

    // Upload glyph instance before binding VAO (avoids redundant bind/unbind)
    if (state.glyph) |metric| {
        const inst: CellInstance = .{
            .col = state.col,
            .row = state.row,
            .atlas_x = metric.atlas_x,
            .atlas_y = metric.atlas_y,
            .glyph_width = metric.width,
            .glyph_height = metric.height,
            .bearing_x = metric.bearing_x,
            .bearing_y = metric.bearing_y,
            .fg_r = state.glyph_fg[0],
            .fg_g = state.glyph_fg[1],
            .fg_b = state.glyph_fg[2],
            .fg_a = 255,
            .flags = .{},
        };

        gl.bindBuffer(gl.ARRAY_BUFFER, self.glyph_inst_vbo);
        gl.bufferSubData(gl.ARRAY_BUFFER, 0, cell_instance_size, &inst);
        gl.bindBuffer(gl.ARRAY_BUFFER, 0);
    }
}

pub fn draw(
    self: *Cursor,
    state: State,
    cell_shader: *const Shader,
    focused: bool,
    dimension: struct {
        cell: Dimension(f32),
        frame: Dimension(f32),
    },
) void {
    const opt = self.option;
    gl.bindVertexArray(self.vao); // single bind for both passes

    // Pass 1: cursor block (rounded rectangle)
    self.shader.use();
    self.shader.set2f("u_cell_size", dimension.cell.width, dimension.cell.height);
    self.shader.set2f("u_screen_size", dimension.frame.width, dimension.frame.height);
    self.shader.set2ui("u_cell_pos", state.col, state.row);
    self.shader.set4f(
        "u_cursor_color",
        @as(f32, @floatFromInt(state.color[0])) / 255.0,
        @as(f32, @floatFromInt(state.color[1])) / 255.0,
        @as(f32, @floatFromInt(state.color[2])) / 255.0,
        self.option.alpha,
    );
    self.shader.set1i("u_shape", @intFromEnum(state.style.shape()));
    self.shader.set1f("u_radius", opt.radius);
    const hollow: f32 = if (focused) 0.0 else opt.hollow_border_width;
    self.shader.set1f("u_hollow", hollow);
    self.shader.set1f("u_underline_frac", opt.underline_frac);
    self.shader.set1f("u_bar_frac", opt.bar_frac);
    self.shader.set1f("u_bar_offset_y", opt.bar_offset_y);
    gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4); // non-instanced, loc 1-6 ignored

    // Pass 2: glyph on top (block cursor only)
    if (state.glyph != null and hollow == 0.0) {
        const metric = state.glyph.?;
        cell_shader.use();
        cell_shader.set2f("u_cell_size", dimension.cell.width, dimension.cell.height);
        cell_shader.set2f("u_screen_size", dimension.frame.width, dimension.frame.height);
        cell_shader.set1i("u_is_color", if (metric.kind == .color) 1 else 0);
        gl.drawArraysInstanced(gl.TRIANGLE_STRIP, 0, 4, 1); // 1 instance from glyph_inst_vbo
    }

    gl.bindVertexArray(0); // single unbind
}
