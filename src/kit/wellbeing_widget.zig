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
const badge = @import("badge.zig");
const button = @import("button.zig");
const chart = @import("chart.zig");
const icons = @import("icons.zig");
const layout = @import("layout.zig");
const text = @import("text.zig");
const tooltip = @import("tooltip.zig");
const Tree = @import("Tree.zig");
const Id = Tree.Id;
const Index = Tree.Index;

pub const min_width: f32 = 96;
pub const max_width: f32 = 320;
pub const min_height: f32 = 72;
pub const max_height: f32 = 160;
pub const default_width: f32 = 264;
pub const default_height: f32 = 132;

const min_square: f32 = 96;
const max_square: f32 = 160;

const min_horizontal_h: f32 = 72;
const normal_horizontal_min_h: f32 = 120;
const max_horizontal_h: f32 = 160;
const horizontal_aspect_threshold: f32 = 1.45;

const edge_margin: f32 = 16;
const min_clamp_margin: f32 = 4;
const resize_corner_size: f32 = 18;
const turn = std.math.tau;

pub const card_id = Id.of("wellbeing_widget.card");
pub const play_pause_id = Id.of("wellbeing_widget.play_pause");
pub const skip_id = Id.of("wellbeing_widget.skip");
pub const reset_id = Id.of("wellbeing_widget.reset");
pub const swap_id = Id.of("wellbeing_widget.swap");
pub const resize_id = Id.of("wellbeing_widget.resize");

pub const Phase = enum(u8) { idle, task, short_break, long_break };
pub const Run = enum(u8) { paused, running, waiting };
pub const Grid = enum(u8) { square, horizontal };
pub const Mode = enum(u8) { mini, normal };

/// Focus progress visual style for the floating widget.
/// `.auto` adapts between `mini` border-sweep and `normal` circular ring by card size.
pub const ProgressStyle = enum(u8) {
    auto,
    bar,
    ring,
    border,
    half_rings,
    coil,
};

/// User-configurable appearance and initial geometry options (`[wellbeing.widget]`).
pub const Option = struct {
    default_width: f32 = default_width,
    default_height: f32 = default_height,
    progress_style: ProgressStyle = .auto,
    anchor: Tree.ScreenAnchor = .bottom_right,
    tooltip: bool = true,
};

pub const Hit = enum(u8) {
    none,
    card,
    play_pause,
    skip,
    reset,
    swap,
    resize,
};

pub const Action = enum(u8) { toggle, skip, reset };

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
    play_pause: DragOrigin,
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
    option: Option = .{},
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
    resized: bool = false,
    pointer_inside: bool = false,
    swapped: bool = false,
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

    /// Returns whether the dial/half-ring container sits on the left side of the widget:
    /// dynamically tracks which half of `viewport_w` the widget sits in (or `option.anchor`
    /// before being dragged) and flips whenever the swap button is toggled.
    pub fn isDialOnLeft(self: *const State, viewport_w: f32) bool {
        const eff = self.effectiveSize(viewport_w, std.math.inf(f32));
        const natural_left = if (self.positioned and std.math.isFinite(viewport_w) and viewport_w > 0)
            (self.x + eff.w * 0.5) < (viewport_w * 0.5)
        else switch (self.option.anchor) {
            .top_left, .bottom_left => true,
            .top_center, .bottom_center, .top_right, .bottom_right => false,
        };
        return natural_left != self.swapped;
    }

    pub fn hit(self: *const State, id: Id) Hit {
        if (!self.visible or id == .none) return .none;
        if (id == play_pause_id) return .play_pause;
        if (id == skip_id) return .skip;
        if (id == reset_id) return .reset;
        if (id == swap_id) return .swap;
        if (id == resize_id) return .resize;
        if (id == card_id) return .card;
        return .none;
    }

    /// Resolves the active grid shape and density mode for `(viewport_w, viewport_h)`.
    pub fn effectiveSize(self: *const State, viewport_w: f32, viewport_h: f32) struct { w: f32, h: f32, grid: Grid, mode: Mode } {
        const fit_w = @max(1, viewport_w - min_clamp_margin * 2);
        const fit_h = @max(1, viewport_h - min_clamp_margin * 2);
        const use_default_w = !self.resized and self.width == default_width;
        const use_default_h = !self.resized and self.height == default_height;
        const target_w = if (use_default_w) self.option.default_width else self.width;
        const target_h = if (use_default_h) self.option.default_height else self.height;
        const clamped_w = std.math.clamp(target_w, min_width, max_width);
        const clamped_h = std.math.clamp(target_h, min_height, max_height);
        const w = @max(@min(min_width, fit_w), @min(clamped_w, fit_w));
        const h = @max(@min(min_height, fit_h), @min(clamped_h, fit_h));
        const classified = classify(w, h);
        return .{ .w = w, .h = h, .grid = classified.grid, .mode = classified.mode };
    }
};

/// Applies updated `[wellbeing.widget]` options and returns whether a visible widget needs a redraw.
pub fn configure(state: *State, option: Option) bool {
    const changed = !std.meta.eql(state.option, option);
    const size_changed = state.option.default_width != option.default_width or
        state.option.default_height != option.default_height;
    if (size_changed or !state.resized) {
        state.width = std.math.clamp(option.default_width, min_width, max_width);
        state.height = std.math.clamp(option.default_height, min_height, max_height);
        if (size_changed) state.resized = false;
    }
    if (state.option.anchor != option.anchor) {
        state.positioned = false;
        state.swapped = false;
    }
    state.option = option;
    return changed and state.visible;
}

/// Chooses the grid shape (`square` 1:1 or `horizontal` 2:1) and density (`mini` or `normal`).
pub fn classify(w: f32, h: f32) struct { grid: Grid, mode: Mode } {
    const grid: Grid = if (w >= h * horizontal_aspect_threshold) .horizontal else .square;
    const mode: Mode = switch (grid) {
        .square => .mini,
        .horizontal => if (w >= normal_horizontal_min_h * 2 and h >= normal_horizontal_min_h) .normal else .mini,
    };
    return .{ .grid = grid, .mode = mode };
}

/// Applies `event` and returns whether anything changed or an action fired.
pub fn update(state: *State, event: Event) Outcome {
    return switch (event) {
        .toggle_visible => {
            state.visible = !state.visible;
            if (!state.visible) {
                state.capture = .none;
                state.hovered = .none;
                state.pointer_inside = false;
            }
            return .redraw;
        },
        .hide => {
            if (!state.visible) return .quiet;
            state.visible = false;
            state.capture = .none;
            state.hovered = .none;
            state.pointer_inside = false;
            return .redraw;
        },
        .sync => |snap| if (syncSnapshot(state, snap)) .redraw else .quiet,
        .pointer => |pt| handlePointer(state, pt.over, pt.x, pt.y),
        .leave => {
            if (state.hovered == .none and !state.pointer_inside and state.capture == .none) return .quiet;
            state.hovered = .none;
            state.pointer_inside = false;
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
        .play_pause, .swap, .resize => over,
        .card, .none => .none,
    };
}

fn resizeBounds(raw_w: f32, raw_h: f32) struct { w: f32, h: f32 } {
    if (raw_w >= raw_h * horizontal_aspect_threshold) {
        // Project onto the 2:1 horizontal grid line between mini and normal bounds.
        const h = std.math.clamp(@round((raw_w * 2.0 + raw_h) / 5.0), min_horizontal_h, max_horizontal_h);
        return .{ .w = h * 2.0, .h = h };
    }
    const side = std.math.clamp(@round((raw_w + raw_h) * 0.5), min_square, max_square);
    return .{ .w = side, .h = side };
}

fn handlePointer(state: *State, over: Hit, x: f32, y: f32) Outcome {
    if (!state.visible) return .quiet;
    const inside = over != .none;
    switch (state.capture) {
        .move => |orig| {
            state.pointer_inside = inside;
            const next_x = orig.x + (x - orig.pointer_x);
            const next_y = orig.y + (y - orig.pointer_y);
            if (state.x == next_x and state.y == next_y) return .quiet;
            state.x = next_x;
            state.y = next_y;
            state.positioned = true;
            state.swapped = false;
            return .redraw;
        },
        .resize => |orig| {
            state.pointer_inside = inside;
            const raw_w = @max(1, orig.w + (x - orig.pointer_x));
            const raw_h = @max(1, orig.h + (y - orig.pointer_y));
            const next = resizeBounds(raw_w, raw_h);
            if (state.width == next.w and state.height == next.h) return .quiet;
            state.width = next.w;
            state.height = next.h;
            return .redraw;
        },
        .play_pause => |orig| {
            const dx = x - orig.pointer_x;
            const dy = y - orig.pointer_y;
            if (dx * dx + dy * dy <= 36) return .quiet;
            state.hovered = .none;
            state.pointer_inside = inside;
            state.capture = .{ .move = orig };
            state.x = orig.x + dx;
            state.y = orig.y + dy;
            state.positioned = true;
            state.swapped = false;
            return .redraw;
        },
        .button => return .quiet,
        .none => {
            const next_hover = hoverTarget(state, over);
            if (state.hovered == next_hover and state.pointer_inside == inside) return .quiet;
            state.hovered = next_hover;
            state.pointer_inside = inside;
            return .redraw;
        },
    }
}

fn handlePress(state: *State, target: Hit, x: f32, y: f32) Outcome {
    if (!state.visible) return .quiet;
    const eff = state.effectiveSize(std.math.inf(f32), std.math.inf(f32));
    const orig: DragOrigin = .{
        .pointer_x = x,
        .pointer_y = y,
        .x = state.x,
        .y = state.y,
        .w = eff.w,
        .h = eff.h,
    };
    switch (target) {
        .card => {
            state.capture = .{ .move = orig };
            return .quiet;
        },
        .resize => {
            state.positioned = true;
            state.resized = true;
            state.width = eff.w;
            state.height = eff.h;
            state.capture = .{ .resize = orig };
            state.hovered = .resize;
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
        .swap => {
            state.capture = .{ .button = .swap };
            state.hovered = .swap;
            return .redraw;
        },
        .play_pause => {
            state.capture = .{ .play_pause = orig };
            state.hovered = .play_pause;
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
            state.hovered = hoverTarget(state, over);
            return .redraw;
        },
        .play_pause => {
            state.hovered = if (over == .play_pause) .play_pause else .none;
            if (over != .play_pause) return .redraw;
            return .{ .action = .toggle };
        },
        .button => |target| {
            state.hovered = if (over == target) hoverTarget(state, target) else .none;
            if (over != target) return .redraw;
            return switch (target) {
                .skip => .{ .action = .skip },
                .reset => .{ .action = .reset },
                .swap => {
                    state.swapped = !state.swapped;
                    return .redraw;
                },
                else => .redraw,
            };
        },
    }
}

/// Worst-case nodes written by one `view` + `viewTooltip` call: card + padded
/// surface + normal grid content + 2 action buttons + corner resize handle + tooltip.
pub const node_max: usize = 32 + 2 * button.node_max + tooltip.nodes(1);
pub const line_max: usize = 6;

/// Writes the floating widget into `tree` adapted to `(viewport_w, viewport_h)`,
/// or returns null when hidden.
pub fn view(
    state: *const State,
    tree: *Tree,
    theme: *const Theme,
    viewport_w: f32,
    viewport_h: f32,
) Tree.Error!?Index {
    if (!state.visible) return null;

    const eff = state.effectiveSize(viewport_w, viewport_h);
    const focused = state.pointer_inside or state.hovered != .none or state.capture != .none;
    const outer_border = if (!focused)
        Color.transparent
    else if (state.capture == .resize)
        theme.ring.alpha(70)
    else
        theme.border;

    const card = try tree.open(.{
        .id = card_id,
        .axis = .column,
        .width = .{ .fixed = eff.w },
        .height = .{ .fixed = eff.h },
        .overflow = .clip,
        .fill = theme.popover,
        .border = outer_border,
        .border_width = Theme.border_width,
        .radius = Theme.radius + 4,
    });

    const on_left = state.isDialOnLeft(viewport_w);
    switch (eff.grid) {
        .square => try viewMini(state, tree, theme, .square, eff.w, eff.h, on_left),
        .horizontal => switch (eff.mode) {
            .mini => try viewMini(state, tree, theme, .horizontal, eff.w, eff.h, on_left),
            .normal => try viewHorizontalNormal(state, tree, theme, eff.w, eff.h, on_left),
        },
    }

    try viewResizeHandle(state, tree, theme);
    tree.close(card);
    return card;
}

fn viewMini(state: *const State, tree: *Tree, theme: *const Theme, grid: Grid, w: f32, h: f32, on_left: bool) Tree.Error!void {
    switch (state.option.progress_style) {
        .auto => try viewMiniBorder(state, tree, theme, grid, w, h, false),
        .border => try viewMiniBorder(state, tree, theme, grid, w, h, true),
        .bar => try viewMiniBar(state, tree, theme, grid, w, h),
        .ring => try viewMiniRing(state, tree, theme, w, h),
        .half_rings => try viewMiniHalfRings(state, tree, theme, grid, w, h, on_left),
        .coil => try viewMiniCoil(state, tree, theme, grid, w, h),
    }
}

fn viewMiniBorder(
    state: *const State,
    tree: *Tree,
    theme: *const Theme,
    grid: Grid,
    w: f32,
    h: f32,
    stadium_pill: bool,
) Tree.Error!void {
    const pad: u8 = if (w < 108 or h < 96) 3 else if (grid == .horizontal and h >= 96) 6 else 4;
    const surface = try tree.open(.{
        .axis = .column,
        .width = .fill,
        .height = .fill,
        .padding = .all(pad),
    });

    const box_state = buttonState(state, .play_pause);
    const tile_h = @max(1, h - @as(f32, @floatFromInt(pad * 2)));
    const radius: u8 = if (stadium_pill)
        chart.pillRadius(tile_h)
    else if (h < 96)
        Theme.radius
    else
        Theme.radius + 2;
    const border_w: u8 = if (grid == .square) (if (h >= 108) 4 else 3) else (if (h >= 96) 4 else 3);

    const tile = try chart.openBorderPill(tree, .{
        .id = play_pause_id,
        .width = .fill,
        .height = .fill,
        .pill_height = tile_h,
        .border_width = border_w,
        .radius = radius,
        .fill = progressBoxFill(theme, box_state),
        .track = progressTrackBorder(theme, box_state),
        .active = progressBorderColor(theme, state.phase, state.run, box_state),
        .fraction = if (state.phase == .idle) 0 else state.fraction,
        .pointer = .hand,
    });

    // Borders paint inside the tile bounds, so content padding includes `border_w` plus breathing room.
    const inner_pad_x: u8 = border_w + if (grid == .square) @as(u8, 6) else (if (h >= 96) @as(u8, 10) else @as(u8, 8));
    const inner_pad_y: u8 = border_w + if (grid == .square) (if (h >= 108) @as(u8, 4) else @as(u8, 6)) else (if (h >= 96) @as(u8, 6) else @as(u8, 4));
    const inner_w = @max(1, w - @as(f32, @floatFromInt(pad * 2 + inner_pad_x * 2)));
    const inner_h = @max(1, h - @as(f32, @floatFromInt(pad * 2 + inner_pad_y * 2)));
    const time_color = progressTimeColor(theme, state.phase, state.run, box_state);

    const content = try tree.open(.{
        .axis = .column,
        .width = .fill,
        .height = .fill,
        .main = .center,
        .cross = .center,
        .padding = .symmetric(inner_pad_x, inner_pad_y),
        .gap = 0,
    });
    try viewMiniTimeText(state, tree, time_color, grid, inner_w, inner_h, !stadium_pill);
    tree.close(content);
    tree.close(tile);
    tree.close(surface);
}

fn viewMiniBar(state: *const State, tree: *Tree, theme: *const Theme, grid: Grid, w: f32, h: f32) Tree.Error!void {
    const pad: u8 = if (w < 108 or h < 96) 4 else 6;
    const surface = try tree.open(.{
        .axis = .column,
        .width = .fill,
        .height = .fill,
        .padding = .all(pad),
    });
    const box_state = buttonState(state, .play_pause);
    const tile = try tree.open(.{
        .id = play_pause_id,
        .axis = .column,
        .width = .fill,
        .height = .fill,
        .main = .center,
        .cross = .center,
        .padding = .symmetric(10, 8),
        .gap = 8,
        .fill = progressBoxFill(theme, box_state),
        .border = tileBorder(theme, box_state),
        .border_width = Theme.border_width,
        .radius = Theme.radius + 2,
        .pointer = .hand,
    });
    const inner_w = @max(1, w - @as(f32, @floatFromInt(pad * 2 + 20)));
    const inner_h = @max(1, h - @as(f32, @floatFromInt(pad * 2 + 30)));
    const time_color = progressTimeColor(theme, state.phase, state.run, box_state);
    try viewMiniTimeText(state, tree, time_color, grid, inner_w, inner_h, false);
    try chart.progress(
        tree,
        theme,
        .bar,
        if (state.phase == .idle) 0 else state.fraction,
        progressColor(theme, state.phase, state.run),
        6,
    );
    tree.close(tile);
    tree.close(surface);
}

fn viewMiniRing(state: *const State, tree: *Tree, theme: *const Theme, w: f32, h: f32) Tree.Error!void {
    const pad: u8 = 4;
    const surface = try tree.open(.{
        .axis = .column,
        .width = .fill,
        .height = .fill,
        .padding = .all(pad),
    });
    const box_state = buttonState(state, .play_pause);
    const tile = try tree.open(.{
        .id = play_pause_id,
        .width = .fill,
        .height = .fill,
        .main = .center,
        .cross = .center,
        .fill = progressBoxFill(theme, box_state),
        .border = tileBorder(theme, box_state),
        .border_width = Theme.border_width,
        .radius = Theme.radius + 2,
        .pointer = .hand,
    });
    const side = @max(36, @min(w, h) - @as(f32, @floatFromInt(pad * 2 + 12)));
    const radius = side / 2;
    const thick: f32 = if (side >= 84) 6 else 5;
    const dial = try tree.open(.{
        .width = .{ .fixed = side },
        .height = .{ .fixed = side },
    });
    _ = try tree.arc(.{
        .radius = radius,
        .thickness = thick,
        .sweep = turn,
        .fill = trackColor(theme, state.phase, state.run),
    }, .{ .overlay = true, .width = .fill, .height = .fill });
    if (state.fraction > 0 and state.phase != .idle) {
        _ = try tree.arc(.{
            .radius = radius,
            .thickness = thick,
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
    const inner = @max(1, side - thick * 2 - 8);
    const time_color = progressTimeColor(theme, state.phase, state.run, box_state);
    _ = try tree.text(state.timeText(), .{
        .color = time_color,
        .style = fitTimerStyle(inner, inner, state.timeText().len, false),
        .figures = .tabular,
    });
    tree.close(center);
    tree.close(dial);
    tree.close(tile);
    tree.close(surface);
}

fn viewMiniHalfRings(state: *const State, tree: *Tree, theme: *const Theme, grid: Grid, w: f32, h: f32, on_left: bool) Tree.Error!void {
    const pad_x: u8 = if (grid == .horizontal) 8 else 6;
    const pad_y: u8 = 4;
    const half_w = w * 0.5;

    const surface = try tree.open(.{
        .axis = .row,
        .width = .fill,
        .height = .fill,
        .cross = .center,
    });
    if (on_left) {
        try viewHalfRingsContainer(state, tree, theme, half_w, h, true);
    }
    const info = try tree.open(.{
        .axis = .column,
        .width = .fill,
        .height = .fill,
        .main = .center,
        .cross = .center,
        .padding = if (on_left)
            .{ .left = 4, .right = pad_x, .top = pad_y, .bottom = pad_y }
        else
            .{ .left = pad_x, .right = 4, .top = pad_y, .bottom = pad_y },
    });
    const box_state = buttonState(state, .play_pause);
    const time_color = progressTimeColor(theme, state.phase, state.run, box_state);
    const avail_w = @max(1, half_w - @as(f32, @floatFromInt(pad_x + 4)));
    const avail_h = @max(1, h - @as(f32, @floatFromInt(pad_y * 2)));
    const full_time = state.timeText();
    // Both 1:1 square (1:2 half) and 2:1 mini (1:1 half) have a tall/square timer half,
    // so stacking MM over SS fills it cleanly with larger Regular display digits.
    const stacked_style: ?text.Style = if (full_time.len == 5 and full_time[2] == ':') blk: {
        if (avail_h >= 104 and avail_w >= 54) break :blk .display_md;
        if (avail_h >= 84 and avail_w >= 44) break :blk .display_sm;
        if (avail_h >= 64 and avail_w >= 34) break :blk .xl_semibold;
        break :blk null;
    } else null;
    if (stacked_style) |style| {
        _ = try tree.text(full_time[0..2], .{
            .color = time_color,
            .style = style,
            .figures = .tabular,
        });
        _ = try tree.text(full_time[3..5], .{
            .color = time_color,
            .style = style,
            .figures = .tabular,
        });
    } else {
        _ = try tree.text(full_time, .{
            .color = time_color,
            .style = fitTimerStyle(avail_w, avail_h, full_time.len, grid == .horizontal),
            .figures = .tabular,
        });
    }
    tree.close(info);
    if (!on_left) {
        try viewHalfRingsContainer(state, tree, theme, half_w, h, false);
    }
    tree.close(surface);
}

fn viewMiniCoil(state: *const State, tree: *Tree, theme: *const Theme, grid: Grid, w: f32, h: f32) Tree.Error!void {
    const pad: u8 = if (w < 112 or h < 88) 8 else 12;
    const gap: u8 = if (h < 92) 4 else 8;
    const box_state = buttonState(state, .play_pause);
    const tile = try tree.open(.{
        .id = play_pause_id,
        .axis = .column,
        .width = .fill,
        .height = .fill,
        .padding = .all(pad),
        .gap = gap,
        .cross = .center,
        .fill = progressBoxFill(theme, box_state),
        .pointer = .hand,
    });
    const inner_w = @max(24, w - @as(f32, @floatFromInt(pad * 2)));
    const time_h_budget = @max(20, (h - @as(f32, @floatFromInt(pad * 2 + gap))) * (if (grid == .square) @as(f32, 0.36) else @as(f32, 0.44)));
    const time_style = fitTimerStyle(inner_w, time_h_budget, state.timeText().len, true);
    const thick: f32 = if (inner_w >= 120 and h >= 112) 4.0 else if (inner_w >= 88 and h >= 84) 3.5 else 3.0;
    try chart.coil(tree, .{
        .width = .fill,
        .height = .fill,
        .fill = progressColor(theme, state.phase, state.run),
        .track = theme.muted.alpha(35),
        .fraction = if (state.phase == .idle) 0 else state.fraction,
        .thickness = thick,
        .columns = chart.coilColumns(inner_w, thick),
    });
    const time_color = progressTimeColor(theme, state.phase, state.run, box_state);
    _ = try tree.text(state.timeText(), .{
        .color = time_color,
        .style = time_style,
        .figures = .tabular,
    });
    tree.close(tile);
}

fn viewMiniTimeText(
    state: *const State,
    tree: *Tree,
    time_color: Color,
    grid: Grid,
    inner_w: f32,
    inner_h: f32,
    allow_stacked: bool,
) Tree.Error!void {
    const full_time = state.timeText();
    const stacked_style: ?text.Style = if (allow_stacked and grid == .square and full_time.len == 5 and full_time[2] == ':') blk: {
        if (inner_h >= 128 and inner_w >= 80) break :blk .xxl_semibold;
        if (inner_h >= 104 and inner_w >= 64) break :blk .display_md;
        if (inner_h >= 84 and inner_w >= 48) break :blk .display_sm;
        if (inner_h >= 66 and inner_w >= 44) break :blk .xl_semibold;
        break :blk null;
    } else null;

    if (stacked_style) |style| {
        _ = try tree.text(full_time[0..2], .{
            .color = time_color,
            .style = style,
            .figures = .tabular,
        });
        _ = try tree.text(full_time[3..5], .{
            .color = time_color,
            .style = style,
            .figures = .tabular,
        });
    } else {
        _ = try tree.text(full_time, .{
            .color = time_color,
            .style = fitTimerStyle(inner_w, inner_h, full_time.len, grid == .horizontal or inner_w >= 170),
            .figures = .tabular,
        });
    }
}

fn viewHorizontalNormal(state: *const State, tree: *Tree, theme: *const Theme, w: f32, h: f32, on_left: bool) Tree.Error!void {
    switch (state.option.progress_style) {
        .auto, .ring => try viewHorizontalNormalDial(state, tree, theme, w, h, on_left, .ring),
        .bar => try viewHorizontalNormalDial(state, tree, theme, w, h, on_left, .bar),
        .border => try viewHorizontalNormalBorder(state, tree, theme, w, h),
        .half_rings => try viewHorizontalNormalHalfRings(state, tree, theme, w, h, on_left),
        .coil => try viewHorizontalNormalCoil(state, tree, theme, w, h, on_left),
    }
}

fn viewHorizontalNormalDial(
    state: *const State,
    tree: *Tree,
    theme: *const Theme,
    w: f32,
    h: f32,
    on_left: bool,
    comptime mark: enum { ring, bar },
) Tree.Error!void {
    const roomy = w >= 290 and h >= 144;
    const hpad: u8 = if (roomy) 14 else 12;
    const vpad: u8 = if (roomy) 12 else 10;
    const gap: u8 = if (roomy) 12 else 10;
    const right_pad: u8 = hpad + 2;
    const bottom_pad: u8 = vpad + 2;
    const chrome_x: f32 = @floatFromInt(hpad + right_pad + gap);
    const chrome_y: f32 = @floatFromInt(vpad + bottom_pad);
    const surface = try tree.open(.{
        .axis = .row,
        .width = .fill,
        .height = .fill,
        .padding = .{ .left = hpad, .right = right_pad, .top = vpad, .bottom = bottom_pad },
        .gap = gap,
        .cross = .center,
    });

    // Reserve `min_left_w` so the phase badge and cycle tally never wrap at any `normal` size.
    const min_left_w: f32 = if (roomy) 146 else 132;
    const tile_side = std.math.clamp(@min(h - chrome_y, w - chrome_x - min_left_w), 72, 134);
    const ring_pad: f32 = if (tile_side >= 116) 20 else 16;
    const ring_side = tile_side - ring_pad;
    const thick: f32 = if (tile_side >= 116) 6 else 5;

    if (on_left) {
        switch (mark) {
            .ring => try viewDialTile(state, tree, theme, tile_side, ring_side, thick, Theme.radius + 2),
            .bar => try viewPlayButtonTile(state, tree, theme, tile_side, Theme.radius + 2),
        }
    }

    const left = try tree.open(.{
        .width = .fill,
        .height = .fill,
        .cross = .start,
        .gap = if (mark == .bar) 4 else 0,
    });

    try viewMetaRow(state, tree, theme, roomy);

    _ = try tree.leaf(.{ .width = .{ .fixed = 1 }, .height = .fill });

    const left_w = @max(1, w - chrome_x - tile_side);
    const avail_h = @max(1, h - chrome_y - if (mark == .bar) @as(f32, 72) else @as(f32, 58));
    _ = try tree.text(state.timeText(), .{
        .color = theme.foreground,
        .style = fitTimerStyle(left_w, avail_h, state.timeText().len, roomy and mark != .bar),
        .figures = .tabular,
    });
    if (mark == .bar) {
        try chart.progress(
            tree,
            theme,
            .bar,
            if (state.phase == .idle) 0 else state.fraction,
            progressColor(theme, state.phase, state.run),
            6,
        );
    }

    _ = try tree.leaf(.{ .width = .{ .fixed = 1 }, .height = .fill });

    try viewControlButtons(state, tree, theme, roomy);
    tree.close(left);

    if (!on_left) {
        switch (mark) {
            .ring => try viewDialTile(state, tree, theme, tile_side, ring_side, thick, Theme.radius + 2),
            .bar => try viewPlayButtonTile(state, tree, theme, tile_side, Theme.radius + 2),
        }
    }

    tree.close(surface);
}

fn viewHorizontalNormalBorder(state: *const State, tree: *Tree, theme: *const Theme, w: f32, h: f32) Tree.Error!void {
    const roomy = w >= 290 and h >= 144;
    const hpad: u8 = if (roomy) 14 else 12;
    const vpad: u8 = if (roomy) 12 else 10;
    const right_pad: u8 = hpad + 2;
    const bottom_pad: u8 = vpad + 2;
    const surface = try tree.open(.{
        .axis = .column,
        .width = .fill,
        .height = .fill,
        .padding = .{ .left = hpad, .right = right_pad, .top = vpad, .bottom = bottom_pad },
        .gap = 8,
    });

    const top_row = try tree.open(.{
        .axis = .row,
        .width = .fill,
        .cross = .center,
        .gap = 8,
    });
    try viewMetaRow(state, tree, theme, roomy);
    try viewControlButtons(state, tree, theme, roomy);
    tree.close(top_row);

    const box_state = buttonState(state, .play_pause);
    const pill_h = @max(40, h - @as(f32, @floatFromInt(vpad + bottom_pad)) - (if (roomy) @as(f32, 46) else @as(f32, 38)));
    const pill_w = @max(80, w - @as(f32, @floatFromInt(hpad + right_pad)));
    const border_w: u8 = if (roomy) 5 else 4;
    const pill = try chart.openBorderPill(tree, .{
        .id = play_pause_id,
        .width = .fill,
        .height = .fill,
        .pill_height = pill_h,
        .border_width = border_w,
        .fill = progressBoxFill(theme, box_state),
        .track = progressTrackBorder(theme, box_state),
        .active = progressBorderColor(theme, state.phase, state.run, box_state),
        .fraction = if (state.phase == .idle) 0 else state.fraction,
        .pointer = .hand,
    });
    const inside = try tree.open(.{
        .overlay = true,
        .width = .fill,
        .height = .fill,
        .main = .center,
        .cross = .center,
        .padding = .symmetric(16, 6),
    });
    const time_color = progressTimeColor(theme, state.phase, state.run, box_state);
    _ = try tree.text(state.timeText(), .{
        .color = time_color,
        .style = fitTimerStyle(pill_w - 32, pill_h - 12, state.timeText().len, true),
        .figures = .tabular,
    });
    tree.close(inside);
    tree.close(pill);
    tree.close(surface);
}

fn viewHorizontalNormalHalfRings(state: *const State, tree: *Tree, theme: *const Theme, w: f32, h: f32, on_left: bool) Tree.Error!void {
    const roomy = w >= 290 and h >= 144;
    const hpad: u8 = if (roomy) 14 else 12;
    const vpad: u8 = if (roomy) 12 else 10;
    const bottom_pad: u8 = vpad + 2;
    const inner_edge_pad: u8 = 6;
    const half_w = w * 0.5;

    const surface = try tree.open(.{
        .axis = .row,
        .width = .fill,
        .height = .fill,
        .cross = .center,
    });
    if (on_left) {
        try viewHalfRingsContainer(state, tree, theme, half_w, h, true);
    }
    const info = try tree.open(.{
        .width = .fill,
        .height = .fill,
        .padding = if (on_left)
            .{ .left = inner_edge_pad, .right = hpad, .top = vpad, .bottom = bottom_pad }
        else
            .{ .left = hpad, .right = inner_edge_pad, .top = vpad, .bottom = bottom_pad },
        .cross = .start,
        .gap = 0,
    });
    try viewMetaRow(state, tree, theme, roomy);
    _ = try tree.leaf(.{ .width = .{ .fixed = 1 }, .height = .fill });
    const left_w = @max(1, half_w - @as(f32, @floatFromInt(hpad + inner_edge_pad)));
    const avail_h = @max(1, h - @as(f32, @floatFromInt(vpad + bottom_pad)) - 58);
    _ = try tree.text(state.timeText(), .{
        .color = theme.foreground,
        .style = fitTimerStyle(left_w, avail_h, state.timeText().len, true),
        .figures = .tabular,
    });
    _ = try tree.leaf(.{ .width = .{ .fixed = 1 }, .height = .fill });
    try viewControlButtons(state, tree, theme, roomy);
    tree.close(info);
    if (!on_left) {
        try viewHalfRingsContainer(state, tree, theme, half_w, h, false);
    }
    tree.close(surface);
}

fn viewHalfRingsContainer(
    state: *const State,
    tree: *Tree,
    theme: *const Theme,
    box_w: f32,
    box_h: f32,
    on_left: bool,
) Tree.Error!void {
    const outer_r = @max(18, box_w * 0.75);
    const thick = std.math.clamp(@round(outer_r * 0.08 * 2.0) * 0.5, 3.0, 8.0);
    const ring_gap = std.math.clamp(@round(outer_r * 0.065 * 2.0) * 0.5, 2.0, 7.0);
    const inner_r = @max(12, outer_r - (thick + ring_gap) * 2 - thick);
    // Align ring endpoints flush with the card's top and bottom borders/corners so the
    // card clip connects each concentric band seamlessly into the edge.
    const clip_half_h = @max(1, box_h * 0.5);
    const icon_size: u8 = if (inner_r >= 52) 20 else if (inner_r >= 26) Theme.icon else if (inner_r >= 18) 14 else 12;
    // Semicircle optical centroid sits at ~0.43 of inner_r from the flat edge.
    const edge_offset: u8 = @intFromFloat(@max(4, @round(inner_r * 0.43 - @as(f32, @floatFromInt(icon_size)) * 0.5)));

    const box_state = buttonState(state, .play_pause);
    const hover_disc_fill: ?Color = switch (box_state) {
        .pressed => theme.secondary.alpha(85),
        .hovered => theme.accent.alpha(65),
        else => null,
    };
    const icon_color: Color = switch (box_state) {
        .pressed, .hovered => theme.foreground,
        else => theme.foreground.alpha(90),
    };

    const pane = try tree.open(.{
        .id = play_pause_id,
        .width = .fill,
        .height = .fill,
        .overflow = .clip,
        .pointer = .hand,
    });
    const dock = try tree.open(.{
        .overlay = true,
        .axis = .row,
        .width = .fill,
        .height = .fill,
        .main = if (on_left) .start else .end,
        .cross = .center,
    });
    const anchor = try tree.open(.{
        .width = .{ .fixed = 2 },
        .height = .fill,
    });
    const ring_start = if (on_left) chart.half_ring_vertical_left_start else chart.half_ring_vertical_start;
    if (hover_disc_fill) |disc_color| {
        const disc_r = @max(8, inner_r - 3);
        _ = try tree.arc(.{
            .radius = disc_r,
            .thickness = disc_r,
            .start = ring_start,
            .sweep = chart.half_ring_sweep,
            .fill = disc_color,
            .caps = .butt,
        }, .{ .overlay = true, .width = .fill, .height = .fill });
    }
    try chart.halfRingsArcs(tree, theme, chart.HalfRings.fromCycle(
        toChartPhase(state.phase),
        state.fraction,
        state.tasks_in_cycle,
        state.tasks_before_long_break,
    ), .{
        .outer_radius = outer_r,
        .thickness = thick,
        .gap = ring_gap,
        .start = ring_start,
        .sweep = chart.half_ring_sweep,
        .clip_half_height = clip_half_h,
    });
    tree.close(anchor);
    tree.close(dock);

    const icon_slot = try tree.open(.{
        .axis = .row,
        .width = .fill,
        .height = .fill,
        .main = if (on_left) .start else .end,
        .cross = .center,
        .padding = if (on_left) .{ .left = edge_offset } else .{ .right = edge_offset },
    });
    _ = try tree.icon(.{
        .codepoint = if (state.run == .running) icons.pause else icons.play,
        .color = icon_color,
        .size = icon_size,
    });
    tree.close(icon_slot);
    tree.close(pane);
}

fn viewHorizontalNormalCoil(state: *const State, tree: *Tree, theme: *const Theme, w: f32, h: f32, on_left: bool) Tree.Error!void {
    const roomy = w >= 290 and h >= 144;
    const hpad: u8 = if (roomy) 14 else 12;
    const vpad: u8 = if (roomy) 12 else 10;
    const bottom_pad: u8 = vpad + 2;
    const inner_edge_pad: u8 = 6;
    const half_w = w * 0.5;

    const surface = try tree.open(.{
        .axis = .row,
        .width = .fill,
        .height = .fill,
        .cross = .center,
    });
    if (on_left) {
        try viewCoilContainer(state, tree, theme, half_w, h, roomy);
    }
    const info = try tree.open(.{
        .width = .fill,
        .height = .fill,
        .padding = if (on_left)
            .{ .left = inner_edge_pad, .right = hpad, .top = vpad, .bottom = bottom_pad }
        else
            .{ .left = hpad, .right = inner_edge_pad, .top = vpad, .bottom = bottom_pad },
        .cross = .start,
        .gap = 0,
    });
    try viewMetaRow(state, tree, theme, roomy);
    _ = try tree.leaf(.{ .width = .{ .fixed = 1 }, .height = .fill });
    const left_w = @max(1, half_w - @as(f32, @floatFromInt(hpad + inner_edge_pad)));
    const avail_h = @max(1, h - @as(f32, @floatFromInt(vpad + bottom_pad)) - 58);
    _ = try tree.text(state.timeText(), .{
        .color = theme.foreground,
        .style = fitTimerStyle(left_w, avail_h, state.timeText().len, true),
        .figures = .tabular,
    });
    _ = try tree.leaf(.{ .width = .{ .fixed = 1 }, .height = .fill });
    try viewControlButtons(state, tree, theme, roomy);
    tree.close(info);
    if (!on_left) {
        try viewCoilContainer(state, tree, theme, half_w, h, roomy);
    }
    tree.close(surface);
}

fn viewCoilContainer(
    state: *const State,
    tree: *Tree,
    theme: *const Theme,
    box_w: f32,
    box_h: f32,
    roomy: bool,
) Tree.Error!void {
    const pad: u8 = if (roomy) 14 else 12;
    const inner_w = @max(24, box_w - @as(f32, @floatFromInt(pad * 2)));
    const thick: f32 = if (box_h >= 144) 4.0 else 3.5;
    const box_state = buttonState(state, .play_pause);
    const pane = try tree.open(.{
        .id = play_pause_id,
        .width = .fill,
        .height = .fill,
        .padding = .all(pad),
        .fill = progressBoxFill(theme, box_state),
        .pointer = .hand,
    });
    try chart.coil(tree, .{
        .width = .fill,
        .height = .fill,
        .fill = progressColor(theme, state.phase, state.run),
        .track = theme.muted.alpha(35),
        .fraction = if (state.phase == .idle) 0 else state.fraction,
        .thickness = thick,
        .columns = chart.coilColumns(inner_w, thick),
    });
    tree.close(pane);
}

fn viewMetaRow(state: *const State, tree: *Tree, theme: *const Theme, roomy: bool) Tree.Error!void {
    const meta = try tree.open(.{
        .axis = .row,
        .width = .fill,
        .cross = .center,
        .gap = 6,
    });
    try badge.view(tree, theme, .{
        .label = phaseShortLabel(state.phase, state.run),
        .variant = phaseBadgeVariant(state.phase, state.run),
        .size = if (roomy) .lg else .sm,
    });
    if (state.phase != .idle and state.cycle_len > 0) {
        try badge.view(tree, theme, .{
            .label = state.cycleText(),
            .variant = .muted,
            .size = if (roomy) .lg else .sm,
        });
    }
    tree.close(meta);
}

fn viewControlButtons(state: *const State, tree: *Tree, theme: *const Theme, roomy: bool) Tree.Error!void {
    const btn_size: button.Size = if (roomy) .sm else .xs;
    const controls = try tree.open(.{
        .axis = .row,
        .gap = if (roomy) 6 else 4,
        .cross = .center,
    });
    try button.view(tree, theme, .{
        .id = reset_id,
        .label = "",
        .icon = icons.rotate_ccw,
        .variant = .outline,
        .size = btn_size,
        .state = if (state.canReset()) buttonState(state, .reset) else .disabled,
    });
    try button.view(tree, theme, .{
        .id = skip_id,
        .label = "",
        .icon = icons.skip_forward,
        .variant = .outline,
        .size = btn_size,
        .state = if (state.canSkip()) buttonState(state, .skip) else .disabled,
    });
    try button.view(tree, theme, .{
        .id = swap_id,
        .label = "",
        .icon = icons.panel_left,
        .variant = .outline,
        .size = btn_size,
        .state = buttonState(state, .swap),
    });
    tree.close(controls);
}

fn viewPlayButtonTile(
    state: *const State,
    tree: *Tree,
    theme: *const Theme,
    tile_side: f32,
    radius: u8,
) Tree.Error!void {
    const box_state = buttonState(state, .play_pause);
    const tile = try tree.open(.{
        .id = play_pause_id,
        .width = .{ .fixed = tile_side },
        .height = .{ .fixed = tile_side },
        .main = .center,
        .cross = .center,
        .fill = tileFill(theme, box_state),
        .border = tileBorder(theme, box_state),
        .border_width = Theme.border_width,
        .radius = radius,
        .pointer = .hand,
    });
    const disc_side = @max(28, tile_side - 28);
    const disc = try tree.open(.{
        .width = .{ .fixed = disc_side },
        .height = .{ .fixed = disc_side },
        .main = .center,
        .cross = .center,
        .fill = theme.background.alpha(85),
        .radius = chart.pillRadius(disc_side),
    });
    _ = try tree.icon(.{
        .codepoint = if (state.run == .running) icons.pause else icons.play,
        .color = theme.foreground,
        .size = if (disc_side >= 58) 20 else Theme.icon,
    });
    tree.close(disc);
    tree.close(tile);
}

fn toChartPhase(phase: Phase) chart.FocusPhase {
    return switch (phase) {
        .idle => .idle,
        .task => .task,
        .short_break => .short_break,
        .long_break => .long_break,
    };
}

fn viewDialTile(
    state: *const State,
    tree: *Tree,
    theme: *const Theme,
    tile_side: f32,
    ring_side: f32,
    thickness: f32,
    radius: u8,
) Tree.Error!void {
    const box_state = buttonState(state, .play_pause);
    const tile = try tree.open(.{
        .id = play_pause_id,
        .width = .{ .fixed = tile_side },
        .height = .{ .fixed = tile_side },
        .main = .center,
        .cross = .center,
        .fill = tileFill(theme, box_state),
        .border = tileBorder(theme, box_state),
        .border_width = Theme.border_width,
        .radius = radius,
        .pointer = .hand,
    });
    try viewDialGraphic(state, tree, theme, ring_side, thickness);
    tree.close(tile);
}

fn viewDialGraphic(
    state: *const State,
    tree: *Tree,
    theme: *const Theme,
    side: f32,
    thickness: f32,
) Tree.Error!void {
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
    const inner_side = @max(18, side - thickness * 2 - 4);
    const icon_size: u8 = if (inner_side < 26)
        11
    else if (inner_side >= 100)
        24
    else if (inner_side >= 58)
        20
    else if (inner_side >= 34)
        Theme.icon
    else
        14;
    const disc = try tree.open(.{
        .width = .{ .fixed = inner_side },
        .height = .{ .fixed = inner_side },
        .main = .center,
        .cross = .center,
        .fill = theme.background.alpha(85),
        .radius = @intFromFloat(@ceil(inner_side / 2)),
    });
    _ = try tree.icon(.{
        .codepoint = if (state.run == .running) icons.pause else icons.play,
        .color = theme.foreground,
        .size = icon_size,
    });
    tree.close(disc);
    tree.close(center);
    tree.close(dial);
}

fn fitTimerStyle(avail_w: f32, avail_h: f32, len: usize, allow_hero: bool) text.Style {
    const chars: f32 = @floatFromInt(@max(1, len));
    if (allow_hero and avail_h >= 64 and avail_w >= chars * 34.0) return .xxl_semibold;
    if (allow_hero and avail_h >= 52 and avail_w >= chars * 26.5) return .display_md;
    if (allow_hero and avail_h >= 42 and avail_w >= chars * 21.5) return .display_sm;
    if (avail_h >= 32 and avail_w >= chars * 16.0) return .xl_semibold;
    if (avail_h >= 24 and avail_w >= chars * 12.0) return .lg_semibold;
    return .sm_medium;
}

fn viewResizeHandle(state: *const State, tree: *Tree, theme: *const Theme) Tree.Error!void {
    const corner_active = state.hovered == .resize or state.capture == .resize;
    const grip_color = if (corner_active) theme.foreground else theme.muted_foreground.alpha(65);
    const corner = try tree.open(.{
        .overlay = true,
        .width = .fill,
        .height = .fill,
        .main = .end,
        .cross = .end,
    });
    const grip = try tree.open(.{
        .id = resize_id,
        .width = .{ .fixed = resize_corner_size },
        .height = .{ .fixed = resize_corner_size },
        .main = .end,
        .cross = .end,
        .padding = .{ .right = 3, .bottom = 3 },
        .pointer = .hand,
    });
    _ = try tree.icon(.{
        .codepoint = icons.handle_bottom_right,
        .color = grip_color,
        .size = 10,
    });
    tree.close(grip);
    tree.close(corner);
}

/// Builds the hover tooltip for `mini` mode (colored phase badge and cycle tally),
/// returning null when disabled (`!option.tooltip`), unfocused, dragging/resizing, hidden, or in `normal` mode.
pub fn viewTooltip(
    state: *const State,
    tree: *Tree,
    theme: *const Theme,
    viewport_w: f32,
    viewport_h: f32,
    metrics: tooltip.Metrics,
) Tree.Error!?Index {
    if (!state.visible or !state.option.tooltip) return null;
    if (!state.pointer_inside and state.hovered == .none) return null;
    if (state.capture == .move or state.capture == .resize) return null;
    const eff = state.effectiveSize(viewport_w, viewport_h);
    if (eff.mode != .mini) return null;

    const card = try tooltip.openAt(tree, theme, 0, 0, metrics);
    const row = try tree.open(.{
        .axis = .row,
        .gap = 6,
        .cross = .center,
    });
    try badge.view(tree, theme, .{
        .label = phaseShortLabel(state.phase, state.run),
        .variant = phaseBadgeVariant(state.phase, state.run),
    });
    if (state.phase != .idle and state.cycle_len > 0) {
        try badge.view(tree, theme, .{
            .label = state.cycleText(),
            .variant = .muted,
        });
    }
    tree.close(row);
    tooltip.close(tree, card);
    return card;
}

/// Positions `tip_root` cleanly on the best non-overlapping side of `widget_root`
/// (`below`, `above`, `left`, or `right`), aligned against the card and viewport
/// margins, falling back to minimum card overlap in cramped viewports.
pub fn placeTooltip(tree: *Tree, widget_root: ?Index, tip_root: ?Index, viewport_w: f32, viewport_h: f32) void {
    const w_idx = widget_root orelse return;
    const t_idx = tip_root orelse return;
    const card = tree.nodes[w_idx].rect;
    const tip = tree.nodes[t_idx].rect;
    const at = layout.placeAnchored(tip, card, viewport_w, viewport_h, .{
        .side = .auto,
        .alignment = .flush,
        .match_anchor_width = false,
        .gap = 6,
        .margin = 8,
    });
    tree.translate(t_idx, at.x - tip.x, at.y - tip.y);
}

/// Translates the widget to its clamped `(x, y)` viewport coordinates after layout.
/// When never dragged or resized, docks cleanly at `state.option.anchor`.
pub fn place(state: *State, tree: *Tree, root: ?Index, viewport_w: f32, viewport_h: f32) void {
    const idx = root orelse return;
    const rect = tree.nodes[idx].rect;
    if (!state.positioned) {
        state.x = switch (state.option.anchor) {
            .top_left, .bottom_left => edge_margin,
            .top_center, .bottom_center => @round((viewport_w - rect.w) * 0.5),
            .top_right, .bottom_right => @max(edge_margin, viewport_w - edge_margin - rect.w),
        };
        state.y = if (state.option.anchor.isTop())
            edge_margin
        else
            @max(edge_margin, viewport_h - edge_margin - rect.h);
    }
    const max_x = @max(min_clamp_margin, viewport_w - min_clamp_margin - rect.w);
    const max_y = @max(min_clamp_margin, viewport_h - min_clamp_margin - rect.h);
    state.x = std.math.clamp(state.x, min_clamp_margin, max_x);
    state.y = std.math.clamp(state.y, min_clamp_margin, max_y);
    tree.translate(idx, state.x - rect.x, state.y - rect.y);
}

fn buttonState(state: *const State, target: Hit) button.State {
    switch (state.capture) {
        .play_pause => if (target == .play_pause) return .pressed,
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
        .short_break => theme.success,
        .long_break => theme.foreground,
        .task, .idle => theme.info,
    };
}

fn phaseBadgeVariant(phase: Phase, run: Run) badge.Variant {
    if (phase == .idle or run != .running) return .muted;
    return switch (phase) {
        .task => .info,
        .short_break => .success,
        .long_break => .secondary,
        .idle => .muted,
    };
}

fn tileFill(theme: *const Theme, btn_state: button.State) Color {
    return switch (btn_state) {
        .pressed => theme.secondary,
        .hovered => theme.accent,
        else => theme.muted.alpha(50),
    };
}

fn progressBoxFill(theme: *const Theme, btn_state: button.State) Color {
    return switch (btn_state) {
        .pressed => theme.secondary.alpha(75),
        .hovered => theme.accent.alpha(45),
        else => .transparent,
    };
}

fn progressTrackBorder(theme: *const Theme, btn_state: button.State) Color {
    if (btn_state == .hovered or btn_state == .pressed) {
        return theme.ring.alpha(55);
    }
    return theme.foreground.alpha(12);
}

fn progressBorderColor(theme: *const Theme, phase: Phase, run: Run, btn_state: button.State) Color {
    const hovered = btn_state == .hovered or btn_state == .pressed;
    if (phase == .idle or run != .running) {
        return theme.muted_foreground.alpha(if (hovered) 80 else 55);
    }
    const base = switch (phase) {
        .task => theme.info,
        .short_break => theme.success,
        .long_break => theme.foreground,
        .idle => theme.muted_foreground,
    };
    return if (hovered) base else base.alpha(92);
}

fn progressTimeColor(theme: *const Theme, phase: Phase, run: Run, box_state: button.State) Color {
    if (phase != .idle and run != .running) return progressBorderColor(theme, phase, run, box_state);
    return theme.foreground;
}

fn tileBorder(theme: *const Theme, btn_state: button.State) Color {
    if (btn_state == .hovered or btn_state == .pressed) {
        return theme.ring.alpha(70);
    }
    return theme.border;
}

fn trackColor(theme: *const Theme, phase: Phase, run: Run) Color {
    if (phase != .idle and run == .running) {
        return switch (phase) {
            .task => theme.info.alpha(24),
            .short_break => theme.success.alpha(24),
            .long_break => theme.foreground.alpha(18),
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
