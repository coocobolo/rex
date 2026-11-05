//! Persistent notification banner for actionable alerts and diagnostics.
//!
//! Provides a configurable status banner supporting both floating toast-style cards
//! and edge-to-edge docked bars. Floating cards render elevated rounded surfaces with
//! semantic colored borders, leading status icons, formatted diagnostic messages with
//! source coordinates, and interactive dismiss buttons with hotspot hit-testing.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Tokens = @import("../color/Tokens.zig").Tokens;
const Card = @import("../renderer/Card.zig");
const Cell = @import("../renderer/Cell.zig");
const Text = @import("Text.zig");
const Drawer = Text.Drawer;
const Toast = @import("Toast.zig");
const HotspotTable = @import("hotspot.zig").HotspotTable;
const UiAction = @import("hotspot.zig").UiAction;

pub const Banner = @This();

pub const Level = enum {
    warn,
    err,
    info,
};

pub const Style = enum {
    floating,
    docked,
};

pub const Position = enum {
    top_center,
    top_right,
    top_left,
};

pub const Option = struct {
    enabled: bool = true,
    style: Style = .floating,
    position: Position = .top_center,
    border_style: Toast.BorderStyle = .semantic,
    corner_radius: f32 = 8.0,
    border_width: f32 = 1.0,
    min_width: u16 = 36,
    max_width: u16 = 72,
    margin_cols: u16 = 2,
    margin_rows: u16 = 1,
    dismiss_str: []const u8 = "✕",
};

pub const Layout = struct {
    col: u16 = 0,
    row: u16 = 0,
    width: u16,
    height: u16 = 1,
    text_row: u16 = 0,
    icon_col: u16 = 1,
    text_col: u16 = 3,
    dismiss_col: u16,
    dismiss_row: u16 = 0,
    dismiss_w: u16,
    max_msg_col: u16 = 0,
};

level: Level = .err,
message: [256]u8 = undefined,
message_len: usize = 0,
line: ?usize = null,
col: ?usize = null,

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

/// Formats the diagnostic message with optional severity prefix and source coordinates.
pub fn formatDiagnostic(self: *const Banner, buf: []u8) []const u8 {
    const prefix: []const u8 = switch (self.level) {
        .err => "Config error",
        .warn => "Config warning",
        .info => "Config note",
    };
    if (self.line) |l| {
        if (self.col) |c| {
            return std.fmt.bufPrint(buf, "{s} (line {d}, col {d}): {s}", .{ prefix, l, c, self.getMessage() }) catch self.getMessage();
        } else {
            return std.fmt.bufPrint(buf, "{s} (line {d}): {s}", .{ prefix, l, self.getMessage() }) catch self.getMessage();
        }
    }
    return self.getMessage();
}

/// Returns the leading icon string corresponding to the banner severity level.
pub fn iconString(self: *const Banner) []const u8 {
    return switch (self.level) {
        .err => "!",
        .warn => "⚠",
        .info => "i",
    };
}

/// Computes the horizontal and vertical geometry for floating or docked banner presentation.
pub fn computeLayout(self: *const Banner, total_cols: u16, total_rows: u16, opt: Option) Layout {
    const icon_str = self.iconString();
    const icon_w = Text.measure(icon_str);
    const dismiss_w = Text.measure(opt.dismiss_str);

    switch (opt.style) {
        .docked => {
            const dismiss_col = if (total_cols > dismiss_w + 1) total_cols - dismiss_w - 1 else 0;
            const icon_col: u16 = 1;
            const text_col: u16 = icon_col + icon_w + 1;
            const max_msg_col = if (dismiss_col > 2) dismiss_col - 2 else total_cols;
            return .{
                .col = 0,
                .row = 0,
                .width = total_cols,
                .height = 1,
                .text_row = 0,
                .icon_col = icon_col,
                .text_col = text_col,
                .dismiss_col = dismiss_col,
                .dismiss_row = 0,
                .dismiss_w = dismiss_w,
                .max_msg_col = max_msg_col,
            };
        },
        .floating => {
            var msg_buf: [320]u8 = undefined;
            const full_text = self.formatDiagnostic(&msg_buf);
            const text_w = Text.measure(full_text);

            const content_req = icon_w + 1 + text_w + 2 + dismiss_w;
            const desired_w = content_req + 4;
            const max_allowed = if (total_cols > 4) @min(total_cols - 2, opt.max_width) else total_cols;
            const min_allowed = @min(opt.min_width, max_allowed);
            const banner_w = std.math.clamp(desired_w, min_allowed, max_allowed);

            const col: u16 = switch (opt.position) {
                .top_center => if (total_cols > banner_w) (total_cols - banner_w) / 2 else 0,
                .top_right => if (total_cols > banner_w + opt.margin_cols) total_cols - banner_w - opt.margin_cols else 0,
                .top_left => if (total_cols > banner_w + opt.margin_cols) opt.margin_cols else 0,
            };

            const banner_h: u16 = 3;
            const row: u16 = if (total_rows > banner_h + opt.margin_rows) opt.margin_rows else 0;
            const text_row: u16 = row + 1;

            const icon_col: u16 = col + 2;
            const text_col: u16 = icon_col + icon_w + 1;
            const dismiss_col: u16 = if (col + banner_w >= dismiss_w + 2) col + banner_w - 2 - dismiss_w else col;
            const max_msg_col: u16 = if (dismiss_col > 2) dismiss_col - 2 else col + banner_w - 2;

            return .{
                .col = col,
                .row = row,
                .width = banner_w,
                .height = banner_h,
                .text_row = text_row,
                .icon_col = icon_col,
                .text_col = text_col,
                .dismiss_col = dismiss_col,
                .dismiss_row = text_row,
                .dismiss_w = dismiss_w,
                .max_msg_col = max_msg_col,
            };
        },
    }
}

/// Renders the banner background card, leading status icon, message, and dismiss action.
pub fn render(
    self: *const Banner,
    tokens: Tokens,
    total_cols: u16,
    total_rows: u16,
    opt: Option,
    card_buffer: *std.ArrayListUnmanaged(Card.Instance),
    drawer: Drawer,
    hotspots: ?*HotspotTable,
) Layout {
    const layout = self.computeLayout(total_cols, total_rows, opt);

    const accent_color: [3]u8 = switch (self.level) {
        .err => tokens.critical,
        .warn => tokens.warning,
        .info => tokens.accent,
    };

    const border_color: [3]u8 = if (opt.border_style == .semantic) accent_color else tokens.border;
    const bg_color = Tokens.toF32Rgba(tokens.card_opaque, 255);
    const radius: f32 = opt.corner_radius;
    const border_width: f32 = opt.border_width;

    card_buffer.append(drawer.allocator, .{
        .col = layout.col,
        .row = layout.row,
        .width = layout.width,
        .height = layout.height,
        .bg_color = bg_color,
        .border_color = Tokens.toF32Rgba(border_color, 255),
        .radius = radius,
        .border_width = border_width,
    }) catch {};

    const icon_str = self.iconString();

    if (layout.icon_col < total_cols) {
        _ = drawer.drawString(layout.icon_col, layout.text_row, icon_str, accent_color, 255, total_cols);
    }

    var formatted_buf: [320]u8 = undefined;
    const full_text = self.formatDiagnostic(&formatted_buf);

    if (layout.text_col <= layout.max_msg_col) {
        _ = Text.drawEllipsis(drawer, layout.text_col, layout.text_row, full_text, tokens.primary, 255, layout.max_msg_col, "...");
    }

    if (layout.dismiss_w > 0 and layout.dismiss_col + layout.dismiss_w <= total_cols) {
        _ = drawer.drawString(layout.dismiss_col, layout.text_row, opt.dismiss_str, tokens.muted, 255, total_cols);

        if (hotspots) |hs| {
            hs.add(layout.dismiss_col, layout.dismiss_row, layout.dismiss_w, 1, .dismiss_banner);
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

    // Test docked style
    const docked_opt = Option{ .style = .docked, .dismiss_str = "Dismiss [×]" };
    const docked_layout = banner.computeLayout(80, 24, docked_opt);
    try testing.expectEqual(@as(u16, 0), docked_layout.col);
    try testing.expectEqual(@as(u16, 0), docked_layout.row);
    try testing.expectEqual(@as(u16, 80), docked_layout.width);
    try testing.expectEqual(@as(u16, 1), docked_layout.height);
    try testing.expectEqual(@as(u16, 0), docked_layout.text_row);
    try testing.expectEqual(@as(u16, 0), docked_layout.dismiss_row);
    try testing.expect(docked_layout.dismiss_col > 60);
    try testing.expect(docked_layout.dismiss_w > 0);

    var hs_docked = HotspotTable{};
    hs_docked.add(docked_layout.dismiss_col, docked_layout.dismiss_row, docked_layout.dismiss_w, 1, .dismiss_banner);
    const hit_docked = hs_docked.hitTest(docked_layout.dismiss_col + 1, docked_layout.dismiss_row);
    try testing.expect(hit_docked != null);
    try testing.expectEqual(@import("hotspot.zig").UiActionTag.dismiss_banner, std.meta.activeTag(hit_docked.?));

    // Test floating toast style
    const float_opt = Option{ .style = .floating, .position = .top_center, .margin_rows = 1 };
    const float_layout = banner.computeLayout(80, 24, float_opt);
    try testing.expect(float_layout.width >= float_opt.min_width);
    try testing.expect(float_layout.width <= float_opt.max_width);
    try testing.expectEqual(@as(u16, 3), float_layout.height);
    try testing.expectEqual(@as(u16, 1), float_layout.row);
    try testing.expectEqual(@as(u16, 2), float_layout.text_row);
    try testing.expectEqual(@as(u16, 2), float_layout.dismiss_row);
    try testing.expectEqual((80 - float_layout.width) / 2, float_layout.col);
    try testing.expect(float_layout.dismiss_col > float_layout.text_col);

    var hs_float = HotspotTable{};
    hs_float.add(float_layout.dismiss_col, float_layout.dismiss_row, float_layout.dismiss_w, 1, .dismiss_banner);
    const hit_float = hs_float.hitTest(float_layout.dismiss_col, float_layout.dismiss_row);
    try testing.expect(hit_float != null);
    try testing.expectEqual(@import("hotspot.zig").UiActionTag.dismiss_banner, std.meta.activeTag(hit_float.?));
}
