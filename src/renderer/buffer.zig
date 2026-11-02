const std = @import("std");

const log = std.log.scoped(.buffer);

const gl = @import("gl.zig");

const CellInstance = @import("Cell.zig").Instance;
const BackgroundInstance = @import("Background.zig").Instance;
const SelectionInstance = @import("Selection.zig").Instance;
const SelectionPolygon = @import("frame.zig").SelectionPolygon;
const SelectionVertex = @import("frame.zig").SelectionVertex;

/// Unit quad in [0,1] space, TRIANGLE_STRIP order: TL, TR, BL, BR
const quad_verts = [8]f32{
    0.0, 0.0, 1.0, 0.0,
    0.0, 1.0, 1.0, 1.0,
};

const quad_verts_size = @sizeOf(@TypeOf(quad_verts));
const f32_size = @sizeOf(f32);
const cell_instance_size = @sizeOf(CellInstance);
const background_instance_size = @sizeOf(BackgroundInstance);
const selection_instance_size = @sizeOf(SelectionInstance);

pub inline fn cellOff(comptime field: []const u8) ?*const anyopaque {
    return @ptrFromInt(@offsetOf(CellInstance, field));
}

// offset  0: col: u16, row: u16             ->  loc 1: uvec2 a_cell
// offset  4: atlas_x: u16, atlas_y: u16     ->  loc 2: uvec2 a_atlas_pos
// offset  8: glyph_w: u16, glyph_h: u16     ->  loc 3: uvec2 a_glyph_size
// offset 12: bearing_x: i16, bearing_y: i16 ->  loc 4: ivec2 a_bearing
// offset 16: fg_r/g/b/a: u8 × 4             ->  loc 5: uvec4 a_fg
// offset 20: flags: Flags (u8)              ->  loc 6: uint a_flags
// offset 21: _pad[3]                        ->  not uploaded
pub const CellBuffer = struct {
    vao: gl.GLuint,
    quad_vbo: gl.GLuint,
    inst_vbo: gl.GLuint,
    capacity: usize,

    pub fn init(capacity: usize) CellBuffer {
        var self: CellBuffer = undefined;
        self.capacity = capacity;

        gl.genVertexArrays(1, &self.vao);
        gl.genBuffers(1, &self.quad_vbo);
        gl.genBuffers(1, &self.inst_vbo);

        gl.bindVertexArray(self.vao);

        // quad VBO (static, per-vertex)
        gl.bindBuffer(gl.ARRAY_BUFFER, self.quad_vbo);
        gl.bufferData(gl.ARRAY_BUFFER, quad_verts_size, &quad_verts, gl.STATIC_DRAW);
        // loc 0: vec2 a_pos
        gl.enableVertexAttribArray(0);
        gl.vertexAttribPointer(0, 2, gl.FLOAT, gl.FALSE, 2 * f32_size, null);

        // instance VBO (dynamic, per-cell)
        gl.bindBuffer(gl.ARRAY_BUFFER, self.inst_vbo);
        gl.bufferData(gl.ARRAY_BUFFER, @intCast(capacity * cell_instance_size), null, gl.DYNAMIC_DRAW);

        const stride: gl.GLsizei = cell_instance_size;

        // loc 1: uvec2 a_cell col, row
        gl.enableVertexAttribArray(1);
        gl.vertexAttribIPointer(1, 2, gl.UNSIGNED_SHORT, stride, cellOff("col"));
        gl.vertexAttribDivisor(1, 1);

        // loc 2: uvec2 a_atlas_pos atlas_x, atlas_y
        gl.enableVertexAttribArray(2);
        gl.vertexAttribIPointer(2, 2, gl.UNSIGNED_SHORT, stride, cellOff("atlas_x"));
        gl.vertexAttribDivisor(2, 1);

        // loc 3: uvec2 a_glyph_size glyph_w, glyph_h
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

        return self;
    }

    pub fn deinit(self: *CellBuffer) void {
        gl.deleteVertexArrays(1, &self.vao);
        gl.deleteBuffers(1, &self.quad_vbo);
        gl.deleteBuffers(1, &self.inst_vbo);
        self.* = undefined;
    }

    pub fn resize(self: *CellBuffer, new_cap: usize) void {
        if (new_cap <= self.capacity) return;
        self.capacity = new_cap;
        gl.bindBuffer(gl.ARRAY_BUFFER, self.inst_vbo);
        gl.bufferData(gl.ARRAY_BUFFER, @intCast(new_cap * cell_instance_size), null, gl.DYNAMIC_DRAW);
        gl.bindBuffer(gl.ARRAY_BUFFER, 0);
    }

    pub fn upload(self: *CellBuffer, instances: []const CellInstance) void {
        if (instances.len == 0) return;
        std.debug.assert(instances.len <= self.capacity);
        gl.bindBuffer(gl.ARRAY_BUFFER, self.inst_vbo);
        // orphan: discard old contents, get a fresh buffer
        gl.bufferData(gl.ARRAY_BUFFER, @as(gl.GLsizeiptr, @intCast(self.capacity * cell_instance_size)), null, gl.DYNAMIC_DRAW);
        gl.bufferSubData(gl.ARRAY_BUFFER, 0, @as(gl.GLsizeiptr, @intCast(instances.len * cell_instance_size)), instances.ptr);
        gl.bindBuffer(gl.ARRAY_BUFFER, 0);
    }

    pub fn draw(self: *const CellBuffer, count: usize) void {
        if (count == 0) return;
        gl.bindVertexArray(self.vao);
        gl.drawArraysInstanced(gl.TRIANGLE_STRIP, 0, 4, @intCast(count));
        gl.bindVertexArray(0);
    }
};

// offset  6: r/g/b/a: u8 × 4       ->  loc 3: vec4 a_bg (normalized)
// offset 10: fg_r/g/b/a: u8 × 4    ->  loc 4: vec4 a_fg (normalized)
// offset 14: flags: Flags (u8)     ->  loc 5: uint a_flags
// offset 15: _pad[1]               ->  not uploaded
inline fn bgOff(comptime field: []const u8) ?*const anyopaque {
    return @ptrFromInt(@offsetOf(BackgroundInstance, field));
}

pub const BgBuffer = struct {
    vao: gl.GLuint,
    quad_vbo: gl.GLuint,
    inst_vbo: gl.GLuint,
    capacity: usize,

    pub fn init(capacity: usize) BgBuffer {
        var self: BgBuffer = undefined;
        self.capacity = capacity;

        gl.genVertexArrays(1, &self.vao);
        gl.genBuffers(1, &self.quad_vbo);
        gl.genBuffers(1, &self.inst_vbo);

        gl.bindVertexArray(self.vao);

        // quad VBO (static)
        gl.bindBuffer(gl.ARRAY_BUFFER, self.quad_vbo);
        gl.bufferData(gl.ARRAY_BUFFER, quad_verts_size, &quad_verts, gl.STATIC_DRAW);
        gl.enableVertexAttribArray(0);
        gl.vertexAttribPointer(0, 2, gl.FLOAT, gl.FALSE, 2 * f32_size, null);

        // instance VBO (dynamic)
        gl.bindBuffer(gl.ARRAY_BUFFER, self.inst_vbo);
        gl.bufferData(gl.ARRAY_BUFFER, @intCast(capacity * background_instance_size), null, gl.DYNAMIC_DRAW);

        const stride: gl.GLsizei = background_instance_size;

        // loc 1: uvec2 a_cell — col, row
        gl.enableVertexAttribArray(1);
        gl.vertexAttribIPointer(1, 2, gl.UNSIGNED_SHORT, stride, bgOff("col"));
        gl.vertexAttribDivisor(1, 1);

        // loc 2: uint a_span — number of columns this bg covers
        gl.enableVertexAttribArray(2);
        gl.vertexAttribIPointer(2, 1, gl.UNSIGNED_SHORT, stride, bgOff("span"));
        gl.vertexAttribDivisor(2, 1);

        // loc 3: vec4 a_bg — normalized float from UNSIGNED_BYTE
        gl.enableVertexAttribArray(3);
        gl.vertexAttribPointer(3, 4, gl.UNSIGNED_BYTE, gl.TRUE, stride, bgOff("r"));
        gl.vertexAttribDivisor(3, 1);

        // loc 4: vec4 a_fg - normalized UNSIGNED_BYTE
        gl.enableVertexAttribArray(4);
        gl.vertexAttribPointer(4, 4, gl.UNSIGNED_BYTE, gl.TRUE, stride, bgOff("fg_r"));
        gl.vertexAttribDivisor(4, 1);

        // loc 5: uint a_flags Flags packed byte
        gl.enableVertexAttribArray(5);
        gl.vertexAttribIPointer(5, 1, gl.UNSIGNED_BYTE, stride, bgOff("flags"));
        gl.vertexAttribDivisor(5, 1);

        gl.bindVertexArray(0);
        gl.bindBuffer(gl.ARRAY_BUFFER, 0);

        return self;
    }

    pub fn deinit(self: *BgBuffer) void {
        gl.deleteVertexArrays(1, &self.vao);
        gl.deleteBuffers(1, &self.quad_vbo);
        gl.deleteBuffers(1, &self.inst_vbo);
        self.* = undefined;
    }

    pub fn resize(self: *BgBuffer, new_cap: usize) void {
        if (new_cap <= self.capacity) return;
        self.capacity = new_cap;
        gl.bindBuffer(gl.ARRAY_BUFFER, self.inst_vbo);
        gl.bufferData(gl.ARRAY_BUFFER, @intCast(new_cap * background_instance_size), null, gl.DYNAMIC_DRAW);
        gl.bindBuffer(gl.ARRAY_BUFFER, 0);
    }

    pub fn upload(self: *BgBuffer, instances: []const BackgroundInstance) void {
        if (instances.len == 0) return;
        std.debug.assert(instances.len <= self.capacity);
        gl.bindBuffer(gl.ARRAY_BUFFER, self.inst_vbo);
        gl.bufferData(gl.ARRAY_BUFFER, @as(gl.GLsizeiptr, @intCast(self.capacity * background_instance_size)), null, gl.DYNAMIC_DRAW);
        gl.bufferSubData(gl.ARRAY_BUFFER, 0, @as(gl.GLsizeiptr, @intCast(instances.len * background_instance_size)), instances.ptr);
        gl.bindBuffer(gl.ARRAY_BUFFER, 0);
    }

    pub fn draw(self: *const BgBuffer, count: usize) void {
        if (count == 0) return;
        gl.bindVertexArray(self.vao);
        gl.drawArraysInstanced(gl.TRIANGLE_STRIP, 0, 4, @intCast(count));
        gl.bindVertexArray(0);
    }
};

fn selOff(comptime field: []const u8) ?*const anyopaque {
    return @ptrFromInt(@offsetOf(SelectionInstance, field));
}

pub const SelectionBuffer = struct {
    vao: gl.GLuint,
    quad_vbo: gl.GLuint,
    inst_vbo: gl.GLuint,
    capacity: usize,

    pub fn init(capacity: usize) SelectionBuffer {
        var self: SelectionBuffer = undefined;
        self.capacity = capacity;

        gl.genVertexArrays(1, &self.vao);
        gl.genBuffers(1, &self.quad_vbo);
        gl.genBuffers(1, &self.inst_vbo);

        gl.bindVertexArray(self.vao);

        const stride = selection_instance_size; // 16

        // quad VBO (static) — loc 0
        gl.bindBuffer(gl.ARRAY_BUFFER, self.quad_vbo);
        gl.bufferData(gl.ARRAY_BUFFER, quad_verts_size, &quad_verts, gl.STATIC_DRAW);
        gl.enableVertexAttribArray(0);
        gl.vertexAttribPointer(0, 2, gl.FLOAT, gl.FALSE, 2 * f32_size, null);

        // instance VBO (dynamic) — loc 1, 2
        gl.bindBuffer(gl.ARRAY_BUFFER, self.inst_vbo);
        gl.bufferData(gl.ARRAY_BUFFER, @intCast(capacity * stride), null, gl.DYNAMIC_DRAW);

        gl.enableVertexAttribArray(1);
        gl.vertexAttribIPointer(1, 2, gl.UNSIGNED_SHORT, stride, @ptrFromInt(0));
        gl.vertexAttribDivisor(1, 1);

        gl.enableVertexAttribArray(2);
        gl.vertexAttribIPointer(2, 1, gl.UNSIGNED_SHORT, stride, @ptrFromInt(4));
        gl.vertexAttribDivisor(2, 1);

        // loc 3: uint a_flags
        gl.enableVertexAttribArray(3);
        gl.vertexAttribIPointer(3, 1, gl.UNSIGNED_SHORT, stride, @ptrFromInt(6));
        gl.vertexAttribDivisor(3, 1);

        // loc 4: a_prev (prev_col, prev_span) — uvec2 at offset 8
        gl.vertexAttribIPointer(4, 2, gl.UNSIGNED_SHORT, stride, @ptrFromInt(8));
        gl.vertexAttribDivisor(4, 1);
        gl.enableVertexAttribArray(4);

        // loc 5: a_next (next_col, next_span) — uvec2 at offset 12
        gl.vertexAttribIPointer(5, 2, gl.UNSIGNED_SHORT, stride, @ptrFromInt(12));
        gl.vertexAttribDivisor(5, 1);
        gl.enableVertexAttribArray(5);

        gl.bindVertexArray(0);
        gl.bindBuffer(gl.ARRAY_BUFFER, 0);

        return self;
    }

    pub fn deinit(self: *SelectionBuffer) void {
        gl.deleteVertexArrays(1, &self.vao);
        gl.deleteBuffers(1, &self.quad_vbo);
        gl.deleteBuffers(1, &self.inst_vbo);
        self.* = undefined;
    }

    pub fn resize(self: *SelectionBuffer, capacity: usize) void {
        if (capacity <= self.capacity) return;
        self.capacity = capacity;
        gl.bindBuffer(gl.ARRAY_BUFFER, self.inst_vbo);
        gl.bufferData(gl.ARRAY_BUFFER, @intCast(capacity * selection_instance_size), null, gl.DYNAMIC_DRAW);
        gl.bindBuffer(gl.ARRAY_BUFFER, 0);
    }

    pub fn upload(self: *SelectionBuffer, instances: []const SelectionInstance) void {
        if (instances.len == 0) return;
        std.debug.assert(instances.len <= self.capacity);
        gl.bindBuffer(gl.ARRAY_BUFFER, self.inst_vbo);
        gl.bufferData(gl.ARRAY_BUFFER, @as(gl.GLsizeiptr, @intCast(self.capacity * selection_instance_size)), null, gl.DYNAMIC_DRAW);
        gl.bufferSubData(gl.ARRAY_BUFFER, 0, @as(gl.GLsizeiptr, @intCast(instances.len * selection_instance_size)), instances.ptr);
        gl.bindBuffer(gl.ARRAY_BUFFER, 0);
    }

    pub fn draw(self: *const SelectionBuffer, count: usize) void {
        if (count == 0) return;
        gl.bindVertexArray(self.vao);
        gl.drawArraysInstanced(gl.TRIANGLE_STRIP, 0, 4, @intCast(count));
        gl.bindVertexArray(0);
    }
};

pub const PolygonBuffer = struct {
    vao: gl.GLuint,
    vbo: gl.GLuint,

    const vertex_size = @sizeOf(SelectionVertex);

    pub fn init() PolygonBuffer {
        var self: PolygonBuffer = undefined;

        gl.genVertexArrays(1, &self.vao);
        gl.genBuffers(1, &self.vbo);

        gl.bindVertexArray(self.vao);
        gl.bindBuffer(gl.ARRAY_BUFFER, self.vbo);

        // Fixed capacity max 8 SelectionVertex
        gl.bufferData(gl.ARRAY_BUFFER, @as(gl.GLsizeiptr, 8 * vertex_size), null, gl.DYNAMIC_DRAW);

        // loc 0: uvec2 a_cell (col: u16, row: u16)
        gl.enableVertexAttribArray(0);
        gl.vertexAttribIPointer(0, 2, gl.UNSIGNED_SHORT, vertex_size, @ptrFromInt(0));

        gl.bindVertexArray(0);
        gl.bindBuffer(gl.ARRAY_BUFFER, 0);

        return self;
    }

    pub fn deinit(self: *PolygonBuffer) void {
        gl.deleteVertexArrays(1, &self.vao);
        gl.deleteBuffers(1, &self.vbo);
        self.* = undefined;
    }

    pub fn upload(self: *PolygonBuffer, poly: SelectionPolygon) void {
        if (poly.count == 0) return;
        gl.bindBuffer(gl.ARRAY_BUFFER, self.vbo);
        gl.bufferSubData(
            gl.ARRAY_BUFFER,
            0,
            @as(gl.GLsizeiptr, @intCast(poly.count)) * vertex_size,
            &poly.vertices,
        );
        gl.bindBuffer(gl.ARRAY_BUFFER, 0);
    }

    pub fn draw(self: *const PolygonBuffer, count: u8) void {
        if (count == 0) return;
        gl.bindVertexArray(self.vao);
        gl.drawArrays(gl.TRIANGLE_FAN, 0, @intCast(count));
        gl.bindVertexArray(0);
    }
};
