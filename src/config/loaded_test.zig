const std = @import("std");
const Loaded = @import("Loaded.zig");
const keys = @import("keys.zig");
const Config = @import("Config.zig");
const test_config = @import("test_fixtures.zig").test_config;

const gpa = std.testing.allocator;
const io = std.testing.io;

fn text(label: []const u8, bytes: []const u8) Loaded.Source {
    return .{ .label = label, .from = .{ .text = .{ .bytes = bytes, .dir = "/etc/rex" } } };
}

fn key(comptime section: keys.Section, comptime name: []const u8) keys.KeyIndex {
    return comptime keys.lookup(section, name).?;
}

/// A temporary directory with its path relative to the working directory,
/// which is how `Loaded` opens files.
const Tmp = struct {
    tmp: std.testing.TmpDir,

    fn init() Tmp {
        return .{ .tmp = std.testing.tmpDir(.{}) };
    }

    fn deinit(t: *Tmp) void {
        t.tmp.cleanup();
    }

    fn write(t: *Tmp, name: []const u8, data: []const u8) !void {
        try t.tmp.dir.writeFile(io, .{ .sub_path = name, .data = data });
    }

    /// The caller frees the result.
    fn path(t: *Tmp, name: []const u8) ![]u8 {
        return std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/{s}", .{ &t.tmp.sub_path, name });
    }
};

test "load: later layers override earlier ones, provenance names the layer" {
    var loaded = try Loaded.load(gpa, io, &test_config, null, &.{
        text("system", "[font]\nsize = 10\nsize_step = 3\n"),
        text("user", "[font]\n\nsize = 12\n"),
    });
    defer loaded.deinit(gpa);
    try std.testing.expectEqual(12, loaded.config.font.size);
    try std.testing.expectEqual(3, loaded.config.font.size_step);

    const size = loaded.set_by[key(.font, "size")];
    try std.testing.expectEqual(1, size.layer);
    try std.testing.expectEqualStrings("size", loaded.layers[1].state.loaded.tree.tokenSlice(size.token));
    try std.testing.expectEqual(0, loaded.set_by[key(.font, "size_step")].layer);
    try std.testing.expect(!loaded.set_by[key(.font, "weight")].isSet());
    try std.testing.expectEqual(null, loaded.firstError());
}

test "load: default restores the base, not the lower layer" {
    var loaded = try Loaded.load(gpa, io, &test_config, null, &.{
        text("system", "[font]\nsize = 10\n"),
        text("user", "[font]\nsize = default\n"),
    });
    defer loaded.deinit(gpa);
    try std.testing.expectEqual(test_config.font.size, loaded.config.font.size);
    try std.testing.expectEqual(1, loaded.set_by[key(.font, "size")].layer);
}

test "load: key bindings merge across layers" {
    var loaded = try Loaded.load(gpa, io, &test_config, null, &.{
        text("system", "[keybinds]\nctrl+shift+c = copy_selection\nctrl+shift+v = paste_clipboard\n"),
        text("user", "[keybinds]\nctrl+shift+c = quit\n"),
    });
    defer loaded.deinit(gpa);
    const keymap = loaded.config.keymap;
    try std.testing.expectEqual(2, keymap.len);
    try std.testing.expectEqual(.v, keymap[0].key);
    try std.testing.expectEqual(.paste_clipboard, keymap[0].action);
    try std.testing.expectEqual(.c, keymap[1].key);
    try std.testing.expectEqual(.quit, keymap[1].action);
}

test "load: relative paths resolve against the source's directory" {
    var loaded = try Loaded.load(gpa, io, &test_config, null, &.{text("system", "[font]\nfile = fonts/a.ttf\n")});
    defer loaded.deinit(gpa);
    try std.testing.expectEqualStrings("/etc/rex/fonts/a.ttf", std.mem.span(loaded.config.font.faces.regular));
}

test "load: a missing file is not a problem and changes nothing" {
    var loaded = try Loaded.load(gpa, io, &test_config, null, &.{.file("no/such/dir/config")});
    defer loaded.deinit(gpa);
    try std.testing.expectEqual(.missing, std.meta.activeTag(loaded.layers[0].state));
    try std.testing.expect(!loaded.found());
    try std.testing.expectEqual(null, loaded.firstError());
    try std.testing.expectEqualDeep(test_config, loaded.config);
}

test "load: reads a file, relative paths resolve against its directory" {
    var tmp: Tmp = .init();
    defer tmp.deinit();
    try tmp.write("config", "[font]\nsize = 18\nfile = a.ttf\n");
    const path = try tmp.path("config");
    defer gpa.free(path);

    var loaded = try Loaded.load(gpa, io, &test_config, null, &.{.file(path)});
    defer loaded.deinit(gpa);
    try std.testing.expect(loaded.found());
    try std.testing.expectEqualStrings(path, loaded.layers[0].source.label);
    try std.testing.expectEqual(18, loaded.config.font.size);
    const font = std.mem.span(loaded.config.font.faces.regular);
    try std.testing.expectEqualStrings(std.fs.path.dirname(path).?, std.fs.path.dirname(font).?);
}

test "load: a directory is unreadable" {
    var tmp: Tmp = .init();
    defer tmp.deinit();
    try tmp.tmp.dir.createDir(io, "config", .default_dir);
    const path = try tmp.path("config");
    defer gpa.free(path);

    var loaded = try Loaded.load(gpa, io, &test_config, null, &.{.file(path)});
    defer loaded.deinit(gpa);
    try std.testing.expectEqual(error.IsDir, loaded.layers[0].state.unreadable);
    try std.testing.expect(loaded.found());
    try std.testing.expectEqual(error.IsDir, loaded.firstError().?.unreadable.err);
}

test "load: a file of exactly max_bytes loads, one byte more is too big" {
    var tmp: Tmp = .init();
    defer tmp.deinit();
    // One comment line: valid and sets nothing.
    const bytes = try gpa.alloc(u8, Loaded.max_bytes + 1);
    defer gpa.free(bytes);
    @memset(bytes, '#');
    try tmp.write("fits", bytes[0..Loaded.max_bytes]);
    try tmp.write("big", bytes);
    const fits = try tmp.path("fits");
    defer gpa.free(fits);
    const big = try tmp.path("big");
    defer gpa.free(big);

    var loaded = try Loaded.load(gpa, io, &test_config, null, &.{
        .file(fits),
        .file(big),
        text("text", bytes),
    });
    defer loaded.deinit(gpa);
    try std.testing.expectEqual(.loaded, std.meta.activeTag(loaded.layers[0].state));
    try std.testing.expectEqual(error.FileTooBig, loaded.layers[1].state.unreadable);
    try std.testing.expectEqual(error.FileTooBig, loaded.layers[2].state.unreadable);
}

test "firstError: an unreadable layer comes before any syntax error" {
    var tmp: Tmp = .init();
    defer tmp.deinit();
    try tmp.tmp.dir.createDir(io, "config", .default_dir);
    const path = try tmp.path("config");
    defer gpa.free(path);

    var loaded = try Loaded.load(gpa, io, &test_config, null, &.{
        text("system", "nope = 1\n[font\n"),
        .file(path),
    });
    defer loaded.deinit(gpa);
    const problem = loaded.firstError().?;
    try std.testing.expectEqual(&loaded.layers[1], problem.unreadable.layer);
}

test "firstError: the first syntax error, warnings are not problems" {
    var loaded = try Loaded.load(gpa, io, &test_config, null, &.{
        text("system", "nope = 1\n"),
        text("user", "[font]\nsize = 9\n[font\n[x\n"),
    });
    defer loaded.deinit(gpa);
    const problem = loaded.firstError().?.syntax;
    try std.testing.expectEqual(&loaded.layers[1], problem.layer);
    try std.testing.expectEqual(.unclosed_section, problem.err.tag);
    // Valid entries of a file with errors are still applied (P4 is the caller's).
    try std.testing.expectEqual(9, loaded.config.font.size);
}

test "takeArena: the config outlives the diagnostics" {
    var loaded = try Loaded.load(gpa, io, &test_config, null, &.{text("system", "[font]\nfile = a.ttf\n")});
    var arena = loaded.takeArena();
    defer arena.deinit();
    const config = loaded.config;
    loaded.deinit(gpa);
    try std.testing.expectEqualStrings("/etc/rex/a.ttf", std.mem.span(config.font.faces.regular));
}

fn loadAll(allocator: std.mem.Allocator, path: []const u8) !void {
    var loaded = try Loaded.load(allocator, io, &test_config, "/home/u", &.{
        text("system", "[font]\nfile = ~/a.ttf\n[keybinds]\nctrl+shift+c = quit\n"),
        .file(path),
        text("user", "[font\nnope = 1\n[keybinds]\nctrl+shift+v = paste_clipboard\n"),
    });
    loaded.deinit(allocator);
}

test "load: no leaks on any allocation failure" {
    var tmp: Tmp = .init();
    defer tmp.deinit();
    try tmp.write("config", "[font]\nsize = 18\nfile = b.ttf\n[keybinds]\nctrl+shift+c = copy_selection\n");
    const path = try tmp.path("config");
    defer gpa.free(path);
    try std.testing.checkAllAllocationFailures(gpa, loadAll, .{path});
}

fn expectFallbacks(config: Config, expected: []const []const u8) !void {
    const faces = config.font.faces.fallbacks;
    try std.testing.expectEqual(expected.len, faces.len);
    for (expected, faces) |path, face| try std.testing.expectEqualStrings(path, std.mem.span(face.path));
}

test "load: a layer's fallback lines replace the lower layer's list" {
    var base = test_config;
    base.font.faces.fallbacks = &.{.static("/base.ttf")};

    var replaced = try Loaded.load(gpa, io, &base, null, &.{
        text("system", "[font]\nfallback = /a.ttf\nfallback = /b.ttf\n"),
        text("user", "[font]\nfallback = /c.ttf\n"),
    });
    defer replaced.deinit(gpa);
    try expectFallbacks(replaced.config, &.{"/c.ttf"});

    var kept = try Loaded.load(gpa, io, &base, null, &.{
        text("system", "[font]\nfallback = /a.ttf\nfallback = /b.ttf\n"),
        text("user", "[font]\nsize = 12\n"),
    });
    defer kept.deinit(gpa);
    try expectFallbacks(kept.config, &.{ "/a.ttf", "/b.ttf" });

    var restored = try Loaded.load(gpa, io, &base, null, &.{
        text("system", "[font]\nfallback = /a.ttf\n"),
        text("user", "[font]\nfallback = default\nfallback = /x.ttf\n"),
    });
    defer restored.deinit(gpa);
    try expectFallbacks(restored.config, &.{ "/base.ttf", "/x.ttf" });
}

test "load: a layer whose fallback lines are all invalid keeps the lower list" {
    var loaded = try Loaded.load(gpa, io, &test_config, null, &.{
        text("system", "[font]\nfallback = /a.ttf\n"),
        text("user", "[font]\nfallback = ~/b.ttf\n"),
    });
    defer loaded.deinit(gpa);
    try expectFallbacks(loaded.config, &.{"/a.ttf"});
    try std.testing.expectEqual(0, loaded.set_by[key(.font, "fallback")].layer);
}

test "load: each font style file layers on its own" {
    var loaded = try Loaded.load(gpa, io, &test_config, null, &.{
        text("system", "[font]\nfile = /r.ttf\nbold_file = /b.ttf\nitalic_file = /i.ttf\n"),
        text("user", "[font]\nfile = /r2.ttf\nitalic_file = none\n"),
    });
    defer loaded.deinit(gpa);
    const faces = loaded.config.font.faces;
    try std.testing.expectEqualStrings("/r2.ttf", std.mem.span(faces.regular));
    try std.testing.expectEqualStrings("/b.ttf", std.mem.span(faces.bold.?));
    try std.testing.expectEqual(null, faces.italic);
    try std.testing.expectEqualStrings("/b.ttf", std.mem.span(faces.face(.bold).path));
    try std.testing.expectEqualStrings("/r2.ttf", std.mem.span(faces.face(.bold_italic).path));
}
