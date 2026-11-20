//! Tests for the `[decoration]` defaults (ADR 0014).

const std = @import("std");
const testing = std.testing;
const decoration = @import("decoration.zig");

test "decoration: defaults keep the current renderer behaviour" {
    const cfg: decoration.Decoration = .{};
    try testing.expect(cfg.skip_ink);
    try testing.expectEqual(decoration.Order.over_text, cfg.order);
    try testing.expectEqual(@as(f32, 1.0), cfg.alpha);
    try testing.expect(cfg.dim);
    try testing.expect(cfg.blink);
    try testing.expectEqual(@as(f32, 0.25), cfg.skip_ink_threshold);
    try testing.expectEqual(null, cfg.skip_ink_gap);
    try testing.expectEqual(null, cfg.skip_ink_min_segment);
    try testing.expectEqual(null, cfg.underline_color);
    try testing.expectEqual(null, cfg.strikethrough_color);
    try testing.expectEqual(null, cfg.overline_color);

    try testing.expect(cfg.skip_ink_styles.contains(.single));
    try testing.expect(cfg.skip_ink_styles.contains(.dashed));
}
