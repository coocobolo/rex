const std = @import("std");
const Tokenizer = @import("Tokenizer.zig");
const Token = Tokenizer.Token;

const Expected = struct { Token.Tag, []const u8 };

/// Checks that `source` tokenizes to exactly `expected` (tag and spanned text),
/// followed by an `eof` token at `source.len`.
fn expectTokens(source: []const u8, expected: []const Expected) !void {
    var tokenizer: Tokenizer = .init(source);
    for (expected, 0..) |e, i| {
        errdefer std.debug.print("token {d} of source:\n{s}\n", .{ i, source });
        const token = tokenizer.next();
        try std.testing.expectEqual(e[0], token.tag);
        try std.testing.expectEqualStrings(e[1], source[token.span.start..token.span.end]);
    }
    errdefer std.debug.print("eof of source:\n{s}\n", .{source});
    const last = tokenizer.next();
    try std.testing.expectEqual(Token.Tag.eof, last.tag);
    try std.testing.expectEqual(source.len, last.span.start);
    try std.testing.expectEqual(source.len, last.span.end);
}

test "next: assignment forms" {
    try expectTokens("theme = graphite\n", &.{
        .{ .name, "theme" }, .{ .separator, "=" }, .{ .value, "graphite" }, .{ .newline, "\n" },
    });
    try expectTokens("theme: graphite", &.{
        .{ .name, "theme" }, .{ .separator, ":" }, .{ .value, "graphite" },
    });
    try expectTokens("theme graphite", &.{
        .{ .name, "theme" }, .{ .value, "graphite" },
    });
    try expectTokens("key value with spaces", &.{
        .{ .name, "key" }, .{ .value, "value with spaces" },
    });
    try expectTokens("key\tvalue", &.{ .{ .name, "key" }, .{ .value, "value" } });
    try expectTokens("key   value  ", &.{ .{ .name, "key" }, .{ .value, "value" } });
    try expectTokens("theme graphite # c", &.{
        .{ .name, "theme" }, .{ .value, "graphite" }, .{ .comment, "# c" },
    });
    try expectTokens("foo   ", &.{.{ .name, "foo" }});
    try expectTokens("foo # c", &.{ .{ .name, "foo" }, .{ .comment, "# c" } });
}

test "next: names and values are trimmed of spaces and tabs only" {
    try expectTokens("  a b  =  c d  ", &.{
        .{ .name, "a b" }, .{ .separator, "=" }, .{ .value, "c d" },
    });
    try expectTokens("\tk\t=\tv\t", &.{
        .{ .name, "k" }, .{ .separator, "=" }, .{ .value, "v" },
    });
    // \v and \f are content, not whitespace.
    try expectTokens("k = \x0bv\x0c", &.{
        .{ .name, "k" }, .{ .separator, "=" }, .{ .value, "\x0bv\x0c" },
    });
    // NBSP is content, not whitespace (spec §1).
    try expectTokens("k =\xC2\xA0v\xC2\xA0", &.{
        .{ .name, "k" }, .{ .separator, "=" }, .{ .value, "\xC2\xA0v\xC2\xA0" },
    });
    try expectTokens("k = v   \n", &.{
        .{ .name, "k" }, .{ .separator, "=" }, .{ .value, "v" }, .{ .newline, "\n" },
    });
}

test "next: empty and missing parts" {
    try expectTokens("", &.{});
    try expectTokens("  \t ", &.{});
    try expectTokens("\n\n", &.{ .{ .newline, "\n" }, .{ .newline, "\n" } });
    try expectTokens("key =", &.{ .{ .name, "key" }, .{ .separator, "=" } });
    try expectTokens("= v", &.{ .{ .separator, "=" }, .{ .value, "v" } });
    try expectTokens("foo", &.{.{ .name, "foo" }});
    try expectTokens("key =\nfoo", &.{
        .{ .name, "key" }, .{ .separator, "=" }, .{ .newline, "\n" }, .{ .name, "foo" },
    });
    try expectTokens(" \t\n", &.{.{ .newline, "\n" }});
    try expectTokens("=", &.{.{ .separator, "=" }});
    try expectTokens(":", &.{.{ .separator, ":" }});
}

test "next: the first separator outside quotes splits the line" {
    try expectTokens("k = v = w", &.{
        .{ .name, "k" }, .{ .separator, "=" }, .{ .value, "v = w" },
    });
    try expectTokens("ctrl+: = x", &.{
        .{ .name, "ctrl+" }, .{ .separator, ":" }, .{ .value, "= x" },
    });
    try expectTokens("\"a=b\" = c", &.{
        .{ .name, "\"a=b\"" }, .{ .separator, "=" }, .{ .value, "c" },
    });
    try expectTokens("==", &.{ .{ .separator, "=" }, .{ .value, "=" } });
    try expectTokens("url = http://x", &.{
        .{ .name, "url" }, .{ .separator, "=" }, .{ .value, "http://x" },
    });
    try expectTokens("url: http://x", &.{
        .{ .name, "url" }, .{ .separator, ":" }, .{ .value, "http://x" },
    });
    try expectTokens("a:b = c", &.{
        .{ .name, "a" }, .{ .separator, ":" }, .{ .value, "b = c" },
    });
    // A separator inside a comment does not count.
    try expectTokens("k v # a = b", &.{
        .{ .name, "k" }, .{ .value, "v" }, .{ .comment, "# a = b" },
    });
}

test "next: quotes" {
    try expectTokens("k = \"a # b\" # c", &.{
        .{ .name, "k" }, .{ .separator, "=" }, .{ .value, "\"a # b\"" }, .{ .comment, "# c" },
    });
    try expectTokens("k = 'x'", &.{
        .{ .name, "k" }, .{ .separator, "=" }, .{ .value, "'x'" },
    });
    try expectTokens("k = \"a = b\"", &.{
        .{ .name, "k" }, .{ .separator, "=" }, .{ .value, "\"a = b\"" },
    });
    // A quote preceded by a backslash does not close.
    try expectTokens("k = \"a\\\"b\"", &.{
        .{ .name, "k" }, .{ .separator, "=" }, .{ .value, "\"a\\\"b\"" },
    });
    try expectTokens("k = \"\"", &.{
        .{ .name, "k" }, .{ .separator, "=" }, .{ .value, "\"\"" },
    });
    try expectTokens("k = ''", &.{
        .{ .name, "k" }, .{ .separator, "=" }, .{ .value, "''" },
    });
    // Only the opening character closes; the other quote is content.
    try expectTokens("k = \"it's\"", &.{
        .{ .name, "k" }, .{ .separator, "=" }, .{ .value, "\"it's\"" },
    });
    try expectTokens("k = 'say \"hi\"'", &.{
        .{ .name, "k" }, .{ .separator, "=" }, .{ .value, "'say \"hi\"'" },
    });
    try expectTokens("k = 'a\\'b'", &.{
        .{ .name, "k" }, .{ .separator, "=" }, .{ .value, "'a\\'b'" },
    });
    // A backslash before any other byte changes nothing.
    try expectTokens("k = \"a\\b\"", &.{
        .{ .name, "k" }, .{ .separator, "=" }, .{ .value, "\"a\\b\"" },
    });
    try expectTokens("\"a # b\" = c", &.{
        .{ .name, "\"a # b\"" }, .{ .separator, "=" }, .{ .value, "c" },
    });
}

test "next: unclosed quote" {
    try expectTokens("k = \"abc", &.{
        .{ .name, "k" }, .{ .separator, "=" }, .{ .invalid, "\"abc" },
    });
    try expectTokens("\"abc = d", &.{.{ .invalid, "\"abc = d" }});
    try expectTokens("ab \"cd", &.{ .{ .name, "ab" }, .{ .invalid, "\"cd" } });
    // '#' inside the open quote is content.
    try expectTokens("k = \"a # b", &.{
        .{ .name, "k" }, .{ .separator, "=" }, .{ .invalid, "\"a # b" },
    });
    try expectTokens("k = \"abc  \nx", &.{
        .{ .name, "k" }, .{ .separator, "=" }, .{ .invalid, "\"abc" }, .{ .newline, "\n" }, .{ .name, "x" },
    });
    try expectTokens("k = 'abc", &.{
        .{ .name, "k" }, .{ .separator, "=" }, .{ .invalid, "'abc" },
    });
    try expectTokens("k = \"abc'", &.{
        .{ .name, "k" }, .{ .separator, "=" }, .{ .invalid, "\"abc'" },
    });
    try expectTokens("k = \"abc\r\nx", &.{
        .{ .name, "k" }, .{ .separator, "=" }, .{ .invalid, "\"abc" }, .{ .newline, "\r\n" }, .{ .name, "x" },
    });
    // The invalid token starts at the unclosed quote; text before it in the value is not emitted.
    try expectTokens("k = \"a\" \"b", &.{
        .{ .name, "k" }, .{ .separator, "=" }, .{ .invalid, "\"b" },
    });
    // A quote inside a comment is not tracked.
    try expectTokens("k = v # \"x", &.{
        .{ .name, "k" }, .{ .separator, "=" }, .{ .value, "v" }, .{ .comment, "# \"x" },
    });
}

test "next: a backslash inside quotes escapes the next byte (D8)" {
    // `\\` is an escaped backslash, so the quote after it closes.
    try expectTokens("k = \"a\\\\\"", &.{
        .{ .name, "k" }, .{ .separator, "=" }, .{ .value, "\"a\\\\\"" },
    });
    try expectTokens("k = \"a\\\\\" # c", &.{
        .{ .name, "k" }, .{ .separator, "=" }, .{ .value, "\"a\\\\\"" }, .{ .comment, "# c" },
    });
    // Escaped backslash, then an escaped quote: still open until the last quote.
    try expectTokens("k = \"\\\\\\\"x\"", &.{
        .{ .name, "k" }, .{ .separator, "=" }, .{ .value, "\"\\\\\\\"x\"" },
    });
    // A backslash before the line end escapes nothing; the quote stays open.
    try expectTokens("k = \"a\\\nx", &.{
        .{ .name, "k" }, .{ .separator, "=" }, .{ .invalid, "\"a\\" }, .{ .newline, "\n" }, .{ .name, "x" },
    });
    try expectTokens("k = \"a\\", &.{
        .{ .name, "k" }, .{ .separator, "=" }, .{ .invalid, "\"a\\" },
    });
}

test "next: quirks kept from the old lexer" {
    // The space-separated form ignores quotes (spec §7).
    try expectTokens("\"a b\" c", &.{ .{ .name, "\"a" }, .{ .value, "b\" c" } });
    // An unclosed quote with no separator before it: everything before the quote is the name.
    try expectTokens("key value \"x", &.{ .{ .name, "key value" }, .{ .invalid, "\"x" } });
}

test "next: comments" {
    try expectTokens("# only", &.{.{ .comment, "# only" }});
    try expectTokens("  #x", &.{.{ .comment, "#x" }});
    try expectTokens("key = # c", &.{
        .{ .name, "key" }, .{ .separator, "=" }, .{ .comment, "# c" },
    });
    try expectTokens("[ card ] # c", &.{
        .{ .l_bracket, "[" }, .{ .name, "card" }, .{ .r_bracket, "]" }, .{ .comment, "# c" },
    });
    try expectTokens("# a\nk = v", &.{
        .{ .comment, "# a" }, .{ .newline, "\n" }, .{ .name, "k" }, .{ .separator, "=" }, .{ .value, "v" },
    });
    try expectTokens("# c\rk = v", &.{
        .{ .comment, "# c" }, .{ .newline, "\r" }, .{ .name, "k" }, .{ .separator, "=" }, .{ .value, "v" },
    });
    try expectTokens("k = v # a # b", &.{
        .{ .name, "k" }, .{ .separator, "=" }, .{ .value, "v" }, .{ .comment, "# a # b" },
    });
    try expectTokens("#", &.{.{ .comment, "#" }});
}

test "next: an inline '#' needs whitespace before and whitespace or a line end after (D7)" {
    try expectTokens("color = #ff0000", &.{
        .{ .name, "color" }, .{ .separator, "=" }, .{ .value, "#ff0000" },
    });
    try expectTokens("color = #ff0000 # red", &.{
        .{ .name, "color" }, .{ .separator, "=" }, .{ .value, "#ff0000" }, .{ .comment, "# red" },
    });
    try expectTokens("k = v#c", &.{
        .{ .name, "k" }, .{ .separator, "=" }, .{ .value, "v#c" },
    });
    try expectTokens("k =#c", &.{
        .{ .name, "k" }, .{ .separator, "=" }, .{ .value, "#c" },
    });
    try expectTokens("a#b = 1", &.{
        .{ .name, "a#b" }, .{ .separator, "=" }, .{ .value, "1" },
    });
    try expectTokens("k = v\t# c", &.{
        .{ .name, "k" }, .{ .separator, "=" }, .{ .value, "v" }, .{ .comment, "# c" },
    });
    try expectTokens("k = v #note", &.{
        .{ .name, "k" }, .{ .separator, "=" }, .{ .value, "v #note" },
    });
    try expectTokens("key = #", &.{
        .{ .name, "key" }, .{ .separator, "=" }, .{ .comment, "#" },
    });
    try expectTokens("k = v #\n", &.{
        .{ .name, "k" }, .{ .separator, "=" }, .{ .value, "v" }, .{ .comment, "#" }, .{ .newline, "\n" },
    });
    try expectTokens("[card]#c", &.{
        .{ .l_bracket, "[" }, .{ .name, "card" }, .{ .r_bracket, "]" }, .{ .name, "#c" },
    });
    try expectTokens("[card] #c", &.{
        .{ .l_bracket, "[" }, .{ .name, "card" }, .{ .r_bracket, "]" }, .{ .name, "#c" },
    });
    try expectTokens("k = v #\tc", &.{
        .{ .name, "k" }, .{ .separator, "=" }, .{ .value, "v" }, .{ .comment, "#\tc" },
    });
    try expectTokens("k = v #\r\n", &.{
        .{ .name, "k" }, .{ .separator, "=" }, .{ .value, "v" }, .{ .comment, "#" }, .{ .newline, "\r\n" },
    });
    try expectTokens("k = v ## c", &.{
        .{ .name, "k" }, .{ .separator, "=" }, .{ .value, "v ## c" },
    });
    try expectTokens("k = \"a\"#c", &.{
        .{ .name, "k" }, .{ .separator, "=" }, .{ .value, "\"a\"#c" },
    });
}

test "next: '/' and '//' are content (D6)" {
    try expectTokens("k = /usr//share", &.{
        .{ .name, "k" }, .{ .separator, "=" }, .{ .value, "/usr//share" },
    });
    try expectTokens("k = v // note", &.{
        .{ .name, "k" }, .{ .separator, "=" }, .{ .value, "v // note" },
    });
    try expectTokens("// note", &.{ .{ .name, "//" }, .{ .value, "note" } });
    try expectTokens("ctrl+/ = copy", &.{
        .{ .name, "ctrl+/" }, .{ .separator, "=" }, .{ .value, "copy" },
    });
}

test "next: sections" {
    try expectTokens("[card]", &.{
        .{ .l_bracket, "[" }, .{ .name, "card" }, .{ .r_bracket, "]" },
    });
    try expectTokens("[ card ]", &.{
        .{ .l_bracket, "[" }, .{ .name, "card" }, .{ .r_bracket, "]" },
    });
    try expectTokens("[]", &.{ .{ .l_bracket, "[" }, .{ .r_bracket, "]" } });
    try expectTokens("[card", &.{ .{ .l_bracket, "[" }, .{ .name, "card" } });
    try expectTokens("[a b]", &.{
        .{ .l_bracket, "[" }, .{ .name, "a b" }, .{ .r_bracket, "]" },
    });
    // Quotes and comments are not honored inside brackets.
    try expectTokens("[a \"b]", &.{
        .{ .l_bracket, "[" }, .{ .name, "a \"b" }, .{ .r_bracket, "]" },
    });
    try expectTokens("[a # b]", &.{
        .{ .l_bracket, "[" }, .{ .name, "a # b" }, .{ .r_bracket, "]" },
    });
    // Text after ']' is tokenized as content; Ast reports it (D1).
    try expectTokens("[a] b = c", &.{
        .{ .l_bracket, "[" }, .{ .name, "a" },      .{ .r_bracket, "]" },
        .{ .name, "b" },      .{ .separator, "=" }, .{ .value, "c" },
    });
    try expectTokens("[ ]", &.{ .{ .l_bracket, "[" }, .{ .r_bracket, "]" } });
    try expectTokens("[a=b]", &.{
        .{ .l_bracket, "[" }, .{ .name, "a=b" }, .{ .r_bracket, "]" },
    });
    try expectTokens("[a]]", &.{
        .{ .l_bracket, "[" }, .{ .name, "a" }, .{ .r_bracket, "]" }, .{ .name, "]" },
    });
    try expectTokens("[[a]]", &.{
        .{ .l_bracket, "[" }, .{ .name, "[a" }, .{ .r_bracket, "]" }, .{ .name, "]" },
    });
    try expectTokens("[a]   \n", &.{
        .{ .l_bracket, "[" }, .{ .name, "a" }, .{ .r_bracket, "]" }, .{ .newline, "\n" },
    });
    try expectTokens("[card\nk = v", &.{
        .{ .l_bracket, "[" }, .{ .name, "card" },   .{ .newline, "\n" },
        .{ .name, "k" },      .{ .separator, "=" }, .{ .value, "v" },
    });
    // '[' and ']' are content outside a section header.
    try expectTokens("k = [x]", &.{
        .{ .name, "k" }, .{ .separator, "=" }, .{ .value, "[x]" },
    });
}

test "next: line ends" {
    try expectTokens("a\r\nb c\rd e\n", &.{
        .{ .name, "a" },     .{ .newline, "\r\n" },
        .{ .name, "b" },     .{ .value, "c" },
        .{ .newline, "\r" }, .{ .name, "d" },
        .{ .value, "e" },    .{ .newline, "\n" },
    });
    try expectTokens("k = v\r\n", &.{
        .{ .name, "k" }, .{ .separator, "=" }, .{ .value, "v" }, .{ .newline, "\r\n" },
    });
    try expectTokens("# c\r\n", &.{ .{ .comment, "# c" }, .{ .newline, "\r\n" } });
    try expectTokens("\r", &.{.{ .newline, "\r" }});
    try expectTokens("\r\r\n", &.{ .{ .newline, "\r" }, .{ .newline, "\r\n" } });
    try expectTokens("\n\r", &.{ .{ .newline, "\n" }, .{ .newline, "\r" } });
    try expectTokens("[a]\r\n", &.{
        .{ .l_bracket, "[" }, .{ .name, "a" }, .{ .r_bracket, "]" }, .{ .newline, "\r\n" },
    });
}

test "next: NUL is content" {
    try expectTokens("k = v\x00w", &.{
        .{ .name, "k" }, .{ .separator, "=" }, .{ .value, "v\x00w" },
    });
}

test "next: UTF-8 names and values are content" {
    try expectTokens("ключ = значение", &.{
        .{ .name, "ключ" },
        .{ .separator, "=" },
        .{ .value, "значение" },
    });
}

test "next: a leading UTF-8 BOM is skipped (D4)" {
    const source = "\xEF\xBB\xBFtheme = x";
    try expectTokens(source, &.{
        .{ .name, "theme" }, .{ .separator, "=" }, .{ .value, "x" },
    });
    var tokenizer: Tokenizer = .init(source);
    try std.testing.expectEqual(3, tokenizer.next().span.start);

    // A BOM anywhere else is content.
    try expectTokens("k = \xEF\xBB\xBFv", &.{
        .{ .name, "k" }, .{ .separator, "=" }, .{ .value, "\xEF\xBB\xBFv" },
    });
    try expectTokens("\xEF\xBB\xBF", &.{});
    try expectTokens("\xEF\xBB\xBF\n", &.{.{ .newline, "\n" }});
    try expectTokens("\xEF\xBB\xBF# c", &.{.{ .comment, "# c" }});
    // An incomplete BOM is content.
    try expectTokens("\xEF\xBB", &.{.{ .name, "\xEF\xBB" }});
}

test "next: keeps returning eof after eof" {
    for ([_][]const u8{ "", "k = v", "k = v\n" }) |source| {
        var tokenizer: Tokenizer = .init(source);
        var token = tokenizer.next();
        var count: usize = 0;
        while (token.tag != .eof) : (token = tokenizer.next()) {
            count += 1;
            try std.testing.expect(count <= source.len);
        }
        for (0..3) |_| {
            const again = tokenizer.next();
            try std.testing.expectEqual(Token.Tag.eof, again.tag);
            try std.testing.expectEqual(source.len, again.span.start);
            try std.testing.expectEqual(source.len, again.span.end);
        }
    }
}

test "reset: tokenizes the source again from the start" {
    for ([_][]const u8{ "k = v\n[a]", "\xEF\xBB\xBFtheme = x" }) |source| {
        var tokenizer: Tokenizer = .init(source);
        var first: [8]Token = undefined;
        for (&first) |*token| token.* = tokenizer.next();
        tokenizer.reset();
        for (first) |token| try std.testing.expectEqualDeep(token, tokenizer.next());
    }
}

test "next: spans are ordered, non-overlapping and in bounds" {
    const source =
        "\xEF\xBB\xBF# header\r\n" ++
        "theme = graphite\n" ++
        "  [ card ] # c\n" ++
        "corner_radius: 8.0\r" ++
        "k = \"a # b\" # c\n" ++
        "color = #ff0000 # red\n" ++
        "key value with spaces\n" ++
        "[card\n" ++
        "k = \"open\n" ++
        "\n" ++
        "last";
    var tokenizer: Tokenizer = .init(source);
    var previous_end: usize = 0;
    var count: usize = 0;
    while (true) {
        const token = tokenizer.next();
        try std.testing.expect(token.span.start <= token.span.end);
        try std.testing.expect(token.span.start >= previous_end);
        try std.testing.expect(token.span.end <= source.len);
        if (token.tag == .eof) break;
        // Only eof is zero-length.
        try std.testing.expect(token.span.start < token.span.end);
        previous_end = token.span.end;
        count += 1;
        try std.testing.expect(count <= source.len);
    }
}

/// Bytes that change the tokenizer's state, plus one ordinary byte.
const alphabet = " \t\n\r#=:\"'\\[]a";

test "next: every short input terminates in bounds with well-formed tokens" {
    // All strings of up to 5 bytes over `alphabet` (about 400k inputs, under a second in Debug).
    var buf: [5]u8 = undefined;
    for (0..buf.len + 1) |len| {
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

/// Checks the invariants that hold for every source: tokens are ordered and in
/// bounds, only eof is empty, the tokenizer stops, and each tag spans the bytes
/// it promises (spec §2.2).
fn expectWellFormed(source: []const u8) !void {
    errdefer std.debug.print("source: \"{f}\"\n", .{std.zig.fmtString(source)});
    var tokenizer: Tokenizer = .init(source);
    var previous_end: usize = 0;
    var count: usize = 0;
    while (true) {
        const token = tokenizer.next();
        try std.testing.expect(token.span.start >= previous_end);
        try std.testing.expect(token.span.start <= token.span.end);
        try std.testing.expect(token.span.end <= source.len);
        const text = source[token.span.start..token.span.end];
        switch (token.tag) {
            .eof => {
                try std.testing.expectEqual(source.len, token.span.start);
                break;
            },
            .l_bracket => try std.testing.expectEqualStrings("[", text),
            .r_bracket => try std.testing.expectEqualStrings("]", text),
            .separator => try std.testing.expect(std.mem.eql(u8, text, "=") or std.mem.eql(u8, text, ":")),
            .newline => try std.testing.expect(std.mem.eql(u8, text, "\n") or
                std.mem.eql(u8, text, "\r") or std.mem.eql(u8, text, "\r\n")),
            .comment => try std.testing.expectEqual('#', text[0]),
            .invalid => try std.testing.expect(text[0] == '"' or text[0] == '\''),
            .name, .value => {},
        }
        try std.testing.expect(text.len > 0);
        // Only newline tokens contain line-end bytes; nothing starts or ends with ws.
        if (token.tag != .newline) {
            try std.testing.expect(std.mem.findAny(u8, text, "\r\n") == null);
        }
        try std.testing.expect(text[0] != ' ' and text[0] != '\t');
        try std.testing.expect(text[text.len - 1] != ' ' and text[text.len - 1] != '\t');
        previous_end = token.span.end;
        count += 1;
        try std.testing.expect(count <= source.len);
    }
    // Further calls keep returning eof.
    try std.testing.expectEqual(Token.Tag.eof, tokenizer.next().tag);
}
