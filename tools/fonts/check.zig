//! The copyright in a font's name table is the first line of its OFL file.
//!
//! Groups are separated by `--`. The first path of a group is the license,
//! and every font after it must carry that same copyright. `zig build` runs
//! this on the built-in faces in `assets/fonts` and on the test fonts in
//! `testdata/font`.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.arena.allocator();

    var args = init.minimal.args.iterate();
    _ = args.skip();

    var ofl_path: ?[]const u8 = null;
    var fonts: usize = 0;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--")) {
            if (ofl_path != null and fonts == 0) return error.MissingFont;
            ofl_path = null;
            fonts = 0;
            continue;
        }
        if (ofl_path == null) {
            ofl_path = arg;
            continue;
        }
        try match(io, gpa, ofl_path.?, arg);
        fonts += 1;
    }
    if (ofl_path == null or fonts == 0) return error.MissingFont;
}

fn match(io: std.Io, gpa: std.mem.Allocator, ofl_path: []const u8, font_path: []const u8) !void {
    const notice = try copyright(io, gpa, font_path);
    const ofl = try readFile(io, gpa, ofl_path);
    const line_end = std.mem.indexOfScalar(u8, ofl, '\n') orelse ofl.len;
    const first = std.mem.trim(u8, ofl[0..line_end], " \t\r");
    if (!std.mem.eql(u8, notice, first)) {
        std.log.err("{s}\n  name table: {s}\n  {s}: {s}", .{ font_path, notice, ofl_path, first });
        return error.LicenseMismatch;
    }
}

fn readFile(io: std.Io, gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.Io.Dir.openFile(.cwd(), io, path, .{ .mode = .read_only });
    defer file.close(io);
    const len = try file.length(io);
    const buf = try gpa.alloc(u8, len);
    const n = try file.readPositionalAll(io, buf, 0);
    if (n != len) return error.ShortRead;
    return buf;
}

fn readAt(io: std.Io, file: std.Io.File, buf: []u8, offset: u64) !void {
    const n = try file.readPositionalAll(io, buf, offset);
    if (n != buf.len) return error.ShortRead;
}

/// Name-table ID 0, Windows Unicode (platform 3), as UTF-8.
fn copyright(io: std.Io, gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.Io.Dir.openFile(.cwd(), io, path, .{ .mode = .read_only });
    defer file.close(io);

    var header: [12]u8 = undefined;
    try readAt(io, file, &header, 0);
    const tables = readInt(u16, header[4..6]);
    const records = try gpa.alloc(u8, @as(usize, tables) * 16);
    try readAt(io, file, records, 12);

    var name_at: ?struct { offset: u32, len: u32 } = null;
    var i: usize = 0;
    while (i < tables) : (i += 1) {
        const rec = records[i * 16 ..][0..16];
        if (!std.mem.eql(u8, rec[0..4], "name")) continue;
        name_at = .{
            .offset = readInt(u32, rec[8..12]),
            .len = readInt(u32, rec[12..16]),
        };
    }
    const name = name_at orelse return error.NoNameTable;
    const blob = try gpa.alloc(u8, name.len);
    try readAt(io, file, blob, name.offset);

    const count = readInt(u16, blob[2..4]);
    const storage = readInt(u16, blob[4..6]);
    var n: usize = 0;
    while (n < count) : (n += 1) {
        const rec = blob[6 + n * 12 ..][0..12];
        const platform = readInt(u16, rec[0..2]);
        const id = readInt(u16, rec[6..8]);
        if (platform != 3 or id != 0) continue;
        const length = readInt(u16, rec[8..10]);
        const at = readInt(u16, rec[10..12]);
        const raw = blob[storage + at ..][0..length];
        return utf16Be(gpa, raw);
    }
    return error.NoCopyright;
}

fn utf16Be(gpa: std.mem.Allocator, raw: []const u8) ![]u8 {
    if (raw.len % 2 != 0) return error.BadCopyright;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < raw.len) : (i += 2) {
        const cp = readInt(u16, raw[i..][0..2]);
        var buf: [3]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch return error.BadCopyright;
        try out.appendSlice(gpa, buf[0..n]);
    }
    return out.toOwnedSlice(gpa);
}

fn readInt(comptime T: type, bytes: *const [@divExact(@typeInfo(T).int.bits, 8)]u8) T {
    return std.mem.readInt(T, bytes, .big);
}
