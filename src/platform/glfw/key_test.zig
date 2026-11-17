const std = @import("std");
const testing = std.testing;

const c = @import("glfw");
const newer = @import("key.zig");
const old = @import("../../renderer/glfw_key.zig");

test "glfw key: the new translator matches the old one byte for byte" {
    var candidate: usize = 0;
    while (candidate < 512) : (candidate += 1) {
        const code: c_int = @intCast(candidate);
        try testing.expectEqual(old.key(code), newer.key(code));
        try testing.expectEqual(old.modifiers(code), newer.modifiers(code));
    }
}

test "glfw key: every mapped key has a reverse code" {
    var candidate: usize = 0;
    while (candidate < 512) : (candidate += 1) {
        const code: c_int = @intCast(candidate);
        if (newer.key(code)) |mapped| {
            const back = newer.toGlfw(mapped);
            try testing.expect(back != null);
            try testing.expectEqual(mapped, newer.key(back.?).?);
        }
    }
}

test "glfw key: modifier bits match the backend's view" {
    const mods = c.GLFW_MOD_CONTROL | c.GLFW_MOD_SHIFT | c.GLFW_MOD_ALT | c.GLFW_MOD_SUPER;
    const m = newer.modifiers(mods);
    try testing.expect(m.shift and m.ctrl and m.alt and m.super);
    try testing.expect(!newer.modifiers(c.GLFW_MOD_CAPS_LOCK).hasAny());
}
