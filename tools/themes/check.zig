//! Verifies curated theme metadata, permissive licensing, THIRD_PARTY_NOTICES
//! parity, and generated presets offline.
//!
//! Usage:
//!   check-themes <REVISION> <manifest.conf> <schemes.conf> <notice.txt> <apache.txt> <presets.zig>
//!
//! Run at build time (`zig build` / `zig build check-themes`) and as tests via
//! `zig build test` to ensure tools/themes/manifest.conf, tools/themes/schemes.conf,
//! THIRD_PARTY_NOTICES/iterm2-color-schemes.txt, and src/color/presets.zig cannot
//! drift out of sync or include unverified licenses.

const std = @import("std");
const mem = std.mem;
const parser = @import("scheme");

const upstream_repo = "https://github.com/mbadolato/iTerm2-Color-Schemes";

pub const ManifestEntry = struct {
    slug: []const u8,
    variant: []const u8,
    upstream: []const u8,
    copyright: []const u8,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.arena.allocator();

    var args = init.minimal.args.iterate();
    _ = args.skip();
    const rev_path = args.next() orelse return usage();
    const manifest_path = args.next() orelse return usage();
    const schemes_path = args.next() orelse return usage();
    const notice_path = args.next() orelse return usage();
    const apache_path = args.next() orelse return usage();
    const presets_path = args.next() orelse return usage();
    if (args.next() != null) return usage();

    const rev_raw = try readFile(io, gpa, rev_path);
    const manifest_raw = try readFile(io, gpa, manifest_path);
    const schemes_raw = try readFile(io, gpa, schemes_path);
    const notice_raw = try readFile(io, gpa, notice_path);
    const apache_raw = try readFile(io, gpa, apache_path);
    const presets_raw = try readFile(io, gpa, presets_path);

    try verifyAll(gpa, .{
        .revision = rev_raw,
        .manifest = manifest_raw,
        .schemes = schemes_raw,
        .notice = notice_raw,
        .apache = apache_raw,
        .presets = presets_raw,
    });
}

fn usage() error{InvalidUsage} {
    std.log.err("usage: check-themes <REVISION> <manifest.conf> <schemes.conf> <notice.txt> <apache.txt> <presets.zig>", .{});
    return error.InvalidUsage;
}

pub const Inputs = struct {
    revision: []const u8,
    manifest: []const u8,
    schemes: []const u8,
    notice: []const u8,
    apache: []const u8,
    presets: []const u8,
};

pub fn verifyAll(gpa: mem.Allocator, inputs: Inputs) !void {
    const revision = try parseRevision(inputs.revision);
    const manifest = try parseManifest(gpa, inputs.manifest);
    const parsed = try parser.parse(gpa, inputs.schemes);
    if (parsed.upstream == null or parsed.commit == null) return error.MissingSchemesHeader;
    if (!mem.eql(u8, parsed.upstream.?, upstream_repo)) return error.WrongUpstreamRepo;
    if (!mem.eql(u8, parsed.commit.?, revision)) return error.RevisionMismatch;
    const schemes = parsed.schemes;

    try verifyManifestParity(manifest, schemes);
    try verifyNotices(gpa, revision, schemes, inputs.notice, inputs.apache);
    try verifyPresets(gpa, schemes, inputs.presets);
}

fn parseRevision(raw: []const u8) ![]const u8 {
    const rev = mem.trim(u8, raw, " \t\r\n");
    if (rev.len != 40) return error.InvalidRevision;
    for (rev) |ch| {
        const is_hex = (ch >= '0' and ch <= '9') or (ch >= 'a' and ch <= 'f');
        if (!is_hex) return error.InvalidRevision;
    }
    return rev;
}

fn parseManifest(gpa: mem.Allocator, raw: []const u8) ![]const ManifestEntry {
    var list: std.ArrayListUnmanaged(ManifestEntry) = .empty;
    var lines = mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line_raw| {
        const line = mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        var parts = mem.splitScalar(u8, line, '|');
        const slug = mem.trim(u8, parts.next() orelse return error.InvalidManifestRow, " \t");
        const variant = mem.trim(u8, parts.next() orelse return error.InvalidManifestRow, " \t");
        const upstream = mem.trim(u8, parts.next() orelse return error.InvalidManifestRow, " \t");
        const copyright = mem.trim(u8, parts.next() orelse return error.InvalidManifestRow, " \t");
        if (parts.next() != null) return error.InvalidManifestRow;
        if (slug.len == 0 or upstream.len == 0 or copyright.len == 0) return error.InvalidManifestRow;
        if (!mem.eql(u8, variant, "dark") and !mem.eql(u8, variant, "light")) {
            return error.InvalidVariant;
        }
        for (list.items) |prev| {
            if (mem.eql(u8, prev.slug, slug) or mem.eql(u8, prev.upstream, upstream)) {
                return error.DuplicateManifestEntry;
            }
        }
        try list.append(gpa, .{
            .slug = slug,
            .variant = variant,
            .upstream = upstream,
            .copyright = copyright,
        });
    }
    if (list.items.len == 0) return error.EmptyManifest;
    return list.items;
}

fn verifyManifestParity(manifest: []const ManifestEntry, schemes: []const parser.Scheme) !void {
    if (manifest.len != schemes.len) return error.ManifestCountMismatch;
    for (manifest, schemes) |m, s| {
        if (!mem.eql(u8, m.slug, s.slug) or
            !mem.eql(u8, m.variant, @tagName(s.variant)) or
            !mem.eql(u8, m.upstream, s.title) or
            !mem.eql(u8, m.copyright, s.copyright))
        {
            return error.ManifestSchemesMismatch;
        }
    }
}

fn verifyNotices(
    gpa: mem.Allocator,
    revision: []const u8,
    schemes: []const parser.Scheme,
    notice: []const u8,
    apache: []const u8,
) !void {
    if (mem.indexOf(u8, notice, revision) == null) return error.NoticeMissingRevision;
    if (mem.indexOf(u8, notice, "Permission is hereby granted, free of charge") == null) {
        return error.NoticeMissingMitText;
    }

    var needs_apache = false;
    for (schemes) |s| {
        if (mem.eql(u8, s.license, "Apache-2.0")) {
            needs_apache = true;
            break;
        }
    }
    if (needs_apache) {
        if (mem.indexOf(u8, notice, "THIRD_PARTY_NOTICES/Apache-2.0.txt") == null) {
            return error.NoticeMissingApacheRef;
        }
        if (mem.indexOf(u8, apache, "Apache License") == null or
            mem.indexOf(u8, apache, "Version 2.0, January 2004") == null)
        {
            return error.InvalidApacheLicenseFile;
        }
    }

    const section_header = "Included schemes and individual licenses";
    const section_pos = mem.indexOf(u8, notice, section_header) orelse return error.NoticeMissingSchemesSection;
    var lines = mem.splitScalar(u8, notice[section_pos + section_header.len ..], '\n');

    var notice_rows: std.ArrayListUnmanaged([]const u8) = .empty;
    while (lines.next()) |line_raw| {
        const line = mem.trim(u8, line_raw, " \t\r");
        if (mem.startsWith(u8, line, "- ")) {
            try notice_rows.append(gpa, line);
        }
    }
    if (notice_rows.items.len != schemes.len) return error.NoticeSchemeCountMismatch;

    for (schemes, notice_rows.items) |s, row| {
        const expected = try std.fmt.allocPrint(
            gpa,
            "- {s} [{s}] - {s} ({s})",
            .{ s.title, s.license, s.copyright, s.source },
        );
        if (!mem.eql(u8, row, expected)) return error.NoticeSchemeEntryMismatch;
    }
}

fn verifyPresets(gpa: mem.Allocator, schemes: []const parser.Scheme, presets: []const u8) !void {
    if (mem.indexOf(u8, presets, "// GENERATED by zig build gen-themes from tools/themes/schemes.conf. DO NOT EDIT.") == null) {
        return error.PresetsMissingSourceHeader;
    }
    const marker = "pub const entries = [_]Entry{";
    const start = mem.indexOf(u8, presets, marker) orelse return error.PresetsMissingEntries;
    const end = mem.indexOfPos(u8, presets, start, "};") orelse return error.PresetsMissingEntriesEnd;
    const slice = presets[start + marker.len .. end];

    var entry_lines: std.ArrayListUnmanaged([]const u8) = .empty;
    var lines = mem.splitScalar(u8, slice, '\n');
    while (lines.next()) |line_raw| {
        const line = mem.trim(u8, line_raw, " \t\r");
        if (mem.startsWith(u8, line, ".{ .slug = ")) {
            try entry_lines.append(gpa, line);
        }
    }
    if (entry_lines.items.len != schemes.len) return error.PresetsCountMismatch;

    for (schemes, entry_lines.items) |s, row| {
        const expected = try std.fmt.allocPrint(
            gpa,
            ".{{ .slug = \"{s}\", .title = \"{s}\", .variant = .{s}, .theme = {s} }},",
            .{ s.slug, s.title, @tagName(s.variant), s.slug },
        );
        if (!mem.eql(u8, row, expected)) return error.PresetsEntryMismatch;
    }
}

fn readFile(io: std.Io, gpa: mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.Io.Dir.openFile(.cwd(), io, path, .{ .mode = .read_only });
    defer file.close(io);
    const len = try file.length(io);
    const buf = try gpa.alloc(u8, len);
    const n = try file.readPositionalAll(io, buf, 0);
    if (n != len) return error.ShortRead;
    return buf;
}

const TestFixture = struct {
    const revision = "95705098082c5d07fad152c31f020d50d38e10e8\n";
    const manifest =
        \\nord | dark | Nord | Copyright (c) 2016-present Sven Greb <development@svengreb.de>
        \\tokyo_night | dark | TokyoNight | Folke Lemaitre (folke/tokyonight.nvim)
        \\
    ;
    const schemes =
        \\# Upstream: https://github.com/mbadolato/iTerm2-Color-Schemes
        \\# Commit: 95705098082c5d07fad152c31f020d50d38e10e8
        \\
        \\[nord]
        \\variant = dark
        \\upstream = Nord
        \\license = MIT
        \\copyright = Copyright (c) 2016-present Sven Greb <development@svengreb.de>
        \\source = https://github.com/nordtheme/iterm2
        \\palette = 0=#3b4252
        \\palette = 1=#bf616a
        \\palette = 2=#a3be8c
        \\palette = 3=#ebcb8b
        \\palette = 4=#81a1c1
        \\palette = 5=#b48ead
        \\palette = 6=#88c0d0
        \\palette = 7=#e5e9f0
        \\palette = 8=#4c566a
        \\palette = 9=#bf616a
        \\palette = 10=#a3be8c
        \\palette = 11=#ebcb8b
        \\palette = 12=#81a1c1
        \\palette = 13=#b48ead
        \\palette = 14=#8fbcbb
        \\palette = 15=#eceff4
        \\background = #2e3440
        \\foreground = #d8dee9
        \\
        \\[tokyo_night]
        \\variant = dark
        \\upstream = TokyoNight
        \\license = Apache-2.0
        \\copyright = Folke Lemaitre (folke/tokyonight.nvim)
        \\source = https://github.com/folke/tokyonight.nvim
        \\palette = 0=#15161e
        \\palette = 1=#f7768e
        \\palette = 2=#9ece6a
        \\palette = 3=#e0af68
        \\palette = 4=#7aa2f7
        \\palette = 5=#bb9af7
        \\palette = 6=#7dcfff
        \\palette = 7=#a9b1d6
        \\palette = 8=#414868
        \\palette = 9=#f7768e
        \\palette = 10=#9ece6a
        \\palette = 11=#e0af68
        \\palette = 12=#7aa2f7
        \\palette = 13=#bb9af7
        \\palette = 14=#7dcfff
        \\palette = 15=#c0caf5
        \\background = #1a1b26
        \\foreground = #c0caf5
        \\
    ;
    const notice =
        \\Upstream revision:
        \\95705098082c5d07fad152c31f020d50d38e10e8
        \\
        \\Permission is hereby granted, free of charge
        \\THIRD_PARTY_NOTICES/Apache-2.0.txt
        \\
        \\Included schemes and individual licenses
        \\----------------------------------------
        \\- Nord [MIT] - Copyright (c) 2016-present Sven Greb <development@svengreb.de> (https://github.com/nordtheme/iterm2)
        \\- TokyoNight [Apache-2.0] - Folke Lemaitre (folke/tokyonight.nvim) (https://github.com/folke/tokyonight.nvim)
        \\
    ;
    const apache = "Apache License\nVersion 2.0, January 2004\n";
    const presets =
        \\// GENERATED by zig build gen-themes from tools/themes/schemes.conf. DO NOT EDIT.
        \\pub const entries = [_]Entry{
        \\    .{ .slug = "nord", .title = "Nord", .variant = .dark, .theme = nord },
        \\    .{ .slug = "tokyo_night", .title = "TokyoNight", .variant = .dark, .theme = tokyo_night },
        \\};
        \\
    ;

    fn inputs() Inputs {
        return .{
            .revision = revision,
            .manifest = manifest,
            .schemes = schemes,
            .notice = notice,
            .apache = apache,
            .presets = presets,
        };
    }
};

test "theme check accepts matching manifest, schemes, notices, apache, and presets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try verifyAll(arena.allocator(), TestFixture.inputs());
}

test "theme check rejects non-permissive license" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var inputs = TestFixture.inputs();
    const bad = try mem.replaceOwned(u8, arena.allocator(), TestFixture.schemes, "license = MIT", "license = GPL-2.0-or-later");
    inputs.schemes = bad;
    try std.testing.expectError(error.UnsupportedLicense, verifyAll(arena.allocator(), inputs));
}

test "theme check rejects revision mismatch and notice drift" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var bad_rev = TestFixture.inputs();
    bad_rev.revision = "0000000000000000000000000000000000000000\n";
    try std.testing.expectError(error.RevisionMismatch, verifyAll(arena.allocator(), bad_rev));

    var bad_notice = TestFixture.inputs();
    const trimmed = try mem.replaceOwned(
        u8,
        arena.allocator(),
        TestFixture.notice,
        "- TokyoNight [Apache-2.0] - Folke Lemaitre (folke/tokyonight.nvim) (https://github.com/folke/tokyonight.nvim)\n",
        "",
    );
    bad_notice.notice = trimmed;
    try std.testing.expectError(error.NoticeSchemeCountMismatch, verifyAll(arena.allocator(), bad_notice));
}

test "theme check rejects stale presets.zig" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var inputs = TestFixture.inputs();
    const stale = try mem.replaceOwned(
        u8,
        arena.allocator(),
        TestFixture.presets,
        "    .{ .slug = \"tokyo_night\", .title = \"TokyoNight\", .variant = .dark, .theme = tokyo_night },\n",
        "",
    );
    inputs.presets = stale;
    try std.testing.expectError(error.PresetsCountMismatch, verifyAll(arena.allocator(), inputs));
}
