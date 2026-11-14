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
const tooltip = kit.tooltip;
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

pub const Menu = enum(u8) { closed, more, view };

const ColorScheme = @FieldType(@import("../config/Config.zig").Ui, "color_scheme");
const scheme_labels = [_][]const u8{ "Auto", "Dark", "Light" };

/// Below this width the four cards take two rows; below `narrow_width` the
/// timer chip hides and the page scrolls, the chart and programs cards one
/// over the other at their own heights.
const compact_width = 720;
const narrow_width = 560;

/// How many days History shows.
pub const Period = enum(u8) {
    week,
    fortnight,

    pub fn days(self: Period) u8 {
        return switch (self) {
            .week => 7,
            .fortnight => history_days,
        };
    }

    fn label(self: Period) []const u8 {
        return switch (self) {
            .week => "7 days",
            .fortnight => "14 days",
        };
    }
};

const period_count = @typeInfo(Period).@"enum".fields.len;

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
    period: Period,
    /// A History column, by its index among the days shown.
    day: u8,
    gear: void,
    timer_chart: TimerChart,
    program_chart: ProgramChart,
};

const TimerChart = @TypeOf(@as(DashboardOption, undefined).timer_chart);
const ProgramChart = @TypeOf(@as(DashboardOption, undefined).program_chart);

const tab_id = Id.of("wellbeing.tab");
const chip_id = Id.of("wellbeing.chip");
const toggle_id = Id.of("wellbeing.toggle");
const skip_id = Id.of("wellbeing.skip");
const more_id = Id.of("wellbeing.more");
const reset_id = Id.of("wellbeing.reset");
const layer_id = Id.of("wellbeing.layer");
const period_id = Id.of("wellbeing.period");
const day_id = Id.of("wellbeing.day");
const gear_id = Id.of("wellbeing.gear");
const timer_chart_id = Id.of("wellbeing.timer_chart");
const program_chart_id = Id.of("wellbeing.program_chart");
const scheme_id = Id.of("wellbeing.scheme");

fn over(id: Id) Over {
    if (id == chip_id) return .chip;
    if (id == toggle_id) return .toggle;
    if (id == skip_id) return .skip;
    if (id == more_id) return .more;
    if (id == reset_id) return .reset;
    if (id == layer_id) return .outside;
    if (id == gear_id) return .gear;
    inline for (0..2) |index| {
        if (id == timer_chart_id.item(index)) return .{ .timer_chart = @enumFromInt(index) };
        if (id == program_chart_id.item(index)) return .{ .program_chart = @enumFromInt(index) };
    }
    inline for (0..page_count) |index| {
        if (id == tab_id.item(index)) return .{ .tab = @enumFromInt(index) };
    }
    inline for (0..period_count) |index| {
        if (id == period_id.item(index)) return .{ .period = @enumFromInt(index) };
    }
    for (0..history_days) |index| {
        if (id == day_id.item(@intCast(index))) return .{ .day = @intCast(index) };
    }
    return .none;
}

/// The frame: the root, the header, the tab list, the spacer and the
/// timer chip (its box, dot, time and phase).
/// The frame: the root, the header, the tab list, the spacer, and on the
/// right Today's group (box, chip of four, gear) or History's switch.
const frame_nodes = 3 + tabs.nodeMax(page_count) + 1 + @as(usize, @max(1 + 4 + button.node_max, tabs.nodeMax(period_count)));
/// The card rows' outer column and up to two rows.
const card_rows_nodes = 3;
/// The gear's popup: layer and card, the column, three groups (box,
/// label, tabs), the rule, the settings row (row, text, icon) and the note.
const choices_nodes = popup.node_max + 1 + 2 * (2 + tabs.nodeMax(2)) + (2 + tabs.nodeMax(scheme_labels.len)) + 1 + 3 + 1;
/// The Focus page: its column, the timer block (label, time, task line and
/// the larger of the two marks: a bar, or a ring in its square under an
/// overlaid column), the button row and three buttons, and the popup with
/// its one item.
const focus_nodes = 1 + 1 + 3 + 6 + 1 + 3 * button.node_max + popup.node_max + popup.item_node_max;

/// The Today page: its column, the card row and four stat cards (box,
/// title, value, bar or spacer, note), the lower row and its two slots,
/// the week card and the programs card.
/// A stat card: box, title, value, bar or spacer, and the note, or the
/// note's row with the delta and the note.
const stat_card_nodes = 4 + chart.progress_nodes + 2;
const today_nodes = 1 + card_rows_nodes + 4 * stat_card_nodes + 1 + 2 + week_nodes + programs_nodes + choices_nodes;
/// Card, header row, title, spacer, two legend items (row, swatch, text),
/// the chart's column, the bars, and the label row with a box and text
/// per day.
const week_nodes = daysNodes(week_days);
/// Card, header row, title, spacer, three legend items (row, swatch,
/// text), the chart's column, the bars, and the label row with a box and
/// text per day.
fn daysNodes(comptime count: usize) usize {
    return 4 + 3 * 3 + 1 + chart.dayNodes(count) + 1 + count * 2;
}
/// The History page: like Today with cards of three nodes and no bar, two
/// weeks of days, and the tooltip (card, column, three lines).
const history_nodes = 1 + card_rows_nodes + 4 * stat_card_nodes + 1 + 2 + daysNodes(history_days) + programs_nodes + 5;
/// Card, title, the chart's box and the larger mark, the list and a row
/// per program (row, swatch, name, time, share box and share); or one
/// line when there are none.
const programs_nodes = 2 + 1 + @as(usize, @max(chart.shareNodes(program_rows), chart.donutNodes(program_rows))) + 1 + program_rows * 6;

pub const node_max = frame_nodes + @as(usize, @max(focus_nodes, @max(today_nodes, history_nodes)));
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
    /// The open popup, if any: Focus's "more" menu, which holds Reset, or
    /// the gear's view choices.
    menu: Menu = .closed,
    /// The config's `[ui] color_scheme`, shown in the view choices; the
    /// host picks the theme from it at start.
    scheme: ColorScheme,
    /// In logical pixels, from the last `size` event.
    width: f32 = 0,
    /// How far a narrow page is scrolled, 0 to the last `max` the host
    /// sent; 0 again on another page.
    scroll: f32 = 0,
    /// What `refresh` last computed from the timer.
    shown: Shown = .{},
    /// What `refresh` last computed from the day's records.
    today: Today = .{},
    period: Period = .week,
    history: History = .{},
    tip: Tip = .{},
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
    week: [week_days]DaySummary = @splat(.{}),
    /// Today's day of the week, 0 for Sunday.
    weekday: u8 = 0,
    /// The daily limit in seconds; 0 for none.
    limit_s: u32 = 0,
    /// "6h limit", for the chart's legend.
    limit_label: Label(16) = .{},
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
    /// "↓ 34m": the change from the period before, drawn before `note` in
    /// the color of `trend`. Empty for none.
    delta: Label(16) = .{},
    note: Label(40) = .{},
    /// Of the bar under the value, 0 to 1; negative for no bar.
    fraction: f32 = -1,
    /// Past the daily limit: the value and its bar turn `destructive`.
    over: bool = false,
    trend: Trend = .even,
};

/// Whether a change is good news: less screen time, more focus.
pub const Trend = enum(u8) { better, worse, even };

pub const DaySummary = struct {
    screen_s: u32 = 0,
    focus_s: u32 = 0,
    tasks: u16 = 0,
    breaks: u16 = 0,

    fn of(rec: wellbeing.storage.DayRecord) DaySummary {
        return .{
            .screen_s = rec.active_screen_s,
            .focus_s = rec.focus_s,
            .tasks = rec.tasks_completed,
            .breaks = rec.eyesight_breaks +| rec.movement_breaks,
        };
    }
};

const history_days = 14;

/// The History page as `refresh` last computed it, for `State.period`.
pub const History = struct {
    cards: [Today.card_count]Card = @splat(.{}),
    /// Oldest first; the last is today. The page shows the last
    /// `Period.days`.
    days: [history_days]DaySummary = @splat(.{}),
    /// Today's day of the week, 0 for Sunday, and its local day number.
    weekday: u8 = 0,
    day: u32 = 0,
    programs: [program_rows]Program = @splat(.{}),
    program_count: u8 = 0,
};

/// The tooltip of the History column under the pointer.
pub const Tip = struct {
    title: Label(32) = .{},
    time: Label(40) = .{},
    counts: Label(32) = .{},
};

const history_card_titles = [Today.card_count][]const u8{ "Screen time a day", "Focus a day", "Over the limit", "Breaks" };
const weekday_long = [7][]const u8{ "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" };
const month_names = [12][]const u8{ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" };

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
        .scheme = context.config.ui.color_scheme,
    };
    // Off, the window says so and leaves the state file alone.
    if (!state.wb.option.enabled) return state;
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
    if (!state.wb.option.enabled) return null;
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
    const period = state.period;
    const charts = state.charts;
    const width = state.width;
    const scrolled = state.scroll;
    const timer_changed = switch (event) {
        .size => |size| blk: {
            state.width = size.width;
            break :blk false;
        },
        .pointer => |id| blk: {
            state.hover = over(id);
            refreshTip(state);
            break :blk false;
        },
        .press => |id| blk: {
            const target = over(id);
            // Like a dialog's scrim, a press beside the menu closes it at once.
            if (state.menu != .closed and target == .outside) {
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
        .scroll => |wheel| blk: {
            state.scroll = std.math.clamp(state.scroll + wheel.dy, 0, wheel.max);
            break :blk false;
        },
    };
    if (state.page != page) state.scroll = 0;
    return timer_changed or state.page != page or state.period != period or
        !std.meta.eql(state.charts, charts) or state.width != width or state.scroll != scrolled or
        !std.meta.eql(state.hover, hover) or !std.meta.eql(state.pressed, pressed) or state.menu != menu;
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
        .period => |period| {
            state.period = period;
            refreshHistory(state);
            return false;
        },
        .day => return false,
        .more => {
            state.menu = if (state.menu == .more) .closed else .more;
            return false;
        },
        .gear => {
            state.menu = if (state.menu == .view) .closed else .view;
            return false;
        },
        .timer_chart => |mark| {
            state.charts.timer_chart = mark;
            return false;
        },
        .program_chart => |mark| {
            state.charts.program_chart = mark;
            return false;
        },
        .toggle, .skip, .reset => if (!state.wb.option.enabled) return false,
    }
    switch (target) {
        .toggle => state.wb.toggleFocus(now_ms),
        .skip => state.wb.skipFocus(now_ms),
        .reset => {
            state.menu = .closed;
            state.wb.resetFocus(now_ms);
        },
        else => unreachable, // handled above
    }
    state.wb.sync(state.io, state.state_dir, wallSeconds(state.io), .merge) catch |err| {
        log.err("cannot save wellbeing state: {t}", .{err});
    };
    refresh(state);
    return true;
}

pub fn view(state: *const State, tree: *Tree, theme: *const Theme) kit.tree.Error!void {
    if (!state.wb.option.enabled) return offPage(tree, theme);
    const root = try tree.open(.{ .width = .fill, .height = .fill });
    try header(state, tree, theme);
    switch (state.page) {
        .today => try todayPage(state, tree, theme),
        .history => try historyPage(state, tree, theme),
        .focus => try focusPage(state, tree, theme),
    }
    tree.close(root);

    if (state.page == .history) switch (state.hover) {
        .day => |index| try dayTooltip(state, tree, theme, index),
        else => {},
    };

    if (state.page == .today and state.menu == .view) try viewChoices(state, tree, theme);
    if (state.page == .focus and state.menu == .more) {
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
/// Thickness of a stat card's bar, and of the space a card without one
/// keeps in its place.
const card_bar = 4;

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
    const page = try pageBox(state, tree);
    var rows = try CardRows.begin(tree, state.width);
    for (&state.today.cards, card_titles, 0..) |*card, card_title, index| {
        const fill = switch (index) {
            0 => if (card.over) theme.destructive else theme.primary,
            else => theme.info,
        };
        try rows.next(tree, index);
        try statCard(tree, theme, card_title, card, fill, true);
    }
    rows.end(tree);
    var lower = try LowerRow.begin(tree, isNarrow(state.width));
    try daysCard(tree, theme, .{
        .card_title = "This week",
        .height = lower.chartHeight(),
        .days = &state.today.week,
        .weekday = state.today.weekday,
        .limit_s = state.today.limit_s,
        .limit_label = state.today.limit_label.slice(),
    });
    try lower.middle(tree);
    try programsCard(state, tree, theme, "Programs today", state.today.programs[0..state.today.program_count], lower.programsHeight());
    lower.end(tree);
    tree.close(page);
}

/// The four stat cards: one row, or two rows of two below `compact_width`.
const CardRows = struct {
    outer: kit.tree.Index,
    row: kit.tree.Index,
    per_row: u8,

    fn begin(tree: *Tree, width: f32) kit.tree.Error!CardRows {
        const per_row: u8 = if (width > 0 and width < compact_width) 2 else Today.card_count;
        const outer = try tree.open(.{ .width = .fill, .gap = card_gap });
        return .{ .outer = outer, .row = kit.tree.none, .per_row = per_row };
    }

    fn next(self: *CardRows, tree: *Tree, index: usize) kit.tree.Error!void {
        if (index % self.per_row != 0) return;
        if (self.row != kit.tree.none) tree.close(self.row);
        self.row = try tree.open(.{ .axis = .row, .width = .fill, .gap = card_gap });
    }

    fn end(self: *CardRows, tree: *Tree) void {
        if (self.row != kit.tree.none) tree.close(self.row);
        tree.close(self.outer);
    }
};

/// The chart card and the programs card: three fifths and two fifths side
/// by side, or, on a narrow page that scrolls, one over the other at their
/// own heights. Side by side, the gap is padding inside the first slot, so
/// the fractions add up.
const LowerRow = struct {
    outer: kit.tree.Index,
    first: kit.tree.Index,
    second: kit.tree.Index = kit.tree.none,
    stacked: bool,

    fn begin(tree: *Tree, stacked: bool) kit.tree.Error!LowerRow {
        const outer = try tree.open(if (stacked)
            .{ .width = .fill, .gap = card_gap }
        else
            .{ .axis = .row, .width = .fill, .height = .fill });
        const first = try tree.open(if (stacked)
            .{ .width = .fill }
        else
            .{ .width = .{ .fraction = 0.6 }, .height = .fill, .padding = .{ .right = card_gap } });
        return .{ .outer = outer, .first = first, .stacked = stacked };
    }

    fn middle(self: *LowerRow, tree: *Tree) kit.tree.Error!void {
        tree.close(self.first);
        self.second = try tree.open(if (self.stacked)
            .{ .width = .fill }
        else
            .{ .width = .{ .fraction = 0.4 }, .height = .fill });
    }

    fn end(self: *const LowerRow, tree: *Tree) void {
        tree.close(self.second);
        tree.close(self.outer);
    }

    /// The chart card's height: the slot's, or its own when stacked.
    fn chartHeight(self: *const LowerRow) kit.tree.Size {
        return if (self.stacked) .{ .fixed = stacked_chart_height } else .fill;
    }

    fn programsHeight(self: *const LowerRow) kit.tree.Size {
        return if (self.stacked) .fit else .fill;
    }
};

/// The chart card's height when the cards stack.
const stacked_chart_height = 280;

/// A page's column under the header. A narrow one is the scroll region.
fn pageBox(state: *const State, tree: *Tree) kit.tree.Error!kit.tree.Index {
    const narrow = isNarrow(state.width);
    const page = try tree.open(.{
        .width = .fill,
        .height = .fill,
        .padding = .{ .left = 24, .right = 24, .top = 4, .bottom = 24 },
        .gap = card_gap,
        .overflow = if (narrow) .clip else .visible,
    });
    if (narrow) tree.scrollRegion(page, state.scroll);
    return page;
}

fn isNarrow(width: f32) bool {
    return width > 0 and width < narrow_width;
}

/// With `[wellbeing] enabled = false`: one message, nothing that writes.
fn offPage(tree: *Tree, theme: *const Theme) kit.tree.Error!void {
    const page = try tree.open(.{ .width = .fill, .height = .fill, .padding = .all(24), .gap = 8, .main = .center, .cross = .center });
    _ = try tree.text("Wellbeing is off", .{ .color = theme.foreground, .style = .lg_semibold });
    _ = try tree.text("Turn it on with enabled = true under [wellbeing] in the config file.", .{ .color = theme.muted_foreground });
    tree.close(page);
}

/// The gear's popup: the chart looks, the color scheme, and the way to the
/// settings window.
fn viewChoices(state: *const State, tree: *Tree, theme: *const Theme) kit.tree.Error!void {
    const card = try popup.open(tree, theme, .{ .layer_id = layer_id, .anchor = gear_id });
    const column = try tree.open(.{ .width = .{ .fixed = 252 }, .padding = .all(8), .gap = 12 });

    const timer_tabs = [_]tabs.Tab{ .{ .id = timer_chart_id.item(0), .label = "Bar" }, .{ .id = timer_chart_id.item(1), .label = "Ring" } };
    try choiceGroup(tree, theme, "Timer", &timer_tabs, @intFromEnum(state.charts.timer_chart), switch (state.hover) {
        .timer_chart => |mark| @intFromEnum(mark),
        else => tabs.none,
    });
    const program_tabs = [_]tabs.Tab{ .{ .id = program_chart_id.item(0), .label = "Bar" }, .{ .id = program_chart_id.item(1), .label = "Donut" } };
    try choiceGroup(tree, theme, "Programs", &program_tabs, @intFromEnum(state.charts.program_chart), switch (state.hover) {
        .program_chart => |mark| @intFromEnum(mark),
        else => tabs.none,
    });
    var scheme_tabs: [scheme_labels.len]tabs.Tab = undefined;
    for (&scheme_tabs, scheme_labels, 0..) |*tab, label, index| tab.* = .{ .id = scheme_id.item(@intCast(index)), .label = label };
    try choiceGroup(tree, theme, "Color scheme", &scheme_tabs, @intFromEnum(state.scheme), tabs.none);

    _ = try tree.leaf(.{ .width = .fill, .height = .{ .fixed = 1 }, .fill = theme.border });
    const settings = try tree.open(.{ .axis = .row, .width = .fill, .height = .{ .fixed = Theme.control_sm }, .padding = .symmetric(8, 0), .cross = .center });
    _ = try tree.text("Wellbeing settings\u{2026}", .{ .color = theme.muted_foreground, .width = .fill });
    _ = try tree.icon(.{ .codepoint = icons.external_link, .color = theme.muted_foreground, .size = button.icon_size });
    tree.close(settings);
    _ = try tree.text("Chart choices last until the window closes; the color scheme and saved choices come from the config file.", .{
        .color = theme.muted_foreground,
        .style = .xs,
        .width = .fill,
    });
    tree.close(column);
    popup.close(tree, card);
}

fn choiceGroup(tree: *Tree, theme: *const Theme, label: []const u8, list: []const tabs.Tab, current: u8, hovered: u8) kit.tree.Error!void {
    const group = try tree.open(.{ .width = .fill, .gap = 6 });
    _ = try tree.text(label, .{ .color = theme.muted_foreground, .style = .xs });
    try tabs.view(tree, theme, .{ .tabs = list, .current = current, .hovered = hovered });
    tree.close(group);
}

fn statCard(tree: *Tree, theme: *const Theme, card_title: []const u8, card: *const Card, fill: Theme.Color, with_bar: bool) kit.tree.Error!void {
    // `fill` across the row: every card in a row is as tall as the tallest.
    const box = try tree.open(cardBox(theme, .fill, if (with_bar) 6 else 4));
    _ = try tree.text(card_title, .{ .color = theme.muted_foreground, .style = .xs });
    _ = try tree.text(card.value.slice(), .{
        .color = if (card.over) theme.destructive else theme.foreground,
        .style = .xl_semibold,
        .figures = .tabular,
    });
    if (with_bar) {
        if (card.fraction < 0) {
            _ = try tree.leaf(.{ .height = .{ .fixed = card_bar } });
        } else {
            try chart.progress(tree, theme, .bar, card.fraction, fill, card_bar);
        }
    }
    if (card.delta.len == 0) {
        _ = try tree.text(card.note.slice(), .{ .color = theme.muted_foreground, .style = .xs });
    } else {
        const line = try tree.open(.{ .axis = .row, .gap = 4, .cross = .center });
        _ = try tree.text(card.delta.slice(), .{
            .color = switch (card.trend) {
                .better => theme.success,
                .worse => theme.destructive,
                .even => theme.muted_foreground,
            },
            .style = .sm_medium,
            .figures = .tabular,
        });
        _ = try tree.text(card.note.slice(), .{ .color = theme.muted_foreground, .style = .xs });
        tree.close(line);
    }
    tree.close(box);
}

/// A swatch and its name.
fn legend(tree: *Tree, theme: *const Theme, label: []const u8, color: Theme.Color) kit.tree.Error!void {
    const item = try tree.open(.{ .axis = .row, .gap = 6, .cross = .center });
    _ = try tree.leaf(.{ .width = .{ .fixed = 8 }, .height = .{ .fixed = 8 }, .fill = color, .radius = 2 });
    _ = try tree.text(label, .{ .color = theme.muted_foreground, .style = .xs });
    tree.close(item);
}

/// The limit's hairline and its length, beside the legend.
fn limitLegend(tree: *Tree, theme: *const Theme, label: []const u8) kit.tree.Error!void {
    const item = try tree.open(.{ .axis = .row, .gap = 6, .cross = .center });
    _ = try tree.leaf(.{ .width = .{ .fixed = 12 }, .height = .{ .fixed = 1 }, .fill = theme.muted_foreground });
    _ = try tree.text(label, .{ .color = theme.muted_foreground, .style = .xs });
    tree.close(item);
}

fn screenFill(theme: *const Theme) Theme.Color {
    return theme.chart[theme.chart.len - 1];
}

/// What a day chart shows: the days, oldest first and the last one today,
/// with the limit and, on History, the day under the pointer.
const DayChart = struct {
    card_title: []const u8,
    height: kit.tree.Size,
    days: []const DaySummary,
    /// Today's day of the week, 0 for Sunday.
    weekday: u8,
    limit_s: u32,
    limit_label: []const u8,
    /// Ids on the columns, for hover and the tooltip; `.none` for none.
    ids: Id = .none,
    hovered: ?u8 = null,
};

fn isHovered(hovered: ?u8, index: usize) bool {
    return if (hovered) |h| h == index else false;
}

fn daysCard(tree: *Tree, theme: *const Theme, options: DayChart) kit.tree.Error!void {
    const box = try tree.open(cardBox(theme, options.height, 12));
    const head = try tree.open(.{ .axis = .row, .width = .fill, .gap = 12, .cross = .center });
    _ = try tree.text(options.card_title, .{ .color = theme.foreground, .style = .sm_medium });
    _ = try tree.leaf(.{ .width = .fill });
    try legend(tree, theme, "Screen", screenFill(theme));
    try legend(tree, theme, "Focus", theme.info);
    if (options.limit_s != 0) try limitLegend(tree, theme, options.limit_label);
    tree.close(head);

    var items: [history_days]chart.Day = undefined;
    const shown = items[0..options.days.len];
    for (shown, options.days, 0..) |*item, day, index| {
        const past_limit = options.limit_s != 0 and day.screen_s > options.limit_s;
        item.* = .{
            .id = if (options.ids == .none) .none else options.ids.item(@intCast(index)),
            .slot = if (isHovered(options.hovered, index)) theme.muted else .transparent,
            .total = @floatFromInt(day.screen_s),
            .part = @floatFromInt(day.focus_s),
            .fill = if (past_limit) theme.destructive.alpha(30) else screenFill(theme),
            .part_fill = theme.info,
        };
    }
    const area = try tree.open(.{ .width = .fill, .height = .fill });
    try chart.days(tree, theme, .bar, shown, if (options.limit_s == 0) null else @floatFromInt(options.limit_s));
    tree.close(area);

    const count = options.days.len;
    const labels = try tree.open(.{ .axis = .row, .width = .fill, .gap = Theme.space });
    for (0..count) |index| {
        const last = index + 1 == count;
        const weekday = (options.weekday + 7 * 3 - (count - 1 - index)) % 7;
        const bright = last or isHovered(options.hovered, index);
        const cell = try tree.open(.{ .width = .fill, .cross = .center });
        _ = try tree.text(if (last) "Today" else weekday_names[weekday], .{
            .color = if (bright) theme.foreground else theme.muted_foreground,
            .style = .xs,
        });
        tree.close(cell);
    }
    tree.close(labels);
    tree.close(box);
}

fn programsCard(state: *const State, tree: *Tree, theme: *const Theme, card_title: []const u8, rows: []const Program, height: kit.tree.Size) kit.tree.Error!void {
    const box = try tree.open(cardBox(theme, height, 12));
    _ = try tree.text(card_title, .{ .color = theme.foreground, .style = .sm_medium });
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

fn historyPage(state: *const State, tree: *Tree, theme: *const Theme) kit.tree.Error!void {
    const history = &state.history;
    const page = try pageBox(state, tree);
    var rows = try CardRows.begin(tree, state.width);
    for (&history.cards, history_card_titles, 0..) |*card, card_title, index| {
        try rows.next(tree, index);
        try statCard(tree, theme, card_title, card, theme.info, false);
    }
    rows.end(tree);
    var lower = try LowerRow.begin(tree, isNarrow(state.width));
    const count = state.period.days();
    try daysCard(tree, theme, .{
        .card_title = "Each day",
        .height = lower.chartHeight(),
        .days = history.days[history_days - count ..],
        .weekday = history.weekday,
        .limit_s = state.today.limit_s,
        .limit_label = state.today.limit_label.slice(),
        .ids = day_id,
        .hovered = switch (state.hover) {
            .day => |index| index,
            else => null,
        },
    });
    try lower.middle(tree);
    try programsCard(state, tree, theme, "Where the time went", history.programs[0..history.program_count], lower.programsHeight());
    lower.end(tree);
    tree.close(page);
}

/// The hovered day's date and numbers, anchored to its column.
fn dayTooltip(state: *const State, tree: *Tree, theme: *const Theme, index: u8) kit.tree.Error!void {
    const card = try tooltip.open(tree, theme, day_id.item(index));
    const lines = try tree.open(.{ .padding = .symmetric(2, 4), .gap = 2 });
    _ = try tree.text(state.tip.title.slice(), .{ .color = theme.foreground, .style = .xs });
    _ = try tree.text(state.tip.time.slice(), .{ .color = theme.muted_foreground, .style = .xs, .figures = .tabular });
    _ = try tree.text(state.tip.counts.slice(), .{ .color = theme.muted_foreground, .style = .xs });
    tree.close(lines);
    tooltip.close(tree, card);
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
    switch (state.page) {
        .today => {
            const row_inner = try tree.open(.{ .axis = .row, .gap = 8, .cross = .center });
            if (state.shown.phase != .idle and state.width >= narrow_width) try timerChip(state, tree, theme);
            try button.view(tree, theme, .{
                .id = gear_id,
                .label = "",
                .icon = icons.settings,
                .variant = .ghost,
                .size = .sm,
                .state = if (state.menu == .view) .hovered else buttonState(state, .gear),
            });
            tree.close(row_inner);
        },
        .focus => {},
        .history => {
            var periods: [period_count]tabs.Tab = undefined;
            for (&periods, 0..) |*tab, index| {
                tab.* = .{ .id = period_id.item(@intCast(index)), .label = @as(Period, @enumFromInt(index)).label() };
            }
            try tabs.view(tree, theme, .{
                .tabs = &periods,
                .current = @intFromEnum(state.period),
                .hovered = switch (state.hover) {
                    .period => |period| @intFromEnum(period),
                    else => tabs.none,
                },
            });
        },
    }
    tree.close(row);
}

/// The running timer, on Today: a dot in the phase's color, the time and
/// the phase. A click opens Focus. History has its period switch there.
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
            try chart.progress(tree, theme, .bar, state.shown.fraction, color, 6);
            _ = try tree.text(state.taskLine(), .{ .color = theme.muted_foreground });
            tree.close(block);
        },
        .ring => {
            const side = chart.ring_radius * 2;
            const square = try tree.open(.{ .width = .{ .fixed = side }, .height = .{ .fixed = side } });
            try chart.progress(tree, theme, .ring, state.shown.fraction, color, 6);
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
    _ = try tree.text(phaseLabel(state.shown.phase), .{ .color = phaseTextColor(theme, state.shown.phase), .style = .sm_medium });
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
        .state = if (state.menu == .more) .hovered else buttonState(state, .more),
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

/// The phase's name over the time: lighter than its dot and bar.
fn phaseTextColor(theme: *const Theme, phase: focus.Phase) Theme.Color {
    return switch (phase) {
        .task => theme.info_text,
        .idle, .short_break, .long_break => phaseColor(theme, phase),
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
    computeHistory(&state.history, data, &state.wb.option, day, state.period);
    refreshTip(state);
}

/// For tests: History as of local day `day`.
pub fn refreshHistoryAt(state: *State, day: u32) void {
    state.today_key.day = day;
    computeToday(&state.today, &state.wb.data, &state.wb.option, day);
    refreshHistory(state);
}

fn refreshHistory(state: *State) void {
    computeHistory(&state.history, &state.wb.data, &state.wb.option, state.today_key.day, state.period);
    refreshTip(state);
}

fn refreshTip(state: *State) void {
    const index = switch (state.hover) {
        .day => |index| index,
        else => return,
    };
    const count = state.period.days();
    if (index >= count) return;
    const history = &state.history;
    const back: u32 = count - 1 - index;
    const day = history.day -| back;
    const summary = history.days[history_days - count + index];
    const civil = (std.time.epoch.EpochDay{ .day = day }).calculateYearDay().calculateMonthDay();
    state.tip.title.set("{s}, {d} {s}", .{
        weekday_long[(day + 4) % 7],
        civil.day_index + 1,
        month_names[@intFromEnum(civil.month) - 1],
    });
    var screen: Label(12) = .{};
    var focused: Label(12) = .{};
    screen.duration(summary.screen_s);
    focused.duration(summary.focus_s);
    state.tip.time.set("Screen {s} \u{00b7} Focus {s}", .{ screen.slice(), focused.slice() });
    state.tip.counts.set("{d} {s} \u{00b7} {d} {s}", .{
        summary.tasks,
        if (summary.tasks == 1) "task" else "tasks",
        summary.breaks,
        if (summary.breaks == 1) "break" else "breaks",
    });
}

fn limitSeconds(option: *const wellbeing.Option) u32 {
    const ms = option.screen_time.daily_limit_ms orelse return 0;
    return @intCast(@min(ms / std.time.ms_per_s, std.math.maxInt(u32)));
}

/// Averages over the days in the period that saw any screen time, so a
/// day off does not pull them down. Only the 7-day view compares with the
/// period before: the file keeps 14 days and today.
pub fn computeHistory(history: *History, data: *const wellbeing.storage.PersistentData, option: *const wellbeing.Option, day: u32, period: Period) void {
    history.day = day;
    history.weekday = @intCast((day + 4) % 7);
    for (&history.days, 0..) |*entry, index| {
        const back: u32 = @intCast(history_days - 1 - index);
        entry.* = if (day >= back) .of(record(data, day - back)) else .{};
    }
    const count = period.days();
    const shown = history.days[history_days - count ..];
    const now = average(shown);
    const before: ?Average = switch (period) {
        .week => blk: {
            const earlier = average(history.days[0..week_days]);
            break :blk if (earlier.days == 0) null else earlier;
        },
        .fortnight => null,
    };

    const screen = &history.cards[0];
    screen.value.duration(now.screen_s);
    screen.delta.len = 0;
    screen.over = false;
    if (before) |earlier| {
        change(screen, now.screen_s, earlier.screen_s, false, "from the week before");
    } else if (period == .week) {
        screen.note.set("No earlier week to compare yet", .{});
    } else {
        screen.note.set("over {d} {s} with screen time", .{ now.days, if (now.days == 1) "day" else "days" });
    }

    const focused = &history.cards[1];
    focused.value.duration(now.focus_s);
    const share: u32 = if (now.screen_s == 0) 0 else @intFromFloat(@round(@as(f32, @floatFromInt(now.focus_s)) * 100 / @as(f32, @floatFromInt(now.screen_s))));
    focused.delta.len = 0;
    if (before) |earlier| {
        var share_text: Label(24) = .{};
        share_text.set("\u{00b7} {d}% of screen time", .{share});
        change(focused, now.focus_s, earlier.focus_s, true, share_text.slice());
    } else {
        focused.note.set("{d}% of screen time", .{share});
    }

    const limit_s = limitSeconds(option);
    const over_card = &history.cards[2];
    over_card.over = false;
    if (limit_s == 0) {
        over_card.value.set("\u{2013}", .{});
        over_card.note.set("No daily limit", .{});
    } else {
        var days_over: u32 = 0;
        var worst: ?usize = null;
        for (shown, 0..) |entry, index| {
            if (entry.screen_s <= limit_s) continue;
            days_over += 1;
            if (worst == null or entry.screen_s > shown[worst.?].screen_s) worst = index;
        }
        over_card.value.set("{d} {s}", .{ days_over, if (days_over == 1) "day" else "days" });
        over_card.over = days_over > 0;
        if (worst) |index| {
            var by: Label(12) = .{};
            by.duration(shown[index].screen_s - limit_s);
            const weekday = weekday_long[(history.weekday + 7 * 3 - (count - 1 - index)) % 7];
            over_card.note.set("of {d} \u{00b7} {s}{s}, by {s}", .{ count, if (days_over > 1) "most on " else "", weekday, by.slice() });
        } else {
            over_card.note.set("of {d}", .{count});
        }
    }

    const breaks_card = &history.cards[3];
    var breaks: u32 = 0;
    var screen_s: u64 = 0;
    for (shown) |entry| {
        breaks += entry.breaks;
        screen_s += entry.screen_s;
    }
    if (screen_s == 0) {
        breaks_card.value.set("0", .{});
        breaks_card.note.set("No screen time yet", .{});
    } else {
        const hours = @as(f32, @floatFromInt(screen_s)) / std.time.s_per_hour;
        breaks_card.value.set("{d:.1} an hour", .{@as(f32, @floatFromInt(breaks)) / hours});
        // Whole hours, so the note keeps to one line.
        var screen_text: Label(12) = .{};
        if (screen_s >= std.time.s_per_hour) {
            screen_text.set("{d}h", .{(screen_s + std.time.s_per_hour / 2) / std.time.s_per_hour});
        } else {
            screen_text.duration(screen_s);
        }
        breaks_card.note.set("{d} {s} in {s}", .{ breaks, if (breaks == 1) "break" else "breaks", screen_text.slice() });
    }

    var names: [history_days * wellbeing.storage.max_top_apps]wellbeing.storage.AppUsage = undefined;
    var name_count: usize = 0;
    for (0..count) |index| {
        const back: u32 = @intCast(count - 1 - index);
        if (day < back) continue;
        const rec = record(data, day - back);
        for (rec.top_apps) |app| {
            if (app.seconds == 0) continue;
            const slot = for (names[0..name_count]) |*known| {
                if (std.mem.eql(u8, known.getName(), app.getName())) break known;
            } else blk: {
                names[name_count] = .{ .name = app.name };
                name_count += 1;
                break :blk &names[name_count - 1];
            };
            slot.seconds +|= app.seconds;
        }
    }
    computePrograms(&history.programs, &history.program_count, names[0..name_count]);
}

const Average = struct { screen_s: u32 = 0, focus_s: u32 = 0, days: u32 = 0 };

fn average(days: []const DaySummary) Average {
    var screen: u64 = 0;
    var focused: u64 = 0;
    var used: u32 = 0;
    for (days) |day| {
        if (day.screen_s == 0) continue;
        screen += day.screen_s;
        focused += day.focus_s;
        used += 1;
    }
    if (used == 0) return .{};
    return .{ .screen_s = @intCast(screen / used), .focus_s = @intCast(focused / used), .days = used };
}

/// "↓ 34m from the week before", or "↑ 12m · 34% of screen time".
/// The card's delta ("↑ 12m") and whether it is good news, then `tail`
/// as its note. `more_is_better` is true for focus, false for screen time.
fn change(card: *Card, now: u32, earlier: u32, more_is_better: bool, tail: []const u8) void {
    var amount: Label(12) = .{};
    amount.duration(if (now > earlier) now - earlier else earlier - now);
    if (amount.len == 0 or std.mem.eql(u8, amount.slice(), "0m")) {
        card.delta.set("=", .{});
        card.trend = .even;
    } else {
        card.delta.set("{s} {s}", .{ if (now > earlier) "\u{2191}" else "\u{2193}", amount.slice() });
        card.trend = if ((now > earlier) == more_is_better) .better else .worse;
    }
    card.note.set("{s}", .{tail});
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
    const limit_s = limitSeconds(option);
    today.limit_s = limit_s;
    if (limit_s != 0) {
        var length: Label(12) = .{};
        length.duration(limit_s);
        today.limit_label.set("{s} limit", .{length.slice()});
    }

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
        entry.* = .of(rec);
    }
    // Day 0 of the epoch was a Thursday.
    today.weekday = @intCast((day + 4) % 7);

    computePrograms(&today.programs, &today.program_count, &now.top_apps);
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

/// Programs by time, largest first: four by name, the rest as one row.
fn computePrograms(programs: *[program_rows]Program, program_count: *u8, apps: []const wellbeing.storage.AppUsage) void {
    var order: [history_days * wellbeing.storage.max_top_apps]u8 = undefined;
    var count: usize = 0;
    var total: u64 = 0;
    for (apps, 0..) |app, index| {
        if (app.seconds == 0 or app.getName().len == 0) continue;
        order[count] = @intCast(index);
        count += 1;
        total += app.seconds;
    }
    const Less = struct {
        fn less(list: []const wellbeing.storage.AppUsage, a: u8, b: u8) bool {
            return list[a].seconds > list[b].seconds;
        }
    };
    std.mem.sort(u8, order[0..count], apps, Less.less);

    var rows: u8 = 0;
    var rest: u64 = 0;
    for (order[0..count], 0..) |index, rank| {
        const app = apps[index];
        if (rank < program_names) {
            const row = &programs[rows];
            row.name.set("{s}", .{app.getName()});
            row.seconds = app.seconds;
            rows += 1;
        } else rest += app.seconds;
    }
    if (rest > 0) {
        const row = &programs[rows];
        row.name.set("Other", .{});
        row.seconds = @intCast(@min(rest, std.math.maxInt(u32)));
        rows += 1;
    }
    for (programs[0..rows]) |*row| {
        row.time.duration(row.seconds);
        const percent = if (total == 0) 0 else (@as(u64, row.seconds) * 100 + total / 2) / total;
        row.share.set("{d}%", .{percent});
    }
    program_count.* = rows;
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
