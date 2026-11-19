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
const ttf = @import("font");

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
        const num_tables = ttf.readInt(u16, font[4..6]);
        const dir_end = 12 + @as(usize, num_tables) * 16;
        if (dir_end > font.len) return error.InvalidFont;

        var cmap_slice: ?[]const u8 = null;
        var post_slice: ?[]const u8 = null;
        for (0..num_tables) |i| {
            const rec = font[12 + i * 16 ..][0..16];
            const offset = ttf.readInt(u32, rec[8..12]);
            const length = ttf.readInt(u32, rec[12..16]);
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

        const parsed_post = try ttf.parsePost(gpa, post);
        const gid_to_cp = try ttf.parseCmap(gpa, cmap, parsed_post.num_glyphs);
        return .{
            .name_to_gid = parsed_post.name_to_gid,
            .gid_to_cp = gid_to_cp,
        };
    }
};
