//! Wellbeing break and lock screen overlay: a centered modal card over a
//! dimmed scrim showing the phase/alert header, cycle progress pips,
//! break prompt, remaining countdown bar and early-unlock action.
//!
//! `State` is plain data, `update` is the only code that changes it, and
//! `view` writes its nodes (ADR 0009). Nothing allocates.

const std = @import("std");
const assert = std.debug.assert;

const Theme = @import("Theme.zig");
const Color = Theme.Color;
const button = @import("button.zig");
const chart = @import("chart.zig");
const dialog = @import("dialog.zig");
const motion = @import("motion.zig");
const text = @import("text.zig");
const Tree = @import("Tree.zig");
const Id = Tree.Id;

pub const width: f32 = 440;
/// Maximum logical width of the minimal bottom HUD bar used over the
/// fullscreen ASCII animation backdrop.
pub const hud_max_width: f32 = 680;
/// Logical viewport width below which the bottom HUD stacks vertically so
/// the title, countdown, prompt, and action button never crowd each other.
pub const hud_stack_width: f32 = 460;
/// Logical height reserved at the bottom of the viewport for the HUD bar so
/// the fullscreen ASCII grid stays centered above it.
pub const hud_reserve: f32 = 96;

pub const title_capacity = 64;
pub const subtitle_capacity = 96;
pub const prompt_capacity = 256;
pub const steps_max = 12;

pub const scrim_id = Id.of("lock.scrim");
pub const card_id = Id.of("lock.card");
pub const unlock_id = Id.of("lock.unlock");

pub const Tone = enum(u2) {
    healthy,
    warning,
    critical,

    fn accent(self: Tone, theme: *const Theme) Color {
        return switch (self) {
            .healthy => theme.success,
            .warning => theme.warning,
            .critical => theme.destructive,
        };
    }
};

/// Presentation style of the wellbeing overlay surface.
pub const Layout = enum(u1) {
    /// Centered modal card over a dimmed scrim.
    card,
    /// Compact bottom bar leaving the viewport open for the ASCII backdrop.
    hud,
};

/// Action button semantics for locking breaks versus dismissible reminders.
pub const Action = enum(u1) {
    unlock,
    dismiss,

    pub fn label(self: Action) []const u8 {
        return switch (self) {
            .unlock => "Unlock early",
            .dismiss => "Dismiss",
        };
    }

    pub fn keyCap(self: Action) []const u8 {
        return switch (self) {
            .unlock => "Ctrl+Shift+D",
            .dismiss => "Esc",
        };
    }
};

const Presentation = packed struct(u8) {
    tone: Tone = .healthy,
    layout: Layout = .card,
    action: Action = .unlock,
    _: u4 = 0,
};

pub const Request = struct {
    tone: Tone = .healthy,
    layout: Layout = .card,
    action: Action = .unlock,
    title: []const u8,
    subtitle: []const u8,
    prompt: []const u8,
    remaining_s: u32,
    total_s: u32,
    steps_total: u8 = 0,
    steps_done: u8 = 0,
    scrim_alpha: u8 = 128,
    /// Start keyboard focus on the unlock button.
    focus: bool = true,
};

pub const State = struct {
    phase: dialog.Phase = .closed,
    presentation: Presentation = .{},
    touch: button.State = .normal,
    focused: bool = false,
    motion: motion.Mode = .full,
    scrim_alpha: u8 = 128,
    steps_total: u8 = 0,
    steps_done: u8 = 0,
    remaining_s: u32 = 0,
    total_s: u32 = 0,
    progress: f32 = 0,
    title_len: u8 = 0,
    subtitle_len: u8 = 0,
    prompt_len: u16 = 0,
    time_len: u8 = 0,
    title_bytes: [title_capacity]u8 = undefined,
    subtitle_bytes: [subtitle_capacity]u8 = undefined,
    prompt_bytes: [prompt_capacity]u8 = undefined,
    time_bytes: [16]u8 = undefined,

    pub const empty: State = .{};

    pub fn title(self: *const State) []const u8 {
        return self.title_bytes[0..self.title_len];
    }

    pub fn subtitle(self: *const State) []const u8 {
        return self.subtitle_bytes[0..self.subtitle_len];
    }

    pub fn prompt(self: *const State) []const u8 {
        return self.prompt_bytes[0..self.prompt_len];
    }

    pub fn timeText(self: *const State) []const u8 {
        return self.time_bytes[0..self.time_len];
    }

    pub fn isShown(self: *const State) bool {
        return self.phase != .closed;
    }

    pub fn acceptsInput(self: *const State) bool {
        return self.phase.acceptsInput();
    }

    pub fn wakeMs(self: *const State) ?u32 {
        return self.phase.wakeMs();
    }

    pub fn hit(self: *const State, id: Id) Hit {
        if (!self.phase.acceptsInput() or id == .none) return .none;
        if (id == unlock_id) return .unlock;
        if (id == card_id) return .card;
        if (id == scrim_id) return .scrim;
        return .none;
    }
};

pub const Hit = enum { none, scrim, card, unlock };

pub const Pointer = enum(u8) { away, unlock };

pub const Event = union(enum) {
    /// Opens or updates the lock screen snapshot from the wellbeing engine.
    sync: Request,
    close,
    tick: u32,
    pointer: Pointer,
    press,
    release: Pointer,
    focus,
    activate,
    blur,
};

pub const Outcome = enum {
    quiet,
    redraw,
    /// User activated the unlock button.
    unlocked,
};

/// Applies `event` and returns what happened.
pub fn update(state: *State, event: Event) Outcome {
    return switch (event) {
        .sync => |req| sync(state, req),
        .close => if (beginLeave(state)) .redraw else .quiet,
        .tick => |dt_ms| switch (state.phase.tick(state.motion, dt_ms)) {
            .quiet => .quiet,
            .redraw => .redraw,
            .closed => {
                state.touch = .normal;
                return .redraw;
            },
        },
        .pointer => |over| hoverAt(state, over),
        .press => pressUnlock(state),
        .release => |over| releaseUnlock(state, over),
        .focus => focusUnlock(state),
        .activate => activateUnlock(state),
        .blur => blur(state),
    };
}

fn sync(self: *State, req: Request) Outcome {
    const new_title_len: u8 = @intCast(text.cut(req.title, title_capacity));
    const new_sub_len: u8 = @intCast(text.cut(req.subtitle, subtitle_capacity));
    const new_prompt_len: u16 = @intCast(text.cut(req.prompt, prompt_capacity));
    const clamped_steps_total: u8 = @min(req.steps_total, steps_max);
    const clamped_steps_done: u8 = @min(req.steps_done, clamped_steps_total);
    const new_progress: f32 = if (req.total_s > 0)
        std.math.clamp(1.0 - (@as(f32, @floatFromInt(req.remaining_s)) / @as(f32, @floatFromInt(req.total_s))), 0, 1)
    else
        0;

    const same = self.phase.acceptsInput() and
        self.presentation.tone == req.tone and
        self.presentation.layout == req.layout and
        self.presentation.action == req.action and
        self.scrim_alpha == req.scrim_alpha and
        self.steps_total == clamped_steps_total and
        self.steps_done == clamped_steps_done and
        self.remaining_s == req.remaining_s and
        self.total_s == req.total_s and
        std.mem.eql(u8, self.title(), req.title[0..new_title_len]) and
        std.mem.eql(u8, self.subtitle(), req.subtitle[0..new_sub_len]) and
        std.mem.eql(u8, self.prompt(), req.prompt[0..new_prompt_len]);

    const entered = self.phase.enterImmediate(self.motion);
    if (entered) {
        self.touch = .normal;
        self.focused = req.focus;
    }

    self.presentation = .{
        .tone = req.tone,
        .layout = req.layout,
        .action = req.action,
    };
    self.scrim_alpha = req.scrim_alpha;
    self.steps_total = clamped_steps_total;
    self.steps_done = clamped_steps_done;
    self.remaining_s = req.remaining_s;
    self.total_s = req.total_s;
    self.progress = new_progress;
    self.title_len = new_title_len;
    self.subtitle_len = new_sub_len;
    self.prompt_len = new_prompt_len;
    @memcpy(self.title_bytes[0..new_title_len], req.title[0..new_title_len]);
    @memcpy(self.subtitle_bytes[0..new_sub_len], req.subtitle[0..new_sub_len]);
    @memcpy(self.prompt_bytes[0..new_prompt_len], req.prompt[0..new_prompt_len]);

    const mins = req.remaining_s / 60;
    const secs = req.remaining_s % 60;
    const time_str = std.fmt.bufPrint(&self.time_bytes, "{d:0>2}:{d:0>2}", .{ mins, secs }) catch "00:00";
    self.time_len = @intCast(time_str.len);

    return if (entered or !same) .redraw else .quiet;
}

fn beginLeave(self: *State) bool {
    self.touch = .normal;
    return self.phase.leaveImmediate(self.motion);
}

fn hoverAt(self: *State, over: Pointer) Outcome {
    if (!self.phase.acceptsInput()) return .quiet;
    if (self.touch == .pressed) return .quiet;
    const next: button.State = switch (over) {
        .unlock => .hovered,
        .away => .normal,
    };
    if (self.touch == next) return .quiet;
    self.touch = next;
    return .redraw;
}

fn pressUnlock(self: *State) Outcome {
    if (!self.phase.acceptsInput()) return .quiet;
    self.touch = .pressed;
    return .redraw;
}

fn releaseUnlock(self: *State, over: Pointer) Outcome {
    if (self.touch != .pressed) return .quiet;
    self.touch = switch (over) {
        .unlock => .hovered,
        .away => .normal,
    };
    if (over == .unlock) return .unlocked;
    return .redraw;
}

fn focusUnlock(self: *State) Outcome {
    if (!self.phase.acceptsInput() or self.focused) return .quiet;
    self.focused = true;
    return .redraw;
}

fn activateUnlock(self: *State) Outcome {
    if (!self.phase.acceptsInput() or !self.focused) return .quiet;
    return .unlocked;
}

fn blur(self: *State) Outcome {
    if (!self.phase.acceptsInput() or !self.focused) return .quiet;
    self.focused = false;
    return .redraw;
}

/// Fixed UI labels rendered outside the caller-provided strings:
/// `"Remaining"`, `time_bytes` (`<= 16` bytes), unlock label, and key cap.
const chrome_line_max = 1 + (@sizeOf(@FieldType(State, "time_bytes")) + 1) + 2;

/// Lines of wrapped text one view needs at most.
pub const line_max = title_capacity + 1 + subtitle_capacity + 1 + prompt_capacity + 1 + chrome_line_max;

/// Most nodes one view writes.
pub const node_max = dialog.node_max + 9 + steps_max + chart.progress_nodes + button.node_max;

/// Writes the lock screen over the terminal, or nothing when closed.
pub fn view(state: *const State, tree: *Tree, theme: *const Theme) Tree.Error!void {
    return viewIn(state, tree, theme, hud_max_width);
}

/// Writes the lock screen adapted to a viewport `viewport_width` logical pixels
/// wide, stacking the bottom HUD vertically on narrow windows.
pub fn viewIn(state: *const State, tree: *Tree, theme: *const Theme, viewport_width: f32) Tree.Error!void {
    if (state.phase == .closed) return;
    const presence = state.phase.presence(state.motion);
    const accent = state.presentation.tone.accent(theme).fade(presence);

    switch (state.presentation.layout) {
        .card => try viewCard(state, tree, theme, presence, accent, viewport_width),
        .hud => try viewHud(state, tree, theme, presence, accent, viewport_width),
    }
}

fn viewCard(state: *const State, tree: *Tree, theme: *const Theme, presence: f32, accent: Color, viewport_width: f32) Tree.Error!void {
    const narrow = viewport_width < 300;
    const compact = viewport_width < 220;
    const frame = try dialog.open(tree, theme, .{
        .scrim_id = scrim_id,
        .card_id = card_id,
        .width = width,
        .presence = presence,
        .scrim_alpha = state.scrim_alpha,
        .margin = if (compact) 4 else if (narrow) 8 else dialog.margin,
        .padding = if (compact) 8 else if (narrow) 14 else dialog.padding,
    });

    // Header: title on left, cycle step pips on right.
    const hdr = try dialog.header(tree);
    const title_row = try tree.open(.{
        .axis = .row,
        .width = .fill,
        .cross = .center,
        .gap = 8,
    });
    _ = try tree.text(state.title(), .{
        .color = theme.foreground.fade(presence),
        .style = .lg_semibold,
        .width = .fill,
    });
    try viewSteps(tree, theme, state.steps_total, state.steps_done, accent, presence);
    tree.close(title_row);
    if (state.subtitle_len > 0) {
        try dialog.description(tree, theme, state.subtitle(), presence);
    }
    tree.close(hdr);

    // Body: prompt + Remaining countdown & bar.
    if (state.prompt_len > 0) {
        _ = try tree.text(state.prompt(), .{
            .color = theme.foreground.fade(presence),
            .width = .fill,
        });
    }

    const prog = try tree.open(.{ .width = .fill, .gap = 6 });
    const time_row = try tree.open(.{ .axis = .row, .width = .fill, .cross = .center });
    _ = try tree.text("Remaining", .{
        .color = theme.muted_foreground.fade(presence),
        .style = .sm,
        .width = .fill,
    });
    _ = try tree.text(state.timeText(), .{
        .color = theme.foreground.fade(presence),
        .style = .sm_medium,
        .figures = .tabular,
    });
    tree.close(time_row);
    try chart.progress(tree, theme, .bar, state.progress, accent, 6);
    tree.close(prog);

    const footer = if (narrow)
        try dialog.footerStacked(tree, .zero)
    else
        try dialog.footer(tree);
    try button.view(tree, theme, .{
        .id = unlock_id,
        .label = state.presentation.action.label(),
        .key_cap = if (compact) "" else state.presentation.action.keyCap(),
        .variant = .outline,
        .size = if (compact) .xs else .sm,
        .state = state.touch,
        .focused = state.focused,
        .fill_width = narrow,
        .presence = presence,
    });
    tree.close(footer);

    dialog.close(tree, frame);
}

fn viewHud(state: *const State, tree: *Tree, theme: *const Theme, presence: f32, accent: Color, viewport_width: f32) Tree.Error!void {
    const stacked = viewport_width < hud_stack_width;
    const narrow = viewport_width < 300;
    const compact = viewport_width < 240;
    const scrim_pad_h: u8 = if (compact) 6 else if (narrow) 10 else 20;
    const card_pad_h: u8 = if (compact) 8 else if (narrow) 12 else 16;

    const scrim = try tree.open(.{
        .id = scrim_id,
        .width = .fill,
        .height = .fill,
        .main = .end,
        .cross = .center,
        .padding = .{ .top = 16, .right = scrim_pad_h, .bottom = if (narrow) 12 else 20, .left = scrim_pad_h },
    });
    const bar = try tree.open(.{
        .id = card_id,
        .axis = if (stacked) .column else .row,
        .width = if (stacked) .fill else .{ .at_most = hud_max_width },
        .cross = if (stacked) .start else .center,
        .gap = if (stacked) 10 else 16,
        .padding = .{ .top = 12, .right = card_pad_h, .bottom = 12, .left = card_pad_h },
        .radius = Theme.radius,
        .fill = theme.popover.alpha(90).fade(presence),
        .border_width = 1,
        .border = theme.border.fade(presence),
        .overflow = .clip,
    });

    const body = try tree.open(.{ .width = .fill, .gap = 6 });
    const top_row = try tree.open(.{
        .axis = if (compact) .column else .row,
        .width = .fill,
        .cross = if (compact) .start else .center,
        .gap = if (compact) 4 else 8,
    });
    _ = try tree.text(state.title(), .{
        .color = theme.foreground.fade(presence),
        .style = .sm_medium,
        .width = .fill,
    });
    try viewSteps(tree, theme, state.steps_total, state.steps_done, accent, presence);
    _ = try tree.text(state.timeText(), .{
        .color = theme.foreground.fade(presence),
        .style = .sm_medium,
        .figures = .tabular,
        .wrap = .none,
    });
    tree.close(top_row);

    if (state.prompt_len > 0) {
        _ = try tree.text(state.prompt(), .{
            .color = theme.muted_foreground.fade(presence),
            .style = .xs,
            .width = .fill,
        });
    }
    try chart.progress(tree, theme, .bar, state.progress, accent, 4);
    tree.close(body);

    try button.view(tree, theme, .{
        .id = unlock_id,
        .label = state.presentation.action.label(),
        .key_cap = if (viewport_width < 220) "" else state.presentation.action.keyCap(),
        .variant = .outline,
        .size = if (viewport_width < 220) .xs else .sm,
        .state = state.touch,
        .focused = state.focused,
        .fill_width = stacked,
        .presence = presence,
    });

    tree.close(bar);
    tree.close(scrim);
}

fn viewSteps(tree: *Tree, theme: *const Theme, total: u8, done_count: u8, accent: Color, presence: f32) Tree.Error!void {
    if (total == 0) return;
    const pips = try tree.open(.{
        .axis = .row,
        .cross = .center,
        .gap = 4,
    });
    for (0..total) |idx| {
        const done = idx < done_count;
        _ = try tree.leaf(.{
            .width = .{ .fixed = 8 },
            .height = .{ .fixed = 8 },
            .radius = 4,
            .fill = if (done) accent else theme.muted.fade(presence),
        });
    }
    tree.close(pips);
}
