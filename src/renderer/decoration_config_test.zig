const std = @import("std");
const testing = std.testing;

const config = @import("../config/root.zig");
const config_default = @import("../config/default.zig").default;
const decoration_config = @import("decoration_config.zig");

test "decoration_config.build: one value carries config into both consumers" {
    var cfg = config_default;
    cfg.decoration.skip_ink = false;
    cfg.decoration.order = .under_text;
    cfg.decoration.alpha = 0.5;
    cfg.decoration.underline_offset_px = 2;
    cfg.decoration.double_gap_px = 3;
    cfg.decoration.phase = .run;
    cfg.decoration.underline_color = .{ .r = 1, .g = 2, .b = 3 };
    cfg.hyperlink.underline = .hover;

    const option = decoration_config.build(&cfg);
    try testing.expect(!option.skip_ink.enabled);
    try testing.expectEqual(config.decoration.Order.under_text, option.order);
    try testing.expectEqual(@as(f32, 0.5), option.alpha);
    try testing.expectEqual(@as(f32, 2), option.underline.offset);
    try testing.expectEqual(@as(f32, 3), option.double_gap.?);
    try testing.expectEqual(config.decoration.Phase.run, option.phase);
    try testing.expectEqual([3]u8{ 1, 2, 3 }, option.color.underline.?);
    try testing.expectEqual(config.hyperlink.UnderlineVisibility.hover, option.link.underline);
}
