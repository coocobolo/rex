//! GLFW C callbacks translate native events into `platform.Event` values and
//! push them into the process-wide ring. No application logic lives here.

const std = @import("std");
const c = @import("glfw");

const backend = @import("backend.zig");
const events = @import("../Event.zig");
const Window = @import("../Window.zig");
const key = @import("key.zig");

fn eventWindow(handle: ?*c.GLFWwindow) ?Window {
    const impl = c.glfwGetWindowUserPointer(handle) orelse return null;
    return .{ .impl = impl };
}

fn action(from: c_int) events.Action {
    return switch (from) {
        c.GLFW_PRESS => .press,
        c.GLFW_RELEASE => .release,
        c.GLFW_REPEAT => .repeat,
        else => .press,
    };
}

fn button(from: c_int) ?events.MouseButton {
    return switch (from) {
        c.GLFW_MOUSE_BUTTON_LEFT => .left,
        c.GLFW_MOUSE_BUTTON_MIDDLE => .middle,
        c.GLFW_MOUSE_BUTTON_RIGHT => .right,
        else => null,
    };
}

/// Pushes a GLFW key event into the ring.
pub fn keyCallback(handle: ?*c.GLFWwindow, code: c_int, _: c_int, from: c_int, mods: c_int) callconv(.c) void {
    const window = eventWindow(handle) orelse return;
    const mapped = key.key(code) orelse return;
    backend.pushEvent(.{ .key = .{
        .window = window,
        .key = mapped,
        .mods = key.modifiers(mods),
        .action = action(from),
    } });
}

/// Pushes a printable codepoint into the ring.
pub fn charCallback(handle: ?*c.GLFWwindow, codepoint: c_uint) callconv(.c) void {
    const window = eventWindow(handle) orelse return;
    const cp = std.math.cast(u21, codepoint) orelse return;
    backend.pushEvent(.{ .text = .{
        .window = window,
        .codepoint = cp,
    } });
}

/// Pushes a mouse button transition into the ring.
pub fn mouseButtonCallback(handle: ?*c.GLFWwindow, from: c_int, pressed: c_int, mods: c_int) callconv(.c) void {
    const window = eventWindow(handle) orelse return;
    const mapped = button(from) orelse return;
    backend.pushEvent(.{ .mouse_button = .{
        .window = window,
        .button = mapped,
        .action = action(pressed),
        .mods = key.modifiers(mods),
    } });
}

/// Pushes a pointer position into the ring.
pub fn cursorPosCallback(handle: ?*c.GLFWwindow, x: f64, y: f64) callconv(.c) void {
    const window = eventWindow(handle) orelse return;
    backend.pushEvent(.{ .cursor_pos = .{ .window = window, .x = x, .y = y } });
}

/// Pushes wheel movement into the ring.
pub fn scrollCallback(handle: ?*c.GLFWwindow, dx: f64, dy: f64) callconv(.c) void {
    const window = eventWindow(handle) orelse return;
    backend.pushEvent(.{ .scroll = .{ .window = window, .dx = dx, .dy = dy } });
}

/// Pushes a pointer enter or leave into the ring.
pub fn cursorEnterCallback(handle: ?*c.GLFWwindow, entered: c_int) callconv(.c) void {
    const window = eventWindow(handle) orelse return;
    backend.pushEvent(.{ .cursor_enter = .{ .window = window, .entered = entered != 0 } });
}

/// Pushes a focus change into the ring.
pub fn focusCallback(handle: ?*c.GLFWwindow, focused: c_int) callconv(.c) void {
    const window = eventWindow(handle) orelse return;
    backend.pushEvent(.{ .focus = .{ .window = window, .focused = focused != 0 } });
}

/// Pushes a framebuffer resize into the ring.
pub fn framebufferSizeCallback(handle: ?*c.GLFWwindow, width: c_int, height: c_int) callconv(.c) void {
    const window = eventWindow(handle) orelse return;
    backend.pushEvent(.{ .framebuffer_size = .{
        .window = window,
        .width = @intCast(@max(width, 0)),
        .height = @intCast(@max(height, 0)),
    } });
}

/// Pushes a content scale change into the ring.
pub fn contentScaleCallback(handle: ?*c.GLFWwindow, x: f32, y: f32) callconv(.c) void {
    const window = eventWindow(handle) orelse return;
    backend.pushEvent(.{ .content_scale = .{ .window = window, .x = x, .y = y } });
}

/// Pushes a close request into the ring.
pub fn closeCallback(handle: ?*c.GLFWwindow) callconv(.c) void {
    const window = eventWindow(handle) orelse return;
    backend.pushEvent(.{ .close = .{ .window = window } });
}
