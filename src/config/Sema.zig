//! Applies one config file's syntax tree onto a `Config`: looks up each
//! assignment in `keys.table`, parses and stores its value, merges the
//! `[keybinds]` section into the keymap, and records which entry set each key
//! (provenance). Every problem is reported as an `Error`; all of them are
//! warnings, and a key that fails keeps its previous value. No I/O: paths
//! resolve against `keys.Context.dir`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Ast = @import("Ast.zig");
const keys = @import("keys.zig");
const Config = @import("Config.zig");
const keybind = @import("keybind.zig");
const Binding = @import("../input.zig").Binding;
const Face = @import("../freetype/Config.zig").Face;

pub const Error = struct {
    tag: Tag,
    /// Where the problem is reported (see `Tag`).
    token: Ast.TokenIndex,
    /// The section the entry was in; for an unknown key, the suggestion is
    /// searched there.
    section: keys.Section,
    /// The row, when the key is known.
    key: ?keys.KeyIndex = null,

    pub const Tag = enum {
        /// `[name]` that isn't a section; its keys are skipped. Token: the name.
        unknown_section,
        /// A section reserved for a future version (`[terminal]`, `[shell]`,
        /// `[colors]`, `[profile.*]`); its keys are skipped. Token: the name.
        reserved_section,
        /// Token: the key name.
        unknown_key,
        /// A key from a released version that was renamed or removed. Token: the name.
        retired_key,
        /// The key or chord was already set in this file; the last one wins. Token: the name.
        duplicate_key,
        /// `key =` without a value. Token: the name.
        missing_value,
        /// Token: the value.
        invalid_value,
        /// Token: the value.
        value_out_of_range,
        /// The key has no effect on this operating system (F17); it is not
        /// applied. Token: the name.
        not_available,
        /// A `~/` path with no known home directory. Token: the value.
        no_home,
        /// `font.min_size` is above `font.max_size`; both keep their previous
        /// values. Token: the name that was set last of the two.
        conflicting_font_sizes,
        /// `wellbeing.winddown.start` equals `end`, a window that is never
        /// active; both keep their previous values. Token: the name that was
        /// set last of the two.
        conflicting_winddown_times,
        /// Not modifiers plus one key, or an unknown name (`keybind.zig`). Token: the chord.
        invalid_chord,
        /// Not an action name. Token: the action.
        invalid_action,
        /// Key binding syntax reserved for a future version (`none`,
        /// `action:argument`, chord sequences). Token: the value.
        reserved_keybinding,
    };
};

/// What `apply` found, for one file.
pub const Result = struct {
    /// Owned (gpa). Source order.
    errors: []Error,
    /// The name token of the entry that set each key, last one wins; null if
    /// this file didn't set it.
    set_by: [keys.table.len]?Ast.TokenIndex,

    pub fn deinit(result: *Result, gpa: Allocator) void {
        gpa.free(result.errors);
        result.* = undefined;
    }
};

/// Applies `tree` onto `config`. `ctx.arena` owns everything stored in the
/// config (paths, the merged keymap); `gpa` owns the returned errors. On
/// `error.OutOfMemory`, `config` may be partly applied and nothing else is
/// leaked.
pub fn apply(gpa: Allocator, tree: *const Ast, config: *Config, ctx: keys.Context) Allocator.Error!Result {
    var errors: std.ArrayList(Error) = .empty;
    errdefer errors.deinit(gpa);
    var set_by: [keys.table.len]?Ast.TokenIndex = @splat(null);
    var bindings: std.ArrayList(Binding) = .empty;
    var binding_tokens: std.ArrayList(Ast.TokenIndex) = .empty;
    defer binding_tokens.deinit(gpa);
    // `font.fallback` lines, in order; replaces the list if any appeared (F2).
    var fallbacks: std.ArrayList(Face) = .empty;
    defer fallbacks.deinit(gpa);

    const sizes_before = .{ config.font.min_size, config.font.max_size };
    const winddown_before = .{ config.wellbeing.winddown.start, config.wellbeing.winddown.end };

    // null: an unknown or reserved section, whose keys are skipped.
    var section: ?keys.Section = .root;
    for (tree.entries) |entry| {
        const name = tree.tokenSlice(entry.name);
        switch (entry.tag) {
            .section => {
                if (isReservedSection(name)) {
                    try errors.append(gpa, .{ .tag = .reserved_section, .token = entry.name, .section = .root });
                    section = null;
                } else if (sectionFromName(name)) |s| {
                    section = s;
                } else {
                    try errors.append(gpa, .{ .tag = .unknown_section, .token = entry.name, .section = .root });
                    section = null;
                }
            },
            .assignment => {
                const current = section orelse continue;
                if (current == .keybinds) {
                    try applyBinding(gpa, ctx.arena, tree, entry, &errors, &bindings, &binding_tokens);
                    continue;
                }
                if (keys.retiredLookup(current, name) != null) {
                    try errors.append(gpa, .{ .tag = .retired_key, .token = entry.name, .section = current });
                    continue;
                }
                const index = keys.lookup(current, name) orelse {
                    try errors.append(gpa, .{ .tag = .unknown_key, .token = entry.name, .section = current });
                    continue;
                };
                if (!keys.availableHere(index)) {
                    try errors.append(gpa, .{ .tag = .not_available, .token = entry.name, .section = current, .key = index });
                    continue;
                }
                // Repeating a list key is how a list is written.
                if (set_by[index] != null and !keys.isList(index)) {
                    try errors.append(gpa, .{ .tag = .duplicate_key, .token = entry.name, .section = current, .key = index });
                }
                const value = entry.value orelse {
                    try errors.append(gpa, .{ .tag = .missing_value, .token = entry.name, .section = current, .key = index });
                    continue;
                };
                const applied = if (keys.isList(index))
                    applyFallback(gpa, ctx, &fallbacks, tree.tokenSlice(value))
                else
                    keys.apply(config, ctx, index, tree.tokenSlice(value));
                applied catch |err| {
                    const tag: Error.Tag, const token = switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.InvalidValue => .{ .invalid_value, value },
                        error.OutOfRange => .{ .value_out_of_range, value },
                        error.NoHome => .{ .no_home, value },
                    };
                    try errors.append(gpa, .{ .tag = tag, .token = token, .section = current, .key = index });
                    continue;
                };
                set_by[index] = entry.name;
            },
        }
    }

    if (bindings.items.len > 0) config.keymap = try mergeKeymap(ctx.arena, config.keymap, bindings.items);
    const fallback_key = comptime keys.lookup(.font, "fallback").?;
    if (set_by[fallback_key] != null) config.font.faces.fallbacks = try ctx.arena.dupe(Face, fallbacks.items);

    // Only this file's settings are reverted: a conflict it didn't cause
    // (neither size set here) is left to the layer that caused it.
    const min_key = comptime keys.lookup(.font, "min_size").?;
    const max_key = comptime keys.lookup(.font, "max_size").?;
    if (config.font.min_size > config.font.max_size and (set_by[min_key] != null or set_by[max_key] != null)) {
        config.font.min_size, config.font.max_size = sizes_before;
        try revertPair(gpa, &errors, &set_by, min_key, max_key, .conflicting_font_sizes, .font);
    }
    const start_key = comptime keys.lookup(.@"wellbeing.winddown", "start").?;
    const end_key = comptime keys.lookup(.@"wellbeing.winddown", "end").?;
    const winddown = &config.wellbeing.winddown;
    if (std.meta.eql(winddown.start, winddown.end) and (set_by[start_key] != null or set_by[end_key] != null)) {
        winddown.start, winddown.end = winddown_before;
        try revertPair(gpa, &errors, &set_by, start_key, end_key, .conflicting_winddown_times, .@"wellbeing.winddown");
    }

    // Errors were appended in source order except the cross-key checks, which
    // report at a token that may come earlier.
    std.mem.sort(Error, errors.items, {}, struct {
        fn lessThan(_: void, a: Error, b: Error) bool {
            return a.token < b.token;
        }
    }.lessThan);
    return .{ .errors = try errors.toOwnedSlice(gpa), .set_by = set_by };
}

/// Reports a conflict between two keys at the one this file set last, and
/// forgets that this file set either; the caller restores their values.
fn revertPair(
    gpa: Allocator,
    errors: *std.ArrayList(Error),
    set_by: *[keys.table.len]?Ast.TokenIndex,
    a: keys.KeyIndex,
    b: keys.KeyIndex,
    tag: Error.Tag,
    section: keys.Section,
) Allocator.Error!void {
    const last = if ((set_by[a] orelse 0) >= (set_by[b] orelse 0)) a else b;
    try errors.append(gpa, .{ .tag = tag, .token = set_by[last].?, .section = section, .key = last });
    set_by[a] = null;
    set_by[b] = null;
}

/// One `fallback` line onto this file's list.
fn applyFallback(gpa: Allocator, ctx: keys.Context, list: *std.ArrayList(Face), text: []const u8) keys.ApplyError!void {
    switch (try keys.parseFallback(ctx, text)) {
        .none => list.clearRetainingCapacity(),
        .default => {
            list.clearRetainingCapacity();
            try list.appendSlice(gpa, ctx.defaults.font.faces.fallbacks);
        },
        .face => |face| try list.append(gpa, face),
    }
}

fn sectionFromName(name: []const u8) ?keys.Section {
    if (std.mem.eql(u8, name, "root")) return null;
    return std.meta.stringToEnum(keys.Section, name);
}

fn isReservedSection(name: []const u8) bool {
    for ([_][]const u8{ "terminal", "shell", "colors", "profile" }) |reserved| {
        if (std.mem.eql(u8, name, reserved)) return true;
    }
    return std.mem.startsWith(u8, name, "profile.");
}

/// One `chord = action` line of `[keybinds]`. A chord bound twice in the file
/// keeps the last binding.
fn applyBinding(
    gpa: Allocator,
    arena: Allocator,
    tree: *const Ast,
    entry: Ast.Entry,
    errors: *std.ArrayList(Error),
    bindings: *std.ArrayList(Binding),
    binding_tokens: *std.ArrayList(Ast.TokenIndex),
) Allocator.Error!void {
    const chord = tree.tokenSlice(entry.name);
    const value = entry.value orelse {
        return errors.append(gpa, .{ .tag = .missing_value, .token = entry.name, .section = .keybinds });
    };
    const action = tree.tokenSlice(value);
    // Reserved (F14): chord sequences, `none` (unbind) and `action:argument`.
    if (std.mem.indexOfAny(u8, chord, " \t") != null) {
        return errors.append(gpa, .{ .tag = .reserved_keybinding, .token = entry.name, .section = .keybinds });
    }
    if (std.mem.eql(u8, action, "none") or std.mem.indexOfScalar(u8, action, ':') != null) {
        return errors.append(gpa, .{ .tag = .reserved_keybinding, .token = value, .section = .keybinds });
    }
    const binding = keybind.parseBinding(chord, action) catch |err| {
        const tag: Error.Tag, const token = switch (err) {
            error.InvalidChord => .{ .invalid_chord, entry.name },
            error.InvalidAction => .{ .invalid_action, value },
        };
        return errors.append(gpa, .{ .tag = tag, .token = token, .section = .keybinds });
    };
    for (bindings.items, binding_tokens.items) |*existing, *token| {
        if (existing.key == binding.key and std.meta.eql(existing.mods, binding.mods)) {
            try errors.append(gpa, .{ .tag = .duplicate_key, .token = entry.name, .section = .keybinds });
            existing.* = binding;
            token.* = entry.name;
            return;
        }
    }
    try bindings.append(arena, binding);
    try binding_tokens.append(gpa, entry.name);
}

/// `previous` without the chords `layer` binds, then `layer`, in the arena.
fn mergeKeymap(arena: Allocator, previous: []const Binding, layer: []const Binding) Allocator.Error![]const Binding {
    var merged: std.ArrayList(Binding) = try .initCapacity(arena, previous.len + layer.len);
    for (previous) |binding| {
        const rebound = for (layer) |new| {
            if (new.key == binding.key and std.meta.eql(new.mods, binding.mods)) break true;
        } else false;
        if (!rebound) merged.appendAssumeCapacity(binding);
    }
    merged.appendSliceAssumeCapacity(layer);
    return merged.items;
}

/// Writes the message for `err`, without location or newline, like
/// `Ast.renderError`.
pub fn renderError(tree: *const Ast, err: Error, w: *std.Io.Writer) std.Io.Writer.Error!void {
    const text = tree.tokenSlice(err.token);
    switch (err.tag) {
        .unknown_section => try w.print("unknown section '[{s}]'", .{text}),
        .reserved_section => try w.print("section '[{s}]' is reserved for a future version", .{text}),
        .unknown_key => {
            try w.print("unknown key '{s}' in {s}", .{ text, sectionLabel(err.section) });
            if (suggest(err.section, text)) |name| try w.print("; did you mean '{s}'?", .{name});
        },
        .retired_key => switch (keys.retiredLookup(err.section, text).?.fate) {
            .renamed => |new_name| try w.print("'{s}' was renamed to '{s}'", .{ text, new_name }),
            .removed => |reason| try w.print("'{s}' was removed: {s}", .{ text, reason }),
        },
        .duplicate_key => try w.print("'{s}' is set more than once; the last value is used", .{text}),
        .missing_value => {
            if (err.key) |key| {
                try w.print("{s} has no value, expected ", .{keys.qualified_names[key]});
                try keys.writeExpected(key, w);
            } else {
                try w.print("key binding '{s}' has no action", .{text});
            }
        },
        .invalid_value => {
            try w.print("invalid value '{s}' for {s}, expected ", .{ text, keys.qualified_names[err.key.?] });
            try keys.writeExpected(err.key.?, w);
        },
        .value_out_of_range => {
            try w.print("{s} = {s} is out of range, expected ", .{ keys.qualified_names[err.key.?], text });
            try keys.writeExpected(err.key.?, w);
        },
        .not_available => try w.print("{s} is not available on this system", .{keys.qualified_names[err.key.?]}),
        .no_home => try w.print("{s} = {s}: '~/' needs a home directory, and none is known", .{ keys.qualified_names[err.key.?], text }),
        .conflicting_font_sizes => try w.writeAll("font.min_size is above font.max_size; both keep their previous values"),
        .conflicting_winddown_times => try w.writeAll("wellbeing.winddown.start equals end, so wind-down would never start; both keep their previous values"),
        .invalid_chord => try w.print("invalid key chord '{s}': modifiers ctrl, shift, alt, super and one key, like ctrl+shift+w", .{text}),
        .invalid_action => try w.print("unknown action '{s}'", .{text}),
        .reserved_keybinding => try w.print("key binding '{s}' uses syntax reserved for a future version", .{text}),
    }
}

fn sectionLabel(section: keys.Section) []const u8 {
    return switch (section) {
        .root => "the top level",
        inline else => |s| "[" ++ @tagName(s) ++ "]",
    };
}

/// The key in `section` closest to `name` by edit distance, if within 2.
fn suggest(section: keys.Section, name: []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_distance: usize = 3;
    for (keys.table) |key| {
        if (key.section != section) continue;
        const distance = editDistance(name, key.name) orelse continue;
        if (distance < best_distance) {
            best = key.name;
            best_distance = distance;
        }
    }
    return best;
}

/// Levenshtein distance, or null for names longer than 32 bytes (no key is).
fn editDistance(a: []const u8, b: []const u8) ?usize {
    const max = 32;
    if (a.len > max or b.len > max) return null;
    var row: [max + 1]usize = undefined;
    for (0..b.len + 1) |j| row[j] = j;
    for (a, 1..) |ca, i| {
        var diagonal = row[0];
        row[0] = i;
        for (b, 1..) |cb, j| {
            const above = row[j];
            row[j] = @min(@min(row[j] + 1, row[j - 1] + 1), diagonal + @intFromBool(ca != cb));
            diagonal = above;
        }
    }
    return row[b.len];
}
