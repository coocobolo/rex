//! TrueType subsetter for the bundled Lucide icon font.
//!
//! Usage: subset-icons <out.ttf> <icons.txt> <font.ttf>
//!
//! Reads the hyphenated glyph names in `<icons.txt>`, resolves them through
//! `<font.ttf>`'s `post` (v2.0) and `cmap` tables, and emits a standalone `.ttf`
//! containing only `.notdef` and those simple glyphs (`OS/2`, `cmap`, `glyf`,
//! `head`, `hhea`, `hmtx`, `loca`, `maxp`, `name`, `post` v3.0).

const std = @import("std");
const mem = std.mem;

const usage_line = "usage: subset-icons <out.ttf> <icons.txt> <font.ttf>\n";

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.skip();
    const out_path = args.next() orelse failUsage();
    const list_path = args.next() orelse failUsage();
    const font_path = args.next() orelse failUsage();

    const io = init.io;
    const gpa = init.arena.allocator();

    const list_bytes = try readFile(io, gpa, list_path);
    const font_bytes = try readFile(io, gpa, font_path);

    const out_bytes = try subsetFont(gpa, list_bytes, font_bytes);
    const out_file = try std.Io.Dir.createFile(.cwd(), io, out_path, .{});
    defer out_file.close(io);
    try out_file.writePositionalAll(io, out_bytes, 0);
}

fn failUsage() noreturn {
    std.debug.print(usage_line, .{});
    std.process.exit(2);
}

fn readFile(io: std.Io, gpa: mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.Io.Dir.openFile(.cwd(), io, path, .{ .mode = .read_only });
    defer file.close(io);
    const len = try file.length(io);
    const buf = try gpa.alloc(u8, len);
    errdefer gpa.free(buf);
    if (try file.readPositionalAll(io, buf, 0) != len) return error.ShortRead;
    return buf;
}

const IconEntry = struct {
    cp: u21,
    orig_gid: u16,
    new_gid: u16,
};

const RequiredTables = struct {
    os2: []const u8,
    cmap: []const u8,
    glyf: []const u8,
    head: []const u8,
    hhea: []const u8,
    hmtx: []const u8,
    loca: []const u8,
    maxp: []const u8,
    name: []const u8,
    post: []const u8,
};

const OutputTable = struct {
    tag: [4]u8,
    data: []const u8,
};

pub fn subsetFont(gpa: mem.Allocator, list_bytes: []const u8, font_bytes: []const u8) ![]u8 {
    const tables = try findTables(font_bytes);
    if (tables.head.len < 54) return error.InvalidHead;
    if (tables.hhea.len < 36) return error.InvalidHhea;
    if (tables.maxp.len < 6) return error.InvalidMaxp;
    if (tables.post.len < 32) return error.InvalidPost;

    const orig_num_glyphs = readInt(u16, tables.maxp[4..6]);
    const orig_num_hmetrics = readInt(u16, tables.hhea[34..36]);
    const orig_loca_fmt = readInt(i16, tables.head[50..52]);
    if (orig_num_glyphs == 0 or orig_num_hmetrics == 0) return error.InvalidFont;
    if (orig_loca_fmt != 0 and orig_loca_fmt != 1) return error.InvalidHead;

    const name_to_gid = try parsePostNames(gpa, tables.post);
    const gid_to_cp = try parseCmap(gpa, tables.cmap, orig_num_glyphs);

    const icons = try resolveIcons(gpa, list_bytes, &name_to_gid, gid_to_cp);
    const total_glyphs: usize = 1 + icons.len;
    if (total_glyphs > std.math.maxInt(u16)) return error.TooManyGlyphs;

    var orig_gids = try gpa.alloc(u16, total_glyphs);
    orig_gids[0] = 0; // .notdef
    for (icons, 1..) |entry, i| {
        orig_gids[i] = entry.orig_gid;
    }

    const glyf_and_loca = try buildGlyfAndLoca(gpa, tables.glyf, tables.loca, orig_loca_fmt, orig_num_glyphs, orig_gids);
    const out_hmtx = try buildHmtx(gpa, tables.hmtx, orig_num_hmetrics, orig_gids);
    const out_cmap = try buildCmap(gpa, icons);

    const out_head = try gpa.dupe(u8, tables.head);
    writeInt(u32, out_head[8..12], 0); // checkSumAdjustment filled after assembling all tables
    writeInt(i16, out_head[50..52], glyf_and_loca.loca_fmt);

    const out_hhea = try gpa.dupe(u8, tables.hhea);
    writeInt(u16, out_hhea[34..36], @intCast(total_glyphs));

    const out_maxp = try gpa.dupe(u8, tables.maxp);
    writeInt(u16, out_maxp[4..6], @intCast(total_glyphs));

    const out_os2 = try gpa.dupe(u8, tables.os2);
    if (out_os2.len >= 68 and icons.len > 0) {
        var min_cp: u21 = icons[0].cp;
        var max_cp: u21 = icons[0].cp;
        for (icons[1..]) |entry| {
            min_cp = @min(min_cp, entry.cp);
            max_cp = @max(max_cp, entry.cp);
        }
        writeInt(u16, out_os2[64..66], @intCast(@min(min_cp, 0xFFFF)));
        writeInt(u16, out_os2[66..68], @intCast(@min(max_cp, 0xFFFF)));
    }

    // Minimal post v3.0 header (32 bytes): runtime glyph loading uses cmap only.
    const out_post = try gpa.dupe(u8, tables.post[0..32]);
    writeInt(u32, out_post[0..4], 0x00030000);

    // Must remain strictly sorted ascending by 4-byte ASCII tag.
    const out_tables = [_]OutputTable{
        .{ .tag = "OS/2".*, .data = out_os2 },
        .{ .tag = "cmap".*, .data = out_cmap },
        .{ .tag = "glyf".*, .data = glyf_and_loca.glyf },
        .{ .tag = "head".*, .data = out_head },
        .{ .tag = "hhea".*, .data = out_hhea },
        .{ .tag = "hmtx".*, .data = out_hmtx },
        .{ .tag = "loca".*, .data = glyf_and_loca.loca },
        .{ .tag = "maxp".*, .data = out_maxp },
        .{ .tag = "name".*, .data = tables.name },
        .{ .tag = "post".*, .data = out_post },
    };

    return assembleSfnt(gpa, &out_tables);
}

fn findTables(font: []const u8) !RequiredTables {
    if (font.len < 12) return error.InvalidFont;
    const num_tables = readInt(u16, font[4..6]);
    const dir_end = 12 + @as(usize, num_tables) * 16;
    if (dir_end > font.len) return error.InvalidFont;

    var os2: ?[]const u8 = null;
    var cmap: ?[]const u8 = null;
    var glyf: ?[]const u8 = null;
    var head: ?[]const u8 = null;
    var hhea: ?[]const u8 = null;
    var hmtx: ?[]const u8 = null;
    var loca: ?[]const u8 = null;
    var maxp: ?[]const u8 = null;
    var name: ?[]const u8 = null;
    var post: ?[]const u8 = null;

    for (0..num_tables) |i| {
        const rec = font[12 + i * 16 ..][0..16];
        const tag = rec[0..4];
        const offset = readInt(u32, rec[8..12]);
        const length = readInt(u32, rec[12..16]);
        const end = std.math.add(usize, offset, length) catch return error.InvalidFont;
        if (end > font.len) return error.InvalidFont;
        const slice = font[offset..end];

        if (mem.eql(u8, tag, "OS/2")) os2 = slice else if (mem.eql(u8, tag, "cmap")) cmap = slice else if (mem.eql(u8, tag, "glyf")) glyf = slice else if (mem.eql(u8, tag, "head")) head = slice else if (mem.eql(u8, tag, "hhea")) hhea = slice else if (mem.eql(u8, tag, "hmtx")) hmtx = slice else if (mem.eql(u8, tag, "loca")) loca = slice else if (mem.eql(u8, tag, "maxp")) maxp = slice else if (mem.eql(u8, tag, "name")) name = slice else if (mem.eql(u8, tag, "post")) post = slice;
    }

    return .{
        .os2 = os2 orelse return error.MissingOs2,
        .cmap = cmap orelse return error.MissingCmap,
        .glyf = glyf orelse return error.MissingGlyf,
        .head = head orelse return error.MissingHead,
        .hhea = hhea orelse return error.MissingHhea,
        .hmtx = hmtx orelse return error.MissingHmtx,
        .loca = loca orelse return error.MissingLoca,
        .maxp = maxp orelse return error.MissingMaxp,
        .name = name orelse return error.MissingName,
        .post = post orelse return error.MissingPost,
    };
}

fn parsePostNames(gpa: mem.Allocator, post: []const u8) !std.StringHashMapUnmanaged(u16) {
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
        _ = try map.getOrPutValue(gpa, extra.items[extra_idx], @intCast(gid));
    }
    return map;
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

fn resolveIcons(
    gpa: mem.Allocator,
    list_bytes: []const u8,
    name_to_gid: *const std.StringHashMapUnmanaged(u16),
    gid_to_cp: []const u21,
) ![]IconEntry {
    var icons: std.ArrayList(IconEntry) = .empty;
    var seen_names: std.StringHashMapUnmanaged(void) = .empty;

    var lines = mem.splitScalar(u8, list_bytes, '\n');
    while (lines.next()) |raw| {
        const hash = mem.indexOfScalar(u8, raw, '#') orelse raw.len;
        const name = mem.trim(u8, raw[0..hash], " \t\r");
        if (name.len == 0) continue;

        if ((try seen_names.getOrPut(gpa, name)).found_existing) return error.DuplicateIcon;

        const orig_gid = name_to_gid.get(name) orelse return error.UnknownGlyph;
        if (orig_gid == 0) return error.InvalidGlyph;
        const cp = gid_to_cp[orig_gid];
        if (cp == 0) return error.UnmappedGlyph;

        try icons.append(gpa, .{
            .cp = cp,
            .orig_gid = orig_gid,
            .new_gid = @intCast(1 + icons.items.len),
        });
    }
    if (icons.items.len == 0) return error.EmptyIconList;
    return icons.toOwnedSlice(gpa);
}

fn locaOffset(loca: []const u8, fmt: i16, gid: u16) !usize {
    if (fmt == 0) {
        const idx = @as(usize, gid) * 2;
        if (idx + 2 > loca.len) return error.InvalidLoca;
        return @as(usize, readInt(u16, loca[idx..][0..2])) * 2;
    }
    const idx = @as(usize, gid) * 4;
    if (idx + 4 > loca.len) return error.InvalidLoca;
    return readInt(u32, loca[idx..][0..4]);
}

const GlyfAndLoca = struct {
    glyf: []u8,
    loca: []u8,
    loca_fmt: i16,
};

fn buildGlyfAndLoca(
    gpa: mem.Allocator,
    orig_glyf: []const u8,
    orig_loca: []const u8,
    orig_loca_fmt: i16,
    orig_num_glyphs: u16,
    orig_gids: []const u16,
) !GlyfAndLoca {
    var glyf: std.ArrayList(u8) = .empty;
    var offsets = try gpa.alloc(u32, orig_gids.len + 1);

    for (orig_gids, 0..) |orig_gid, i| {
        if (orig_gid >= orig_num_glyphs) return error.InvalidGlyph;
        const start = try locaOffset(orig_loca, orig_loca_fmt, orig_gid);
        const end = try locaOffset(orig_loca, orig_loca_fmt, orig_gid + 1);
        if (start > end or end > orig_glyf.len) return error.InvalidLoca;

        offsets[i] = @intCast(glyf.items.len);
        if (end > start) {
            if (end - start < 10) return error.InvalidGlyf;
            const num_contours = readInt(i16, orig_glyf[start..][0..2]);
            if (num_contours < 0) return error.UnsupportedCompositeGlyph;
            try glyf.appendSlice(gpa, orig_glyf[start..end]);
            while (glyf.items.len % 4 != 0) try glyf.append(gpa, 0);
        }
    }
    offsets[orig_gids.len] = @intCast(glyf.items.len);

    const use_short = glyf.items.len <= 0x1FFFE;
    const loca_fmt: i16 = if (use_short) 0 else 1;
    const entry_bytes: usize = if (use_short) 2 else 4;
    const loca = try gpa.alloc(u8, offsets.len * entry_bytes);
    for (offsets, 0..) |off, i| {
        if (use_short) {
            writeInt(u16, loca[i * 2 ..][0..2], @intCast(off / 2));
        } else {
            writeInt(u32, loca[i * 4 ..][0..4], off);
        }
    }

    return .{
        .glyf = try glyf.toOwnedSlice(gpa),
        .loca = loca,
        .loca_fmt = loca_fmt,
    };
}

fn buildHmtx(gpa: mem.Allocator, orig_hmtx: []const u8, orig_num_hmetrics: u16, orig_gids: []const u16) ![]u8 {
    if (orig_hmtx.len < @as(usize, orig_num_hmetrics) * 4) return error.InvalidHmtx;
    const out = try gpa.alloc(u8, orig_gids.len * 4);
    const last_adv_off = (@as(usize, orig_num_hmetrics) - 1) * 4;
    const lsb_base = @as(usize, orig_num_hmetrics) * 4;

    for (orig_gids, 0..) |orig_gid, i| {
        const dst = out[i * 4 ..][0..4];
        if (orig_gid < orig_num_hmetrics) {
            @memcpy(dst, orig_hmtx[@as(usize, orig_gid) * 4 ..][0..4]);
        } else {
            const extra_idx = @as(usize, orig_gid - orig_num_hmetrics) * 2;
            if (lsb_base + extra_idx + 2 > orig_hmtx.len) return error.InvalidHmtx;
            @memcpy(dst[0..2], orig_hmtx[last_adv_off..][0..2]);
            @memcpy(dst[2..4], orig_hmtx[lsb_base + extra_idx ..][0..2]);
        }
    }
    return out;
}

const CmapGroup = struct {
    start_cp: u32,
    end_cp: u32,
    start_gid: u32,
};

fn buildCmap(gpa: mem.Allocator, icons: []const IconEntry) ![]u8 {
    const sorted = try gpa.dupe(IconEntry, icons);
    mem.sort(IconEntry, sorted, {}, struct {
        fn lessThan(_: void, a: IconEntry, b: IconEntry) bool {
            return a.cp < b.cp;
        }
    }.lessThan);

    var groups: std.ArrayList(CmapGroup) = .empty;
    for (sorted) |entry| {
        if (groups.items.len > 0) {
            const prev = &groups.items[groups.items.len - 1];
            const prev_last_gid = prev.start_gid + (prev.end_cp - prev.start_cp);
            if (entry.cp == prev.end_cp + 1 and entry.new_gid == prev_last_gid + 1) {
                prev.end_cp = entry.cp;
                continue;
            }
        }
        try groups.append(gpa, .{
            .start_cp = entry.cp,
            .end_cp = entry.cp,
            .start_gid = entry.new_gid,
        });
    }

    const subtable_len: usize = 16 + groups.items.len * 12;
    const out = try gpa.alloc(u8, 12 + subtable_len);
    // cmap header (1 encoding record -> offset 12)
    writeInt(u16, out[0..2], 0);
    writeInt(u16, out[2..4], 1);
    writeInt(u16, out[4..6], 3); // Windows
    writeInt(u16, out[6..8], 10); // Unicode full repertoire
    writeInt(u32, out[8..12], 12);

    // Format 12 subtable
    const sub = out[12..];
    writeInt(u16, sub[0..2], 12);
    writeInt(u16, sub[2..4], 0);
    writeInt(u32, sub[4..8], @intCast(subtable_len));
    writeInt(u32, sub[8..12], 0);
    writeInt(u32, sub[12..16], @intCast(groups.items.len));
    for (groups.items, 0..) |g, i| {
        const rec = sub[16 + i * 12 ..][0..12];
        writeInt(u32, rec[0..4], g.start_cp);
        writeInt(u32, rec[4..8], g.end_cp);
        writeInt(u32, rec[8..12], g.start_gid);
    }
    return out;
}

fn assembleSfnt(gpa: mem.Allocator, tables: []const OutputTable) ![]u8 {
    const dir_size = 12 + tables.len * 16;
    var total_size = dir_size;
    for (tables) |t| total_size += align4(t.data.len);

    const out = try gpa.alloc(u8, total_size);
    @memset(out, 0);

    const num_tables: u16 = @intCast(tables.len);
    const max_pow2: u16 = @as(u16, 1) << std.math.log2_int(u16, num_tables);
    const search_range: u16 = max_pow2 * 16;
    const entry_selector: u16 = std.math.log2_int(u16, num_tables);
    const range_shift: u16 = num_tables * 16 - search_range;

    writeInt(u32, out[0..4], 0x00010000);
    writeInt(u16, out[4..6], num_tables);
    writeInt(u16, out[6..8], search_range);
    writeInt(u16, out[8..10], entry_selector);
    writeInt(u16, out[10..12], range_shift);

    var cursor: usize = dir_size;
    var head_offset: usize = 0;
    for (tables, 0..) |t, i| {
        const padded_len = align4(t.data.len);
        @memcpy(out[cursor..][0..t.data.len], t.data);
        if (mem.eql(u8, &t.tag, "head")) head_offset = cursor;

        const rec = out[12 + i * 16 ..][0..16];
        @memcpy(rec[0..4], &t.tag);
        writeInt(u32, rec[4..8], tableChecksum(out[cursor..][0..padded_len]));
        writeInt(u32, rec[8..12], @intCast(cursor));
        writeInt(u32, rec[12..16], @intCast(t.data.len));
        cursor += padded_len;
    }

    const total_sum = tableChecksum(out);
    writeInt(u32, out[head_offset + 8 ..][0..4], 0xB1B0AFBA -% total_sum);
    return out;
}

fn align4(len: usize) usize {
    return (len + 3) & ~@as(usize, 3);
}

fn tableChecksum(padded: []const u8) u32 {
    var sum: u32 = 0;
    var i: usize = 0;
    while (i + 4 <= padded.len) : (i += 4) {
        sum +%= readInt(u32, padded[i..][0..4]);
    }
    return sum;
}

fn readInt(comptime T: type, bytes: *const [@divExact(@typeInfo(T).int.bits, 8)]u8) T {
    return std.mem.readInt(T, bytes, .big);
}

fn writeInt(comptime T: type, bytes: *[@divExact(@typeInfo(T).int.bits, 8)]u8, value: T) void {
    std.mem.writeInt(T, bytes, value, .big);
}
