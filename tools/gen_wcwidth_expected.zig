//! Generates src/unicode/wcwidth_expected.zig, the oracle that
//! wcwidth_v2_test.zig checks wcwidth_table.zig against.
//!
//! It is derived from different UCD files than tools/
//! gen_unified_wcwidth_table.zig (DerivedGeneralCategory.txt instead of
//! UnicodeData.txt, plus emoji-data.txt), so a bug in one generator shows
//! up as a disagreement instead of being copied into both.
//!
//! This generator uses data from the Unicode Character Database.
//! See THIRD_PARTY_NOTICES/unicode.license.txt for the license terms.
//!
//! Usage (writes the Zig source to stdout):
//!   zig build gen-wcwidth
//!   zig run tools/gen_wcwidth_expected.zig -- \
//!       <DerivedGeneralCategory.txt> <EastAsianWidth.txt> <emoji-data.txt>
//!
//! Rules, applied in order:
//!   General_Category Cc, Cs, Cn            control
//!   General_Category Mn, Me, Cf            zero
//!   any other General_Category             narrow
//!   East_Asian_Width W or F (narrow only)  wide
//!   East_Asian_Width A (narrow only)       ambiguous
//!   Cn in the default-Wide blocks          wide
//!   Emoji_Presentation (narrow only)       wide
//!   U+1160..U+11FF (Hangul medial/final)   zero

const std = @import("std");
const mem = std.mem;

const Class = enum { control, zero, narrow, wide, ambiguous };

const table_len = 0x110000;

/// Blocks whose unassigned code points default to East_Asian_Width W
/// (see the EastAsianWidth.txt header).
const default_wide_ranges = [_][2]u21{
    .{ 0x3400, 0x4DBF },
    .{ 0x4E00, 0x9FFF },
    .{ 0xF900, 0xFAFF },
    .{ 0x20000, 0x2FFFD },
    .{ 0x30000, 0x3FFFD },
};

/// One parsed `first..last ; value` line.
const Line = struct { first: u21, last: u21, value: []const u8 };

fn parseLine(raw: []const u8) !?Line {
    const hash = mem.indexOfScalar(u8, raw, '#') orelse raw.len;
    const line = mem.trim(u8, raw[0..hash], " \t\r");
    if (line.len == 0) return null;
    const semi = mem.indexOfScalar(u8, line, ';') orelse return null;
    const cps = mem.trim(u8, line[0..semi], " \t");
    const value = mem.trim(u8, line[semi + 1 ..], " \t");
    if (mem.indexOf(u8, cps, "..")) |dots| return .{
        .first = try std.fmt.parseInt(u21, cps[0..dots], 16),
        .last = try std.fmt.parseInt(u21, cps[dots + 2 ..], 16),
        .value = value,
    };
    const cp = try std.fmt.parseInt(u21, cps, 16);
    return .{ .first = cp, .last = cp, .value = value };
}

fn readFile(io: std.Io, gpa: mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.Io.Dir.openFile(.cwd(), io, path, .{ .mode = .read_only });
    defer file.close(io);
    const len = try file.length(io);
    const buf = try gpa.alloc(u8, len);
    if (try file.readPositionalAll(io, buf, 0) != len) return error.ShortRead;
    return buf;
}

fn isAny(value: []const u8, comptime names: []const []const u8) bool {
    inline for (names) |n| if (mem.eql(u8, value, n)) return true;
    return false;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    var args = init.minimal.args.iterate();
    _ = args.skip();
    const gc_path = args.next() orelse return usage();
    const eaw_path = args.next() orelse return usage();
    const emoji_path = args.next() orelse return usage();

    const class = try arena.alloc(Class, table_len);
    const unassigned = try arena.alloc(bool, table_len);
    @memset(class, .narrow);
    @memset(unassigned, false);

    const gc = try readFile(io, arena, gc_path);
    var it = mem.splitScalar(u8, gc, '\n');
    while (it.next()) |raw| {
        const l = (try parseLine(raw)) orelse continue;
        const c: Class = if (isAny(l.value, &.{ "Cc", "Cs", "Cn" }))
            .control
        else if (isAny(l.value, &.{ "Mn", "Me", "Cf" }))
            .zero
        else
            .narrow;
        @memset(class[l.first .. @as(usize, l.last) + 1], c);
        if (mem.eql(u8, l.value, "Cn")) @memset(unassigned[l.first .. @as(usize, l.last) + 1], true);
    }

    const eaw = try readFile(io, arena, eaw_path);
    const version = blk: {
        // First line: "# EastAsianWidth-17.0.0.txt".
        const first = eaw[0 .. mem.indexOfScalar(u8, eaw, '\n') orelse eaw.len];
        const dash = mem.indexOfScalar(u8, first, '-') orelse break :blk "unknown";
        const dot_txt = mem.lastIndexOf(u8, first, ".txt") orelse break :blk "unknown";
        break :blk first[dash + 1 .. dot_txt];
    };
    it = mem.splitScalar(u8, eaw, '\n');
    while (it.next()) |raw| {
        const l = (try parseLine(raw)) orelse continue;
        const c: Class = if (isAny(l.value, &.{ "W", "F" }))
            .wide
        else if (mem.eql(u8, l.value, "A"))
            .ambiguous
        else
            continue;
        for (l.first..@as(usize, l.last) + 1) |cp| {
            if (class[cp] == .narrow) class[cp] = c;
        }
    }

    for (default_wide_ranges) |r| {
        for (r[0]..@as(usize, r[1]) + 1) |cp| {
            if (unassigned[cp]) class[cp] = .wide;
        }
    }

    const emoji = try readFile(io, arena, emoji_path);
    it = mem.splitScalar(u8, emoji, '\n');
    while (it.next()) |raw| {
        const l = (try parseLine(raw)) orelse continue;
        if (!mem.eql(u8, l.value, "Emoji_Presentation")) continue;
        for (l.first..@as(usize, l.last) + 1) |cp| {
            if (class[cp] == .narrow) class[cp] = .wide;
        }
    }

    @memset(class[0x1160..0x1200], .zero);

    var buf: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buf);
    const w = &writer.interface;
    try w.print(
        \\//! Expected terminal width class of every code point, generated
        \\//! from the UCD independently of wcwidth_table.zig. It is the oracle
        \\//! for wcwidth_v2_test.zig; see tools/gen_wcwidth_expected.zig for
        \\//! the rules.
        \\//!
        \\//! DO NOT EDIT. Regenerate with `zig build gen-wcwidth`.
        \\//! Unicode version: {s} (DerivedGeneralCategory.txt,
        \\//! EastAsianWidth.txt, emoji-data.txt).
        \\
        \\/// Width class before the ambiguous-width policy is applied.
        \\pub const Class = enum {{ control, zero, narrow, wide, ambiguous }};
        \\
        \\/// An inclusive code point range with one class.
        \\pub const Range = struct {{ first: u21, last: u21, class: Class }};
        \\
        \\/// Sorted, contiguous ranges covering U+0000..U+10FFFF.
        \\pub const ranges = [_]Range{{
        \\
    , .{version});
    var start: usize = 0;
    for (1..table_len + 1) |cp| {
        if (cp < table_len and class[cp] == class[start]) continue;
        try w.print("    .{{ .first = 0x{X:0>4}, .last = 0x{X:0>4}, .class = .{t} }},\n", .{ start, cp - 1, class[start] });
        start = cp;
    }
    try w.writeAll(
        \\};
        \\
        \\/// Returns the class of `cp`, which must be at most U+10FFFF.
        \\pub fn classOf(cp: u21) Class {
        \\    var lo: usize = 0;
        \\    var hi: usize = ranges.len;
        \\    while (lo < hi) {
        \\        const mid = lo + (hi - lo) / 2;
        \\        if (ranges[mid].last < cp) lo = mid + 1 else hi = mid;
        \\    }
        \\    return ranges[lo].class;
        \\}
        \\
    );
    try w.flush();
}

fn usage() void {
    std.debug.print(
        "usage: gen_wcwidth_expected <DerivedGeneralCategory.txt> <EastAsianWidth.txt> <emoji-data.txt>\n",
        .{},
    );
    std.process.exit(1);
}
