const std = @import("std");
const Allocator = std.mem.Allocator;

const Background = @import("../../renderer/Background.zig");
const Card = @import("../../renderer/Card.zig");
const Cell = @import("../../renderer/Cell.zig");
const Atlas = @import("../../renderer/Atlas.zig");
const Toast = @import("../../ui/Toast.zig");
const Icon = @import("../../ui/Icon.zig");
const Modal = @import("../../ui/Modal.zig");
const Text = @import("../../ui/Text.zig");
const Rasterizer = @import("../../freetype/root.zig").Rasterizer;
const wc = @import("../../unicode/wcwidth.zig");

const root = @import("root.zig");
const Wellbeing = root.Wellbeing;
const storage = @import("storage.zig");
const reminders = @import("reminders.zig");
const focus = @import("focus.zig");
const tokens = @import("tokens.zig");
pub const Tokens = tokens.Tokens;
const ColorTokens = @import("../../color/Tokens.zig").Tokens;
const Theme = @import("../../color/Theme.zig");
const icons = @import("icons.zig");
const HotspotTable = @import("../../ui/hotspot.zig").HotspotTable;
pub const IconStyle = icons.IconStyle;
pub const IconId = icons.IconId;

pub const BorderShape = enum { rounded, sharp };

pub const ToastVariant = enum {
    info,
    success,
    warning,
    critical,
    healthy_break,
};

pub const ToastStyle = struct {
    icon_id: IconId,
    accent: [3]u8,
    title: []const u8,
};

pub fn variantStyle(variant: ToastVariant) ToastStyle {
    return switch (variant) {
        .info => .{
            .icon_id = .info,
            .accent = Tokens.info,
            .title = "Information",
        },
        .success => .{
            .icon_id = .success,
            .accent = Tokens.healthy,
            .title = "Success",
        },
        .warning => .{
            .icon_id = .warning,
            .accent = Tokens.warning,
            .title = "Warning",
        },
        .critical => .{
            .icon_id = .error_icon,
            .accent = Tokens.critical,
            .title = "Attention",
        },
        .healthy_break => .{
            .icon_id = .coffee,
            .accent = Tokens.healthy,
            .title = "Time for a healthy break",
        },
    };
}

pub fn alertToToast(alert: reminders.Alert) struct { variant: ToastVariant, icon_id: IconId, title: []const u8 } {
    return switch (alert.kind) {
        .eyesight => .{
            .variant = .healthy_break,
            .icon_id = .eye,
            .title = "Rest your eyes",
        },
        .movement => .{
            .variant = .healthy_break,
            .icon_id = .walk,
            .title = "Stretch and move",
        },
        .hydration => .{
            .variant = .info,
            .icon_id = .water,
            .title = "Hydration check",
        },
        .posture => .{
            .variant = .warning,
            .icon_id = .warning,
            .title = "Posture check",
        },
        .healthy_break => .{
            .variant = .healthy_break,
            .icon_id = .coffee,
            .title = "Time for a healthy break",
        },
        .screen_limit => .{
            .variant = .critical,
            .icon_id = .error_icon,
            .title = "Screen limit reached",
        },
        .custom => .{
            .variant = .info,
            .icon_id = .info,
            .title = "Health reminder",
        },
        .none => .{
            .variant = .info,
            .icon_id = .info,
            .title = "Notification",
        },
    };
}

pub fn stringWidth(str: []const u8) u16 {
    var iter = (std.unicode.Utf8View.init(str) catch return @intCast(str.len)).iterator();
    var w: u16 = 0;
    while (iter.nextCodepoint()) |cp| {
        const cw = wc.wcwidth(cp, .narrow);
        w += if (cw == .wide) 2 else if (cw == .zero) 0 else 1;
    }
    return w;
}

pub fn splitDescription(text: []const u8, max_w: u16) struct { line1: []const u8, line2: []const u8 } {
    if (stringWidth(text) <= max_w) return .{ .line1 = text, .line2 = "" };

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

pub const PanelRect = struct {
    col: u16,
    row: u16,
    width: u16,
    height: u16,

    pub inline fn maxCol(self: PanelRect) u16 {
        return self.col + self.width;
    }

    pub inline fn maxRow(self: PanelRect) u16 {
        return self.row + self.height;
    }

    pub inline fn innerCol(self: PanelRect) u16 {
        return self.col + 1;
    }

    pub inline fn innerRow(self: PanelRect) u16 {
        return self.row + 1;
    }

    pub inline fn innerMaxCol(self: PanelRect) u16 {
        return if (self.width > 2) self.col + self.width - 2 else self.col;
    }

    pub inline fn innerMaxRow(self: PanelRect) u16 {
        return if (self.height > 2) self.row + self.height - 2 else self.row;
    }

    pub inline fn innerWidth(self: PanelRect) u16 {
        return if (self.width > 2) self.width - 2 else 0;
    }

    pub inline fn innerHeight(self: PanelRect) u16 {
        return if (self.height > 2) self.height - 2 else 0;
    }
};

pub const Overlay = struct {
    dashboard_open: bool = false,
    toast_active: bool = false,
    lock_screen_active: bool = false,
    was_active: bool = false,
    last_toast_layout: ?Toast.Layout = null,

    tokens: ColorTokens = ColorTokens.dark,
    card_opt: Card.Option = .{},
    toast_opt: Toast.Option = .{},
    icon_opt: Icon.Option = .{},
    modal_opt: Modal.Option = .{},

    bg_buffer: std.ArrayListUnmanaged(Background.Instance) = .empty,
    card_buffer: std.ArrayListUnmanaged(Card.Instance) = .empty,
    gray_buffer: std.ArrayListUnmanaged(Cell.Instance) = .empty,
    color_buffer: std.ArrayListUnmanaged(Cell.Instance) = .empty,

    pub fn init() Overlay {
        return .{};
    }

    pub fn deinit(self: *Overlay, allocator: Allocator) void {
        self.bg_buffer.deinit(allocator);
        self.card_buffer.deinit(allocator);
        self.gray_buffer.deinit(allocator);
        self.color_buffer.deinit(allocator);
        self.* = undefined;
    }

    pub fn isActive(self: *const Overlay) bool {
        return self.dashboard_open or self.toast_active or self.lock_screen_active;
    }

    pub fn toastRowOffset(self: *const Overlay) u16 {
        if (self.toast_active) {
            if (self.last_toast_layout) |layout| return layout.height + 1;
        }
        return 0;
    }

    pub fn handleMouseClick(self: *Overlay, wellbeing: *Wellbeing, mouse_col: u16, mouse_row: u16) bool {
        if (self.lock_screen_active) return true;
        if (self.dashboard_open) {
            if (self.card_buffer.items.len > 0) {
                const c = self.card_buffer.items[0];
                if (mouse_col < c.col or mouse_col >= c.col + c.width or
                    mouse_row < c.row or mouse_row >= c.row + c.height)
                {
                    self.dashboard_open = false;
                }
            }
            return true;
        }
        if (self.toast_active) {
            if (self.last_toast_layout) |layout| {
                if (Toast.hitTestLayout(layout, mouse_col, mouse_row)) |part| {
                    switch (part) {
                        .dismiss, .action => {
                            wellbeing.dismissAlert();
                            self.toast_active = false;
                            self.last_toast_layout = null;
                        },
                        .body => {},
                    }
                    return true;
                }
            }
        }
        return false;
    }

    pub fn build(
        self: *Overlay,
        allocator: Allocator,
        atlas: *Atlas,
        rasterizer: *Rasterizer,
        wellbeing: *const Wellbeing,
        color_tokens: ColorTokens,
        card_opt: Card.Option,
        toast_opt: Toast.Option,
        icon_opt: Icon.Option,
        modal_opt: Modal.Option,
        total_cols: u16,
        total_rows: u16,
        hotspots: ?*HotspotTable,
    ) void {
        self.tokens = color_tokens;

        self.card_opt = card_opt;
        self.toast_opt = toast_opt;
        self.icon_opt = icon_opt;
        self.modal_opt = modal_opt;
        self.last_toast_layout = null;

        self.bg_buffer.clearRetainingCapacity();
        self.card_buffer.clearRetainingCapacity();
        self.gray_buffer.clearRetainingCapacity();
        self.color_buffer.clearRetainingCapacity();

        if (total_cols < 20 or total_rows < 5) {
            self.toast_active = false;
            self.lock_screen_active = false;
            return;
        }

        if (self.dashboard_open) {
            self.toast_active = false;
            self.lock_screen_active = false;
            self.renderDashboard(allocator, atlas, rasterizer, wellbeing, total_cols, total_rows, hotspots);
            return;
        }

        const lock_enabled = wellbeing.option.lock_screen.enabled;
        if (wellbeing.input_locked and lock_enabled) {
            self.lock_screen_active = true;
            self.toast_active = false;
            self.renderLockScreen(allocator, atlas, rasterizer, wellbeing, total_cols, total_rows);
            return;
        }
        self.lock_screen_active = false;

        const has_alert = wellbeing.current_alert.kind != .none and wellbeing.current_alert.remaining_s > 0;
        const toast_enabled = self.toast_opt.enabled;
        if (has_alert and toast_enabled) {
            self.toast_active = true;
            self.renderToast(allocator, atlas, rasterizer, wellbeing, total_cols, total_rows, hotspots);
            return;
        }
        self.toast_active = false;
    }

    fn renderToast(
        self: *Overlay,
        allocator: Allocator,
        atlas: *Atlas,
        rasterizer: *Rasterizer,
        wellbeing: *const Wellbeing,
        total_cols: u16,
        total_rows: u16,
        hotspots: ?*HotspotTable,
    ) void {
        const alert = wellbeing.current_alert;
        const toast_info = alertToToast(alert);
        const icon_str = icons.getGlyphWithOption(toast_info.icon_id, self.icon_opt);
        const prompt_clean = cleanPromptText(alert.prompt);

        const drawer: Toast.Drawer = .{
            .allocator = allocator,
            .atlas = atlas,
            .rasterizer = rasterizer,
            .gray_buffer = &self.gray_buffer,
            .color_buffer = &self.color_buffer,
        };

        const icon_style = icons.resolveStyle(self.icon_opt.style);
        const dismiss_str = self.toast_opt.dismiss_str orelse (if (icon_style == .ascii) "x" else "✕");

        const toast_req: Toast.Request = .{
            .title = toast_info.title,
            .description = prompt_clean,
            .icon = if (icon_str.len > 0) icon_str else null,
            .countdown_s = if (alert.remaining_s > 0) alert.remaining_s else null,
            .dismiss_str = dismiss_str,
            .action_prompt = self.toast_opt.action_prompt,
            .action_shortcut = "Ctrl+Shift+D",
            .action_label = "Dismiss",
            .variant = switch (toast_info.variant) {
                .info => .info,
                .success, .healthy_break => .success,
                .warning => .warning,
                .critical => .critical,
            },
            .position = self.toast_opt.position,
            .border_style = self.toast_opt.border_style,
            .corner_radius = self.card_opt.effectiveRadius(),
            .border_width = self.card_opt.border_width,
            .min_width = self.toast_opt.min_width,
            .max_width = self.toast_opt.max_width,
            .margin_cols = self.toast_opt.margin_cols,
            .margin_rows = self.toast_opt.margin_rows,
        };

        self.last_toast_layout = Toast.renderAt(toast_req, self.tokens, total_cols, total_rows, 0, &self.card_buffer, drawer);
        if (hotspots) |ht| {
            if (self.last_toast_layout) |layout| {
                if (layout.dismiss_w > 0) {
                    ht.add(layout.dismiss_col, layout.dismiss_row, layout.dismiss_w, 1, .wellbeing_close);
                }
                if (layout.action_w > 0) {
                    ht.add(layout.action_col, layout.action_row, layout.action_w, 1, .wellbeing_close);
                }
            }
        }
    }

    fn renderLockScreen(
        self: *Overlay,
        allocator: Allocator,
        atlas: *Atlas,
        rasterizer: *Rasterizer,
        wellbeing: *const Wellbeing,
        total_cols: u16,
        total_rows: u16,
    ) void {
        const icon_style = icons.resolveStyle(self.icon_opt.style);

        // Determine state & semantic styling
        const is_paused = wellbeing.isFocusPausedByAlert() or
            wellbeing.focus_state.phase == .task or
            (wellbeing.focus_state.phase != .short_break and wellbeing.focus_state.phase != .long_break) or
            wellbeing.focus_state.paused;

        const accent_color: [3]u8 = if (is_paused) self.tokens.warning else self.tokens.healthy;
        const header_text: []const u8 = if (is_paused) "BREAK PAUSED" else "BREAK IN PROGRESS";
        const subtitle_text: []const u8 = if (is_paused)
            "A health alert temporarily interrupted your break."
        else switch (wellbeing.focus_state.phase) {
            .short_break => "Short Rest Break",
            .long_break => "Long Rest Break",
            else => "Rest & Recharge",
        };

        // Unified Panel Geometry calculation
        const modal_w: u16 = if (total_cols > 6) @min(total_cols - 4, 46) else total_cols;
        const inner_content_w: u16 = if (modal_w > 6) modal_w - 6 else modal_w;

        const raw_prompt = if (wellbeing.current_alert.remaining_s > 0)
            wellbeing.current_alert.prompt
        else
            "Roll your shoulders backward and release tension in your neck.";
        const clean_prompt = cleanPromptText(raw_prompt);
        const desc_split = splitDescription(clean_prompt, inner_content_w);
        const has_two_lines = desc_split.line2.len > 0;

        const desired_h: u16 = if (has_two_lines) 13 else 12;
        const modal_h: u16 = if (total_rows > desired_h + 2) desired_h else @min(total_rows, desired_h);
        const col: u16 = if (total_cols > modal_w) (total_cols - modal_w) / 2 else 0;
        const row: u16 = if (total_rows > modal_h) (total_rows - modal_h) / 2 else 0;

        const rect = PanelRect{ .col = col, .row = row, .width = modal_w, .height = modal_h };

        // Step 1: Apply background dimming OUTSIDE the panel only
        const dim_byte = @as(u8, @intFromFloat(std.math.clamp(wellbeing.option.lock_screen.dim_strength, 0.0, 1.0) * 255.0));
        if (dim_byte > 0) {
            self.drawDimmingBackdropOutside(allocator, total_cols, total_rows, rect, .{ self.tokens.bg[0], self.tokens.bg[1], self.tokens.bg[2], dim_byte });
        }

        // Step 2: Emit shader-based rounded rectangle card with SDF anti-aliased border and transparent corners
        const border_color: [3]u8 = if (self.card_opt.border_style == .semantic) accent_color else self.tokens.border;
        self.card_buffer.append(allocator, .{
            .col = rect.col,
            .row = rect.row,
            .width = rect.width,
            .height = rect.height,
            .bg_color = tokens.toF32Rgba(self.tokens.card_opaque, 255),
            .border_color = tokens.toF32Rgba(border_color, 255),
            .radius = self.card_opt.effectiveRadius(),
            .border_width = self.card_opt.border_width,
        }) catch {};

        // Step 4: Draw content strictly inside panel
        const content_col = if (rect.width > 34) rect.col + 3 else rect.col + 2;
        const max_content_col = rect.innerMaxCol();

        // Line 1: Header (inside box, clean unbroken top border, typography first)
        _ = self.drawString(allocator, atlas, rasterizer, content_col, rect.row + 1, header_text, accent_color, 255, max_content_col);

        // Line 2: Subtitle
        _ = self.drawString(allocator, atlas, rasterizer, content_col, rect.row + 2, subtitle_text, self.tokens.secondary, 255, max_content_col);

        // Line 4: Activity section or text
        var cur_r = rect.row + 4;
        if (is_paused) {
            _ = self.drawString(allocator, atlas, rasterizer, content_col, cur_r, "Activity", self.tokens.muted, 255, max_content_col);
            cur_r += 1;
        }

        _ = self.drawString(allocator, atlas, rasterizer, content_col, cur_r, desc_split.line1, self.tokens.primary, 255, max_content_col);
        cur_r += 1;
        if (has_two_lines and cur_r < rect.maxRow() - 4) {
            _ = self.drawString(allocator, atlas, rasterizer, content_col, cur_r, desc_split.line2, self.tokens.primary, 255, max_content_col);
            cur_r += 1;
        }

        // Remaining timer & Progress bar
        const time_r = if (has_two_lines) rect.row + 8 else rect.row + 7;

        const rem_s = if (wellbeing.focus_state.phase == .short_break or wellbeing.focus_state.phase == .long_break)
            (wellbeing.focus_state.remaining_ms + 999) / 1000
        else
            wellbeing.current_alert.remaining_s;

        const total_s: u64 = if (wellbeing.focus_state.phase == .short_break)
            wellbeing.focus_state.option.short_break_ms / 1000
        else if (wellbeing.focus_state.phase == .long_break)
            wellbeing.focus_state.option.long_break_ms / 1000
        else
            30;

        const frac: f32 = if (total_s > 0)
            1.0 - (@as(f32, @floatFromInt(rem_s)) / @as(f32, @floatFromInt(total_s)))
        else
            0.0;

        const mins = rem_s / 60;
        const secs = rem_s % 60;
        var time_buf: [16]u8 = undefined;
        const time_str = std.fmt.bufPrint(&time_buf, "{d:0>2}:{d:0>2}", .{ mins, secs }) catch "00:00";

        if (time_r < rect.maxRow() - 2) {
            _ = self.drawString(allocator, atlas, rasterizer, content_col, time_r, "Remaining", self.tokens.secondary, 255, max_content_col);
            const time_w: u16 = 5; // "00:00"
            const time_col = if (max_content_col >= time_w) max_content_col - time_w + 1 else content_col;
            _ = self.drawString(allocator, atlas, rasterizer, time_col, time_r, time_str, self.tokens.primary, 255, max_content_col);

            // Responsive progress bar width (never exceed time_col or modal boundary)
            const avail_bar_w = if (time_col > content_col + 2) time_col - content_col - 2 else 0;
            const bar_w: u16 = @min(24, avail_bar_w);
            if (bar_w >= 4) {
                _ = self.drawProgressBar(allocator, atlas, rasterizer, content_col, time_r + 1, bar_w, frac, accent_color, self.tokens.border_subtle, 255, icon_style);
                var pct_buf: [16]u8 = undefined;
                const pct_str = std.fmt.bufPrint(&pct_buf, "{d:>3}%", .{@as(u32, @intFromFloat(std.math.clamp(frac, 0.0, 1.0) * 100.0))}) catch "";
                _ = self.drawString(allocator, atlas, rasterizer, time_col + 1, time_r + 1, pct_str, self.tokens.secondary, 255, max_content_col);
            }
        }

        // Action Line: Terminal prompt cursor + highlighted shortcut key + muted label
        const action_r = time_r + 3;
        if (action_r < rect.maxRow() - 1) {
            _ = self.drawString(allocator, atlas, rasterizer, content_col, action_r, ">", self.tokens.accent, 255, max_content_col);
            const key_drawn = self.drawString(allocator, atlas, rasterizer, content_col + 2, action_r, "Ctrl+Shift+D", self.tokens.primary, 255, max_content_col);
            _ = self.drawString(allocator, atlas, rasterizer, content_col + 2 + key_drawn + 2, action_r, "Unlock early", self.tokens.muted, 255, max_content_col);
        }
    }

    fn renderDashboard(
        self: *Overlay,
        allocator: Allocator,
        atlas: *Atlas,
        rasterizer: *Rasterizer,
        wellbeing: *const Wellbeing,
        total_cols: u16,
        total_rows: u16,
        hotspots: ?*HotspotTable,
    ) void {
        const icon_style = icons.resolveStyle(self.icon_opt.style);

        var active_apps: u16 = 0;
        for (&wellbeing.data.today.top_apps) |*app| {
            if (app.seconds > 0 and app.name[0] != 0) active_apps += 1;
        }
        const needed_h: u16 = if (active_apps > 3) 16 else 15;
        const target_w: u16 = @max(self.modal_opt.width, 66);
        const modal_w: u16 = if (total_cols > 6) @min(total_cols - 2, target_w) else total_cols;
        const modal_h: u16 = if (total_rows > 4) @min(total_rows - 2, needed_h) else total_rows;
        const col: u16 = if (total_cols > modal_w) (total_cols - modal_w) / 2 else 0;
        const row: u16 = if (total_rows > modal_h) (total_rows - modal_h) / 2 else 0;

        const rect = PanelRect{ .col = col, .row = row, .width = modal_w, .height = modal_h };

        if (self.modal_opt.dim_alpha > 0) {
            self.drawDimmingBackdropOutside(allocator, total_cols, total_rows, rect, .{ self.tokens.bg[0], self.tokens.bg[1], self.tokens.bg[2], self.modal_opt.dim_alpha });
        }

        const effective_radius = self.modal_opt.corner_radius orelse self.card_opt.effectiveRadius();
        const effective_border_w = self.modal_opt.border_width orelse self.card_opt.border_width;

        const border_color: [3]u8 = if (self.card_opt.border_style == .semantic) self.tokens.accent else self.tokens.border;
        self.card_buffer.append(allocator, .{
            .col = rect.col,
            .row = rect.row,
            .width = rect.width,
            .height = rect.height,
            .bg_color = tokens.toF32Rgba(self.tokens.card_opaque, 255),
            .border_color = tokens.toF32Rgba(border_color, 255),
            .radius = effective_radius,
            .border_width = effective_border_w,
        }) catch {};

        const content_col = rect.col + 3;
        const max_content_col = if (rect.width > 6) rect.col + rect.width - 4 else rect.col + rect.width - 1;

        const drawer: Text.Drawer = .{
            .allocator = allocator,
            .atlas = atlas,
            .rasterizer = rasterizer,
            .gray_buffer = &self.gray_buffer,
            .color_buffer = &self.color_buffer,
        };

        // Header inside box (preserves unbroken top border)
        const header = "Digital Wellbeing";
        _ = Text.draw(drawer, content_col, rect.row + 1, header, self.tokens.primary, 255, max_content_col);

        var streak_buf: [32]u8 = undefined;
        const streak_str = std.fmt.bufPrint(&streak_buf, "Streak: {d}d", .{wellbeing.data.current_streak}) catch "";
        const streak_w: u16 = Text.measure(streak_str);
        if (max_content_col > streak_w) {
            _ = Text.draw(drawer, max_content_col - streak_w, rect.row + 1, streak_str, self.tokens.warning, 255, max_content_col);
        }

        var r = rect.row + 2;
        var fmt_buf: [128]u8 = undefined;

        // Section 1: Screen Time
        if (r < rect.maxRow() - 2) {
            const active_s = wellbeing.data.today.active_screen_s;
            const limit_m = wellbeing.option.screen_time.daily_limit_minutes orelse 480;
            const limit_s: u32 = @as(u32, limit_m) * 60;
            const frac: f32 = if (limit_s > 0) @as(f32, @floatFromInt(active_s)) / @as(f32, @floatFromInt(limit_s)) else 0.0;

            const st_str = std.fmt.bufPrint(
                &fmt_buf,
                "Today Active: {d}h {d:0>2}m / {d}h {d:0>2}m  ",
                .{ active_s / 3600, (active_s % 3600) / 60, limit_m / 60, limit_m % 60 },
            ) catch "";
            const cur_c = content_col + self.drawString(allocator, atlas, rasterizer, content_col, r, st_str, self.tokens.primary, 255, max_content_col);

            const bar_w: u16 = if (max_content_col > cur_c + 8) @min(18, (max_content_col - cur_c - 8)) else 0;
            if (bar_w >= 4) {
                const fill_color: [3]u8 = if (frac >= 1.0) self.tokens.critical else self.tokens.healthy;
                const bar_drawn = self.drawProgressBar(allocator, atlas, rasterizer, cur_c, r, bar_w, frac, fill_color, self.tokens.border_subtle, 255, icon_style);
                var pct_buf: [16]u8 = undefined;
                const pct_str = std.fmt.bufPrint(&pct_buf, " {d}%", .{@as(u32, @intFromFloat(@min(1.0, frac) * 100.0))}) catch "";
                _ = self.drawString(allocator, atlas, rasterizer, cur_c + bar_drawn, r, pct_str, self.tokens.secondary, 255, max_content_col);
            }
            r += 1;
        }

        // Separator
        if (r < rect.maxRow() - 2) {
            self.drawSeparator(allocator, atlas, rasterizer, rect.col, r, rect.width, self.tokens.border, 255, icon_style);
            r += 1;
        }

        // Section 2: Focus Session Metrics
        if (r < rect.maxRow() - 2) {
            const foc_s = wellbeing.data.today.focus_s;
            const brk_s = wellbeing.data.today.break_s;
            const focus_line = std.fmt.bufPrint(
                &fmt_buf,
                "Focus: {d}h {d:0>2}m  |  Rest: {d}h {d:0>2}m  |  Done: {d}  |  Best: {d}d",
                .{ foc_s / 3600, (foc_s % 3600) / 60, brk_s / 3600, (brk_s % 3600) / 60, wellbeing.data.today.tasks_completed, wellbeing.data.best_streak },
            ) catch "";
            _ = self.drawString(allocator, atlas, rasterizer, content_col, r, focus_line, self.tokens.secondary, 255, max_content_col);
            r += 1;
        }

        // Focus Phase line
        if (r < rect.maxRow() - 2) {
            const rem_s = (wellbeing.focus_state.remaining_ms + 999) / 1000;
            const phase_name = switch (wellbeing.focus_state.phase) {
                .task => "Task",
                .short_break => "Short Break",
                .long_break => "Long Break",
                .idle => "Idle",
            };
            const phase_info = if (wellbeing.focus_state.phase != .idle)
                std.fmt.bufPrint(&fmt_buf, "Phase: {s} [{d:0>2}:{d:0>2}] {s}", .{
                    phase_name,
                    rem_s / 60,
                    rem_s % 60,
                    if (wellbeing.isFocusPausedByAlert()) "[PAUSED]" else if (wellbeing.focus_state.paused) "[PAUSED]" else "[RUNNING]",
                }) catch ""
            else
                std.fmt.bufPrint(&fmt_buf, "Phase: {s} (Press 'p' to start)", .{phase_name}) catch "";
            _ = self.drawString(allocator, atlas, rasterizer, content_col, r, phase_info, self.tokens.primary, 255, max_content_col);
            r += 1;
        }

        // Separator
        if (r < rect.maxRow() - 2) {
            self.drawSeparator(allocator, atlas, rasterizer, rect.col, r, rect.width, self.tokens.border, 255, icon_style);
            r += 1;
        }

        // Section 3: Health Tallies
        if (r < rect.maxRow() - 2) {
            const health_line = std.fmt.bufPrint(
                &fmt_buf,
                "Eye Pauses: {d}  |  Posture Checks: {d}  |  Hydration: {d}",
                .{ wellbeing.data.today.eyesight_breaks, wellbeing.data.today.movement_breaks, wellbeing.data.today.hydration_count },
            ) catch "";
            _ = Text.drawEllipsis(drawer, content_col, r, health_line, self.tokens.secondary, 255, max_content_col, "…");
            r += 1;
        }

        // Separator
        if (r < rect.maxRow() - 2) {
            self.drawSeparator(allocator, atlas, rasterizer, rect.col, r, rect.width, self.tokens.border, 255, icon_style);
            r += 1;
        }

        // Section 4: Top Foreground Tools
        if (r < rect.maxRow() - 3) {
            _ = Text.draw(drawer, content_col, r, "Top Foreground Tools:", self.tokens.muted, 255, max_content_col);
            r += 1;

            const max_tools_row = @min(r + 1, rect.maxRow() - 3);
            var flow = Text.Flow.init(content_col + 2, r, max_content_col, max_tools_row);
            for (&wellbeing.data.today.top_apps) |*app| {
                if (app.seconds == 0 or app.name[0] == 0) continue;
                const app_name = app.getName();
                var val_buf: [16]u8 = undefined;
                const val_str = std.fmt.bufPrint(&val_buf, "({d}m)", .{app.seconds / 60}) catch "";
                _ = flow.addBullet(
                    drawer,
                    "•",
                    app_name,
                    val_str,
                    self.tokens.muted,
                    self.tokens.primary,
                    self.tokens.secondary,
                    255,
                    2,
                );
            }
            if (flow.overflow_count > 0 and flow.cur_row < rect.maxRow() - 3) {
                var more_buf: [16]u8 = undefined;
                const more_str = std.fmt.bufPrint(&more_buf, "+{d} more", .{flow.overflow_count}) catch "";
                _ = flow.add(drawer, more_str, self.tokens.muted, 255, 1);
            } else if (flow.items_drawn == 0) {
                _ = Text.draw(drawer, content_col + 2, r, "(No process samples yet)", self.tokens.muted, 255, max_content_col);
            }
            r = flow.cur_row + 1;
        }

        // Section 5: All-Time Lifetime Summary
        if (r < rect.maxRow() - 2) {
            const total_foc = wellbeing.data.total_focus_s + wellbeing.data.today.focus_s;
            const total_screen = wellbeing.data.total_active_screen_s + wellbeing.data.today.active_screen_s;
            const life_line = std.fmt.bufPrint(
                &fmt_buf,
                "All-Time Focus: {d}h {d:0>2}m  |  Total Screen: {d}h {d:0>2}m",
                .{ total_foc / 3600, (total_foc % 3600) / 60, total_screen / 3600, (total_screen % 3600) / 60 },
            ) catch "";
            _ = Text.drawEllipsis(drawer, content_col, r, life_line, self.tokens.muted, 255, max_content_col, "…");
            r += 1;
        }

        // Footer Separator
        const footer_r = rect.maxRow() - 2;
        if (footer_r > rect.row + 2) {
            self.drawSeparator(allocator, atlas, rasterizer, rect.col, footer_r - 1, rect.width, self.tokens.border, 255, icon_style);

            // Action Bar
            var act_c = content_col;
            const w_close = self.drawShortcut(allocator, atlas, rasterizer, act_c, footer_r, "[Esc/q]", " Close   ");
            if (hotspots) |ht| ht.add(act_c, footer_r, w_close, 1, .wellbeing_close);
            act_c += w_close;

            const w_focus = self.drawShortcut(allocator, atlas, rasterizer, act_c, footer_r, "[p]", " Focus   ");
            if (hotspots) |ht| ht.add(act_c, footer_r, w_focus, 1, .wellbeing_toggle_focus);
            act_c += w_focus;

            const w_reset = self.drawShortcut(allocator, atlas, rasterizer, act_c, footer_r, "[r]", " Reset   ");
            if (hotspots) |ht| ht.add(act_c, footer_r, w_reset, 1, .wellbeing_reset);
            act_c += w_reset;

            const w_copy = self.drawShortcut(allocator, atlas, rasterizer, act_c, footer_r, "[c]", " Copy Card");
            if (hotspots) |ht| ht.add(act_c, footer_r, w_copy, 1, .wellbeing_copy_card);
        }
    }

    fn drawShortcut(
        self: *Overlay,
        allocator: Allocator,
        atlas: *Atlas,
        rasterizer: *Rasterizer,
        col: u16,
        row: u16,
        key: []const u8,
        label: []const u8,
    ) u16 {
        const k_len = self.drawString(allocator, atlas, rasterizer, col, row, key, self.tokens.accent, 255, col + 30);
        const l_len = self.drawString(allocator, atlas, rasterizer, col + k_len, row, label, self.tokens.secondary, 255, col + 30);
        return k_len + l_len;
    }

    pub fn drawBox(
        self: *Overlay,
        allocator: Allocator,
        col: u16,
        row: u16,
        width: u16,
        height: u16,
        color: [4]u8,
    ) void {
        for (0..height) |i| {
            self.bg_buffer.append(allocator, .{
                .col = col,
                .row = @intCast(row + i),
                .span = width,
                .r = color[0],
                .g = color[1],
                .b = color[2],
                .a = color[3],
            }) catch {};
        }
    }

    pub fn drawDimmingBackdropOutside(
        self: *Overlay,
        allocator: Allocator,
        total_cols: u16,
        total_rows: u16,
        rect: PanelRect,
        dim_color: [4]u8,
    ) void {
        if (dim_color[3] == 0) return;

        if (rect.row > 0) {
            self.drawBox(allocator, 0, 0, total_cols, rect.row, dim_color);
        }
        const mid_start = rect.row;
        const mid_end = @min(total_rows, rect.maxRow());
        if (mid_end > mid_start) {
            const mid_h = mid_end - mid_start;
            if (rect.col > 0) {
                self.drawBox(allocator, 0, mid_start, rect.col, mid_h, dim_color);
            }
            const right_start = rect.maxCol();
            if (total_cols > right_start) {
                self.drawBox(allocator, right_start, mid_start, total_cols - right_start, mid_h, dim_color);
            }
        }
        if (total_rows > rect.maxRow()) {
            self.drawBox(allocator, 0, rect.maxRow(), total_cols, total_rows - rect.maxRow(), dim_color);
        }
    }

    pub fn drawBorder(
        self: *Overlay,
        allocator: Allocator,
        atlas: *Atlas,
        rasterizer: *Rasterizer,
        col: u16,
        row: u16,
        width: u16,
        height: u16,
        fg: [3]u8,
        fg_a: u8,
        style: IconStyle,
        shape: BorderShape,
    ) void {
        if (width < 2 or height < 2) return;
        const max_c = col + width;

        const tl: u21 = if (style == .ascii) '+' else if (shape == .sharp) 0x250C else 0x256D; // ╭ or ┌ or +
        const tr: u21 = if (style == .ascii) '+' else if (shape == .sharp) 0x2510 else 0x256E; // ╮ or ┐ or +
        const bl: u21 = if (style == .ascii) '+' else if (shape == .sharp) 0x2514 else 0x2570; // ╰ or └ or +
        const br: u21 = if (style == .ascii) '+' else if (shape == .sharp) 0x2518 else 0x256F; // ╯ or ┘ or +
        const horiz: u21 = if (style == .ascii) '-' else 0x2500; // ─ or -
        const vert: u21 = if (style == .ascii) '|' else 0x2502; // │ or |

        // Top row
        _ = self.drawChar(allocator, atlas, rasterizer, col, row, tl, fg, fg_a);
        var c = col + 1;
        while (c < max_c - 1) : (c += 1) {
            _ = self.drawChar(allocator, atlas, rasterizer, c, row, horiz, fg, fg_a);
        }
        _ = self.drawChar(allocator, atlas, rasterizer, max_c - 1, row, tr, fg, fg_a);

        // Vertical sides
        var r = row + 1;
        while (r < row + height - 1) : (r += 1) {
            _ = self.drawChar(allocator, atlas, rasterizer, col, r, vert, fg, fg_a);
            _ = self.drawChar(allocator, atlas, rasterizer, max_c - 1, r, vert, fg, fg_a);
        }

        // Bottom row
        _ = self.drawChar(allocator, atlas, rasterizer, col, row + height - 1, bl, fg, fg_a);
        c = col + 1;
        while (c < max_c - 1) : (c += 1) {
            _ = self.drawChar(allocator, atlas, rasterizer, c, row + height - 1, horiz, fg, fg_a);
        }
        _ = self.drawChar(allocator, atlas, rasterizer, max_c - 1, row + height - 1, br, fg, fg_a);
    }

    fn drawSeparator(
        self: *Overlay,
        allocator: Allocator,
        atlas: *Atlas,
        rasterizer: *Rasterizer,
        col: u16,
        row: u16,
        width: u16,
        fg: [3]u8,
        fg_a: u8,
        style: IconStyle,
    ) void {
        if (width < 6) return;
        const start_c = col + 2;
        const end_c = col + width - 2;
        const horiz: u21 = if (style == .ascii) '-' else 0x2500; // ─ or -

        var c = start_c;
        while (c < end_c) : (c += 1) {
            _ = self.drawChar(allocator, atlas, rasterizer, c, row, horiz, fg, fg_a);
        }
    }

    fn drawProgressBar(
        self: *Overlay,
        allocator: Allocator,
        atlas: *Atlas,
        rasterizer: *Rasterizer,
        col: u16,
        row: u16,
        bar_width: u16,
        fraction: f32,
        fg_fill: [3]u8,
        fg_empty: [3]u8,
        fg_a: u8,
        style: IconStyle,
    ) u16 {
        if (bar_width < 2) return 0;
        const clamped_frac = std.math.clamp(fraction, 0.0, 1.0);
        const filled_count: u16 = @intFromFloat(@round(clamped_frac * @as(f32, @floatFromInt(bar_width))));

        const fill_cp: u21 = if (style == .ascii) '=' else 0x2588; // █ or =
        const empty_cp: u21 = if (style == .ascii) '.' else 0x2591; // ░ or .

        var c = col;
        var i: u16 = 0;
        while (i < filled_count) : (i += 1) {
            _ = self.drawChar(allocator, atlas, rasterizer, c, row, fill_cp, fg_fill, fg_a);
            c += 1;
        }
        while (i < bar_width) : (i += 1) {
            _ = self.drawChar(allocator, atlas, rasterizer, c, row, empty_cp, fg_empty, fg_a);
            c += 1;
        }
        return c - col;
    }

    fn drawChar(
        self: *Overlay,
        allocator: Allocator,
        atlas: *Atlas,
        rasterizer: *Rasterizer,
        col: u16,
        row: u16,
        cp: u21,
        fg: [3]u8,
        fg_a: u8,
    ) u16 {
        const w = wc.wcwidth(cp, .narrow);
        const span: Rasterizer.Span = if (w == .wide) .double else .single;
        if (atlas.get(allocator, rasterizer, cp, .regular, span)) |metric| {
            if (metric.width > 0 and metric.height > 0) {
                const inst: Cell.Instance = .{
                    .col = col,
                    .row = row,
                    .atlas_x = metric.atlas_x,
                    .atlas_y = metric.atlas_y,
                    .bearing_x = metric.bearing_x,
                    .bearing_y = metric.bearing_y,
                    .fg_r = fg[0],
                    .fg_g = fg[1],
                    .fg_b = fg[2],
                    .fg_a = fg_a,
                    .glyph_width = metric.width,
                    .glyph_height = metric.height,
                    .flags = .{},
                };
                switch (metric.kind) {
                    .gray => self.gray_buffer.append(allocator, inst) catch {},
                    .color => self.color_buffer.append(allocator, inst) catch {},
                }
            }
        } else |_| {}
        return if (span == .double) 2 else 1;
    }

    fn drawString(
        self: *Overlay,
        allocator: Allocator,
        atlas: *Atlas,
        rasterizer: *Rasterizer,
        start_col: u16,
        row: u16,
        str: []const u8,
        fg: [3]u8,
        fg_a: u8,
        max_col: u16,
    ) u16 {
        var iter = (std.unicode.Utf8View.init(str) catch return 0).iterator();
        var col = start_col;
        while (iter.nextCodepoint()) |cp| {
            const w = wc.wcwidth(cp, .narrow);
            const adv: u16 = if (w == .wide) 2 else if (w == .zero) 0 else 1;
            if (col + adv > max_col + 1) break;
            _ = self.drawChar(allocator, atlas, rasterizer, col, row, cp, fg, fg_a);
            col += adv;
        }
        return col - start_col;
    }
};
