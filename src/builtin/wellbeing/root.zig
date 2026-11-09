const std = @import("std");
const Io = std.Io;

pub const storage = @import("storage.zig");
pub const merge = @import("merge.zig");
pub const tracker = @import("tracker.zig");
pub const reminders = @import("reminders.zig");
pub const winddown = @import("winddown.zig");
pub const localtime = @import("localtime.zig");
pub const dashboard = @import("dashboard.zig");
pub const focus = @import("focus.zig");
pub const icons = @import("icons.zig");
pub const overlay = @import("overlay.zig");

const log = std.log.scoped(.wellbeing);

pub const Option = struct {
    enabled: bool = true,

    privacy: struct {
        state_dir: ?[]const u8 = null,
        state_filename: []const u8 = "wellbeing.bin",
    } = .{},

    screen_time: tracker.TrackerOption = .{},
    eyesight: reminders.EyesightOption = .{},
    movement: reminders.MovementOption = .{},
    focus: focus.Option = .default,
    winddown: winddown.WinddownOption = .{},

    // Domain-specific UI behaviors
    lock_screen: struct {
        enabled: bool = true,
        dim_strength: f32 = 0.50,
    } = .{},

    dashboard: struct {
        modal_enabled: bool = true,
    } = .{},

    pub const default: Option = .{};
};

pub const Wellbeing = struct {
    option: Option,
    /// What the engines read and update: `base` plus this process's changes.
    data: storage.PersistentData = .empty,
    /// The state file version `data` was derived from (see merge.zig).
    base: storage.PersistentData = .empty,
    /// Identifies the file version in `base`, to notice other processes'
    /// saves with one `stat`.
    stamp: storage.Stamp = .none,
    /// Wall-clock second of the last merge attempt.
    last_merge_utc_s: i64 = 0,
    /// Wall-clock second of the last poll; polls run at most once a second.
    last_poll_utc_s: i64 = 0,
    /// Held from `open` to `close`; null in a process that never opened the
    /// shared state (tests, `rex wellbeing`).
    presence: ?storage.Presence = null,
    tracker_engine: tracker.Tracker,
    reminders_engine: reminders.RemindersEngine,
    winddown_engine: winddown.WinddownEngine,
    focus_state: focus.State,

    current_alert: reminders.Alert = .{},
    color_tint: [3]f32 = .{ 1.0, 1.0, 1.0 },
    grayscale_factor: f32 = 0.0,
    mute_audio_bell: bool = false,
    input_locked: bool = false,
    anim_elapsed_ms: u64 = 0,
    accum_ms: u64 = 0,
    /// Statistics of timer changes not written yet; added to the file only
    /// if the change wins (see `mergeLocked`).
    tally: focus.Tally = .empty,
    /// The timer as the last `tick` saw it, to notice a phase end that
    /// another window recorded.
    seen_timer: focus.Timer = .{},
    /// Wall-clock ms at which a reminder began blocking input during a
    /// running task (`on_alert = pause`); 0 when none does.
    alert_pause_start_ms: i64 = 0,
    /// Screen time counts only in the focused window: the window manager
    /// focuses one window at a time, so windows never count the same
    /// second twice and adding their times is exact.
    window_focused: bool = true,

    pub fn init(option: Option) Wellbeing {
        var focus_state = focus.State.idle;
        focus_state.option = option.focus;

        return .{
            .option = option,
            .tracker_engine = tracker.Tracker.init(option.screen_time),
            .reminders_engine = reminders.RemindersEngine.init(option.eyesight, option.movement),
            .winddown_engine = winddown.WinddownEngine.init(option.winddown),
            .focus_state = focus_state,
        };
    }

    /// Takes reloaded settings. Running state (timers, the focus phase and
    /// its remaining time, today's records) is kept, and each engine uses the
    /// new settings from its next tick; a focus phase already running keeps
    /// its remaining time. The configured transition mode replaces one
    /// toggled at runtime.
    pub fn applyOption(self: *Wellbeing, option: Option) void {
        self.option = option;
        self.tracker_engine.option = option.screen_time;
        self.reminders_engine.eyesight_opt = option.eyesight;
        self.reminders_engine.movement_opt = option.movement;
        self.winddown_engine.option = option.winddown;
        self.focus_state.option = option.focus;
        // A waiting phase starts on the next tick if phases now start on
        // their own (`focus.applyPhaseEnd`).
    }

    /// The directory holding the state file: `privacy.state_dir` if set,
    /// otherwise `default_state_dir`.
    pub fn stateDir(self: *const Wellbeing, default_state_dir: []const u8) []const u8 {
        return self.option.privacy.state_dir orelse default_state_dir;
    }

    pub const SyncMode = enum {
        /// Re-read the file when another process saved it, and merge when a
        /// merge is due and the write lock is free.
        poll,
        /// Merge now, waiting for the write lock if another process holds it,
        /// and flush the save to disk (`Durability.synced`). For the exit
        /// save and the restart in `open`, off the frame path.
        merge,
    };

    /// A poll merges when this long has passed since the last merge (either
    /// way, so a clock set back does not postpone it) or the day changed.
    pub const merge_interval_s = 60;

    pub const OpenError = storage.LockError || storage.StampError || storage.LoadError;
    pub const SyncError = storage.LockError || storage.StampError || storage.LoadError || storage.SaveError;

    /// Joins the shared state as a running window: takes the presence lock,
    /// then loads the file. On a load error the presence stays held, the
    /// data stays empty, and the first merge replaces the file; call `close`
    /// in every case.
    ///
    /// When no other window is alive, a running phase was left behind by
    /// windows that closed: it comes back paused with the time it had left
    /// at the last save, or waiting (and not counted) if that had run out.
    /// This is written at once, so a window opening next does not join it.
    pub fn open(self: *Wellbeing, io: Io, default_state_dir: []const u8, utc_ms: i64) (OpenError || SyncError)!void {
        const dir = self.stateDir(default_state_dir);
        const name = self.option.privacy.state_filename;
        const acquired = try storage.acquirePresence(io, dir, name);
        self.presence = acquired.presence;
        self.stamp = try storage.stamp(io, dir, name);
        try self.loadState(io, default_state_dir);

        var left_behind = self.timer();
        if (!acquired.alone or left_behind.run != .running) return;
        const left_ms = left_behind.ms -| (self.data.last_write_utc_s *| std.time.ms_per_s);
        left_behind.run = if (left_ms > 0) .paused else .waiting;
        left_behind.ms = @max(left_ms, 0);
        self.data.timer = rawTimer(left_behind);
        try self.sync(io, default_state_dir, @divFloor(utc_ms, std.time.ms_per_s), .merge);
    }

    /// Milliseconds until the next poll second, for the event loop's wait:
    /// a sleeping window still notices another window's timer within a
    /// second. No deadline while wellbeing is disabled.
    pub fn msUntilSync(self: *const Wellbeing, utc_ms: i64) u64 {
        if (!self.option.enabled) return std.math.maxInt(u64);
        return @intCast(std.time.ms_per_s - @mod(utc_ms, std.time.ms_per_s));
    }

    /// Releases the presence lock. Merge before, so nothing is lost.
    pub fn close(self: *Wellbeing, io: Io) void {
        if (self.presence) |presence| presence.release(io);
        self.presence = null;
    }

    /// Restores saved data and the focus phase without joining the shared
    /// state (for `rex wellbeing`). On error the current data is kept.
    pub fn loadState(self: *Wellbeing, io: Io, default_state_dir: []const u8) storage.LoadError!void {
        self.data = try storage.load(io, self.stateDir(default_state_dir), self.option.privacy.state_filename);
        self.base = self.data;
        self.seen_timer = self.timer();
        self.focus_state = .view(self.seen_timer, self.option.focus, 0);
    }

    /// The timer this process wants, which `mergeLocked` writes if no
    /// other process changed the timer first. An invalid stored phase or
    /// run reads as idle.
    pub fn timer(self: *const Wellbeing) focus.Timer {
        const raw = self.data.timer;
        const phase = std.enums.fromInt(focus.Phase, raw.phase) orelse return .{};
        const run = std.enums.fromInt(focus.Run, raw.run) orelse return .{};
        return .{ .phase = phase, .run = run, .ms = raw.ms, .tasks_in_cycle = raw.tasks_in_cycle };
    }

    fn rawTimer(t: focus.Timer) storage.Timer {
        return .{ .ms = t.ms, .phase = @intFromEnum(t.phase), .run = @intFromEnum(t.run), .tasks_in_cycle = t.tasks_in_cycle };
    }

    /// Takes a timer change. Its statistics wait in `tally` for the write,
    /// except in a process that never joined the shared state, which has no
    /// other writer and records them at once.
    fn applyChange(self: *Wellbeing, change: focus.Change) void {
        self.data.timer = rawTimer(change.timer);
        if (self.presence == null) {
            applyTally(&self.data, change.tally);
        } else {
            self.tally.add(change.tally);
        }
    }

    fn timerPending(self: *const Wellbeing) bool {
        return !std.meta.eql(self.data.timer, self.base.timer) or !self.tally.isEmpty();
    }

    /// Ends a phase whose end time passed before a user action, so the
    /// action applies to the phase that follows it.
    fn catchUp(self: *Wellbeing, now_ms: i64) void {
        if (self.alert_pause_start_ms != 0) return;
        if (focus.endIfDue(self.timer(), self.option.focus, now_ms)) |change| self.applyChange(change);
    }

    /// Exchanges changes with the state file: picks up other processes'
    /// saves and, when due (or asked), merges this process's changes. A
    /// poll does nothing more than once per wall-clock second unless a
    /// merge is due, so the caller may call it every frame. Nothing happens
    /// while wellbeing is disabled.
    pub fn sync(self: *Wellbeing, io: Io, default_state_dir: []const u8, utc_s: i64, mode: SyncMode) SyncError!void {
        if (!self.option.enabled) return;
        if (mode == .poll) {
            if (utc_s == self.last_poll_utc_s and !self.mergeDue(utc_s)) return;
            self.last_poll_utc_s = utc_s;
        }
        const dir = self.stateDir(default_state_dir);
        const name = self.option.privacy.state_filename;
        const lock: ?storage.WriteLock = switch (mode) {
            .merge => try storage.lockWrite(io, dir, name),
            .poll => if (self.mergeDue(utc_s)) try storage.tryLockWrite(io, dir, name) else null,
        };
        if (lock) |held| {
            defer held.release(io);
            try self.mergeLocked(io, dir, name, utc_s, if (mode == .merge) .synced else .buffered);
        } else {
            try self.poll(io, dir, name);
        }
    }

    /// A merge is due on a day change, a timer change, a reminder due point
    /// moved (so other windows see it within a poll), screen time left
    /// unmerged in a window that lost focus (so only the focused window
    /// holds unmerged time and the shared limit stays exact), or after
    /// `merge_interval_s`.
    fn mergeDue(self: *const Wellbeing, utc_s: i64) bool {
        if (self.data.today.day != self.base.today.day or self.timerPending()) return true;
        if (self.data.eyesight_due_s != self.base.eyesight_due_s or self.data.movement_due_s != self.base.movement_due_s) return true;
        if (!self.window_focused and self.data.today.active_screen_s != self.base.today.active_screen_s) return true;
        const elapsed_s = std.math.sub(i64, utc_s, self.last_merge_utc_s) catch return true;
        return @abs(elapsed_s) >= merge_interval_s;
    }

    /// Re-reads the file when its stamp changed and replays this process's
    /// changes on top. An unreadable file is logged once per version and
    /// left for the next merge to replace.
    fn poll(self: *Wellbeing, io: Io, dir: []const u8, name: []const u8) SyncError!void {
        const current = try storage.stamp(io, dir, name);
        if (current.eql(self.stamp)) return;
        self.stamp = current;
        if (current.eql(.none)) return;
        const fresh = storage.load(io, dir, name) catch |err| switch (err) {
            error.InvalidStateFile => {
                log.warn("ignoring the unreadable wellbeing state in {s} until the next save", .{dir});
                return;
            },
            else => |e| return e,
        };
        const view = merge.rebase(&self.data, &self.base, &fresh);
        self.adopt(&fresh, &view);
    }

    /// Merges with the write lock held. A timer change is written only when
    /// no other process changed the timer since `base` (`timer_rev`);
    /// otherwise it and its statistics are dropped and the file's timer
    /// wins. Writes only when the result differs from the file, so an idle
    /// process does not rewrite it every minute.
    fn mergeLocked(
        self: *Wellbeing,
        io: Io,
        dir: []const u8,
        name: []const u8,
        utc_s: i64,
        durability: storage.Durability,
    ) SyncError!void {
        // Set first: a failed merge is retried after the interval, not on
        // every poll.
        self.last_merge_utc_s = utc_s;
        const fresh = storage.load(io, dir, name) catch |err| switch (err) {
            error.InvalidStateFile => blk: {
                log.warn("replacing the unreadable wellbeing state in {s}", .{dir});
                break :blk self.base;
            },
            else => |e| return e,
        };
        var merged = merge.rebase(&self.data, &self.base, &fresh);
        const purged = fresh.generation != self.base.generation;
        if (!purged and fresh.timer_rev == self.base.timer_rev and self.timerPending()) {
            merged.timer = self.data.timer;
            merged.timer_rev +%= 1;
            applyTally(&merged, self.tally);
        }
        if (!std.mem.eql(u8, std.mem.asBytes(&merged), std.mem.asBytes(&fresh))) {
            merged.last_write_utc_s = utc_s;
            try storage.save(io, &merged, dir, name, durability);
            self.stamp = try storage.stamp(io, dir, name);
        }
        self.adopt(&merged, &merged);
    }

    /// Takes `file` as the new base and `view` as the data. When another
    /// process changed the timer (`timer_rev`) or purged (generation), this
    /// process's pending timer change and statistics are dropped; a purge
    /// also clears the timer.
    fn adopt(self: *Wellbeing, file: *const storage.PersistentData, view: *const storage.PersistentData) void {
        const replaced = file.generation != self.base.generation or file.timer_rev != self.base.timer_rev;
        const pending = self.data.timer;
        self.base = file.*;
        self.data = view.*;
        if (replaced) {
            self.tally = .empty;
        } else {
            self.data.timer = pending;
        }
    }

    /// Adds a timer change's statistics to `data`'s current day.
    fn applyTally(data: *storage.PersistentData, tally: focus.Tally) void {
        data.today.focus_s +|= std.math.cast(u32, tally.focus_ms / std.time.ms_per_s) orelse std.math.maxInt(u32);
        data.today.break_s +|= std.math.cast(u32, tally.break_ms / std.time.ms_per_s) orelse std.math.maxInt(u32);
        data.today.tasks_completed +|= std.math.cast(u16, tally.tasks) orelse std.math.maxInt(u16);
        data.tasks_completed +|= tally.tasks;
        data.long_breaks_taken +|= tally.long_breaks;
        if (tally.tasks > 0) merge.recordTaskDay(data, data.today.day);
    }

    /// Clears the history for every process: writes an empty file with the
    /// next generation, which makes the others drop what they have not
    /// merged. The save is flushed, so the old data does not come back
    /// after a power loss. Memory is cleared only once the file is written.
    pub fn purgeHistory(self: *Wellbeing, io: Io, default_state_dir: []const u8, utc_s: i64) SyncError!void {
        const dir = self.stateDir(default_state_dir);
        const name = self.option.privacy.state_filename;
        const lock = try storage.lockWrite(io, dir, name);
        defer lock.release(io);
        const fresh = storage.load(io, dir, name) catch |err| switch (err) {
            error.InvalidStateFile => storage.PersistentData.empty,
            else => |e| return e,
        };
        var cleared: storage.PersistentData = .empty;
        cleared.generation = fresh.generation +% 1;
        cleared.last_write_utc_s = utc_s;
        try storage.save(io, &cleared, dir, name, .synced);
        self.stamp = try storage.stamp(io, dir, name);
        self.base = cleared;
        self.data = cleared;
        self.tally = .empty;
    }

    pub fn recordActivity(self: *Wellbeing) void {
        self.tracker_engine.recordActivity();
    }

    /// The window gained or lost focus. Gaining it (a click, alt-tab) is
    /// user activity. While unfocused the screen-time tracker does not run:
    /// no active time, no foreground-app samples, no limit check.
    pub fn windowFocusChanged(self: *Wellbeing, focused: bool) void {
        self.window_focused = focused;
        if (focused) self.tracker_engine.recordActivity();
    }

    /// Start, pause, resume, or confirm the next phase. `now_ms` is
    /// wall-clock milliseconds since the epoch.
    pub fn toggleFocus(self: *Wellbeing, now_ms: i64) void {
        self.catchUp(now_ms);
        self.applyChange(focus.toggle(self.timer(), self.option.focus, now_ms));
        self.showAction(now_ms);
    }

    pub fn resetFocus(self: *Wellbeing, now_ms: i64) void {
        self.catchUp(now_ms);
        self.applyChange(focus.reset(self.timer(), self.option.focus, now_ms));
        self.showAction(now_ms);
    }

    pub fn skipFocus(self: *Wellbeing, now_ms: i64) void {
        self.catchUp(now_ms);
        if (focus.skip(self.timer(), self.option.focus, now_ms)) |change| self.applyChange(change);
        self.showAction(now_ms);
    }

    /// Shows a timer change made here. It also becomes `seen_timer`: `tick`
    /// treats only changes it has not seen as phase ends to announce.
    fn showAction(self: *Wellbeing, now_ms: i64) void {
        self.seen_timer = self.timer();
        self.focus_state = .view(self.seen_timer, self.option.focus, now_ms);
    }

    /// Switches between waiting for the user and starting the next phase on
    /// its own, until the next config reload. A waiting phase starts on the
    /// next tick.
    pub fn toggleFocusPhaseEnd(self: *Wellbeing) void {
        const focus_option = &self.option.focus;
        focus_option.on_phase_end = if (focus_option.on_phase_end == .start_next) .wait else .start_next;
        self.focus_state.option = focus_option.*;
    }

    pub fn dismissAlert(self: *Wellbeing) void {
        self.current_alert = .{};
        self.reminders_engine.current_alert = .{};
        self.input_locked = false;
        self.anim_elapsed_ms = 0;
    }

    /// `local_s` is local wall-clock seconds since the epoch (see
    /// `localtime.Clock`); it sets the day boundary and the wind-down window.
    /// `utc_ms` is wall-clock milliseconds since the epoch, for the focus
    /// timer.
    pub fn tick(
        self: *Wellbeing,
        dt_ms: u64,
        pty_fd: std.posix.fd_t,
        local_s: i64,
        utc_ms: i64,
    ) struct {
        needs_redraw: bool,
        phase_changed: bool,
        alert: ?reminders.Alert,
        bell_muted: bool,
        input_locked: bool,
        grayscale: f32,
        tint: [3]f32,
    } {
        if (!self.option.enabled) {
            return .{
                .needs_redraw = false,
                .phase_changed = false,
                .alert = null,
                .bell_muted = false,
                .input_locked = false,
                .grayscale = 0.0,
                .tint = .{ 1.0, 1.0, 1.0 },
            };
        }

        self.accum_ms +|= dt_ms;
        const dt_s: u32 = @intCast(self.accum_ms / 1000);
        self.accum_ms %= 1000;

        var alert_to_return: ?reminders.Alert = null;
        var needs_redraw = false;
        var phase_changed = false;

        const today_epoch_day = merge.localDay(local_s);
        if (merge.rollover(&self.data, today_epoch_day)) needs_redraw = true;

        // Screen-time tracker tick. `data.today` holds the file's time plus
        // this window's, so the daily limit sees every window's time once
        // the others have merged.
        if (dt_s > 0 and self.window_focused) {
            const tr = self.tracker_engine.tick(dt_s, pty_fd, &self.data.today);
            if (tr.limit_reached) {
                alert_to_return = .{
                    .kind = .screen_limit,
                    .prompt = "Daily screen-time limit reached.",
                    .remaining_s = 20,
                    .lock_input = self.option.screen_time.on_limit.contains(.lock_input),
                    .show_animation = self.option.screen_time.on_limit.contains(.animation),
                    .animation = .grayscale_wave,
                };
                needs_redraw = true;
            }
            if (self.tracker_engine.grayscale_factor != self.grayscale_factor) {
                self.grayscale_factor = self.tracker_engine.grayscale_factor;
                needs_redraw = true;
            }
        }

        // Reminders tick
        if (dt_s > 0) {
            if (self.reminders_engine.tick(dt_s, self.tracker_engine.is_idle, &self.data.today)) |rem| {
                alert_to_return = rem;
                needs_redraw = true;
            }
        }

        // Wind-Down update
        const wd = self.winddown_engine.update(local_s);
        if (wd.just_started) {
            alert_to_return = .{
                .kind = .healthy_break,
                .prompt = self.option.winddown.prompt,
                .remaining_s = 20,
            };
            needs_redraw = true;
        }
        if (!std.meta.eql(self.color_tint, wd.color_tint)) {
            self.color_tint = wd.color_tint;
            needs_redraw = true;
        }

        // Focus timer. A reminder blocking input during a running task
        // (`on_alert = pause`) holds the phase end in this window and, once
        // it closes, moves the end later by how long it was shown. Another
        // window does not see the reminder and may end the phase meanwhile;
        // then the task is no longer running and nothing is moved.
        const focus_option = self.option.focus;
        const alert_is_locking = if (alert_to_return) |al|
            al.lock_input
        else
            (self.current_alert.kind != .none and self.current_alert.remaining_s > 0 and self.current_alert.lock_input);
        const running_task = self.timer().phase == .task and self.timer().run == .running;
        if (focus_option.on_alert.contains(.pause) and alert_is_locking and running_task) {
            if (self.alert_pause_start_ms == 0) self.alert_pause_start_ms = utc_ms;
        } else if (self.alert_pause_start_ms != 0) {
            const shown_ms = std.math.cast(u64, utc_ms -| self.alert_pause_start_ms) orelse 0;
            self.alert_pause_start_ms = 0;
            if (focus.extend(self.timer(), shown_ms)) |change| self.applyChange(change);
        }
        if (self.alert_pause_start_ms == 0) {
            if (focus.endIfDue(self.timer(), focus_option, utc_ms)) |change| self.applyChange(change);
        }
        if (focus.applyPhaseEnd(self.timer(), focus_option, utc_ms)) |change| self.applyChange(change);

        // A phase that ran out, ended here or by another window, shows the
        // break prompt in every window.
        const current = self.timer();
        const seen = self.seen_timer;
        if (!std.meta.eql(current, seen)) {
            needs_redraw = true;
            if (seen.phase != .idle and seen.run == .running and utc_ms >= seen.ms) {
                phase_changed = true;
                const on_break = focus_option.on_break;
                if (seen.phase == .task and (on_break.contains(.prompt) or on_break.contains(.animation))) {
                    alert_to_return = .{
                        .kind = .healthy_break,
                        .prompt = self.reminders_engine.nextBreakPrompt(),
                        .remaining_s = 30,
                        .lock_input = on_break.contains(.lock_input),
                        .show_animation = on_break.contains(.animation),
                        .animation = .pulse_dim,
                    };
                }
            }
            self.seen_timer = current;
        }
        const view_ms = if (self.alert_pause_start_ms != 0) self.alert_pause_start_ms else utc_ms;
        self.focus_state = .view(current, focus_option, view_ms);

        // Bell silencing policy
        const in_focus_task = self.option.focus.during_task.contains(.mute_bell) and self.focus_state.phase == .task;
        const in_winddown = wd.active and self.option.winddown.during_window.contains(.mute_bell);
        self.mute_audio_bell = in_focus_task or in_winddown;

        if (alert_to_return) |al| {
            self.current_alert = al;
            self.anim_elapsed_ms = 0;
        } else if (dt_s > 0 and self.current_alert.remaining_s > 0) {
            self.current_alert.remaining_s -|= dt_s;
            if (self.current_alert.remaining_s == 0) {
                self.current_alert = .{};
                self.anim_elapsed_ms = 0;
                needs_redraw = true;
            }
        }

        const has_active_alert = self.current_alert.kind != .none and self.current_alert.remaining_s > 0;
        const in_focus_break = self.focus_state.phase == .short_break or self.focus_state.phase == .long_break;
        self.input_locked = (has_active_alert and self.current_alert.lock_input) or
            (in_focus_break and self.focus_state.option.on_break.contains(.lock_input));

        var out_grayscale = self.grayscale_factor;
        var out_tint = self.color_tint;

        if (has_active_alert and self.current_alert.show_animation and self.current_alert.animation != .none) {
            self.anim_elapsed_ms +|= dt_ms;
            const phase_rad = (@as(f32, @floatFromInt(self.anim_elapsed_ms % 4000)) / 4000.0) * (2.0 * std.math.pi);
            const wave = 0.5 * (1.0 - @cos(phase_rad)); // Smooth 0.0 -> 1.0 -> 0.0 over 4s
            switch (self.current_alert.animation) {
                .none => {},
                .pulse_dim => {
                    const dim = 1.0 - (0.35 * wave);
                    out_tint[0] *= dim;
                    out_tint[1] *= dim;
                    out_tint[2] *= dim;
                },
                .grayscale_wave => {
                    out_grayscale = @max(out_grayscale, 0.85 * wave);
                },
                .warm_glow => {
                    out_tint[1] *= (1.0 - 0.18 * wave);
                    out_tint[2] *= (1.0 - 0.45 * wave);
                },
            }
            needs_redraw = true;
        }

        return .{
            .needs_redraw = needs_redraw,
            .phase_changed = phase_changed,
            .alert = alert_to_return,
            .bell_muted = self.mute_audio_bell,
            .input_locked = self.input_locked,
            .grayscale = out_grayscale,
            .tint = out_tint,
        };
    }

    pub fn renderDashboard(self: *const Wellbeing, buf: []u8) []const u8 {
        return dashboard.render(&self.data, self.option.screen_time.daily_limit_ms, buf);
    }

    pub fn isFocusPausedByAlert(self: *const Wellbeing) bool {
        const alert_is_locking = (self.current_alert.kind != .none and self.current_alert.remaining_s > 0 and self.current_alert.lock_input);
        return self.focus_state.option.on_alert.contains(.pause) and alert_is_locking and self.focus_state.phase == .task;
    }
};
