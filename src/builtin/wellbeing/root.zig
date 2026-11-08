const std = @import("std");
const Io = std.Io;

pub const storage = @import("storage.zig");
pub const tracker = @import("tracker.zig");
pub const reminders = @import("reminders.zig");
pub const winddown = @import("winddown.zig");
pub const localtime = @import("localtime.zig");
pub const dashboard = @import("dashboard.zig");
pub const focus = @import("focus.zig");
pub const icons = @import("icons.zig");
pub const overlay = @import("overlay.zig");

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
    data: storage.PersistentData = .empty,
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

    pub fn loadState(self: *Wellbeing, io: Io, default_state_dir: []const u8) void {
        const dir = self.option.privacy.state_dir orelse default_state_dir;
        self.data = storage.load(io, dir, self.option.privacy.state_filename);

        if (std.enums.fromInt(focus.Phase, self.data.focus_phase)) |phase| {
            self.focus_state.phase = phase;
            self.focus_state.remaining_ms = self.data.focus_remaining_ms;
            self.focus_state.tasks_in_cycle = self.data.tasks_in_cycle;
            self.focus_state.paused = true;
            self.focus_state.waiting = false;
        }
    }

    pub fn saveState(self: *Wellbeing, io: Io, default_state_dir: []const u8) !void {
        const dir = self.option.privacy.state_dir orelse default_state_dir;
        self.data.focus_phase = @intFromEnum(self.focus_state.phase);
        self.data.focus_remaining_ms = self.focus_state.remaining_ms;
        self.data.tasks_in_cycle = self.focus_state.tasks_in_cycle;
        try storage.save(io, &self.data, dir, self.option.privacy.state_filename);
    }

    pub fn purgeHistory(self: *Wellbeing, io: Io, default_state_dir: []const u8) !void {
        const dir = self.option.privacy.state_dir orelse default_state_dir;
        self.data = .empty;
        self.focus_state.reset();
        try storage.purge(io, dir, self.option.privacy.state_filename);
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

        // Day rollover check
        const today_epoch_day: u32 = @intCast(@divFloor(local_s, std.time.s_per_day));
        if (self.data.today.day == 0) {
            self.data.today.day = today_epoch_day;
        } else if (today_epoch_day > self.data.today.day) {
            // Push today to history
            if (self.data.history_count < storage.max_history_days) {
                self.data.history[self.data.history_count] = self.data.today;
                self.data.history_count += 1;
            } else {
                // Shift history
                for (0..storage.max_history_days - 1) |i| {
                    self.data.history[i] = self.data.history[i + 1];
                }
                self.data.history[storage.max_history_days - 1] = self.data.today;
            }

            self.data.total_active_screen_s +|= self.data.today.active_screen_s;
            self.data.total_focus_s +|= self.data.today.focus_s;
            self.data.today = .{ .day = today_epoch_day };
            needs_redraw = true;
        }

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

                    // Update streak
                    if (today_epoch_day == self.data.last_task_day) {
                        // same day
                    } else if (today_epoch_day == self.data.last_task_day + 1) {
                        self.data.current_streak += 1;
                    } else {
                        self.data.current_streak = 1;
                    }
                    self.data.best_streak = @max(self.data.best_streak, self.data.current_streak);
                    self.data.last_task_day = today_epoch_day;

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
