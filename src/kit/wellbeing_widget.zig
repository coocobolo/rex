//! Toggleable, draggable and resizable floating wellbeing focus widget for the
//! terminal overlay (`KitOverlay`, ADR 0010).
//!
//! `State` is plain data, `update` is the only code that changes it, `view`
//! builds its nodes into a `Tree`, and `place` translates and clamps it to the
//! viewport. Nothing allocates.

const std = @import("std");

const Theme = @import("Theme.zig");
const Color = Theme.Color;
const button = @import("button.zig");
const icons = @import("icons.zig");
const text = @import("text.zig");
const tree_zig = @import("tree.zig");
const Tree = tree_zig.Tree;
const Id = tree_zig.Id;
const Index = tree_zig.Index;

pub const min_width: f32 = 176;
pub const max_width: f32 = 420;
pub const min_height: f32 = 56;
pub const max_height: f32 = 240;
pub const default_width: f32 = 288;
pub const default_height: f32 = 148;

const compact_width: f32 = 244;
const compact_height: f32 = 116;
const edge_margin: f32 = 16;
const min_clamp_margin: f32 = 4;
const resize_grip_size: f32 = 14;
const turn = std.math.tau;

pub const card_id = Id.of("wellbeing_widget.card");
pub const play_pause_id = Id.of("wellbeing_widget.play_pause");
pub const skip_id = Id.of("wellbeing_widget.skip");
pub const reset_id = Id.of("wellbeing_widget.reset");
pub const close_id = Id.of("wellbeing_widget.close");
pub const resize_id = Id.of("wellbeing_widget.resize");

pub const Phase = enum(u8) { idle, task, short_break, long_break };
pub const Run = enum(u8) { paused, running, waiting };

pub const Hit = enum(u8) { none, card, play_pause, skip, reset, close, resize };

pub const Action = enum(u8) { toggle, skip, reset, close };

pub const DragOrigin = struct {
    pointer_x: f32,
    pointer_y: f32,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
};

pub const Capture = union(enum) {
    none,
    move: DragOrigin,
    resize: DragOrigin,
    button: Hit,
};

pub const Snapshot = struct {
    phase: Phase = .idle,
    run: Run = .paused,
    fraction: f32 = 0,
    seconds: u64 = 0,
    tasks_in_cycle: u8 = 0,
    tasks_before_long_break: u8 = 4,
};

pub const Event = union(enum) {
    toggle_visible,
    hide,
    sync: Snapshot,
    pointer: struct { over: Hit, x: f32, y: f32 },
    leave,
    press: struct { hit: Hit, x: f32, y: f32 },
    release: Hit,
};

pub const Outcome = union(enum) {
    quiet,
    redraw,
    action: Action,
};

pub const State = struct {
    width: f32 = default_width,
    height: f32 = default_height,
    x: f32 = 0,
    y: f32 = 0,
    fraction: f32 = 0,
    capture: Capture = .none,
    phase: Phase = .idle,
    run: Run = .paused,
    tasks_in_cycle: u8 = 0,
    tasks_before_long_break: u8 = 4,
    hovered: Hit = .none,
    visible: bool = false,
    positioned: bool = false,
    time_len: u8 = 5,
    time_buf: [16]u8 = .{ '0', '0', ':', '0', '0', 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },

    pub const empty: State = .{};

    pub fn timeText(self: *const State) []const u8 {
        return self.time_buf[0..self.time_len];
    }

    pub fn holdsPress(self: *const State) bool {
        return self.capture != .none;
    }

    pub fn hit(self: *const State, id: Id) Hit {
        if (!self.visible or id == .none) return .none;
        if (id == play_pause_id) return .play_pause;
        if (id == skip_id) return .skip;
        if (id == reset_id) return .reset;
        if (id == close_id) return .close;
        if (id == resize_id) return .resize;
        if (id == card_id) return .card;
        return .none;
    }
};

/// Applies `event` and returns whether anything changed or an action fired.
pub fn update(state: *State, event: Event) Outcome {
    return switch (event) {
        .toggle_visible => {
            state.visible = !state.visible;
            if (!state.visible) {
                state.capture = .none;
                state.hovered = .none;
            }
            return .redraw;
        },
        .hide => {
            if (!state.visible) return .quiet;
            state.visible = false;
            state.capture = .none;
            state.hovered = .none;
            return .redraw;
        },
        .sync => |snap| if (syncSnapshot(state, snap)) .redraw else .quiet,
        .pointer => |pt| handlePointer(state, pt.over, pt.x, pt.y),
        .leave => {
            if (state.hovered == .none and state.capture == .none) return .quiet;
            state.hovered = .none;
            return .redraw;
        },
        .press => |p| handlePress(state, p.hit, p.x, p.y),
        .release => |over| handleRelease(state, over),
    };
}

fn syncSnapshot(state: *State, snap: Snapshot) bool {
    var time_buf: [16]u8 = undefined;
    const time_len = formatSeconds(&time_buf, snap.seconds);
    const clamped_frac = clamp01(snap.fraction);
    const quant_frac = @round(clamped_frac * 360) / 360;

    const changed = state.phase != snap.phase or
        state.run != snap.run or
        state.fraction != quant_frac or
        state.tasks_in_cycle != snap.tasks_in_cycle or
        state.tasks_before_long_break != snap.tasks_before_long_break or
        state.time_len != time_len or
        !std.mem.eql(u8, state.time_buf[0..state.time_len], time_buf[0..time_len]);

    state.phase = snap.phase;
    state.run = snap.run;
    state.fraction = quant_frac;
    state.tasks_in_cycle = snap.tasks_in_cycle;
    state.tasks_before_long_break = snap.tasks_before_long_break;
    state.time_len = time_len;
    @memcpy(state.time_buf[0..time_len], time_buf[0..time_len]);
    return changed;
}

fn handlePointer(state: *State, over: Hit, x: f32, y: f32) Outcome {
    if (!state.visible) return .quiet;
    switch (state.capture) {
        .move => |orig| {
            const dx = x - orig.pointer_x;
            const dy = y - orig.pointer_y;
            const next_x = orig.x + dx;
            const next_y = orig.y + dy;
            if (state.x == next_x and state.y == next_y) return .quiet;
            state.x = next_x;
            state.y = next_y;
            state.positioned = true;
            return .redraw;
        },
        .resize => |orig| {
            const next_w = std.math.clamp(orig.w + (x - orig.pointer_x), min_width, max_width);
            const next_h = std.math.clamp(orig.h + (y - orig.pointer_y), min_height, max_height);
            if (state.width == next_w and state.height == next_h) return .quiet;
            state.width = next_w;
            state.height = next_h;
            return .redraw;
        },
        .button => return .quiet,
        .none => {
            const next_hover: Hit = switch (over) {
                .reset => if (state.phase == .idle) .none else .reset,
                .play_pause, .skip, .close, .resize => over,
                .card, .none => .none,
            };
            if (state.hovered == next_hover) return .quiet;
            state.hovered = next_hover;
            return .redraw;
        },
    }
}

fn handlePress(state: *State, target: Hit, x: f32, y: f32) Outcome {
    if (!state.visible) return .quiet;
    switch (target) {
        .card => {
            state.capture = .{ .move = .{
                .pointer_x = x,
                .pointer_y = y,
                .x = state.x,
                .y = state.y,
                .w = state.width,
                .h = state.height,
            } };
            return .quiet;
        },
        .resize => {
            state.capture = .{ .resize = .{
                .pointer_x = x,
                .pointer_y = y,
                .x = state.x,
                .y = state.y,
                .w = state.width,
                .h = state.height,
            } };
            state.hovered = .resize;
            return .redraw;
        },
        .reset => {
            if (state.phase == .idle) return .quiet;
            state.capture = .{ .button = .reset };
            state.hovered = .reset;
            return .redraw;
        },
        .play_pause, .skip, .close => {
            state.capture = .{ .button = target };
            state.hovered = target;
            return .redraw;
        },
        .none => return .quiet,
    }
}

fn handleRelease(state: *State, over: Hit) Outcome {
    const cap = state.capture;
    state.capture = .none;
    switch (cap) {
        .none => return .quiet,
        .move, .resize => {
            state.hovered = switch (over) {
                .play_pause, .skip, .close, .resize => over,
                .reset => if (state.phase == .idle) .none else .reset,
                .card, .none => .none,
            };
            return .redraw;
        },
        .button => |target| {
            state.hovered = if (over == target) target else .none;
            if (over != target) return .redraw;
            return switch (target) {
                .play_pause => .{ .action = .toggle },
                .skip => .{ .action = .skip },
                .reset => .{ .action = .reset },
                .close => .{ .action = .close },
                else => .redraw,
            };
        },
    }
}

/// Most nodes one view writes: card + header + spacer + close + body +
/// clock column + controls row + 2 buttons + ring square + 2 arcs +
/// overlay + play/pause + resize overlay + grip + 2 ticks.
pub const node_max: usize = 36 + 3 * button.node_max;
pub const line_max: usize = 4;

/// Writes the floating widget into `tree`, or returns null when hidden.
pub fn view(state: *const State, tree: *Tree, theme: *const Theme) tree_zig.Error!?Index {
    if (!state.visible) return null;

    const compact = state.width < compact_width or state.height < compact_height;
    const w = std.math.clamp(state.width, min_width, max_width);
    const h = std.math.clamp(state.height, min_height, max_height);

    const card = try tree.open(.{
        .id = card_id,
        .axis = if (compact) .row else .column,
        .width = .{ .fixed = w },
        .height = .{ .fixed = h },
        .padding = .all(if (compact) 10 else 14),
        .gap = if (compact) 8 else 6,
        .cross = if (compact) .center else .start,
        .overflow = .clip,
        .fill = theme.popover,
        .border = theme.border,
        .border_width = Theme.border_width,
        .radius = Theme.radius + 4,
    });

    if (compact) {
        try viewCompact(state, tree, theme, w);
    } else {
        try viewCard(state, tree, theme, h);
    }

    try viewResizeGrip(state, tree, theme);
    tree.close(card);
    return card;
}

fn viewCompact(state: *const State, tree: *Tree, theme: *const Theme, card_w: f32) tree_zig.Error!void {
    try viewRingButton(state, tree, theme, 32, 3.5, Theme.icon);
    const label_col = try tree.open(.{ .width = .fill, .gap = 0, .cross = .start });
    _ = try tree.text(state.timeText(), .{
        .color = theme.foreground,
        .style = .sm_medium,
        .figures = .tabular,
    });
    if (card_w >= 200) {
        _ = try tree.text(phaseLabel(state.phase, state.run), .{
            .color = theme.muted_foreground,
            .style = .xs,
        });
    }
    tree.close(label_col);

    try button.view(tree, theme, .{
        .id = close_id,
        .label = "",
        .icon = icons.x,
        .variant = .ghost,
        .size = .sm,
        .state = buttonState(state, .close),
    });
}

fn viewCard(state: *const State, tree: *Tree, theme: *const Theme, card_h: f32) tree_zig.Error!void {
    const header = try tree.open(.{
        .axis = .row,
        .width = .fill,
        .cross = .center,
        .gap = 6,
    });
    _ = try tree.text(phaseLabel(state.phase, state.run), .{
        .color = theme.muted_foreground,
        .style = .xs,
    });
    _ = try tree.leaf(.{ .width = .fill, .height = .{ .fixed = 1 } });
    try button.view(tree, theme, .{
        .id = close_id,
        .label = "",
        .icon = icons.x,
        .variant = .ghost,
        .size = .sm,
        .state = buttonState(state, .close),
    });
    tree.close(header);

    const body = try tree.open(.{
        .axis = .row,
        .width = .fill,
        .height = .fill,
        .gap = 12,
        .cross = .center,
    });

    const left = try tree.open(.{
        .width = .fill,
        .height = .fill,
        .main = .center,
        .gap = 8,
    });
    _ = try tree.text(state.timeText(), .{
        .color = theme.foreground,
        .style = .xl_semibold,
        .figures = .tabular,
    });
    const controls = try tree.open(.{
        .axis = .row,
        .gap = 6,
        .cross = .center,
    });
    try button.view(tree, theme, .{
        .id = reset_id,
        .label = "Stop",
        .variant = .outline,
        .size = .sm,
        .state = if (state.phase == .idle) .disabled else buttonState(state, .reset),
    });
    try button.view(tree, theme, .{
        .id = skip_id,
        .label = "",
        .icon = icons.skip_forward,
        .variant = .ghost,
        .size = .sm,
        .state = buttonState(state, .skip),
    });
    tree.close(controls);
    tree.close(left);

    const dial_side = std.math.clamp(card_h - 62, 54, 92);
    try viewRingButton(state, tree, theme, dial_side, 5.5, Theme.icon);

    tree.close(body);
}

fn viewRingButton(state: *const State, tree: *Tree, theme: *const Theme, side: f32, thickness: f32, icon_size: u8) tree_zig.Error!void {
    const radius = side / 2;
    const dial = try tree.open(.{
        .width = .{ .fixed = side },
        .height = .{ .fixed = side },
    });
    _ = try tree.arc(.{
        .radius = radius,
        .thickness = thickness,
        .sweep = turn,
        .fill = theme.muted,
    }, .{ .overlay = true, .width = .fill, .height = .fill });
    if (state.fraction > 0) {
        _ = try tree.arc(.{
            .radius = radius,
            .thickness = thickness,
            .sweep = state.fraction * turn,
            .fill = progressColor(theme, state.phase, state.run),
            .caps = .round,
        }, .{ .overlay = true, .width = .fill, .height = .fill });
    }
    const center = try tree.open(.{
        .overlay = true,
        .width = .fill,
        .height = .fill,
        .main = .center,
        .cross = .center,
    });
    const btn_side = @max(22, side - thickness * 2 - 4);
    const btn_state = buttonState(state, .play_pause);
    const center_fill: Color = switch (btn_state) {
        .pressed => theme.secondary,
        .hovered => theme.accent,
        else => theme.background.alpha(75),
    };
    const play_box = try tree.open(.{
        .id = play_pause_id,
        .width = .{ .fixed = btn_side },
        .height = .{ .fixed = btn_side },
        .main = .center,
        .cross = .center,
        .fill = center_fill,
        .radius = @intFromFloat(@ceil(btn_side / 2)),
        .pointer = .hand,
    });
    _ = try tree.icon(.{
        .codepoint = if (state.run == .running) icons.pause else icons.play,
        .color = theme.foreground,
        .size = icon_size,
    });
    tree.close(play_box);
    tree.close(center);
    tree.close(dial);
}

fn viewResizeGrip(state: *const State, tree: *Tree, theme: *const Theme) tree_zig.Error!void {
    const corner = try tree.open(.{
        .overlay = true,
        .width = .fill,
        .height = .fill,
        .main = .end,
        .cross = .end,
    });
    const grip = try tree.open(.{
        .id = resize_id,
        .width = .{ .fixed = resize_grip_size },
        .height = .{ .fixed = resize_grip_size },
        .main = .end,
        .cross = .end,
        .padding = .{ .right = 3, .bottom = 3 },
        .pointer = .hand,
    });
    const is_active = state.hovered == .resize or switch (state.capture) {
        .resize => true,
        else => false,
    };
    _ = try tree.leaf(.{
        .width = .{ .fixed = 6 },
        .height = .{ .fixed = 6 },
        .fill = if (is_active) theme.foreground else theme.muted_foreground.alpha(65),
        .radius = 2,
    });
    tree.close(grip);
    tree.close(corner);
}

/// Translates the widget to its clamped `(x, y)` viewport coordinates after layout.
/// When never dragged, defaults cleanly into the top-right corner.
pub fn place(state: *State, tree: *Tree, root: ?Index, viewport_w: f32, viewport_h: f32) void {
    const idx = root orelse return;
    const rect = tree.nodes[idx].rect;
    if (!state.positioned) {
        state.x = @max(edge_margin, viewport_w - edge_margin - rect.w);
        state.y = edge_margin;
    }
    const max_x = @max(min_clamp_margin, viewport_w - min_clamp_margin - rect.w);
    const max_y = @max(min_clamp_margin, viewport_h - min_clamp_margin - rect.h);
    state.x = std.math.clamp(state.x, min_clamp_margin, max_x);
    state.y = std.math.clamp(state.y, min_clamp_margin, max_y);
    tree.translate(idx, state.x - rect.x, state.y - rect.y);
}

fn buttonState(state: *const State, target: Hit) button.State {
    switch (state.capture) {
        .button => |b| if (b == target) return .pressed,
        else => {},
    }
    return if (state.hovered == target) .hovered else .normal;
}

fn phaseLabel(phase: Phase, run: Run) []const u8 {
    return switch (phase) {
        .idle => "Focus timer",
        .task => switch (run) {
            .running => "Focus",
            .paused => "Focus · Paused",
            .waiting => "Focus · Ready",
        },
        .short_break => switch (run) {
            .running => "Short break",
            .paused => "Break · Paused",
            .waiting => "Short break · Ready",
        },
        .long_break => switch (run) {
            .running => "Long break",
            .paused => "Break · Paused",
            .waiting => "Long break · Ready",
        },
    };
}

fn progressColor(theme: *const Theme, phase: Phase, run: Run) Color {
    if (run == .waiting) return theme.muted_foreground;
    return switch (phase) {
        .short_break, .long_break => theme.success,
        .task, .idle => theme.info,
    };
}

fn formatSeconds(buf: *[16]u8, total_s: u64) u8 {
    const minutes: u64 = (total_s / 60) % 60;
    const seconds: u64 = total_s % 60;
    const hours: u64 = total_s / 3600;
    const written = if (hours > 0)
        std.fmt.bufPrint(buf, "{d}:{d:0>2}:{d:0>2}", .{ hours, minutes, seconds })
    else
        std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}", .{ minutes, seconds });
    if (written) |slice| return @intCast(slice.len) else |_| {
        @memcpy(buf[0..5], "00:00");
        return 5;
    }
}

fn clamp01(value: f32) f32 {
    if (!std.math.isFinite(value)) return 0;
    return @min(1, @max(0, value));
}
