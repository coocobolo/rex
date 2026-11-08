//! Syntax tree of a config file: the token list, one entry per section
//! header or assignment, and the syntax errors. Built by `parse`; values are
//! not interpreted here (that is Sema, config stage 2).

const std = @import("std");
const Allocator = std.mem.Allocator;

const Tokenizer = @import("Tokenizer.zig");
const Token = Tokenizer.Token;

const Ast = @This();

/// Borrowed; must outlive the Ast and every TokenIndex or Error taken from it.
source: []const u8,
/// Owned (gpa). Always ends with exactly one `eof` token.
tokens: TokenList.Slice,
/// Owned (gpa). Source order.
entries: []const Entry,
/// Owned (gpa). Source order; at most one per line.
errors: []const Error,

pub const TokenList = std.MultiArrayList(Token);
pub const TokenIndex = u32;

pub const Entry = struct {
    tag: Tag,
    /// Section name or key.
    name: TokenIndex,
    /// Value token of an assignment; null for sections and `key =`.
    value: ?TokenIndex,

    pub const Tag = enum { section, assignment };
};

pub const Error = struct {
    tag: Tag,
    /// Where the error is reported; which token depends on `tag`.
    token: TokenIndex,

    pub const Tag = enum {
        /// `[name` without ']'. Token: the '['.
        unclosed_section,
        /// `[]` (D3). Token: the '['.
        empty_section_name,
        /// A quote still open at the line end. Token: the invalid token, which
        /// starts at the quote (D5).
        unclosed_quote,
        /// `key` with neither separator nor value. Token: the name.
        missing_value,
        /// `= value` (D2). Token: the separator.
        missing_name,
        /// Text after a section header's ']' (D1). Token: the first such token.
        trailing_characters,
    };
};

pub const ParseError = Allocator.Error || error{SourceTooLong};

/// Position of a token, 0-based like `std.zig.Ast.Location`; printed output
/// adds 1. Lines end at "\r\n", "\n" or a lone "\r", as in the tokenizer.
pub const Location = struct {
    line: usize,
    /// Byte offset within the line; a leading BOM counts (D4).
    column: usize,
    /// Offset of the line's first byte.
    line_start: usize,
    /// Offset of the line's first line-end byte, or `source.len`.
    line_end: usize,
};

/// Frees everything `parse` allocated. `source` is not freed.
pub fn deinit(tree: *Ast, gpa: Allocator) void {
    tree.tokens.deinit(gpa);
    gpa.free(tree.entries);
    gpa.free(tree.errors);
    tree.* = undefined;
}

/// Tokenizes and parses `source`. The caller owns the result and frees it
/// with `deinit(gpa)`; `source` is borrowed. Syntax errors are collected in
/// `errors`, a line with an error yields no entry (except D1: the section
/// before trailing text is kept). Returns `error.SourceTooLong` above
/// `maxInt(u32)` bytes.
pub fn parse(gpa: Allocator, source: []const u8) ParseError!Ast {
    if (source.len > std.math.maxInt(u32)) return error.SourceTooLong;

    var tokens: TokenList = .empty;
    errdefer tokens.deinit(gpa);
    try tokens.ensureTotalCapacity(gpa, source.len / 8);
    var tokenizer: Tokenizer = .init(source);

    while (true) {
        const token = tokenizer.next();
        try tokens.append(gpa, token);
        if (token.tag == .eof) break;
    }

    var entries: std.ArrayList(Entry) = .empty;
    errdefer entries.deinit(gpa);
    var errors: std.ArrayList(Error) = .empty;
    errdefer errors.deinit(gpa);

    const tags = tokens.items(.tag);
    var i: TokenIndex = 0;
    while (true) {
        const start = i;
        const failure: ?Error = switch (tags[i]) {
            .newline, .comment => {
                i += 1;
                continue;
            },
            .eof => break,
            .l_bracket => blk: {
                i += 1;
                if (tags[i] != .name) {
                    if (tags[i] == .r_bracket) break :blk .{ .tag = .empty_section_name, .token = start };
                    break :blk .{ .tag = .unclosed_section, .token = start };
                }

                const name = i;
                i += 1;
                if (tags[i] != .r_bracket) break :blk .{ .tag = .unclosed_section, .token = start };
                i += 1;
                try entries.append(gpa, .{ .tag = .section, .name = name, .value = null });
                break :blk expectLineEnd(tags, &i);
            },
            .name => blk: {
                const name = i;
                i += 1;
                var value: ?TokenIndex = null;
                if (tags[i] == .separator) {
                    i += 1;
                    if (tags[i] == .value) {
                        value = i;
                        i += 1;
                    }
                } else if (tags[i] == .value) {
                    value = i;
                    i += 1;
                } else if (tags[i] != .invalid) {
                    break :blk .{ .tag = .missing_value, .token = name };
                }

                if (tags[i] == .invalid) break :blk .{ .tag = .unclosed_quote, .token = i };
                try entries.append(gpa, .{ .tag = .assignment, .name = name, .value = value });
                break :blk expectLineEnd(tags, &i);
            },
            .separator => .{ .tag = .missing_name, .token = i },
            .invalid => .{ .tag = .unclosed_quote, .token = i },
            // The tokenizer never starts a line with these: a value always follows a
            // name or separator, and ']' only follows '[' or a section name.
            .value, .r_bracket => unreachable,
        };

        if (failure) |err| {
            try errors.append(gpa, err);
            while (tags[i] != .newline and tags[i] != .eof) i += 1;
        }
    }

    const owned_entries = try entries.toOwnedSlice(gpa);
    errdefer gpa.free(owned_entries);
    const owned_errors = try errors.toOwnedSlice(gpa);
    return .{
        .source = source,
        .tokens = tokens.toOwnedSlice(),
        .entries = owned_entries,
        .errors = owned_errors,
    };
}

fn expectLineEnd(tags: []const Token.Tag, i: *TokenIndex) ?Error {
    if (tags[i.*] == .comment) i.* += 1;
    if (tags[i.*] == .newline or tags[i.*] == .eof) return null;
    return .{ .tag = .trailing_characters, .token = i.* };
}

/// The source text of token `i`.
pub fn tokenSlice(tree: *const Ast, i: TokenIndex) []const u8 {
    const span = tree.tokens.items(.span)[i];
    return tree.source[span.start..span.end];
}

/// Line and column of token `i`. Scans from the start of `source`: O(n) per
/// call, meant for reporting errors, not for hot paths.
pub fn tokenLocation(tree: *const Ast, i: TokenIndex) Location {
    const start = tree.tokens.items(.span)[i].start;
    var location: Location = .{ .line = 0, .column = 0, .line_start = 0, .line_end = 0 };
    var j: usize = 0;
    while (j < start) : (j += 1) {
        const c = tree.source[j];
        if (c == '\n' or c == '\r') {
            if (c == '\r' and j + 1 < tree.source.len and tree.source[j + 1] == '\n') j += 1;
            location.line += 1;
            location.line_start = j + 1;
        }
    }
    location.column = start - location.line_start;
    var end = start;
    while (end < tree.source.len and tree.source[end] != '\n' and tree.source[end] != '\r') end += 1;
    location.line_end = end;
    return location;
}

/// Writes the message for `err`, without location or newline, like
/// `std.zig.Ast.renderError`.
pub fn renderError(tree: *const Ast, err: Error, w: *std.Io.Writer) std.Io.Writer.Error!void {
    switch (err.tag) {
        .unclosed_section => try w.writeAll("unclosed section header, expected ']'"),
        .empty_section_name => try w.writeAll("empty section header"),
        .unclosed_quote => try w.writeAll("unclosed quote in string literal"),
        .missing_value => try w.writeAll("expected assignment operator '=' or value"),
        .missing_name => try w.print("expected a key before '{s}'", .{tree.tokenSlice(err.token)}),
        .trailing_characters => try w.writeAll("unexpected text after section header"),
    }
}
