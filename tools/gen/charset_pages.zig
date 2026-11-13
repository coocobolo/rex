//! `zig build gen-charset-pages`: src/term/charset_pages.zig from xterm's
//! charsets.h.
//!
//! Usage: charset_pages <out.zig> <charsets.h>
//!
//! Each page is one xterm `map_*` macro: the code point every GL code
//! 0x20..0x7F prints as. A code the macro does not list keeps the value
//! xterm's caller passes, the 7-bit code or, for DEC Supplemental and
//! Latin-1, the 8-bit one. `UNI` and `XXX` entries count as mappings,
//! as they do in xterm's wide-character output path.
//!
//! See THIRD_PARTY_NOTICES/xterm-charsets.h.COPYING for the upstream
//! revision and license.

const std = @import("std");
const mem = std.mem;
const ucd = @import("ucd.zig");

const gen_name = "charset-pages";
const usage_args = "<out.zig> <charsets.h>";

/// What a GL code the macro does not list becomes.
const Fallback = enum { seven, eight };

/// A 94-set has no space (0x20) or DEL (0x7F); they stay themselves.
const Size = enum { set94, set96 };

/// One output page: its name in charset_pages.zig and the xterm macro
/// (`map_<macro>`) it comes from.
const Table = struct {
    name: []const u8,
    macro: []const u8,
    size: Size = .set94,
    fallback: Fallback = .seven,
};

const tables = [_]Table{
    .{ .name = "dec_special", .macro = "DEC_Spec_Graphic" },
    .{ .name = "dec_suppl", .macro = "DEC_Supp_Graphic", .fallback = .eight },
    .{ .name = "iso_latin1", .macro = "ISO_Latin_1", .size = .set96, .fallback = .eight },
    .{ .name = "dutch", .macro = "NRCS_Dutch" },
    .{ .name = "finnish", .macro = "NRCS_Finnish" },
    .{ .name = "french", .macro = "NRCS_French" },
    .{ .name = "french_ca", .macro = "NRCS_French_Canadian" },
    .{ .name = "german", .macro = "NRCS_German" },
    .{ .name = "italian", .macro = "NRCS_Italian" },
    .{ .name = "norwegian", .macro = "NRCS_Norwegian_Danish" },
    .{ .name = "spanish", .macro = "NRCS_Spanish" },
    .{ .name = "swedish", .macro = "NRCS_Swedish" },
    .{ .name = "swiss", .macro = "NRCS_Swiss" },
    .{ .name = "dec_technical", .macro = "DEC_Technical" },
    .{ .name = "jis_roman", .macro = "JIS_Roman" },
    .{ .name = "jis_katakana", .macro = "JIS_Katakana" },
    .{ .name = "portuguese", .macro = "NRCS_Portuguese" },
    .{ .name = "greek_nrc", .macro = "NRCS_Greek" },
    .{ .name = "turkish_nrc", .macro = "NRCS_Turkish" },
    .{ .name = "hebrew_nrc", .macro = "NRCS_Hebrew" },
    .{ .name = "dec_hebrew", .macro = "DEC_Hebrew_Supp" },
    .{ .name = "dec_greek", .macro = "DEC_Greek_Supp" },
    .{ .name = "dec_turkish", .macro = "DEC_Turkish_Supp" },
    .{ .name = "dec_cyrillic", .macro = "DEC_Cyrillic" },
    .{ .name = "serbo_croatian", .macro = "NRCS_Serbo_Croatian" },
    .{ .name = "dec_russian", .macro = "NRCS_Russian" },
    .{ .name = "iso_latin2", .macro = "ISO_Latin_2", .size = .set96 },
    .{ .name = "iso_greek", .macro = "ISO_Greek_Supp", .size = .set96 },
    .{ .name = "iso_hebrew", .macro = "ISO_Hebrew", .size = .set96 },
    .{ .name = "iso_cyrillic", .macro = "ISO_Latin_Cyrillic", .size = .set96 },
    .{ .name = "iso_latin5", .macro = "ISO_Latin_5", .size = .set96 },
};

/// Keysyms an entry names without a `U+` comment. Latin-1 keysyms are
/// their code points (X11 keysymdef.h). Any other one is an error.
const keysyms = [_]struct { name: []const u8, cp: u16 }{
    .{ .name = "XK_Eacute", .cp = 0x00C9 },
};

const Page = [96]u16;

const Error = error{ MissingDefine, MissingMacro, BadEntry, UnknownKeysym };

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.skip(); // argv[0]
    const out_path = args.next() orelse ucd.usage(gen_name, usage_args);
    const source_path = args.next() orelse ucd.usage(gen_name, usage_args);

    const io = init.io;
    const header = try ucd.readFile(io, init.arena.allocator(), gen_name, source_path);

    const revision = try xtermRevision(header);
    const undef = try hexAfter(header, "#define UNDEF");
    const pua = try hexAfter(header, "#define PUA(n) (");

    var buf: [4096]u8 = undefined;
    var writer = (try ucd.createFile(io, out_path)).writer(io, &buf);
    const w = &writer.interface;
    try ucd.writeHeader(w, gen_name, "xterm charsets.h {s}", .{revision});
    try w.writeAll(preamble);
    for (tables) |table| {
        const page = try parseMap(header, table, undef, pua);
        try writePage(w, table.name, &page);
    }
    try w.flush();
    ucd.log(gen_name, "wrote {s}: {d} pages", .{ std.fs.path.basename(out_path), tables.len });
}

const preamble =
    \\//! Character set pages derived from xterm's charsets.h. The upstream
    \\//! revision and license are in THIRD_PARTY_NOTICES/xterm-charsets.h.COPYING.
    \\//!
    \\//! Copyright 2023-2024,2025 by Thomas E. Dickey. Permission is granted
    \\//! under the MIT-style license reproduced in that file.
    \\//!
    \\//! Regenerate with `zig build gen-charset-pages` (tools/xterm/charsets.h).
    \\
    \\/// The code point each GL code 0x20..0x7F (index 0..95) prints as.
    \\pub const Page = [96]u16;
    \\
;

/// `1.36` from `$XTermId: charsets.h,v 1.36 ...`.
fn xtermRevision(header: []const u8) Error![]const u8 {
    const marker = "$XTermId: charsets.h,v ";
    const start = (mem.indexOf(u8, header, marker) orelse return error.MissingDefine) + marker.len;
    const end = mem.indexOfScalarPos(u8, header, start, ' ') orelse return error.MissingDefine;
    return header[start..end];
}

/// The hex number after `prefix`, as in `#define UNDEF  0x2426`.
fn hexAfter(header: []const u8, prefix: []const u8) Error!u16 {
    const at = mem.indexOf(u8, header, prefix) orelse return error.MissingDefine;
    const rest = mem.trimStart(u8, header[at + prefix.len ..], " \t");
    return parseHex(rest) orelse error.MissingDefine;
}

/// The leading `0x...` of `text`, or null.
fn parseHex(text: []const u8) ?u16 {
    if (!mem.startsWith(u8, text, "0x")) return null;
    var end: usize = 2;
    while (end < text.len and std.ascii.isHex(text[end])) end += 1;
    return std.fmt.parseInt(u16, text[2..end], 16) catch null;
}

/// The body of the first `#define map_<macro>(code...` that holds a
/// `switch`: xterm also defines empty fallbacks for builds without wide
/// characters.
fn macroBody(header: []const u8, macro: []const u8) Error![]const u8 {
    var buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&buf, "#define map_{s}(code", .{macro}) catch return error.MissingMacro;
    var pos: usize = 0;
    while (mem.indexOfPos(u8, header, pos, needle)) |at| : (pos = at + needle.len) {
        // A macro ends at the first line without a trailing backslash.
        var end = at;
        while (mem.indexOfScalarPos(u8, header, end, '\n')) |nl| {
            end = nl + 1;
            if (nl == 0 or header[nl - 1] != '\\') break;
        } else end = header.len;
        const body = header[at..end];
        if (mem.indexOf(u8, body, "switch") != null) return body;
    }
    return error.MissingMacro;
}

fn parseMap(header: []const u8, table: Table, undef: u16, pua: u16) Error!Page {
    var page: Page = undefined;
    for (&page, 0..) |*slot, i| {
        const code: u16 = @intCast(0x20 + i);
        const edge = code == 0x20 or code == 0x7F;
        slot.* = if (table.size == .set94 and edge) code else switch (table.fallback) {
            .seven => code,
            .eight => code + 0x80,
        };
    }

    const body = try macroBody(header, table.macro);
    var entries: usize = 0;
    var lines = mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| {
        const entry = findEntry(line) orelse continue;
        const parsed = try parseEntry(line[entry..], undef, pua);
        if (parsed.code < 0x20 or parsed.code > 0x7F) return error.BadEntry;
        // xterm lists nothing there for a 94-set; refuse to guess.
        if (table.size == .set94 and (parsed.code == 0x20 or parsed.code == 0x7F)) return error.BadEntry;
        page[parsed.code - 0x20] = parsed.cp;
        entries += 1;
    }
    ucd.log(gen_name, "map_{s}: {d} entries", .{ table.macro, entries });
    return page;
}

/// The index of an `UNI(`, `XXX(` or `MAP(` entry in `line`, or null.
fn findEntry(line: []const u8) ?usize {
    for ([_][]const u8{ "UNI(", "XXX(", "MAP(" }) |tag| {
        if (mem.indexOf(u8, line, tag)) |at| return at;
    }
    return null;
}

/// `UNI(0x21, 0x23B7)`, `XXX(0x31, PUA(0))`, `XXX(0x5F, UNDEF)` or
/// `MAP(0x40, XK_Adiaeresis) /* U+00C4 ... */`.
fn parseEntry(text: []const u8, undef: u16, pua: u16) Error!struct { code: u16, cp: u16 } {
    const args = text[4..];
    const code = parseHex(args) orelse return error.BadEntry;
    const comma = mem.indexOfScalar(u8, args, ',') orelse return error.BadEntry;
    const value = mem.trimStart(u8, args[comma + 1 ..], " \t");

    if (parseHex(value)) |cp| return .{ .code = code, .cp = cp };
    if (mem.startsWith(u8, value, "UNDEF")) return .{ .code = code, .cp = undef };
    if (mem.startsWith(u8, value, "PUA(")) {
        const n = std.fmt.parseInt(u16, value[4 .. mem.indexOfScalar(u8, value, ')') orelse return error.BadEntry], 10) catch return error.BadEntry;
        return .{ .code = code, .cp = pua + n };
    }
    if (mem.startsWith(u8, value, "XK_")) {
        if (mem.indexOf(u8, value, "U+")) |u| {
            const cp = std.fmt.parseInt(u16, value[u + 2 .. u + 6], 16) catch return error.BadEntry;
            return .{ .code = code, .cp = cp };
        }
        const name_end = mem.indexOfScalar(u8, value, ')') orelse return error.BadEntry;
        const name = value[0..name_end];
        for (keysyms) |k| if (mem.eql(u8, k.name, name)) return .{ .code = code, .cp = k.cp };
        ucd.log(gen_name, "keysym {s} has no U+ comment and is not in `keysyms`", .{name});
        return error.UnknownKeysym;
    }
    return error.BadEntry;
}

fn writePage(w: *std.Io.Writer, name: []const u8, page: *const Page) !void {
    try w.print("\npub const {s}: Page = .{{\n", .{name});
    var row: usize = 0;
    while (row < page.len) : (row += 8) {
        try w.writeAll("   ");
        for (page[row..][0..8]) |cp| try w.print(" 0x{X:0>4},", .{cp});
        try w.print(" // 0x{X:0>2}\n", .{0x20 + row});
    }
    try w.writeAll("};\n");
}
