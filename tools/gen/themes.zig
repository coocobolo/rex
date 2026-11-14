//! `zig build gen-themes`: src/color/presets.zig from tools/themes/schemes.conf.
//!
//! Usage: gen-themes <out.zig> <schemes.conf>
//!
//! Each `[slug]` block holds scheme metadata (`variant`, `upstream`,
//! `license`) followed by Ghostty-format palette and role colors exported
//! from mbadolato/iTerm2-Color-Schemes.
//!
//! See THIRD_PARTY_NOTICES/iterm2-color-schemes.txt for the upstream revision
//! and licenses.

const std = @import("std");
const mem = std.mem;
const ucd = @import("ucd.zig");

const gen_name = "themes";
const usage_args = "<out.zig> <schemes.conf>";

const Rgb = struct {
    r: u8,
    g: u8,
    b: u8,
};

const Variant = enum { dark, light };

const Scheme = struct {
    slug: []const u8,
    title: []const u8,
    license: []const u8,
    copyright: []const u8,
    source: []const u8,
    variant: ?Variant = null,
    ansi: [16]?Rgb = .{null} ** 16,
    background: ?Rgb = null,
    foreground: ?Rgb = null,
    selection_background: ?Rgb = null,
    selection_foreground: ?Rgb = null,
};

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.skip(); // argv[0]
    const out_path = args.next() orelse ucd.usage(gen_name, usage_args);
    const source_path = args.next() orelse ucd.usage(gen_name, usage_args);

    const io = init.io;
    const allocator = init.arena.allocator();
    const content = try ucd.readFile(io, allocator, gen_name, source_path);

    const schemes = try parseSchemes(allocator, content);

    var stdout_buf: [8192]u8 = undefined;
    var writer = (try ucd.createFile(io, out_path)).writer(io, &stdout_buf);
    defer writer.flush() catch {};

    const out = &writer.interface;
    try ucd.writeHeader(out, gen_name, "tools/themes/schemes.conf", .{});
    try writePresets(out, schemes);
    ucd.log(gen_name, "wrote {s}: {d} theme presets", .{ std.fs.path.basename(out_path), schemes.len });
}

fn parseSchemes(gpa: mem.Allocator, content: []const u8) ![]const Scheme {
    var list: std.ArrayListUnmanaged(Scheme) = .empty;
    var current: ?Scheme = null;

    var lines = mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw| {
        const line = mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        if (line[0] == '[' and line[line.len - 1] == ']') {
            if (current) |done| try appendValidated(gpa, &list, done);
            const slug = mem.trim(u8, line[1 .. line.len - 1], " \t");
            if (slug.len == 0) return error.InvalidSlug;
            current = .{ .slug = slug, .title = "", .license = "", .copyright = "", .source = "" };
            continue;
        }

        const scheme = &(current orelse return error.KeyOutsideSection);
        const eq = mem.indexOfScalar(u8, line, '=') orelse return error.MissingEquals;
        const key = mem.trim(u8, line[0..eq], " \t");
        const val = mem.trim(u8, line[eq + 1 ..], " \t");

        if (mem.eql(u8, key, "variant")) {
            scheme.variant = if (mem.eql(u8, val, "dark"))
                .dark
            else if (mem.eql(u8, val, "light"))
                .light
            else
                return error.InvalidVariant;
        } else if (mem.eql(u8, key, "upstream")) {
            scheme.title = val;
        } else if (mem.eql(u8, key, "license")) {
            scheme.license = val;
        } else if (mem.eql(u8, key, "copyright")) {
            scheme.copyright = val;
        } else if (mem.eql(u8, key, "source")) {
            scheme.source = val;
        } else if (mem.eql(u8, key, "palette")) {
            const inner_eq = mem.indexOfScalar(u8, val, '=') orelse return error.InvalidPaletteEntry;
            const slot = try std.fmt.parseInt(u8, mem.trim(u8, val[0..inner_eq], " \t"), 10);
            if (slot >= 16) return error.PaletteSlotOutOfRange;
            scheme.ansi[slot] = try parseHexRgb(mem.trim(u8, val[inner_eq + 1 ..], " \t"));
        } else if (mem.eql(u8, key, "background")) {
            scheme.background = try parseHexRgb(val);
        } else if (mem.eql(u8, key, "foreground")) {
            scheme.foreground = try parseHexRgb(val);
        } else if (mem.eql(u8, key, "selection-background")) {
            scheme.selection_background = try parseHexRgb(val);
        } else if (mem.eql(u8, key, "selection-foreground")) {
            scheme.selection_foreground = try parseHexRgb(val);
        } else if (mem.eql(u8, key, "cursor-color") or mem.eql(u8, key, "cursor-text")) {
            // Theme does not store cursor colors yet; ignored cleanly.
        } else {
            return error.UnknownKey;
        }
    }

    if (current) |done| try appendValidated(gpa, &list, done);
    return list.items;
}

fn isAllowedLicense(lic: []const u8) bool {
    return mem.eql(u8, lic, "MIT") or mem.eql(u8, lic, "Apache-2.0");
}

fn appendValidated(gpa: mem.Allocator, list: *std.ArrayListUnmanaged(Scheme), scheme: Scheme) !void {
    if (scheme.variant == null) return error.MissingVariant;
    if (scheme.title.len == 0) return error.MissingUpstreamTitle;
    if (scheme.license.len == 0) return error.MissingLicense;
    if (!isAllowedLicense(scheme.license)) return error.UnsupportedLicense;
    if (scheme.copyright.len == 0) return error.MissingCopyright;
    if (!mem.startsWith(u8, scheme.source, "https://")) return error.InvalidSourceUrl;
    if (scheme.background == null or scheme.foreground == null) return error.MissingGroundColor;
    for (scheme.ansi) |slot| if (slot == null) return error.MissingAnsiSlot;
    for (list.items) |prev| if (mem.eql(u8, prev.slug, scheme.slug)) return error.DuplicateSlug;
    try list.append(gpa, scheme);
}

fn parseHexRgb(text: []const u8) !Rgb {
    if (text.len != 7 or text[0] != '#') return error.InvalidHexColor;
    return .{
        .r = try std.fmt.parseInt(u8, text[1..3], 16),
        .g = try std.fmt.parseInt(u8, text[3..5], 16),
        .b = try std.fmt.parseInt(u8, text[5..7], 16),
    };
}

fn writeRgb(w: *std.Io.Writer, c: Rgb) !void {
    try w.print(".{{ .r = 0x{X:0>2}, .g = 0x{X:0>2}, .b = 0x{X:0>2} }}", .{ c.r, c.g, c.b });
}

fn writePresets(w: *std.Io.Writer, schemes: []const Scheme) !void {
    try w.writeAll(
        \\//! Curated terminal color theme presets generated from iTerm2-Color-Schemes.
        \\//!
        \\//! See THIRD_PARTY_NOTICES/iterm2-color-schemes.txt for upstream licenses
        \\//! and source revisions.
        \\
        \\const Theme = @import("Theme.zig");
        \\
        \\pub const Variant = enum { dark, light };
        \\
        \\pub const Entry = struct {
        \\    slug: []const u8,
        \\    title: []const u8,
        \\    variant: Variant,
        \\    theme: Theme,
        \\};
        \\
        \\
    );

    for (schemes) |scheme| {
        const bg = scheme.background.?;
        const fg = scheme.foreground.?;
        const sel_bg = scheme.selection_background orelse fg;
        const sel_fg = scheme.selection_foreground orelse bg;

        try w.print("// {s} ({s})\n", .{ scheme.title, scheme.license });
        try w.print("pub const {s}: Theme = .{{\n", .{scheme.slug});
        try w.writeAll("    .background = ");
        try writeRgb(w, bg);
        try w.writeAll(",\n    .foreground = ");
        try writeRgb(w, fg);
        try w.writeAll(",\n    .selection_background = ");
        try writeRgb(w, sel_bg);
        try w.writeAll(",\n    .selection_foreground = ");
        try writeRgb(w, sel_fg);
        try w.writeAll(",\n    .ansi = .{\n");
        for (scheme.ansi) |maybe_c| {
            try w.writeAll("        ");
            try writeRgb(w, maybe_c.?);
            try w.writeAll(",\n");
        }
        try w.writeAll("    },\n    .accent = Theme.default_accent,\n    .flags = 0,\n};\n\n");
    }

    try w.writeAll("pub const entries = [_]Entry{\n");
    for (schemes) |scheme| {
        try w.print(
            "    .{{ .slug = \"{s}\", .title = \"{s}\", .variant = .{t}, .theme = {s} }},\n",
            .{ scheme.slug, scheme.title, scheme.variant.?, scheme.slug },
        );
    }
    try w.writeAll("};\n");
}
