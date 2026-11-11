//! Tests for the key encoding in encode.zig.

const std = @import("std");
const testing = std.testing;

const encode = @import("encode.zig");
const Key = @import("key.zig").Key;
const Modifiers = @import("key.zig").Modifiers;

// Modifier bits in the layout of `Modifiers`, so tests can write
// `ctrl | alt`.
const shift: u8 = @bitCast(Modifiers{ .shift = true });
const ctrl: u8 = @bitCast(Modifiers{ .ctrl = true });
const alt: u8 = @bitCast(Modifiers{ .alt = true });
const super: u8 = @bitCast(Modifiers{ .super = true });

fn expectKey(expected: []const u8, key: Key, mods: u8, modes: encode.Modes) !void {
    var buf: [encode.max_len]u8 = undefined;
    try testing.expectEqualStrings(expected, encode.encode(key, @bitCast(mods), modes, &buf));
}

test "encode: ctrl+backtick, ctrl+space and ctrl+2 send NUL" {
    try expectKey("\x00", .grave_accent, ctrl, .{});
    try expectKey("\x00", .space, ctrl, .{});
    try expectKey("\x00", .num_2, ctrl, .{});
    try expectKey("\x1b\x00", .num_2, ctrl | alt, .{});
}

test "encode: ctrl+6 and ctrl+^ send RS" {
    try expectKey("\x1e", .num_6, ctrl, .{});
    try expectKey("\x1e", .num_6, ctrl | shift, .{});
    try expectKey("\x1b\x1e", .num_6, ctrl | alt, .{});
}

test "encode: ctrl+3 to ctrl+8 send ESC, FS, GS, RS, US and DEL" {
    try expectKey("\x1b", .num_3, ctrl, .{});
    try expectKey("\x1c", .num_4, ctrl, .{});
    try expectKey("\x1d", .num_5, ctrl, .{});
    try expectKey("\x1e", .num_6, ctrl, .{});
    try expectKey("\x1f", .num_7, ctrl, .{});
    try expectKey("\x7f", .num_8, ctrl, .{});
}

test "encode: alt puts ESC before a ctrl+digit code" {
    try expectKey("\x1b\x1b", .num_3, ctrl | alt, .{});
    try expectKey("\x1b\x1c", .num_4, ctrl | alt, .{});
    try expectKey("\x1b\x1d", .num_5, ctrl | alt, .{});
    try expectKey("\x1b\x1f", .num_7, ctrl | alt, .{});
    try expectKey("\x1b\x7f", .num_8, ctrl | alt, .{});
}

test "encode: other digits are left to the char callback" {
    try expectKey("", .num_2, 0, .{});
    try expectKey("", .num_0, ctrl, .{});
    try expectKey("", .num_1, ctrl, .{});
    try expectKey("", .num_9, ctrl, .{});
    try expectKey("\x1b5", .num_5, alt, .{});
}

const KeyCase = struct { level: encode.ModifyOtherKeys, key: Key, mods: u8, expected: []const u8 };

fn expectKeyCases(cases: []const KeyCase) !void {
    for (cases) |k| {
        var buf: [encode.max_len]u8 = undefined;
        const got = encode.encode(k.key, @bitCast(k.mods), .{ .modify_other_keys = k.level }, &buf);
        testing.expectEqualStrings(k.expected, got) catch |err| {
            std.debug.print("level {t}, key {t}, mods {d}\n", .{ k.level, k.key, k.mods });
            return err;
        };
    }
}

// Expected bytes worked out by hand from xterm 412 `input.c`
// (ModifyOtherKeys, allowedCharModifiers) with its default resources.

test "encode: modifyOtherKeys 1 leaves keys whose byte already carries the modifier" {
    try expectKeyCases(&.{
        .{ .level = .partial, .key = .num_2, .mods = ctrl, .expected = "\x00" }, // Ctrl+2 is NUL in X
        .{ .level = .partial, .key = .num_6, .mods = ctrl, .expected = "\x1e" },
        .{ .level = .partial, .key = .a, .mods = ctrl, .expected = "\x01" },
        .{ .level = .partial, .key = .a, .mods = ctrl | shift, .expected = "\x01" },
        .{ .level = .partial, .key = .space, .mods = ctrl, .expected = "\x00" },
        .{ .level = .partial, .key = .escape, .mods = ctrl, .expected = "\x1b" },
        .{ .level = .partial, .key = .backspace, .mods = ctrl, .expected = "\x08" },
        .{ .level = .partial, .key = .backspace, .mods = shift, .expected = "\x7f" },
        .{ .level = .partial, .key = .tab, .mods = shift, .expected = "\x1b[Z" },
        .{ .level = .partial, .key = .a, .mods = shift, .expected = "" }, // char callback
        // A bare Alt is not a modifier for it.
        .{ .level = .partial, .key = .a, .mods = alt, .expected = "\x1ba" },
        .{ .level = .partial, .key = .num_3, .mods = alt, .expected = "\x1b3" },
        .{ .level = .partial, .key = .enter, .mods = alt, .expected = "\x1b\r" },
    });
}

test "encode: modifyOtherKeys 1 encodes the other modified keys" {
    try expectKeyCases(&.{
        .{ .level = .partial, .key = .num_1, .mods = ctrl, .expected = "\x1b[27;5;49~" },
        .{ .level = .partial, .key = .num_3, .mods = ctrl | alt, .expected = "\x1b[27;7;51~" },
        .{ .level = .partial, .key = .a, .mods = ctrl | alt, .expected = "\x1b[27;7;97~" },
        .{ .level = .partial, .key = .enter, .mods = ctrl, .expected = "\x1b[27;5;13~" },
        .{ .level = .partial, .key = .enter, .mods = shift, .expected = "\x1b[27;2;13~" },
        .{ .level = .partial, .key = .tab, .mods = ctrl, .expected = "\x1b[27;5;9~" },
        .{ .level = .partial, .key = .escape, .mods = ctrl | alt, .expected = "\x1b[27;7;27~" },
    });
}

test "encode: modifyOtherKeys 2 encodes every modified ordinary key" {
    try expectKeyCases(&.{
        .{ .level = .full, .key = .a, .mods = ctrl, .expected = "\x1b[27;5;97~" },
        .{ .level = .full, .key = .a, .mods = shift, .expected = "\x1b[27;2;65~" },
        .{ .level = .full, .key = .a, .mods = alt, .expected = "\x1b[27;3;97~" },
        .{ .level = .full, .key = .a, .mods = ctrl | shift, .expected = "\x1b[27;6;65~" },
        .{ .level = .full, .key = .left_bracket, .mods = ctrl, .expected = "\x1b[27;5;91~" },
        .{ .level = .full, .key = .minus, .mods = ctrl, .expected = "\x1b[27;5;45~" },
        .{ .level = .full, .key = .num_3, .mods = ctrl | shift, .expected = "\x1b[27;6;35~" }, // '#'
        .{ .level = .full, .key = .num_8, .mods = ctrl, .expected = "\x1b[27;5;56~" },
        .{ .level = .full, .key = .space, .mods = ctrl, .expected = "\x1b[27;5;32~" },
        .{ .level = .full, .key = .space, .mods = shift, .expected = "\x1b[27;2;32~" },
        .{ .level = .full, .key = .enter, .mods = ctrl, .expected = "\x1b[27;5;13~" },
        .{ .level = .full, .key = .tab, .mods = ctrl, .expected = "\x1b[27;5;9~" },
        .{ .level = .full, .key = .tab, .mods = ctrl | shift, .expected = "\x1b[27;6;9~" },
        .{ .level = .full, .key = .escape, .mods = ctrl, .expected = "\x1b[27;5;27~" },
        // Backspace: DEL (127) unless Ctrl turns it into BS (8).
        .{ .level = .full, .key = .backspace, .mods = shift, .expected = "\x1b[27;2;127~" },
        .{ .level = .full, .key = .backspace, .mods = alt, .expected = "\x1b[27;3;127~" },
        .{ .level = .full, .key = .backspace, .mods = ctrl | shift, .expected = "\x1b[27;6;8~" },
        .{ .level = .full, .key = .backspace, .mods = ctrl | alt, .expected = "\x1b[27;7;8~" },
    });
}

test "encode: modifyOtherKeys 2 leaves the keys xterm leaves" {
    try expectKeyCases(&.{
        .{ .level = .full, .key = .a, .mods = 0, .expected = "" },
        .{ .level = .full, .key = .num_1, .mods = shift, .expected = "" }, // '!' is not control input
        .{ .level = .full, .key = .backspace, .mods = ctrl, .expected = "\x08" },
        .{ .level = .full, .key = .tab, .mods = shift, .expected = "\x1b[Z" },
        .{ .level = .full, .key = .kp_enter, .mods = ctrl, .expected = "\r" }, // keypad key
        .{ .level = .full, .key = .f1, .mods = ctrl, .expected = "\x1b[1;5P" }, // function key
        .{ .level = .full, .key = .up, .mods = ctrl, .expected = "\x1b[1;5A" },
        .{ .level = .full, .key = .a, .mods = super, .expected = "" },
    });
}

test "encode: modifyOtherKeys 0 keeps the usual bytes" {
    try expectKeyCases(&.{
        .{ .level = .off, .key = .a, .mods = ctrl, .expected = "\x01" },
        .{ .level = .off, .key = .a, .mods = shift, .expected = "" },
        .{ .level = .off, .key = .a, .mods = alt, .expected = "\x1ba" },
        .{ .level = .off, .key = .a, .mods = ctrl | alt, .expected = "\x1b\x01" },
        .{ .level = .off, .key = .num_1, .mods = ctrl, .expected = "" },
        .{ .level = .off, .key = .enter, .mods = ctrl, .expected = "\r" },
        .{ .level = .off, .key = .tab, .mods = ctrl, .expected = "\t" },
        .{ .level = .off, .key = .backspace, .mods = ctrl, .expected = "\x08" },
        .{ .level = .off, .key = .backspace, .mods = shift, .expected = "\x7f" },
        .{ .level = .off, .key = .space, .mods = ctrl, .expected = "\x00" },
        .{ .level = .off, .key = .escape, .mods = ctrl, .expected = "\x1b" },
        .{ .level = .off, .key = .left_bracket, .mods = ctrl, .expected = "\x1b" },
    });
}

test "encode: 8-bit controls send CSI and SS3 as one byte, and leave ESC prefixes alone" {
    const eight: encode.Modes = .{ .eight_bit_controls = true };
    try expectKey("\x9bA", .up, 0, eight);
    try expectKey("\x9b1;5A", .up, ctrl, eight);
    try expectKey("\x8fA", .up, 0, .{ .eight_bit_controls = true, .cursor_keys = true });
    try expectKey("\x8fP", .f1, 0, eight);
    try expectKey("\x9b1;2P", .f1, shift, eight);
    try expectKey("\x9b15~", .f5, 0, eight);
    try expectKey("\x9b3;3~", .delete, alt, eight);
    try expectKey("\x9bZ", .tab, shift, eight);
    try expectKey("\x8fp", .kp_0, 0, .{ .eight_bit_controls = true, .keypad_app = true });
    try expectKey("\x9b27;5;97~", .a, ctrl, .{ .eight_bit_controls = true, .modify_other_keys = .full });
    // Alt's ESC is a prefix, not CSI or SS3, even before `[` and `O`.
    try expectKey("\x1b[", .left_bracket, alt, eight);
    try expectKey("\x1bO", .o, alt | shift, eight);
    try expectKey("\x1b\r", .enter, alt, eight);
    try expectKey("\x1b", .escape, 0, eight);
}

test "encode: 7-bit controls for the same keys" {
    try expectKey("\x1b[A", .up, 0, .{});
    try expectKey("\x1bOA", .up, 0, .{ .cursor_keys = true });
    try expectKey("\x1bOP", .f1, 0, .{});
    try expectKey("\x1b[15~", .f5, 0, .{});
    try expectKey("\x1b[3;3~", .delete, alt, .{});
    try expectKey("\x1b[Z", .tab, shift, .{});
    try expectKey("\x1bOp", .kp_0, 0, .{ .keypad_app = true });
}

test "encode: Home and End follow DECCKM like the arrows, as in xterm" {
    try expectKey("\x1b[H", .home, 0, .{});
    try expectKey("\x1b[F", .end, 0, .{});
    try expectKey("\x1bOH", .home, 0, .{ .cursor_keys = true });
    try expectKey("\x1bOF", .end, 0, .{ .cursor_keys = true });
    // With a modifier they stay CSI.
    try expectKey("\x1b[1;2H", .home, shift, .{ .cursor_keys = true });
    try expectKey("\x1b[1;5F", .end, ctrl, .{ .cursor_keys = true });
    try expectKey("\x8fH", .home, 0, .{ .cursor_keys = true, .eight_bit_controls = true });
}

test "encode: keypad Enter sends SS3 M in keypad application mode" {
    const app: encode.Modes = .{ .keypad_app = true };
    try expectKey("\x1bOM", .kp_enter, 0, app);
    try expectKey("\x1bO5M", .kp_enter, ctrl, app);
    try expectKey("\x1bO2M", .kp_enter, shift, app);
    try expectKey("\x1bO3M", .kp_enter, alt, app);
    try expectKey("\x8fM", .kp_enter, 0, .{ .keypad_app = true, .eight_bit_controls = true });
    // The main Enter key is not a keypad key.
    try expectKey("\r", .enter, 0, app);
    // Numeric mode is unchanged.
    try expectKey("\r", .kp_enter, 0, .{});
    try expectKey("\r", .kp_enter, ctrl, .{});
}
