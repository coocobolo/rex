pub const Shader = @This();

const std = @import("std");
const log = std.log.scoped(.shader);

const gl = @import("gl.zig");

program_id: gl.GLuint,

pub const Error = error{ CompileFailed, LinkFailed };

/// compile and link a vertex + fragment shader pair.
pub fn init(vert_source: [:0]const u8, frag_source: [:0]const u8) Error!Shader {
    const vert = try compile(gl.VERTEX_SHADER, vert_source);
    defer gl.deleteShader(vert);

    const frag = try compile(gl.FRAGMENT_SHADER, frag_source);
    defer gl.deleteShader(frag);

    const prog = gl.createProgram();
    gl.attachShader(prog, vert);
    gl.attachShader(prog, frag);
    gl.linkProgram(prog);

    var ok: gl.GLint = 0;
    gl.getProgramiv(prog, gl.LINK_STATUS, &ok);
    if (ok == gl.FALSE) {
        var buf: [1024]u8 = undefined;
        var len: gl.GLsizei = 0;
        gl.getProgramInfoLog(prog, buf.len, &len, &buf);
        log.err("shader link:\n{s}", .{buf[0..@intCast(len)]});
        gl.deleteProgram(prog);
        return error.LinkFailed;
    }

    return .{ .program_id = prog };
}

pub fn deinit(self: *Shader) void {
    gl.deleteProgram(self.program_id);
    self.* = undefined;
}

pub fn use(self: Shader) void {
    gl.useProgram(self.program_id);
}

pub fn unbind(_: Shader) void {
    gl.useProgram(0);
}

pub fn set1i(self: Shader, name: [:0]const u8, v: gl.GLint) void {
    const loc = gl.getUniformLocation(self.program_id, name.ptr);
    if (loc >= 0) gl.uniform1i(loc, v);
}

pub fn set2i(self: Shader, name: [:0]const u8, x: gl.GLint, y: gl.GLint) void {
    const loc = gl.getUniformLocation(self.program_id, name.ptr);
    if (loc >= 0) gl.uniform2i(loc, x, y);
}

pub fn set4f(self: Shader, name: [:0]const u8, x: f32, y: f32, z: f32, w: f32) void {
    const loc = gl.getUniformLocation(self.program_id, name.ptr);
    if (loc >= 0) gl.uniform4f(loc, x, y, z, w);
}

pub fn set3f(self: Shader, name: [:0]const u8, x: f32, y: f32, z: f32) void {
    const loc = gl.getUniformLocation(self.program_id, name.ptr);
    if (loc >= 0) gl.uniform3f(loc, x, y, z);
}

pub fn set2f(self: Shader, name: [:0]const u8, x: gl.GLfloat, y: gl.GLfloat) void {
    const loc = gl.getUniformLocation(self.program_id, name.ptr);
    if (loc >= 0) gl.uniform2f(loc, x, y);
}

pub fn set1f(self: Shader, name: [:0]const u8, v: gl.GLfloat) void {
    const loc = gl.getUniformLocation(self.program_id, name.ptr);
    if (loc >= 0) gl.uniform1f(loc, v);
}

pub fn set1ui(self: Shader, name: [:0]const u8, v: gl.GLuint) void {
    const loc = gl.getUniformLocation(self.program_id, name.ptr);
    if (loc >= 0) gl.uniform1ui(loc, v);
}

pub fn set2ui(self: Shader, name: [:0]const u8, v0: gl.GLuint, v1: gl.GLuint) void {
    const loc = gl.getUniformLocation(self.program_id, name.ptr);
    if (loc >= 0) gl.uniform2ui(loc, v0, v1);
}

pub fn set1b(self: Shader, name: [:0]const u8, v: bool) void {
    const loc = gl.getUniformLocation(self.program_id, name.ptr);
    if (loc >= 0) gl.uniform1i(loc, if (v) 1 else 0);
}

pub fn setMat4(self: Shader, name: [:0]const u8, m: [16]f32) void {
    const loc = gl.getUniformLocation(self.program_id, name);
    gl.uniformMatrix4fv(loc, 1, gl.FALSE, &m);
}

fn compile(kind: gl.GLenum, src: [:0]const u8) Error!gl.GLuint {
    const s = gl.createShader(kind);
    const ptr: [*c]const u8 = src.ptr;
    gl.shaderSource(s, 1, &ptr, null);
    gl.compileShader(s);

    var ok: gl.GLint = 0;
    gl.getShaderiv(s, gl.COMPILE_STATUS, &ok);
    if (ok == gl.FALSE) {
        var buf: [1024]u8 = undefined;
        var len: gl.GLsizei = 0;

        gl.getShaderInfoLog(s, @intCast(buf.len), &len, &buf);
        log.err("shader compile:\n{s}", .{buf[0..@intCast(len)]});
        gl.deleteShader(s);
        return error.CompileFailed;
    }
    return s;
}

fn compileProgram(vert_src: []const u8, frag_src: []const u8) !gl.GLuint {
    const vert = try compileShader(gl.VERTEX_SHADER, vert_src);
    defer gl.deleteShader(vert);
    const frag = try compileShader(gl.FRAGMENT_SHADER, frag_src);
    defer gl.deleteShader(frag);

    const prog = gl.createProgram();
    gl.attachShader(prog, vert);
    gl.attachShader(prog, frag);
    gl.linkProgram(prog);

    var ok: gl.GLint = 0;
    gl.getProgramiv(prog, gl.LINK_STATUS, &ok);
    if (ok == 0) {
        var buf: [512]u8 = undefined;
        gl.getProgramInfoLog(prog, buf.len, null, &buf);
        std.log.err("link error: {s}", .{buf});
        return error.LinkFailed;
    }
    return prog;
}

fn compileShader(kind: gl.GLenum, src: []const u8) !gl.GLuint {
    const sh = gl.createShader(kind);
    const ptr: [*]const u8 = src.ptr;
    const len: gl.GLint = @intCast(src.len);
    gl.shaderSource(sh, 1, &ptr, &len);
    gl.compileShader(sh);

    var ok: gl.GLint = 0;
    gl.getShaderiv(sh, gl.COMPILE_STATUS, &ok);
    if (ok == 0) {
        var buf: [512]u8 = undefined;
        gl.getShaderInfoLog(sh, buf.len, null, &buf);
        std.log.err("shader compile error: {s}", .{buf});
        gl.deleteShader(sh);
        return error.CompileFailed;
    }
    return sh;
}
