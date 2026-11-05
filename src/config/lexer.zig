//! Streaming, zero-allocation tokenizer for Rex configuration files.
//!
//! Scans configuration buffers in linear O(N) time without allocating memory,
//! producing tokens for section headers, key-value assignments, and comments.

const std = @import("std");

/// Token classification emitted by the configuration lexer.
pub const TokenKind = enum {
    section,
    key_value,
    invalid,
    eof,
};

/// A single token referencing source slices with precise line and column coordinates.
pub const Token = struct {
    kind: TokenKind,
    line: usize,
    col: usize,
    key: []const u8 = "",
    value: []const u8 = "",
};

/// Zero-allocation sequential scanner over a UTF-8 configuration source buffer.
pub const Lexer = struct {
    source: []const u8,
    cursor: usize = 0,
    line: usize = 1,
    col: usize = 1,

    pub fn init(source: []const u8) Lexer {
        return .{
            .source = source,
        };
    }

    /// Advances to and returns the next meaningful token, skipping comments and blank lines.
    pub fn next(self: *Lexer) Token {
        while (self.cursor < self.source.len) {
            self.skipWhitespaceOnLine();

            if (self.cursor >= self.source.len) break;

            const c = self.source[self.cursor];

            // Newlines
            if (c == '\n') {
                self.cursor += 1;
                self.line += 1;
                self.col = 1;
                continue;
            }
            if (c == '\r') {
                self.cursor += 1;
                if (self.cursor < self.source.len and self.source[self.cursor] == '\n') {
                    self.cursor += 1;
                }
                self.line += 1;
                self.col = 1;
                continue;
            }

            // Comments (# or //)
            if (c == '#' or (c == '/' and self.peek(1) == '/')) {
                self.skipToEndOfLine();
                continue;
            }

            // Section header: [section_name]
            if (c == '[') {
                return self.scanSection();
            }

            // Key-Value entry
            return self.scanKeyValue();
        }

        return .{
            .kind = .eof,
            .line = self.line,
            .col = self.col,
        };
    }

    fn peek(self: Lexer, offset: usize) u8 {
        const idx = self.cursor + offset;
        if (idx < self.source.len) return self.source[idx];
        return 0;
    }

    fn skipWhitespaceOnLine(self: *Lexer) void {
        while (self.cursor < self.source.len) {
            const c = self.source[self.cursor];
            if (c == ' ' or c == '\t') {
                self.cursor += 1;
                self.col += 1;
            } else {
                break;
            }
        }
    }

    fn skipToEndOfLine(self: *Lexer) void {
        while (self.cursor < self.source.len) {
            const c = self.source[self.cursor];
            if (c == '\n' or c == '\r') break;
            self.cursor += 1;
            self.col += 1;
        }
    }

    fn scanSection(self: *Lexer) Token {
        const start_line = self.line;
        const start_col = self.col;

        self.cursor += 1; // skip '['
        self.col += 1;

        const name_start = self.cursor;
        while (self.cursor < self.source.len) {
            const c = self.source[self.cursor];
            if (c == ']') break;
            if (c == '\n' or c == '\r') break;
            self.cursor += 1;
            self.col += 1;
        }

        const name_raw = self.source[name_start..self.cursor];
        if (self.cursor < self.source.len and self.source[self.cursor] == ']') {
            self.cursor += 1;
            self.col += 1;
        } else {
            return .{
                .kind = .invalid,
                .line = start_line,
                .col = start_col,
                .key = "unclosed section header, expected ']'",
            };
        }

        // Consume trailing comment or whitespace on the same line
        self.skipWhitespaceOnLine();
        if (self.cursor < self.source.len and (self.source[self.cursor] == '#' or (self.source[self.cursor] == '/' and self.peek(1) == '/'))) {
            self.skipToEndOfLine();
        }

        return .{
            .kind = .section,
            .line = start_line,
            .col = start_col,
            .key = std.mem.trim(u8, name_raw, " \t"),
        };
    }

    fn scanKeyValue(self: *Lexer) Token {
        const start_line = self.line;
        const start_col = self.col;

        const key_start = self.cursor;
        var separator_idx: ?usize = null;
        var end_of_line_idx: usize = self.cursor;

        // Scan until end of line, identifying '=' or ':' outside quotes
        var in_quotes = false;
        var quote_char: u8 = 0;

        while (self.cursor < self.source.len) {
            const c = self.source[self.cursor];
            if (c == '\n' or c == '\r') {
                end_of_line_idx = self.cursor;
                break;
            }

            if (!in_quotes) {
                if (c == '"' or c == '\'') {
                    in_quotes = true;
                    quote_char = c;
                } else if (c == '#' or (c == '/' and self.peek(1) == '/')) {
                    end_of_line_idx = self.cursor;
                    self.skipToEndOfLine();
                    break;
                } else if (separator_idx == null and (c == '=' or c == ':')) {
                    separator_idx = self.cursor;
                }
            } else {
                if (c == quote_char and (self.cursor == 0 or self.source[self.cursor - 1] != '\\')) {
                    in_quotes = false;
                }
            }

            self.cursor += 1;
            self.col += 1;
            end_of_line_idx = self.cursor;
        }

        if (in_quotes) {
            return .{
                .kind = .invalid,
                .line = start_line,
                .col = start_col,
                .key = "unclosed quote in string literal",
            };
        }

        var key: []const u8 = "";
        var val: []const u8 = "";

        if (separator_idx) |sep| {
            key = std.mem.trim(u8, self.source[key_start..sep], " \t");
            val = std.mem.trim(u8, self.source[sep + 1 .. end_of_line_idx], " \t");
        } else {
            // Space-separated key and value (Ghostty style)
            const line_content = std.mem.trim(u8, self.source[key_start..end_of_line_idx], " \t");
            if (std.mem.indexOfAny(u8, line_content, " \t")) |space_idx| {
                key = std.mem.trim(u8, line_content[0..space_idx], " \t");
                val = std.mem.trim(u8, line_content[space_idx + 1 ..], " \t");
            } else {
                return .{
                    .kind = .invalid,
                    .line = start_line,
                    .col = start_col,
                    .key = "expected assignment operator '=' or value",
                };
            }
        }

        // Unquote value if wrapped in double or single quotes
        if (val.len >= 2) {
            if ((val[0] == '"' and val[val.len - 1] == '"') or (val[0] == '\'' and val[val.len - 1] == '\'')) {
                val = val[1 .. val.len - 1];
            }
        }

        return .{
            .kind = .key_value,
            .line = start_line,
            .col = start_col,
            .key = key,
            .value = val,
        };
    }
};
