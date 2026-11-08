const std = @import("std");
const Ast = @import("Ast.zig");

const gpa = std.testing.allocator;

const ExpectedEntry = struct { Ast.Entry.Tag, []const u8, ?[]const u8 };
const ExpectedError = struct { Ast.Error.Tag, usize, usize };

/// Checks that `source` parses to exactly `expected` entries: tag, name text and
/// value text (null for sections and `key =`).
fn expectEntries(source: []const u8, expected: []const ExpectedEntry) !void {
    var tree = try Ast.parse(gpa, source);
    defer tree.deinit(gpa);
    errdefer std.debug.print("source:\n{s}\n", .{source});
    for (expected, 0..) |e, i| {
        errdefer std.debug.print("entry {d}\n", .{i});
        if (i >= tree.entries.len) return error.TestExpectedEqual;
        const entry = tree.entries[i];
        try std.testing.expectEqual(e[0], entry.tag);
        try std.testing.expectEqualStrings(e[1], tree.tokenSlice(entry.name));
        if (e[2]) |value| {
            try std.testing.expect(entry.value != null);
            try std.testing.expectEqualStrings(value, tree.tokenSlice(entry.value.?));
        } else {
            try std.testing.expectEqual(null, entry.value);
        }
    }
    try std.testing.expectEqual(expected.len, tree.entries.len);
}

/// Checks that `source` produces exactly `expected` errors: tag and 0-based
/// (line, column) of the error's token.
fn expectErrors(source: []const u8, expected: []const ExpectedError) !void {
    var tree = try Ast.parse(gpa, source);
    defer tree.deinit(gpa);
    errdefer std.debug.print("source:\n{s}\n", .{source});
    for (expected, 0..) |e, i| {
        errdefer std.debug.print("error {d}\n", .{i});
        if (i >= tree.errors.len) return error.TestExpectedEqual;
        const err = tree.errors[i];
        try std.testing.expectEqual(e[0], err.tag);
        const location = tree.tokenLocation(err.token);
        try std.testing.expectEqual(e[1], location.line);
        try std.testing.expectEqual(e[2], location.column);
    }
    try std.testing.expectEqual(expected.len, tree.errors.len);
}

test "parse: port of the old lexer test" {
    const sample =
        \\# Global config
        \\theme = graphite
        \\font-size = 14.5 # size in points
        \\
        \\[card]
        \\corner-radius = 10.0
        \\border-shape = sharp
        \\
        \\[keybinds]
        \\ctrl+shift+w = wellbeing_dashboard
        \\ctrl+shift+r = reload_config
    ;
    try expectEntries(sample, &.{
        .{ .assignment, "theme", "graphite" },
        .{ .assignment, "font-size", "14.5" },
        .{ .section, "card", null },
        .{ .assignment, "corner-radius", "10.0" },
        .{ .assignment, "border-shape", "sharp" },
        .{ .section, "keybinds", null },
        .{ .assignment, "ctrl+shift+w", "wellbeing_dashboard" },
        .{ .assignment, "ctrl+shift+r", "reload_config" },
    });
    try expectErrors(sample, &.{});
}

test "parse: three assignment forms and an empty value" {
    const source = "theme = graphite\nfont_size: 14\ncursor block\nkey =\nother = # c\n";
    try expectEntries(source, &.{
        .{ .assignment, "theme", "graphite" },
        .{ .assignment, "font_size", "14" },
        .{ .assignment, "cursor", "block" },
        .{ .assignment, "key", null },
        .{ .assignment, "other", null },
    });
    try expectErrors(source, &.{});
}

test "parse: blank lines and comments yield nothing" {
    for ([_][]const u8{ "", "\n", "  \t\n", "# c", "# a\r\n\r\n  # b\n" }) |source| {
        try expectEntries(source, &.{});
        try expectErrors(source, &.{});
    }
}

test "parse: sections" {
    const source = "[card]\n[ a b ] # c\n";
    try expectEntries(source, &.{ .{ .section, "card", null }, .{ .section, "a b", null } });
    try expectErrors(source, &.{});
}

test "parse: unclosed_section" {
    try expectErrors("[card", &.{.{ .unclosed_section, 0, 0 }});
    try expectErrors("[", &.{.{ .unclosed_section, 0, 0 }});
    // '#' is not a comment inside brackets, so this is a name without ']'.
    try expectErrors("x = 1\n  [card # c", &.{.{ .unclosed_section, 1, 2 }});
    try expectEntries("[card", &.{});
}

test "parse: empty_section_name (D3)" {
    try expectErrors("[]", &.{.{ .empty_section_name, 0, 0 }});
    try expectErrors(" [ ]", &.{.{ .empty_section_name, 0, 1 }});
    try expectEntries("[]", &.{});
}

test "parse: unclosed_quote points at the quote (D5)" {
    try expectErrors("k = \"abc", &.{.{ .unclosed_quote, 0, 4 }});
    try expectErrors("\"abc = d", &.{.{ .unclosed_quote, 0, 0 }});
    try expectErrors("ab \"cd", &.{.{ .unclosed_quote, 0, 3 }});
    try expectErrors("k = 'abc # c", &.{.{ .unclosed_quote, 0, 4 }});
    try expectEntries("k = \"abc", &.{});
    try expectEntries("ab \"cd", &.{});
}

test "parse: missing_value" {
    try expectErrors("foo", &.{.{ .missing_value, 0, 0 }});
    try expectErrors("  foo # c", &.{.{ .missing_value, 0, 2 }});
    try expectEntries("foo", &.{});
}

test "parse: missing_name (D2)" {
    try expectErrors("= v", &.{.{ .missing_name, 0, 0 }});
    try expectErrors("  : v", &.{.{ .missing_name, 0, 2 }});
    try expectErrors("=", &.{.{ .missing_name, 0, 0 }});
    try expectEntries("= v", &.{});
}

test "parse: trailing_characters after a section header keeps the section (D1)" {
    try expectEntries("[a] b = c", &.{.{ .section, "a", null }});
    try expectErrors("[a] b = c", &.{.{ .trailing_characters, 0, 4 }});
    try expectErrors("[a]]", &.{.{ .trailing_characters, 0, 3 }});
}

test "parse: an inline '#' needs whitespace on both sides (D7)" {
    try expectEntries("color = #ff0000", &.{.{ .assignment, "color", "#ff0000" }});
    try expectErrors("color = #ff0000", &.{});
    try expectEntries("[a]#c", &.{.{ .section, "a", null }});
    try expectErrors("[a]#c", &.{.{ .trailing_characters, 0, 3 }});
    try expectErrors("[a] #c", &.{.{ .trailing_characters, 0, 4 }});
}

test "parse: at most one error per line" {
    try expectErrors("= \"abc", &.{.{ .missing_name, 0, 0 }});
    try expectErrors("[a] = \"x", &.{.{ .trailing_characters, 0, 4 }});
    try expectErrors("[ \"a", &.{.{ .unclosed_section, 0, 0 }});
}

test "parse: recovers on the next line" {
    const source = "[card\ntheme = x\n= v\nfoo = bar\n\"open\n[ok]";
    try expectEntries(source, &.{
        .{ .assignment, "theme", "x" },
        .{ .assignment, "foo", "bar" },
        .{ .section, "ok", null },
    });
    try expectErrors(source, &.{
        .{ .unclosed_section, 0, 0 },
        .{ .missing_name, 2, 0 },
        .{ .unclosed_quote, 4, 0 },
    });
}

test "parse: error lines count every line-end form" {
    try expectErrors("a = 1\r\n= v\r= w\n\n= x", &.{
        .{ .missing_name, 1, 0 },
        .{ .missing_name, 2, 0 },
        .{ .missing_name, 4, 0 },
    });
}

test "parse: a leading BOM is skipped, columns stay byte offsets (D4)" {
    const source = "\xEF\xBB\xBFtheme = x";
    try expectEntries(source, &.{.{ .assignment, "theme", "x" }});
    try expectErrors(source, &.{});

    var tree = try Ast.parse(gpa, source);
    defer tree.deinit(gpa);
    try std.testing.expectEqual(3, tree.tokens.items(.span)[tree.entries[0].name].start);
    try std.testing.expectEqual(3, tree.tokenLocation(tree.entries[0].name).column);

    try expectErrors("\xEF\xBB\xBF= v", &.{.{ .missing_name, 0, 3 }});
    // A BOM anywhere else is content.
    try expectEntries("k = \xEF\xBB\xBFv", &.{.{ .assignment, "k", "\xEF\xBB\xBFv" }});
}

test "parse: tokens end with exactly one eof" {
    for ([_][]const u8{ "", "\n", "k = v", "[a\n= v\n", "k = \"x" }) |source| {
        var tree = try Ast.parse(gpa, source);
        defer tree.deinit(gpa);
        const tags = tree.tokens.items(.tag);
        try std.testing.expect(tags.len > 0);
        try std.testing.expectEqual(.eof, tags[tags.len - 1]);
        for (tags[0 .. tags.len - 1]) |tag| try std.testing.expect(tag != .eof);
    }
}

/// Checks the location of token `index` in `source`, and that the token's text is
/// `text`, so a wrong index fails loudly instead of testing the wrong token.
fn expectLocation(source: []const u8, index: Ast.TokenIndex, text: []const u8, expected: Ast.Location) !void {
    var tree = try Ast.parse(gpa, source);
    defer tree.deinit(gpa);
    try std.testing.expectEqualStrings(text, tree.tokenSlice(index));
    try std.testing.expectEqual(expected, tree.tokenLocation(index));
}

test "tokenLocation: first token and each line-end form" {
    try expectLocation("ab = c", 0, "ab", .{ .line = 0, .column = 0, .line_start = 0, .line_end = 6 });
    try expectLocation("a\nb", 2, "b", .{ .line = 1, .column = 0, .line_start = 2, .line_end = 3 });
    try expectLocation("a\r\nb", 2, "b", .{ .line = 1, .column = 0, .line_start = 3, .line_end = 4 });
    try expectLocation("a\rb", 2, "b", .{ .line = 1, .column = 0, .line_start = 2, .line_end = 3 });
    // line_end stops at '\r'.
    try expectLocation("ab = c\r\nx", 0, "ab", .{ .line = 0, .column = 0, .line_start = 0, .line_end = 6 });
}

test "tokenLocation: mixed line ends" {
    const source = "a\r\n\rb\nc";
    try expectLocation(source, 3, "b", .{ .line = 2, .column = 0, .line_start = 4, .line_end = 5 });
    try expectLocation(source, 5, "c", .{ .line = 3, .column = 0, .line_start = 6, .line_end = 7 });
}

test "tokenLocation: column within the last line without newline" {
    try expectLocation("a\nb c", 3, "c", .{ .line = 1, .column = 2, .line_start = 2, .line_end = 5 });
}

test "tokenLocation: eof" {
    try expectLocation("", 0, "", .{ .line = 0, .column = 0, .line_start = 0, .line_end = 0 });
    try expectLocation("a\n", 2, "", .{ .line = 1, .column = 0, .line_start = 2, .line_end = 2 });
    try expectLocation("a\r\n", 2, "", .{ .line = 1, .column = 0, .line_start = 3, .line_end = 3 });
    try expectLocation("a\r", 2, "", .{ .line = 1, .column = 0, .line_start = 2, .line_end = 2 });
    try expectLocation("ab", 1, "", .{ .line = 0, .column = 2, .line_start = 0, .line_end = 2 });
}

fn expectRendered(source: []const u8, expected: []const u8) !void {
    var tree = try Ast.parse(gpa, source);
    defer tree.deinit(gpa);
    try std.testing.expectEqual(1, tree.errors.len);
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try tree.renderError(tree.errors[0], &w);
    try std.testing.expectEqualStrings(expected, w.buffered());
}

test "renderError: one message per tag" {
    try expectRendered("[card", "unclosed section header, expected ']'");
    try expectRendered("[]", "empty section header");
    try expectRendered("k = \"abc", "unclosed quote in string literal");
    try expectRendered("foo", "expected assignment operator '=' or value");
    try expectRendered("= v", "expected a key before '='");
    try expectRendered(": v", "expected a key before ':'");
    try expectRendered("[a] b", "unexpected text after section header");
}

fn parseAndFree(allocator: std.mem.Allocator, source: []const u8) !void {
    var tree = try Ast.parse(allocator, source);
    tree.deinit(allocator);
}

test "parse: frees everything on allocation failure" {
    const source = "# c\ntheme = x\n[card\nk = \"open\n[a] b\nfoo\n= v\n[ok]\nkey value\n";
    try std.testing.checkAllAllocationFailures(gpa, parseAndFree, .{source});
}

/// Bytes that change the tokenizer's state, plus one ordinary byte.
const alphabet = " \t\n\r#=:\"'\\[]a";

test "parse: every short input parses with well-formed entries and errors" {
    // All strings over `alphabet` of up to 3 bytes, or up to 5 with -Dslow (about
    // 400k inputs, 25 s in Debug: each parse goes through the testing allocator).
    // Also checks that the `unreachable` prong in `parse` is never reached.
    const max_len: usize = if (@import("test_options").slow) 5 else 3;
    var buf: [5]u8 = undefined;
    for (0..max_len + 1) |len| {
        var digits = [_]u8{0} ** buf.len;
        while (true) {
            for (buf[0..len], digits[0..len]) |*b, d| b.* = alphabet[d];
            try expectWellFormed(buf[0..len]);
            // Next combination, odometer-style; stop after the last one.
            var i: usize = 0;
            while (i < len) : (i += 1) {
                digits[i] += 1;
                if (digits[i] < alphabet.len) break;
                digits[i] = 0;
            }
            if (i == len) break;
        }
    }
}

/// Checks the invariants that hold for every source: entries point at name and
/// value tokens, errors are on strictly increasing lines, and every token's
/// location is within its line and the source.
fn expectWellFormed(source: []const u8) !void {
    errdefer std.debug.print("source: \"{f}\"\n", .{std.zig.fmtString(source)});
    var tree = try Ast.parse(gpa, source);
    defer tree.deinit(gpa);
    const tags = tree.tokens.items(.tag);
    for (tree.entries) |entry| {
        try std.testing.expectEqual(.name, tags[entry.name]);
        if (entry.value) |value| try std.testing.expectEqual(.value, tags[value]);
    }
    var previous_line: ?usize = null;
    for (tree.errors) |err| {
        const line = tree.tokenLocation(err.token).line;
        if (previous_line) |previous| try std.testing.expect(line > previous);
        previous_line = line;
    }
    for (0..tree.tokens.len) |i| {
        const location = tree.tokenLocation(@intCast(i));
        try std.testing.expect(location.line_start + location.column <= location.line_end);
        try std.testing.expect(location.line_end <= source.len);
    }
}
