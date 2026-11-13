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

test "selections: CLIPBOARD and PRIMARY set and read back on X11" {
    try Window.testGlContext();
    if (c.glfwGetPlatform() != c.GLFW_PLATFORM_X11) return error.SkipZigTest;

    var win: Window = .{ .handle = c.glfwGetCurrentContext().? };
    try testing.expect(win.setPrimarySelection("from osc 52"));
    try testing.expectEqualStrings("from osc 52", win.getPrimarySelection().?);
    win.setClipboard("clipboard text");
    try testing.expectEqualStrings("clipboard text", win.getClipboard().?);
    try testing.expectEqualStrings("from osc 52", win.getPrimarySelection().?);
}

test "choosePlatform: auto follows the session (Cocoa on macOS), an explicit choice is forced" {
    const macos = @import("builtin").os.tag == .macos;
    const Case = struct {
        requested: Window.Platform,
        wayland_session: bool,
        platform: c_int,
        forced: bool,
    };
    const cases = [_]Case{
        .{ .requested = .auto, .wayland_session = true, .platform = if (macos) c.GLFW_PLATFORM_COCOA else c.GLFW_PLATFORM_WAYLAND, .forced = false },
        .{ .requested = .auto, .wayland_session = false, .platform = if (macos) c.GLFW_PLATFORM_COCOA else c.GLFW_PLATFORM_X11, .forced = false },
        .{ .requested = .wayland, .wayland_session = true, .platform = c.GLFW_PLATFORM_WAYLAND, .forced = true },
        .{ .requested = .wayland, .wayland_session = false, .platform = c.GLFW_PLATFORM_WAYLAND, .forced = true },
        .{ .requested = .x11, .wayland_session = true, .platform = c.GLFW_PLATFORM_X11, .forced = true },
        .{ .requested = .x11, .wayland_session = false, .platform = c.GLFW_PLATFORM_X11, .forced = true },
    };
    for (cases) |case| {
        const choice = Window.choosePlatform(case.requested, case.wayland_session);
        try testing.expectEqual(case.platform, choice.platform);
        try testing.expectEqual(case.forced, choice.forced);
    }
}

test "PlatformChoice: formats as the platform name for the startup log" {
    var buf: [16]u8 = undefined;
    const x11: Window.PlatformChoice = .{ .platform = c.GLFW_PLATFORM_X11, .forced = false };
    try testing.expectEqualStrings("x11", try std.fmt.bufPrint(&buf, "{f}", .{x11}));
    const wayland: Window.PlatformChoice = .{ .platform = c.GLFW_PLATFORM_WAYLAND, .forced = true };
    try testing.expectEqualStrings("wayland", try std.fmt.bufPrint(&buf, "{f}", .{wayland}));
}

test "Window: bellPercent clamps the volume to XBell's 0..100" {
    try std.testing.expectEqual(0, Window.bellPercent(0));
    try std.testing.expectEqual(50, Window.bellPercent(0.5));
    try std.testing.expectEqual(100, Window.bellPercent(1));
    try std.testing.expectEqual(100, Window.bellPercent(7));
    try std.testing.expectEqual(0, Window.bellPercent(-1));
    try std.testing.expectEqual(0, Window.bellPercent(std.math.nan(f32)));
    try std.testing.expectEqual(0, Window.bellPercent(std.math.inf(f32)));
}
