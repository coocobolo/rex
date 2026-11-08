//! Splits a config source into tokens. One pass, no allocation, no
//! knowledge of sections or keys: `Ast.parse` decides what is valid.
//! The grammar and the decisions it follows (D1–D7) are in the config spec.

const std = @import("std");

/// What `scanLine` records about the line it starts on. All fields are byte
/// offsets into `src`.
const Line = struct {
    /// Where the entry text stops: `comment` if there is one, else `end`.
    content_end: u32,
    /// First line-end byte, or `src.len`.
    end: u32,
    /// The '#' that starts the comment: outside quotes, with ' ' or '\t'
    /// before it and ' ', '\t' or the line end after it (D7).
    comment: ?u32,
    /// First '=' or ':' outside quotes, before `comment`.
    separator: ?u32,
    /// Opening quote that is still open at `content_end`.
    unclosed_quote: ?u32,

    pub const init: Line = .{
        .content_end = 0,
        .end = 0,
        .comment = null,
        .separator = null,
        .unclosed_quote = null,
    };
};

const State = enum {
    line_start,
    section,
    key,
    separator,
    value,
    after_entry,
};

pub const Token = struct {
    tag: Tag,
    span: Span,

    /// Half-open byte range `src[start..end]`, trimmed of ' ' and '\t'. Only
    /// `eof` is empty.
    pub const Span = struct { start: u32, end: u32 };
    pub const Tag = enum {
        l_bracket,
        r_bracket,
        name,
        separator,
        value,
        comment,
        newline,
        invalid,
        eof,
    };

    pub fn init(tag: Tag, span: Span) Token {
        return .{ .tag = tag, .span = span };
    }
};

const Tokenizer = @This();

/// Borrowed; must outlive the tokenizer and every span it returns.
src: []const u8,
index: u32 = 0,
state: State = .line_start,
/// Set by `scanLine` when a line has an entry; valid until the line's newline token.
line: Line = undefined,

/// Starts after a leading UTF-8 BOM (D4); spans stay offsets into `src`.
/// `src.len` must fit in a u32 (`Ast.parse` checks this for host input).
pub fn init(src: []const u8) Tokenizer {
    std.debug.assert(src.len <= std.math.maxInt(u32));
    const bom = "\xEF\xBB\xBF";
    return .{ .src = src, .index = if (std.mem.startsWith(u8, src, bom)) bom.len else 0 };
}

/// Starts over from the beginning of `src`, as after `init`.
pub fn reset(self: *Tokenizer) void {
    self.* = .init(self.src);
}

/// Returns the next token. After `eof`, keeps returning `eof` at `src.len`.
pub fn next(self: *Tokenizer) Token {
    while (true) switch (self.state) {
        .line_start => {
            self.skipWhitespace();
            if (self.atLineEnd()) return self.newline();
            switch (self.src[self.index]) {
                '#' => return self.comment(),
                '[' => {
                    self.state = .section;
                    return self.single(.l_bracket);
                },
                else => {
                    self.line = self.scanLine();
                    self.state = .key;
                },
            }
        },
        .section => {
            self.skipWhitespace();
            if (self.atLineEnd()) {
                self.state = .after_entry;
                continue;
            }

            if (self.src[self.index] == ']') {
                self.state = .after_entry;
                return self.single(.r_bracket);
            }

            var end = self.index;
            while (end < self.src.len and self.src[end] != ']' and !isLineEnd(self.src[end])) end += 1;
            return self.emit(.name, .{ .start = self.index, .end = self.trimEnd(self.index, end) });
        },
        .key => {
            const l = self.line;
            if (l.unclosed_quote) |q| if (l.separator == null or l.separator.? > q) {
                self.state = .value;
                const name_end = self.trimEnd(self.index, q);
                if (name_end > self.index) return self.emit(.name, .{ .start = self.index, .end = name_end });
                continue;
            };

            if (l.separator) |s| {
                self.state = .separator;
                const name_end = self.trimEnd(self.index, s);
                if (name_end > self.index) return self.emit(.name, .{ .start = self.index, .end = name_end });
                continue;
            }

            // Space-separated form: the name ends at the first whitespace.
            var name_end = self.index;
            while (name_end < l.content_end and !isWhitespace(self.src[name_end])) name_end += 1;
            self.state = .value;
            return self.emit(.name, .{ .start = self.index, .end = name_end });
        },
        .separator => {
            self.state = .value;
            self.index = self.line.separator.?;
            return self.single(.separator);
        },
        .value => {
            self.skipWhitespace();
            self.state = .after_entry;
            if (self.line.unclosed_quote) |q| if (q >= self.index) {
                return self.emit(.invalid, .{ .start = q, .end = self.trimEnd(q, self.line.end) });
            };
            const end = self.trimEnd(self.index, self.line.content_end);
            if (end > self.index) return self.emit(.value, .{ .start = self.index, .end = end });
        },
        .after_entry => {
            self.skipWhitespace();
            if (self.atLineEnd()) return self.newline();
            if (self.src[self.index] == '#' and self.isCommentStart(self.index)) return self.comment();

            // Text after an entry, e.g. after ']': tokenized as a new line's content (D1).
            self.line = self.scanLine();
            self.state = .key;
        },
    };
}

/// Scans the line from `index`, which is not whitespace, a line end or a
/// line-start comment. Quotes open with '"' or '\'' and close on the same byte
/// unless it follows a '\'; inside quotes, '#', '=' and ':' are content.
fn scanLine(self: *const Tokenizer) Line {
    var line: Line = .init;
    var quote: ?u32 = null;
    var i = self.index;

    while (i < self.src.len and !isLineEnd(self.src[i])) : (i += 1) {
        const c = self.src[i];
        if (quote) |q| {
            if (c == self.src[q] and self.src[i - 1] != '\\') quote = null;
            continue;
        }
        switch (c) {
            '"', '\'' => quote = i,
            '=', ':' => if (line.separator == null) {
                line.separator = i;
            },
            '#' => if (self.isCommentStart(i)) {
                line.comment = i;
                break;
            },
            else => {},
        }
    }

    line.unclosed_quote = quote;
    line.content_end = i;
    line.end = self.lineEnd(i);
    return line;
}

fn comment(self: *Tokenizer) Token {
    self.state = .after_entry;
    return self.emit(.comment, .{ .start = self.index, .end = self.trimEnd(self.index, self.lineEnd(self.index)) });
}

fn newline(self: *Tokenizer) Token {
    const start = self.index;
    if (start == self.src.len) return .init(.eof, .{ .start = start, .end = start });
    var len: u32 = 1;
    if (self.src[start] == '\r' and start + 1 < self.src.len and self.src[start + 1] == '\n') len = 2;
    self.state = .line_start;
    return self.emit(.newline, .{ .start = start, .end = start + len });
}

fn emit(self: *Tokenizer, tag: Token.Tag, span: Token.Span) Token {
    self.index = span.end;
    return .{ .tag = tag, .span = span };
}

fn skipWhitespace(self: *Tokenizer) void {
    while (self.index < self.src.len and isWhitespace(self.src[self.index])) self.index += 1;
}

/// D7: an inline '#' starts a comment only with ' ' or '\t' before it and
/// ' ', '\t' or the line end after it. A '#' that is the first non-whitespace
/// byte of a line is handled in `.line_start` and is always a comment.
fn isCommentStart(self: *const Tokenizer, index: u32) bool {
    if (index == 0 or !isWhitespace(self.src[index - 1])) return false;
    return index + 1 == self.src.len or isWhitespace(self.src[index + 1]) or isLineEnd(self.src[index + 1]);
}

fn single(self: *Tokenizer, tag: Token.Tag) Token {
    return self.emit(tag, .{ .start = self.index, .end = self.index + 1 });
}

fn atLineEnd(self: *const Tokenizer) bool {
    return self.index == self.src.len or isLineEnd(self.src[self.index]);
}

fn lineEnd(self: *const Tokenizer, from: u32) u32 {
    var i = from;
    while (i < self.src.len and !isLineEnd(self.src[i])) i += 1;
    return i;
}

fn trimEnd(self: *const Tokenizer, start: u32, end: u32) u32 {
    var e = end;
    while (e > start and isWhitespace(self.src[e - 1])) e -= 1;
    return e;
}

fn isWhitespace(b: u8) bool {
    return b == ' ' or b == '\t';
}

fn isLineEnd(c: u8) bool {
    return c == '\n' or c == '\r';
}
