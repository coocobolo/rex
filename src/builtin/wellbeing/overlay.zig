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
const Button = @import("../../ui/Button.zig");
const ProgressBar = @import("../../ui/ProgressBar.zig");
const RingGauge = @import("../../ui/RingGauge.zig");
const Rect = @import("../../ui/Rect.zig").Rect;
const Padding = @import("../../ui/Rect.zig").Padding;
const Border = @import("../../ui/Border.zig");
const Box = @import("../../ui/Box.zig");
const Label = @import("../../ui/Label.zig");
const Divider = @import("../../ui/Divider.zig");
const Badge = @import("../../ui/Badge.zig");
const Kbd = @import("../../ui/Kbd.zig");
const StepIndicator = @import("../../ui/StepIndicator.zig");
const BarChart = @import("../../ui/BarChart.zig");
const StatCard = @import("../../ui/StatCard.zig");
const TabBar = @import("../../ui/TabBar.zig");
const Rasterizer = @import("../../freetype/root.zig").Rasterizer;
const wc = @import("../../unicode/wcwidth.zig");

const root = @import("root.zig");
const Wellbeing = root.Wellbeing;
const storage = @import("storage.zig");
const reminders = @import("reminders.zig");
const focus = @import("focus.zig");
const ColorTokens = @import("../../color/Tokens.zig").Tokens;
const icons = @import("icons.zig");
const Table = @import("../../ui/hotspot.zig").Table;
pub const IconStyle = icons.IconStyle;
pub const IconId = icons.IconId;

pub const BorderShape = Border.Shape;

pub const DashboardTab = enum(u8) {
    overview = 0,
    pomodoro = 1,
    activity = 2,
};

pub const ButtonId = enum(u64) {
    close = 1,
    toggle_focus = 2,
    skip_focus = 3,
    reset_focus = 4,
    purge_history = 5,
    copy_card = 6,
};

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

pub const stringWidth = Text.measure;
pub const splitDescription = Label.splitDescription;
pub const isEmojiOrTrailingSymbol = Label.isEmojiOrTrailingSymbol;
pub const cleanPromptText = Label.cleanPromptText;

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
    active_tab: DashboardTab = .overview,
    selected_day_idx: ?u16 = null,
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

    pub fn nextTab(self: *Overlay) void {
        self.active_tab = switch (self.active_tab) {
            .overview => .pomodoro,
            .pomodoro => .activity,
            .activity => .overview,
        };
    }

    pub fn selectTab(self: *Overlay, idx: u8) void {
        if (idx <= 2) {
            self.active_tab = @enumFromInt(idx);
        }
    }

    pub fn moveSelectedDay(self: *Overlay, delta: i16, history_count: u32) void {
        const total_days: u16 = @intCast(@min(history_count, storage.max_history_days) + 1);
        const cur: i32 = @intCast(self.selected_day_idx orelse (total_days - 1));
        const next_idx = std.math.clamp(cur + delta, 0, @as(i32, total_days) - 1);
        self.selected_day_idx = @intCast(next_idx);
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
        hotspots: ?*Table,
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
        hotspots: ?*Table,
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
            .icon_style = self.icon_opt.style,
        };

        self.last_toast_layout = Toast.renderAt(toast_req, self.tokens, total_cols, total_rows, 0, &self.card_buffer, drawer);
        if (hotspots) |ht| {
            if (self.last_toast_layout) |layout| {
                if (layout.dismiss_w > 0) {
                    ht.add(layout.dismiss_col, layout.dismiss_row, layout.dismiss_w, 1, .{ .button = @intFromEnum(ButtonId.close) });
                }
                if (layout.action_w > 0) {
                    ht.add(layout.action_col, layout.action_row, layout.action_w, 1, .{ .button = @intFromEnum(ButtonId.close) });
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

        const modal_w: u16 = if (total_cols > 6) @min(total_cols - 4, 48) else total_cols;
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
        const center_rect = Rect.center(total_cols, total_rows, modal_w, modal_h);
        const rect = PanelRect{ .col = center_rect.col, .row = center_rect.row, .width = center_rect.width, .height = center_rect.height };

        const dim_byte = @as(u8, @intFromFloat(std.math.clamp(wellbeing.option.lock_screen.dim_strength, 0.0, 1.0) * 255.0));
        _ = Box.render(
            .{
                .rect = center_rect,
                .option = .{
                    .surface = .card,
                    .border = .{
                        .shape = if (self.card_opt.border_shape == .sharp) .sharp else .rounded,
                        .radius = self.card_opt.effectiveRadius(),
                        .width = self.card_opt.border_width,
                        .style = if (self.card_opt.border_style == .semantic) .semantic else .normal,
                    },
                    .backdrop_dim_alpha = dim_byte,
                },
                .semantic_accent = accent_color,
                .viewport_cols = total_cols,
                .viewport_rows = total_rows,
            },
            self.tokens,
            &self.bg_buffer,
            &self.card_buffer,
            allocator,
            null,
            null,
        );

        const drawer: Text.Drawer = .{
            .allocator = allocator,
            .atlas = atlas,
            .rasterizer = rasterizer,
            .gray_buffer = &self.gray_buffer,
            .color_buffer = &self.color_buffer,
        };

        const content_col = if (rect.width > 34) rect.col + 3 else rect.col + 2;
        const max_content_col = rect.innerMaxCol();

        _ = self.drawString(allocator, atlas, rasterizer, content_col, rect.row + 1, header_text, accent_color, 255, max_content_col);

        const total_steps = wellbeing.focus_state.option.tasks_before_long_break;
        const pips_w = StepIndicator.measureWidth(total_steps, 2, 1);
        if (max_content_col > content_col + pips_w + 18) {
            _ = StepIndicator.render(.{
                .col = max_content_col - pips_w,
                .row = rect.row + 1,
                .max_col = max_content_col,
                .total_steps = total_steps,
                .completed_steps = wellbeing.focus_state.tasks_in_cycle,
            }, self.tokens, &self.card_buffer, allocator);
        }

        _ = self.drawString(allocator, atlas, rasterizer, content_col, rect.row + 2, subtitle_text, self.tokens.secondary, 255, max_content_col);

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
            const time_w: u16 = 5;
            const time_col = if (max_content_col >= time_w) max_content_col - time_w + 1 else content_col;
            _ = self.drawString(allocator, atlas, rasterizer, time_col, time_r, time_str, self.tokens.primary, 255, max_content_col);

            const avail_bar_w = if (max_content_col > content_col) max_content_col - content_col + 1 else 0;
            if (avail_bar_w >= 8) {
                _ = ProgressBar.render(.{
                    .col = content_col,
                    .row = time_r + 1,
                    .width = avail_bar_w,
                    .progress = frac,
                    .fill_color = accent_color,
                    .show_percentage = true,
                }, self.tokens, &self.card_buffer, allocator, drawer);
            }
        }

        const action_r = time_r + 3;
        if (action_r < rect.maxRow() - 1) {
            _ = Kbd.renderHint(content_col, action_r, max_content_col, ">", "Ctrl+Shift+D", "Unlock early", .{ .style = .subtle, .icon_style = self.icon_opt.style }, self.tokens, &self.card_buffer, drawer, null, null);
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
        hotspots: ?*Table,
    ) void {
        const icon_style = icons.resolveStyle(self.icon_opt.style);

        const needed_h: u16 = 18;
        const target_w: u16 = @max(self.modal_opt.width, 70);
        const modal_w: u16 = if (total_cols > 6) @min(total_cols - 2, target_w) else total_cols;
        const modal_h: u16 = if (total_rows > 4) @min(total_rows - 2, needed_h) else total_rows;
        const center_rect = Rect.center(total_cols, total_rows, modal_w, modal_h);
        const rect = PanelRect{ .col = center_rect.col, .row = center_rect.row, .width = center_rect.width, .height = center_rect.height };

        const effective_radius = self.modal_opt.corner_radius orelse self.card_opt.effectiveRadius();
        const effective_border_w = self.modal_opt.border_width orelse self.card_opt.border_width;

        _ = Box.render(
            .{
                .rect = center_rect,
                .option = .{
                    .surface = .card,
                    .border = .{
                        .shape = if (self.card_opt.border_shape == .sharp) .sharp else .rounded,
                        .radius = effective_radius,
                        .width = effective_border_w,
                        .style = if (self.card_opt.border_style == .semantic) .semantic else .normal,
                    },
                    .backdrop_dim_alpha = self.modal_opt.dim_alpha,
                },
                .semantic_accent = self.tokens.accent,
                .viewport_cols = total_cols,
                .viewport_rows = total_rows,
            },
            self.tokens,
            &self.bg_buffer,
            &self.card_buffer,
            allocator,
            null,
            null,
        );

        const content_col = rect.col + 3;
        const max_content_col = if (rect.width > 6) rect.col + rect.width - 4 else rect.col + rect.width - 1;

        const drawer: Text.Drawer = .{
            .allocator = allocator,
            .atlas = atlas,
            .rasterizer = rasterizer,
            .gray_buffer = &self.gray_buffer,
            .color_buffer = &self.color_buffer,
        };

        const header = "Digital Wellbeing";
        const header_w = Text.draw(drawer, content_col, rect.row + 1, header, self.tokens.primary, 255, max_content_col);

        const tabs = [_]TabBar.Tab{
            .{ .label = "Overview", .shortcut = "1" },
            .{ .label = "Pomodoro", .shortcut = "2" },
            .{ .label = "Activity", .shortcut = "3" },
        };
        const tab_start = content_col + header_w + 2;
        if (tab_start + 30 <= max_content_col) {
            _ = TabBar.render(.{
                .col = tab_start,
                .row = rect.row + 1,
                .max_col = max_content_col,
                .tabs = &tabs,
                .active_index = @intFromEnum(self.active_tab),
                .icon_style = self.icon_opt.style,
            }, self.tokens, &self.card_buffer, drawer, hotspots);
        }

        if (rect.row + 2 < rect.maxRow() - 2) {
            Divider.renderHorizontal(rect.col, rect.row + 2, rect.width, null, .{
                .mode = .glyph,
                .color = self.tokens.border,
                .glyph_style = icon_style,
            }, self.tokens, null, drawer);
        }

        const body_start_r = rect.row + 3;
        const footer_r = rect.maxRow() - 2;
        const body_max_r = if (footer_r > 2) footer_r - 2 else rect.maxRow();

        switch (self.active_tab) {
            .overview => self.renderOverviewTab(drawer, wellbeing, content_col, max_content_col, body_start_r, body_max_r),
            .pomodoro => self.renderPomodoroTab(drawer, wellbeing, content_col, max_content_col, body_start_r, body_max_r, hotspots),
            .activity => self.renderActivityTab(drawer, wellbeing, content_col, max_content_col, body_start_r, body_max_r, hotspots),
        }

        if (footer_r > rect.row + 2) {
            Divider.renderHorizontal(rect.col, footer_r - 1, rect.width, null, .{
                .mode = .glyph,
                .color = self.tokens.border,
                .glyph_style = icon_style,
            }, self.tokens, null, drawer);

            const FooterHint = struct { chord: []const u8, label: []const u8, button: ?ButtonId };
            const footer_hints = [_]FooterHint{
                .{ .chord = "Esc/q", .label = "Close", .button = .close },
                .{ .chord = "Tab", .label = "View", .button = null },
                .{ .chord = "p", .label = "Focus", .button = .toggle_focus },
                .{ .chord = "s", .label = "Skip", .button = .skip_focus },
                .{ .chord = "c", .label = "Copy", .button = .copy_card },
            };
            // Lowercase letters are kept because these bindings fire without Shift.
            const footer_kbd: Kbd.Option = .{ .style = .keycap, .connector_pad = 0, .uppercase_letters = false, .icon_style = self.icon_opt.style };

            var act_c = content_col;
            for (footer_hints) |hint| {
                if (act_c > max_content_col) break;
                act_c += Kbd.renderHint(
                    act_c,
                    footer_r,
                    max_content_col,
                    null,
                    hint.chord,
                    hint.label,
                    footer_kbd,
                    self.tokens,
                    &self.card_buffer,
                    drawer,
                    hotspots,
                    if (hint.button) |b| .{ .button = @intFromEnum(b) } else null,
                );
                act_c += 2;
            }
        }
    }

    fn renderOverviewTab(
        self: *Overlay,
        drawer: Text.Drawer,
        wellbeing: *const Wellbeing,
        content_col: u16,
        max_content_col: u16,
        start_row: u16,
        max_row: u16,
    ) void {
        const avail_w: u16 = if (max_content_col > content_col) max_content_col - content_col + 1 else return;
        var r = start_row;

        // Top KPI Row: 3 StatCards side-by-side
        if (r + 3 <= max_row and avail_w >= 36) {
            const gap: u16 = 2;
            const card_w: u16 = (avail_w - gap * 2) / 3;

            const active_s = wellbeing.data.today.active_screen_s;
            // null: no daily limit, so no "/ limit" and no percentage.
            const limit_s: ?u64 = if (wellbeing.option.screen_time.daily_limit_ms) |ms| ms / std.time.ms_per_s else null;
            const screen_frac: f32 = if (limit_s) |l|
                (if (l > 0) @as(f32, @floatFromInt(active_s)) / @as(f32, @floatFromInt(l)) else 0.0)
            else
                0.0;

            var screen_val_buf: [32]u8 = undefined;
            const screen_val = if (limit_s) |l|
                std.fmt.bufPrint(&screen_val_buf, "{d}h {d:0>2}m / {d}h", .{ active_s / 3600, (active_s % 3600) / 60, l / 3600 }) catch ""
            else
                std.fmt.bufPrint(&screen_val_buf, "{d}h {d:0>2}m", .{ active_s / 3600, (active_s % 3600) / 60 }) catch "";
            var screen_pct_buf: [16]u8 = undefined;
            const screen_pct = if (limit_s != null)
                std.fmt.bufPrint(&screen_pct_buf, "{d}%", .{@as(u32, @intFromFloat(@min(1.0, screen_frac) * 100.0))}) catch ""
            else
                "no limit";

            StatCard.render(.{
                .col = content_col,
                .row = r,
                .width = card_w,
                .height = 3,
                .title = "Screen Quota",
                .value = screen_val,
                .badge = screen_pct,
                .progress = screen_frac,
                .progress_mode = .semantic_quota,
            }, self.tokens, &self.card_buffer, drawer);

            const foc_s = wellbeing.data.today.focus_s;
            var foc_val_buf: [32]u8 = undefined;
            const foc_val = std.fmt.bufPrint(&foc_val_buf, "{d}h {d:0>2}m", .{ foc_s / 3600, (foc_s % 3600) / 60 }) catch "";
            var tasks_buf: [24]u8 = undefined;
            const tasks_badge = std.fmt.bufPrint(&tasks_buf, "{d} done", .{wellbeing.data.today.tasks_completed}) catch "";
            const total_steps = @max(@as(u8, 1), wellbeing.focus_state.option.tasks_before_long_break);
            const cycle_frac: f32 = @as(f32, @floatFromInt(wellbeing.focus_state.tasks_in_cycle)) / @as(f32, @floatFromInt(total_steps));

            StatCard.render(.{
                .col = content_col + card_w + gap,
                .row = r,
                .width = card_w,
                .height = 3,
                .title = "Focus Today",
                .value = foc_val,
                .badge = tasks_badge,
                .progress = cycle_frac,
                .progress_mode = .semantic_completion,
            }, self.tokens, &self.card_buffer, drawer);

            var streak_val_buf: [32]u8 = undefined;
            const streak_val = std.fmt.bufPrint(&streak_val_buf, "{d} days", .{wellbeing.data.current_streak}) catch "";
            var best_buf: [24]u8 = undefined;
            const best_badge = std.fmt.bufPrint(&best_buf, "Best {d}d", .{wellbeing.data.best_streak}) catch "";

            StatCard.render(.{
                .col = content_col + (card_w + gap) * 2,
                .row = r,
                .width = avail_w - (card_w + gap) * 2,
                .height = 3,
                .title = "Focus Streak",
                .value = streak_val,
                .badge = best_badge,
                .value_color = self.tokens.warning,
            }, self.tokens, &self.card_buffer, drawer);

            r += 4;
        }

        var fmt_buf: [128]u8 = undefined;

        // Pomodoro Status & Cycle Pips
        if (r <= max_row) {
            const rem_s = (wellbeing.focus_state.remaining_ms + 999) / 1000;
            const phase_name = switch (wellbeing.focus_state.phase) {
                .task => "Task",
                .short_break => "Short Break",
                .long_break => "Long Break",
                .idle => "Idle",
            };
            const phase_info = if (wellbeing.focus_state.phase != .idle)
                std.fmt.bufPrint(&fmt_buf, "Pomodoro: {s} [{d:0>2}:{d:0>2}] {s}", .{
                    phase_name,
                    rem_s / 60,
                    rem_s % 60,
                    if (wellbeing.isFocusPausedByAlert() or wellbeing.focus_state.paused) "[PAUSED]" else "[RUNNING]",
                }) catch ""
            else
                std.fmt.bufPrint(&fmt_buf, "Pomodoro: {s} (Press 'p' or switch to Tab 2)", .{phase_name}) catch "";
            const text_w = Text.draw(drawer, content_col, r, phase_info, self.tokens.primary, 255, max_content_col);

            const total_steps = wellbeing.focus_state.option.tasks_before_long_break;
            const pips_w = StepIndicator.measureWidth(total_steps, 2, 1);
            if (max_content_col > content_col + text_w + pips_w + 2) {
                _ = StepIndicator.render(.{
                    .col = max_content_col - pips_w,
                    .row = r,
                    .max_col = max_content_col,
                    .total_steps = total_steps,
                    .completed_steps = wellbeing.focus_state.tasks_in_cycle,
                    .active_step = if (wellbeing.focus_state.phase == .task) wellbeing.focus_state.tasks_in_cycle else null,
                }, self.tokens, &self.card_buffer, drawer.allocator);
            }
            r += 1;
        }

        // Health Tallies
        if (r <= max_row) {
            const health_line = std.fmt.bufPrint(
                &fmt_buf,
                "Eye Pauses: {d}  |  Posture Checks: {d}  |  Hydration: {d}",
                .{ wellbeing.data.today.eyesight_breaks, wellbeing.data.today.movement_breaks, wellbeing.data.today.hydration_count },
            ) catch "";
            _ = Text.drawEllipsis(drawer, content_col, r, health_line, self.tokens.secondary, 255, max_content_col, "…");
            r += 2;
        }

        // Top Foreground Tools Horizontal Bar Chart
        if (r <= max_row) {
            _ = Text.draw(drawer, content_col, r, "Top Foreground Tools:", self.tokens.muted, 255, max_content_col);
            r += 1;

            var bars: [4]BarChart.HorizontalBar = undefined;
            var val_bufs: [4][24]u8 = undefined;
            var bar_count: usize = 0;

            for (&wellbeing.data.today.top_apps) |*app| {
                if (app.seconds == 0 or app.name[0] == 0) continue;
                if (bar_count >= 4) break;
                const val_str = std.fmt.bufPrint(&val_bufs[bar_count], "{d}m {d:0>2}s", .{ app.seconds / 60, app.seconds % 60 }) catch "";
                bars[bar_count] = .{
                    .label = app.getName(),
                    .value = @floatFromInt(app.seconds),
                    .value_text = val_str,
                };
                bar_count += 1;
            }

            if (bar_count > 0 and r <= max_row) {
                const max_bar_rows = max_row - r + 1;
                _ = BarChart.renderHorizontal(.{
                    .col = content_col,
                    .row = r,
                    .width = avail_w,
                    .max_rows = max_bar_rows,
                    .bars = bars[0..bar_count],
                }, self.tokens, &self.card_buffer, drawer);
            } else if (r <= max_row) {
                _ = Text.draw(drawer, content_col, r, "(No foreground process samples yet)", self.tokens.muted, 255, max_content_col);
            }
        }
    }

    fn renderPomodoroTab(
        self: *Overlay,
        drawer: Text.Drawer,
        wellbeing: *const Wellbeing,
        content_col: u16,
        max_content_col: u16,
        start_row: u16,
        max_row: u16,
        hotspots: ?*Table,
    ) void {
        const avail_w: u16 = if (max_content_col > content_col) max_content_col - content_col + 1 else return;
        const avail_h: u16 = if (max_row >= start_row) max_row - start_row + 1 else return;

        const ring_w: u16 = @min(22, avail_w / 2);
        const ring_h: u16 = @min(9, avail_h);

        const phase = wellbeing.focus_state.phase;
        const is_paused = wellbeing.isFocusPausedByAlert() or wellbeing.focus_state.paused;
        const total_ms: u64 = switch (phase) {
            .task => wellbeing.focus_state.option.task_ms,
            .short_break => wellbeing.focus_state.option.short_break_ms,
            .long_break => wellbeing.focus_state.option.long_break_ms,
            .idle => wellbeing.focus_state.option.task_ms,
        };
        const rem_ms: u64 = if (phase == .idle) total_ms else wellbeing.focus_state.remaining_ms;
        const rem_s: u64 = (rem_ms + 999) / 1000;

        const progress: f32 = if (phase == .idle)
            0.0
        else if (total_ms > 0)
            1.0 - (@as(f32, @floatFromInt(rem_ms)) / @as(f32, @floatFromInt(total_ms)))
        else
            0.0;

        const ring_color: [3]u8 = if (phase == .idle)
            self.tokens.border
        else if (is_paused)
            self.tokens.warning
        else switch (phase) {
            .task => self.tokens.accent,
            .short_break, .long_break => self.tokens.healthy,
            .idle => self.tokens.border,
        };

        var time_buf: [16]u8 = undefined;
        const time_str = std.fmt.bufPrint(&time_buf, "{d:0>2}:{d:0>2}", .{ rem_s / 60, rem_s % 60 }) catch "00:00";

        const badge_str: []const u8 = if (phase == .idle)
            "IDLE"
        else if (is_paused)
            "PAUSED"
        else switch (phase) {
            .task => "FOCUS",
            .short_break => "SHORT BREAK",
            .long_break => "LONG BREAK",
            .idle => "IDLE",
        };

        const total_steps = wellbeing.focus_state.option.tasks_before_long_break;
        var cycle_buf: [24]u8 = undefined;
        const cycle_str = std.fmt.bufPrint(&cycle_buf, "Task {d}/{d}", .{
            @min(wellbeing.focus_state.tasks_in_cycle + 1, total_steps),
            total_steps,
        }) catch "";

        RingGauge.render(.{
            .col = content_col,
            .row = start_row,
            .width = ring_w,
            .height = ring_h,
            .progress = progress,
            .stroke_width_px = 6.5,
            .fill_color = ring_color,
            .headline = time_str,
            .badge = badge_str,
            .badge_color = ring_color,
            .caption = cycle_str,
        }, self.tokens, &self.card_buffer, drawer.allocator, drawer);

        // StepIndicator pips centered below RingGauge
        const pips_row = start_row + ring_h;
        if (pips_row <= max_row) {
            const pips_w = StepIndicator.measureWidth(total_steps, 2, 1);
            const pips_col = if (ring_w > pips_w) content_col + (ring_w - pips_w) / 2 else content_col;
            _ = StepIndicator.render(.{
                .col = pips_col,
                .row = pips_row,
                .max_col = content_col + ring_w,
                .total_steps = total_steps,
                .completed_steps = wellbeing.focus_state.tasks_in_cycle,
                .active_step = if (phase == .task) wellbeing.focus_state.tasks_in_cycle else null,
            }, self.tokens, &self.card_buffer, drawer.allocator);
        }

        // Right Column: Pomodoro Stats + Interactive Control Buttons
        const right_col = content_col + ring_w + 3;
        if (right_col + 16 > max_content_col) return;
        const right_w = max_content_col - right_col + 1;

        var r = start_row;
        const half_w = (right_w - 2) / 2;
        if (r + 3 <= max_row and half_w >= 10) {
            const foc_s = wellbeing.data.today.focus_s;
            var foc_buf: [24]u8 = undefined;
            const foc_str = std.fmt.bufPrint(&foc_buf, "{d}h {d:0>2}m", .{ foc_s / 3600, (foc_s % 3600) / 60 }) catch "";

            StatCard.render(.{
                .col = right_col,
                .row = r,
                .width = half_w,
                .height = 3,
                .title = "Focus Time",
                .value = foc_str,
            }, self.tokens, &self.card_buffer, drawer);

            const brk_s = wellbeing.data.today.break_s;
            var brk_buf: [24]u8 = undefined;
            const brk_str = std.fmt.bufPrint(&brk_buf, "{d}h {d:0>2}m", .{ brk_s / 3600, (brk_s % 3600) / 60 }) catch "";

            StatCard.render(.{
                .col = right_col + half_w + 2,
                .row = r,
                .width = right_w - half_w - 2,
                .height = 3,
                .title = "Rest Time",
                .value = brk_str,
            }, self.tokens, &self.card_buffer, drawer);

            r += 4;
        }

        var info_buf: [64]u8 = undefined;
        if (r <= max_row) {
            const summary = std.fmt.bufPrint(
                &info_buf,
                "Completed: {d} tasks  |  Sessions: {d}",
                .{ wellbeing.data.today.tasks_completed, wellbeing.data.sessions },
            ) catch "";
            _ = Text.draw(drawer, right_col, r, summary, self.tokens.secondary, 255, max_content_col);
            r += 2;
        }

        if (hotspots) |ht| {
            const btn_w: u16 = @min(16, (right_w - 2) / 2);
            if (r <= max_row and btn_w >= 10) {
                const start_label = if (phase == .idle) "Start Focus" else if (is_paused) "Resume" else "Pause";
                Button.render(.{
                    .col = right_col,
                    .row = r,
                    .width = btn_w,
                    .label = start_label,
                    .shortcut = "p",
                    .style = .primary,
                    .focused = true,
                    .action = .{ .button = @intFromEnum(ButtonId.toggle_focus) },
                }, self.tokens, &self.card_buffer, ht, drawer);

                Button.render(.{
                    .col = right_col + btn_w + 2,
                    .row = r,
                    .width = right_w - btn_w - 2,
                    .label = "Skip Phase",
                    .shortcut = "s",
                    .style = .default,
                    .action = .{ .button = @intFromEnum(ButtonId.skip_focus) },
                }, self.tokens, &self.card_buffer, ht, drawer);
                r += 2;
            }

            if (r <= max_row and btn_w >= 10) {
                Button.render(.{
                    .col = right_col,
                    .row = r,
                    .width = btn_w,
                    .label = "Reset Cycle",
                    .shortcut = "r",
                    .style = .danger,
                    .action = .{ .button = @intFromEnum(ButtonId.reset_focus) },
                }, self.tokens, &self.card_buffer, ht, drawer);
            }
        }
    }

    fn renderActivityTab(
        self: *Overlay,
        drawer: Text.Drawer,
        wellbeing: *const Wellbeing,
        content_col: u16,
        max_content_col: u16,
        start_row: u16,
        max_row: u16,
        hotspots: ?*Table,
    ) void {
        const avail_w: u16 = if (max_content_col > content_col) max_content_col - content_col + 1 else return;
        var r = start_row;

        const hist_count: usize = @min(wellbeing.data.history_count, storage.max_history_days);
        const total_days: usize = hist_count + 1;
        const selected_idx: u16 = @intCast(@min(self.selected_day_idx orelse @as(u16, @intCast(total_days - 1)), total_days - 1));

        const inspected_record: storage.DayRecord = if (selected_idx < hist_count)
            wellbeing.data.history[selected_idx]
        else
            wellbeing.data.today;

        var hdr_buf: [96]u8 = undefined;
        const day_tag = if (selected_idx == total_days - 1) "Today" else "Selected";
        const hdr_str = std.fmt.bufPrint(
            &hdr_buf,
            "History ({s}: {d}m focus / {d}m active, {d} tasks)",
            .{ day_tag, inspected_record.focus_s / 60, inspected_record.active_screen_s / 60, inspected_record.tasks_completed },
        ) catch "Activity History";

        if (r <= max_row) {
            _ = Text.drawEllipsis(drawer, content_col, r, hdr_str, self.tokens.secondary, 255, max_content_col, "…");
            r += 1;
        }

        // Build vertical bar chart columns from history + today
        var cols: [storage.max_history_days + 1]BarChart.Column = undefined;
        var lbl_bufs: [storage.max_history_days + 1][8]u8 = undefined;
        for (0..total_days) |i| {
            const rec = if (i < hist_count) wellbeing.data.history[i] else wellbeing.data.today;
            const lbl = if (i == total_days - 1)
                "Now"
            else
                std.fmt.bufPrint(&lbl_bufs[i], "-{d}d", .{total_days - 1 - i}) catch "";
            cols[i] = .{
                .value = @floatFromInt(rec.focus_s),
                .secondary_value = @floatFromInt(rec.active_screen_s),
                .label = lbl,
            };
        }

        const chart_h: u16 = @min(5, if (max_row > r) max_row - r else 2);
        if (chart_h >= 2 and r + chart_h <= max_row) {
            _ = BarChart.renderVertical(.{
                .col = content_col,
                .row = r,
                .width = avail_w,
                .height = chart_h,
                .columns = cols[0..total_days],
                .selected_index = selected_idx,
            }, self.tokens, &self.card_buffer, drawer, hotspots);
            r += chart_h + 1;
        }

        // Lower section: Inspected Day's Top Foreground Tools Horizontal Bar Chart
        if (r <= max_row) {
            _ = Text.draw(drawer, content_col, r, "Foreground Tool Breakdown:", self.tokens.muted, 255, max_content_col);
            r += 1;

            var bars: [storage.max_top_apps]BarChart.HorizontalBar = undefined;
            var val_bufs: [storage.max_top_apps][24]u8 = undefined;
            var bar_count: usize = 0;

            for (&inspected_record.top_apps) |*app| {
                if (app.seconds == 0 or app.name[0] == 0) continue;
                const val_str = std.fmt.bufPrint(&val_bufs[bar_count], "{d}m {d:0>2}s", .{ app.seconds / 60, app.seconds % 60 }) catch "";
                bars[bar_count] = .{
                    .label = app.getName(),
                    .value = @floatFromInt(app.seconds),
                    .value_text = val_str,
                };
                bar_count += 1;
            }

            if (bar_count > 0 and r <= max_row) {
                _ = BarChart.renderHorizontal(.{
                    .col = content_col,
                    .row = r,
                    .width = avail_w,
                    .max_rows = max_row - r + 1,
                    .bars = bars[0..bar_count],
                }, self.tokens, &self.card_buffer, drawer);
            } else if (r <= max_row) {
                _ = Text.draw(drawer, content_col, r, "(No process usage recorded for this day)", self.tokens.muted, 255, max_content_col);
            }
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
        Box.fillCells(allocator, &self.bg_buffer, .{ .col = col, .row = row, .width = width, .height = height }, color);
    }

    pub fn drawDimmingBackdropOutside(
        self: *Overlay,
        allocator: Allocator,
        total_cols: u16,
        total_rows: u16,
        rect: PanelRect,
        dim_color: [4]u8,
    ) void {
        Box.dimOutside(allocator, &self.bg_buffer, total_cols, total_rows, .{
            .col = rect.col,
            .row = rect.row,
            .width = rect.width,
            .height = rect.height,
        }, dim_color);
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
        const drawer: Text.Drawer = .{
            .allocator = allocator,
            .atlas = atlas,
            .rasterizer = rasterizer,
            .gray_buffer = &self.gray_buffer,
            .color_buffer = &self.color_buffer,
        };
        const b_opt: Border.Option = .{
            .shape = shape,
            .style = .custom,
            .mode = .glyph,
            .color = fg,
            .alpha = fg_a,
            .glyph_style = style,
        };
        b_opt.render(.{ .col = col, .row = row, .width = width, .height = height }, self.tokens, null, false, &self.card_buffer, allocator, drawer);
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
        const drawer: Text.Drawer = .{
            .allocator = allocator,
            .atlas = atlas,
            .rasterizer = rasterizer,
            .gray_buffer = &self.gray_buffer,
            .color_buffer = &self.color_buffer,
        };
        Divider.renderHorizontal(col, row, width, null, .{
            .mode = .glyph,
            .color = fg,
            .alpha = fg_a,
            .glyph_style = style,
            .inset_cols = 2,
        }, self.tokens, null, drawer);
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
