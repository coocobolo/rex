//! Shared parser for `tools/themes/schemes.conf`.
//!
//! `gen-themes` and `check-theme-license` both read this format. One parser
//! and one validator keep the generator and the checker from accepting
//! different files; header comments are returned for the caller to interpret.

const std = @import("std");
const mem = std.mem;

pub const Rgb = struct {
    r: u8,
    g: u8,
    b: u8,
};

pub const Variant = enum { dark, light };

pub const Scheme = struct {
    slug: []const u8,
    title: []const u8,
    license: []const u8,
    copyright: []const u8,
    source: []const u8,
    variant: Variant,
    ansi: [16]Rgb,
    background: Rgb,
    foreground: Rgb,
    selection_background: ?Rgb = null,
    selection_foreground: ?Rgb = null,
};

pub const Parsed = struct {
    schemes: []Scheme,
    upstream: ?[]const u8 = null,
    commit: ?[]const u8 = null,
};

const Building = struct {
    slug: []const u8,
    title: []const u8 = "",
    license: []const u8 = "",
    copyright: []const u8 = "",
    source: []const u8 = "",
    variant: ?Variant = null,
    ansi: [16]?Rgb = .{null} ** 16,
    background: ?Rgb = null,
    foreground: ?Rgb = null,
    selection_background: ?Rgb = null,
    selection_foreground: ?Rgb = null,
};

/// Parses and validates every `[slug]` block. The generator ignores the
/// header values; the checker verifies them against REVISION and the upstream
/// repository. Cursor colors are validated but not stored: `Theme` has none.
pub fn parse(gpa: mem.Allocator, content: []const u8) !Parsed {
    var list: std.ArrayListUnmanaged(Scheme) = .empty;
    var current: ?Building = null;
    var upstream: ?[]const u8 = null;
    var commit: ?[]const u8 = null;

    var lines = mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw| {
        const line = mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '#') {
            if (mem.startsWith(u8, line, "# Upstream:")) {
                upstream = mem.trim(u8, line["# Upstream:".len..], " \t");
            } else if (mem.startsWith(u8, line, "# Commit:")) {
                commit = mem.trim(u8, line["# Commit:".len..], " \t");
            }
            continue;
        }

        if (line[0] == '[' and line[line.len - 1] == ']') {
            if (current) |done| try appendValidated(gpa, &list, done);
            const slug = mem.trim(u8, line[1 .. line.len - 1], " \t");
            if (slug.len == 0) return error.InvalidSlug;
            current = .{ .slug = slug };
            continue;
        }

        const building = &(current orelse return error.KeyOutsideSection);
        const eq = mem.indexOfScalar(u8, line, '=') orelse return error.MissingEquals;
        const key = mem.trim(u8, line[0..eq], " \t");
        const val = mem.trim(u8, line[eq + 1 ..], " \t");

        if (mem.eql(u8, key, "variant")) {
            if (mem.eql(u8, val, "dark")) {
                building.variant = .dark;
            } else if (mem.eql(u8, val, "light")) {
                building.variant = .light;
            } else {
                return error.InvalidVariant;
            }
        } else if (mem.eql(u8, key, "upstream")) {
            building.title = val;
        } else if (mem.eql(u8, key, "license")) {
            building.license = val;
        } else if (mem.eql(u8, key, "copyright")) {
            building.copyright = val;
        } else if (mem.eql(u8, key, "source")) {
            building.source = val;
        } else if (mem.eql(u8, key, "palette")) {
            const inner_eq = mem.indexOfScalar(u8, val, '=') orelse return error.InvalidPaletteEntry;
            const slot = std.fmt.parseInt(u8, mem.trim(u8, val[0..inner_eq], " \t"), 10) catch
                return error.InvalidPaletteEntry;
            if (slot >= 16) return error.PaletteSlotOutOfRange;
            building.ansi[slot] = try parseHexRgb(mem.trim(u8, val[inner_eq + 1 ..], " \t"));
        } else if (mem.eql(u8, key, "background")) {
            building.background = try parseHexRgb(val);
        } else if (mem.eql(u8, key, "foreground")) {
            building.foreground = try parseHexRgb(val);
        } else if (mem.eql(u8, key, "selection-background")) {
            building.selection_background = try parseHexRgb(val);
        } else if (mem.eql(u8, key, "selection-foreground")) {
            building.selection_foreground = try parseHexRgb(val);
        } else if (mem.eql(u8, key, "cursor-color") or mem.eql(u8, key, "cursor-text")) {
            _ = try parseHexRgb(val);
        } else {
            return error.UnknownKey;
        }
    }

    if (current) |done| try appendValidated(gpa, &list, done);
    if (list.items.len == 0) return error.EmptySchemes;
    return .{ .schemes = list.items, .upstream = upstream, .commit = commit };
}

fn isAllowedLicense(lic: []const u8) bool {
    return mem.eql(u8, lic, "MIT") or mem.eql(u8, lic, "Apache-2.0");
}

fn appendValidated(gpa: mem.Allocator, list: *std.ArrayListUnmanaged(Scheme), b: Building) !void {
    const variant = b.variant orelse return error.MissingVariant;
    if (b.title.len == 0) return error.MissingUpstreamTitle;
    if (b.license.len == 0) return error.MissingLicense;
    if (!isAllowedLicense(b.license)) return error.UnsupportedLicense;
    if (b.copyright.len == 0) return error.MissingCopyright;
    if (!mem.startsWith(u8, b.source, "https://")) return error.InvalidSourceUrl;
    const background = b.background orelse return error.MissingGroundColor;
    const foreground = b.foreground orelse return error.MissingGroundColor;
    var ansi: [16]Rgb = undefined;
    for (b.ansi, 0..) |maybe, i| ansi[i] = maybe orelse return error.MissingAnsiSlot;
    for (list.items) |prev| if (mem.eql(u8, prev.slug, b.slug)) return error.DuplicateSlug;
    try list.append(gpa, .{
        .slug = b.slug,
        .title = b.title,
        .license = b.license,
        .copyright = b.copyright,
        .source = b.source,
        .variant = variant,
        .ansi = ansi,
        .background = background,
        .foreground = foreground,
        .selection_background = b.selection_background,
        .selection_foreground = b.selection_foreground,
    });
}

fn parseHexRgb(text: []const u8) !Rgb {
    if (text.len != 7 or text[0] != '#') return error.InvalidHexColor;
    return .{
        .r = try std.fmt.parseInt(u8, text[1..3], 16),
        .g = try std.fmt.parseInt(u8, text[3..5], 16),
        .b = try std.fmt.parseInt(u8, text[5..7], 16),
    };
}
