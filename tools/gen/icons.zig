//! `zig build gen-icons`: src/kit/icons.zig from an icon name list and font.
//!
//! Usage: gen-icons <out.zig> <icons.txt> <font.ttf>
//!
//! Resolves each hyphenated glyph name in `<icons.txt>` through the font's
//! `post` (format 2.0) glyph-name table and `cmap` table, writing Zig
//! `pub const <snake_case> = 0xXXXX;` definitions. Fails if any listed glyph
//! is missing from `post`, unmapped in `cmap`, duplicated, or invalid as a
//! Zig identifier.

const std = @import("std");
const mem = std.mem;
const ucd = @import("ucd.zig");

const gen_name = "icons";
const usage_args = "<out.zig> <icons.txt> <font.ttf>";

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.skip(); // argv[0]
    const out_path = args.next() orelse ucd.usage(gen_name, usage_args);
    const list_path = args.next() orelse ucd.usage(gen_name, usage_args);
    const font_path = args.next() orelse ucd.usage(gen_name, usage_args);

    const io = init.io;
    const gpa = init.arena.allocator();

    const list_bytes = try ucd.readFile(io, gpa, gen_name, list_path);
    const font_bytes = try ucd.readFile(io, gpa, gen_name, font_path);

    const font = try FontIndex.parse(gpa, font_bytes);

    var buf: [4096]u8 = undefined;
    var writer = (try ucd.createFile(io, out_path)).writer(io, &buf);

    const count = try writeIcons(&writer.interface, gpa, list_bytes, &font);
    try writer.flush();
    ucd.log(gen_name, "wrote {s}: {d} icons", .{ std.fs.path.basename(out_path), count });
}

fn writeIcons(w: *std.Io.Writer, gpa: mem.Allocator, list_bytes: []const u8, font: *const FontIndex) !usize {
    try ucd.writeHeader(w, gen_name, "tools/gen/icons.txt and assets/fonts/lucide.ttf", .{});
    try w.writeAll(
        \\//! The icons the kit draws: code points in the bundled Lucide icon font
        \\//! (`assets/fonts/lucide.ttf`, its private-use area). Add names to
        \\//! `tools/gen/icons.txt` and run `zig build gen-icons`.
        \\
        \\/// No icon: code point 0 is never a glyph.
        \\pub const none = 0;
        \\
    );

    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var count: usize = 0;
    var lines = mem.splitScalar(u8, list_bytes, '\n');
    while (lines.next()) |raw| {
        const hash = mem.indexOfScalar(u8, raw, '#') orelse raw.len;
        const name = mem.trim(u8, raw[0..hash], " \t\r");
        if (name.len == 0) continue;

        const ident = toIdentifier(gpa, name) catch |err| {
            ucd.log(gen_name, "invalid icon name '{s}': {t}", .{ name, err });
            return err;
        };
        if (mem.eql(u8, ident, "none")) {
            ucd.log(gen_name, "reserved icon name: '{s}'", .{name});
            return error.ReservedIconName;
        }
        const gop = try seen.getOrPut(gpa, ident);
        if (gop.found_existing) {
            ucd.log(gen_name, "duplicate icon '{s}' ({s})", .{ name, ident });
            return error.DuplicateIcon;
        }

        const gid = font.name_to_gid.get(name) orelse {
            ucd.log(gen_name, "glyph not found in post table: '{s}'", .{name});
            return error.UnknownGlyph;
        };
        const cp = font.gid_to_cp[gid];
        if (cp == 0) {
            ucd.log(gen_name, "glyph has no Unicode mapping in cmap: '{s}' (gid {d})", .{ name, gid });
            return error.UnmappedGlyph;
        }

        try w.print("pub const {s} = 0x{X:0>4};\n", .{ ident, cp });
        count += 1;
    }
    return count;
}

fn toIdentifier(gpa: mem.Allocator, name: []const u8) ![]u8 {
    if (name.len == 0 or (name[0] >= '0' and name[0] <= '9')) return error.InvalidIdentifier;
    const out = try gpa.alloc(u8, name.len);
    for (name, 0..) |ch, i| {
        out[i] = switch (ch) {
            'a'...'z', '0'...'9', '_' => ch,
            '-' => '_',
            else => return error.InvalidIdentifier,
        };
    }
    return out;
}

const FontIndex = struct {
    name_to_gid: std.StringHashMapUnmanaged(u16),
    gid_to_cp: []u21,

    fn parse(gpa: mem.Allocator, font: []const u8) !FontIndex {
        if (font.len < 12) return error.InvalidFont;
        const num_tables = readInt(u16, font[4..6]);
        const dir_end = 12 + @as(usize, num_tables) * 16;
        if (dir_end > font.len) return error.InvalidFont;

        var cmap_slice: ?[]const u8 = null;
        var post_slice: ?[]const u8 = null;
        for (0..num_tables) |i| {
            const rec = font[12 + i * 16 ..][0..16];
            const offset = readInt(u32, rec[8..12]);
            const length = readInt(u32, rec[12..16]);
            const end = std.math.add(usize, offset, length) catch return error.InvalidFont;
            if (end > font.len) return error.InvalidFont;
            if (mem.eql(u8, rec[0..4], "cmap")) {
                cmap_slice = font[offset..end];
            } else if (mem.eql(u8, rec[0..4], "post")) {
                post_slice = font[offset..end];
            }
        }

        const cmap = cmap_slice orelse return error.MissingCmap;
        const post = post_slice orelse return error.MissingPost;

        const parsed_post = try parsePost(gpa, post);
        const gid_to_cp = try parseCmap(gpa, cmap, parsed_post.num_glyphs);
        return .{
            .name_to_gid = parsed_post.name_to_gid,
            .gid_to_cp = gid_to_cp,
        };
    }
};

const PostTable = struct {
    num_glyphs: u16,
    name_to_gid: std.StringHashMapUnmanaged(u16),
};

fn parsePost(gpa: mem.Allocator, post: []const u8) !PostTable {
    if (post.len < 34) return error.InvalidPost;
    const version = readInt(u32, post[0..4]);
    if (version != 0x00020000) return error.UnsupportedPostVersion;

    const num_glyphs = readInt(u16, post[32..34]);
    const idx_end = 34 + @as(usize, num_glyphs) * 2;
    if (idx_end > post.len) return error.InvalidPost;

    var extra: std.ArrayList([]const u8) = .empty;
    var pos: usize = idx_end;
    while (pos < post.len) {
        const slen = post[pos];
        pos += 1;
        if (pos + slen > post.len) return error.InvalidPost;
        try extra.append(gpa, post[pos .. pos + slen]);
        pos += slen;
    }

    var map: std.StringHashMapUnmanaged(u16) = .empty;
    for (0..num_glyphs) |gid| {
        const idx = readInt(u16, post[34 + gid * 2 ..][0..2]);
        if (idx < 258) continue;
        const extra_idx = idx - 258;
        if (extra_idx >= extra.items.len) return error.InvalidPost;
        const glyph_name = extra.items[extra_idx];
        // Keep the first glyph ID if a font lists a duplicate post name.
        _ = try map.getOrPutValue(gpa, glyph_name, @intCast(gid));
    }
    return .{ .num_glyphs = num_glyphs, .name_to_gid = map };
}

fn parseCmap(gpa: mem.Allocator, cmap: []const u8, num_glyphs: u16) ![]u21 {
    if (cmap.len < 4) return error.InvalidCmap;
    const num_subtables = readInt(u16, cmap[2..4]);
    const dir_end = 4 + @as(usize, num_subtables) * 8;
    if (dir_end > cmap.len) return error.InvalidCmap;

    var best_score: u8 = 0;
    var best_sub: []const u8 = &.{};
    var best_fmt: u16 = 0;
    for (0..num_subtables) |i| {
        const rec = cmap[4 + i * 8 ..][0..8];
        const platform = readInt(u16, rec[0..2]);
        const encoding = readInt(u16, rec[2..4]);
        const offset = readInt(u32, rec[4..8]);
        if (offset + 2 > cmap.len) return error.InvalidCmap;
        const fmt = readInt(u16, cmap[offset..][0..2]);

        const score: u8 = switch (fmt) {
            12 => if (platform == 3 and encoding == 10)
                5
            else if (platform == 0 and encoding == 4)
                4
            else
                3,
            4 => if (platform == 3 and encoding == 1)
                2
            else if (platform == 0 and encoding == 3)
                1
            else
                0,
            else => 0,
        };
        if (score > best_score) {
            best_score = score;
            best_sub = cmap[offset..];
            best_fmt = fmt;
        }
    }
    if (best_score == 0) return error.MissingUnicodeCmap;

    const gid_to_cp = try gpa.alloc(u21, num_glyphs);
    @memset(gid_to_cp, 0);

    switch (best_fmt) {
        12 => try readCmapFormat12(best_sub, gid_to_cp),
        4 => try readCmapFormat4(best_sub, gid_to_cp),
        else => unreachable,
    }
    return gid_to_cp;
}

fn readCmapFormat12(sub: []const u8, gid_to_cp: []u21) !void {
    if (sub.len < 16) return error.InvalidCmap;
    const num_groups = readInt(u32, sub[12..16]);
    const end_off = 16 + @as(usize, num_groups) * 12;
    if (end_off > sub.len) return error.InvalidCmap;

    for (0..num_groups) |g| {
        const rec = sub[16 + g * 12 ..][0..12];
        const start_cp = readInt(u32, rec[0..4]);
        const end_cp = readInt(u32, rec[4..8]);
        const start_gid = readInt(u32, rec[8..12]);
        if (end_cp < start_cp) return error.InvalidCmap;

        var cp = start_cp;
        while (cp <= end_cp) : (cp += 1) {
            if (cp == 0 or cp > std.math.maxInt(u21)) continue;
            const gid = start_gid + (cp - start_cp);
            if (gid == 0 or gid >= gid_to_cp.len) continue;
            recordMapping(gid_to_cp, gid, @intCast(cp));
        }
    }
}

fn readCmapFormat4(sub: []const u8, gid_to_cp: []u21) !void {
    if (sub.len < 16) return error.InvalidCmap;
    const seg_count_x2 = readInt(u16, sub[6..8]);
    if (seg_count_x2 % 2 != 0) return error.InvalidCmap;
    const seg_count: usize = seg_count_x2 / 2;

    const end_base: usize = 14;
    const start_base = end_base + seg_count * 2 + 2;
    const delta_base = start_base + seg_count * 2;
    const ro_base = delta_base + seg_count * 2;
    if (ro_base + seg_count * 2 > sub.len) return error.InvalidCmap;

    for (0..seg_count) |i| {
        const end_cp = readInt(u16, sub[end_base + i * 2 ..][0..2]);
        const start_cp = readInt(u16, sub[start_base + i * 2 ..][0..2]);
        const id_delta = readInt(i16, sub[delta_base + i * 2 ..][0..2]);
        const id_ro = readInt(u16, sub[ro_base + i * 2 ..][0..2]);
        if (start_cp == 0xFFFF and end_cp == 0xFFFF) continue;

        var cp: u32 = start_cp;
        while (cp <= end_cp) : (cp += 1) {
            if (cp == 0) continue;
            const raw_gid: u16 = if (id_ro == 0)
                @intCast(@as(i32, @intCast(cp)) + id_delta & 0xFFFF)
            else blk: {
                const addr = ro_base + i * 2 + id_ro + (cp - start_cp) * 2;
                if (addr + 2 > sub.len) return error.InvalidCmap;
                const val = readInt(u16, sub[addr..][0..2]);
                if (val == 0) break :blk 0;
                break :blk @intCast(@as(i32, val) + id_delta & 0xFFFF);
            };
            if (raw_gid == 0 or raw_gid >= gid_to_cp.len) continue;
            recordMapping(gid_to_cp, raw_gid, @intCast(cp));
        }
    }
}

fn isPrivateUse(cp: u21) bool {
    return (cp >= 0xE000 and cp <= 0xF8FF) or (cp >= 0xF0000 and cp <= 0xFFFFD) or (cp >= 0x100000 and cp <= 0x10FFFD);
}

/// Prefer Private Use Area code points over ASCII/Latin aliases (e.g. `x` -> U+E1B2 over U+0078).
fn recordMapping(gid_to_cp: []u21, gid: usize, cp: u21) void {
    const prev = gid_to_cp[gid];
    if (prev == 0) {
        gid_to_cp[gid] = cp;
        return;
    }
    const prev_pua = isPrivateUse(prev);
    const next_pua = isPrivateUse(cp);
    if ((next_pua and !prev_pua) or (next_pua == prev_pua and cp < prev)) {
        gid_to_cp[gid] = cp;
    }
}

fn readInt(comptime T: type, bytes: *const [@divExact(@typeInfo(T).int.bits, 8)]u8) T {
    return std.mem.readInt(T, bytes, .big);
}
