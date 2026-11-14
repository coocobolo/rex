//! Preserving config writer: updates one key in a config source (or appends it
//! to its section, creating the section when missing) while leaving comments,
//! key order, indentation, and untouched lines byte-for-byte intact.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const Ast = @import("Ast.zig");
const Loaded = @import("Loaded.zig");
const keys = @import("keys.zig");

pub const SetError = Allocator.Error || Ast.ParseError || error{
    InvalidKey,
    InvalidValue,
};

pub const WriteError = SetError ||
    Io.Dir.ReadFileAllocError ||
    Io.Dir.CreateDirPathOpenError ||
    Io.Dir.CreateFileAtomicError ||
    Io.File.WritePositionalError ||
    Io.File.Atomic.ReplaceError ||
    error{FileTooBig};

/// Reads the user config file at `path` (creating parent directories and
/// starting from an empty file when missing), updates `key` under `section`
/// to `new_value`, and replaces the file atomically.
pub fn writeKey(
    gpa: Allocator,
    io: Io,
    path: []const u8,
    section: keys.Section,
    key: []const u8,
    new_value: []const u8,
) WriteError!void {
    if (!isValidKey(key)) return error.InvalidKey;
    if (!isValidValue(new_value)) return error.InvalidValue;

    const cwd = Io.Dir.cwd();
    const existing: []u8 = cwd.readFileAlloc(io, path, gpa, .limited(Loaded.max_bytes)) catch |err| switch (err) {
        error.FileNotFound => try gpa.dupe(u8, ""),
        error.StreamTooLong => return error.FileTooBig,
        else => |e| return e,
    };
    defer gpa.free(existing);

    const updated = try setValue(gpa, existing, section, key, new_value);
    defer gpa.free(updated);

    const dir_path = std.fs.path.dirname(path) orelse ".";
    const filename = std.fs.path.basename(path);
    const dir = try cwd.createDirPathOpen(io, dir_path, .{});
    defer dir.close(io);

    var atomic = try dir.createFileAtomic(io, filename, .{ .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writePositionalAll(io, updated, 0);
    try atomic.replace(io);
}

/// Returns an owned copy of `source` with `key` under `section` set to
/// `new_value`. Caller owns the returned slice and frees it with `gpa`.
pub fn setValue(
    gpa: Allocator,
    source: []const u8,
    section: keys.Section,
    key: []const u8,
    new_value: []const u8,
) SetError![]u8 {
    if (!isValidKey(key)) return error.InvalidKey;
    if (!isValidValue(new_value)) return error.InvalidValue;

    var tree = try Ast.parse(gpa, source);
    defer tree.deinit(gpa);

    const eol = detectEol(source);
    const spans = tree.tokens.items(.span);
    const tags = tree.tokens.items(.tag);

    var current_section: ?keys.Section = .root;
    var last_match: ?Ast.Entry = null;
    var last_section_token: ?Ast.TokenIndex = null;
    var first_section_token: ?Ast.TokenIndex = null;

    for (tree.entries) |entry| {
        const name = tree.tokenSlice(entry.name);
        switch (entry.tag) {
            .section => {
                if (first_section_token == null) first_section_token = entry.name;
                current_section = sectionFromName(name);
                if (current_section == section) {
                    last_section_token = entry.name;
                }
            },
            .assignment => {
                const active = current_section orelse continue;
                if (active == section) {
                    last_section_token = entry.name;
                    if (std.mem.eql(u8, name, key)) {
                        last_match = entry;
                    }
                }
            },
        }
    }

    if (last_match) |entry| {
        if (entry.value) |val_tok| {
            const span = spans[val_tok];
            return replaceSpan(gpa, source, span.start, span.end, new_value);
        }
        const sep_tok = entry.name + 1;
        std.debug.assert(tags[sep_tok] == .separator);
        const sep_end = spans[sep_tok].end;
        return insertParts(gpa, source, sep_end, &.{ " ", new_value });
    }

    if (last_section_token) |tok| {
        const line = lineBoundsAfter(source, spans[tok].end);
        if (line.has_eol) {
            return insertParts(gpa, source, line.next_start, &.{ key, " = ", new_value, eol });
        }
        return insertParts(gpa, source, line.next_start, &.{ eol, key, " = ", new_value, eol });
    }

    if (section == .root) {
        if (first_section_token) |tok| {
            const line_start = lineStartBefore(source, spans[tok].start);
            return insertParts(gpa, source, line_start, &.{ key, " = ", new_value, eol, eol });
        }
        if (source.len == 0 or endsWithLineBreak(source)) {
            return insertParts(gpa, source, source.len, &.{ key, " = ", new_value, eol });
        }
        return insertParts(gpa, source, source.len, &.{ eol, key, " = ", new_value, eol });
    }

    const section_name = @tagName(section);
    if (source.len == 0) {
        return insertParts(gpa, source, 0, &.{ "[", section_name, "]", eol, key, " = ", new_value, eol });
    }
    if (endsWithBlankLine(source)) {
        return insertParts(gpa, source, source.len, &.{ "[", section_name, "]", eol, key, " = ", new_value, eol });
    }
    if (endsWithLineBreak(source)) {
        return insertParts(gpa, source, source.len, &.{ eol, "[", section_name, "]", eol, key, " = ", new_value, eol });
    }
    return insertParts(gpa, source, source.len, &.{ eol, eol, "[", section_name, "]", eol, key, " = ", new_value, eol });
}

fn sectionFromName(name: []const u8) ?keys.Section {
    if (std.mem.eql(u8, name, "root")) return null;
    return std.meta.stringToEnum(keys.Section, name);
}

fn isValidKey(key: []const u8) bool {
    if (key.len == 0) return false;
    for (key) |ch| {
        switch (ch) {
            ' ', '\t', '\r', '\n', '=', ':', '[', ']', '#' => return false,
            else => {},
        }
    }
    return true;
}

fn isValidValue(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |ch| {
        if (ch == '\r' or ch == '\n') return false;
    }
    return true;
}

fn detectEol(source: []const u8) []const u8 {
    for (source, 0..) |ch, i| {
        if (ch == '\n') {
            return if (i > 0 and source[i - 1] == '\r') "\r\n" else "\n";
        }
        if (ch == '\r') {
            if (i + 1 < source.len and source[i + 1] == '\n') return "\r\n";
            return "\r";
        }
    }
    return "\n";
}

fn endsWithLineBreak(source: []const u8) bool {
    if (source.len == 0) return false;
    const last = source[source.len - 1];
    return last == '\n' or last == '\r';
}

fn endsWithBlankLine(source: []const u8) bool {
    if (std.mem.endsWith(u8, source, "\r\n\r\n")) return true;
    if (std.mem.endsWith(u8, source, "\n\n")) return true;
    if (std.mem.endsWith(u8, source, "\r\r")) return true;
    return false;
}

fn lineStartBefore(source: []const u8, offset: usize) usize {
    var i = offset;
    while (i > 0) : (i -= 1) {
        const prev = source[i - 1];
        if (prev == '\n' or prev == '\r') break;
    }
    return i;
}

fn lineBoundsAfter(source: []const u8, offset: usize) struct { next_start: usize, has_eol: bool } {
    var i = offset;
    while (i < source.len) : (i += 1) {
        if (source[i] == '\r') {
            const step: usize = if (i + 1 < source.len and source[i + 1] == '\n') 2 else 1;
            return .{ .next_start = i + step, .has_eol = true };
        }
        if (source[i] == '\n') {
            return .{ .next_start = i + 1, .has_eol = true };
        }
    }
    return .{ .next_start = source.len, .has_eol = false };
}

fn replaceSpan(gpa: Allocator, source: []const u8, start: usize, end: usize, replacement: []const u8) Allocator.Error![]u8 {
    const out = try gpa.alloc(u8, source.len - (end - start) + replacement.len);
    @memcpy(out[0..start], source[0..start]);
    @memcpy(out[start..][0..replacement.len], replacement);
    @memcpy(out[start + replacement.len ..], source[end..]);
    return out;
}

fn insertParts(gpa: Allocator, source: []const u8, at: usize, parts: []const []const u8) Allocator.Error![]u8 {
    var extra_len: usize = 0;
    for (parts) |part| extra_len += part.len;

    const out = try gpa.alloc(u8, source.len + extra_len);
    @memcpy(out[0..at], source[0..at]);
    var pos = at;
    for (parts) |part| {
        @memcpy(out[pos..][0..part.len], part);
        pos += part.len;
    }
    @memcpy(out[pos..], source[at..]);
    return out;
}
