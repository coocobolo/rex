const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

const c = @import("glfw");

const Window = @import("Window.zig");

test "bellKind: only X11 gets an audible bell" {
    const has_x11 = builtin.os.tag == .linux or builtin.os.tag == .freebsd;
    try testing.expectEqual(
        if (has_x11) Window.BellKind.audible_x11 else .attention_only,
        Window.bellKind(c.GLFW_PLATFORM_X11),
    );
    try testing.expectEqual(.attention_only, Window.bellKind(c.GLFW_PLATFORM_WAYLAND));
    try testing.expectEqual(.attention_only, Window.bellKind(c.GLFW_PLATFORM_NULL));
    try testing.expectEqual(.attention_only, Window.bellKind(c.GLFW_PLATFORM_COCOA));
    try testing.expectEqual(.attention_only, Window.bellKind(c.GLFW_PLATFORM_WIN32));
}

test "Xlib: the bell functions load next to GLFW's X11 connection" {
    // Needs GLFW running on X11 (a display, or Xvfb in CI). Doesn't ring:
    // a test shouldn't make a sound.
    try Window.testGlContext();
    if (c.glfwGetPlatform() != c.GLFW_PLATFORM_X11) return error.SkipZigTest;

    try testing.expect(Window.glfwGetX11Display() != null);
    var xlib = try Window.Xlib.load();
    xlib.close();
}
