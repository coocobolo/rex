//! Persistent notification banner for actionable status messages and alerts.
//!
//! Provides a domain-agnostic status banner supporting both floating toast-style cards
//! and edge-to-edge docked bars. Floating cards render elevated rounded surfaces with
//! semantic colored borders, leading status icons, optional title prefixes, and
//! interactive dismiss buttons with hotspot hit-testing.

const std = @import("std");

const overlay_config = @import("../config/overlay.zig");
const Tokens = @import("../color/Tokens.zig").Tokens;
const Card = @import("../renderer/Card.zig");
const Rect = @import("Rect.zig").Rect;
const Border = @import("Border.zig");
const Box = @import("Box.zig");
const Label = @import("Label.zig");
const Text = @import("Text.zig");
const Drawer = Text.Drawer;
const Toast = @import("Toast.zig");
const Table = @import("hotspot.zig").Table;

pub const Banner = @This();

pub const Level = enum {
    warn,
    err,
    info,
};

pub const Placement = Option.Placement;

pub const Position = Option.Position;

pub const Option = overlay_config.Banner;

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

id: u64 = 0,
level: Level = .err,
title: [64]u8 = undefined,
title_len: usize = 0,
message: [256]u8 = undefined,
message_len: usize = 0,

/// Constructs a new persistent banner with a severity level, optional title prefix, and message.
pub fn init(level: Level, title: []const u8, msg: []const u8) Banner {
    var b = Banner{
        .level = level,
    };
    const t_len = @min(title.len, b.title.len);
    if (t_len > 0) @memcpy(b.title[0..t_len], title[0..t_len]);
    b.title_len = t_len;

    const copy_len = @min(msg.len, b.message.len);
    if (copy_len > 0) @memcpy(b.message[0..copy_len], msg[0..copy_len]);
    b.message_len = copy_len;
    return b;
}

/// Returns the title prefix slice stored in the banner buffer.
pub fn getTitle(self: *const Banner) []const u8 {
    return self.title[0..self.title_len];
}

/// Returns the message slice stored in the banner buffer.
pub fn getMessage(self: *const Banner) []const u8 {
    return self.message[0..self.message_len];
}

/// Formats the banner text combining the optional title prefix and message.
pub fn formatText(self: *const Banner, buf: []u8) []const u8 {
    const title_str = self.getTitle();
    const msg_str = self.getMessage();
    if (title_str.len > 0) {
        return std.fmt.bufPrint(buf, "{s}: {s}", .{ title_str, msg_str }) catch msg_str;
    }
    return msg_str;
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

    switch (opt.placement) {
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
            const full_text = self.formatText(&msg_buf);
            const text_w = Text.measure(full_text);

            const content_req = icon_w + 1 + text_w + 2 + dismiss_w;
            const desired_w = content_req + 4;
            const max_allowed = if (total_cols > 4) @min(total_cols - 2, opt.max_cols) else total_cols;
            const min_allowed = @min(opt.min_cols, max_allowed);
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
    surface: Card.Option,
    card_buffer: *std.ArrayListUnmanaged(Card.Instance),
    drawer: Drawer,
    hotspots: ?*Table,
) Layout {
    const layout = self.computeLayout(total_cols, total_rows, opt);

    const accent_color: [3]u8 = switch (self.level) {
        .err => tokens.critical,
        .warn => tokens.warning,
        .info => tokens.info,
    };

    _ = Box.render(
        .{
            .rect = .{ .col = layout.col, .row = layout.row, .width = layout.width, .height = layout.height },
            .option = .{
                .surface = .card,
                .border = .{
                    .shape = if (surface.border_shape == .sharp) .sharp else .rounded,
                    .radius = surface.effectiveRadius(),
                    .width = surface.border_width,
                    .style = if (surface.border_style == .semantic) .semantic else .normal,
                },
            },
            .semantic_accent = accent_color,
        },
        tokens,
        null,
        card_buffer,
        drawer.allocator,
        drawer,
        null,
    );

    const icon_str = self.iconString();

    if (layout.icon_col < total_cols) {
        _ = drawer.drawString(layout.icon_col, layout.text_row, icon_str, accent_color, 255, total_cols);
    }

    var formatted_buf: [320]u8 = undefined;
    const full_text = self.formatText(&formatted_buf);

    if (layout.text_col <= layout.max_msg_col) {
        _ = Label.renderAt(layout.text_col, layout.text_row, layout.max_msg_col, full_text, .{ .role = .primary, .ellipsis = "..." }, tokens, drawer);
    }

    if (layout.dismiss_w > 0 and layout.dismiss_col + layout.dismiss_w <= total_cols) {
        _ = Label.renderAt(layout.dismiss_col, layout.text_row, total_cols, opt.dismiss_str, .{ .role = .muted }, tokens, drawer);

        if (hotspots) |hs| {
            hs.add(layout.dismiss_col, layout.dismiss_row, layout.dismiss_w, 1, .{ .banner_dismiss = self.id });
        }
    }

    return layout;
}
