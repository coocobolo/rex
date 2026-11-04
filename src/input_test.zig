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

test "encodeKey: ctrl+3 to ctrl+8 send ESC, FS, GS, RS, US and DEL" {
    try expectKey("\x1b", c.GLFW_KEY_3, ctrl, .{});
    try expectKey("\x1c", c.GLFW_KEY_4, ctrl, .{});
    try expectKey("\x1d", c.GLFW_KEY_5, ctrl, .{});
    try expectKey("\x1e", c.GLFW_KEY_6, ctrl, .{});
    try expectKey("\x1f", c.GLFW_KEY_7, ctrl, .{});
    try expectKey("\x7f", c.GLFW_KEY_8, ctrl, .{});
}

test "encodeKey: alt puts ESC before a ctrl+digit code" {
    try expectKey("\x1b\x1b", c.GLFW_KEY_3, ctrl | alt, .{});
    try expectKey("\x1b\x1c", c.GLFW_KEY_4, ctrl | alt, .{});
    try expectKey("\x1b\x1d", c.GLFW_KEY_5, ctrl | alt, .{});
    try expectKey("\x1b\x1f", c.GLFW_KEY_7, ctrl | alt, .{});
    try expectKey("\x1b\x7f", c.GLFW_KEY_8, ctrl | alt, .{});
}

test "encodeKey: other digits are left to the char callback" {
    try expectKey("", c.GLFW_KEY_2, 0, .{});
    try expectKey("", c.GLFW_KEY_0, ctrl, .{});
    try expectKey("", c.GLFW_KEY_1, ctrl, .{});
    try expectKey("", c.GLFW_KEY_9, ctrl, .{});
    try expectKey("\x1b5", c.GLFW_KEY_5, alt, .{});
}

test "encodeKey: modifyOtherKeys still wins for ctrl+digit" {
    try expectKey("\x1b[27;5;50~", c.GLFW_KEY_2, ctrl, .{ .modify_other_keys = 1 });
    try expectKey("\x1b[27;5;54~", c.GLFW_KEY_6, ctrl, .{ .modify_other_keys = 1 });
    try expectKey("\x1b[27;5;56~", c.GLFW_KEY_8, ctrl, .{ .modify_other_keys = 2 });
    try expectKey("\x1b[27;7;51~", c.GLFW_KEY_3, ctrl | alt, .{ .modify_other_keys = 1 });
}
