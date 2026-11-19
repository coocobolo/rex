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
const ucd = @import("ucd.zig");
const emit = @import("emit.zig");
const parser = @import("scheme");

const gen_name = "themes";
const usage_args = "<out.zig> <schemes.conf>";

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.skip(); // argv[0]
    const out_path = args.next() orelse ucd.usage(gen_name, usage_args);
    const source_path = args.next() orelse ucd.usage(gen_name, usage_args);

    const io = init.io;
    const allocator = init.arena.allocator();
    const content = try ucd.readFile(io, allocator, gen_name, source_path);

    const parsed = try parser.parse(allocator, content);
    const schemes = parsed.schemes;

    var stdout_buf: [8192]u8 = undefined;
    var writer = (try ucd.createFile(io, out_path)).writer(io, &stdout_buf);
    defer writer.flush() catch {};

    const out = &writer.interface;
    try ucd.writeHeader(out, gen_name, "tools/themes/schemes.conf", .{});
    try writePresets(out, schemes);
    ucd.log(gen_name, "wrote {s}: {d} theme presets", .{ std.fs.path.basename(out_path), schemes.len });
}

fn writeRgb(w: *std.Io.Writer, c: parser.Rgb) !void {
    try w.print(".{{ .r = 0x{X:0>2}, .g = 0x{X:0>2}, .b = 0x{X:0>2} }}", .{ c.r, c.g, c.b });
}

fn writePresets(w: *std.Io.Writer, schemes: []const parser.Scheme) !void {
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
        const bg = scheme.background;
        const fg = scheme.foreground;
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
        for (scheme.ansi) |c| {
            try w.writeAll("        ");
            try writeRgb(w, c);
            try w.writeAll(",\n");
        }
        try w.writeAll("    },\n    .accent = Theme.default_accent,\n    .flags = 0,\n};\n\n");
    }

    try w.writeAll("pub const entries = [_]Entry{\n");
    for (schemes) |scheme| {
        try w.writeAll("    .{ .slug = \"");
        try emit.writeStringLiteral(w, scheme.slug);
        try w.writeAll("\", .title = \"");
        try emit.writeStringLiteral(w, scheme.title);
        try w.print("\", .variant = .{t}, .theme = {s} }},\n", .{ scheme.variant, scheme.slug });
    }
    try w.writeAll("};\n");
}
