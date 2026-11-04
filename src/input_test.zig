//! Tests for the key encoding in input.zig.

const std = @import("std");
const testing = std.testing;

const c = @import("glfw");
const input = @import("input.zig");

const ctrl = c.GLFW_MOD_CONTROL;
const shift = c.GLFW_MOD_SHIFT;
const alt = c.GLFW_MOD_ALT;

fn expectKey(expected: []const u8, key: c_int, mods: c_int, ctx: input.KeyContext) !void {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings(expected, input.encodeKey(key, mods, ctx, &buf));
}

test "encodeKey: ctrl+backtick, ctrl+space and ctrl+2 send NUL" {
    try expectKey("\x00", c.GLFW_KEY_GRAVE_ACCENT, ctrl, .{});
    try expectKey("\x00", c.GLFW_KEY_SPACE, ctrl, .{});
    try expectKey("\x00", c.GLFW_KEY_2, ctrl, .{});
    try expectKey("\x1b\x00", c.GLFW_KEY_2, ctrl | alt, .{});
}

test "encodeKey: ctrl+6 and ctrl+^ send RS" {
    try expectKey("\x1e", c.GLFW_KEY_6, ctrl, .{});
    try expectKey("\x1e", c.GLFW_KEY_6, ctrl | shift, .{});
    try expectKey("\x1b\x1e", c.GLFW_KEY_6, ctrl | alt, .{});
}

test "encodeKey: other digits are left to the char callback" {
    try expectKey("", c.GLFW_KEY_2, 0, .{});
    try expectKey("", c.GLFW_KEY_5, ctrl, .{});
    try expectKey("\x1b5", c.GLFW_KEY_5, alt, .{});
}

test "encodeKey: modifyOtherKeys still wins for ctrl+digit" {
    try expectKey("\x1b[27;5;50~", c.GLFW_KEY_2, ctrl, .{ .modify_other_keys = 1 });
    try expectKey("\x1b[27;5;54~", c.GLFW_KEY_6, ctrl, .{ .modify_other_keys = 1 });
}
