const std = @import("std");
const testing = std.testing;

const Ast = @import("Ast.zig");
const Sema = @import("Sema.zig");
const default = @import("default.zig");
const writer = @import("writer.zig");

test "writer: replace existing value preserves comments, spacing, and order" {
    const src =
        \\# Header comment
        \\[font]
        \\size = 13.0   # inline comment
        \\weight = 400
        \\
        \\[ui]
        \\color_scheme = dark
        \\
    ;
    const out = try writer.setValue(testing.allocator, src, .font, "size", "16.5");
    defer testing.allocator.free(out);

    try testing.expectEqualStrings(
        \\# Header comment
        \\[font]
        \\size = 16.5   # inline comment
        \\weight = 400
        \\
        \\[ui]
        \\color_scheme = dark
        \\
    , out);
}

test "writer: replace empty assignment (key =)" {
    const src =
        \\[font]
        \\file = # unset
        \\
    ;
    const out = try writer.setValue(testing.allocator, src, .font, "file", "~/font.ttf");
    defer testing.allocator.free(out);

    try testing.expectEqualStrings(
        \\[font]
        \\file = ~/font.ttf # unset
        \\
    , out);
}

test "writer: duplicate key updates last occurrence" {
    const src =
        \\[font]
        \\size = 12
        \\size = 14
        \\
    ;
    const out = try writer.setValue(testing.allocator, src, .font, "size", "18");
    defer testing.allocator.free(out);

    try testing.expectEqualStrings(
        \\[font]
        \\size = 12
        \\size = 18
        \\
    , out);
}

test "writer: append missing key to existing section" {
    const src =
        \\[ui]
        \\color_scheme = dark
        \\
        \\[font]
        \\size = 13
        \\
    ;
    const out = try writer.setValue(testing.allocator, src, .ui, "accent", "#ff0000");
    defer testing.allocator.free(out);

    try testing.expectEqualStrings(
        \\[ui]
        \\color_scheme = dark
        \\accent = #ff0000
        \\
        \\[font]
        \\size = 13
        \\
    , out);
}

test "writer: append missing key to empty section" {
    const src =
        \\[wellbeing.dashboard]
        \\
        \\[ui]
        \\color_scheme = light
        \\
    ;
    const out = try writer.setValue(testing.allocator, src, .@"wellbeing.dashboard", "timer_chart", "ring");
    defer testing.allocator.free(out);

    try testing.expectEqualStrings(
        \\[wellbeing.dashboard]
        \\timer_chart = ring
        \\
        \\[ui]
        \\color_scheme = light
        \\
    , out);
}

test "writer: append new section to non-empty file" {
    const src =
        \\[ui]
        \\color_scheme = dark
        \\
    ;
    const out = try writer.setValue(testing.allocator, src, .@"wellbeing.dashboard", "program_chart", "donut");
    defer testing.allocator.free(out);

    try testing.expectEqualStrings(
        \\[ui]
        \\color_scheme = dark
        \\
        \\[wellbeing.dashboard]
        \\program_chart = donut
        \\
    , out);
}

test "writer: empty file creates section and key" {
    const out = try writer.setValue(testing.allocator, "", .ui, "color_scheme", "light");
    defer testing.allocator.free(out);

    try testing.expectEqualStrings(
        \\[ui]
        \\color_scheme = light
        \\
    , out);
}

test "writer: root section inserts before first section header" {
    const src =
        \\# top comment
        \\[ui]
        \\color_scheme = dark
        \\
    ;
    const out = try writer.setValue(testing.allocator, src, .root, "theme", "nord");
    defer testing.allocator.free(out);

    try testing.expectEqualStrings(
        \\# top comment
        \\theme = nord
        \\
        \\[ui]
        \\color_scheme = dark
        \\
    , out);
}

test "writer: preserves CRLF line endings" {
    const src = "[ui]\r\ncolor_scheme = dark\r\n";
    const out = try writer.setValue(testing.allocator, src, .@"wellbeing.dashboard", "timer_chart", "ring");
    defer testing.allocator.free(out);

    try testing.expectEqualStrings(
        "[ui]\r\ncolor_scheme = dark\r\n\r\n[wellbeing.dashboard]\r\ntimer_chart = ring\r\n",
        out,
    );
}

test "writer: missing final newline handled cleanly" {
    const src = "[ui]\ncolor_scheme = dark";
    const out = try writer.setValue(testing.allocator, src, .@"wellbeing.dashboard", "timer_chart", "ring");
    defer testing.allocator.free(out);

    try testing.expectEqualStrings(
        "[ui]\ncolor_scheme = dark\n\n[wellbeing.dashboard]\ntimer_chart = ring\n",
        out,
    );
}

test "writer: rejects invalid key or multiline value" {
    try testing.expectError(error.InvalidKey, writer.setValue(testing.allocator, "", .ui, "", "1"));
    try testing.expectError(error.InvalidKey, writer.setValue(testing.allocator, "", .ui, "a=b", "1"));
    try testing.expectError(error.InvalidValue, writer.setValue(testing.allocator, "", .ui, "color_scheme", ""));
    try testing.expectError(error.InvalidValue, writer.setValue(testing.allocator, "", .ui, "color_scheme", "light\nbad = 1"));
}

test "writer: round-trip over documented default config" {
    const out = try writer.setValue(testing.allocator, default.text, .@"wellbeing.dashboard", "timer_chart", "ring");
    defer testing.allocator.free(out);

    var tree = try Ast.parse(testing.allocator, out);
    defer tree.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), tree.errors.len);

    var cfg = default.default;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var res = try Sema.apply(testing.allocator, &tree, &cfg, .{
        .defaults = &default.default,
        .arena = arena.allocator(),
        .dir = ".",
        .home = null,
    });
    defer res.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), res.errors.len);
    try testing.expectEqual(.ring, cfg.wellbeing.dashboard.timer_chart);
}

test "writer: writeKey creates missing file and updates existing file atomically" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = testing.io;
    const base_path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/nested/config", .{tmp.sub_path});
    defer testing.allocator.free(base_path);

    try writer.writeKey(testing.allocator, io, base_path, .ui, "color_scheme", "light");
    const first = try std.Io.Dir.cwd().readFileAlloc(io, base_path, testing.allocator, .limited(4096));
    defer testing.allocator.free(first);
    try testing.expectEqualStrings("[ui]\ncolor_scheme = light\n", first);

    try writer.writeKey(testing.allocator, io, base_path, .@"wellbeing.dashboard", "timer_chart", "ring");
    const second = try std.Io.Dir.cwd().readFileAlloc(io, base_path, testing.allocator, .limited(4096));
    defer testing.allocator.free(second);
    try testing.expectEqualStrings(
        \\[ui]
        \\color_scheme = light
        \\
        \\[wellbeing.dashboard]
        \\timer_chart = ring
        \\
    , second);

    try testing.expectError(
        error.InvalidValue,
        writer.writeKey(testing.allocator, io, base_path, .ui, "color_scheme", "bad\nline"),
    );
    const unchanged = try std.Io.Dir.cwd().readFileAlloc(io, base_path, testing.allocator, .limited(4096));
    defer testing.allocator.free(unchanged);
    try testing.expectEqualStrings(second, unchanged);
}

test "writer: setListValues replaces existing rows, preserves comments, and writes none when empty" {
    const src =
        \\[font]
        \\size = 13
        \\fallback = /a.ttf
        \\# keep comment
        \\fallback = /b.ttf
        \\weight = 400
        \\
    ;
    const replaced = try writer.setListValues(testing.allocator, src, .font, "fallback", &.{ "/x.ttf", "/y.ttf" });
    defer testing.allocator.free(replaced);

    try testing.expectEqualStrings(
        \\[font]
        \\size = 13
        \\fallback = /x.ttf
        \\fallback = /y.ttf
        \\# keep comment
        \\weight = 400
        \\
    , replaced);

    const cleared = try writer.setListValues(testing.allocator, replaced, .font, "fallback", &.{});
    defer testing.allocator.free(cleared);

    try testing.expectEqualStrings(
        \\[font]
        \\size = 13
        \\fallback = none
        \\# keep comment
        \\weight = 400
        \\
    , cleared);
}

test "writer: setListValues inserts new section when missing" {
    const out = try writer.setListValues(testing.allocator, "[ui]\ncolor_scheme = dark\n", .shell, "argument", &.{ "--login", "-i" });
    defer testing.allocator.free(out);

    try testing.expectEqualStrings(
        \\[ui]
        \\color_scheme = dark
        \\
        \\[shell]
        \\argument = --login
        \\argument = -i
        \\
    , out);
}
