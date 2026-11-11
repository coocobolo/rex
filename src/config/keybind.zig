//! Key bindings as users write them in `[keybinds]`: `chord = action`, with
//! exactly one spelling for each modifier, key and action (rebuild plan C4).
//!
//! A chord is modifiers and one key joined by `+`, for example `ctrl+shift+w`.
//! Modifiers are `ctrl`, `shift`, `alt` and `super`, each at most once, in any
//! order. Keys are `a`–`z`, `0`–`9` and the other `input.Key` tag names
//! (`f1`–`f12`, `enter`, `page_up`, `minus`, `kp_add`, …); the modifier keys
//! themselves can't be a chord's key. Actions are `input.Action` tag names;
//! `send_to_pty` takes an argument and is reserved (F14).

const std = @import("std");
const Key = @import("../input/key.zig").Key;
const Modifiers = @import("../input/key.zig").Modifiers;
const Action = @import("../input/binding.zig").Action;
const Binding = @import("../input/binding.zig").Binding;

pub const Error = error{
    /// Not modifiers plus exactly one key, or an unknown or repeated name.
    InvalidChord,
    /// Not the name of an action without an argument.
    InvalidAction,
};

pub const Chord = struct { key: Key, mods: Modifiers };

/// The bindable keys by name: every `Key` tag except the modifier keys, with
/// `num_N` written as the digit `N`.
const key_names = blk: {
    const fields = @typeInfo(Key).@"enum".fields;
    var kvs: [fields.len]struct { []const u8, Key } = undefined;
    var n: usize = 0;
    for (fields) |field| {
        const key: Key = @enumFromInt(field.value);
        if (key.isModifier()) continue;
        const name = if (std.mem.startsWith(u8, field.name, "num_")) field.name["num_".len..] else field.name;
        kvs[n] = .{ name, key };
        n += 1;
    }
    break :blk std.StaticStringMap(Key).initComptime(kvs[0..n]);
};

/// The actions by name: every `Action` tag without a payload.
const action_names = blk: {
    const fields = @typeInfo(Action).@"union".fields;
    var kvs: [fields.len]struct { []const u8, Action } = undefined;
    var n: usize = 0;
    for (fields) |field| {
        if (field.type != void) continue;
        kvs[n] = .{ field.name, @unionInit(Action, field.name, {}) };
        n += 1;
    }
    break :blk std.StaticStringMap(Action).initComptime(kvs[0..n]);
};

pub fn parseChord(text: []const u8) Error!Chord {
    var mods: Modifiers = .{};
    var key: ?Key = null;
    var parts = std.mem.splitScalar(u8, text, '+');
    while (parts.next()) |part| {
        if (std.meta.stringToEnum(Modifier, part)) |modifier| {
            // Modifiers is packed, so its flags are set by name, not by pointer.
            switch (modifier) {
                inline else => |tag| {
                    if (@field(mods, @tagName(tag))) return error.InvalidChord;
                    @field(mods, @tagName(tag)) = true;
                },
            }
            continue;
        }
        if (key != null) return error.InvalidChord;
        key = key_names.get(part) orelse return error.InvalidChord;
    }
    return .{ .key = key orelse return error.InvalidChord, .mods = mods };
}

/// The modifier names, each a `Modifiers` field.
const Modifier = enum { ctrl, shift, alt, super };

pub fn parseAction(text: []const u8) Error!Action {
    return action_names.get(text) orelse error.InvalidAction;
}

pub fn parseBinding(chord: []const u8, action: []const u8) Error!Binding {
    const parsed = try parseChord(chord);
    return .{ .key = parsed.key, .mods = parsed.mods, .action = try parseAction(action) };
}
