const std = @import("std");

const Banner = @import("Banner.zig");
const Level = Banner.Level;
const Option = Banner.Option;
const computeLayout = Banner.computeLayout;
const getMessage = Banner.getMessage;
const getTitle = Banner.getTitle;
const init = Banner.init;

const Table = @import("hotspot.zig").Table;

test "Banner: init, layout computation, and message formatting" {
    const testing = std.testing;

    const banner = Banner.init(.err, "Syntax error (line 14, col 5)", "unknown key 'foo'");
    try testing.expectEqual(Level.err, banner.level);
    try testing.expectEqualStrings("Syntax error (line 14, col 5)", banner.getTitle());
    try testing.expectEqualStrings("unknown key 'foo'", banner.getMessage());

    // Test docked style
    const docked_opt = Option{ .placement = .docked, .dismiss_str = "Dismiss [×]" };
    const docked_layout = banner.computeLayout(80, 24, docked_opt);
    try testing.expectEqual(@as(u16, 0), docked_layout.col);
    try testing.expectEqual(@as(u16, 0), docked_layout.row);
    try testing.expectEqual(@as(u16, 80), docked_layout.width);
    try testing.expectEqual(@as(u16, 1), docked_layout.height);
    try testing.expectEqual(@as(u16, 0), docked_layout.text_row);
    try testing.expectEqual(@as(u16, 0), docked_layout.dismiss_row);
    try testing.expect(docked_layout.dismiss_col > 60);
    try testing.expect(docked_layout.dismiss_w > 0);

    var hs_docked = Table{};
    hs_docked.add(docked_layout.dismiss_col, docked_layout.dismiss_row, docked_layout.dismiss_w, 1, .{ .banner_dismiss = 0 });
    const hit_docked = hs_docked.hitTest(docked_layout.dismiss_col + 1, docked_layout.dismiss_row);
    try testing.expect(hit_docked != null);
    try testing.expectEqual(@import("hotspot.zig").Tag.banner_dismiss, std.meta.activeTag(hit_docked.?));

    // Test floating toast style
    const float_opt = Option{ .placement = .floating, .position = .top_center, .margin_rows = 1 };
    const float_layout = banner.computeLayout(80, 24, float_opt);
    try testing.expect(float_layout.width >= float_opt.min_cols);
    try testing.expect(float_layout.width <= float_opt.max_cols);
    try testing.expectEqual(@as(u16, 3), float_layout.height);
    try testing.expectEqual(@as(u16, 1), float_layout.row);
    try testing.expectEqual(@as(u16, 2), float_layout.text_row);
    try testing.expectEqual(@as(u16, 2), float_layout.dismiss_row);
    try testing.expectEqual((80 - float_layout.width) / 2, float_layout.col);
    try testing.expect(float_layout.dismiss_col > float_layout.text_col);

    var hs_float = Table{};
    hs_float.add(float_layout.dismiss_col, float_layout.dismiss_row, float_layout.dismiss_w, 1, .{ .banner_dismiss = 0 });
    const hit_float = hs_float.hitTest(float_layout.dismiss_col, float_layout.dismiss_row);
    try testing.expect(hit_float != null);
    try testing.expectEqual(@import("hotspot.zig").Tag.banner_dismiss, std.meta.activeTag(hit_float.?));
}
