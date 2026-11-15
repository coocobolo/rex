//! Toggleable, draggable and resizable floating wellbeing focus widget for the
//! terminal overlay (`KitOverlay`, ADR 0010).
//!
//! `State` is plain data, `update` is the only code that changes it, `view`
//! builds responsive nodes into a `Tree` for the current `(width, height)` and
//! viewport bounds, and `place` translates and clamps it into view. Nothing
//! allocates.

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

pub const min_width: f32 = 164;
pub const max_width: f32 = 440;
pub const min_height: f32 = 48;
pub const max_height: f32 = 240;
pub const default_width: f32 = 312;
pub const default_height: f32 = 152;

const bar_min_width: f32 = 256;
const card_min_height: f32 = 136;
const portrait_min_height: f32 = 152;
const expanded_min_width: f32 = 348;
const expanded_min_height: f32 = 186;

const edge_margin: f32 = 16;
const min_clamp_margin: f32 = 4;
const resize_corner_size: f32 = 20;
const resize_edge_band: f32 = 7;
const turn = std.math.tau;

pub const card_id = Id.of("wellbeing_widget.card");
pub const play_pause_id = Id.of("wellbeing_widget.play_pause");
pub const skip_id = Id.of("wellbeing_widget.skip");
pub const reset_id = Id.of("wellbeing_widget.reset");
pub const close_id = Id.of("wellbeing_widget.close");
pub const resize_id = Id.of("wellbeing_widget.resize");
pub const resize_w_id = Id.of("wellbeing_widget.resize_w");
pub const resize_h_id = Id.of("wellbeing_widget.resize_h");

pub const Phase = enum(u8) { idle, task, short_break, long_break };
pub const Run = enum(u8) { paused, running, waiting };
pub const Mode = enum(u8) { mini, bar, portrait, card, expanded };

pub const Hit = enum(u8) {
    none,
    card,
    play_pause,
    skip,
    reset,
    close,
    resize,
    resize_w,
    resize_h,
};

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
    resize_w: DragOrigin,
    resize_h: DragOrigin,
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
    cycle_len: u8 = 3,
    time_buf: [16]u8 = .{ '0', '0', ':', '0', '0', 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    cycle_buf: [8]u8 = .{ '1', '/', '4', 0, 0, 0, 0, 0 },

    pub const empty: State = .{};

    pub fn timeText(self: *const State) []const u8 {
        return self.time_buf[0..self.time_len];
    }

    pub fn cycleText(self: *const State) []const u8 {
        return self.cycle_buf[0..self.cycle_len];
    }

    pub fn holdsPress(self: *const State) bool {
        return self.capture != .none;
    }

    pub fn canReset(self: *const State) bool {
        return self.phase != .idle;
    }

    pub fn canSkip(self: *const State) bool {
        return self.phase != .idle;
    }

    pub fn hit(self: *const State, id: Id) Hit {
        if (!self.visible or id == .none) return .none;
        if (id == play_pause_id) return .play_pause;
        if (id == skip_id) return .skip;
        if (id == reset_id) return .reset;
        if (id == close_id) return .close;
        if (id == resize_id) return .resize;
        if (id == resize_w_id) return .resize_w;
        if (id == resize_h_id) return .resize_h;
        if (id == card_id) return .card;
        return .none;
    }

    /// Resolves the active responsive layout mode for `(viewport_w, viewport_h)`.
    pub fn effectiveSize(self: *const State, viewport_w: f32, viewport_h: f32) struct { w: f32, h: f32, mode: Mode } {
        const fit_w = @max(1, viewport_w - min_clamp_margin * 2);
        const fit_h = @max(1, viewport_h - min_clamp_margin * 2);
        const clamped_w = std.math.clamp(self.width, min_width, max_width);
        const clamped_h = std.math.clamp(self.height, min_height, max_height);
        const w = @max(@min(min_width, fit_w), @min(clamped_w, fit_w));
        const h = @max(@min(min_height, fit_h), @min(clamped_h, fit_h));
        return .{ .w = w, .h = h, .mode = classify(w, h) };
    }
};

/// Chooses the layout breakpoint from effective `(w, h)` bounds.
pub fn classify(w: f32, h: f32) Mode {
    if (h < card_min_height) return if (w >= bar_min_width) .bar else .mini;
    if (w < bar_min_width) return if (h >= portrait_min_height) .portrait else .mini;
    if (w >= expanded_min_width and h >= expanded_min_height) return .expanded;
    return .card;
}

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
    var cycle_buf: [8]u8 = undefined;
    const cycle_len = formatCycle(&cycle_buf, snap.phase, snap.tasks_in_cycle, snap.tasks_before_long_break);
    const clamped_frac = clamp01(snap.fraction);
    const quant_frac = @round(clamped_frac * 360) / 360;

    const changed = state.phase != snap.phase or
        state.run != snap.run or
        state.fraction != quant_frac or
        state.tasks_in_cycle != snap.tasks_in_cycle or
        state.tasks_before_long_break != snap.tasks_before_long_break or
        state.time_len != time_len or
        state.cycle_len != cycle_len or
        !std.mem.eql(u8, state.time_buf[0..state.time_len], time_buf[0..time_len]) or
        !std.mem.eql(u8, state.cycle_buf[0..state.cycle_len], cycle_buf[0..cycle_len]);

    state.phase = snap.phase;
    state.run = snap.run;
    state.fraction = quant_frac;
    state.tasks_in_cycle = snap.tasks_in_cycle;
    state.tasks_before_long_break = snap.tasks_before_long_break;
    state.time_len = time_len;
    state.cycle_len = cycle_len;
    @memcpy(state.time_buf[0..time_len], time_buf[0..time_len]);
    @memcpy(state.cycle_buf[0..cycle_len], cycle_buf[0..cycle_len]);
    return changed;
}

fn hoverTarget(state: *const State, over: Hit) Hit {
    return switch (over) {
        .reset => if (state.canReset()) .reset else .none,
        .skip => if (state.canSkip()) .skip else .none,
        .play_pause, .close, .resize, .resize_w, .resize_h => over,
        .card, .none => .none,
    };
}

fn handlePointer(state: *State, over: Hit, x: f32, y: f32) Outcome {
    if (!state.visible) return .quiet;
    switch (state.capture) {
        .move => |orig| {
            const next_x = orig.x + (x - orig.pointer_x);
            const next_y = orig.y + (y - orig.pointer_y);
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
        .resize_w => |orig| {
            const next_w = std.math.clamp(orig.w + (x - orig.pointer_x), min_width, max_width);
            if (state.width == next_w) return .quiet;
            state.width = next_w;
            return .redraw;
        },
        .resize_h => |orig| {
            const next_h = std.math.clamp(orig.h + (y - orig.pointer_y), min_height, max_height);
            if (state.height == next_h) return .quiet;
            state.height = next_h;
            return .redraw;
        },
        .button => return .quiet,
        .none => {
            const next_hover = hoverTarget(state, over);
            if (state.hovered == next_hover) return .quiet;
            state.hovered = next_hover;
            return .redraw;
        },
    }
}

fn handlePress(state: *State, target: Hit, x: f32, y: f32) Outcome {
    if (!state.visible) return .quiet;
    const orig: DragOrigin = .{
        .pointer_x = x,
        .pointer_y = y,
        .x = state.x,
        .y = state.y,
        .w = state.width,
        .h = state.height,
    };
    switch (target) {
        .card => {
            state.capture = .{ .move = orig };
            return .quiet;
        },
        .resize => {
            state.positioned = true;
            state.capture = .{ .resize = orig };
            state.hovered = .resize;
            return .redraw;
        },
        .resize_w => {
            state.positioned = true;
            state.capture = .{ .resize_w = orig };
            state.hovered = .resize_w;
            return .redraw;
        },
        .resize_h => {
            state.positioned = true;
            state.capture = .{ .resize_h = orig };
            state.hovered = .resize_h;
            return .redraw;
        },
        .reset => {
            if (!state.canReset()) return .quiet;
            state.capture = .{ .button = .reset };
            state.hovered = .reset;
            return .redraw;
        },
        .skip => {
            if (!state.canSkip()) return .quiet;
            state.capture = .{ .button = .skip };
            state.hovered = .skip;
            return .redraw;
        },
        .play_pause, .close => {
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
        .move, .resize, .resize_w, .resize_h => {
            state.hovered = hoverTarget(state, over);
            return .redraw;
        },
        .button => |target| {
            state.hovered = if (over == target) hoverTarget(state, target) else .none;
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

/// Worst-case nodes written by one `view` call: card + padded surface +
/// header/badge/controls/dial + 3 buttons + 3 resize overlay zones.
pub const node_max: usize = 36 + 3 * button.node_max;
pub const line_max: usize = 6;

/// Writes the floating widget into `tree` adapted to `(viewport_w, viewport_h)`,
/// or returns null when hidden.
pub fn view(
    state: *const State,
    tree: *Tree,
    theme: *const Theme,
    viewport_w: f32,
    viewport_h: f32,
) tree_zig.Error!?Index {
    if (!state.visible) return null;

    const eff = state.effectiveSize(viewport_w, viewport_h);
    const resizing = switch (state.capture) {
        .resize, .resize_w, .resize_h => true,
        else => false,
    };
    const radius: u8 = if (eff.mode == .mini and eff.h <= 56) 14 else Theme.radius + 4;

    const card = try tree.open(.{
        .id = card_id,
        .axis = .column,
        .width = .{ .fixed = eff.w },
        .height = .{ .fixed = eff.h },
        .overflow = .clip,
        .fill = theme.popover,
        .border = if (resizing) theme.info.alpha(65) else theme.border,
        .border_width = Theme.border_width,
        .radius = radius,
    });

    switch (eff.mode) {
        .mini => try viewMini(state, tree, theme, eff.w, eff.h),
        .bar => try viewBar(state, tree, theme, eff.w, eff.h),
        .portrait => try viewPortrait(state, tree, theme, eff.w, eff.h),
        .card => try viewCard(state, tree, theme, eff.w, eff.h, false),
        .expanded => try viewCard(state, tree, theme, eff.w, eff.h, true),
    }

    try viewResizeHandles(state, tree, theme, eff.h);
    tree.close(card);
    return card;
}

fn viewMini(state: *const State, tree: *Tree, theme: *const Theme, w: f32, h: f32) tree_zig.Error!void {
    const vpad: u8 = if (h >= 72) 6 else 5;
    const surface = try tree.open(.{
        .axis = .row,
        .width = .fill,
        .height = .fill,
        .padding = .{ .left = 10, .right = 16, .top = vpad, .bottom = vpad },
        .gap = 6,
        .cross = .center,
    });

    const ring_side = std.math.clamp(h - 14, 30, 52);
    const thick: f32 = if (ring_side <= 38) 3.5 else 4.5;
    try viewRingButton(state, tree, theme, ring_side, thick);

    const col = try tree.open(.{ .width = .fill, .gap = 1, .cross = .start });
    const time_style: text.Style = if (h >= 84 and w >= 190)
        .xl_semibold
    else if (w >= 176)
        .lg_semibold
    else
        .sm_medium;
    _ = try tree.text(state.timeText(), .{
        .color = theme.foreground,
        .style = time_style,
        .figures = .tabular,
    });
    if (h >= 72 and w >= 186) {
        _ = try tree.text(phaseShortLabel(state.phase, state.run), .{
            .color = phaseSubtextColor(theme, state.phase, state.run),
            .style = .xs,
        });
    }
    tree.close(col);

    try button.view(tree, theme, .{
        .id = close_id,
        .label = "",
        .icon = icons.x,
        .variant = .ghost,
        .size = .sm,
        .state = buttonState(state, .close),
    });

    tree.close(surface);
}

fn viewBar(state: *const State, tree: *Tree, theme: *const Theme, w: f32, h: f32) tree_zig.Error!void {
    const vpad: u8 = if (h >= 72) 8 else 5;
    const surface = try tree.open(.{
        .axis = .row,
        .width = .fill,
        .height = .fill,
        .padding = .{ .left = 12, .right = 16, .top = vpad, .bottom = vpad },
        .gap = if (w >= 320) 12 else 8,
        .cross = .center,
    });

    const ring_side = std.math.clamp(h - 16, 32, 72);
    const thick: f32 = if (ring_side >= 52) 5 else 4;
    try viewRingButton(state, tree, theme, ring_side, thick);

    const col = try tree.open(.{ .width = .fill, .gap = 2, .cross = .start });
    _ = try tree.text(state.timeText(), .{
        .color = theme.foreground,
        .style = if (h >= 84) .xl_semibold else .lg_semibold,
        .figures = .tabular,
    });
    if (h >= 68) {
        const meta = try tree.open(.{ .axis = .row, .cross = .center, .gap = 6 });
        try viewPhaseBadge(state, tree, theme, false);
        if (state.phase != .idle and state.cycle_len > 0 and w >= 300) {
            _ = try tree.text(state.cycleText(), .{
                .color = theme.muted_foreground,
                .style = .xs,
                .figures = .tabular,
            });
        }
        tree.close(meta);
    }
    tree.close(col);

    const actions = try tree.open(.{ .axis = .row, .cross = .center, .gap = 6 });
    if (w >= 344) {
        try button.view(tree, theme, .{
            .id = reset_id,
            .label = "",
            .icon = icons.rotate_ccw,
            .variant = .outline,
            .size = .sm,
            .state = if (state.canReset()) buttonState(state, .reset) else .disabled,
        });
    }
    if (w >= 292) {
        try button.view(tree, theme, .{
            .id = skip_id,
            .label = "",
            .icon = icons.skip_forward,
            .variant = .outline,
            .size = .sm,
            .state = if (state.canSkip()) buttonState(state, .skip) else .disabled,
        });
    }
    try button.view(tree, theme, .{
        .id = close_id,
        .label = "",
        .icon = icons.x,
        .variant = .ghost,
        .size = .sm,
        .state = buttonState(state, .close),
    });
    tree.close(actions);

    tree.close(surface);
}

fn viewPortrait(state: *const State, tree: *Tree, theme: *const Theme, w: f32, h: f32) tree_zig.Error!void {
    const surface = try tree.open(.{
        .axis = .column,
        .width = .fill,
        .height = .fill,
        .padding = .{ .left = 12, .right = 12, .top = 10, .bottom = 12 },
        .gap = 6,
        .cross = .center,
    });

    const header = try tree.open(.{
        .axis = .row,
        .width = .fill,
        .cross = .center,
        .gap = 6,
    });
    try viewPhaseBadge(state, tree, theme, false);
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

    const show_controls = h >= 196;
    const dial_max_h = h - @as(f32, if (show_controls) 148 else 108);
    const ring_side = std.math.clamp(@min(w - 56, dial_max_h), 42, 74);
    const tile_side = ring_side + 16;

    const tile_wrap = try tree.open(.{
        .width = .fill,
        .height = .fill,
        .main = .center,
        .cross = .center,
    });
    const tile = try tree.open(.{
        .width = .{ .fixed = tile_side },
        .height = .{ .fixed = tile_side },
        .main = .center,
        .cross = .center,
        .fill = dialTileFill(theme, state.phase, state.run),
        .radius = Theme.radius + 2,
    });
    try viewRingButton(state, tree, theme, ring_side, 5);
    tree.close(tile);
    tree.close(tile_wrap);

    _ = try tree.text(state.timeText(), .{
        .color = theme.foreground,
        .style = if (w >= 200) .xl_semibold else .lg_semibold,
        .figures = .tabular,
    });

    if (show_controls) {
        const controls = try tree.open(.{ .axis = .row, .gap = 6, .cross = .center });
        try button.view(tree, theme, .{
            .id = reset_id,
            .label = if (w >= 210) "Stop" else "",
            .icon = if (w >= 210) icons.none else icons.rotate_ccw,
            .variant = .outline,
            .size = .sm,
            .state = if (state.canReset()) buttonState(state, .reset) else .disabled,
        });
        try button.view(tree, theme, .{
            .id = skip_id,
            .label = "",
            .icon = icons.skip_forward,
            .variant = .outline,
            .size = .sm,
            .state = if (state.canSkip()) buttonState(state, .skip) else .disabled,
        });
        tree.close(controls);
    }

    tree.close(surface);
}

fn viewCard(state: *const State, tree: *Tree, theme: *const Theme, w: f32, h: f32, expanded: bool) tree_zig.Error!void {
    const surface = try tree.open(.{
        .axis = .column,
        .width = .fill,
        .height = .fill,
        .padding = if (expanded)
            .{ .left = 16, .right = 14, .top = 12, .bottom = 14 }
        else
            .{ .left = 14, .right = 12, .top = 10, .bottom = 12 },
        .gap = if (expanded) 8 else 6,
    });

    const header = try tree.open(.{
        .axis = .row,
        .width = .fill,
        .cross = .center,
        .gap = 8,
    });
    try viewPhaseBadge(state, tree, theme, expanded);
    if (state.phase != .idle and state.cycle_len > 0) {
        _ = try tree.text(state.cycleText(), .{
            .color = theme.muted_foreground,
            .style = if (expanded) .sm else .xs,
            .figures = .tabular,
        });
    }
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
        .gap = if (expanded) 16 else 12,
        .cross = .center,
    });

    const left_gap: u8 = if (expanded) 10 else if (h >= 148) 8 else 4;
    const left = try tree.open(.{
        .width = .fill,
        .height = .fill,
        .main = .center,
        .cross = .start,
        .gap = left_gap,
    });
    const time_style: text.Style = if (expanded and (state.timeText().len <= 5 or w >= 408))
        .xxl_semibold
    else if (expanded or h >= 144)
        .xl_semibold
    else
        .lg_semibold;
    _ = try tree.text(state.timeText(), .{
        .color = theme.foreground,
        .style = time_style,
        .figures = .tabular,
    });

    const controls = try tree.open(.{
        .axis = .row,
        .gap = if (expanded) 8 else 6,
        .cross = .center,
    });
    try button.view(tree, theme, .{
        .id = reset_id,
        .label = "Stop",
        .icon = if (expanded) icons.rotate_ccw else icons.none,
        .variant = .outline,
        .size = .sm,
        .state = if (state.canReset()) buttonState(state, .reset) else .disabled,
    });
    try button.view(tree, theme, .{
        .id = skip_id,
        .label = if (expanded or w >= 324) "Skip" else "",
        .icon = icons.skip_forward,
        .variant = .outline,
        .size = .sm,
        .state = if (state.canSkip()) buttonState(state, .skip) else .disabled,
    });
    tree.close(controls);
    tree.close(left);

    const tile_side = if (expanded)
        std.math.clamp(@min(h - 76, w * 0.34), 104, 152)
    else
        std.math.clamp(h - 68, 60, 108);
    const tile = try tree.open(.{
        .width = .{ .fixed = tile_side },
        .height = .{ .fixed = tile_side },
        .main = .center,
        .cross = .center,
        .fill = dialTileFill(theme, state.phase, state.run),
        .radius = Theme.radius + 2,
    });
    const ring_side = tile_side - if (expanded) @as(f32, 20) else @as(f32, 14);
    const thick: f32 = if (expanded) 6.5 else 5.5;
    try viewRingButton(state, tree, theme, ring_side, thick);
    tree.close(tile);

    tree.close(body);
    tree.close(surface);
}

fn viewPhaseBadge(state: *const State, tree: *Tree, theme: *const Theme, large: bool) tree_zig.Error!void {
    const pad: tree_zig.Edges = if (large) .symmetric(10, 3) else .symmetric(8, 2);
    const pill = try tree.open(.{
        .width = .fit,
        .padding = pad,
        .cross = .center,
        .main = .center,
        .fill = phaseBadgeFill(theme, state.phase, state.run),
        .radius = Theme.radius_sm,
    });
    _ = try tree.text(phaseShortLabel(state.phase, state.run), .{
        .color = phaseSubtextColor(theme, state.phase, state.run),
        .style = if (large) .sm_medium else .xs,
    });
    tree.close(pill);
}

fn viewRingButton(state: *const State, tree: *Tree, theme: *const Theme, side: f32, thickness: f32) tree_zig.Error!void {
    const radius = side / 2;
    const dial = try tree.open(.{
        .width = .{ .fixed = side },
        .height = .{ .fixed = side },
    });
    _ = try tree.arc(.{
        .radius = radius,
        .thickness = thickness,
        .sweep = turn,
        .fill = trackColor(theme, state.phase, state.run),
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
        else => theme.background,
    };
    const icon_size: u8 = if (btn_side < 30) 12 else if (btn_side >= 58) 20 else Theme.icon;
    const play_box = try tree.open(.{
        .id = play_pause_id,
        .width = .{ .fixed = btn_side },
        .height = .{ .fixed = btn_side },
        .main = .center,
        .cross = .center,
        .fill = center_fill,
        .border = theme.border,
        .border_width = Theme.border_width,
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

fn viewResizeHandles(state: *const State, tree: *Tree, theme: *const Theme, card_h: f32) tree_zig.Error!void {
    const right_active = state.hovered == .resize_w or switch (state.capture) {
        .resize_w => true,
        else => false,
    };
    const right_wrap = try tree.open(.{
        .overlay = true,
        .axis = .row,
        .width = .fill,
        .height = .fill,
        .main = .end,
        .cross = .center,
    });
    const right_hit = try tree.open(.{
        .id = resize_w_id,
        .width = .{ .fixed = resize_edge_band },
        .height = .fill,
        .main = .center,
        .cross = .center,
        .pointer = .hand,
    });
    _ = try tree.leaf(.{
        .width = .{ .fixed = 2 },
        .height = .{ .fixed = 22 },
        .fill = if (right_active) theme.info else Color.transparent,
        .radius = 1,
    });
    tree.close(right_hit);
    tree.close(right_wrap);

    const bottom_active = state.hovered == .resize_h or switch (state.capture) {
        .resize_h => true,
        else => false,
    };
    const bottom_wrap = try tree.open(.{
        .overlay = true,
        .axis = .column,
        .width = .fill,
        .height = .fill,
        .main = .end,
        .cross = .center,
    });
    const bottom_hit = try tree.open(.{
        .id = resize_h_id,
        .width = .fill,
        .height = .{ .fixed = resize_edge_band },
        .main = .center,
        .cross = .center,
        .pointer = .hand,
    });
    _ = try tree.leaf(.{
        .width = .{ .fixed = 22 },
        .height = .{ .fixed = 2 },
        .fill = if (bottom_active) theme.info else Color.transparent,
        .radius = 1,
    });
    tree.close(bottom_hit);
    tree.close(bottom_wrap);

    const corner_active = state.hovered == .resize or switch (state.capture) {
        .resize => true,
        else => false,
    };
    const grip_color = if (corner_active) theme.info else theme.muted_foreground.alpha(55);
    const corner = try tree.open(.{
        .overlay = true,
        .width = .fill,
        .height = .fill,
        .main = .end,
        .cross = .end,
    });
    const corner_side: f32 = if (card_h < 80) 14 else resize_corner_size;
    const grip_pad: u8 = if (card_h < 80) 6 else 7;
    const grip = try tree.open(.{
        .id = resize_id,
        .width = .{ .fixed = corner_side },
        .height = .{ .fixed = corner_side },
        .main = .end,
        .cross = .end,
        .padding = .{ .right = grip_pad, .bottom = grip_pad },
        .pointer = .hand,
    });
    const corner_mark = try tree.open(.{
        .axis = .row,
        .cross = .end,
        .gap = 0,
    });
    _ = try tree.leaf(.{
        .width = .{ .fixed = 5 },
        .height = .{ .fixed = 2 },
        .fill = grip_color,
        .radius = 1,
    });
    _ = try tree.leaf(.{
        .width = .{ .fixed = 2 },
        .height = .{ .fixed = 7 },
        .fill = grip_color,
        .radius = 1,
    });
    tree.close(corner_mark);
    tree.close(grip);
    tree.close(corner);
}

/// Translates the widget to its clamped `(x, y)` viewport coordinates after layout.
/// When never dragged or resized, defaults cleanly into the top-right corner.
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

fn phaseShortLabel(phase: Phase, run: Run) []const u8 {
    return switch (phase) {
        .idle => "Focus timer",
        .task => switch (run) {
            .running => "Focus",
            .paused => "Paused",
            .waiting => "Focus ready",
        },
        .short_break => switch (run) {
            .running => "Short break",
            .paused => "Break paused",
            .waiting => "Break ready",
        },
        .long_break => switch (run) {
            .running => "Long break",
            .paused => "Break paused",
            .waiting => "Long break",
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

fn phaseBadgeFill(theme: *const Theme, phase: Phase, run: Run) Color {
    if (phase == .idle or run != .running) return theme.muted;
    return switch (phase) {
        .task => theme.info.alpha(16),
        .short_break, .long_break => theme.success.alpha(16),
        .idle => theme.muted,
    };
}

fn phaseSubtextColor(theme: *const Theme, phase: Phase, run: Run) Color {
    if (phase == .idle) return theme.muted_foreground;
    if (run != .running) return theme.muted_foreground;
    return switch (phase) {
        .task => theme.info_text,
        .short_break, .long_break => theme.success,
        .idle => theme.muted_foreground,
    };
}

fn dialTileFill(theme: *const Theme, phase: Phase, run: Run) Color {
    if (phase == .idle or run != .running) return theme.muted.alpha(50);
    return switch (phase) {
        .task => theme.info.alpha(14),
        .short_break, .long_break => theme.success.alpha(14),
        .idle => theme.muted.alpha(50),
    };
}

fn trackColor(theme: *const Theme, phase: Phase, run: Run) Color {
    if (phase != .idle and run == .running) {
        return switch (phase) {
            .task => theme.info.alpha(24),
            .short_break, .long_break => theme.success.alpha(24),
            .idle => theme.foreground.alpha(14),
        };
    }
    return theme.foreground.alpha(14);
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

fn formatCycle(buf: *[8]u8, phase: Phase, tasks_in_cycle: u8, tasks_before_long_break: u8) u8 {
    if (phase == .idle or tasks_before_long_break == 0) return 0;
    const total = tasks_before_long_break;
    const current = switch (phase) {
        .idle => unreachable,
        .task => @min(tasks_in_cycle + 1, total),
        .short_break => @min(tasks_in_cycle, total),
        .long_break => total,
    };
    const written = std.fmt.bufPrint(buf, "{d}/{d}", .{ current, total });
    if (written) |slice| return @intCast(slice.len) else |_| return 0;
}

fn clamp01(value: f32) f32 {
    if (!std.math.isFinite(value)) return 0;
    return @min(1, @max(0, value));
}
