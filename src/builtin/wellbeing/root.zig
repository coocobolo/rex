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
    routines: reminders.RoutinesOption = .{},

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
    focus_accum_ms: u64 = 0,
    break_accum_ms: u64 = 0,

    pub fn init(option: Option) Wellbeing {
        var focus_state = focus.State.idle;
        focus_state.option = option.focus;
        focus_state.paused = true;

        return .{
            .option = option,
            .tracker_engine = tracker.Tracker.init(option.screen_time),
            .reminders_engine = reminders.RemindersEngine.init(option.eyesight, option.movement, option.routines),
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
        self.reminders_engine.routines_opt = option.routines;
        self.winddown_engine.option = option.winddown;
        self.focus_state.option = option.focus;
        // Starts the next phase if one is waiting and phases now start on their own.
        self.focus_state.setPhaseEnd(option.focus.on_phase_end);
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
        /// Merge now, waiting for the write lock if another process holds it.
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
    pub fn open(self: *Wellbeing, io: Io, default_state_dir: []const u8) OpenError!void {
        const dir = self.stateDir(default_state_dir);
        const name = self.option.privacy.state_filename;
        self.presence = (try storage.acquirePresence(io, dir, name)).presence;
        self.stamp = try storage.stamp(io, dir, name);
        try self.loadState(io, default_state_dir);
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

        const timer = self.data.timer;
        if (std.enums.fromInt(focus.Phase, timer.phase)) |phase| {
            self.focus_state.phase = phase;
            self.focus_state.remaining_ms = std.math.cast(u64, timer.ms) orelse 0;
            self.focus_state.tasks_in_cycle = timer.tasks_in_cycle;
            // A phase that had ended still waits for the user; anything
            // else comes back paused.
            const waiting = timer.run == @intFromEnum(storage.Run.waiting);
            self.focus_state.waiting = waiting;
            self.focus_state.paused = !waiting;
        }
    }

    /// Exchanges changes with the state file: picks up other processes'
    /// saves and, when due (or asked), merges this process's changes.
    pub fn sync(self: *Wellbeing, io: Io, default_state_dir: []const u8, utc_s: i64, mode: SyncMode) SyncError!void {
        const dir = self.stateDir(default_state_dir);
        const name = self.option.privacy.state_filename;
        const lock: ?storage.WriteLock = switch (mode) {
            .merge => try storage.lockWrite(io, dir, name),
            .poll => if (self.mergeDue(utc_s)) try storage.tryLockWrite(io, dir, name) else null,
        };
        if (lock) |held| {
            defer held.release(io);
            try self.mergeLocked(io, dir, name, utc_s);
        } else {
            try self.poll(io, dir, name);
        }
    }

    fn mergeDue(self: *const Wellbeing, utc_s: i64) bool {
        if (self.data.today.day != self.base.today.day) return true;
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

    /// Merges with the write lock held. Writes only when the result differs
    /// from the file, so an idle process does not rewrite it every minute.
    fn mergeLocked(self: *Wellbeing, io: Io, dir: []const u8, name: []const u8, utc_s: i64) SyncError!void {
        // Set first: a failed merge is retried after the interval, not on
        // every poll.
        self.last_merge_utc_s = utc_s;
        self.storeTimer();
        const fresh = storage.load(io, dir, name) catch |err| switch (err) {
            error.InvalidStateFile => blk: {
                log.warn("replacing the unreadable wellbeing state in {s}", .{dir});
                break :blk self.base;
            },
            else => |e| return e,
        };
        var merged = merge.rebase(&self.data, &self.base, &fresh);
        // Until the shared timer lands, the last writer's timer wins, as
        // before; a purge since `base` resets it.
        if (fresh.generation == self.base.generation) merged.timer = self.data.timer;
        if (!std.mem.eql(u8, std.mem.asBytes(&merged), std.mem.asBytes(&fresh))) {
            merged.last_write_utc_s = utc_s;
            try storage.save(io, &merged, dir, name);
            self.stamp = try storage.stamp(io, dir, name);
        }
        self.adopt(&merged, &merged);
    }

    /// Takes `file` as the new base and `view` as the data. A purge in
    /// another process (newer generation) also resets the focus timer.
    fn adopt(self: *Wellbeing, file: *const storage.PersistentData, view: *const storage.PersistentData) void {
        const purged = file.generation != self.base.generation;
        const timer = self.data.timer;
        self.base = file.*;
        self.data = view.*;
        if (purged) self.focus_state.reset() else self.data.timer = timer;
    }

    /// Writes the focus state into `data.timer`. Until the shared timer
    /// lands, a running phase is stored paused with the time left.
    fn storeTimer(self: *Wellbeing) void {
        self.data.timer = .{
            .ms = std.math.cast(i64, self.focus_state.remaining_ms) orelse std.math.maxInt(i64),
            .phase = @intFromEnum(self.focus_state.phase),
            .run = @intFromEnum(if (self.focus_state.waiting) storage.Run.waiting else storage.Run.paused),
            .tasks_in_cycle = self.focus_state.tasks_in_cycle,
        };
    }

    /// Clears the history for every process: writes an empty file with the
    /// next generation, which makes the others drop what they have not
    /// merged. Memory is cleared only once the file is written.
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
        try storage.save(io, &cleared, dir, name);
        self.stamp = try storage.stamp(io, dir, name);
        self.base = cleared;
        self.data = cleared;
        self.focus_state.reset();
    }

    pub fn recordActivity(self: *Wellbeing) void {
        self.tracker_engine.recordActivity();
    }

    pub fn toggleFocus(self: *Wellbeing) void {
        const was_idle = self.focus_state.phase == .idle;
        self.focus_state.toggle();
        if (was_idle and self.focus_state.phase == .task) {
            self.data.sessions +|= 1;
        }
    }

    pub fn resetFocus(self: *Wellbeing) void {
        self.focus_state.reset();
    }

    pub fn skipFocus(self: *Wellbeing) void {
        self.focus_state.skip();
    }

    pub fn toggleFocusPhaseEnd(self: *Wellbeing) void {
        self.focus_state.setPhaseEnd(
            if (self.focus_state.option.on_phase_end == .start_next) .wait else .start_next,
        );
    }

    pub fn dismissAlert(self: *Wellbeing) void {
        self.current_alert = .{};
        self.reminders_engine.current_alert = .{};
        self.input_locked = false;
        self.anim_elapsed_ms = 0;
    }

    /// `local_s` is local wall-clock seconds since the epoch (see
    /// `localtime.Clock`); it sets the day boundary and the wind-down window.
    pub fn tick(
        self: *Wellbeing,
        dt_ms: u64,
        pty_fd: std.posix.fd_t,
        local_s: i64,
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

        // Screen-time tracker tick
        if (dt_s > 0) {
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

        // Focus session tick
        const alert_is_locking = if (alert_to_return) |al|
            al.lock_input
        else
            (self.current_alert.kind != .none and self.current_alert.remaining_s > 0 and self.current_alert.lock_input);
        const pause_focus_for_alert = self.focus_state.option.on_alert.contains(.pause) and alert_is_locking and self.focus_state.phase == .task;

        if (self.focus_state.phase != .idle and !self.focus_state.paused and !self.focus_state.waiting and !pause_focus_for_alert) {
            const elapsed = @min(dt_ms, self.focus_state.remaining_ms);
            switch (self.focus_state.phase) {
                .task => {
                    self.focus_accum_ms +|= elapsed;
                    const add_s: u32 = @intCast(self.focus_accum_ms / 1000);
                    self.focus_accum_ms %= 1000;
                    self.data.today.focus_s +|= add_s;
                },
                .short_break, .long_break => {
                    self.break_accum_ms +|= elapsed;
                    const add_s: u32 = @intCast(self.break_accum_ms / 1000);
                    self.break_accum_ms %= 1000;
                    self.data.today.break_s +|= add_s;
                },
                .idle => {},
            }

            if (self.focus_state.tick(dt_ms)) {
                needs_redraw = true;
                phase_changed = true;
                const was_task = self.focus_state.phase == .task;
                const was_long_break = self.focus_state.phase == .long_break;

                if (was_task) {
                    self.data.today.tasks_completed +|= 1;
                    self.data.tasks_completed +|= 1;

                    merge.recordTaskDay(&self.data, today_epoch_day);

                    const on_break = self.focus_state.option.on_break;
                    if (on_break.contains(.prompt) or on_break.contains(.animation)) {
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
                if (was_long_break) {
                    self.data.long_breaks_taken +|= 1;
                }

                if (self.focus_state.option.on_phase_end == .start_next) {
                    self.focus_state.advance();
                }
            }
        }

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
