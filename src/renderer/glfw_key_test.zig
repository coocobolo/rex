const std = @import("std");
const testing = std.testing;

const c = @import("glfw");

const glfw_key = @import("glfw_key.zig");
const Key = @import("../input/key.zig").Key;

test "glfw_key: key codes map to Rex keys, unknown ones to null" {
    try testing.expectEqual(Key.escape, glfw_key.key(c.GLFW_KEY_ESCAPE).?);
    try testing.expectEqual(Key.enter, glfw_key.key(c.GLFW_KEY_ENTER).?);
    try testing.expectEqual(Key.tab, glfw_key.key(c.GLFW_KEY_TAB).?);
    try testing.expectEqual(Key.a, glfw_key.key(c.GLFW_KEY_A).?);
    try testing.expectEqual(Key.q, glfw_key.key(c.GLFW_KEY_Q).?);
    try testing.expectEqual(Key.num_0, glfw_key.key(c.GLFW_KEY_0).?);
    try testing.expectEqual(null, glfw_key.key(c.GLFW_KEY_UNKNOWN));
}

test "glfw_key: every Key has exactly one GLFW key code" {
    var seen: std.EnumSet(Key) = .initEmpty();
    var code: c_int = 0;
    while (code <= c.GLFW_KEY_LAST) : (code += 1) {
        const k = glfw_key.key(code) orelse continue;
        try testing.expect(!seen.contains(k));
        seen.insert(k);
    }
    try testing.expectEqual(@typeInfo(Key).@"enum".fields.len, seen.count());
}

test "glfw_key: the eight GLFW modifier keys are the modifier Keys" {
    var code: c_int = 0;
    while (code <= c.GLFW_KEY_LAST) : (code += 1) {
        const is_glfw_modifier = code >= c.GLFW_KEY_LEFT_SHIFT and code <= c.GLFW_KEY_RIGHT_SUPER;
        const k = glfw_key.key(code) orelse {
            try testing.expect(!is_glfw_modifier);
            continue;
        };
        try testing.expectEqual(is_glfw_modifier, k.isModifier());
    }
}

test "glfw_key: modifier bits" {
    const mods = glfw_key.modifiers(c.GLFW_MOD_CONTROL | c.GLFW_MOD_SHIFT);
    try testing.expect(mods.ctrl and mods.shift and !mods.alt and !mods.super);
    try testing.expect(mods.hasAny());
    try testing.expect(glfw_key.modifiers(c.GLFW_MOD_SUPER).super);
    try testing.expect(!glfw_key.modifiers(c.GLFW_MOD_CAPS_LOCK).hasAny());
}
