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

    const existing = try readOrEmpty(gpa, io, path);
    defer gpa.free(existing);

    const updated = try setValue(gpa, existing, section, key, new_value);
    defer gpa.free(updated);

    try writeAtomic(io, path, updated);
}

/// Reads the user config file at `path` (creating parent directories and
/// starting from an empty file when missing), replaces all occurrences of
/// `key` under `section` with one line per item in `values` (or `key = none`
/// when `values` is empty), and writes the file atomically.
pub fn writeList(
    gpa: Allocator,
    io: Io,
    path: []const u8,
    section: keys.Section,
    key: []const u8,
    values: []const []const u8,
) WriteError!void {
    if (!isValidKey(key)) return error.InvalidKey;
    for (values) |v| {
        if (!isValidValue(v)) return error.InvalidValue;
    }

    const existing = try readOrEmpty(gpa, io, path);
    defer gpa.free(existing);

    const updated = try setListValues(gpa, existing, section, key, values);
    defer gpa.free(updated);

    try writeAtomic(io, path, updated);
}

fn readOrEmpty(gpa: Allocator, io: Io, path: []const u8) WriteError![]u8 {
    return Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(Loaded.max_bytes)) catch |err| switch (err) {
        error.FileNotFound => try gpa.dupe(u8, ""),
        error.StreamTooLong => return error.FileTooBig,
        else => |e| return e,
    };
}

fn writeAtomic(io: Io, path: []const u8, data: []const u8) WriteError!void {
    const cwd = Io.Dir.cwd();
    const dir_path = std.fs.path.dirname(path) orelse ".";
    const filename = std.fs.path.basename(path);
    const dir = try cwd.createDirPathOpen(io, dir_path, .{});
    defer dir.close(io);

    var atomic = try dir.createFileAtomic(io, filename, .{ .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writePositionalAll(io, data, 0);
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

    return insertNewSectionBlock(gpa, source, section, eol, if (first_section_token) |tok| spans[tok].start else null, &.{ key, " = ", new_value, eol });
}

/// Returns an owned copy of `source` with all occurrences of `key` under
/// `section` replaced by one line per item in `values` (or `key = none` when
/// empty). Caller owns the returned slice and frees it with `gpa`.
pub fn setListValues(
    gpa: Allocator,
    source: []const u8,
    section: keys.Section,
    key: []const u8,
    values: []const []const u8,
) SetError![]u8 {
    if (!isValidKey(key)) return error.InvalidKey;
    for (values) |v| {
        if (!isValidValue(v)) return error.InvalidValue;
    }

    var tree = try Ast.parse(gpa, source);
    defer tree.deinit(gpa);

    const eol = detectEol(source);
    const spans = tree.tokens.items(.span);

    var current_section: ?keys.Section = .root;
    var matches: std.ArrayListUnmanaged(Ast.Entry) = .empty;
    defer matches.deinit(gpa);
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
                        try matches.append(gpa, entry);
                    }
                }
            },
        }
    }

    var block: std.ArrayListUnmanaged(u8) = .empty;
    defer block.deinit(gpa);
    if (values.len == 0) {
        try block.appendSlice(gpa, key);
        try block.appendSlice(gpa, " = none");
        try block.appendSlice(gpa, eol);
    } else {
        for (values) |v| {
            try block.appendSlice(gpa, key);
            try block.appendSlice(gpa, " = ");
            try block.appendSlice(gpa, v);
            try block.appendSlice(gpa, eol);
        }
    }

    if (matches.items.len > 0) {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(gpa);
        var pos: usize = 0;
        for (matches.items, 0..) |entry, i| {
            const line_start = lineStartBefore(source, spans[entry.name].start);
            const end_tok = entry.value orelse (entry.name + 1);
            const line_end = lineBoundsAfter(source, spans[end_tok].end).next_start;
            if (line_start > pos) {
                try out.appendSlice(gpa, source[pos..line_start]);
            }
            if (i == 0) {
                try out.appendSlice(gpa, block.items);
            }
            pos = line_end;
        }
        if (pos < source.len) {
            try out.appendSlice(gpa, source[pos..]);
        }
        return out.toOwnedSlice(gpa);
    }

    if (last_section_token) |tok| {
        const line = lineBoundsAfter(source, spans[tok].end);
        if (line.has_eol) {
            return insertParts(gpa, source, line.next_start, &.{block.items});
        }
        return insertParts(gpa, source, line.next_start, &.{ eol, block.items });
    }

    return insertNewSectionBlock(gpa, source, section, eol, if (first_section_token) |tok| spans[tok].start else null, &.{block.items});
}

fn insertNewSectionBlock(
    gpa: Allocator,
    source: []const u8,
    section: keys.Section,
    eol: []const u8,
    first_section_start: ?usize,
    block_parts: []const []const u8,
) Allocator.Error![]u8 {
    var prefix: [6][]const u8 = undefined;
    var prefix_len: usize = 0;
    var suffix_eol = false;
    var at: usize = source.len;

    if (section == .root) {
        if (first_section_start) |start| {
            at = lineStartBefore(source, start);
            suffix_eol = true;
        } else if (source.len > 0 and !endsWithLineBreak(source)) {
            prefix[prefix_len] = eol;
            prefix_len += 1;
        }
    } else {
        const section_name = @tagName(section);
        if (source.len == 0 or endsWithBlankLine(source)) {
            if (source.len == 0) at = 0;
        } else if (endsWithLineBreak(source)) {
            prefix[prefix_len] = eol;
            prefix_len += 1;
        } else {
            prefix[prefix_len] = eol;
            prefix_len += 1;
            prefix[prefix_len] = eol;
            prefix_len += 1;
        }
        prefix[prefix_len] = "[";
        prefix[prefix_len + 1] = section_name;
        prefix[prefix_len + 2] = "]";
        prefix[prefix_len + 3] = eol;
        prefix_len += 4;
    }

    var all: [11][]const u8 = undefined;
    var total: usize = 0;
    for (prefix[0..prefix_len]) |p| {
        all[total] = p;
        total += 1;
    }
    for (block_parts) |p| {
        all[total] = p;
        total += 1;
    }
    if (suffix_eol) {
        all[total] = eol;
        total += 1;
    }
    return insertParts(gpa, source, at, all[0..total]);
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
