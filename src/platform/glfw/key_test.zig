const std = @import("std");
const testing = std.testing;

const c = @import("glfw");
const keys = @import("key.zig");

test "glfw key: every mapped key has a reverse code" {
    var candidate: usize = 0;
    while (candidate < 512) : (candidate += 1) {
        const code: c_int = @intCast(candidate);
        if (keys.key(code)) |mapped| {
            const back = keys.toGlfw(mapped);
            try testing.expect(back != null);
            try testing.expectEqual(mapped, keys.key(back.?).?);
        }
    }
}

test "glfw key: modifier bits match the backend's view" {
    const mods = c.GLFW_MOD_CONTROL | c.GLFW_MOD_SHIFT | c.GLFW_MOD_ALT | c.GLFW_MOD_SUPER;
    const m = keys.modifiers(mods);
    try testing.expect(m.shift and m.ctrl and m.alt and m.super);
    try testing.expect(!keys.modifiers(c.GLFW_MOD_CAPS_LOCK).hasAny());
}
