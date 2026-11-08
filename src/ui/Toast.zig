//! General UI toast notification component and zero-allocation toast queue.
//!
//! Provides a domain-agnostic, responsive, content-derived notification card
//! with smooth SDF rounded corners, subtle or semantic borders, leading icon,
//! title/description typography hierarchy, countdown timer, dismiss button,
//! interactive action prompts, and sub-cell mouse hit-testing.

const std = @import("std");
const Allocator = std.mem.Allocator;
const wc = @import("../unicode/wcwidth.zig");
const Tokens = @import("../color/Tokens.zig").Tokens;
const Card = @import("../renderer/Card.zig");
const Cell = @import("../renderer/Cell.zig");
const Atlas = @import("../renderer/Atlas.zig");
const Freetype = @import("../freetype/root.zig");
const Rasterizer = Freetype.Rasterizer;
const Rect = @import("Rect.zig").Rect;
const Border = @import("Border.zig");
const Box = @import("Box.zig");
const Label = @import("Label.zig");
const Kbd = @import("Kbd.zig");
const Icon = @import("Icon.zig");
const Table = @import("hotspot.zig").Table;

/// Keycap styling shared by toast action rendering and layout measurement so
/// that hit regions always match the drawn width.
inline fn actionKbdOption(icon_style: Icon.IconStyle, margin: u16) Kbd.Option {
    return .{ .style = .keycap, .connector_pad = 0, .icon_style = icon_style, .margin = margin };
}

pub const Toast = @This();

pub const Variant = enum {
    neutral,
    info,
    success,
    warning,
    critical,
};

pub const Position = enum {
    top_right,
    top_center,
    bottom_right,
};

pub const BorderStyle = Card.BorderStyle;

pub const Option = struct {
    enabled: bool = true,
    position: Position = .top_right,
    border_style: BorderStyle = .semantic,
    icon_style: Icon.IconStyle = .auto,
    duration_ms: u32 = 5000,
    min_cols: u16 = 32,
    max_cols: u16 = 48,
    margin_cols: u16 = 2,
    margin_rows: u16 = 1,
    dismiss_str: ?[]const u8 = null,
    action_prompt: []const u8 = ">",
    action_margin: u16 = 1,
};

pub const Request = struct {
    title: []const u8,
    description: []const u8 = "",
    icon: ?[]const u8 = null,
    icon_color: ?[3]u8 = null,
    icon_style: Icon.IconStyle = .auto,
    countdown_s: ?u32 = null,
    dismiss_str: []const u8 = "✕",
    action_prompt: ?[]const u8 = ">",
    action_shortcut: ?[]const u8 = null,
    action_label: ?[]const u8 = null,
    action_margin: u16 = 1,
    variant: Variant = .info,
    position: Position = .top_right,
    border_style: BorderStyle = .semantic,
    corner_radius: f32 = 8.0,
    border_width: f32 = 1.0,
    min_cols: u16 = 32,
    max_cols: u16 = 48,
    margin_cols: u16 = 2,
    margin_rows: u16 = 1,
};

/// Computed cell-grid geometry and interactive hit regions for a toast card.
pub const Layout = struct {
    col: u16,
    row: u16,
    width: u16,
    height: u16,
    content_col: u16,
    text_col: u16,
    max_content_col: u16,
    inner_text_w: u16,
    dismiss_col: u16,
    dismiss_row: u16,
    dismiss_w: u16,
    action_col: u16,
    action_row: u16,
    action_w: u16,
};

pub const HitPart = enum {
    dismiss,
    action,
    body,
};

pub const HitResult = struct {
    id: u64,
    part: HitPart,
};

const Text = @import("Text.zig");
pub const Drawer = Text.Drawer;
pub const stringWidth = Text.measure;

pub fn variantAccent(variant: Variant, tokens: Tokens) [3]u8 {
    return switch (variant) {
        .neutral => tokens.border,
        .info => tokens.info,
        .success => tokens.healthy,
        .warning => tokens.warning,
        .critical => tokens.critical,
    };
}

pub const splitDescription = Label.splitDescription;

/// Computes the deterministic cell-grid geometry and interactive hit regions for a toast card.
pub fn computeLayout(
    req: Request,
    total_cols: u16,
    total_rows: u16,
    row_offset: u16,
) Layout {
    const icon_str = req.icon orelse "";
    const icon_w = if (icon_str.len > 0) stringWidth(icon_str) else 0;

    const title_w = stringWidth(req.title);
    const desc_w = stringWidth(req.description);
    const kbd_opt = actionKbdOption(req.icon_style, req.action_margin);
    const action_req_w: u16 = if (req.action_shortcut) |s|
        Kbd.measureHint(req.action_prompt, s, req.action_label orelse "", kbd_opt)
    else
        0;
    const countdown_w: u16 = if (req.countdown_s != null) 5 else 0;
    const icon_spacing: u16 = if (icon_w > 0) icon_w + 1 else 0;

    const content_req = @max(
        title_w + countdown_w + 5,
        @max(desc_w, action_req_w),
    ) + icon_spacing;
    const desired_w: u16 = content_req +| 6;
    const max_allowed_w: u16 = if (total_cols > 4) @min(total_cols - 2, req.max_cols) else total_cols;
    const min_allowed_w: u16 = @min(req.min_cols, max_allowed_w);
    const toast_w: u16 = std.math.clamp(desired_w, min_allowed_w, max_allowed_w);

    const col: u16 = switch (req.position) {
        .top_right => if (total_cols > toast_w + req.margin_cols) total_cols - toast_w - req.margin_cols else 0,
        .top_center => if (total_cols > toast_w) (total_cols - toast_w) / 2 else 0,
        .bottom_right => if (total_cols > toast_w + req.margin_cols) total_cols - toast_w - req.margin_cols else 0,
    };

    const content_col = col + 2;
    const text_col = if (icon_w > 0) content_col + icon_w + 1 else content_col;
    const max_content_col = if (toast_w > 2) col + toast_w - 2 else col;
    const inner_text_w = if (max_content_col >= text_col) max_content_col - text_col + 1 else 20;

    const desc_split = splitDescription(req.description, inner_text_w);
    const has_two_lines = desc_split.line2.len > 0;
    const has_action = req.action_shortcut != null;

    const base_h: u16 = if (req.description.len == 0)
        3
    else if (has_two_lines)
        5
    else
        4;
    const toast_h: u16 = if (has_action) base_h + 1 else base_h;

    const row: u16 = switch (req.position) {
        .top_right, .top_center => @min(req.margin_rows +| row_offset, if (total_rows > toast_h) total_rows - toast_h else 0),
        .bottom_right => if (total_rows > toast_h +| req.margin_rows + 1 +| row_offset)
            total_rows - toast_h - req.margin_rows - 1 - row_offset
        else
            1,
    };

    const close_w = stringWidth(req.dismiss_str);
    const dismiss_col = if (max_content_col >= close_w) max_content_col - close_w + 1 else max_content_col;
    const dismiss_row = row + 1;

    var action_r = row + 2;
    if (req.description.len > 0) {
        action_r = if (has_two_lines) row + 4 else row + 3;
    }

    var action_w: u16 = 0;
    if (req.action_shortcut) |shortcut| {
        action_w = Kbd.measureHint(req.action_prompt, shortcut, req.action_label orelse "", kbd_opt);
        if (text_col + action_w > max_content_col + 1) {
            action_w = if (max_content_col + 1 > text_col) max_content_col + 1 - text_col else 0;
        }
    }

    return .{
        .col = col,
        .row = row,
        .width = toast_w,
        .height = toast_h,
        .content_col = content_col,
        .text_col = text_col,
        .max_content_col = max_content_col,
        .inner_text_w = inner_text_w,
        .dismiss_col = dismiss_col,
        .dismiss_row = dismiss_row,
        .dismiss_w = close_w,
        .action_col = text_col,
        .action_row = action_r,
        .action_w = action_w,
    };
}

/// Tests whether a cell-grid coordinate hits the dismiss button, action prompt, or card body.
pub fn hitTestLayout(layout: Layout, mouse_col: u16, mouse_row: u16) ?HitPart {
    if (mouse_col < layout.col or mouse_col >= layout.col + layout.width) return null;
    if (mouse_row < layout.row or mouse_row >= layout.row + layout.height) return null;

    if (layout.dismiss_w > 0 and
        mouse_row == layout.dismiss_row and
        mouse_col >= layout.dismiss_col and
        mouse_col < layout.dismiss_col + layout.dismiss_w)
    {
        return .dismiss;
    }

    if (layout.action_w > 0 and
        mouse_row == layout.action_row and
        mouse_col >= layout.action_col and
        mouse_col < layout.action_col + layout.action_w)
    {
        return .action;
    }

    return .body;
}

/// Renders a toast notification into the card instance buffer and text drawer at a vertical stack offset.
pub fn renderAt(
    req: Request,
    tokens: Tokens,
    total_cols: u16,
    total_rows: u16,
    row_offset: u16,
    card_buffer: *std.ArrayListUnmanaged(Card.Instance),
    drawer: Drawer,
) Layout {
    const layout = computeLayout(req, total_cols, total_rows, row_offset);
    const accent = req.icon_color orelse variantAccent(req.variant, tokens);
    const icon_str = req.icon orelse "";
    const icon_w = if (icon_str.len > 0) stringWidth(icon_str) else 0;

    const desc_split = splitDescription(req.description, layout.inner_text_w);
    const has_two_lines = desc_split.line2.len > 0;

    _ = Box.render(
        .{
            .rect = .{ .col = layout.col, .row = layout.row, .width = layout.width, .height = layout.height },
            .option = .{
                .surface = .card,
                .border = .{
                    .shape = .rounded,
                    .radius = req.corner_radius,
                    .width = req.border_width,
                    .style = if (req.border_style == .semantic) .semantic else .normal,
                },
            },
            .semantic_accent = accent,
        },
        tokens,
        null,
        card_buffer,
        drawer.allocator,
        drawer,
        null,
    );

    if (icon_w > 0) {
        _ = drawer.drawString(layout.content_col, layout.row + 1, icon_str, accent, 255, layout.max_content_col);
    }

    const close_w = layout.dismiss_w;
    var sec_buf: [16]u8 = undefined;
    var sec_str: []const u8 = "";
    var sec_w: u16 = 0;
    if (req.countdown_s) |secs| {
        sec_str = std.fmt.bufPrint(&sec_buf, "{d}s", .{secs}) catch "";
        sec_w = stringWidth(sec_str);
    }

    const right_badge_w: u16 = if (sec_w > 0) sec_w + 1 + close_w else close_w;
    const title_max_col = if (layout.max_content_col > right_badge_w + 1) layout.max_content_col - right_badge_w - 1 else layout.max_content_col;
    _ = drawer.drawString(layout.text_col, layout.row + 1, req.title, tokens.primary, 255, title_max_col);

    if (layout.max_content_col >= close_w and close_w > 0) {
        const close_col = layout.dismiss_col;
        _ = drawer.drawString(close_col, layout.row + 1, req.dismiss_str, tokens.muted, 255, layout.max_content_col);

        if (sec_w > 0 and close_col > sec_w + 1) {
            const timer_col = close_col - sec_w - 1;
            _ = drawer.drawString(timer_col, layout.row + 1, sec_str, tokens.secondary, 255, close_col - 1);
        }
    }

    if (req.description.len > 0) {
        _ = drawer.drawString(layout.text_col, layout.row + 2, desc_split.line1, tokens.secondary, 255, layout.max_content_col);
        if (has_two_lines and layout.row + 3 < layout.row + layout.height - 1) {
            _ = drawer.drawString(layout.text_col, layout.row + 3, desc_split.line2, tokens.secondary, 255, layout.max_content_col);
        }
    }

    if (req.action_shortcut) |shortcut| {
        if (layout.action_row < layout.row + layout.height) {
            _ = Kbd.renderHint(
                layout.text_col,
                layout.action_row,
                layout.max_content_col,
                req.action_prompt,
                shortcut,
                req.action_label orelse "",
                actionKbdOption(req.icon_style, req.action_margin),
                tokens,
                card_buffer,
                drawer,
                null,
                null,
            );
        }
    }

    return layout;
}

/// Renders a toast notification into the card instance buffer and text drawer at the top of the stack.
pub fn render(
    req: Request,
    tokens: Tokens,
    total_cols: u16,
    total_rows: u16,
    card_buffer: *std.ArrayListUnmanaged(Card.Instance),
    drawer: Drawer,
) void {
    _ = renderAt(req, tokens, total_cols, total_rows, 0, card_buffer, drawer);
}

/// Fixed-capacity, zero-allocation application toast manager supporting vertical stacking,
/// monotonic expiration countdowns, and interactive mouse hit-testing.
pub const Queue = struct {
    pub const max_active: usize = 4;

    pub const Entry = struct {
        id: u64 = 0,
        remaining_ms: u32 = 0,
        show_countdown: bool = false,

        title_buf: [64]u8 = undefined,
        title_len: u8 = 0,

        desc_buf: [160]u8 = undefined,
        desc_len: u8 = 0,

        icon_buf: [8]u8 = undefined,
        icon_len: u8 = 0,
        has_icon: bool = false,
        icon_color: ?[3]u8 = null,

        dismiss_buf: [8]u8 = undefined,
        dismiss_len: u8 = 0,

        prompt_buf: [8]u8 = undefined,
        prompt_len: u8 = 0,
        has_prompt: bool = false,

        shortcut_buf: [32]u8 = undefined,
        shortcut_len: u8 = 0,
        has_shortcut: bool = false,

        label_buf: [48]u8 = undefined,
        label_len: u8 = 0,
        has_label: bool = false,

        variant: Variant = .info,
        position: Position = .top_right,
        border_style: BorderStyle = .semantic,
        corner_radius: f32 = 8.0,
        border_width: f32 = 1.0,
        min_cols: u16 = 32,
        max_cols: u16 = 48,
        margin_cols: u16 = 2,
        margin_rows: u16 = 1,

        pub fn toRequest(self: *const Entry) Request {
            const rem_s: ?u32 = if (self.show_countdown)
                (self.remaining_ms + 999) / 1000
            else
                null;
            return .{
                .title = self.title_buf[0..self.title_len],
                .description = self.desc_buf[0..self.desc_len],
                .icon = if (self.has_icon) self.icon_buf[0..self.icon_len] else null,
                .icon_color = self.icon_color,
                .countdown_s = rem_s,
                .dismiss_str = self.dismiss_buf[0..self.dismiss_len],
                .action_prompt = if (self.has_prompt) self.prompt_buf[0..self.prompt_len] else null,
                .action_shortcut = if (self.has_shortcut) self.shortcut_buf[0..self.shortcut_len] else null,
                .action_label = if (self.has_label) self.label_buf[0..self.label_len] else null,
                .variant = self.variant,
                .position = self.position,
                .border_style = self.border_style,
                .corner_radius = self.corner_radius,
                .border_width = self.border_width,
                .min_cols = self.min_cols,
                .max_cols = self.max_cols,
                .margin_cols = self.margin_cols,
                .margin_rows = self.margin_rows,
            };
        }
    };

    entries: [max_active]Entry = undefined,
    count: usize = 0,
    next_id: u64 = 1,
    dirty: bool = false,

    pub inline fn isActive(self: *const Queue) bool {
        return self.count > 0;
    }

    fn copySlice(dest: []u8, src: []const u8) u8 {
        const n = @min(dest.len, src.len);
        @memcpy(dest[0..n], src[0..n]);
        return @intCast(n);
    }

    /// Pushes a new toast onto the top of the stack, shifting existing toasts down.
    pub fn push(self: *Queue, req: Request, duration_ms: u32) u64 {
        const effective_duration = if (duration_ms > 0) duration_ms else 5000;
        const id = self.next_id;
        self.next_id +%= 1;
        if (self.next_id == 0) self.next_id = 1;

        const keep: usize = @min(self.count, max_active - 1);
        var i: usize = keep;
        while (i > 0) : (i -= 1) {
            self.entries[i] = self.entries[i - 1];
        }

        var entry: Entry = .{
            .id = id,
            .remaining_ms = effective_duration,
            .show_countdown = req.countdown_s != null,
            .icon_color = req.icon_color,
            .variant = req.variant,
            .position = req.position,
            .border_style = req.border_style,
            .corner_radius = req.corner_radius,
            .border_width = req.border_width,
            .min_cols = req.min_cols,
            .max_cols = req.max_cols,
            .margin_cols = req.margin_cols,
            .margin_rows = req.margin_rows,
        };
        entry.title_len = copySlice(&entry.title_buf, req.title);
        entry.desc_len = copySlice(&entry.desc_buf, req.description);
        entry.dismiss_len = copySlice(&entry.dismiss_buf, req.dismiss_str);

        if (req.icon) |ic| {
            entry.icon_len = copySlice(&entry.icon_buf, ic);
            entry.has_icon = true;
        }
        if (req.action_prompt) |p| {
            entry.prompt_len = copySlice(&entry.prompt_buf, p);
            entry.has_prompt = true;
        }
        if (req.action_shortcut) |s| {
            entry.shortcut_len = copySlice(&entry.shortcut_buf, s);
            entry.has_shortcut = true;
        }
        if (req.action_label) |l| {
            entry.label_len = copySlice(&entry.label_buf, l);
            entry.has_label = true;
        }

        self.entries[0] = entry;
        self.count = keep + 1;
        self.dirty = true;
        return id;
    }

    /// Dismisses a specific toast by ID. Returns true if found and removed.
    pub fn dismiss(self: *Queue, id: u64) bool {
        var idx: usize = 0;
        while (idx < self.count) : (idx += 1) {
            if (self.entries[idx].id == id) {
                var j = idx;
                while (j + 1 < self.count) : (j += 1) {
                    self.entries[j] = self.entries[j + 1];
                }
                self.count -= 1;
                self.dirty = true;
                return true;
            }
        }
        return false;
    }

    /// Dismisses all active toasts.
    pub fn dismissAll(self: *Queue) void {
        if (self.count > 0) {
            self.count = 0;
            self.dirty = true;
        }
    }

    /// Advances active toast timers by `dt_ms` milliseconds and prunes expired toasts.
    /// Returns true when the visual state changed and a redraw is required.
    pub fn tick(self: *Queue, dt_ms: u64) bool {
        var changed = self.dirty;
        self.dirty = false;

        if (self.count == 0 or dt_ms == 0) return changed;

        const step: u32 = @intCast(@min(dt_ms, std.math.maxInt(u32)));
        var write_idx: usize = 0;
        for (0..self.count) |read_idx| {
            var entry = self.entries[read_idx];
            const old_sec = (entry.remaining_ms + 999) / 1000;
            if (entry.remaining_ms <= step) {
                changed = true;
                continue;
            }
            entry.remaining_ms -= step;
            const new_sec = (entry.remaining_ms + 999) / 1000;
            if (entry.show_countdown and old_sec != new_sec) {
                changed = true;
            }
            self.entries[write_idx] = entry;
            write_idx += 1;
        }
        self.count = write_idx;
        return changed;
    }

    /// Milliseconds until the next toast expiration or countdown second tick.
    pub fn msUntilNextTick(self: *const Queue) u64 {
        if (self.count == 0) return std.math.maxInt(u64);
        var min_ms: u64 = std.math.maxInt(u64);
        for (self.entries[0..self.count]) |entry| {
            min_ms = @min(min_ms, entry.remaining_ms);
            if (entry.show_countdown and entry.remaining_ms > 0) {
                const to_next_sec = ((entry.remaining_ms - 1) % 1000) + 1;
                min_ms = @min(min_ms, to_next_sec);
            }
        }
        return min_ms;
    }

    /// Renders all active toasts stacked vertically starting from `initial_row_offset`.
    pub fn build(
        self: *const Queue,
        tokens: Tokens,
        total_cols: u16,
        total_rows: u16,
        initial_row_offset: u16,
        card_buffer: *std.ArrayListUnmanaged(Card.Instance),
        drawer: Drawer,
        hotspots: ?*Table,
    ) void {
        var row_offset = initial_row_offset;
        for (self.entries[0..self.count]) |*entry| {
            const req = entry.toRequest();
            const layout = renderAt(req, tokens, total_cols, total_rows, row_offset, card_buffer, drawer);
            if (hotspots) |ht| {
                if (layout.dismiss_w > 0) {
                    ht.add(layout.dismiss_col, layout.dismiss_row, layout.dismiss_w, 1, .{ .toast_dismiss = entry.id });
                }
                if (layout.action_w > 0) {
                    ht.add(layout.action_col, layout.action_row, layout.action_w, 1, .{ .toast_action = entry.id });
                }
            }
            row_offset +|= layout.height + 1;
        }
    }

    /// Hit-tests all active toasts against `(mouse_col, mouse_row)` using the same stacking geometry as `build`.
    pub fn hitTest(
        self: *const Queue,
        mouse_col: u16,
        mouse_row: u16,
        total_cols: u16,
        total_rows: u16,
        initial_row_offset: u16,
    ) ?HitResult {
        var row_offset = initial_row_offset;
        for (self.entries[0..self.count]) |*entry| {
            const req = entry.toRequest();
            const layout = computeLayout(req, total_cols, total_rows, row_offset);
            if (hitTestLayout(layout, mouse_col, mouse_row)) |part| {
                return .{ .id = entry.id, .part = part };
            }
            row_offset +|= layout.height + 1;
        }
        return null;
    }
};

pub const ToastQueue = Queue;

test "ToastQueue: push, vertical stacking, countdown tick, expiration, and hit testing" {
    const testing = std.testing;

    var queue: Queue = .{};
    try testing.expect(!queue.isActive());

    const id1 = queue.push(.{
        .title = "Copied to clipboard",
        .description = "128 bytes copied.",
        .variant = .success,
    }, 3000);
    try testing.expect(queue.isActive());
    try testing.expectEqual(@as(usize, 1), queue.count);
    try testing.expect(queue.tick(0)); // consumes dirty flag

    const id2 = queue.push(.{
        .title = "Font size: 14pt",
        .action_shortcut = "Ctrl+0",
        .action_label = "Reset",
        .countdown_s = 5,
        .variant = .info,
    }, 5000);
    try testing.expectEqual(@as(usize, 2), queue.count);
    // Newest toast is at index 0
    try testing.expectEqual(id2, queue.entries[0].id);
    try testing.expectEqual(id1, queue.entries[1].id);

    // Hit test top toast (id2) on a 100x40 grid
    const layout0 = computeLayout(queue.entries[0].toRequest(), 100, 40, 0);
    const hit_dismiss = queue.hitTest(layout0.dismiss_col, layout0.dismiss_row, 100, 40, 0);
    try testing.expect(hit_dismiss != null);
    try testing.expectEqual(id2, hit_dismiss.?.id);
    try testing.expectEqual(HitPart.dismiss, hit_dismiss.?.part);

    const hit_action = queue.hitTest(layout0.action_col, layout0.action_row, 100, 40, 0);
    try testing.expect(hit_action != null);
    try testing.expectEqual(id2, hit_action.?.id);
    try testing.expectEqual(HitPart.action, hit_action.?.part);

    // Hit test second stacked toast (id1) below first toast
    const layout1 = computeLayout(queue.entries[1].toRequest(), 100, 40, layout0.height + 1);
    const hit_second = queue.hitTest(layout1.col + 1, layout1.row + 1, 100, 40, 0);
    try testing.expect(hit_second != null);
    try testing.expectEqual(id1, hit_second.?.id);
    try testing.expectEqual(HitPart.body, hit_second.?.part);

    // Advance 3000ms: id1 (3000ms) expires, id2 (5000ms -> 2000ms) remains
    try testing.expect(queue.tick(3000));
    try testing.expectEqual(@as(usize, 1), queue.count);
    try testing.expectEqual(id2, queue.entries[0].id);
    try testing.expectEqual(@as(?u32, 2), queue.entries[0].toRequest().countdown_s);

    // Dismiss id2 explicitly
    try testing.expect(queue.dismiss(id2));
    try testing.expect(!queue.isActive());

    // Push beyond max_active (rapid font zoom scenario) without integer overflow
    for (0..8) |_| {
        _ = queue.push(.{ .title = "Font: 12pt" }, 3000);
    }
    try testing.expectEqual(Queue.max_active, queue.count);
}
