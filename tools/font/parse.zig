//! Shared TrueType table parsing for the icon tools.
//!
//! `gen-icons`, `subset-icons` and `check-font-license` need the same big-endian
//! reader, and the first two need the same `post` and `cmap` interpretation.
//! One copy keeps the generator and the subsetter from drifting apart.

const std = @import("std");
const mem = std.mem;

pub const PostTable = struct {
    num_glyphs: u16,
    name_to_gid: std.StringHashMapUnmanaged(u16),
};

/// Reads a big-endian integer from an exactly sized byte array.
pub fn readInt(comptime T: type, bytes: *const [@divExact(@typeInfo(T).int.bits, 8)]u8) T {
    return std.mem.readInt(T, bytes, .big);
}

/// Reads the format 2.0 post table. Duplicate glyph names keep their first ID.
pub fn parsePost(gpa: mem.Allocator, post: []const u8) !PostTable {
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

/// Picks the best Unicode cmap subtable and maps glyph IDs to code points.
pub fn parseCmap(gpa: mem.Allocator, cmap: []const u8, num_glyphs: u16) ![]u21 {
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
        // best_fmt is only set when best_score > 0, which requires fmt 12 or 4.
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
