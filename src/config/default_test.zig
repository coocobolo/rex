const std = @import("std");
const Ast = @import("Ast.zig");
const Sema = @import("Sema.zig");
const keys = @import("keys.zig");
const Config = @import("Config.zig");
const defaults = @import("default.zig");

const gpa = std.testing.allocator;

fn renderAll(tree: *const Ast, result: *const Sema.Result) void {
    var buf: [512]u8 = undefined;
    for (tree.errors) |err| {
        var w: std.Io.Writer = .fixed(&buf);
        tree.renderError(err, &w) catch {};
        std.debug.print("syntax, line {d}: {s}\n", .{ tree.tokenLocation(err.token).line + 1, w.buffered() });
    }
    for (result.errors) |err| {
        var w: std.Io.Writer = .fixed(&buf);
        Sema.renderError(tree, err, &w) catch {};
        std.debug.print("line {d}: {s}\n", .{ tree.tokenLocation(err.token).line + 1, w.buffered() });
    }
}

/// Keys default.conf leaves unset because they have no default yet.
const unset_keys = [_][]const u8{
    // Startup fills an omitted key from share/rex/fonts (#20). `none` in a
    // user file turns that fill off. There is no single path to print here.
    "font.file",
    "font.italic_file",
    "font.emoji_file",
};

fn isUnsetKey(name: []const u8) bool {
    for (unset_keys) |unset| if (std.mem.eql(u8, unset, name)) return true;
    return false;
}

test "default.conf: parses, sets every key once, and changes nothing" {
    var tree = try Ast.parse(gpa, defaults.text);
    defer tree.deinit(gpa);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var config = defaults.default;
    var result = try Sema.apply(gpa, &tree, &config, .{
        .defaults = &defaults.default,
        .arena = arena.allocator(),
        .dir = "/",
        .home = null,
    });
    defer result.deinit(gpa);
    errdefer renderAll(&tree, &result);

    try std.testing.expectEqual(0, tree.errors.len);
    try std.testing.expectEqual(0, result.errors.len);
    for (result.set_by, 0..) |token, i| {
        const unset = isUnsetKey(keys.qualified_names[i]);
        errdefer std.debug.print("default.conf {s} {s}\n", .{ if (unset) "sets" else "does not set", keys.qualified_names[i] });
        try std.testing.expectEqual(unset, token == null);
    }

    // The keymap: the same bindings, in any order.
    const want = defaults.default.keymap;
    try std.testing.expectEqual(want.len, config.keymap.len);
    for (want) |binding| {
        const found = for (config.keymap) |got| {
            if (got.key == binding.key and std.meta.eql(got.mods, binding.mods)) break got;
        } else {
            std.debug.print("default.conf lacks the binding for {t}\n", .{binding.key});
            return error.TestUnexpectedResult;
        };
        try std.testing.expectEqual(binding.action, found.action);
    }
    config.keymap = want;

    try std.testing.expectEqualDeep(defaults.default, config);
}
