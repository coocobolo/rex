//! Tests for the `[hyperlink]` defaults (ADR 0012).

const std = @import("std");
const testing = std.testing;
const hyperlink = @import("hyperlink.zig");

test "hyperlink: links on by default, file scheme off, system command" {
    const cfg: hyperlink.Hyperlink = .{};
    try testing.expect(cfg.enabled);
    try testing.expectEqual(.always, cfg.underline);
    try testing.expectEqual(null, cfg.underline_color);
    try testing.expectEqualStrings("", cfg.open_command);

    try testing.expect(cfg.schemes.contains(.http));
    try testing.expect(cfg.schemes.contains(.https));
    try testing.expect(cfg.schemes.contains(.mailto));
    try testing.expect(!cfg.schemes.contains(.file));

    const Scheme = hyperlink.Scheme;
    try testing.expect(std.meta.stringToEnum(Scheme, "https") == .https);
    try testing.expect(std.meta.stringToEnum(Scheme, "javascript") == null);
    try testing.expectEqual(.single, cfg.underline_style);
    try testing.expectEqual(.ctrl, cfg.show_targets);
    try testing.expectEqual(.multiline, cfg.target_style);
    try testing.expectEqual(@as(u16, 40), cfg.tooltip.head_bytes);
    try testing.expectEqual(@as(u16, 24), cfg.tooltip.tail_bytes);
    try testing.expectEqual(@as(u16, 40), cfg.tooltip.line_bytes);
    try testing.expectEqual(@as(u8, 5), cfg.tooltip.max_lines);
    try testing.expectEqual(@as(u16, 360), cfg.tooltip.width);
    try testing.expectEqual(@as(u16, 520), cfg.tooltip.wide_width);
}
