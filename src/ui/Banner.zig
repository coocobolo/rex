//! Persistent top-docked notification banner for actionable alerts and diagnostics.
//!
//! Renders a full-width notification bar across the top row of the viewport,
//! displaying a semantic status background, warning or error icon, structured diagnostic
//! message with source line numbers, and an interactive dismiss action button.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Tokens = @import("../color/Tokens.zig").Tokens;
const Card = @import("../renderer/Card.zig");
const Cell = @import("../renderer/Cell.zig");
const Text = @import("Text.zig");
const Drawer = Text.Drawer;
const HotspotTable = @import("hotspot.zig").HotspotTable;
const UiAction = @import("hotspot.zig").UiAction;

pub const Banner = @This();

pub const Level = enum {
    warn,
    err,
    info,
};

pub const Layout = struct {
    col: u16 = 0,
    row: u16 = 0,
    width: u16,
    height: u16 = 1,
    dismiss_col: u16,
    dismiss_w: u16,
};

level: Level = .err,
message: [256]u8 = undefined,
message_len: usize = 0,
line: ?usize = null,
col: ?usize = null,
dismiss_str: []const u8 = "Dismiss [×]",

/// Constructs a new persistent banner with a diagnostic message and optional source coordinates.
pub fn init(level: Level, msg: []const u8, line: ?usize, col: ?usize) Banner {
    var b = Banner{
        .level = level,
        .line = line,
        .col = col,
    };
    const copy_len = @min(msg.len, b.message.len);
    @memcpy(b.message[0..copy_len], msg[0..copy_len]);
    b.message_len = copy_len;
    return b;
}

/// Returns the formatted message slice stored in the banner buffer.
pub fn getMessage(self: *const Banner) []const u8 {
    return self.message[0..self.message_len];
}

/// Computes the horizontal placement of banner components across the viewport.
pub fn computeLayout(self: *const Banner, total_cols: u16) Layout {
    const dismiss_w = Text.measure(self.dismiss_str);
    const dismiss_col = if (total_cols > dismiss_w + 1) total_cols - dismiss_w - 1 else 0;
    return .{
        .col = 0,
        .row = 0,
        .width = total_cols,
        .height = 1,
        .dismiss_col = dismiss_col,
        .dismiss_w = dismiss_w,
    };
}

/// Renders the banner background card, leading status icon, message, and dismiss action.
pub fn render(
    self: *const Banner,
    tokens: Tokens,
    total_cols: u16,
    total_rows: u16,
    card_buffer: *std.ArrayListUnmanaged(Card.Instance),
    drawer: Drawer,
    hotspots: ?*HotspotTable,
) Layout {
    _ = total_rows;
    const layout = self.computeLayout(total_cols);

    // Determine semantic color palette based on severity level
    const accent_color: [3]u8 = switch (self.level) {
        .err => tokens.critical,
        .warn => tokens.warning,
        .info => tokens.accent,
    };

    const bg_color: [4]f32 = switch (self.level) {
        .err => .{ 0.32, 0.08, 0.08, 0.96 },
        .warn => .{ 0.30, 0.22, 0.05, 0.96 },
        .info => .{ 0.08, 0.20, 0.30, 0.96 },
    };

    const border_f32 = Tokens.toF32Rgba(accent_color, 255);

    // Full-width top bar card instance with sharp rectangular geometry
    card_buffer.append(drawer.allocator, .{
        .col = layout.col,
        .row = layout.row,
        .width = layout.width,
        .height = layout.height,
        .bg_color = bg_color,
        .border_color = border_f32,
        .radius = 0.0,
        .border_width = 1.0,
    }) catch {};

    const icon_str: []const u8 = switch (self.level) {
        .err => "!",
        .warn => "⚠",
        .info => "i",
    };
    const icon_w = Text.measure(icon_str);

    var cur_col: u16 = 1;
    if (cur_col < total_cols) {
        _ = drawer.drawString(cur_col, 0, icon_str, accent_color, 255, total_cols);
        cur_col += icon_w + 1;
    }

    // Format full diagnostic text: e.g. "Config error (line 14): unknown option 'foo'"
    var formatted_buf: [320]u8 = undefined;
    var full_text: []const u8 = self.getMessage();
    if (self.line) |l| {
        if (self.col) |c| {
            full_text = std.fmt.bufPrint(&formatted_buf, "Config error (line {d}, col {d}): {s}", .{ l, c, self.getMessage() }) catch self.getMessage();
        } else {
            full_text = std.fmt.bufPrint(&formatted_buf, "Config error (line {d}): {s}", .{ l, self.getMessage() }) catch self.getMessage();
        }
    }

    const max_msg_col = if (layout.dismiss_col > 2) layout.dismiss_col - 2 else total_cols;
    if (cur_col <= max_msg_col) {
        _ = Text.drawEllipsis(drawer, cur_col, 0, full_text, tokens.primary, 255, max_msg_col, "...");
    }

    if (layout.dismiss_w > 0 and layout.dismiss_col + layout.dismiss_w <= total_cols) {
        _ = drawer.drawString(layout.dismiss_col, 0, self.dismiss_str, accent_color, 255, total_cols);

        if (hotspots) |hs| {
            hs.add(layout.dismiss_col, 0, layout.dismiss_w, 1, .dismiss_banner);
        }
    }

    return layout;
}

test "Banner: init, layout computation, and message formatting" {
    const testing = std.testing;

    const banner = Banner.init(.err, "unknown key 'foo'", 14, 5);
    try testing.expectEqual(Level.err, banner.level);
    try testing.expectEqualStrings("unknown key 'foo'", banner.getMessage());
    try testing.expectEqual(@as(?usize, 14), banner.line);
    try testing.expectEqual(@as(?usize, 5), banner.col);

    const layout = banner.computeLayout(80);
    try testing.expectEqual(@as(u16, 0), layout.col);
    try testing.expectEqual(@as(u16, 0), layout.row);
    try testing.expectEqual(@as(u16, 80), layout.width);
    try testing.expectEqual(@as(u16, 1), layout.height);
    try testing.expect(layout.dismiss_col > 60);
    try testing.expect(layout.dismiss_w > 0);

    var hs = HotspotTable{};
    hs.add(layout.dismiss_col, 0, layout.dismiss_w, 1, .dismiss_banner);
    const hit = hs.hitTest(layout.dismiss_col + 1, 0);
    try testing.expect(hit != null);
    try testing.expectEqual(@import("hotspot.zig").UiActionTag.dismiss_banner, std.meta.activeTag(hit.?));
}
