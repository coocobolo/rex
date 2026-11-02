//! Generates unified_wcwidth_table.zig from Unicode Character Database data:
//! UnicodeData.txt and EastAsianWidth.txt.
//!
//! This generator uses data from the Unicode Character Database.
//! See THIRD_PARTY_NOTICES/unicode.license.txt for the applicable Unicode license terms.
//!
//! Unicode version: 17.0.0
//!
//! Usage:
//!   zig run tools/gen_unified_wcwidth_table.zig -- \
//!       <EastAsianWidth.txt> <UnicodeData.txt> <output.zig>
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
//! This file is NOT wired into build.zig. Run it by hand whenever the
//! vendored Unicode version needs to be bumped, and commit the generated
//! table file.

const std = @import("std");
const mem = std.mem;
const fmt = std.fmt;

const Property = enum(u3) {
    single = 0,
    double = 1,
    ambiguous = 2,
    zero = 3,
    control = 4,
};

const Working = enum {
    unclassified,
    single,
    double,
    ambiguous,
    zero,
    control,
};

const max_codepoint: u21 = 0x10ffff;
const table_len: usize = @as(usize, max_codepoint) + 1;

// Unicode's documented defaults for unassigned code points in these blocks
// (see EastAsianWidth.txt header comments) the default to Wide even before
// any assigned character is listed explicitly.
const default_double_ranges = [_][2]u21{
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

fn printUsage() void {
    std.debug.print(
        \\Usage:
        \\  zig run tools/gen_unified_wcwidth_table.zig -- \
        \\      <EastAsianWidth.txt> <UnicodeData.txt> <output.zig>
        \\
        \\Generates unified_wcwidth_table.zig from Unicode Character Database data.
        \\
        \\Arguments:
        \\  <EastAsianWidth.txt>  Unicode East Asian Width data
        \\  <UnicodeData.txt>     Unicode character property data
        \\  <output.zig>          Generated Zig source file
        \\
    , .{});
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var arena = init.arena.allocator();

    var args_it = init.minimal.args.iterate();
    if (args_it.inner.remaining.len < 4) {
        printUsage();
        std.process.exit(1);
    }

    // Skip the executable name.
    _ = args_it.next() orelse unreachable;

    const eaw_path = args_it.next() orelse unreachable;
    const udata_path = args_it.next() orelse unreachable;
    const out_path = args_it.next() orelse unreachable;

    // eaw_path, udata_path, and out_path are sentinel-terminated slices
    // and can generally be passed directly to file APIs.

    std.debug.print("eaw_path: {s}\n", .{eaw_path});
    std.debug.print("udata_path: {s}\n", .{udata_path});
    std.debug.print("out_path: {s}\n", .{out_path});

    const working = try arena.alloc(Working, table_len);
    @memset(working, .unclassified);

    try applyUnicodeData(io, arena, working, udata_path);
    std.debug.print(
        "AFTER UnicodeData: U+1421D = {t}\n",
        .{working[0x1421D]},
    );
    try applyEastAsianWidth(io, arena, working, eaw_path);
    std.debug.print(
        "AFTER EAW: U+1421D = {t}\n",
        .{working[0x1421D]},
    );

    applyDefaultDoubleRangeOverrides(working);
    applyTerminalPolicyOverridesOverrides(working);

    std.debug.print(
        "FINAL: U+1421D = {t}\n",
        .{working[0x1421D]},
    );

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
            .single => .single,
            .double => .double,
            .ambiguous => .ambiguous,
            .zero => .zero,
            .control => .control,
        };
    }
    const entries = try buildEntries(arena, properties);
    try writeOutput(io, entries, out_path);
}

fn applyEastAsianWidth(io: std.Io, gpa: mem.Allocator, dest: []Working, path: []const u8) !void {
    const content = blk: {
        const file = try std.Io.Dir.openFile(.cwd(), io, path, .{ .mode = .read_only });
        defer file.close(io);
        const file_len = try file.length(io);
        std.debug.print("reading: file '{s}' size: {}\n", .{ path, file_len });
        const buffer = try gpa.alloc(u8, file_len);
        const n = try file.readPositionalAll(io, buffer, 0);
        if (n != file_len) return error.FileSizeMismatched;
        break :blk buffer;
    };
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
                .double
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

        // std.debug.print("prop: {t}, cp: 0x{x}, start: 0x{x}..0x{x}\n", .{ prop, cp, start, end });

        // Promote only characters that currently have the default terminal
        // width of one cell. Never overwrite zero/control classifications.
        var cp = start;
        while (cp <= end) : (cp += 1) {
            if (dest[cp] == .single) dest[cp] = prop;
        }
    }
}

fn applyUnicodeData(io: std.Io, gpa: mem.Allocator, dest: []Working, path: []const u8) !void {
    const content = blk: {
        const file = try std.Io.Dir.openFile(.cwd(), io, path, .{ .mode = .read_only });
        defer file.close(io);
        const file_len = try file.length(io);
        std.debug.print("reading: file '{s}' size: {}\n", .{ path, file_len });
        const buffer = try gpa.alloc(u8, file_len);
        const n = try file.readPositionalAll(io, buffer, 0);
        if (n != file_len) return error.FileSizeMismatched;
        break :blk buffer;
    };
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

        // std.debug.print("cp=0x{x}, name='{s}', category='{s}'\n", .{ cp, fields[1], category });

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

        // std.debug.print("prop={t}, cp=0x{x}, start=0x{?}, end=0x{}\n", .{ prop, cp, pending_first, cp });
        dest[cp] = prop;
    }
}

fn applyTerminalPolicyOverridesOverrides(dest: []Working) void {
    for (terminal_zero_width_overrides) |range| {
        fillRange(dest, range[0], range[1], .zero);
    }
}
fn applyDefaultDoubleRangeOverrides(dest: []Working) void {
    for (default_double_ranges) |range| {
        for (range[0]..range[1] + 1) |cp| {
            if (dest[cp] == .unclassified) dest[cp] = .double;
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
    return .single;
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

        // Skip single-cell runs entirely, .single is the implicit default
        // for any codepoint not covered by an entry.
        if (prop != .single) {
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

pub fn writeOutput(io: std.Io, entries: []const Entry, path: []const u8) !void {
    const file = try std.Io.Dir.createFile(.cwd(), io, path, .{ .truncate = true });
    defer file.close(io);

    var buffer: [4096]u8 = undefined;
    var fwriter = file.writer(io, &buffer);
    const w = &fwriter.interface;

    try w.writeAll(
        \\//! This file is auto-generated by tools/gen_unified_wcwidth_table.zig.
        \\//! DO NOT EDIT DIRECTLY. Regenerate from EastAsianWidth.txt and
        \\//! UnicodeData.txt for the desired Unicode version instead.
        \\//!
        \\//! Terminal width policy:
        \\//!
        \\//! This project derives terminal-cell width from Unicode Character Database
        \\//! properties, with a small number of explicit terminal-policy overrides.
        \\//!
        \\//! Unicode version: 17.0.0
        \\//!
        \\//! Policy:
        \\//!   General_Category Cc              -> .control
        \\//!   General_Category Mn, Me, Cf      -> .zero
        \\//!   East_Asian_Width W or F          -> .double
        \\//!   East_Asian_Width A               -> .ambiguous
        \\//!   Assigned characters otherwise   -> .single
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
        \\    single = 0,
        \\    double = 1,
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
        try w.print("   0x{X:0>8},\n", .{packed_value});
    }

    try w.writeAll(
        \\};  
    );

    try w.flush();
    std.debug.print(
        "wrote {d} entries ({d} bytes) to {s}\n",
        .{ entries.len, entries.len * 4, path },
    );
}

pub fn writeTestOutput(io: std.Io, properties: []const Property, tables_path: []const u8, path: []const u8) !void {
    const file = try std.Io.Dir.createFile(.cwd(), io, path, .{ .truncate = true });
    defer file.close(io);

    var buffer: [4096]u8 = undefined;
    var fwriter = file.writer(io, &buffer);
    const w = &fwriter.interface;

    try w.writeAll(
        \\//! This file is auto-generated by tools/gen_unified_wcwidth_table.zig.
        \\//! DO NOT EDIT DIRECTLY. Regenerate from EastAsianWidth.txt and
        \\//! UnicodeData.txt for the desired Unicode version instead.
        \\
    );

    try w.print("const Property = @import(\"{s}\").Property;\n\n", .{tables_path});

    try w.writeAll(
        \\/// Flat, one-entry-per-codepoint property table (0x0..0x10FFFF),
        \\/// used ONLY for exhaustive self-consistency testing of lookup's
        \\/// binary-search-over-packed-ranges logic against this ground-truth
        \\/// array. Not intended for production use (much larger than \\/// entries).
        \\pub const flat_properties_for_testing = [_]Property{
        \\
    );

    for (properties) |p| {
        try w.print("   .{s},\n", .{@tagName(p)});
    }
    try w.writeAll("};\n");

    try w.flush();
    std.debug.print(
        "wrote test {} flat properties table ({d} bytes) to {s}\n",
        .{ properties.len, properties.len * 4, path },
    );
}

// One property slot per code point. This is ~1.1MB transient memory,
// fine for a one-shot codegen tool.
// Default: unassigned/unclassified = non-printable
// const properties = try arena.alloc(Property, table_len);
// @memset(properties, .control);
//
// try applyEastAsianWidth(io, arena, properties, eaw_path);
// for (default_wide_ranges) |range| {
//     for (range[0]..range[1] + 1) |cp| {
//         if (properties[cp] == .control) properties[cp] = .wide;
//     }
// }
//
// try applyUnicodeData(io, arena, properties, udata_path);
//
// applyKuhnOverrides(properties);
//
// // Noncharacters (U+xFFFE, U+xFFFF in every plane, and U+FDD0..U+FDEF)
// // are never printable; treat like musl's -1 case.
// {
//     var plane: u21 = 0;
//     while (plane <= 0x10) : (plane += 1) {
//         const base = plane * 0x10000;
//         properties[base + 0xFFFE] = .control;
//         properties[base + 0xFFFF] = .control;
//     }
//     for (0xFDD0..0xFDEF + 1) |cp| properties[cp] = .control;
// }
// // Surrogates are not valid scalar values but the table must still
// // cover the full 21-bit domain; mark them .control defensively.
// for (0xD800..0xDFFF + 1) |cp| properties[cp] = .control;
//
// const entries = try buildEntries(arena, properties);
// // std.debug.print("entries.items: {any} | len={}\n", .{ entries, entries.len });
// try writeOutput(io, entries, out_path);

// optionals: write flat_properties for testing
// const dot = mem.lastIndexOfScalar(u8, out_path, '.') orelse out_path.len;
// const stem = out_path[0..dot];
// const extension = out_path[dot..];
//
// const test_out_path = try fmt.allocPrint(
//     arena,
//     "{s}_test{s}",
//     .{ stem, extension },
// );
// try writeTestOutput(io, properties, std.fs.path.basename(out_path), test_out_path);