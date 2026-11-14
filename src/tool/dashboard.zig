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

/// The Today page: its column, the card row and four stat cards (box,
/// title, value, bar or spacer, note), the lower row and its two slots,
/// the week card and the programs card.
const today_nodes = 1 + 1 + 4 * (4 + chart.progress_nodes) + 1 + 2 + week_nodes + programs_nodes;
/// Card, header row, title, spacer, two legend items (row, swatch, text),
/// the chart's column, the bars, and the label row with a box and text
/// per day.
const week_nodes = 4 + 2 * 3 + 1 + chart.dayNodes(week_days) + 1 + week_days * 2;
/// Card, title, the chart's box and the larger mark, the list and a row
/// per program (row, swatch, name, time, share box and share); or one
/// line when there are none.
const programs_nodes = 2 + 1 + @as(usize, @max(chart.shareNodes(program_rows), chart.donutNodes(program_rows))) + 1 + program_rows * 6;

pub const node_max = frame_nodes + @as(usize, @max(focus_nodes, today_nodes));
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
    /// What `refresh` last computed from the day's records.
    today: Today = .{},
    local_clock: wellbeing.localtime.Clock = .{},
    /// Wall-clock second of the next local midnight, when the pages roll
    /// over to a new day.
    midnight_utc_s: i64 = 0,
    /// Bumped when `today` is computed from different records or a new
    /// day, so a wake knows to redraw.
    today_revision: u32 = 0,
    /// The records and day `today` was computed from.
    today_key: TodayKey = .{},
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

/// Text formatted into a fixed buffer, so the view can borrow it until the
/// next `refresh`. Text that does not fit is cut.
fn Label(comptime capacity: u8) type {
    return struct {
        buf: [capacity]u8 = undefined,
        len: u8 = 0,

        const Self = @This();

        /// `args` is whatever `fmt` formats.
        fn set(self: *Self, comptime fmt: []const u8, args: anytype) void {
            var writer: std.Io.Writer = .fixed(&self.buf);
            writer.print(fmt, args) catch {};
            self.len = @intCast(writer.end);
        }

        fn duration(self: *Self, seconds: u64) void {
            const minutes = seconds / std.time.s_per_min;
            if (minutes >= 60 and minutes % 60 == 0) {
                self.set("{d}h", .{minutes / 60});
            } else if (minutes >= 60) {
                self.set("{d}h {d}m", .{ minutes / 60, minutes % 60 });
            } else if (seconds >= std.time.s_per_min or seconds == 0) {
                self.set("{d}m", .{minutes});
            } else {
                self.set("<1m", .{});
            }
        }

        pub fn slice(self: *const Self) []const u8 {
            return self.buf[0..self.len];
        }
    };
}

const week_days = 7;
/// Four programs by name, then the rest together.
const program_rows = 5;
const program_names = program_rows - 1;

/// The Today page as `refresh` last computed it.
pub const Today = struct {
    cards: [card_count]Card = @splat(.{}),
    /// Oldest first; the last is today.
    week: [week_days]WeekDay = @splat(.{}),
    /// Today's day of the week, 0 for Sunday.
    weekday: u8 = 0,
    /// The daily limit in seconds; 0 for none.
    limit_s: u32 = 0,
    programs: [program_rows]Program = @splat(.{}),
    program_count: u8 = 0,

    const card_count = 4;
};

/// What `Today` is computed from besides the clock.
const TodayKey = struct {
    last_write_utc_s: i64 = 0,
    generation: u32 = 0,
    day: u32 = 0,
};

pub const Card = struct {
    value: Label(16) = .{},
    note: Label(40) = .{},
    /// Of the bar under the value, 0 to 1; negative for no bar.
    fraction: f32 = -1,
    over: bool = false,
};

pub const WeekDay = struct {
    screen_s: u32 = 0,
    focus_s: u32 = 0,
};

pub const Program = struct {
    name: Label(wellbeing.storage.max_comm_len) = .{},
    time: Label(12) = .{},
    share: Label(5) = .{},
    seconds: u32 = 0,
};

const card_titles = [Today.card_count][]const u8{ "Screen time", "Focus", "Breaks", "Streak" };
const weekday_names = [7][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };

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
/// the terminal to end it, as an idle window waits: for the file watch
/// (and local midnight, when Today becomes a new day), or a poll once a
/// second without one.
pub fn waitAt(state: *const State, now_ms: i64) ?f64 {
    const shown = focus.State.view(state.wb.timer(), state.wb.option.focus, now_ms);
    const tick_ms = shown.msUntilTick();
    if (tick_ms != std.math.maxInt(u64) and shown.remaining_ms > 0) {
        return @as(f64, @floatFromInt(@min(tick_ms, std.time.ms_per_s))) / std.time.ms_per_s;
    }
    if (state.watch) |watch| {
        if (watch.isAlive()) {
            const now_s = @divFloor(now_ms, std.time.ms_per_s);
            return @floatFromInt(@max(1, state.midnight_utc_s - now_s));
        }
    }
    return 1;
}

/// Picks up another process's save. True when the timer or the shown time
/// changed. A wake from the watch reads the file at once; any other wake
/// (input, the timeout) polls, at most once a second.
pub fn wake(state: *State) bool {
    const timer_before = state.wb.timer();
    const shown_before = state.shown;
    const today_before = state.today_revision;
    const changed = if (state.watch) |watch| watch.takeChanged() else false;
    const mode: wellbeing.Wellbeing.SyncMode = if (changed) .changed else .poll;
    state.wb.sync(state.io, state.state_dir, wallSeconds(state.io), mode) catch |err| {
        log.err("cannot read wellbeing state: {t}", .{err});
    };
    refresh(state);
    if (!std.meta.eql(timer_before, state.wb.timer())) return true;
    return !shownEql(&shown_before, &state.shown) or state.today_revision != today_before;
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
        .today => try todayPage(state, tree, theme),
        .history => {},
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

/// Room between cards, and around the page under the header.
const card_gap = 16;

fn cardBox(theme: *const Theme, height: kit.tree.Size, gap: u8) kit.tree.Box {
    return .{
        .width = .fill,
        .height = height,
        .padding = .all(16),
        .gap = gap,
        .fill = theme.card,
        .border = theme.border,
        .border_width = Theme.border_width,
        .radius = Theme.radius,
    };
}

fn todayPage(state: *const State, tree: *Tree, theme: *const Theme) kit.tree.Error!void {
    const page = try tree.open(.{
        .width = .fill,
        .height = .fill,
        .padding = .{ .left = 24, .right = 24, .top = 4, .bottom = 24 },
        .gap = card_gap,
    });
    const cards = try tree.open(.{ .axis = .row, .width = .fill, .gap = card_gap });
    for (&state.today.cards, card_titles, 0..) |*card, card_title, index| {
        const fill = switch (index) {
            0 => if (card.over) theme.destructive else theme.primary,
            else => theme.info,
        };
        try statCard(tree, theme, card_title, card, fill);
    }
    tree.close(cards);
    // Three fifths and two fifths; the gap is padding inside the first.
    const lower = try tree.open(.{ .axis = .row, .width = .fill, .height = .fill });
    const left = try tree.open(.{ .width = .{ .fraction = 0.6 }, .height = .fill, .padding = .{ .right = card_gap } });
    try weekCard(state, tree, theme);
    tree.close(left);
    const right = try tree.open(.{ .width = .{ .fraction = 0.4 }, .height = .fill });
    try programsCard(state, tree, theme, "Programs today");
    tree.close(right);
    tree.close(lower);
    tree.close(page);
}

fn statCard(tree: *Tree, theme: *const Theme, card_title: []const u8, card: *const Card, fill: Theme.Color) kit.tree.Error!void {
    const box = try tree.open(cardBox(theme, .fit, 6));
    _ = try tree.text(card_title, .{ .color = theme.muted_foreground, .style = .xs });
    _ = try tree.text(card.value.slice(), .{ .color = theme.foreground, .style = .xl_semibold, .figures = .tabular });
    if (card.fraction < 0) {
        _ = try tree.leaf(.{ .height = .{ .fixed = chart.thickness } });
    } else {
        try chart.progress(tree, theme, .bar, card.fraction, fill);
    }
    _ = try tree.text(card.note.slice(), .{ .color = theme.muted_foreground, .style = .xs });
    tree.close(box);
}

/// A swatch and its name.
fn legend(tree: *Tree, theme: *const Theme, label: []const u8, color: Theme.Color) kit.tree.Error!void {
    const item = try tree.open(.{ .axis = .row, .gap = 6, .cross = .center });
    _ = try tree.leaf(.{ .width = .{ .fixed = 8 }, .height = .{ .fixed = 8 }, .fill = color, .radius = 2 });
    _ = try tree.text(label, .{ .color = theme.muted_foreground, .style = .xs });
    tree.close(item);
}

fn screenFill(theme: *const Theme) Theme.Color {
    return theme.chart[theme.chart.len - 1];
}

fn weekCard(state: *const State, tree: *Tree, theme: *const Theme) kit.tree.Error!void {
    const box = try tree.open(cardBox(theme, .fill, 12));
    const head = try tree.open(.{ .axis = .row, .width = .fill, .gap = 12, .cross = .center });
    _ = try tree.text("This week", .{ .color = theme.foreground, .style = .sm_medium });
    _ = try tree.leaf(.{ .width = .fill });
    try legend(tree, theme, "Screen", screenFill(theme));
    try legend(tree, theme, "Focus", theme.info);
    tree.close(head);

    const today = &state.today;
    var items: [week_days]chart.Day = undefined;
    for (&items, &today.week) |*item, day| {
        const past_limit = today.limit_s != 0 and day.screen_s > today.limit_s;
        item.* = .{
            .total = @floatFromInt(day.screen_s),
            .part = @floatFromInt(day.focus_s),
            .fill = if (past_limit) theme.destructive.alpha(30) else screenFill(theme),
            .part_fill = theme.info,
        };
    }
    const area = try tree.open(.{ .width = .fill, .height = .fill });
    try chart.days(tree, theme, .bar, &items, if (today.limit_s == 0) null else @floatFromInt(today.limit_s));
    tree.close(area);

    const labels = try tree.open(.{ .axis = .row, .width = .fill, .gap = Theme.space });
    for (0..week_days) |index| {
        const last = index + 1 == week_days;
        const weekday = (today.weekday + 7 - (week_days - 1 - index)) % 7;
        const cell = try tree.open(.{ .width = .fill, .cross = .center });
        _ = try tree.text(if (last) "Today" else weekday_names[weekday], .{
            .color = if (last) theme.foreground else theme.muted_foreground,
            .style = .xs,
        });
        tree.close(cell);
    }
    tree.close(labels);
    tree.close(box);
}

fn programsCard(state: *const State, tree: *Tree, theme: *const Theme, card_title: []const u8) kit.tree.Error!void {
    const box = try tree.open(cardBox(theme, .fill, 12));
    _ = try tree.text(card_title, .{ .color = theme.foreground, .style = .sm_medium });
    const today = &state.today;
    const rows = today.programs[0..today.program_count];
    if (rows.len == 0) {
        const empty = if (state.wb.option.screen_time.track_foreground_apps) "No programs recorded yet" else "Program tracking is off";
        _ = try tree.text(empty, .{ .color = theme.muted_foreground });
        tree.close(box);
        return;
    }
    var parts: [program_rows]chart.Part = undefined;
    for (parts[0..rows.len], rows, 0..) |*part, row, index| {
        part.* = .{ .label = row.name.slice(), .value = @floatFromInt(row.seconds), .fill = theme.chart[index] };
    }
    const mark: chart.ShareMark = switch (state.charts.program_chart) {
        .bar => .bar,
        .donut => .donut,
    };
    const holder = try tree.open(.{ .width = .fill, .cross = .center });
    try chart.share(tree, theme, mark, parts[0..rows.len]);
    tree.close(holder);

    const list = try tree.open(.{ .width = .fill, .gap = 8 });
    for (rows, 0..) |*row, index| {
        const line = try tree.open(.{ .axis = .row, .width = .fill, .gap = 8, .cross = .center });
        _ = try tree.leaf(.{ .width = .{ .fixed = 8 }, .height = .{ .fixed = 8 }, .fill = theme.chart[index], .radius = 2 });
        _ = try tree.text(row.name.slice(), .{ .color = theme.foreground, .width = .fill });
        _ = try tree.text(row.time.slice(), .{ .color = theme.muted_foreground, .figures = .tabular });
        const share_box = try tree.open(.{ .width = .{ .fixed = 36 }, .cross = .end });
        _ = try tree.text(row.share.slice(), .{ .color = theme.muted_foreground, .figures = .tabular });
        tree.close(share_box);
        tree.close(line);
    }
    tree.close(list);
    tree.close(box);
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

/// Recomputes the Today page when the records or the local day changed
/// since the last time.
fn refreshToday(state: *State, now_ms: i64) void {
    const utc_s = @divFloor(now_ms, std.time.ms_per_s);
    const local_s = state.local_clock.localSeconds(utc_s);
    const day = wellbeing.merge.localDay(local_s);
    state.midnight_utc_s = utc_s + (@as(i64, day) + 1) * std.time.s_per_day - local_s;
    const data = &state.wb.data;
    const current: TodayKey = .{ .last_write_utc_s = data.last_write_utc_s, .generation = data.generation, .day = day };
    if (std.meta.eql(current, state.today_key) and state.today_revision != 0) return;
    state.today_key = current;
    state.today_revision +%= 1;
    computeToday(&state.today, data, &state.wb.option, day);
}

/// A day's record from the file, or an empty one when none was kept.
fn record(data: *const wellbeing.storage.PersistentData, day: u32) wellbeing.storage.DayRecord {
    if (data.today.day == day) return data.today;
    for (data.history[0..data.history_count]) |entry| {
        if (entry.day == day) return entry;
    }
    return .{ .day = day };
}

pub fn computeToday(today: *Today, data: *const wellbeing.storage.PersistentData, option: *const wellbeing.Option, day: u32) void {
    const now = record(data, day);
    const limit_s: u32 = if (option.screen_time.daily_limit_ms) |ms| @intCast(@min(ms / std.time.ms_per_s, std.math.maxInt(u32))) else 0;
    today.limit_s = limit_s;

    const screen = &today.cards[0];
    screen.value.duration(now.active_screen_s);
    screen.over = limit_s != 0 and now.active_screen_s > limit_s;
    if (limit_s == 0) {
        screen.fraction = -1;
        screen.note.set("No daily limit", .{});
    } else {
        screen.fraction = @as(f32, @floatFromInt(now.active_screen_s)) / @as(f32, @floatFromInt(limit_s));
        var limit: Label(12) = .{};
        limit.duration(limit_s);
        if (screen.over) {
            var past: Label(12) = .{};
            past.duration(now.active_screen_s - limit_s);
            screen.note.set("{s} over the {s} limit", .{ past.slice(), limit.slice() });
        } else {
            screen.note.set("of {s} limit", .{limit.slice()});
        }
    }

    const focused = &today.cards[1];
    focused.value.duration(now.focus_s);
    if (now.active_screen_s == 0) {
        focused.fraction = 0;
        focused.note.set("No screen time yet", .{});
    } else {
        const share = @min(1, @as(f32, @floatFromInt(now.focus_s)) / @as(f32, @floatFromInt(now.active_screen_s)));
        focused.fraction = share;
        focused.note.set("{d}% of screen time", .{@as(u32, @intFromFloat(@round(share * 100)))});
    }

    const breaks = &today.cards[2];
    breaks.value.set("{d}", .{@as(u32, now.eyesight_breaks) + now.movement_breaks});
    breaks.fraction = -1;
    breakNote(&breaks.note, data, option);

    const streak = &today.cards[3];
    streak.value.set("{d} {s}", .{ data.current_streak, if (data.current_streak == 1) "day" else "days" });
    streak.fraction = -1;
    streak.note.set("{d} {s} today", .{ now.tasks_completed, if (now.tasks_completed == 1) "task" else "tasks" });

    for (&today.week, 0..) |*entry, index| {
        const offset: u32 = @intCast(week_days - 1 - index);
        const past = day -| offset;
        const rec = if (day >= offset) record(data, past) else wellbeing.storage.DayRecord{};
        entry.* = .{ .screen_s = rec.active_screen_s, .focus_s = rec.focus_s };
    }
    // Day 0 of the epoch was a Thursday.
    today.weekday = @intCast((day + 4) % 7);

    computePrograms(today, &now);
}

/// "next eye break in 12m": the eyesight reminder, else the movement
/// one. The shared active clock moves with each terminal's save, so this
/// is as fresh as the last save.
fn breakNote(note: *Label(40), data: *const wellbeing.storage.PersistentData, option: *const wellbeing.Option) void {
    const Reminder = struct { enabled: bool, interval_ms: u64, due_s: u64, name: []const u8 };
    const choices = [_]Reminder{
        .{ .enabled = option.eyesight.enabled, .interval_ms = option.eyesight.interval_ms, .due_s = data.eyesight_due_s, .name = "eye" },
        .{ .enabled = option.movement.enabled, .interval_ms = option.movement.interval_ms, .due_s = data.movement_due_s, .name = "movement" },
    };
    for (choices) |reminder| {
        if (!reminder.enabled) continue;
        const interval_s = @max(1, reminder.interval_ms / std.time.ms_per_s);
        var in: Label(12) = .{};
        if (reminder.due_s == 0) {
            in.duration(interval_s);
            note.set("{s} breaks every {s}", .{ reminder.name, in.slice() });
        } else {
            const left_s = (reminder.due_s + interval_s) -| data.activeClock();
            if (left_s < std.time.s_per_min) {
                note.set("{s} break due now", .{reminder.name});
            } else {
                in.duration(left_s);
                note.set("next {s} break in {s}", .{ reminder.name, in.slice() });
            }
        }
        return;
    }
    note.set("Reminders are off", .{});
}

/// The day's programs by time, largest first: four by name, the rest as
/// one row.
fn computePrograms(today: *Today, day: *const wellbeing.storage.DayRecord) void {
    var order: [wellbeing.storage.max_top_apps]u8 = undefined;
    var count: usize = 0;
    var total: u64 = 0;
    for (day.top_apps, 0..) |app, index| {
        if (app.seconds == 0 or app.getName().len == 0) continue;
        order[count] = @intCast(index);
        count += 1;
        total += app.seconds;
    }
    const Less = struct {
        fn less(apps: *const [wellbeing.storage.max_top_apps]wellbeing.storage.AppUsage, a: u8, b: u8) bool {
            return apps[a].seconds > apps[b].seconds;
        }
    };
    std.mem.sort(u8, order[0..count], &day.top_apps, Less.less);

    var rows: u8 = 0;
    var rest: u64 = 0;
    for (order[0..count], 0..) |index, rank| {
        const app = day.top_apps[index];
        if (rank < program_names) {
            const row = &today.programs[rows];
            row.name.set("{s}", .{app.getName()});
            row.seconds = app.seconds;
            rows += 1;
        } else rest += app.seconds;
    }
    if (rest > 0) {
        const row = &today.programs[rows];
        row.name.set("Other", .{});
        row.seconds = @intCast(rest);
        rows += 1;
    }
    for (today.programs[0..rows]) |*row| {
        row.time.duration(row.seconds);
        const percent = if (total == 0) 0 else (@as(u64, row.seconds) * 100 + total / 2) / total;
        row.share.set("{d}%", .{percent});
    }
    today.program_count = rows;
}

/// As the terminal shows the timer: an idle timer shows a full task, a
/// waiting one the next phase in full, and with `timer = countdown` a
/// second still partly left counts as a whole one.
pub fn refreshAt(state: *State, now_ms: i64) void {
    refreshToday(state, now_ms);
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
