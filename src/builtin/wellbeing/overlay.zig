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
const ProgressBar = @import("../../ui/ProgressBar.zig");
const Rect = @import("../../ui/Rect.zig").Rect;
const Box = @import("../../ui/Box.zig");
const Label = @import("../../ui/Label.zig");
const Kbd = @import("../../ui/Kbd.zig");
const StepIndicator = @import("../../ui/StepIndicator.zig");
const Rasterizer = @import("../../freetype/root.zig").Rasterizer;
const wc = @import("../../unicode/wcwidth.zig");

const root = @import("root.zig");
const Wellbeing = root.Wellbeing;
const reminders = @import("reminders.zig");
const ColorTokens = @import("../../color/Tokens.zig").Tokens;
const icons = @import("icons.zig");
const Table = @import("../../ui/hotspot.zig").Table;
pub const IconStyle = icons.IconStyle;
pub const IconId = icons.IconId;

pub const ButtonId = enum(u64) {
    close = 1,
};

pub const ToastVariant = enum {
    info,
    success,
    warning,
    critical,
    healthy_break,
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

/// The resolved looks of the surfaces the overlay draws
/// (`config.Config.Window.surfaceFor`).
pub const Surfaces = struct {
    card: Card.Option = .{},
    toast: Card.Option = .{},
    modal: Card.Option = .{},
};

pub const Overlay = struct {
    toast_active: bool = false,
    lock_screen_active: bool = false,
    was_active: bool = false,
    last_toast_layout: ?Toast.Layout = null,

    tokens: ColorTokens = ColorTokens.dark,
    surfaces: Surfaces = .{},
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
        return self.toast_active or self.lock_screen_active;
    }

    pub fn toastRowOffset(self: *const Overlay) u16 {
        if (self.toast_active) {
            if (self.last_toast_layout) |layout| return layout.height + 1;
        }
        return 0;
    }

    pub fn handleMouseClick(self: *Overlay, wellbeing: *Wellbeing, mouse_col: u16, mouse_row: u16) bool {
        if (self.lock_screen_active) return true;
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
        surfaces: Surfaces,
        toast_opt: Toast.Option,
        icon_opt: Icon.Option,
        modal_opt: Modal.Option,
        total_cols: u16,
        total_rows: u16,
        hotspots: ?*Table,
    ) void {
        self.tokens = color_tokens;

        self.surfaces = surfaces;
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
            .border_style = self.surfaces.toast.border_style,
            .corner_radius = self.surfaces.toast.effectiveRadius(),
            .border_width = self.surfaces.toast.border_width,
            .min_cols = self.toast_opt.min_cols,
            .max_cols = self.toast_opt.max_cols,
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
                        .shape = if (self.surfaces.card.border_shape == .sharp) .sharp else .rounded,
                        .radius = self.surfaces.card.effectiveRadius(),
                        .width = self.surfaces.card.border_width,
                        .style = if (self.surfaces.card.border_style == .semantic) .semantic else .normal,
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
