//! Atomic text layout, alignment, truncation, line-splitting, and key hint primitive.
//!
//! Provides zero-allocation typographic rendering with semantic color roles,
//! horizontal alignment, ellipsis overflow clipping, word-boundary line wrapping,
//! and structured interactive keyboard shortcut hints.

const std = @import("std");
const Tokens = @import("../color/Tokens.zig").Tokens;
const Rect = @import("Rect.zig").Rect;
const Text = @import("Text.zig");
const wc = @import("../unicode/wcwidth.zig");
const hotspot_mod = @import("hotspot.zig");
const Table = hotspot_mod.Table;
const Action = hotspot_mod.Action;

pub const Label = @This();

pub const Align = enum {
    left,
    center,
    right,
};

pub const Overflow = enum {
    clip,
    ellipsis,
    wrap,
};

pub const Role = enum {
    primary,
    secondary,
    muted,
    accent,
    healthy,
    warning,
    critical,
    info,
    custom,
};

pub const Option = struct {
    align_h: Align = .left,
    overflow: Overflow = .ellipsis,
    role: Role = .primary,
    color: ?[3]u8 = null,
    alpha: u8 = 255,
    ellipsis: []const u8 = "…",
};

pub fn resolveColor(opt: Option, tokens: Tokens) [3]u8 {
    if (opt.color) |c| return c;
    return switch (opt.role) {
        .primary => tokens.primary,
        .secondary => tokens.secondary,
        .muted => tokens.muted,
        .accent => tokens.accent,
        .healthy => tokens.healthy,
        .warning => tokens.warning,
        .critical => tokens.critical,
        .info => tokens.info,
        .custom => tokens.primary,
    };
}

pub fn render(
    rect: Rect,
    text: []const u8,
    opt: Option,
    tokens: Tokens,
    drawer: Text.Drawer,
) u16 {
    if (rect.width == 0 or rect.height == 0 or text.len == 0) return 0;

    const fg = resolveColor(opt, tokens);
    const max_c = rect.maxCol();

    if (opt.overflow == .wrap and rect.height > 1) {
        var rem_text = text;
        var r = rect.row;
        var total_drawn: u16 = 0;
        while (rem_text.len > 0 and r < rect.bottomEdge()) : (r += 1) {
            const split = splitDescription(rem_text, rect.width);
            const line = split.line1;
            const w = Text.measure(line);
            const start_c = switch (opt.align_h) {
                .left => rect.col,
                .center => if (rect.width > w) rect.col + (rect.width - w) / 2 else rect.col,
                .right => if (rect.width > w) rect.col + rect.width - w else rect.col,
            };
            _ = drawer.drawString(start_c, r, line, fg, opt.alpha, max_c);
            total_drawn += w;
            rem_text = split.line2;
            if (split.line2.len == 0) break;
        }
        return total_drawn;
    }

    const text_w = Text.measure(text);
    if (text_w > rect.width) {
        return switch (opt.overflow) {
            .clip => drawer.drawString(rect.col, rect.row, text, fg, opt.alpha, max_c),
            .ellipsis, .wrap => Text.drawEllipsis(drawer, rect.col, rect.row, text, fg, opt.alpha, max_c, opt.ellipsis),
        };
    }

    const start_c = switch (opt.align_h) {
        .left => rect.col,
        .center => rect.col + (rect.width - text_w) / 2,
        .right => rect.col + rect.width - text_w,
    };

    return drawer.drawString(start_c, rect.row, text, fg, opt.alpha, max_c);
}

pub fn renderAt(
    col: u16,
    row: u16,
    max_col: u16,
    text: []const u8,
    opt: Option,
    tokens: Tokens,
    drawer: Text.Drawer,
) u16 {
    if (max_col < col) return 0;
    const w = max_col - col + 1;
    return render(.{ .col = col, .row = row, .width = w, .height = 1 }, text, opt, tokens, drawer);
}

pub fn splitDescription(text: []const u8, max_w: u16) struct { line1: []const u8, line2: []const u8 } {
    if (Text.measure(text) <= max_w) return .{ .line1 = text, .line2 = "" };

    var last_space: ?usize = null;
    var iter = (std.unicode.Utf8View.init(text) catch return .{ .line1 = text, .line2 = "" }).iterator();
    var cur_w: u16 = 0;
    var byte_idx: usize = 0;
    while (iter.nextCodepoint()) |cp| {
        const cw = wc.wcwidth(cp, .narrow);
        const w: u16 = if (cw == .wide) 2 else if (cw == .zero) 0 else 1;
        if (cur_w + w > max_w) break;
        cur_w += w;
        const cp_len = std.unicode.utf8CodepointSequenceLength(cp) catch 1;
        if (cp == ' ') last_space = byte_idx;
        byte_idx += cp_len;
    }

    if (last_space) |sp| {
        const l1 = std.mem.trimEnd(u8, text[0..sp], " ");
        const l2 = std.mem.trimStart(u8, text[sp..], " ");
        return .{ .line1 = l1, .line2 = l2 };
    }

    return .{ .line1 = text[0..byte_idx], .line2 = text[byte_idx..] };
}

pub fn isEmojiOrTrailingSymbol(cp: u21) bool {
    if (cp >= 0x1F300 and cp <= 0x1FAFF) return true;
    if (cp >= 0x2600 and cp <= 0x27BF) return true;
    if (cp >= 0xFE00 and cp <= 0xFE0F) return true;
    return false;
}

pub fn cleanPromptText(text: []const u8) []const u8 {
    var trimmed = std.mem.trimEnd(u8, text, " \t\r\n");
    while (trimmed.len > 0) {
        var iter = (std.unicode.Utf8View.init(trimmed) catch return trimmed).iterator();
        var last_cp: u21 = 0;
        var last_len: usize = 0;
        var prev_cp: u21 = 0;
        var prev_len: usize = 0;
        while (iter.nextCodepoint()) |cp| {
            prev_cp = last_cp;
            prev_len = last_len;
            last_cp = cp;
            last_len = std.unicode.utf8CodepointSequenceLength(cp) catch 1;
        }

        if (isEmojiOrTrailingSymbol(last_cp)) {
            trimmed = std.mem.trimEnd(u8, trimmed[0 .. trimmed.len - last_len], " \t\r\n.");
        } else if ((last_cp == '.' or last_cp == '!') and isEmojiOrTrailingSymbol(prev_cp)) {
            trimmed = std.mem.trimEnd(u8, trimmed[0 .. trimmed.len - last_len - prev_len], " \t\r\n.");
        } else {
            break;
        }
    }
    return trimmed;
}

pub fn renderKeyHint(
    col: u16,
    row: u16,
    max_col: u16,
    prefix: ?[]const u8,
    key: []const u8,
    label: []const u8,
    focused: bool,
    tokens: Tokens,
    drawer: Text.Drawer,
    hotspots: ?*Table,
    action: ?Action,
) u16 {
    if (col > max_col) return 0;
    var cur_c = col;

    if (prefix) |p| {
        if (p.len > 0) {
            const p_color = if (focused) tokens.accent else tokens.muted;
            cur_c += drawer.drawString(cur_c, row, p, p_color, 255, max_col);
            if (cur_c <= max_col) {
                _ = drawer.drawChar(cur_c, row, ' ', tokens.muted, 255);
                cur_c += 1;
            }
        }
    }

    const key_color = if (focused) tokens.accent else tokens.primary;
    const k_len = drawer.drawString(cur_c, row, key, key_color, 255, max_col);
    cur_c += k_len;

    if (label.len > 0 and cur_c <= max_col) {
        _ = drawer.drawChar(cur_c, row, ' ', tokens.muted, 255);
        cur_c += 1;
        const label_color = if (focused) tokens.primary else tokens.muted;
        cur_c += drawer.drawString(cur_c, row, label, label_color, 255, max_col);
    }

    const total_w = cur_c - col;
    if (hotspots) |ht| {
        if (action) |act| {
            if (total_w > 0) {
                ht.add(col, row, total_w, 1, act);
            }
        }
    }

    return total_w;
}

test "Label: color resolution matches semantic tokens" {
    const testing = std.testing;
    const tokens = Tokens.dark;

    try testing.expectEqual(tokens.primary, resolveColor(.{ .role = .primary }, tokens));
    try testing.expectEqual(tokens.secondary, resolveColor(.{ .role = .secondary }, tokens));
    try testing.expectEqual(tokens.muted, resolveColor(.{ .role = .muted }, tokens));
    try testing.expectEqual(tokens.accent, resolveColor(.{ .role = .accent }, tokens));
    try testing.expectEqual(tokens.critical, resolveColor(.{ .role = .critical }, tokens));
    try testing.expectEqual([3]u8{ 12, 34, 56 }, resolveColor(.{ .color = .{ 12, 34, 56 } }, tokens));
}

test "Label: line splitting on word boundaries" {
    const testing = std.testing;

    const short = splitDescription("Short text", 20);
    try testing.expectEqualStrings("Short text", short.line1);
    try testing.expectEqualStrings("", short.line2);

    const long_text = "Time to stand up and stretch your legs!";
    const split = splitDescription(long_text, 22);
    try testing.expectEqualStrings("Time to stand up and", split.line1);
    try testing.expectEqualStrings("stretch your legs!", split.line2);
}

test "Label: prompt text cleaning removes trailing emojis" {
    const testing = std.testing;

    const cleaned1 = cleanPromptText("Time for a quick stretch! 🚶");
    try testing.expectEqualStrings("Time for a quick stretch!", cleaned1);

    const cleaned2 = cleanPromptText("Rest your eyes 👁️");
    try testing.expectEqualStrings("Rest your eyes", cleaned2);

    const untouched = cleanPromptText("Normal message without emoji.");
    try testing.expectEqualStrings("Normal message without emoji.", untouched);
}
