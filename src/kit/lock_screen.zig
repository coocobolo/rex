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
const motion_zig = @import("motion.zig");
const text = @import("text.zig");
const tree_zig = @import("tree.zig");
const Tree = tree_zig.Tree;
const Id = tree_zig.Id;

pub const width: f32 = 440;

pub const title_capacity = 64;
pub const subtitle_capacity = 96;
pub const prompt_capacity = 256;
pub const steps_max = 12;

pub const scrim_id = Id.of("lock.scrim");
pub const card_id = Id.of("lock.card");
pub const unlock_id = Id.of("lock.unlock");

pub const Tone = enum(u8) {
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

pub const ButtonTouch = enum(u8) {
    normal,
    hovered,
    pressed,
};

pub const Request = struct {
    tone: Tone = .healthy,
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
    tone: Tone = .healthy,
    touch: ButtonTouch = .normal,
    focused: bool = false,
    motion: motion_zig.Mode = .full,
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
        self.tone == req.tone and
        self.scrim_alpha == req.scrim_alpha and
        self.steps_total == clamped_steps_total and
        self.steps_done == clamped_steps_done and
        self.remaining_s == req.remaining_s and
        self.total_s == req.total_s and
        std.mem.eql(u8, self.title(), req.title[0..new_title_len]) and
        std.mem.eql(u8, self.subtitle(), req.subtitle[0..new_sub_len]) and
        std.mem.eql(u8, self.prompt(), req.prompt[0..new_prompt_len]);

    const entered = if (self.motion == .none) blk: {
        const was_open = self.phase.acceptsInput();
        self.phase = .open;
        break :blk !was_open;
    } else self.phase.enter(self.motion);
    if (entered) {
        self.touch = .normal;
        self.focused = req.focus;
    }

    self.tone = req.tone;
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
    if (self.motion == .none) {
        const was_open = self.phase != .closed;
        self.phase = .closed;
        return was_open;
    }
    return self.phase.leave(self.motion);
}

fn hoverAt(self: *State, over: Pointer) Outcome {
    if (!self.phase.acceptsInput()) return .quiet;
    if (self.touch == .pressed) return .quiet;
    const next: ButtonTouch = switch (over) {
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

/// Lines of wrapped text one view needs at most.
pub const line_max = title_capacity + 1 + subtitle_capacity + 1 + prompt_capacity + 1 + 64;

/// Most nodes one view writes.
pub const node_max = dialog.node_max + 9 + steps_max + chart.progress_nodes + button.node_max;

/// Writes the lock screen over the terminal, or nothing when closed.
pub fn view(state: *const State, tree: *Tree, theme: *const Theme) tree_zig.Error!void {
    if (state.phase == .closed) return;
    const presence = state.phase.presence(state.motion);
    const accent = state.tone.accent(theme).fade(presence);

    const frame = try dialog.open(tree, theme, .{
        .scrim_id = scrim_id,
        .card_id = card_id,
        .width = width,
        .presence = presence,
        .scrim_alpha = state.scrim_alpha,
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
    if (state.steps_total > 0) {
        const pips = try tree.open(.{
            .axis = .row,
            .cross = .center,
            .gap = 4,
        });
        for (0..state.steps_total) |idx| {
            const done = idx < state.steps_done;
            _ = try tree.leaf(.{
                .width = .{ .fixed = 8 },
                .height = .{ .fixed = 8 },
                .radius = 4,
                .fill = if (done) accent else theme.muted.fade(presence),
            });
        }
        tree.close(pips);
    }
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

    const footer = try dialog.footer(tree);
    const btn_state: button.State = switch (state.touch) {
        .normal => .normal,
        .hovered => .hovered,
        .pressed => .pressed,
    };
    try button.view(tree, theme, .{
        .id = unlock_id,
        .label = "Unlock early",
        .key_cap = "Ctrl+Shift+D",
        .variant = .outline,
        .size = .sm,
        .state = btn_state,
        .focused = state.focused,
        .presence = presence,
    });
    tree.close(footer);

    dialog.close(tree, frame);
}
