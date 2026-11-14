//! Compiles and links every shader pair, so a GLSL error fails the
//! tests instead of the first frame.

const std = @import("std");

const Shader = @import("Shader.zig");
const testGlContext = @import("Window.zig").testGlContext;

const pairs = [_][2][:0]const u8{
    .{ @embedFile("shaders/background.vert"), @embedFile("shaders/background.frag") },
    .{ @embedFile("shaders/cell.vert"), @embedFile("shaders/cell.frag") },
    .{ @embedFile("shaders/cursor.vert"), @embedFile("shaders/cursor.frag") },
    .{ @embedFile("shaders/decoration.vert"), @embedFile("shaders/decoration.frag") },
    .{ @embedFile("shaders/scrollbar.vert"), @embedFile("shaders/scrollbar.frag") },
    .{ @embedFile("shaders/selection.vert"), @embedFile("shaders/selection.frag") },
    .{ @embedFile("shaders/kit.vert"), @embedFile("shaders/kit.frag") },
};

test "shaders: every pair compiles and links" {
    try testGlContext();
    for (pairs) |pair| {
        var shader = try Shader.init(pair[0], pair[1]);
        shader.deinit();
    }
}
