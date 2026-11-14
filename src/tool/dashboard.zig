//! The wellbeing window: one `Wellbeing` joined to the shared state file,
//! and the Today timer. Focus, History and the gear popup are the next
//! slice. The window does not call `tick`; that counts screen time.

const std = @import("std");
const builtin = @import("builtin");

const host = @import("host.zig");
const FileWatch = @import("FileWatch.zig");
const kit = @import("../kit/root.zig");
const wellbeing = @import("../builtin/wellbeing/root.zig");

const button = kit.button;
const Theme = kit.Theme;
const Tree = kit.tree.Tree;
const Id = kit.tree.Id;
const focus = wellbeing.focus;

const log = std.log.scoped(.wellbeing);

pub const name = "wellbeing";
pub const title = "Wellbeing";

const pause_id = Id.of("wellbeing.pause");
const skip_id = Id.of("wellbeing.skip");
const reset_id = Id.of("wellbeing.reset");

pub const node_max = 3 + 3 * button.node_max;
pub const line_max = 4;

pub const State = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    /// Borrowed from the host (`host.Context.state_dir`).
    state_dir: []const u8,
    wb: wellbeing.Wellbeing,
    hover: Id = .none,
    pressed: Id = .none,
    time_buf: [16]u8 = undefined,
    time_len: usize = 0,
    /// Linux only; null elsewhere or when the watch could not start.
    watch: ?*FileWatch = null,

    pub fn clock(self: *const State) []const u8 {
        return self.time_buf[0..self.time_len];
    }
};

/// Joins the shared state and, on Linux, watches the state file.
pub fn init(context: host.Context) !State {
    var state: State = .{
        .io = context.io,
        .gpa = context.gpa,
        .state_dir = context.state_dir,
        .wb = wellbeing.Wellbeing.init(context.config.wellbeing),
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

/// One second while the timer is running, so the digits move. An idle
/// window waits for the file watch, or polls once a second without one.
pub fn wait(state: *const State) ?f64 {
    if (state.wb.timer().run == .running) return 1;
    if (state.watch) |watch| {
        if (watch.isAlive()) return null;
    }
    return 1;
}

/// Picks up another process's save. True when the shown time changed.
/// A wake from the watch reads the file at once; any other wake (input,
/// the one-second timeout) polls, at most once a second.
pub fn wake(state: *State) bool {
    const before = state.clock();
    var previous: [16]u8 = undefined;
    const n = @min(before.len, previous.len);
    @memcpy(previous[0..n], before[0..n]);
    const changed = if (state.watch) |watch| watch.takeChanged() else false;
    const mode: wellbeing.Wellbeing.SyncMode = if (changed) .changed else .poll;
    state.wb.sync(state.io, state.state_dir, wallSeconds(state.io), mode) catch |err| {
        log.err("cannot read wellbeing state: {t}", .{err});
    };
    refresh(state);
    return n != state.time_len or !std.mem.eql(u8, previous[0..n], state.clock());
}

pub fn update(state: *State, event: host.Event) bool {
    switch (event) {
        .size, .key => return false,
        .pointer => |id| {
            const before = state.hover;
            state.hover = id;
            return before != id;
        },
        .press => |id| {
            state.pressed = id;
            return state.pressed != .none;
        },
        .release => {
            const pressed = state.pressed;
            state.pressed = .none;
            if (pressed == .none or pressed != state.hover) return true;
            const now_ms = wallMs(state.io);
            if (pressed == pause_id) {
                state.wb.toggleFocus(now_ms);
            } else if (pressed == skip_id) {
                state.wb.skipFocus(now_ms);
            } else if (pressed == reset_id) {
                state.wb.resetFocus(now_ms);
            } else return true;
            state.wb.sync(state.io, state.state_dir, wallSeconds(state.io), .merge) catch |err| {
                log.err("cannot save wellbeing state: {t}", .{err});
            };
            refresh(state);
            return true;
        },
    }
}

pub fn view(state: *const State, tree: *Tree, theme: *const Theme) kit.tree.Error!void {
    const column = try tree.open(.{ .padding = .all(24), .gap = 16 });
    _ = try tree.text(state.clock(), .{
        .color = theme.foreground,
        .style = .xxxl_semibold,
        .figures = .tabular,
    });
    const row = try tree.open(.{ .axis = .row, .gap = button.gap });
    try button.view(tree, theme, .{
        .id = pause_id,
        .label = pauseLabel(state),
        .variant = .primary,
        .state = buttonState(state, pause_id),
    });
    try button.view(tree, theme, .{
        .id = skip_id,
        .label = "Skip",
        .state = buttonState(state, skip_id),
    });
    try button.view(tree, theme, .{
        .id = reset_id,
        .label = "Reset",
        .state = buttonState(state, reset_id),
    });
    tree.close(row);
    tree.close(column);
}

fn pauseLabel(state: *const State) []const u8 {
    const timer = state.wb.timer();
    if (timer.run == .running) return "Pause";
    if (timer.phase == .idle) return "Start";
    return "Resume";
}

fn buttonState(state: *const State, id: Id) button.State {
    if (state.pressed == id and state.hover == id) return .pressed;
    if (state.hover == id) return .hovered;
    return .normal;
}

fn refresh(state: *State) void {
    const shown = focus.State.view(state.wb.timer(), state.wb.option.focus, wallMs(state.io));
    state.time_len = formatTime(&state.time_buf, shown.remaining_ms);
}

fn formatTime(buf: *[16]u8, ms: u64) usize {
    const total_s = ms / std.time.ms_per_s;
    const minutes: u64 = (total_s / 60) % 60;
    const seconds: u64 = total_s % 60;
    const hours: u64 = total_s / 3600;
    const text = if (hours > 0)
        std.fmt.bufPrint(buf, "{d}:{d:0>2}:{d:0>2}", .{ hours, minutes, seconds })
    else
        std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}", .{ minutes, seconds });
    if (text) |written| return written.len else |_| {
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
