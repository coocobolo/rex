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

const KeyCase = struct { level: u2, key: c_int, mods: c_int, expected: []const u8 };

fn expectKeyCases(cases: []const KeyCase) !void {
    for (cases) |k| {
        var buf: [32]u8 = undefined;
        const got = input.encodeKey(k.key, k.mods, .{ .modify_other_keys = k.level }, &buf);
        testing.expectEqualStrings(k.expected, got) catch |err| {
            std.debug.print("level {d}, key {d}, mods {d}\n", .{ k.level, k.key, k.mods });
            return err;
        };
    }
}

// Expected bytes worked out by hand from xterm 412 `input.c`
// (ModifyOtherKeys, allowedCharModifiers) with its default resources.

test "encodeKey: modifyOtherKeys 1 leaves keys whose byte already carries the modifier" {
    try expectKeyCases(&.{
        .{ .level = 1, .key = c.GLFW_KEY_2, .mods = ctrl, .expected = "\x00" }, // Ctrl+2 is NUL in X
        .{ .level = 1, .key = c.GLFW_KEY_6, .mods = ctrl, .expected = "\x1e" },
        .{ .level = 1, .key = c.GLFW_KEY_A, .mods = ctrl, .expected = "\x01" },
        .{ .level = 1, .key = c.GLFW_KEY_A, .mods = ctrl | shift, .expected = "\x01" },
        .{ .level = 1, .key = c.GLFW_KEY_SPACE, .mods = ctrl, .expected = "\x00" },
        .{ .level = 1, .key = c.GLFW_KEY_ESCAPE, .mods = ctrl, .expected = "\x1b" },
        .{ .level = 1, .key = c.GLFW_KEY_BACKSPACE, .mods = ctrl, .expected = "\x08" },
        .{ .level = 1, .key = c.GLFW_KEY_BACKSPACE, .mods = shift, .expected = "\x7f" },
        .{ .level = 1, .key = c.GLFW_KEY_TAB, .mods = shift, .expected = "\x1b[Z" },
        .{ .level = 1, .key = c.GLFW_KEY_A, .mods = shift, .expected = "" }, // char callback
        // A bare Alt is not a modifier for it.
        .{ .level = 1, .key = c.GLFW_KEY_A, .mods = alt, .expected = "\x1ba" },
        .{ .level = 1, .key = c.GLFW_KEY_3, .mods = alt, .expected = "\x1b3" },
        .{ .level = 1, .key = c.GLFW_KEY_ENTER, .mods = alt, .expected = "\x1b\r" },
    });
}

test "encodeKey: modifyOtherKeys 1 encodes the other modified keys" {
    try expectKeyCases(&.{
        .{ .level = 1, .key = c.GLFW_KEY_1, .mods = ctrl, .expected = "\x1b[27;5;49~" },
        .{ .level = 1, .key = c.GLFW_KEY_3, .mods = ctrl | alt, .expected = "\x1b[27;7;51~" },
        .{ .level = 1, .key = c.GLFW_KEY_A, .mods = ctrl | alt, .expected = "\x1b[27;7;97~" },
        .{ .level = 1, .key = c.GLFW_KEY_ENTER, .mods = ctrl, .expected = "\x1b[27;5;13~" },
        .{ .level = 1, .key = c.GLFW_KEY_ENTER, .mods = shift, .expected = "\x1b[27;2;13~" },
        .{ .level = 1, .key = c.GLFW_KEY_TAB, .mods = ctrl, .expected = "\x1b[27;5;9~" },
        .{ .level = 1, .key = c.GLFW_KEY_ESCAPE, .mods = ctrl | alt, .expected = "\x1b[27;7;27~" },
    });
}

test "encodeKey: modifyOtherKeys 2 encodes every modified ordinary key" {
    try expectKeyCases(&.{
        .{ .level = 2, .key = c.GLFW_KEY_A, .mods = ctrl, .expected = "\x1b[27;5;97~" },
        .{ .level = 2, .key = c.GLFW_KEY_A, .mods = shift, .expected = "\x1b[27;2;65~" },
        .{ .level = 2, .key = c.GLFW_KEY_A, .mods = alt, .expected = "\x1b[27;3;97~" },
        .{ .level = 2, .key = c.GLFW_KEY_A, .mods = ctrl | shift, .expected = "\x1b[27;6;65~" },
        .{ .level = 2, .key = c.GLFW_KEY_LEFT_BRACKET, .mods = ctrl, .expected = "\x1b[27;5;91~" },
        .{ .level = 2, .key = c.GLFW_KEY_MINUS, .mods = ctrl, .expected = "\x1b[27;5;45~" },
        .{ .level = 2, .key = c.GLFW_KEY_3, .mods = ctrl | shift, .expected = "\x1b[27;6;35~" }, // '#'
        .{ .level = 2, .key = c.GLFW_KEY_8, .mods = ctrl, .expected = "\x1b[27;5;56~" },
        .{ .level = 2, .key = c.GLFW_KEY_SPACE, .mods = ctrl, .expected = "\x1b[27;5;32~" },
        .{ .level = 2, .key = c.GLFW_KEY_SPACE, .mods = shift, .expected = "\x1b[27;2;32~" },
        .{ .level = 2, .key = c.GLFW_KEY_ENTER, .mods = ctrl, .expected = "\x1b[27;5;13~" },
        .{ .level = 2, .key = c.GLFW_KEY_TAB, .mods = ctrl, .expected = "\x1b[27;5;9~" },
        .{ .level = 2, .key = c.GLFW_KEY_TAB, .mods = ctrl | shift, .expected = "\x1b[27;6;9~" },
        .{ .level = 2, .key = c.GLFW_KEY_ESCAPE, .mods = ctrl, .expected = "\x1b[27;5;27~" },
        // Backspace: DEL (127) unless Ctrl turns it into BS (8).
        .{ .level = 2, .key = c.GLFW_KEY_BACKSPACE, .mods = shift, .expected = "\x1b[27;2;127~" },
        .{ .level = 2, .key = c.GLFW_KEY_BACKSPACE, .mods = alt, .expected = "\x1b[27;3;127~" },
        .{ .level = 2, .key = c.GLFW_KEY_BACKSPACE, .mods = ctrl | shift, .expected = "\x1b[27;6;8~" },
        .{ .level = 2, .key = c.GLFW_KEY_BACKSPACE, .mods = ctrl | alt, .expected = "\x1b[27;7;8~" },
    });
}

test "encodeKey: modifyOtherKeys 2 leaves the keys xterm leaves" {
    try expectKeyCases(&.{
        .{ .level = 2, .key = c.GLFW_KEY_A, .mods = 0, .expected = "" },
        .{ .level = 2, .key = c.GLFW_KEY_1, .mods = shift, .expected = "" }, // '!' is not control input
        .{ .level = 2, .key = c.GLFW_KEY_BACKSPACE, .mods = ctrl, .expected = "\x08" },
        .{ .level = 2, .key = c.GLFW_KEY_TAB, .mods = shift, .expected = "\x1b[Z" },
        .{ .level = 2, .key = c.GLFW_KEY_KP_ENTER, .mods = ctrl, .expected = "\r" }, // keypad key
        .{ .level = 2, .key = c.GLFW_KEY_F1, .mods = ctrl, .expected = "\x1b[1;5P" }, // function key
        .{ .level = 2, .key = c.GLFW_KEY_UP, .mods = ctrl, .expected = "\x1b[1;5A" },
        .{ .level = 2, .key = c.GLFW_KEY_A, .mods = c.GLFW_MOD_SUPER, .expected = "" },
    });
}

test "encodeKey: modifyOtherKeys 0 keeps the usual bytes" {
    try expectKeyCases(&.{
        .{ .level = 0, .key = c.GLFW_KEY_A, .mods = ctrl, .expected = "\x01" },
        .{ .level = 0, .key = c.GLFW_KEY_A, .mods = shift, .expected = "" },
        .{ .level = 0, .key = c.GLFW_KEY_A, .mods = alt, .expected = "\x1ba" },
        .{ .level = 0, .key = c.GLFW_KEY_A, .mods = ctrl | alt, .expected = "\x1b\x01" },
        .{ .level = 0, .key = c.GLFW_KEY_1, .mods = ctrl, .expected = "" },
        .{ .level = 0, .key = c.GLFW_KEY_ENTER, .mods = ctrl, .expected = "\r" },
        .{ .level = 0, .key = c.GLFW_KEY_TAB, .mods = ctrl, .expected = "\t" },
        .{ .level = 0, .key = c.GLFW_KEY_BACKSPACE, .mods = ctrl, .expected = "\x08" },
        .{ .level = 0, .key = c.GLFW_KEY_BACKSPACE, .mods = shift, .expected = "\x7f" },
        .{ .level = 0, .key = c.GLFW_KEY_SPACE, .mods = ctrl, .expected = "\x00" },
        .{ .level = 0, .key = c.GLFW_KEY_ESCAPE, .mods = ctrl, .expected = "\x1b" },
        .{ .level = 0, .key = c.GLFW_KEY_LEFT_BRACKET, .mods = ctrl, .expected = "\x1b" },
    });
}

test "canonical Key and Modifiers: GLFW round-trip and binding matching" {
    // Round-trip Key conversions
    try testing.expectEqual(input.Key.escape, input.Key.fromGlfw(c.GLFW_KEY_ESCAPE).?);
    try testing.expectEqual(input.Key.enter, input.Key.fromGlfw(c.GLFW_KEY_ENTER).?);
    try testing.expectEqual(input.Key.tab, input.Key.fromGlfw(c.GLFW_KEY_TAB).?);
    try testing.expectEqual(input.Key.a, input.Key.fromGlfw(c.GLFW_KEY_A).?);
    try testing.expectEqual(input.Key.q, input.Key.fromGlfw(c.GLFW_KEY_Q).?);
    try testing.expectEqual(input.Key.num_0, input.Key.fromGlfw(c.GLFW_KEY_0).?);
    try testing.expectEqual(@as(c_int, c.GLFW_KEY_Q), input.Key.q.toGlfw());

    // Modifier packing and detection
    const mods = input.Modifiers.fromGlfw(c.GLFW_MOD_CONTROL | c.GLFW_MOD_SHIFT);
    try testing.expect(mods.ctrl);
    try testing.expect(mods.shift);
    try testing.expect(!mods.alt);
    try testing.expect(!mods.super);
    try testing.expect(mods.hasAny());
    try testing.expectEqual(@as(c_int, c.GLFW_MOD_CONTROL | c.GLFW_MOD_SHIFT), mods.toGlfw());

    // Canonical key binding lookup
    const bindings: []const input.Binding = &.{
        .{ .key = .q, .mods = .{ .ctrl = true, .shift = true }, .action = .quit },
        .{ .key = .c, .mods = .{ .ctrl = true, .shift = true }, .action = .copy_selection },
    };

    try testing.expectEqual(input.Action.quit, input.matchBinding(bindings, .q, mods).?);
    try testing.expectEqual(input.Action.copy_selection, input.matchBinding(bindings, .c, mods).?);
    try testing.expectEqual(@as(?input.Action, null), input.matchBinding(bindings, .q, .{}));

    // Glfw bridge matching
    try testing.expectEqual(input.Action.quit, input.matchGlfwBinding(bindings, c.GLFW_KEY_Q, c.GLFW_MOD_CONTROL | c.GLFW_MOD_SHIFT).?);
    try testing.expectEqual(@as(?input.Action, null), input.matchGlfwBinding(bindings, c.GLFW_KEY_Q, 0));
}
