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

test "Faces.eql: paths compare by content, every setting counts" {
    var upright_a = "/f/a.ttf".*;
    var upright_b = "/f/a.ttf".*;
    const base: Config.Faces = .{
        .family = .{ .variable = .{ .upright = &upright_a, .italic = "/f/i.ttf" } },
        .emoji = .static("/f/e.ttf"),
        .fallbacks = &.{ .static("/f/x.ttf"), .static("/f/y.ttc") },
    };
    var same = base;
    same.family.variable.upright = &upright_b;
    try testing.expect(base.eql(same));

    var weight = base;
    weight.family.variable.bold_weight = 600;
    try testing.expect(!base.eql(weight));
    var italic = base;
    italic.family.variable.italic = null;
    try testing.expect(!base.eql(italic));
    var emoji = base;
    emoji.emoji = null;
    try testing.expect(!base.eql(emoji));
    var fallbacks = base;
    fallbacks.fallbacks = &.{.static("/f/x.ttf")};
    try testing.expect(!base.eql(fallbacks));
    var order = base;
    order.fallbacks = &.{ .static("/f/y.ttc"), .static("/f/x.ttf") };
    try testing.expect(!base.eql(order));
    var static = base;
    static.family = .{ .static = .{ .regular = "/f/a.ttf", .bold = "/f/a.ttf", .italic = "/f/a.ttf", .bold_italic = "/f/a.ttf" } };
    try testing.expect(!base.eql(static));
}
