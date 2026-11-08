const std = @import("std");
const Ast = @import("Ast.zig");
const Sema = @import("Sema.zig");
const diagnostics = @import("diagnostics.zig");
const test_config = @import("test_fixtures.zig").test_config;

const gpa = std.testing.allocator;

/// Parses and applies `text` onto the test config.
fn parse(text: []const u8) !diagnostics.File {
    const source = try gpa.dupe(u8, text);
    errdefer gpa.free(source);
    var tree = try Ast.parse(gpa, source);
    errdefer tree.deinit(gpa);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var config = test_config;
    const sema = try Sema.apply(gpa, &tree, &config, .{
        .defaults = &test_config,
        .arena = arena.allocator(),
        .dir = "/etc/rex",
        .home = null,
    });
    return .{ .source = source, .tree = tree, .sema = sema };
}

/// Every diagnostic of `text`, formatted, one after the other.
fn expectFormatted(text: []const u8, options: diagnostics.FormatOptions, expected: []const u8) !void {
    var file = try parse(text);
    defer file.deinit(gpa);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var it = file.iterator();
    while (it.next()) |d| try diagnostics.format(&file, "rex.conf", d, &out.writer, options);
    try std.testing.expectEqualStrings(expected, out.written());
}

test "format: 1-based line and column, severity, message" {
    try expectFormatted(
        \\[font
        \\[font]
        \\nope = 1
        \\
    , .{},
        \\rex.conf:1:1: error: unclosed section header, expected ']'
        \\rex.conf:3:1: warning: unknown key 'nope' in [font]
        \\
    );
}

test "format: lines end at CRLF and lone CR" {
    try expectFormatted("[font]\r\nsize = 1\rnope = 2\r\n", .{ .source_line = true },
        \\rex.conf:3:1: warning: unknown key 'nope' in [font]
        \\nope = 2
        \\^
        \\
    );
}

test "format: the caret copies tabs" {
    try expectFormatted("[toast]\n\tenabled =\tbig\n", .{ .source_line = true }, "" ++
        "rex.conf:2:12: warning: invalid value 'big' for toast.enabled, expected true or false\n" ++
        "\tenabled =\tbig\n" ++
        "\t         \t^\n");
}

test "format: the caret counts code points, the column bytes" {
    // 'é' is two bytes: the error is at byte column 5, the caret 4 places in.
    try expectFormatted("[é] x\n", .{ .source_line = true }, "" ++
        "rex.conf:1:2: warning: unknown section '[é]'\n" ++
        "[é] x\n" ++
        " ^\n" ++
        "rex.conf:1:6: error: unexpected text after section header\n" ++
        "[é] x\n" ++
        "    ^\n");
}

test "iterator: syntax and Sema diagnostics merged in source order" {
    var file = try parse(
        \\nope = 1
        \\[font
        \\[font]
        \\size = big
        \\= x
        \\
    );
    defer file.deinit(gpa);
    const Expected = struct { diagnostics.Severity, []const u8 };
    const expected = [_]Expected{
        .{ .warn, "unknown_key" },
        .{ .err, "unclosed_section" },
        .{ .warn, "invalid_value" },
        .{ .err, "missing_name" },
    };
    var it = file.iterator();
    for (expected) |e| {
        const d = it.next() orelse return error.TestExpectedMore;
        try std.testing.expectEqual(e[0], d.severity());
        const tag = switch (d) {
            inline else => |err| @tagName(err.tag),
        };
        try std.testing.expectEqualStrings(e[1], tag);
    }
    try std.testing.expectEqual(null, it.next());
}

test "iterator: a file without problems yields nothing" {
    var file = try parse("[font]\nsize = 12\n");
    defer file.deinit(gpa);
    var it = file.iterator();
    try std.testing.expectEqual(null, it.next());
}
