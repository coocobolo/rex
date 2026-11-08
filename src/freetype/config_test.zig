const std = @import("std");
const testing = std.testing;

const Config = @import("Config.zig");

test "pixelSize: logical size times the display scale, rounded" {
    const cases = [_]struct { scale: f32, px: u32 }{
        .{ .scale = 1.0, .px = 21 },
        .{ .scale = 1.25, .px = 26 }, // 26.25
        .{ .scale = 1.5, .px = 32 }, // 31.5 rounds away from zero
        .{ .scale = 1.75, .px = 37 }, // 36.75
        .{ .scale = 2.0, .px = 42 },
    };
    for (cases) |case| try testing.expectEqual(case.px, Config.pixelSize(21, case.scale));
}

test "pixelSize: at least one pixel" {
    try testing.expectEqual(1, Config.pixelSize(0, 1.0));
    try testing.expectEqual(1, Config.pixelSize(1, 0.25));
}

test "pixelSize: a scale GLFW couldn't determine counts as 100%" {
    try testing.expectEqual(21, Config.pixelSize(21, 0));
    try testing.expectEqual(21, Config.pixelSize(21, -1.5));
    try testing.expectEqual(21, Config.pixelSize(21, std.math.nan(f32)));
    try testing.expectEqual(21, Config.pixelSize(21, std.math.inf(f32)));
}

test "Faces.face: a style without its own file takes the next one" {
    const one: Config.Faces = .{ .regular = "/r.ttf", .regular_weight = 350, .bold_weight = 650 };
    try expectFace(one.face(.regular), "/r.ttf", 350);
    try expectFace(one.face(.bold), "/r.ttf", 650);
    try expectFace(one.face(.italic), "/r.ttf", 350);
    try expectFace(one.face(.bold_italic), "/r.ttf", 650);

    const italic: Config.Faces = .{ .regular = "/r.ttf", .italic = "/i.ttf" };
    try expectFace(italic.face(.bold), "/r.ttf", 800);
    try expectFace(italic.face(.bold_italic), "/i.ttf", 800);

    const all: Config.Faces = .{ .regular = "/r.ttf", .bold = "/b.ttf", .italic = "/i.ttf", .bold_italic = "/bi.ttf" };
    try expectFace(all.face(.bold), "/b.ttf", 800);
    try expectFace(all.face(.bold_italic), "/bi.ttf", 800);
}

fn expectFace(face: Config.Face, path: []const u8, weight: f64) !void {
    try testing.expectEqualStrings(path, std.mem.span(face.path));
    try testing.expectEqual(weight, face.weight_axis.?);
}

test "Faces.eql: paths compare by content, every setting counts" {
    var regular_a = "/f/a.ttf".*;
    var regular_b = "/f/a.ttf".*;
    const base: Config.Faces = .{
        .regular = &regular_a,
        .italic = "/f/i.ttf",
        .emoji = .static("/f/e.ttf"),
        .fallbacks = &.{ .static("/f/x.ttf"), .static("/f/y.ttc") },
    };
    var same = base;
    same.regular = &regular_b;
    try testing.expect(base.eql(same));

    var weight = base;
    weight.bold_weight = 600;
    try testing.expect(!base.eql(weight));
    var italic = base;
    italic.italic = null;
    try testing.expect(!base.eql(italic));
    var bold = base;
    bold.bold = "/f/b.ttf";
    try testing.expect(!base.eql(bold));
    var emoji = base;
    emoji.emoji = null;
    try testing.expect(!base.eql(emoji));
    var fallbacks = base;
    fallbacks.fallbacks = &.{.static("/f/x.ttf")};
    try testing.expect(!base.eql(fallbacks));
    var order = base;
    order.fallbacks = &.{ .static("/f/y.ttc"), .static("/f/x.ttf") };
    try testing.expect(!base.eql(order));
}
