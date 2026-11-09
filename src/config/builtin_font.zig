//! Faces Rex ships and where they sit next to the executable.
//!
//! `zig build` installs `share/rex/fonts` to `<prefix>/share/rex/fonts`,
//! and the executable is `<prefix>/bin/rex`. An unset `[font] file` uses
//! the text faces there. An unset `emoji_file` uses the color emoji face.
//! A config that sets `none` leaves that slot empty.

const std = @import("std");
const Allocator = std.mem.Allocator;

const defaults = @import("default.zig");
const Loaded = @import("Loaded.zig");
const keys = @import("keys.zig");

const log = std.log.scoped(.config);

pub const regular_name = "GoogleSansCode[wght].ttf";
pub const italic_name = "GoogleSansCode-Italic[wght].ttf";
pub const emoji_name = "NotoColorEmoji.ttf";

/// Directory of the installed faces for an executable at `exe_path`.
/// `<prefix>/bin/rex` → `<prefix>/share/rex/fonts`.
pub fn fontDir(allocator: Allocator, exe_path: []const u8) error{ OutOfMemory, BadExePath }![]u8 {
    const bin = std.fs.path.dirname(exe_path) orelse return error.BadExePath;
    return std.fs.path.resolve(allocator, &.{ bin, "..", "share", "rex", "fonts" });
}

fn key(comptime section: keys.Section, comptime name: []const u8) keys.KeyIndex {
    return comptime keys.lookup(section, name).?;
}

fn joinZ(arena: Allocator, dir: []const u8, name: []const u8) ![:0]u8 {
    const path = try std.fs.path.join(arena, &.{ dir, name });
    return arena.dupeZ(u8, path);
}

fn exists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

/// Fills faces the loaded config left unset with the shipped files.
/// A set key wins, including `none`. The shipped text face has to be
/// present when `[font] file` was unset; a missing emoji face leaves
/// that slot empty.
pub fn apply(
    io: std.Io,
    arena: Allocator,
    loaded: *Loaded,
    exe_path: []const u8,
) error{ OutOfMemory, BadExePath, BuiltinFontMissing }!void {
    const wants_text = !loaded.set_by[key(.font, "file")].isSet();
    const wants_italic = !loaded.set_by[key(.font, "italic_file")].isSet();
    const wants_emoji = !loaded.set_by[key(.font, "emoji_file")].isSet();
    if (!wants_text and !wants_emoji and !wants_italic) return;

    const dir = try fontDir(arena, exe_path);
    var faces = &loaded.config.font.faces;

    if (wants_text) {
        const regular = try joinZ(arena, dir, regular_name);
        if (!exists(io, regular)) return error.BuiltinFontMissing;
        faces.regular = regular.ptr;
        if (wants_italic) {
            const italic = try joinZ(arena, dir, italic_name);
            if (exists(io, italic)) {
                faces.italic = italic.ptr;
            } else {
                log.warn("built-in italic missing: {s}", .{italic});
            }
        }
    }

    if (wants_emoji) {
        const emoji = try joinZ(arena, dir, emoji_name);
        if (exists(io, emoji)) {
            faces.emoji = .{ .path = emoji.ptr };
        } else {
            log.warn("built-in emoji missing: {s}", .{emoji});
        }
    }
}

test "fontDir: installed faces sit beside the executable" {
    const dir = try fontDir(std.testing.allocator, "/opt/rex/bin/rex");
    defer std.testing.allocator.free(dir);
    try std.testing.expectEqualStrings("/opt/rex/share/rex/fonts", dir);
}

test "apply: an unset config takes the shipped faces" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "bin");
    try tmp.dir.createDirPath(std.testing.io, "share/rex/fonts");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "share/rex/fonts/" ++ regular_name, .data = "regular" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "share/rex/fonts/" ++ italic_name, .data = "italic" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "share/rex/fonts/" ++ emoji_name, .data = "emoji" });

    var prefix_buf: [std.fs.max_path_bytes]u8 = undefined;
    const prefix_len = try tmp.dir.realPath(std.testing.io, &prefix_buf);
    const prefix = prefix_buf[0..prefix_len];
    const exe = try std.fmt.allocPrint(std.testing.allocator, "{s}/bin/rex", .{prefix});
    defer std.testing.allocator.free(exe);

    var arena_owner: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_owner.deinit();
    var loaded = try Loaded.load(std.testing.allocator, std.testing.io, &defaults.default, null, &.{});
    defer loaded.deinit(std.testing.allocator);

    try apply(std.testing.io, loaded.arena.allocator(), &loaded, exe);
    const faces = loaded.config.font.faces;
    const dir = try fontDir(std.testing.allocator, exe);
    defer std.testing.allocator.free(dir);
    const regular = try std.fs.path.join(std.testing.allocator, &.{ dir, regular_name });
    defer std.testing.allocator.free(regular);
    const italic = try std.fs.path.join(std.testing.allocator, &.{ dir, italic_name });
    defer std.testing.allocator.free(italic);
    const emoji = try std.fs.path.join(std.testing.allocator, &.{ dir, emoji_name });
    defer std.testing.allocator.free(emoji);
    try std.testing.expectEqualStrings(regular, std.mem.span(faces.regular));
    try std.testing.expectEqualStrings(italic, std.mem.span(faces.italic.?));
    try std.testing.expectEqualStrings(emoji, std.mem.span(faces.emoji.?.path));
}

test "apply: a set file and emoji none stay as the config wrote them" {
    var loaded = try Loaded.load(std.testing.allocator, std.testing.io, &defaults.default, null, &.{.{
        .label = "user",
        .from = .{ .text = .{ .bytes = "[font]\nfile = /fonts/custom.ttf\nitalic_file = none\nemoji_file = none\n", .dir = "/" } },
    }});
    defer loaded.deinit(std.testing.allocator);

    try apply(std.testing.io, loaded.arena.allocator(), &loaded, "/opt/rex/bin/rex");
    const faces = loaded.config.font.faces;
    try std.testing.expectEqualStrings("/fonts/custom.ttf", std.mem.span(faces.regular));
    try std.testing.expectEqual(null, faces.italic);
    try std.testing.expectEqual(null, faces.emoji);
}

test "apply: a missing built-in text face is an error" {
    var loaded = try Loaded.load(std.testing.allocator, std.testing.io, &defaults.default, null, &.{});
    defer loaded.deinit(std.testing.allocator);
    try std.testing.expectError(error.BuiltinFontMissing, apply(std.testing.io, loaded.arena.allocator(), &loaded, "/opt/rex/bin/rex"));
}
