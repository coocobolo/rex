//! Problems found in one config file, kept as token references and located
//! and rendered only when reported (rebuild plan C5). Syntax errors (Ast) are
//! errors; Sema findings are warnings.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Ast = @import("Ast.zig");
const Sema = @import("Sema.zig");

pub const Severity = enum { err, warn };

/// A parsed and applied file. Every diagnostic refers into it, so it must
/// outlive them.
pub const File = struct {
    /// Owned (gpa). `tree` borrows it.
    source: []u8,
    /// Owned (gpa).
    tree: Ast,
    /// Owned (gpa).
    sema: Sema.Result,

    pub fn deinit(file: *File, gpa: Allocator) void {
        file.sema.deinit(gpa);
        file.tree.deinit(gpa);
        gpa.free(file.source);
        file.* = undefined;
    }

    pub fn iterator(file: *const File) Iterator {
        return .{ .syntax = file.tree.errors, .sema = file.sema.errors };
    }
};

pub const Diagnostic = union(enum) {
    syntax: Ast.Error,
    sema: Sema.Error,

    pub fn severity(d: Diagnostic) Severity {
        return switch (d) {
            .syntax => .err,
            .sema => .warn,
        };
    }

    pub fn token(d: Diagnostic) Ast.TokenIndex {
        return switch (d) {
            inline else => |e| e.token,
        };
    }
};

/// Both lists of a `File` in source order. Each list is already in source
/// order, so this is a merge; at the same token the syntax error comes first.
pub const Iterator = struct {
    syntax: []const Ast.Error,
    sema: []const Sema.Error,

    pub fn next(it: *Iterator) ?Diagnostic {
        if (it.syntax.len > 0 and (it.sema.len == 0 or it.syntax[0].token <= it.sema[0].token)) {
            defer it.syntax = it.syntax[1..];
            return .{ .syntax = it.syntax[0] };
        }
        if (it.sema.len > 0) {
            defer it.sema = it.sema[1..];
            return .{ .sema = it.sema[0] };
        }
        return null;
    }
};

/// Writes the message for `d`, without location or newline.
pub fn renderMessage(file: *const File, d: Diagnostic, w: *std.Io.Writer) std.Io.Writer.Error!void {
    switch (d) {
        .syntax => |e| try file.tree.renderError(e, w),
        .sema => |e| try Sema.renderError(&file.tree, e, w),
    }
}

pub const FormatOptions = struct {
    /// Also write the source line and a caret under the reported column.
    source_line: bool = false,
};

/// Writes `label:line:col: error|warning: message` and a newline. Line and
/// column are 1-based; the column counts bytes, as editors expect when
/// jumping to it. With `source_line`, the caret line copies the line's tabs
/// and puts one space per code point before the column, so it aligns under
/// text with tabs or non-ASCII characters (but not under wide characters).
pub fn format(file: *const File, label: []const u8, d: Diagnostic, w: *std.Io.Writer, options: FormatOptions) std.Io.Writer.Error!void {
    const loc = file.tree.tokenLocation(d.token());
    const severity: []const u8 = switch (d.severity()) {
        .err => "error",
        .warn => "warning",
    };
    try w.print("{s}:{d}:{d}: {s}: ", .{ label, loc.line + 1, loc.column + 1, severity });
    try renderMessage(file, d, w);
    try w.writeByte('\n');
    if (!options.source_line) return;

    const line = file.source[loc.line_start..loc.line_end];
    try w.print("{s}\n", .{line});
    for (line[0..loc.column]) |c| switch (c) {
        '\t' => try w.writeByte('\t'),
        // UTF-8 continuation bytes belong to the code point already counted.
        0x80...0xbf => {},
        else => try w.writeByte(' '),
    };
    try w.writeAll("^\n");
}
