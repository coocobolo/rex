//! The wellbeing window: one `Wellbeing` joined to the shared state file,
//! shown as three pages under a tab list: Today, Focus and History. The
//! window does not call `tick`; that counts screen time and belongs to the
//! terminal. It reads the shared timer and writes only Start, Pause, Skip
//! and Reset.

const std = @import("std");
const builtin = @import("builtin");

const host = @import("host.zig");
const FileWatch = @import("FileWatch.zig");
const kit = @import("../kit/root.zig");
const wellbeing = @import("../builtin/wellbeing/root.zig");
const DashboardOption = @FieldType(@import("../config/wellbeing.zig").Wellbeing, "dashboard");

const button = kit.button;
const chart = kit.chart;
const icons = kit.icons;
const popup = kit.popup;
const tabs = kit.tabs;
const Theme = kit.Theme;
const Tree = kit.tree.Tree;
const Id = kit.tree.Id;
const focus = wellbeing.focus;

const log = std.log.scoped(.wellbeing);

pub const name = "wellbeing";
pub const title = "Wellbeing";

pub const Page = enum(u8) {
    today,
    focus,
    history,

    fn label(self: Page) []const u8 {
        return switch (self) {
            .today => "Today",
            .focus => "Focus",
            .history => "History",
        };
    }

    fn next(self: Page) Page {
        return @enumFromInt((@intFromEnum(self) + 1) % page_count);
    }

    fn previous(self: Page) Page {
        return @enumFromInt((@intFromEnum(self) + page_count - 1) % page_count);
    }
};

const page_count = @typeInfo(Page).@"enum".fields.len;

/// What the pointer is on, or what the left button went down on.
const Over = union(enum) {
    none,
    tab: Page,
    chip,
    toggle,
    skip,
    more,
    reset,
    /// The popup's layer, outside its card.
    outside,
};

const tab_id = Id.of("wellbeing.tab");
const chip_id = Id.of("wellbeing.chip");
const toggle_id = Id.of("wellbeing.toggle");
const skip_id = Id.of("wellbeing.skip");
const more_id = Id.of("wellbeing.more");
const reset_id = Id.of("wellbeing.reset");
const layer_id = Id.of("wellbeing.layer");

fn over(id: Id) Over {
    if (id == chip_id) return .chip;
    if (id == toggle_id) return .toggle;
    if (id == skip_id) return .skip;
    if (id == more_id) return .more;
    if (id == reset_id) return .reset;
    if (id == layer_id) return .outside;
    inline for (0..page_count) |index| {
        if (id == tab_id.item(index)) return .{ .tab = @enumFromInt(index) };
    }
    return .none;
}

/// The frame: the root, the header, the tab list, the spacer and the
/// timer chip (its box, dot, time and phase).
const frame_nodes = 3 + tabs.nodeMax(page_count) + 1 + 4;
/// The Focus page: its column, the timer block (label, time, task line and
/// the larger of the two marks: a bar, or a ring in its square under an
/// overlaid column), the button row and three buttons, and the popup with
/// its one item.
const focus_nodes = 1 + 1 + 3 + 6 + 1 + 3 * button.node_max + popup.node_max + popup.item_node_max;

pub const node_max = frame_nodes + focus_nodes;
/// At most one line per text node: no text here wraps.
pub const line_max = node_max;

pub const State = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    /// Borrowed from the host (`host.Context.state_dir`).
    state_dir: []const u8,
    wb: wellbeing.Wellbeing,
    /// Read at start, like `[ui] color_scheme`.
    charts: DashboardOption,
    page: Page = .today,
    hover: Over = .none,
    pressed: Over = .none,
    /// The Focus page's "more" menu, which holds Reset.
    menu: enum(u8) { closed, open } = .closed,
    /// What `refresh` last computed from the timer.
    shown: Shown = .{},
    /// Linux only; null elsewhere or when the watch could not start.
    watch: ?*FileWatch = null,

    pub fn clock(self: *const State) []const u8 {
        return self.shown.time_buf[0..self.shown.time_len];
    }

    pub fn taskLine(self: *const State) []const u8 {
        return self.shown.task_buf[0..self.shown.task_len];
    }
};

/// The timer as the pages show it at one moment.
const Shown = struct {
    /// The phase the time and the label are about: the next one while the
    /// timer waits to start it.
    phase: focus.Phase = .idle,
    /// Of the phase, 0 to 1.
    fraction: f32 = 0,
    time_len: u8 = 0,
    task_len: u8 = 0,
    time_buf: [16]u8 = undefined,
    task_buf: [32]u8 = undefined,
};

/// Joins the shared state and, on Linux, watches the state file.
pub fn init(context: host.Context) !State {
    var state: State = .{
        .io = context.io,
        .gpa = context.gpa,
        .state_dir = context.state_dir,
        .wb = wellbeing.Wellbeing.init(context.config.wellbeing),
        .charts = context.config.wellbeing.dashboard,
    };
    try state.wb.open(state.io, state.state_dir, wallMs(state.io));
    errdefer state.wb.close(state.io);
    refresh(&state);
    if (comptime builtin.os.tag == .linux) {
        const dir = state.wb.stateDir(state.state_dir);
        state.watch = FileWatch.create(state.gpa, dir, state.wb.option.privacy.state_filename, context.wake_loop) catch |err| blk: {
            log.warn("not watching {s} for changes ({t}); checking once a second", .{ dir, err });
            break :blk null;
        };
    }
    return state;
}

pub fn deinit(state: *State) void {
    if (state.watch) |watch| {
        watch.destroy(state.gpa);
        state.watch = null;
    }
    // Retries a button's save that failed; writes nothing otherwise.
    state.wb.sync(state.io, state.state_dir, wallSeconds(state.io), .merge) catch |err| {
        log.err("cannot save wellbeing state: {t}", .{err});
    };
    state.wb.close(state.io);
}

pub fn wait(state: *const State) ?f64 {
    return waitAt(state, wallMs(state.io));
}

/// While the timer runs, until the shown second changes, as the terminal
/// ticks (`focus.State.msUntilTick`). A running phase at its end waits for
/// the terminal to end it, as an idle window waits: for the file watch, or
/// a poll once a second without one.
pub fn waitAt(state: *const State, now_ms: i64) ?f64 {
    const shown = focus.State.view(state.wb.timer(), state.wb.option.focus, now_ms);
    const tick_ms = shown.msUntilTick();
    if (tick_ms != std.math.maxInt(u64) and shown.remaining_ms > 0) {
        return @as(f64, @floatFromInt(@min(tick_ms, std.time.ms_per_s))) / std.time.ms_per_s;
    }
    if (state.watch) |watch| {
        if (watch.isAlive()) return null;
    }
    return 1;
}

/// Picks up another process's save. True when the timer or the shown time
/// changed. A wake from the watch reads the file at once; any other wake
/// (input, the timeout) polls, at most once a second.
pub fn wake(state: *State) bool {
    const timer_before = state.wb.timer();
    const shown_before = state.shown;
    const changed = if (state.watch) |watch| watch.takeChanged() else false;
    const mode: wellbeing.Wellbeing.SyncMode = if (changed) .changed else .poll;
    state.wb.sync(state.io, state.state_dir, wallSeconds(state.io), mode) catch |err| {
        log.err("cannot read wellbeing state: {t}", .{err});
    };
    refresh(state);
    if (!std.meta.eql(timer_before, state.wb.timer())) return true;
    return !shownEql(&shown_before, &state.shown);
}

fn shownEql(a: *const Shown, b: *const Shown) bool {
    return a.phase == b.phase and a.fraction == b.fraction and
        std.mem.eql(u8, a.time_buf[0..a.time_len], b.time_buf[0..b.time_len]) and
        std.mem.eql(u8, a.task_buf[0..a.task_len], b.task_buf[0..b.task_len]);
}

pub fn update(state: *State, event: host.Event) bool {
    const page = state.page;
    const hover = state.hover;
    const pressed = state.pressed;
    const menu = state.menu;
    const timer_changed = switch (event) {
        .size => false,
        .pointer => |id| blk: {
            state.hover = over(id);
            break :blk false;
        },
        .press => |id| blk: {
            const target = over(id);
            // Like a dialog's scrim, a press beside the menu closes it at once.
            if (state.menu == .open and target == .outside) {
                state.menu = .closed;
            } else {
                state.pressed = target;
            }
            break :blk false;
        },
        .release => blk: {
            const target = state.pressed;
            state.pressed = .none;
            break :blk std.meta.eql(target, state.hover) and act(state, target);
        },
        .key => |press| key(state, press),
    };
    return timer_changed or state.page != page or !std.meta.eql(state.hover, hover) or
        !std.meta.eql(state.pressed, pressed) or state.menu != menu;
}

/// Ctrl+Tab and Ctrl+Shift+Tab switch pages, Space starts or pauses the
/// timer, Escape closes the menu. True when the timer changed.
fn key(state: *State, press: host.KeyPress) bool {
    const mods = press.mods;
    switch (press.key) {
        .tab => if (mods.ctrl and !mods.alt and !mods.super) {
            state.menu = .closed;
            state.page = if (mods.shift) state.page.previous() else state.page.next();
        },
        .space => if (!mods.hasAny() and state.menu == .closed) return act(state, .toggle),
        .escape => state.menu = .closed,
        else => {},
    }
    return false;
}

/// Carries out a click or its key. True when the timer changed.
fn act(state: *State, target: Over) bool {
    const now_ms = wallMs(state.io);
    switch (target) {
        .none, .outside => return false,
        .tab => |page| {
            state.page = page;
            state.menu = .closed;
            return false;
        },
        .chip => {
            state.page = .focus;
            return false;
        },
        .more => {
            state.menu = if (state.menu == .open) .closed else .open;
            return false;
        },
        .toggle => state.wb.toggleFocus(now_ms),
        .skip => state.wb.skipFocus(now_ms),
        .reset => {
            state.menu = .closed;
            state.wb.resetFocus(now_ms);
        },
    }
    state.wb.sync(state.io, state.state_dir, wallSeconds(state.io), .merge) catch |err| {
        log.err("cannot save wellbeing state: {t}", .{err});
    };
    refresh(state);
    return true;
}

pub fn view(state: *const State, tree: *Tree, theme: *const Theme) kit.tree.Error!void {
    const root = try tree.open(.{ .width = .fill, .height = .fill });
    try header(state, tree, theme);
    switch (state.page) {
        .today, .history => {},
        .focus => try focusPage(state, tree, theme),
    }
    tree.close(root);

    if (state.page == .focus and state.menu == .open) {
        const card = try popup.open(tree, theme, .{ .layer_id = layer_id, .anchor = more_id });
        try popup.item(tree, theme, .{
            .id = reset_id,
            .label = "Reset cycle",
            .highlighted = std.meta.eql(state.hover, Over.reset),
        });
        popup.close(tree, card);
    }
}

fn header(state: *const State, tree: *Tree, theme: *const Theme) kit.tree.Error!void {
    const row = try tree.open(.{
        .axis = .row,
        .width = .fill,
        .height = .{ .fixed = 56 },
        .padding = .symmetric(24, 0),
        .cross = .center,
    });
    var list: [page_count]tabs.Tab = undefined;
    for (&list, 0..) |*tab, index| {
        tab.* = .{ .id = tab_id.item(@intCast(index)), .label = @as(Page, @enumFromInt(index)).label() };
    }
    try tabs.view(tree, theme, .{
        .tabs = &list,
        .current = @intFromEnum(state.page),
        .hovered = switch (state.hover) {
            .tab => |page| @intFromEnum(page),
            else => tabs.none,
        },
    });
    _ = try tree.leaf(.{ .width = .fill });
    if (state.page != .focus and state.shown.phase != .idle) try timerChip(state, tree, theme);
    tree.close(row);
}

/// The running timer, on the pages that do not show it: a dot in the
/// phase's color, the time and the phase. A click opens Focus.
fn timerChip(state: *const State, tree: *Tree, theme: *const Theme) kit.tree.Error!void {
    const touched = std.meta.eql(state.hover, Over.chip);
    const chip = try tree.open(.{
        .id = chip_id,
        .pointer = .hand,
        .axis = .row,
        .height = .{ .fixed = Theme.control_sm },
        .padding = .symmetric(12, 0),
        .gap = 8,
        .cross = .center,
        .fill = if (touched) theme.accent else .transparent,
        .border = theme.border,
        .border_width = Theme.border_width,
        .radius = Theme.radius_md,
    });
    _ = try tree.leaf(.{
        .width = .{ .fixed = 8 },
        .height = .{ .fixed = 8 },
        .fill = phaseColor(theme, state.shown.phase),
        .radius = 4,
    });
    _ = try tree.text(state.clock(), .{ .color = theme.foreground, .style = .sm_medium, .figures = .tabular });
    _ = try tree.text(phaseLabel(state.shown.phase), .{ .color = theme.muted_foreground });
    tree.close(chip);
}

fn focusPage(state: *const State, tree: *Tree, theme: *const Theme) kit.tree.Error!void {
    const page = try tree.open(.{
        .width = .fill,
        .height = .fill,
        .padding = .{ .left = 24, .right = 24, .top = 0, .bottom = 40 },
        .gap = 28,
        .main = .center,
        .cross = .center,
    });
    const color = phaseColor(theme, state.shown.phase);
    switch (state.charts.timer_chart) {
        .bar => {
            const block = try tree.open(.{ .width = .{ .at_most = 400 }, .gap = 8, .cross = .center });
            try timerText(state, tree, theme, .xxxl_semibold);
            try chart.progress(tree, theme, .bar, state.shown.fraction, color);
            _ = try tree.text(state.taskLine(), .{ .color = theme.muted_foreground });
            tree.close(block);
        },
        .ring => {
            const side = chart.ring_radius * 2;
            const square = try tree.open(.{ .width = .{ .fixed = side }, .height = .{ .fixed = side } });
            try chart.progress(tree, theme, .ring, state.shown.fraction, color);
            const inside = try tree.open(.{ .overlay = true, .width = .fill, .height = .fill, .gap = 4, .main = .center, .cross = .center });
            try timerText(state, tree, theme, .xxl_semibold);
            _ = try tree.text(state.taskLine(), .{ .color = theme.muted_foreground });
            tree.close(inside);
            tree.close(square);
        },
    }
    try timerButtons(state, tree, theme);
    tree.close(page);
}

/// The phase over the time.
fn timerText(state: *const State, tree: *Tree, theme: *const Theme, style: kit.text.Style) kit.tree.Error!void {
    _ = try tree.text(phaseLabel(state.shown.phase), .{ .color = phaseColor(theme, state.shown.phase), .style = .sm_medium });
    _ = try tree.text(state.clock(), .{ .color = theme.foreground, .style = style, .figures = .tabular });
}

fn timerButtons(state: *const State, tree: *Tree, theme: *const Theme) kit.tree.Error!void {
    const running = state.wb.timer().run == .running;
    const row = try tree.open(.{ .axis = .row, .gap = button.gap, .cross = .center });
    try button.view(tree, theme, .{
        .id = toggle_id,
        .label = toggleLabel(state),
        .icon = if (running) icons.pause else icons.play,
        .variant = .primary,
        .size = .lg,
        .state = buttonState(state, .toggle),
    });
    // Skip does nothing to an idle timer (`focus.skip`).
    const idle = state.wb.timer().phase == .idle;
    try button.view(tree, theme, .{
        .id = skip_id,
        .label = "Skip",
        .icon = icons.skip_forward,
        .size = .lg,
        .state = if (idle) .disabled else buttonState(state, .skip),
    });
    try button.view(tree, theme, .{
        .id = more_id,
        .label = "",
        .icon = icons.ellipsis,
        .variant = .ghost,
        .size = .lg,
        .state = if (state.menu == .open) .hovered else buttonState(state, .more),
    });
    tree.close(row);
}

fn toggleLabel(state: *const State) []const u8 {
    const timer = state.wb.timer();
    return switch (timer.run) {
        .running => "Pause",
        .waiting => "Start",
        .paused => if (timer.phase == .idle) "Start" else "Resume",
    };
}

fn buttonState(state: *const State, target: Over) button.State {
    const hovered = std.meta.eql(state.hover, target);
    if (hovered and std.meta.eql(state.pressed, target)) return .pressed;
    if (hovered) return .hovered;
    return .normal;
}

fn phaseLabel(phase: focus.Phase) []const u8 {
    return switch (phase) {
        .idle => "Ready",
        .task => "Focus",
        .short_break => "Short break",
        .long_break => "Long break",
    };
}

fn phaseColor(theme: *const Theme, phase: focus.Phase) Theme.Color {
    return switch (phase) {
        .idle => theme.muted_foreground,
        .task => theme.info,
        .short_break, .long_break => theme.success,
    };
}

fn refresh(state: *State) void {
    refreshAt(state, wallMs(state.io));
}

/// As the terminal shows the timer: an idle timer shows a full task, a
/// waiting one the next phase in full, and with `timer = countdown` a
/// second still partly left counts as a whole one.
pub fn refreshAt(state: *State, now_ms: i64) void {
    const option = state.wb.option.focus;
    const timer = state.wb.timer();
    const view_now = focus.State.view(timer, option, now_ms);
    const phase: focus.Phase = switch (timer.run) {
        .waiting => nextPhase(timer, option),
        .running, .paused => timer.phase,
    };
    const shown = &state.shown;
    shown.phase = phase;
    const duration_ms = view_now.getDuration(if (phase == .idle) .task else phase);
    const started = timer.phase != .idle and timer.run != .waiting;
    const left_ms = if (started) @min(view_now.remaining_ms, duration_ms) else duration_ms;
    shown.fraction = if (started and duration_ms > 0)
        1 - @as(f32, @floatFromInt(left_ms)) / @as(f32, @floatFromInt(duration_ms))
    else
        0;
    shown.time_len = switch (option.timer) {
        .countdown => formatTime(&shown.time_buf, secondsCeil(left_ms)),
        .countup => formatTime(&shown.time_buf, (duration_ms - left_ms) / std.time.ms_per_s),
    };
    const of = option.tasks_before_long_break;
    const task_line = switch (phase) {
        .idle, .task => std.fmt.bufPrint(&shown.task_buf, "Task {d} of {d}", .{ @min(timer.tasks_in_cycle + 1, of), of }),
        .short_break => std.fmt.bufPrint(&shown.task_buf, "{d} of {d} tasks done", .{ timer.tasks_in_cycle, of }),
        .long_break => std.fmt.bufPrint(&shown.task_buf, "Cycle of {d} tasks done", .{of}),
    };
    // 32 bytes hold any of these lines with two u8 counts.
    shown.task_len = @intCast((task_line catch unreachable).len);
}

/// The phase a waiting timer starts next (`focus.State.fmt` does the same).
fn nextPhase(timer: focus.Timer, option: focus.Option) focus.Phase {
    return switch (timer.phase) {
        .idle => .idle,
        .task => if (timer.tasks_in_cycle + 1 >= option.tasks_before_long_break) .long_break else .short_break,
        .short_break, .long_break => .task,
    };
}

fn secondsCeil(ms: u64) u64 {
    return ms / std.time.ms_per_s + @intFromBool(ms % std.time.ms_per_s != 0);
}

fn formatTime(buf: *[16]u8, total_s: u64) u8 {
    const minutes: u64 = (total_s / 60) % 60;
    const seconds: u64 = total_s % 60;
    const hours: u64 = total_s / 3600;
    const text = if (hours > 0)
        std.fmt.bufPrint(buf, "{d}:{d:0>2}:{d:0>2}", .{ hours, minutes, seconds })
    else
        std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}", .{ minutes, seconds });
    // A u64 of seconds is at most 5124095576030431 hours: 16 digits plus
    // ":mm:ss" does not fit, but no phase lasts that long; show 00:00.
    if (text) |written| return @intCast(written.len) else |_| {
        @memcpy(buf[0..5], "00:00");
        return 5;
    }
}

fn wallMs(io: std.Io) i64 {
    return std.Io.Clock.Timestamp.now(io, .real).raw.toMilliseconds();
}

fn wallSeconds(io: std.Io) i64 {
    return @divFloor(wallMs(io), std.time.ms_per_s);
}
