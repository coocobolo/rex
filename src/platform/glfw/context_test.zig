//! Integration test for the shared GL test context. It checks that the
//! helper leaves a usable context with GLAD loaded, that a second call keeps
//! it current, and that drawing and reading a pixel work.

const std = @import("std");
const testing = std.testing;

const backend = @import("backend.zig");
const gl = @import("../../renderer/gl.zig");

test "testGlContext: leaves a current OpenGL 3.3 context with GLAD loaded" {
    try backend.testGlContext();

    var major: c_int = 0;
    var minor: c_int = 0;
    var profile: c_int = 0;
    gl.getIntegerv(gl.MAJOR_VERSION, &major);
    gl.getIntegerv(gl.MINOR_VERSION, &minor);
    gl.getIntegerv(gl.CONTEXT_PROFILE_MASK, &profile);

    // GLAD is loaded if these enums return real values, not zeros.
    try testing.expect(major > 3 or (major == 3 and minor >= 3));
    try testing.expect(profile != 0);
}

test "testGlContext: a second call keeps the context and a draw round trip works" {
    try backend.testGlContext();

    var original: [4]f32 = undefined;
    gl.getFloatv(gl.COLOR_CLEAR_VALUE, &original);
    defer gl.clearColor(original[0], original[1], original[2], original[3]);

    const marker = [4]f32{ 0.125, 0.25, 0.5, 1.0 };
    gl.clearColor(marker[0], marker[1], marker[2], marker[3]);

    // A replacement context would have lost this state.
    try backend.testGlContext();
    var read_back: [4]f32 = undefined;
    gl.getFloatv(gl.COLOR_CLEAR_VALUE, &read_back);
    try testing.expectEqual(marker[0], read_back[0]);
    try testing.expectEqual(marker[1], read_back[1]);
    try testing.expectEqual(marker[2], read_back[2]);
    try testing.expectEqual(marker[3], read_back[3]);

    gl.viewport(0, 0, 1, 1);
    gl.clear(gl.COLOR_BUFFER_BIT);
    var pixel: [4]u8 = undefined;
    gl.readPixels(0, 0, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, &pixel);
    try testing.expect(pixel[0] > 0 and pixel[1] > 0 and pixel[2] > 0);
}
