//! `zig build gen-grapheme-table`: src/term/grapheme_table.zig from
//! GraphemeBreakProperty.txt and emoji-data.txt.
//!
//! Usage: grapheme_table <out.zig> <GraphemeBreakProperty.txt> <emoji-data.txt>
//!
//! This generator uses data from the Unicode Character Database.
//! See THIRD_PARTY_NOTICES/unicode.license.txt for the applicable Unicode license terms.
//!
//! Unicode version: 17.0.0
//!
//! Data sources:
//! - [ucd/auxiliary/GraphemeBreakProperty.txt](https://www.unicode.org/Public/UCD/17.0.0/ucd/auxiliary/GraphemeBreakProperty.txt)
//! - [ucd/emoji/emoji-data.txt](https://www.unicode.org/Public/UCD/17.0.0/ucd/emoji/emoji-data.txt)
//!
//!
//! Encoding is compatible with libc++'s extended_grapheme_cluster_table.h:
//! - bits [0,3]   = property enum value
//! - bits [4,10]  = range size (hi - lo; maximum 127 per entry)
//! - bits [11,31] = lower-bound code point
//!
//! Reference implementation:
//!     https://github.com/ziglang/zig/blob/738d2be9/lib/libcxx/include/__format/extended_grapheme_cluster_table.h#L107-L112

const std = @import("std");
const ucd = @import("ucd.zig");

const gen_name = "grapheme-table";
const usage_args = "<out.zig> <GraphemeBreakProperty.txt> <emoji-data.txt>";

/// Grapheme cluster break properties (Unicode TR29).
/// Enum value must match the bit encoding in entries. DO NOT REORDER.
pub const Property = enum(u4) {
    cr = 0,
    control = 1,
    extend = 2,
    extended_pictographic = 3,
    l = 4,
    lf = 5,
    lv = 6,
    lvt = 7,
    prepend = 8,
    regional_indicator = 9,
    spacing_mark = 10,
    t = 11,
    v = 12,
    /// Zero Width Joiner
    zwj = 13,
};

const Range = struct {
    lo: u21,
    hi: u21,
    prop: Property,
};

fn parseProperty(name: []const u8) ?Property {
    const map = .{
        .{ "CR", Property.cr },
        .{ "Control", Property.control },
        .{ "Extend", Property.extend },
        .{ "Extended_Pictographic", Property.extended_pictographic },
        .{ "L", Property.l },
        .{ "LF", Property.lf },
        .{ "LV", Property.lv },
        .{ "LVT", Property.lvt },
        .{ "Prepend", Property.prepend },
        .{ "Regional_Indicator", Property.regional_indicator },
        .{ "SpacingMark", Property.spacing_mark },
        .{ "T", Property.t },
        .{ "V", Property.v },
        .{ "ZWJ", Property.zwj },
    };

    inline for (map) |e| if (std.mem.eql(u8, name, e[0])) return e[1];

    // unknown / not needed (e.g. Emoji, Emoji_Modifier, etc.)
    return null;
}

/// Parse one data file (GraphemeBreakProperty.txt or emoji-data.txt).
///
/// Lines look like;
/// 000E..001F    ; Control # Cc  [18] <control-000E>..<control-001F>
/// 007F..009F    ; Control # Cc  [33] <control-007F>..<control-009F>
///
/// Unknown property names are silently skipped.
pub fn parseFile(data: []const u8, gpa: std.mem.Allocator, ranges: *std.ArrayList(Range)) !usize {
    const before = ranges.items.len;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        // Strip comment
        const no_comment = if (std.mem.indexOfScalar(u8, line, '#')) |i| line[0..i] else line;
        const trimmed = std.mem.trim(u8, no_comment, " \t\r");
        if (trimmed.len == 0) continue;

        // split on ';'
        var parts = std.mem.splitScalar(u8, trimmed, ';');
        const range_str = std.mem.trim(u8, parts.next() orelse continue, " \t");
        const prop_str = std.mem.trim(u8, parts.next() orelse continue, " \t");

        const prop = parseProperty(prop_str) orelse continue;

        // Parse "XXXX" or "XXXX..YYYY"
        var lo: u21 = undefined;
        var hi: u21 = undefined;
        if (std.mem.indexOf(u8, range_str, "..")) |dot| {
            lo = std.math.cast(u21, try std.fmt.parseInt(u32, range_str[0..dot], 16)) orelse continue;
            hi = std.math.cast(u21, try std.fmt.parseInt(u32, range_str[dot + 2 ..], 16)) orelse continue;
        } else {
            lo = std.math.cast(u21, try std.fmt.parseInt(u32, range_str, 16)) orelse continue;
            hi = lo;
        }

        if (lo > hi) continue;
        try ranges.append(gpa, .{ .hi = hi, .lo = lo, .prop = prop });
    }

    return ranges.items.len - before;
}

/// Pack sorted ranges into the libcxx u32 entry format.
/// Ranges wider than 127 are split into consecutive entries.
fn packEntries(gpa: std.mem.Allocator, ranges: []const Range, out: *std.ArrayList(u32)) !void {
    for (ranges) |r| {
        var lo: u32 = r.lo;
        const hi: u32 = r.hi;
        while (lo <= hi) {
            const size: u32 = @min(hi - lo, 127);
            // bits [11,31] = lo
            // bits [4,10]  = size
            // bits [0,3]   = prop
            try out.append(gpa, (lo << 11) | (size << 4) | @intFromEnum(r.prop));
            lo += size + 1;
        }
    }
}

fn emitTable(w: *std.Io.Writer, entry_count: usize, entries: []const u32) !void {
    try w.writeAll(
        \\//! Grapheme Cluster Break property table.
        \\//! The data is derived from the Unicode Character Database (UCD).
        \\//! See THIRD_PARTY_NOTICES/unicode.license.txt for the applicable
        \\//! Unicode license terms.
        \\//!
        \\//! Unicode version: 17.0.0
        \\//!
        \\//! Data sources:
        \\//!   https://www.unicode.org/Public/UCD/17.0.0/ucd/auxiliary/GraphemeBreakProperty.txt
        \\//!   https://www.unicode.org/Public/UCD/17.0.0/ucd/emoji/emoji-data.txt
        \\//!
        \\//! Encoding is compatible with libc++'s
        \\//! extended_grapheme_cluster_table.h:
        \\//!   bits [0,3]   = property enum value
        \\//!   bits [4,10]  = range size (hi - lo; max. 127 per entry)
        \\//!   bits [11,31] = lower-bound code point
        \\
        \\/// Grapheme cluster break property (Unicode TR29 §3).
        \\/// Values are encoded in the low 4 bits of each table entry; DO NOT REORDER.
        \\pub const Property = enum(u4) {
        \\    cr = 0,
        \\    control = 1,
        \\    extend = 2,
        \\    extended_pictographic = 3,
        \\    l = 4,
        \\    lf = 5,
        \\    lv = 6,
        \\    lvt = 7,
        \\    prepend = 8,
        \\    regional_indicator = 9,
        \\    spacing_mark = 10,
        \\    t = 11,
        \\    v = 12,
        \\    zwj = 13,
        \\    /// Code point has no special grapheme break property.
        \\    none = 14,
        \\};
        \\
    );

    try w.print("\npub const entries: [{}]u32 = .{{\n", .{entry_count});
    for (entries) |e| try w.print("    0x{x:0>8},\n", .{e});
    try w.writeAll("};\n\n");

    // Emit the lookup function upper-bound binary search, same algorithm as
    // libcxx __extended_grapheme_custer_property_boundary::__get_property.
    try w.writeAll(
        \\/// Returns the grapheme cluster break property of a Unicode code point.
        \\/// Returns `.none` if the code point has no special property.
        \\pub fn getProperty(cp: u21) ?Property {
        \\    // ASCII printable: no grapheme break property.
        \\    // The parser handles CR/LF/control before they reach here.
        \\    if (cp >= 0x20 and cp < 0x7F) return null;
        \\
        \\    // Upper-bound search: find the first entry whose lower bound > cp.
        \\    // Setting the low 11 bits ensures we land *after* any entry whose
        \\    // lower bound equals cp (matching the libcxx trick).
        \\    const key: u32 = (@as(u32, cp) << 11) | 0x7ff;
        \\    var lo: usize = 0;
        \\    var hi: usize = entries.len;
        \\    while (lo < hi) {
        \\        const mid = lo + (hi - lo) / 2;
        \\        if (entries[mid] <= key) lo = mid + 1 else hi = mid;
        \\    }
        \\    if (lo == 0) return .none;
        \\    const e = entries[lo - 1];
        \\    const range_lo: u32 = e >> 11;
        \\    const range_size: u32 = (e >> 4) & 0x7f;
        \\    if (cp >= range_lo and cp <= range_lo + range_size) {
        \\        return @enumFromInt(e & 0xf);
        \\    }
        \\
        \\    return null;
        \\}
        \\
    );
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var args = init.minimal.args.iterate();
    _ = args.skip(); // argv[0]
    const out_path = args.next() orelse ucd.usage(gen_name, usage_args);
    var paths: [2][]const u8 = undefined;
    for (&paths) |*p| p.* = args.next() orelse ucd.usage(gen_name, usage_args);

    var ranges: std.ArrayList(Range) = try .initCapacity(gpa, 69);
    defer ranges.deinit(gpa);

    for (paths) |path| {
        const data = try ucd.readFile(io, gpa, gen_name, path);
        defer gpa.free(data);
        const added = try parseFile(data, gpa, &ranges);
        ucd.log(gen_name, "{s}: {d} ranges (total {d})", .{ path, added, ranges.items.len });
    }
    if (ranges.items.len == 0) return error.NoRanges;

    // Sort by lower bound so the binary search works.
    std.mem.sort(Range, ranges.items, {}, struct {
        fn lt(_: void, a: Range, b: Range) bool {
            return a.lo < b.lo;
        }
    }.lt);

    // Pack into u32 entries (split ranges > 127 wide into consecutive entries).
    var packed_entries: std.ArrayList(u32) = try .initCapacity(gpa, 69);
    defer packed_entries.deinit(gpa);
    try packEntries(gpa, ranges.items, &packed_entries);

    var stdout_buf: [8192]u8 = undefined;
    var stdout_writer = (try ucd.createFile(io, out_path)).writer(io, &stdout_buf);
    const w = &stdout_writer.interface;
    try ucd.writeHeader(w, gen_name, "UCD {s}", .{ucd.versionOf(paths[0])});
    try emitTable(w, packed_entries.items.len, packed_entries.items);
    try w.flush();
    ucd.log(gen_name, "wrote {s}: {d} entries", .{ std.fs.path.basename(out_path), packed_entries.items.len });
}
