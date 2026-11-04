//! `zig build gen-wcwidth-table`: src/unicode/wcwidth_table.zig from
//! UnicodeData.txt and EastAsianWidth.txt.
//!
//! This generator uses data from the Unicode Character Database.
//! See THIRD_PARTY_NOTICES/unicode.license.txt for the applicable Unicode license terms.
//!
//! Unicode version: 17.0.0
//!
//! Usage: wcwidth_table <out.zig> <EastAsianWidth.txt> <UnicodeData.txt>
//!
//! Parses the Unicode Character Database files needed for a POSIX
//! wcwidth(3) compatible width table and emits a single sorted, packed
//! range table as a standalone Zig source file.
//!
//! Property classification (priority: control/zero from UnicodeData.txt
//! overrides East Asian Width from EastAsianWidth.txt):
//!  General_Category Cc                    .control
//!  General_Category Mn, Me, Cf            .zero
//!  East_Asian_Width W or F                .wide
//!  East_Asian_Width A                     .ambiguous
//!  everything else (including unassigned) .narrow
//!
//! Table entry (u32):
//!   bits [0,3)   property enum (3 bits, 5 values used)
//!   bits [3,11)  range size - 1 (8 bits, max run length 256)
//!   bits [11,32) lower-bound codepoint (21 bits, max 0x10FFFF)
//!
//! Run `zig build gen` after bumping tools/ucd/VERSION and commit the
//! generated table.

const std = @import("std");
const ucd = @import("ucd.zig");

const gen_name = "wcwidth-table";
const usage_args = "<out.zig> <EastAsianWidth.txt> <UnicodeData.txt>";
const mem = std.mem;
const fmt = std.fmt;

const Property = enum(u3) {
    narrow = 0,
    wide = 1,
    ambiguous = 2,
    zero = 3,
    control = 4,
};

const Working = enum {
    unclassified,
    narrow,
    wide,
    ambiguous,
    zero,
    control,
};

const max_codepoint: u21 = 0x10ffff;
const table_len: usize = @as(usize, max_codepoint) + 1;

// Unicode's documented defaults for unassigned code points in these blocks
// (see EastAsianWidth.txt header comments) the default to Wide even before
// any assigned character is listed explicitly.
const default_wide_ranges = [_][2]u21{
    .{ 0x3400, 0x4DBF }, // CJK Unified Ideographs Extension A
    .{ 0x4E00, 0x9FFF }, // CJK Unified Ideographs
    .{ 0xF900, 0xFAFF }, // CJK Compatibility Ideographs
    .{ 0x20000, 0x2FFFD }, // Plane 2
    .{ 0x30000, 0x3FFFD }, // Plane 3
};

// Explicit terminal-policy override.
//
// U+1160..U+11FF are Hangul Jungseong/Jongseong jamo. Their General_Category
// is Lo, so General_Category alone would classify them as single-cell.
// This project follows the traditional terminal-width convention of treating
// these combining jamo as zero-width.
const terminal_zero_width_overrides = [_][2]u21{
    .{ 0x1160, 0x11FF }, // Hangul Jungseong/Jongseong
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var arena = init.arena.allocator();

    var args_it = init.minimal.args.iterate();
    _ = args_it.skip(); // argv[0]
    const out_path = args_it.next() orelse ucd.usage(gen_name, usage_args);
    const eaw_path = args_it.next() orelse ucd.usage(gen_name, usage_args);
    const udata_path = args_it.next() orelse ucd.usage(gen_name, usage_args);

    const working = try arena.alloc(Working, table_len);
    @memset(working, .unclassified);

    try applyUnicodeData(io, arena, working, udata_path);
    try applyEastAsianWidth(io, arena, working, eaw_path);

    applyDefaultDoubleRangeOverrides(working);
    applyTerminalPolicyOverridesOverrides(working);

    // noncharacters/surrogates forced to .control
    {
        var plane: u21 = 0;
        while (plane <= 0x10) : (plane += 1) {
            const base = plane * 0x10000;
            working[base + 0xFFFE] = .control;
            working[base + 0xFFFF] = .control;
        }
        for (0xFDD0..0xFDEF + 1) |cp| working[cp] = .control;
    }
    for (0xD800..0xDFFF + 1) |cp| working[cp] = .control;

    const properties = try arena.alloc(Property, table_len);
    for (working, 0..) |w, i| {
        properties[i] = switch (w) {
            .unclassified => .control,
            .narrow => .narrow,
            .wide => .wide,
            .ambiguous => .ambiguous,
            .zero => .zero,
            .control => .control,
        };
    }
    const entries = try buildEntries(arena, properties);

    var buffer: [4096]u8 = undefined;
    var stdout = (try ucd.createFile(io, out_path)).writer(io, &buffer);
    const w = &stdout.interface;
    try ucd.writeHeader(w, gen_name, "UCD {s}", .{ucd.versionOf(eaw_path)});
    try writeOutput(w, entries);
    try w.flush();
    ucd.log(gen_name, "wrote {s}: {d} entries ({d} bytes)", .{ std.fs.path.basename(out_path), entries.len, entries.len * 4 });
}

fn applyEastAsianWidth(io: std.Io, gpa: mem.Allocator, dest: []Working, path: []const u8) !void {
    const content = try ucd.readFile(io, gpa, gen_name, path);
    defer gpa.free(content);

    var reader: std.Io.Reader = .fixed(content);

    while (try reader.takeDelimiter('\n')) |raw_line| {
        const line = stripComment(raw_line);
        if (line.len == 0) continue;

        const semi = mem.indexOfScalar(u8, line, ';') orelse continue;
        const cp_field = mem.trim(u8, line[0..semi], " \t\r");
        const eaw = mem.trim(u8, line[semi + 1 ..], " \t\r");

        const property: ?Working =
            if (mem.eql(u8, eaw, "W") or mem.eql(u8, eaw, "F"))
                .wide
            else if (mem.eql(u8, eaw, "A"))
                .ambiguous
            else
                null; // Na/H/N; narrow is handled by applyUnicodeData.
        const prop = property orelse continue;

        var start: u21 = undefined;
        var end: u21 = undefined;
        if (mem.indexOf(u8, cp_field, "..")) |dots| {
            start = try fmt.parseInt(u21, cp_field[0..dots], 16);
            end = try fmt.parseInt(u21, cp_field[dots + 2 ..], 16);
        } else {
            start = try fmt.parseInt(u21, cp_field, 16);
            end = start;
        }

        // Promote only characters that currently have the default terminal
        // width of one cell. Never overwrite zero/control classifications.
        var cp = start;
        while (cp <= end) : (cp += 1) {
            if (dest[cp] == .narrow) dest[cp] = prop;
        }
    }
}

fn applyUnicodeData(io: std.Io, gpa: mem.Allocator, dest: []Working, path: []const u8) !void {
    const content = try ucd.readFile(io, gpa, gen_name, path);
    defer gpa.free(content);

    var reader: std.Io.Reader = .fixed(content);
    var pending_first: ?u21 = null;

    while (try reader.takeDelimiter('\n')) |raw_line| {
        const line = mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;

        var fields: [3][]const u8 = undefined;
        var it = mem.splitScalar(u8, line, ';');
        fields[0] = it.next() orelse continue; // codepoint
        fields[1] = it.next() orelse continue; // name
        fields[2] = it.next() orelse continue; // general category

        const cp = try fmt.parseInt(u21, fields[0], 16);
        const category = fields[2];

        // classify() returns .narrow explicitly for every other
        // assigned category (Lu, Ll, Lo, Nd, So, Zs, Sc, ...).
        // not null-falling-through-to-a-default.
        const prop = classify(category);

        if (mem.endsWith(u8, fields[1], "First>")) {
            pending_first = cp;
            continue;
        }
        if (mem.endsWith(u8, fields[1], "Last>")) {
            if (pending_first) |start| {
                fillRange(dest, start, cp, prop);
                pending_first = null;
            }
            continue;
        }

        dest[cp] = prop;
    }
}

fn applyTerminalPolicyOverridesOverrides(dest: []Working) void {
    for (terminal_zero_width_overrides) |range| {
        fillRange(dest, range[0], range[1], .zero);
    }
}
fn applyDefaultDoubleRangeOverrides(dest: []Working) void {
    for (default_wide_ranges) |range| {
        for (range[0]..range[1] + 1) |cp| {
            if (dest[cp] == .unclassified) dest[cp] = .wide;
        }
    }
}

fn stripComment(line: []const u8) []const u8 {
    const hash = mem.indexOfScalar(u8, line, '#') orelse line.len;
    return mem.trim(u8, line[0..hash], " \t\r");
}

fn classify(bytes: []const u8) Working {
    if (mem.eql(u8, bytes, "Cc")) return .control;
    if (mem.eql(u8, bytes, "Mn")) return .zero;
    if (mem.eql(u8, bytes, "Me")) return .zero;
    if (mem.eql(u8, bytes, "Cf")) return .zero;
    return .narrow;
}

fn fillRange(props: []Working, start: u21, end: u21, prop: Working) void {
    var cp = start;
    while (cp <= end) : (cp += 1) props[cp] = prop;
}

const Entry = struct {
    codepoint: u21,
    size: u32, // actual run length, split to <= 256 before packing
    property: Property,
};

fn buildEntries(gpa: mem.Allocator, properties: []const Property) ![]const Entry {
    var entries: std.ArrayList(Entry) = .empty;

    var i: usize = 0;
    while (i < properties.len) {
        const prop = properties[i];
        var j = i + 1;
        while (j < properties.len and properties[j] == prop and (j - i) < 256) : (j += 1) {}

        // Skip single-cell runs entirely, .narrow is the implicit default
        // for any codepoint not covered by an entry.
        if (prop != .narrow) {
            try entries.append(gpa, .{
                .codepoint = @intCast(i),
                .size = @intCast(j - i),
                .property = prop,
            });
        }
        i = j;
    }

    return entries.items;
}

fn writeOutput(w: *std.Io.Writer, entries: []const Entry) !void {
    try w.writeAll(
        \\//! Terminal width policy:
        \\//!
        \\//! This project derives terminal-cell width from Unicode Character Database
        \\//! properties, with a small number of explicit terminal-policy overrides.
        \\//!
        \\//! Policy:
        \\//!   General_Category Cc              -> .control
        \\//!   General_Category Mn, Me, Cf      -> .zero
        \\//!   East_Asian_Width W or F          -> .wide
        \\//!   East_Asian_Width A               -> .ambiguous
        \\//!   Assigned characters otherwise   -> .narrow
        \\//!   Unassigned characters (Cn)      -> .control
        \\//!   Noncharacters                   -> .control
        \\//!   Surrogates                      -> .control
        \\//!
        \\//! Terminal-policy overrides:
        \\//!   U+1160..U+11FF -> .zero
        \\//!
        \\//! The UCD does not define POSIX wcwidth() results directly. East_Asian_Width
        \\//! is a Unicode character property intended primarily for East Asian legacy
        \\//! character-set interoperability and typography. Terminal emulators may
        \\//! tailor width behavior for their environment.
        \\//!
        \\//! This generator therefore implements this project's explicit terminal
        \\//! width policy from UCD data. It does not attempt to reproduce glibc or
        \\//! musl wcwidth() bit-for-bit.
        \\//!
        \\//! glibc and musl may be used by tests as secondary compatibility oracles,
        \\//! but disagreement with either implementation is not by itself an error.
        \\
        \\pub const Property = enum(u3) {
        \\    narrow = 0,
        \\    wide = 1,
        \\    ambiguous = 2,
        \\    zero = 3,
        \\    control = 4,
        \\};
        \\
        \\/// Packed range entry: bits [0,3) property, bits [3,11) size-1,
        \\/// bits [11,32) lower-bound codepoint.
        \\pub const entries = [_]u32{
        \\
    );

    for (entries) |e| {
        std.debug.assert(e.size >= 1 and e.size <= 256);
        const packed_value: u32 =
            (@as(u32, @intFromEnum(e.property))) |
            (@as(u32, e.size - 1) << 3) |
            (@as(u32, e.codepoint) << 11);
        try w.print("    0x{X:0>8},\n", .{packed_value});
    }

    try w.writeAll("};\n");
}
