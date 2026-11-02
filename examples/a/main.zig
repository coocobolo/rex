const std = @import("std");
const glfw = @import("glfw").glfw;

pub fn main(_: std.process.Init) !void {
    _ = glfw.glfwInit();
    defer glfw.glfwTerminate();
    std.debug.print("ok!", .{});
}
