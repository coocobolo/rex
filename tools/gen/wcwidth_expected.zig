//! `zig build gen-wcwidth-expected`: src/unicode/wcwidth_expected.zig,
//! the oracle that wcwidth_test.zig checks wcwidth_table.zig against.
//!
//! It is derived from different UCD files than tools/gen/
//! wcwidth_table.zig (DerivedGeneralCategory.txt instead of
//! UnicodeData.txt, plus emoji-data.txt), so a bug in one generator shows
//! up as a disagreement instead of being copied into both.
//!
//! This generator uses data from the Unicode Character Database.
//! See THIRD_PARTY_NOTICES/unicode.license.txt for the license terms.
//!
//! Usage: wcwidth_expected <out.zig> <DerivedGeneralCategory.txt> <EastAsianWidth.txt>
//!        <emoji-data.txt>
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
const ucd = @import("ucd.zig");

const gen_name = "wcwidth-expected";
const usage_args = "<out.zig> <DerivedGeneralCategory.txt> <EastAsianWidth.txt> <emoji-data.txt>";

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

fn isAny(value: []const u8, comptime names: []const []const u8) bool {
    inline for (names) |n| if (mem.eql(u8, value, n)) return true;
    return false;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    var args = init.minimal.args.iterate();
    _ = args.skip(); // argv[0]
    const out_path = args.next() orelse ucd.usage(gen_name, usage_args);
    const gc_path = args.next() orelse ucd.usage(gen_name, usage_args);
    const eaw_path = args.next() orelse ucd.usage(gen_name, usage_args);
    const emoji_path = args.next() orelse ucd.usage(gen_name, usage_args);

    const class = try arena.alloc(Class, table_len);
    const unassigned = try arena.alloc(bool, table_len);
    @memset(class, .narrow);
    @memset(unassigned, false);

    const gc = try ucd.readFile(io, arena, gen_name, gc_path);
    var it = mem.splitScalar(u8, gc, '\n');
    while (it.next()) |raw| {
        const l = (try ucd.parseLine(raw)) orelse continue;
        const c: Class = if (isAny(l.value, &.{ "Cc", "Cs", "Cn" }))
            .control
        else if (isAny(l.value, &.{ "Mn", "Me", "Cf" }))
            .zero
        else
            .narrow;
        @memset(class[l.first .. @as(usize, l.last) + 1], c);
        if (mem.eql(u8, l.value, "Cn")) @memset(unassigned[l.first .. @as(usize, l.last) + 1], true);
    }

    const eaw = try ucd.readFile(io, arena, gen_name, eaw_path);
    it = mem.splitScalar(u8, eaw, '\n');
    while (it.next()) |raw| {
        const l = (try ucd.parseLine(raw)) orelse continue;
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

    const emoji = try ucd.readFile(io, arena, gen_name, emoji_path);
    it = mem.splitScalar(u8, emoji, '\n');
    while (it.next()) |raw| {
        const l = (try ucd.parseLine(raw)) orelse continue;
        if (!mem.eql(u8, l.value, "Emoji_Presentation")) continue;
        for (l.first..@as(usize, l.last) + 1) |cp| {
            if (class[cp] == .narrow) class[cp] = .wide;
        }
    }

    @memset(class[0x1160..0x1200], .zero);

    var buf: [4096]u8 = undefined;
    var writer = (try ucd.createFile(io, out_path)).writer(io, &buf);
    const w = &writer.interface;
    try ucd.writeHeader(w, gen_name, "UCD {s}", .{ucd.versionOf(eaw_path)});
    try w.print(
        \\//! Expected terminal width class of every code point, generated
        \\//! from the UCD independently of wcwidth_table.zig. It is the oracle
        \\//! for wcwidth_test.zig; see tools/gen/wcwidth_expected.zig for
        \\//! the rules.
        \\//!
        \\//! Sources: DerivedGeneralCategory.txt, EastAsianWidth.txt,
        \\//! emoji-data.txt.
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
    , .{});
    var start: usize = 0;
    var count: usize = 0;
    for (1..table_len + 1) |cp| {
        if (cp < table_len and class[cp] == class[start]) continue;
        try w.print("    .{{ .first = 0x{X:0>4}, .last = 0x{X:0>4}, .class = .{t} }},\n", .{ start, cp - 1, class[start] });
        start = cp;
        count += 1;
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
    ucd.log(gen_name, "wrote {s}: {d} ranges", .{ std.fs.path.basename(out_path), count });
}
