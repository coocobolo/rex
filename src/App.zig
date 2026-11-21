const App = @This();

const std = @import("std");
const builtin = @import("builtin");

const log = std.log.scoped(.app);

pub const std_options: std.Options = .{
    .log_level = .debug,
};

const native_os = builtin.os.tag;
const is_posix = native_os != .windows;

var sighup_pending = std.atomic.Value(bool).init(false);

fn sighupHandler(_: posix.SIG) callconv(.c) void {
    sighup_pending.store(true, .release);
}

const posix = std.posix;
const system = posix.system;

const rex = @import("root.zig");
pub const KitOverlay = @import("KitOverlay.zig");
const alert_dialog = @import("kit/alert_dialog.zig");
const icons = @import("kit/icons.zig");

const unicode = rex.unicode;

const renderer_mod = rex.renderer;
const decoration_config = @import("renderer/decoration_config.zig");
const Atlas = renderer_mod.Atlas;
const gl = renderer_mod.gl;
const Window = @import("platform/Window.zig");
const Platform = @import("platform/Platform.zig");
const PlatformEvents = @import("platform/Event.zig");
const Choice = @import("platform/root.zig").Choice;

const Background = renderer_mod.Background;
const Cursor = renderer_mod.Cursor;
const Scrollbar = renderer_mod.Scrollbar;
const SelectionState = renderer_mod.Selection.State;

const Renderer = renderer_mod.Renderer;
const Dimension = renderer_mod.Dimension;
const FrameBuilder = renderer_mod.Frame.Builder;
const kit_alert = @import("kit/alert.zig");
const kit_ascii_canvas = @import("kit/AsciiCanvas.zig");
const kit_lock_screen = @import("kit/lock_screen.zig");
const kit_motion = @import("kit/motion.zig");
const kit_theme = @import("kit/Theme.zig");
const kit_toast = @import("kit/toast.zig");
const kit_widget = @import("kit/wellbeing_widget.zig");

const Freetype = rex.FreeType;
const Rasterizer = rex.FreeType.Rasterizer;

const input = rex.input;
const Binding = input.Binding;

const Pty = rex.termio.Pty;
const latency_trace = rex.driver.latency_trace;

const Theme = rex.terminal.Theme;
const Color = rex.terminal.cell.Color;
const Terminal = rex.terminal.Terminal;
const MouseButton = rex.terminal.term.MouseButton;
const HeldButtons = rex.terminal.term.HeldButtons;
const TermName = rex.terminal.term.TermName;
const TerminalOption = rex.terminal.Option;
const Screen = rex.terminal.screen.Screen;
const Response = rex.terminal.Response;

const wellbeing = rex.builtin.wellbeing;
const FileWatch = @import("tool/FileWatch.zig");

/// Largest selection copied to the clipboard, in bytes.
const max_copy_size: usize = std.math.maxInt(u16) - 1;

const Config = rex.config.Config;
const Loaded = rex.config.Loaded;
const diagnostics = rex.config.diagnostics;

/// Half period of SGR 6 rapid blink, in ms.
/// How long a synchronized update (DEC mode 2026) may hold frames back.
const sync_output_timeout_ms = 150;

/// Grid limits and identity the screen, frame and renderer types are
/// built with, at compile time; no key sets them. 200 rows plus 3896 lines
/// of scrollback fill a 4096 row ring, so it wastes nothing (see
/// `TerminalOption.optimized`).
pub const terminal_option: TerminalOption = .{
    .max_rows = 200,
    .max_cols = 220,
    .tab_width = 8,
    .max_scrollback = 3896,
    .name = "rex",
    .version = "0.1.0",
};

pub const FrameBuilderType = FrameBuilder(terminal_option);
pub const FrameType = rex.terminal.Frame(terminal_option);
pub const RendererType = Renderer(terminal_option);
pub const ScreenType = Screen(terminal_option);
pub const TerminalType = Terminal(terminal_option);

pub const Driver = rex.driver.Driver(terminal_option);
pub const SingleDriverType = rex.driver.SingleDriver(terminal_option);
pub const ThreadedDriverType = rex.driver.ThreadedDriver(terminal_option);
pub const Events = rex.driver.Events;
pub const SharedModes = rex.driver.SharedModes;
pub const InputEvent = rex.driver.InputEvent;
pub const resolveAnchor = rex.driver.resolveAnchor;

allocator: std.mem.Allocator,
atlas: Atlas,

/// The active config: `base_config` with the system and user config files
/// applied. Everything applying the files allocates (the font path, the
/// merged keymap) lives in `config_arena`; a reload builds a new config in
/// a new arena and frees the old one as a whole.
config: Config,
config_arena: std.heap.ArenaAllocator,
/// The built-in defaults every config is built from. Static, owned by the
/// caller of `init`.
base_config: *const Config,
config_watcher: ?rex.config.Watcher = null,
/// The user config file: the --config path, else <config dir>/config.
/// Owned, freed in `deinit`.
config_path: []const u8,
/// `$HOME`, for `~/` paths in config files. Owned, freed in `deinit`.
home_dir: []const u8,
background_color: [4]f32,

rasterizer: Rasterizer,
frame_builder: FrameBuilderType,

io: std.Io,
renderer: RendererType,
driver: Driver,

/// Input latency trace (`-Dtrace-latency`), created in `init` and written
/// to `latency_path` in `deinit` once the driver has stopped.
latency: latency_trace.Handle = latency_trace.none,
/// Where the trace goes: `$REX_LATENCY_TRACE`, or `latency-<pid>.csv` in
/// the state directory. Owned, freed in `deinit`.
latency_path: if (latency_trace.enabled) []u8 else void =
    if (latency_trace.enabled) &.{} else {},

word_classifier: unicode.Classifier,

// Wellbeing & Focus state
wellbeing_state: wellbeing.Wellbeing,
/// Owned, destroyed in `deinit` and restarted on a config reload; see
/// `startWellbeingWatch`.
wellbeing_watch: ?*FileWatch = null,
local_clock: wellbeing.localtime.Clock = .{},
/// Serial of the toast currently representing a non-locking wellbeing alert,
/// so dismissing either side keeps the other in sync.
wellbeing_toast_serial: ?u32 = null,
/// Null only if the bundled UI fonts could not be loaded on startup.
kit: ?*KitOverlay = null,
/// Lazily created instanced renderer for the fullscreen wellbeing ASCII overlay.
ascii_overlay: ?*renderer_mod.AsciiOverlay = null,
/// Pre-parsed UTF-8 frame animation loaded from `[wellbeing.ascii] file`, when set.
ascii_frames: ?kit_ascii_canvas.Frames = null,
/// Monotonic animation clock and redraw pacer for the fullscreen ASCII overlay.
ascii_state: AsciiOverlayState = .{},
/// Config or startup banner deferred while this window was unfocused.
pending_banner: ?PendingAlert = null,

window: Window,
/// Owns the native platform process for this application's lifetime.
platform: Platform,

// Mouse reporting state
mouse_x: f32 = 0,
mouse_y: f32 = 0,
/// Cell of the last button or motion report, so motion is reported once
/// per cell.
mouse_report_col: u16 = 0,
mouse_report_row: u16 = 0,
mouse_held: HeldButtons = .{},
mouse_last_click_ms: f64 = 0,
mouse_last_click_pos: rex.Selection.Position = .empty,
mouse_click_count: u2 = 0,
pointer_visibility: PointerVisibility = .{ .visible = .{} },
/// Modifier state from key events, used for the link tooltip. The platform
/// key query is not reliable on every backend; an event's own modifiers are.
mods_down: rex.input.Modifiers = .{},
/// Last resolved hover state, so a change in link or modifier repaints the
/// tooltip without waiting for another event.
link_hint_id: u16 = 0,
link_hint_visible: bool = false,

// Selection state
selection: rex.Selection = .empty,
/// Pending Ctrl+click on a link: only opened if release lands on the same cell.
pending_link: ?struct { row: u16, col: u16, id: u16 } = null,

// Scrollbar and Scrolling state
scroll_accumulator_y: f64 = 0,
scrollbar_drag_offset_y: f32 = 0,
scrollbar_dragging: bool = false,

// Font state
/// Current font size, in logical pixels (pixels at 100% scale).
font_size: u32,
font_size_pending: ?u32 = null,
/// The window's display scale (1.0 at 100%). Every size in logical pixels
/// is multiplied by it on the way to the screen: today the font, later UI
/// geometry too.
content_scale: f32,
/// A scale reported by the content-scale callback, applied by
/// `applyContentScale` from the framebuffer-size callback that follows it,
/// or from the event loop when no size change follows.
content_scale_pending: ?f32 = null,

needs_redraw: bool = true,
renderer_dirty: bool = false,
quit_confirmed: bool = false,
skip_next_char: bool = false,
dialog_kind: DialogKind = .none,
clipboard_session: ClipboardSession = .{},
pending_clipboard: PendingClipboard = .none,

// Blink state
blink_on: bool = true,
blink_rapid_on: bool = true,
blink: PeriodicTimer,
blink_rapid: PeriodicTimer,

// Frame timing, focus and size tracking
last_frame: std.Io.Clock.Timestamp,
/// Draws a due frame just before vblank. Idle turns leave it unused.
frame_latch: FrameLatch = .{},
window_focused: bool = true,
/// The last wellbeing sync error, so a failure that repeats every second is
/// reported once and its end is reported too; null while syncs succeed.
wellbeing_sync_error: ?wellbeing.Wellbeing.SyncError = null,
frame_buffer_size: Dimension(u16),
/// Top-left pixel origin of cell `(0, 0)` within the framebuffer (scaled inner padding).
grid_origin: [2]f32 = .{ 0.0, 0.0 },
/// Main-thread copy of an OSC 52 write, with room for the NUL GLFW needs.
/// Owned; freed in `deinit`.
clipboard_buf: *[terminal_option.max_clipboard_bytes + 1]u8,

// Environment data
dirs: rex.dirs.Application,
/// How rex was started, for when /proc/self/exe cannot be read.
argv0: []const u8,

/// Counts whole `period_ms` periods as time passes. A period of 0
/// disables the timer: it never fires and sets no deadline.
pub const PeriodicTimer = struct {
    period_ms: u64,
    elapsed_ms: u64 = 0,

    /// Adds `dt_ms` and returns how many periods ended.
    pub fn tick(self: *PeriodicTimer, dt_ms: u64) u64 {
        if (self.period_ms == 0) return 0;
        const total = self.elapsed_ms + dt_ms;
        self.elapsed_ms = total % self.period_ms;
        return total / self.period_ms;
    }

    /// Milliseconds until the current period ends, or the largest u64
    /// when the timer is disabled.
    pub fn remaining(self: *const PeriodicTimer) u64 {
        if (self.period_ms == 0) return std.math.maxInt(u64);
        return self.period_ms - self.elapsed_ms;
    }

    /// Updates `period_ms`, clamping `elapsed_ms` so `remaining` never underflows.
    pub fn setPeriod(self: *PeriodicTimer, period_ms: u64) void {
        self.period_ms = period_ms;
        if (period_ms == 0) {
            self.elapsed_ms = 0;
        } else if (self.elapsed_ms >= period_ms) {
            self.elapsed_ms %= period_ms;
        }
    }
};

pub const PointerVisibility = union(enum) {
    visible: Visible,
    hidden,

    pub const Visible = struct {
        idle_ms: u64 = 0,
    };

    pub const Rules = struct {
        mode: Config.Window.MouseAutoHide,
        timeout_ms: ?u64 = null,

        /// Hiding is fully disabled: the pointer never hides on its own.
        fn disabled(self: Rules) bool {
            return self.mode == .never and self.timeout_ms == null;
        }
    };

    /// Live window state. Changes every frame.
    pub const State = struct {
        focused: bool,
        modal_active: bool = false,

        fn suspended(self: State) bool {
            return !self.focused or self.modal_active;
        }
    };

    pub fn onTyping(self: *PointerVisibility, rules: Rules, window: State) bool {
        if (rules.mode != .on_typing or window.suspended()) return false;

        switch (self.*) {
            .hidden => return false,
            .visible => {
                self.* = .hidden;
                return true;
            },
        }
    }

    pub fn show(self: *PointerVisibility) bool {
        switch (self.*) {
            .hidden => {
                self.* = .{ .visible = .{} };
                return true;
            },
            .visible => |*v| {
                v.idle_ms = 0;
                return false;
            },
        }
    }

    pub fn tick(self: *PointerVisibility, dt_ms: u64, rules: Rules, window: State) bool {
        const is_suspended = window.suspended();
        const is_disabled = rules.disabled();

        switch (self.*) {
            // Come back when auto-hide is paused, or when hiding is disabled.
            .hidden => {
                if (is_suspended or is_disabled) {
                    self.* = .{ .visible = .{} };
                    return true;
                }
                return false;
            },
            .visible => |*v| {
                if (is_suspended) {
                    v.idle_ms = 0;
                    return false;
                }
                const limit = rules.timeout_ms orelse {
                    v.idle_ms = 0;
                    return false;
                };
                v.idle_ms +|= dt_ms;
                if (v.idle_ms >= limit) {
                    self.* = .hidden;
                    return true;
                }
                return false;
            },
        }
    }

    pub const default_wake_ms = std.math.maxInt(u64);

    pub fn wakeMs(self: PointerVisibility, rules: Rules, window: State) u64 {
        if (window.suspended()) return default_wake_ms;
        const limit = rules.timeout_ms orelse default_wake_ms;
        return switch (self) {
            .hidden => std.math.maxInt(u64),
            .visible => |v| if (limit > v.idle_ms) limit - v.idle_ms else 1,
        };
    }

    pub fn isVisible(self: PointerVisibility) bool {
        return self == .visible;
    }
};

/// Resolves the window pointer shape from the topmost hit surface.
pub fn resolvePointerShape(
    kit_pointer: ?rex.kit.Tree.PointerShape,
    modal_active: bool,
    scrollbar_active: bool,
    mouse_reporting: bool,
    shift_held: bool,
    link_hover: bool,
) Window.PointerShape {
    if (kit_pointer) |kp| return switch (kp) {
        .arrow => .arrow,
        .hand => .hand,
        .text => .text,
    };
    if (modal_active or scrollbar_active) return .arrow;
    // A link under the pointer is clickable with Ctrl even during mouse
    // reporting, so it keeps the hand over the terminal's text shape.
    if (link_hover) return .hand;
    if (mouse_reporting and !shift_held) return .arrow;
    return .text;
}

/// Picks the moment to draw so `swapBuffers` blocks for about `margin_ns`
/// instead of a whole refresh. `next_vblank_ns == 0` means the next vblank
/// is not known: startup, an idle gap, or a swap that did not wait.
const FrameLatch = struct {
    /// Nanoseconds between refreshes. Starts at the monitor's rate (`init`)
    /// and follows the gap between two swaps that waited for consecutive
    /// vblanks (`observe`).
    period_ns: u64 = 1_000_000_000 / fallback_hz,
    /// How long the swap should still block after the draw is submitted.
    margin_ns: u64 = 1_500_000,
    /// Recent build and draw time, kept so the wait ends early enough to
    /// finish the frame inside the margin.
    render_ns: u64 = 300_000,
    /// Awake-clock time of the next vblank, or 0 when it is not known.
    next_vblank_ns: u64 = 0,
    /// Last swap return that waited for a vblank, or 0.
    last_vblank_ns: u64 = 0,
    /// Added to the vblank estimated from the last blocking swap. Positive
    /// draws later. A swap that returns without waiting drives this down,
    /// and the next frame is drawn at once so its block can reanchor.
    shift_ns: i64 = 0,
    /// This draw was aimed at `next_vblank_ns`. Cleared once the swap is
    /// observed, including when the frame had nothing dirty to swap.
    used_prediction: bool = false,

    /// A gap outside the range around `period_ns` (2-50 ms), kept until a
    /// second one agrees with it; then it replaces the period. 0 when none.
    /// Lets a wrong start (the window is not on the primary monitor, or
    /// moved) correct itself.
    candidate_ns: u64 = 0,

    /// Used when the monitor's refresh rate is unknown.
    const fallback_hz = 60;
    /// Refresh periods considered real: 500 Hz to 20 Hz.
    const min_period_ns = 2_000_000;
    const max_period_ns = 50_000_000;

    /// A latch for a display refreshing at `refresh_hz`, or at 60 Hz when
    /// that is unknown. The period adapts to the measured swaps either way.
    fn init(refresh_hz: ?u32) FrameLatch {
        const hz: u64 = refresh_hz orelse fallback_hz;
        return .{ .period_ns = 1_000_000_000 / @max(hz, 1) };
    }

    fn leadNs(self: *const FrameLatch) u64 {
        return self.margin_ns +| self.render_ns;
    }

    /// The stored vblank is still the upcoming refresh. Two periods covers
    /// a late aim. A longer gap is an idle stretch, and sleeping toward it
    /// would delay a key.
    fn pending(self: *const FrameLatch, now_ns: u64) bool {
        const vb = self.next_vblank_ns;
        if (vb == 0 or now_ns >= vb) return false;
        return vb - now_ns <= self.period_ns *| 2;
    }

    /// Nanoseconds to sleep before drawing. Zero means draw now: the vblank
    /// is unknown, already inside the lead, or left over from an idle gap.
    fn sleepNs(self: *const FrameLatch, now_ns: u64) u64 {
        if (!self.pending(now_ns)) return 0;
        const until_vb = self.next_vblank_ns - now_ns;
        const lead = self.leadNs();
        if (until_vb <= lead) return 0;
        return until_vb - lead;
    }

    /// `render_ns` is the build and draw that just finished, before the swap.
    /// A swap that returns without waiting is not a vblank sample.
    fn observe(self: *FrameLatch, swap_enter_ns: u64, swap_return_ns: u64, render_ns: u64) void {
        const predicted = self.used_prediction;
        self.used_prediction = false;
        if (swap_return_ns < swap_enter_ns) return;
        const block = swap_return_ns - swap_enter_ns;

        if (render_ns > 0 and render_ns < 20_000_000) {
            self.render_ns = (self.render_ns *| 3 +| render_ns) / 4;
            if (self.render_ns < 200_000) self.render_ns = 200_000;
        }

        // A real wait is longer than a scheduling hiccup. However long it
        // was, it ended at a vblank, so it anchors the next one; bounding it
        // by the current period would lock out a period that started wrong.
        const trusted = block >= 400_000 and block <= max_period_ns;
        if (!trusted) {
            // Aim was past the vblank. Drop it and draw the next frame
            // immediately: that swap blocks for a refresh and reanchors.
            // Shifting earlier keeps the following aim on the safe side.
            if (predicted and block < 400_000) self.bump(-500_000);
            self.next_vblank_ns = 0;
            return;
        }

        // The gap since the last vblank is a sample of the period only when
        // no vblank passed in between. A swap never waits longer than one
        // refresh, so a swap that waited at least as long as the time that
        // went by before it started within one refresh of that vblank, and
        // ended at the very next one. Frames drawn at typing pace fail this:
        // their gaps are several refreshes and must not be learned.
        if (self.last_vblank_ns != 0 and swap_enter_ns >= self.last_vblank_ns) {
            const idle = swap_enter_ns - self.last_vblank_ns;
            if (idle <= block) self.samplePeriod(idle + block);
        }
        self.last_vblank_ns = swap_return_ns;

        if (predicted and block > self.margin_ns +| 300_000) {
            const extra = block - self.margin_ns;
            self.bump(@intCast(@min(extra / 2, 200_000)));
        } else if (predicted and self.margin_ns > block +| 300_000) {
            const deficit = self.margin_ns - block;
            self.bump(-@as(i64, @intCast(@min(deficit / 2, 200_000))));
        }
        self.arm(swap_return_ns);
    }

    /// Folds `gap`, the time between two consecutive vblanks, into
    /// `period_ns`. Half to one and a half periods refines the average.
    /// Anything else between 2 and 50 ms means the period is wrong (or the
    /// swap stalled): it becomes the period only when the next such gap
    /// agrees within 10%. The period never leaves 2 to 50 ms.
    fn samplePeriod(self: *FrameLatch, gap: u64) void {
        if (gap >= self.period_ns / 2 and gap <= self.period_ns + self.period_ns / 2) {
            self.period_ns = std.math.clamp((self.period_ns *| 7 +| gap) / 8, min_period_ns, max_period_ns);
            self.candidate_ns = 0;
            return;
        }
        if (gap < min_period_ns or gap > max_period_ns) return;
        const prev = self.candidate_ns;
        if (prev != 0 and @max(gap, prev) - @min(gap, prev) <= prev / 10) {
            self.period_ns = (gap + prev) / 2;
            self.candidate_ns = 0;
        } else {
            self.candidate_ns = gap;
        }
    }

    /// Moves `shift_ns` and keeps it inside three milliseconds. A larger
    /// step walks the aim past the vblank; the swap then stops blocking.
    fn bump(self: *FrameLatch, delta_ns: i64) void {
        const sum = self.shift_ns +| delta_ns;
        self.shift_ns = std.math.clamp(sum, -3_000_000, 3_000_000);
    }

    fn arm(self: *FrameLatch, swap_return_ns: u64) void {
        const base = swap_return_ns +| self.period_ns;
        if (self.shift_ns >= 0) {
            self.next_vblank_ns = base +| @as(u64, @intCast(self.shift_ns));
        } else {
            self.next_vblank_ns = base -| @as(u64, @intCast(-self.shift_ns));
        }
    }
};

fn awakeNs(io: std.Io) u64 {
    return @intCast(std.Io.Clock.Timestamp.now(io, .awake).raw.toNanoseconds());
}

pub fn init(
    self: *App,
    gpa: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ,
    argv0: []const u8,
    config: *const Config,
    custom_config_path: ?[]const u8,
) !void {
    log.debug("envi.block.len: {d}", .{environ.block.slice.len});

    const home_dir = try environ.getAlloc(gpa, "HOME");
    errdefer gpa.free(home_dir);
    if (!std.fs.path.isAbsolute(home_dir)) {
        return error.InvalidHomeDir;
    }

    log.debug("envi $HOME: '{s}'", .{home_dir});

    var envmap = try environ.createMap(gpa);
    defer envmap.deinit();

    const wayland_session = envmap.get("WAYLAND_DISPLAY") != null or
        std.mem.eql(u8, envmap.get("XDG_SESSION_TYPE") orelse "", "wayland");

    var dirs = try rex.dirs.Application.resolve(
        gpa,
        terminal_option.name,
        home_dir,
        &envmap,
    );
    errdefer dirs.deinit(gpa);

    log.debug("dirs: {f}", .{dirs});

    // The user file: the --config path, else <config dir>/config.
    const user_cfg_path: []const u8 = if (custom_config_path) |ccp|
        try gpa.dupe(u8, ccp)
    else
        try rex.config.paths.user(gpa, &dirs);
    errdefer gpa.free(user_cfg_path);

    // At startup a file with errors still applies its valid entries; the
    // banner names the first problem (decision P4).
    var loaded = try Loaded.load(gpa, io, config, home_dir, &.{ .file(rex.config.paths.system), .file(user_cfg_path) });
    defer loaded.deinit(gpa);
    logConfigDiagnostics(gpa, &loaded);
    // Before takeArena: the filled paths live in this arena.
    useBuiltinFonts(io, loaded.arena.allocator(), &loaded, argv0) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.BadExePath => {
            log.err("no font: set `file` in [font] of {s}; the executable path is not usable", .{user_cfg_path});
            return error.NoFontFile;
        },
        error.BuiltinFontMissing => {
            log.err("no font: set `file` in [font] of {s}; missing {s}", .{ user_cfg_path, missingBuiltinFace(io, loaded.arena.allocator(), argv0) });
            return error.NoFontFile;
        },
    };
    var startup_banner = configBanner(&loaded);
    var config_arena = loaded.takeArena();
    errdefer config_arena.deinit();
    var active_config = loaded.config;
    // Clamped like every later size change (setFontSize).
    active_config.font.size = @max(active_config.font.min_size, @min(active_config.font.size, active_config.font.max_size));
    if (!hasFontFile(active_config.font)) {
        log.err("no font: set `file` in [font] of {s}", .{user_cfg_path});
        return error.NoFontFile;
    }

    // apply user's overrides environment values
    for (active_config.environments) |*envp| {
        try envmap.put(envp.key, envp.value);
    }

    const block: std.process.Environ.Block = switch (native_os) {
        .windows => try envmap.createWindowsBlock(gpa, .{}),
        else => try envmap.createPosixBlock(gpa, .{}),
    };
    defer block.deinit(gpa);

    // Without a configured program, the user's shell, like other terminals.
    const login_shell = try gpa.dupeZ(u8, defaultShell(envmap.get("SHELL"), passwdShell()));
    defer gpa.free(login_shell);

    // A [shell] setting that can't start (a missing program or directory)
    // must not keep Rex from starting: fall back to the login shell in
    // Rex's own directory, and say so.
    var failure: ?rex.termio.pty.SpawnFailure = null;
    var pty = spawnShell(gpa, io, active_config.shell, login_shell, block.slice, &failure) catch |err| switch (err) {
        error.SpawnFailed => if (isDefaultShell(active_config.shell)) {
            if (failure) |f| log.err("the shell failed to start: {f}", .{f}) else log.err("the shell failed to start: {}", .{err});
            return err;
        } else blk: {
            var message_buf: [256]u8 = undefined;
            const message = if (failure) |f|
                std.fmt.bufPrint(&message_buf, "[shell]: {f}; started {s} instead", .{ f, login_shell }) catch "[shell] failed to start; started the login shell instead"
            else
                "[shell] failed to start; started the login shell instead";
            log.err("{s}", .{message});
            startup_banner = PendingAlert.init(.err, "Shell error", message);
            break :blk try spawnShell(gpa, io, .{}, login_shell, block.slice, &failure);
        },
        else => return err,
    };
    errdefer pty.close(io);

    log.debug("termio.pty: {f}", .{pty});

    const platform_choice: Choice = Platform.choose(active_config.window.platform, wayland_session);
    log.debug("platform: {f}, forced: {}", .{ platform_choice, platform_choice.forced });

    var app_platform: Platform = try .init(platform_choice);
    errdefer app_platform.deinit();
    var win: Window = try app_platform.createWindow(.{
        .width = active_config.window.size.width,
        .height = active_config.window.size.height,
        .title = active_config.window.title orelse Config.Window.default_title,
        .decorated = active_config.window.decorations == .full,
    });
    errdefer win.deinit();

    // The font is rasterized at the display's scale; the config's size is
    // in logical pixels.
    const content_scale = win.contentScale().width;
    const font_pixels: Freetype.FontConfig = .{
        .faces = active_config.font.faces,
        .height = Freetype.FontConfig.pixelSize(active_config.font.size, content_scale),
    };
    log.info("display scale {d:.2}, font {d} px for size {d}", .{
        content_scale,
        font_pixels.height,
        active_config.font.size,
    });
    var rasterizer: Rasterizer = try .init(gpa, font_pixels);
    errdefer rasterizer.deinit(gpa);

    var atlas: Atlas = try .init(gpa, .{});
    errdefer atlas.deinit();

    const decoration_option = decoration_config.build(&active_config);
    var frame_builder: FrameBuilderType = try .init(gpa, .{
        .dim_alpha = active_config.window.dim_alpha,
        .decoration = decoration_option,
    });
    errdefer frame_builder.deinit(gpa);

    atlas.preRasterize(gpa, &rasterizer, .{ .start = 0x20, .end = 0x7F });

    var renderer: RendererType = try .init(.{
        .background = active_config.window.background,
        .font_metrics = rasterizer.metrics,
        .cursor = rendererCursorOption(active_config.cursor),
        .decoration = decoration_option,
        .scrollbar = rendererScrollbarOption(active_config.scrollbar),
        .selection = rendererSelectionOption(active_config.selection),
        .modal_blur = active_config.window.modal.blur,
        .modal_blur_radius = active_config.window.modal.blur_radius,
        // The renderer stores the configured effects; `draw` applies the
        // current focus itself, so query the helpers as if unfocused.
        .inactive_blur = active_config.window.effectiveInactiveBlur(false),
        .inactive_blur_radius = active_config.window.inactive_blur_radius,
        .inactive_dim_alpha = renderer_mod.Frame.alphaByte(active_config.window.effectiveInactiveDimAlpha(false)),
    });
    errdefer renderer.deinit();

    var wellbeing_state = wellbeing.Wellbeing.init(active_config.wellbeing);
    const open_ms: i64 = @intCast(std.Io.Clock.Timestamp.now(io, .real).raw.toMilliseconds());
    wellbeing_state.open(io, dirs.state, open_ms) catch |err| {
        log.warn("cannot read wellbeing state in {s}: {t}; starting empty", .{ wellbeing_state.stateDir(dirs.state), err });
    };
    const wellbeing_watch = startWellbeingWatch(gpa, &wellbeing_state, dirs.state);
    errdefer if (wellbeing_watch) |watch| watch.destroy(gpa);

    // Created before the driver, which writes to it, and destroyed after it.
    const latency: latency_trace.Handle = if (latency_trace.enabled) try latency_trace.Trace.create(gpa) else {};
    errdefer if (latency_trace.enabled) latency.?.destroy(gpa);
    const latency_path = if (latency_trace.enabled) environ.getAlloc(gpa, "REX_LATENCY_TRACE") catch |err| switch (err) {
        error.EnvironmentVariableMissing => try std.fmt.allocPrint(gpa, "{s}/latency-{d}.csv", .{ dirs.state, std.c.getpid() }),
        else => |e| return e,
    } else {};
    errdefer if (latency_trace.enabled) gpa.free(latency_path);
    if (latency_trace.enabled) {
        log.info("latency trace: writing to {s} on exit", .{latency_path});
    }

    // XTGETTCAP reports the TERM the shell got, config override included.
    const term_name: TermName = TermName.init(envmap.get("TERM") orelse "") catch blk: {
        log.warn("TERM is longer than {d} bytes; XTGETTCAP will not report it", .{rex.terminal.term.max_term_name_len});
        break :blk .empty;
    };
    const resolved_theme = active_config.resolvedTheme();
    const driver_options: rex.driver.Options = .{
        .theme = resolved_theme,
        .sync_output_timeout_ms = sync_output_timeout_ms,
        .term_name = term_name,
    };
    // The single-threaded driver is for tests.
    var driver: Driver = .{ .threaded = try ThreadedDriverType.create(gpa, io, pty, driver_options, latency) };
    errdefer driver.deinit();

    const clipboard_buf = try gpa.create([terminal_option.max_clipboard_bytes + 1]u8);
    errdefer gpa.destroy(clipboard_buf);

    driver.setWakeupFn(Platform.postWakeup);

    const background_alpha = active_config.window.background.alpha;

    const classifier = try unicode.Classifier.init(active_config.selection.classifier);
    const now = std.Io.Clock.Timestamp.now(io, .awake);

    const watcher: ?rex.config.Watcher = rex.config.Watcher.init(
        std.fs.path.dirname(user_cfg_path) orelse dirs.config,
        std.fs.path.basename(user_cfg_path),
    );

    if (is_posix) {
        posix.sigaction(.HUP, &.{
            .handler = .{ .handler = sighupHandler },
            .mask = posix.sigemptyset(),
            .flags = 0,
        }, null);
    }

    const kit = createKit(gpa, io, argv0, content_scale, active_config.font.faces.regular);
    errdefer if (kit) |k| k.destroy(gpa);
    var ascii_frames = loadAsciiFrames(gpa, io, active_config.window.wellbeing_ascii.file);
    errdefer if (ascii_frames) |*frames| frames.deinit(gpa);
    var initial_pending_banner: ?PendingAlert = null;
    if (kit) |k| {
        k.configure(kitOverlayOptions(active_config.ui, active_config.window));
        if (active_config.wellbeing.enabled and active_config.window.wellbeing_widget.default_visible) {
            _ = k.toggleWellbeingWidget();
            _ = k.syncWellbeingWidget(wellbeingWidgetSnapshot(&wellbeing_state));
        }
        if (active_config.window.banner.enabled) {
            if (startup_banner) |b| {
                if (win.focused()) {
                    _ = k.showAlert(b.request());
                } else {
                    initial_pending_banner = b;
                }
            }
        }
    }

    self.* = .{
        .io = io,
        .driver = driver,
        .latency = latency,
        .latency_path = latency_path,
        .window = win,
        .platform = app_platform,
        .frame_latch = .init(app_platform.primaryRefreshHz()),
        .background_color = normalizedRgba(resolved_theme.background, background_alpha),
        .blink = .{ .period_ms = active_config.cursor.blink_interval_ms },
        .blink_rapid = .{ .period_ms = active_config.cursor.rapid_blink_interval_ms },
        .dirs = dirs,
        .argv0 = argv0,
        .allocator = gpa,
        .renderer = renderer,
        .rasterizer = rasterizer,
        .atlas = atlas,
        .frame_builder = frame_builder,
        .config = active_config,
        .config_arena = config_arena,
        .base_config = config,
        .config_watcher = watcher,
        .config_path = user_cfg_path,
        .home_dir = home_dir,
        .font_size = active_config.font.size,
        .content_scale = content_scale,
        .wellbeing_state = wellbeing_state,
        .wellbeing_watch = wellbeing_watch,
        .kit = kit,
        .ascii_frames = ascii_frames,
        .pending_banner = initial_pending_banner,
        .frame_buffer_size = .empty,
        .clipboard_buf = clipboard_buf,
        .last_frame = now,
        .word_classifier = classifier,
    };
}

pub fn deinit(self: *App, gpa: std.mem.Allocator) void {
    // First: its thread wakes GLFW, which the window's deinit ends.
    if (self.wellbeing_watch) |watch| watch.destroy(gpa);
    self.wellbeing_watch = null;
    if (self.config_watcher) |*w| w.deinit();
    gpa.free(self.config_path);
    gpa.free(self.home_dir);

    if (self.ascii_frames) |*frames| frames.deinit(gpa);
    self.ascii_frames = null;
    if (self.ascii_overlay) |ao| ao.destroy(gpa);
    self.ascii_overlay = null;
    if (self.kit) |kit| kit.destroy(gpa);
    self.renderer.deinit();
    self.frame_builder.deinit(gpa);
    self.atlas.deinit();
    self.rasterizer.deinit(gpa);
    self.window.deinit();
    self.platform.deinit();
    self.driver.deinit();
    gpa.destroy(self.clipboard_buf);
    if (latency_trace.enabled) {
        // The driver's worker has been joined, so the trace is complete.
        if (self.latency.?.writeFile(self.io, self.latency_path)) {
            log.info("latency trace written to {s}", .{self.latency_path});
        } else |err| {
            log.err("cannot write the latency trace to {s}: {}", .{ self.latency_path, err });
        }
        self.latency.?.destroy(gpa);
        gpa.free(self.latency_path);
    }

    // No toast: the window is closing.
    self.wellbeing_state.sync(self.io, self.dirs.state, self.wallSeconds(), .merge) catch |err| {
        log.err("cannot save wellbeing state in {s}: {t}", .{ self.wellbeing_state.stateDir(self.dirs.state), err });
    };
    self.wellbeing_state.close(self.io);
    self.dirs.deinit(gpa);
    // Last: the window, rasterizer and driver above were set up from config
    // values that live here.
    self.config_arena.deinit();
}

pub fn tick(self: *App, dt_ms: u64) bool {
    var changed = false;

    if ((self.blink.tick(dt_ms) & 1) != 0) {
        self.blink_on = !self.blink_on;
        changed = true;
    }

    if ((self.blink_rapid.tick(dt_ms) & 1) != 0) {
        self.blink_rapid_on = !self.blink_rapid_on;
        changed = true;
    }
    return changed;
}

pub fn run(self: *App) !void {
    // initialize window size and pty window size
    {
        const frame_buffer_size = self.window.framebufferSize(u16);
        self.handleResize(frame_buffer_size);
    }

    // The platform backend installs the window callbacks when it creates the
    // window; events are drained from its ring after each event-loop wait.
    // A window can open unfocused and then never get a focus event. Both
    // flags start true, so that window would count screen time and fire
    // reminders. Assigning the flag skips `windowFocusChanged`, which would
    // count the open itself as activity.
    const focused_now = self.window.focused();
    self.window_focused = focused_now;
    self.wellbeing_state.window_focused = focused_now;
    self.syncWindowEffects();
    if (focused_now) self.applyPendingBanner();

    start: while (true) {
        if (self.window.shouldClose()) {
            if (self.config.window.on_close == .close or self.quit_confirmed) break :start;
            self.requestQuit();
        }
        const now = std.Io.Clock.Timestamp.now(self.io, .awake);
        const dt = self.last_frame.durationTo(now);
        self.last_frame = now;
        const dt_ms: u64 = @intCast(dt.raw.toMilliseconds());
        const dt_clamped: u64 = @min(dt_ms, 500);

        const blink_changed = self.tick(dt_clamped);
        var title_updated = false;

        const now_real = std.Io.Clock.Timestamp.now(self.io, .real);
        const local_s = self.local_clock.localSeconds(@intCast(now_real.raw.toSeconds()));

        const wb_res = self.wellbeing_state.tick(dt_clamped, self.driver.getMasterFd(), local_s, @intCast(now_real.raw.toMilliseconds()));
        if (self.renderer.grayscale != wb_res.grayscale or !std.meta.eql(self.renderer.color_tint, wb_res.tint)) {
            self.renderer.grayscale = wb_res.grayscale;
            self.renderer.color_tint = wb_res.tint;
            self.renderer_dirty = true;
            self.needs_redraw = true;
        }
        if (wb_res.needs_redraw) {
            self.renderer_dirty = true;
            self.needs_redraw = true;
        }
        self.syncWellbeing(@intCast(now_real.raw.toSeconds()));
        if (wb_res.phase_changed or wb_res.alert != null) self.ringBell();
        self.syncWellbeingKit(wb_res.alert != null);
        if (self.ascii_state.tick(
            dt_clamped,
            self.wellbeingOverlayMode().showsAscii(),
            self.frame_buffer_size.width > 0 and self.frame_buffer_size.height > 0,
            self.config.ui.motion,
            self.config.window.wellbeing_ascii.fps,
        )) {
            self.renderer_dirty = true;
            self.needs_redraw = true;
        }

        var had_data = false;
        const driver_events = try self.driver.pollAndDrain();
        const f = driver_events.bits();

        if (f.had_data) {
            had_data = true;
            self.needs_redraw = true;
        }

        if (f.bell) self.ringBell();

        if (driver_events.getResize()) |resize| {
            self.driver.sendInput(.{
                .resize = .{
                    .rows = resize.rows,
                    .cols = resize.cols,
                    .pixel_width = self.frame_buffer_size.width,
                    .pixel_height = self.frame_buffer_size.height,
                },
            }) catch |err| {
                log.err("driver resize failed: {}", .{err});
            };
            self.needs_redraw = true;
        }

        if (f.hard_reset) {
            self.selection = .empty;
            self.frame_buffer_size = .empty;
            self.handleResize(self.window.framebufferSize(u16));
        }

        if (f.selection_reset) {
            self.selection = .empty;
            self.needs_redraw = true;
        }

        if (f.clipboard) self.handleClipboard();

        if (f.title or f.hard_reset) {
            title_updated = true;
            self.updateWindowTitle();
        }

        if (f.child_closed) {
            break :start;
        }

        if (self.content_scale_pending) |scale| {
            self.applyContentScale(scale);
            self.content_scale_pending = null;
        }

        if (self.font_size_pending) |size| {
            self.setFontSize(size);
            self.font_size_pending = null;
        }

        if (self.kit) |kit| {
            // The real time: a toast whose wakeup is seconds away must not
            // have that sleep clamped, or it would stay several times as long.
            if (kit.tick(dt_ms)) self.needs_redraw = true;
            self.syncWellbeingKit(false);
        }
        self.tickPointerIdle(dt_ms);
        if (self.renderer.tick(dt_clamped)) {
            self.renderer_dirty = true;
            self.needs_redraw = true;
        }

        if (is_posix and sighup_pending.swap(false, .acq_rel)) {
            self.reloadConfig();
        }

        if (self.config_watcher) |*w| {
            if (w.checkChanged()) {
                self.reloadConfig();
            }
        }

        if (had_data or blink_changed or self.needs_redraw or self.driver.hasNewFrame()) {
            // Events keep flowing while this sleeps, so a key is queued and
            // its echo can be published before the draw latches the frame.
            self.waitUntilFrame();
            if (latency_trace.enabled) self.latency.?.setCause(blink_changed, title_updated);
            self.needs_redraw = false;
            _ = try self.renderFrame();
        }

        self.waitForNextEvent(had_data);
        if (latency_trace.enabled) self.latency.?.eventsHandled();
        self.flushScroll();
    }
}

fn syncWindowEffects(self: *App) void {
    const win_cfg = &self.config.window;
    self.background_color[3] = win_cfg.effectiveBackgroundAlpha(self.window_focused);
    self.renderer.background.option.alpha = self.background_color[3];
    // As in init: the renderer stores configured effects; draw applies focus.
    self.renderer.setInactiveEffects(
        win_cfg.effectiveInactiveBlur(false),
        win_cfg.inactive_blur_radius,
        renderer_mod.Frame.alphaByte(win_cfg.effectiveInactiveDimAlpha(false)),
    );
}

fn showPointer(self: *App) void {
    _ = self.pointer_visibility.show();
    self.window.setPointerVisible(true);
}

fn hidePointerOnTyping(self: *App) void {
    if (self.hasModalOverlay()) return;
    if (self.pointer_visibility.onTyping(
        .{
            .mode = self.config.window.mouse_auto_hide,
            .timeout_ms = self.config.window.mouse_idle_timeout_ms,
        },
        .{ .focused = self.window_focused },
    )) {
        self.window.setPointerVisible(false);
    }
}

fn tickPointerIdle(self: *App, dt_ms: u64) void {
    if (self.pointer_visibility.tick(
        dt_ms,
        .{
            .mode = self.config.window.mouse_auto_hide,
            .timeout_ms = self.config.window.mouse_idle_timeout_ms,
        },
        .{
            .focused = self.window_focused,
            .modal_active = self.hasModalOverlay(),
        },
    )) {
        self.window.setPointerVisible(self.pointer_visibility.isVisible());
    }
}

/// The link id under the pointer in `frame`, or 0 for no linked cell.
fn hoveredLinkId(self: *App, frame: *const FrameType) u16 {
    const col, const row = self.mouseCellPos(self.mouse_x, self.mouse_y);
    return frame.styleOf(frame.cellAt(row, col)).linkId();
}

/// Whether the configured modifier for `show_targets` is down.
fn linkHintEnabled(self: *App) bool {
    if (!self.config.hyperlink.enabled) return false;
    return switch (self.config.hyperlink.show_targets) {
        .never => false,
        .always => true,
        .ctrl => self.mods_down.ctrl,
        .cmd => self.mods_down.super,
        .alt => self.mods_down.alt,
        .shift => self.mods_down.shift,
    };
}

fn updatePointerShape(self: *App, shift_held: bool) void {
    const kit_pointer = if (self.kit) |kit|
        kit.pointerShape(self.mouse_x / self.content_scale, self.mouse_y / self.content_scale)
    else
        null;
    const scrollbar_active = self.scrollbar_dragging or self.renderer.scrollbar.hover;
    const mouse_reporting = self.driver.getModes().mouse_reporting;
    const frame = self.driver.getFrame();
    const link = self.hoveredLinkId(frame);
    const link_hover = link != 0 and frame.hyperlink(link) != null;
    const hint_visible = link_hover and self.linkHintEnabled() and
        !self.hasModalOverlay() and !scrollbar_active;
    if (link != self.link_hint_id or hint_visible != self.link_hint_visible) {
        self.link_hint_id = link;
        self.link_hint_visible = hint_visible;
        self.needs_redraw = true;
    }
    const shape = resolvePointerShape(
        kit_pointer,
        self.hasModalOverlay(),
        scrollbar_active,
        mouse_reporting,
        shift_held,
        link_hover,
    );
    // The renderer and platform shapes share their order and values.
    self.window.setPointerShape(shape);
}

/// Starts tracing bytes about to go to the driver; pair with
/// `latencyQueued`. Only with `-Dtrace-latency`.
fn latencyBeginSend(self: *App) u32 {
    return self.latency.?.beginSend(latency_trace.now(self.io));
}

/// The bytes traced as `seq` were pushed to the driver.
fn latencyQueued(self: *App, seq: u32) void {
    self.latency.?.stamp(seq, .queued, latency_trace.now(self.io));
}

fn renderFrame(self: *App) !bool {
    const render_enter = awakeNs(self.io);
    const atlas = &self.atlas;
    const current_frame = self.driver.getFrame();
    if (latency_trace.enabled) {
        self.latency.?.framePicked(self.driver.latencyFrameSeq(), latency_trace.now(self.io));
    }

    const selection_state = self.buildSelectionState(current_frame);

    // Resolve the link under the pointer before building the frame so the
    // decoration pass can underline it. A modal or the scrollbar takes the
    // hover away, matching the tooltip and the pointer shape.
    const hovered_link = self.hoveredLinkId(current_frame);
    // A link without a snapshot URI cannot be opened or shown, so it gets
    // no hover underline either.
    const clickable_hover = if (current_frame.hyperlink(hovered_link) != null) hovered_link else 0;
    self.frame_builder.hovered_link = if (self.hasModalOverlay() or
        self.scrollbar_dragging or self.renderer.scrollbar.hover) 0 else clickable_hover;

    var frame = try self.frame_builder.build(
        self.allocator,
        current_frame,
        atlas,
        &self.rasterizer,
        self.blink_on,
        selection_state,
        null,
    );

    const fb_width: f32 = @floatFromInt(self.frame_buffer_size.width);
    const fb_height: f32 = @floatFromInt(self.frame_buffer_size.height);
    var background: [3]u8 = undefined;
    for (&background, self.background_color[0..3]) |*out, channel| {
        out.* = @intFromFloat(@round(std.math.clamp(channel, 0, 1) * 255));
    }

    const overlay_mode = self.wellbeingOverlayMode();
    var ascii_ready = false;
    if (overlay_mode.showsAscii()) {
        if (self.ensureAsciiOverlay()) |ao| {
            const theme = self.config.ui.color_scheme.variant(background).theme();
            const accent = self.wellbeingAccent(theme);
            const backdrop: kit_theme.Color = .{
                .r = theme.background.r,
                .g = theme.background.g,
                .b = theme.background.b,
                .a = 242,
            };
            ao.prepare(self.allocator, atlas, &self.rasterizer, .{
                .source = self.asciiSource(),
                .aspect = self.config.window.wellbeing_ascii.cell_aspect,
                .time_s = self.ascii_state.timeSeconds(),
                .progress = self.wellbeingProgress(),
                .palette = kit_ascii_canvas.Palette.fromTheme(theme, accent),
                .backdrop = backdrop,
                .screen_w = fb_width,
                .screen_h = fb_height,
                .bottom_reserve_px = 0,
            }) catch |err| {
                log.err("cannot prepare ASCII overlay: {t}", .{err});
            };
            ascii_ready = true;
            if (!self.ascii_state.drawn_last) frame.dirty.overlay = true;
        }
    } else if (self.ascii_state.drawn_last) {
        frame.dirty.overlay = true;
    }

    var link_hint: ?KitOverlay.LinkHint = null;
    if (self.linkHintEnabled() and !self.hasModalOverlay() and
        !self.scrollbar_dragging and !self.renderer.scrollbar.hover and !ascii_ready)
    {
        if (hovered_link != 0) if (current_frame.hyperlink(hovered_link)) |uri| {
            link_hint = .{
                .uri = uri,
                .style = self.config.hyperlink.target_style,
                .layout = self.config.hyperlink.tooltip,
                .x = self.mouse_x / self.content_scale,
                .y = self.mouse_y / self.content_scale,
            };
        };
    }

    if (self.kit) |kit| {
        // The size `handleResize` last saw: asking the window is a
        // round trip to the X server on every frame.
        if (kit.buildFrame(atlas, fb_width / self.content_scale, fb_height / self.content_scale, background, link_hint)) {
            frame.dirty.overlay = true;
        }
        frame.overlay_has_modal = kit.hasScrim() and !ascii_ready;
    }
    const shift_held = self.platform.isKeyDown(self.window, .left_shift) or
        self.platform.isKeyDown(self.window, .right_shift);
    self.updatePointerShape(shift_held);

    if (!frame.dirty.any() and !self.renderer_dirty) {
        self.frame_latch.used_prediction = false;
        return false;
    }
    self.renderer_dirty = false;

    if (latency_trace.enabled) self.latency.?.frameBuilt(latency_trace.now(self.io));

    const dimension = self.window.framebufferSize(f32);
    self.renderer.draw(
        frame,
        atlas,
        dimension,
        self.background_color,
        self.window_focused,
        if (selection_state) |state| state.bg else null,
        .{ .blink_on = self.blink_on, .blink_rapid_on = self.blink_rapid_on },
    );
    if (ascii_ready) {
        if (self.ascii_overlay) |ao| ao.draw(atlas, dimension.width, dimension.height);
    }
    self.ascii_state.drawn_last = ascii_ready;
    if (self.kit) |kit| kit.draw(atlas, dimension.width, dimension.height);

    const swapped_seq = if (latency_trace.enabled) self.latency.?.frameDrawn(latency_trace.now(self.io)) else {};
    const swap_enter = awakeNs(self.io);
    self.window.swapBuffers();
    const swap_return = awakeNs(self.io);
    self.frame_latch.observe(swap_enter, swap_return, swap_enter -| render_enter);
    if (latency_trace.enabled and swapped_seq != 0) {
        self.latency.?.stamp(swapped_seq, .swapped, latency_trace.now(self.io));
    }
    return true;
}

/// Delivers every queued platform event in order, then reports any the
/// bounded ring had to drop.
fn drainPlatformEvents(self: *App) void {
    var event: PlatformEvents.Event = undefined;
    while (self.platform.nextEvent(&event)) {
        switch (event) {
            .key => |e| self.onKey(e),
            .text => |e| self.onText(e.codepoint),
            .preedit => {},
            .mouse_button => |e| self.onMouseButton(e),
            .cursor_pos => |e| self.onCursorPos(e.x, e.y),
            .scroll => |e| self.onScroll(e.dx, e.dy),
            .cursor_enter => |e| self.onCursorEnter(e.entered),
            .focus => |e| self.onFocus(e.focused),
            .framebuffer_size => |e| self.onFramebufferSize(e.width, e.height),
            .content_scale => |e| self.onContentScale(e.x, e.y),
            .close => self.onClose(),
        }
    }
    const dropped = self.platform.takeDropped();
    if (dropped > 0) log.warn("dropped {} platform events", .{dropped});
}

/// Sleeps until this frame's draw should start. The long gap is one sleep:
/// the event wait returns on the worker's empty event and was ending the
/// wait early. The last 1.5 ms is polled in short slices so a key and its
/// character are delivered while the echo can still publish.
fn waitUntilFrame(self: *App) void {
    self.frame_latch.used_prediction = self.frame_latch.pending(awakeNs(self.io));
    self.platform.pollEvents();
    self.drainPlatformEvents();
    while (true) {
        const sleep = self.frame_latch.sleepNs(awakeNs(self.io));
        if (sleep == 0) break;
        const slice: i96 = @intCast(if (sleep > 1_500_000) sleep - 1_500_000 else @min(sleep, 250_000));
        std.Io.sleep(self.io, .fromNanoseconds(slice), .awake) catch |err| switch (err) {
            // The Io is shutting down: stop waiting and draw now.
            error.Canceled => break,
        };
        self.platform.pollEvents();
        self.drainPlatformEvents();
    }
}

/// Polls when pty data arrived or a new frame is ready, else sleeps until the next blink or
/// focus tick or an input event (capped to 8ms if a redraw is pending).
fn waitForNextEvent(self: *App, had_data: bool) void {
    if (had_data or self.driver.hasNewFrame()) {
        self.platform.pollEvents();
        self.drainPlatformEvents();
        return;
    }

    const alert = self.wellbeing_state.current_alert;
    const animating = alert.kind != .none and alert.remaining_s > 0 and alert.show_animation and alert.animation != .none;
    const lock_active = self.wellbeing_state.input_locked and self.wellbeing_state.option.lock_screen.enabled;

    var ms = @min(
        self.blink.remaining(),
        @min(
            self.blink_rapid.remaining(),
            @min(
                self.wellbeing_state.focus_state.msUntilTick(),
                self.wellbeing_state.msUntilSync(self.wallMs()),
            ),
        ),
    );
    ms = @min(
        ms,
        self.pointer_visibility.wakeMs(
            .{
                .timeout_ms = self.config.window.mouse_idle_timeout_ms,
                .mode = self.config.window.mouse_auto_hide,
            },
            .{
                .focused = self.window_focused,
                .modal_active = self.hasModalOverlay(),
            },
        ),
    );
    if (self.kit) |kit| {
        if (kit.wakeMs()) |wake| ms = @min(ms, wake);
    }
    const ascii_active = self.wellbeingOverlayMode().showsAscii();
    if (self.ascii_state.wakeMs(
        ascii_active,
        self.frame_buffer_size.width > 0 and self.frame_buffer_size.height > 0,
        self.config.ui.motion,
        self.config.window.wellbeing_ascii.fps,
    )) |ascii_wake| {
        ms = @min(ms, ascii_wake);
    }
    if ((lock_active or ascii_active) and alert.remaining_s > 0) ms = @min(ms, 1000);
    if (animating and !ascii_active) ms = @min(ms, 33);
    if (self.needs_redraw) ms = @min(ms, 8);

    self.platform.waitEvents(@as(f64, @floatFromInt(ms)));
    self.drainPlatformEvents();
}

fn buildSelectionState(self: *App, frame: *const FrameType) ?SelectionState {
    if (self.selection.phase == .none) return null;

    const is_primary = !frame.is_alternate;

    const active_rows: i64 = @intCast(frame.active_rows);
    const active_cols: u16 = frame.active_cols;
    const total_lines_scrolled = frame.total_lines_scrolled;
    const scrollback_used: i64 = @intCast(frame.scrollback_used);

    const start_anchor = resolveAnchor(self.selection.range.start, total_lines_scrolled, scrollback_used) orelse return null;
    const end_anchor = resolveAnchor(self.selection.range.end, total_lines_scrolled, scrollback_used) orelse return null;
    const viewport_offset: i64 = @intCast(frame.viewport_offset);

    const start_row_i = start_anchor + viewport_offset;
    const end_row_i = end_anchor + viewport_offset;

    // Determine which raw endpoint is "lo" (topmost) vs "hi" (bottommost) in
    // display-row space, since start/end roles can be swapped for .word/.line.
    const start_is_lo = start_row_i <= end_row_i;

    const lo_row_i = if (start_is_lo) start_row_i else end_row_i;
    const hi_row_i = if (start_is_lo) end_row_i else start_row_i;

    const lo_col_raw = if (start_is_lo) self.selection.range.start.col else self.selection.range.end.col;
    const hi_col_raw = if (start_is_lo) self.selection.range.end.col else self.selection.range.start.col;

    // Both endpoints scrolled entirely out of view, nothing to draw.
    if (hi_row_i < 0 or lo_row_i > active_rows - 1) return null;

    // If the lo endpoint is clipped off the top, its column no longer means
    // anything (the actual row isn't visible), force it to column 0 so the
    // clipped row renders as a full-width band from the left edge.
    const lo_col: u16 = if (lo_row_i < 0) 0 else lo_col_raw;

    // Same for the hi endpoint clipped off the bottom, force to the last column.
    const hi_col: u16 = if (hi_row_i > active_rows - 1) active_cols - 1 else hi_col_raw;

    const lo_row: u16 = @intCast(std.math.clamp(lo_row_i, 0, active_rows - 1));
    const hi_row: u16 = @intCast(std.math.clamp(hi_row_i, 0, active_rows - 1));

    // Re-map back into start/end (preserving whichever role was actually "lo").
    const start_row, const start_col, const end_row, const end_col = if (start_is_lo)
        .{ lo_row, lo_col, hi_row, hi_col }
    else
        .{ hi_row, hi_col, lo_row, lo_col };

    // On the alternate buffer, apps manage their own selection highlighting.
    // Only apply the theme selection color on the primary buffer.

    const sel_theme = self.config.resolvedTheme();
    const foreground = blk: {
        if (frame.selection_foreground) |fg| break :blk fg;
        if (is_primary) break :blk sel_theme.selection_foreground.toArray();
        break :blk null;
    };

    const background = blk: {
        if (frame.selection_background) |bg| break :blk bg;
        if (is_primary) break :blk sel_theme.selection_background.toArray();
        break :blk null;
    };

    const fg_alpha: u8 = @intFromFloat(@round(self.config.selection.foreground_opacity * 255.0));

    return .{
        .active = true,
        .start_row = start_row,
        .start_col = start_col,
        .end_row = end_row,
        .end_col = end_col,
        .bg = background,
        .fg = foreground,
        .fg_alpha = fg_alpha,
        .kind = self.selection.kind,
    };
}

fn updateWindowTitle(self: *App) void {
    var buf: [rex.terminal.max_title_len:0]u8 = undefined;
    self.window.setTitle(windowTitle(self.config.window.title, self.driver.copyTitle(&buf)));
}

/// The title to show: the configured text when it is set, else the title
/// the program set, else `Config.Window.default_title`.
fn windowTitle(configured: ?[:0]const u8, program: [:0]const u8) [:0]const u8 {
    if (configured) |text| return text;
    return if (program.len > 0) program else Config.Window.default_title;
}

/// Rings the X bell at the configured volume (window attention only where
/// there is no audible bell), unless the bell is off or muted by wellbeing.
fn ringBell(self: *App) void {
    if (!self.config.window.bell.enabled) return;
    if (self.wellbeing_state.mute_audio_bell) return;
    self.window.ringBell(self.config.window.bell.volume);
}

pub const GridLayout = struct {
    cols: u16,
    rows: u16,
    origin_x: u16,
    origin_y: u16,
};

/// Converts logical padding pixels into physical framebuffer pixels at `content_scale`.
pub fn scaledPaddingPx(logical_px: u16, content_scale: f32) u16 {
    if (logical_px == 0) return 0;
    const scale: f32 = if (content_scale > 0) content_scale else 1.0;
    const scaled = @round(@as(f32, @floatFromInt(logical_px)) * scale);
    return @intFromFloat(std.math.clamp(scaled, 0.0, @as(f32, @floatFromInt(std.math.maxInt(u16)))));
}

/// Computes terminal grid dimensions and top-left pixel origin after applying
/// symmetric inner padding, shrinking padding when needed to keep at least one
/// cell whenever the framebuffer is at least one cell wide/tall.
pub fn gridLayout(
    fb_w: u16,
    fb_h: u16,
    cell_w: u16,
    cell_h: u16,
    pad_x: u16,
    pad_y: u16,
    max_cols: u16,
    max_rows: u16,
) GridLayout {
    if (cell_w == 0 or cell_h == 0) return .{ .cols = 0, .rows = 0, .origin_x = 0, .origin_y = 0 };
    const eff_x = @min(pad_x, (fb_w -| cell_w) / 2);
    const eff_y = @min(pad_y, (fb_h -| cell_h) / 2);
    const inner_w = fb_w -| (eff_x *| 2);
    const inner_h = fb_h -| (eff_y *| 2);
    return .{
        .cols = @min(inner_w / cell_w, max_cols),
        .rows = @min(inner_h / cell_h, max_rows),
        .origin_x = eff_x,
        .origin_y = eff_y,
    };
}

/// Maps physical framebuffer pointer coordinates onto a grid cell `(col, row)`
/// relative to `(origin_x, origin_y)`.
pub fn cellPosAt(
    xpos: f32,
    ypos: f32,
    origin_x: f32,
    origin_y: f32,
    cell_w: u16,
    cell_h: u16,
    max_cols: u16,
    max_rows: u16,
) struct { u16, u16 } {
    const local_x = @max(0.0, xpos - origin_x);
    const local_y = @max(0.0, ypos - origin_y);
    const col: u16 = @intCast(@min(@as(u32, @intFromFloat(local_x)) / cell_w, max_cols - 1));
    const row: u16 = @intCast(@min(@as(u32, @intFromFloat(local_y)) / cell_h, max_rows - 1));
    return .{ col, row };
}

pub fn handleResize(self: *App, dimension: Dimension(u16)) void {
    const frame_buffer_width = dimension.width;
    const frame_buffer_height = dimension.height;

    if (std.meta.eql(self.frame_buffer_size, dimension)) return;

    self.frame_buffer_size = dimension;

    const cell_width = self.rasterizer.cell_width;
    const cell_height = self.rasterizer.cell_height;
    if (cell_width == 0 or cell_height == 0) return;

    const pad_x = scaledPaddingPx(self.config.window.padding_x, self.content_scale);
    const pad_y = scaledPaddingPx(self.config.window.padding_y, self.content_scale);
    const layout = gridLayout(
        frame_buffer_width,
        frame_buffer_height,
        cell_width,
        cell_height,
        pad_x,
        pad_y,
        terminal_option.max_cols,
        terminal_option.max_rows,
    );
    const new_cols = layout.cols;
    const new_rows = layout.rows;
    if (new_rows == 0 or new_cols == 0) return;

    self.grid_origin = .{ @floatFromInt(layout.origin_x), @floatFromInt(layout.origin_y) };
    self.renderer.setGridOrigin(self.grid_origin[0], self.grid_origin[1]);

    self.driver.sendInput(.{
        .resize = .{
            .rows = new_rows,
            .cols = new_cols,
            .pixel_width = frame_buffer_width -| layout.origin_x *| 2,
            .pixel_height = frame_buffer_height -| layout.origin_y *| 2,
        },
    }) catch |err| {
        log.err("handleResize: driver sendInput failed: {}", .{err});
    };

    log.debug("fb={}x{} pad={}x{} cell={}x{} grid={}cols {}rows (unused: {}px right, {}px bottom)", .{
        frame_buffer_width,                                                     frame_buffer_height,
        layout.origin_x,                                                        layout.origin_y,
        cell_width,                                                             cell_height,
        new_cols,                                                               new_rows,
        (frame_buffer_width -| layout.origin_x *| 2) -| new_cols *| cell_width, (frame_buffer_height -| layout.origin_y *| 2) -| new_rows *| cell_height,
    });

    gl.viewport(0, 0, @intCast(frame_buffer_width), @intCast(frame_buffer_height));

    self.selection = .empty; // clear selection on resize
    self.needs_redraw = true;
}

fn pasteFromClipboard(self: *App) void {
    const text: []const u8 = self.window.getClipboard() orelse return;

    self.selection = .empty;
    self.driver.writePaste(text) catch |err| {
        log.err("pasteFromClipboard: writePaste failed: {}", .{err});
    };
    self.snapToLiveView();
}

/// Synchronizes wellbeing alerts and lock screen state with the UI kit overlay.
fn syncWellbeingKit(self: *App, new_alert_fired: bool) void {
    const kit = self.kit orelse return;
    const wb = &self.wellbeing_state;

    // If the toast tracking the active wellbeing alert was dismissed or expired,
    // clear the underlying alert (unless a fresh alert replaced it this tick).
    if (self.wellbeing_toast_serial) |serial| {
        if (!kit.hasToast(serial)) {
            self.wellbeing_toast_serial = null;
            if (!new_alert_fired and
                wb.current_alert.kind != .none and
                !(wb.input_locked and wb.option.lock_screen.enabled))
            {
                wb.dismissAlert();
            }
        }
    }

    const has_active_alert = wb.current_alert.kind != .none and wb.current_alert.remaining_s > 0;
    self.ascii_state.syncFocusPhase(
        wb.focus_state.phase,
        wb.option.enabled and wb.focus_state.option.on_break.contains(.animation),
        self.window_focused,
    );
    if (!has_active_alert or wb.input_locked) {
        self.ascii_state.reminder_active = false;
        self.ascii_state.alert_total_s = 0;
    } else if (new_alert_fired) {
        self.ascii_state.reminder_active = self.window_focused;
        self.ascii_state.alert_total_s = 0;
    }

    const overlay_mode = self.wellbeingOverlayMode();
    if (overlay_mode.showsLockSurface()) {
        if (self.wellbeing_toast_serial) |serial| {
            if (kit.dismissToast(serial)) self.needs_redraw = true;
            self.wellbeing_toast_serial = null;
        }
        const hud_layout: kit_lock_screen.Layout = if (overlay_mode.showsAscii()) .hud else .card;
        if (overlay_mode == .ascii_reminder) {
            if (self.ascii_state.break_overlay == .active) {
                const is_long = wb.focus_state.phase == .long_break;
                const title: []const u8 = if (is_long) "Long Rest Break" else "Short Rest Break";
                const tone: kit_lock_screen.Tone = if (wb.isFocusPausedByAlert() or wb.focus_state.paused) .warning else .healthy;
                const prompt_text = if (wb.current_alert.remaining_s > 0 and wb.current_alert.prompt.len > 0)
                    wb.current_alert.prompt
                else
                    "Step away from the screen and recharge.";
                const rem_s: u32 = @intCast((wb.focus_state.remaining_ms + 999) / 1000);
                const break_ms = if (is_long) wb.focus_state.option.long_break_ms else wb.focus_state.option.short_break_ms;
                const total_s: u32 = @intCast(@max(@as(u64, 1), break_ms / 1000));
                const steps_total = wb.focus_state.option.tasks_before_long_break;
                const steps_done = if (is_long) steps_total else wb.focus_state.tasks_in_cycle;
                if (kit.syncLockScreen(.{
                    .tone = tone,
                    .layout = hud_layout,
                    .action = .dismiss,
                    .title = title,
                    .subtitle = "",
                    .prompt = prompt_text,
                    .remaining_s = rem_s,
                    .total_s = @max(total_s, rem_s),
                    .steps_total = steps_total,
                    .steps_done = steps_done,
                    .scrim_alpha = 0,
                })) self.needs_redraw = true;
                return;
            }
            self.ascii_state.reminder_active = true;
            const title: []const u8, const tone: kit_lock_screen.Tone, const default_total_s: u32 = switch (wb.current_alert.kind) {
                .eyesight => .{ "Rest your eyes", .healthy, @intCast(@max(@as(u64, 1), wb.option.eyesight.duration_ms / 1000)) },
                .movement => .{ "Stretch and move", .healthy, @intCast(@max(@as(u64, 1), wb.option.movement.duration_ms / 1000)) },
                .healthy_break => .{ "Time for a healthy break", .healthy, 30 },
                .screen_limit => .{ "Screen limit reached", .critical, 20 },
                .none => return,
            };
            const rem_s = wb.current_alert.remaining_s;
            if (self.ascii_state.alert_total_s == 0 or rem_s > self.ascii_state.alert_total_s) {
                self.ascii_state.alert_total_s = @max(default_total_s, rem_s);
            }
            if (kit.syncLockScreen(.{
                .tone = tone,
                .layout = hud_layout,
                .action = .dismiss,
                .title = title,
                .subtitle = "",
                .prompt = wb.current_alert.prompt,
                .remaining_s = rem_s,
                .total_s = self.ascii_state.alert_total_s,
                .steps_total = 0,
                .steps_done = 0,
                .scrim_alpha = 0,
            })) self.needs_redraw = true;
            return;
        }
        self.ascii_state.reminder_active = false;
        self.ascii_state.alert_total_s = 0;

        const in_break = wb.focus_state.phase == .short_break or wb.focus_state.phase == .long_break;
        const is_paused = wb.isFocusPausedByAlert() or !in_break or wb.focus_state.paused;
        const tone: kit_lock_screen.Tone = if (is_paused) .warning else .healthy;
        const header_text: []const u8 = if (!in_break)
            "HEALTH REMINDER"
        else if (is_paused)
            "BREAK PAUSED"
        else
            "BREAK IN PROGRESS";
        const subtitle_text: []const u8 = if (wb.focus_state.phase == .task)
            "Focus paused for a health reminder."
        else if (!in_break)
            "Take a brief pause before continuing."
        else if (is_paused)
            "A health alert temporarily interrupted your break."
        else switch (wb.focus_state.phase) {
            .short_break => "Short Rest Break",
            .long_break => "Long Rest Break",
            else => "Rest & Recharge",
        };
        const prompt_text = if (wb.current_alert.remaining_s > 0 and wb.current_alert.prompt.len > 0)
            wb.current_alert.prompt
        else
            "Roll your shoulders backward and release tension in your neck.";
        const rem_s: u32 = if (wb.focus_state.phase == .short_break or wb.focus_state.phase == .long_break)
            @intCast((wb.focus_state.remaining_ms + 999) / 1000)
        else
            wb.current_alert.remaining_s;
        const total_s: u32 = if (wb.focus_state.phase == .short_break)
            @intCast(wb.focus_state.option.short_break_ms / 1000)
        else if (wb.focus_state.phase == .long_break)
            @intCast(wb.focus_state.option.long_break_ms / 1000)
        else
            30;
        const dim_byte: u8 = @intFromFloat(std.math.clamp(wb.option.lock_screen.dim_strength, 0.0, 1.0) * 255.0);
        if (kit.syncLockScreen(.{
            .tone = tone,
            .layout = hud_layout,
            .action = .unlock,
            .title = header_text,
            .subtitle = subtitle_text,
            .prompt = prompt_text,
            .remaining_s = rem_s,
            .total_s = total_s,
            .steps_total = wb.focus_state.option.tasks_before_long_break,
            .steps_done = wb.focus_state.tasks_in_cycle,
            .scrim_alpha = dim_byte,
        })) self.needs_redraw = true;
        return;
    }

    if (kit.lockScreenShown()) {
        if (kit.closeLockScreen()) self.needs_redraw = true;
    }

    if (!wb.option.enabled) {
        if (kit.hideWellbeingWidget()) self.needs_redraw = true;
    } else if (kit.wellbeingWidgetShown()) {
        if (kit.syncWellbeingWidget(wellbeingWidgetSnapshot(wb))) self.needs_redraw = true;
    }

    if (wb.current_alert.kind == .none) {
        if (self.wellbeing_toast_serial) |serial| {
            if (kit.dismissToast(serial)) self.needs_redraw = true;
            self.wellbeing_toast_serial = null;
        }
        return;
    }

    if (new_alert_fired or self.wellbeing_toast_serial == null) {
        if (self.wellbeing_toast_serial) |serial| {
            _ = kit.dismissToast(serial);
            self.wellbeing_toast_serial = null;
        }
        if (!self.window_focused or !self.config.window.toast.enabled) return;
        const title: []const u8, const kind: kit_toast.Kind = switch (wb.current_alert.kind) {
            .eyesight => .{ "Rest your eyes", .success },
            .movement => .{ "Stretch and move", .success },
            .healthy_break => .{ "Time for a healthy break", .success },
            .screen_limit => .{ "Screen limit reached", .err },
            .none => return,
        };
        const duration_ms: u32 = if (wb.current_alert.remaining_s > 0)
            wb.current_alert.remaining_s *| 1000
        else
            self.config.window.toast.duration_ms;
        const tracked = kit.pushTracked(.{
            .title = title,
            .description = wb.current_alert.prompt,
            .kind = kind,
            .duration_ms = @max(duration_ms, 1000),
        });
        self.wellbeing_toast_serial = tracked.serial;
        if (tracked.changed) self.needs_redraw = true;
    }
}

fn wellbeingWidgetSnapshot(wb: *const wellbeing.Wellbeing) kit_widget.Snapshot {
    const timer = wb.timer();
    const view_now = wb.focus_state;
    const option = wb.option.focus;
    const phase: wellbeing.focus.Phase = switch (timer.run) {
        .waiting => switch (timer.phase) {
            .idle => .idle,
            .task => if (timer.tasks_in_cycle + 1 >= option.tasks_before_long_break) .long_break else .short_break,
            .short_break, .long_break => .task,
        },
        .running, .paused => timer.phase,
    };
    const duration_ms = view_now.getDuration(if (phase == .idle) .task else phase);
    const started = timer.phase != .idle and timer.run != .waiting;
    const left_ms = if (started) @min(view_now.remaining_ms, duration_ms) else duration_ms;
    const fraction: f32 = if (started and duration_ms > 0)
        1.0 - @as(f32, @floatFromInt(left_ms)) / @as(f32, @floatFromInt(duration_ms))
    else
        0.0;
    const seconds: u64 = switch (option.timer) {
        .countdown => left_ms / std.time.ms_per_s + @intFromBool(left_ms % std.time.ms_per_s != 0),
        .countup => (duration_ms - left_ms) / std.time.ms_per_s,
    };
    return .{
        .phase = switch (phase) {
            .idle => .idle,
            .task => .task,
            .short_break => .short_break,
            .long_break => .long_break,
        },
        .run = switch (timer.run) {
            .paused => .paused,
            .running => .running,
            .waiting => .waiting,
        },
        .fraction = fraction,
        .seconds = seconds,
        .tasks_in_cycle = timer.tasks_in_cycle,
        .tasks_before_long_break = option.tasks_before_long_break,
    };
}

/// Linux only: wakes the loop when another process saves the wellbeing
/// state, so a press in the wellbeing window shows here at once rather
/// than at the next once-a-second poll. Null elsewhere, while wellbeing is
/// disabled, or when the watch cannot start; the poll runs either way.
fn startWellbeingWatch(gpa: std.mem.Allocator, state: *const wellbeing.Wellbeing, default_state_dir: []const u8) ?*FileWatch {
    if (comptime builtin.os.tag != .linux) return null;
    if (!state.option.enabled) return null;
    const dir = state.stateDir(default_state_dir);
    return FileWatch.create(gpa, dir, state.option.privacy.state_filename, Platform.postWakeup) catch |err| {
        log.warn("not watching {s} for wellbeing changes ({t}); checking once a second", .{ dir, err });
        return null;
    };
}

/// Polls the shared wellbeing state (at most once a second, see
/// `Wellbeing.sync`), or reads it at once after the watch saw a save. A
/// failure is reported when it starts or changes, not on every retry, and
/// the return to working is reported too.
fn syncWellbeing(self: *App, utc_s: i64) void {
    const saved_elsewhere = if (self.wellbeing_watch) |watch| watch.takeChanged() else false;
    const mode: wellbeing.Wellbeing.SyncMode = if (saved_elsewhere) .changed else .poll;
    if (self.wellbeing_state.sync(self.io, self.dirs.state, utc_s, mode)) |_| {
        if (self.wellbeing_sync_error != null) {
            log.info("wellbeing state in {s} is saved again", .{self.wellbeing_state.stateDir(self.dirs.state)});
            self.notifySimple("Wellbeing data", "Saved again", .success);
        }
        self.wellbeing_sync_error = null;
    } else |err| {
        const changed = if (self.wellbeing_sync_error) |previous| previous != err else true;
        if (changed) self.reportWellbeingError("save", err);
        self.wellbeing_sync_error = err;
    }
}

/// Clears the wellbeing data and deletes its state file. Returns false and
/// reports the error when the file could not be deleted.
fn purgeWellbeingHistory(self: *App) bool {
    self.wellbeing_state.purgeHistory(self.io, self.dirs.state, self.wallSeconds()) catch |err| {
        self.reportWellbeingError("delete", err);
        return false;
    };
    return true;
}

/// Wall-clock seconds since the epoch, for the wellbeing state file.
fn wallSeconds(self: *const App) i64 {
    return @intCast(std.Io.Clock.Timestamp.now(self.io, .real).raw.toSeconds());
}

/// Wall-clock milliseconds since the epoch, for the shared focus timer.
fn wallMs(self: *const App) i64 {
    return @intCast(std.Io.Clock.Timestamp.now(self.io, .real).raw.toMilliseconds());
}

/// Logs a failed write of the wellbeing state file and shows it as a toast,
/// so the user learns that their data was not written. The error name
/// comes first because the toast truncates long descriptions.
fn reportWellbeingError(
    self: *App,
    action: []const u8,
    err: wellbeing.Wellbeing.SyncError,
) void {
    const dir = self.wellbeing_state.stateDir(self.dirs.state);
    log.err("cannot {s} wellbeing state in {s}: {t}", .{ action, dir, err });
    var title_buf: [64]u8 = undefined;
    const title = std.fmt.bufPrint(&title_buf, "Couldn't {s} wellbeing data", .{action}) catch "Wellbeing data error";
    var desc_buf: [256]u8 = undefined;
    const desc = std.fmt.bufPrint(&desc_buf, "{t} in {s}", .{ err, dir }) catch @errorName(err);
    self.notifySimple(title, desc, .err);
}

fn pushFocusedToast(
    kit: *KitOverlay,
    focused: bool,
    toast_cfg: @import("config/overlay.zig").Toast,
    title: []const u8,
    description: []const u8,
    kind: kit_toast.Kind,
) bool {
    if (!focused or !toast_cfg.enabled) return false;
    return kit.push(.{
        .title = title,
        .description = description,
        .kind = kind,
        .duration_ms = toast_cfg.duration_ms,
    });
}

fn pushOrDeferBanner(
    kit: ?*KitOverlay,
    focused: bool,
    banner_enabled: bool,
    pending_banner: *?PendingAlert,
    kind: kit_alert.Kind,
    title: []const u8,
    description: []const u8,
) bool {
    if (!banner_enabled) {
        pending_banner.* = null;
        return false;
    }
    if (!focused) {
        pending_banner.* = PendingAlert.init(kind, title, description);
        return false;
    }
    pending_banner.* = null;
    const k = kit orelse return false;
    return k.showAlert(.{ .kind = kind, .title = title, .description = description });
}

fn flushDeferredBanner(
    kit: ?*KitOverlay,
    focused: bool,
    banner_enabled: bool,
    pending_banner: *?PendingAlert,
) bool {
    if (!focused or !banner_enabled) return false;
    const b = pending_banner.* orelse return false;
    pending_banner.* = null;
    const k = kit orelse return false;
    return k.showAlert(b.request());
}

/// Pushes a concise toast notification into the UI kit stack when focused.
pub fn notifySimple(self: *App, title: []const u8, description: []const u8, kind: kit_toast.Kind) void {
    const kit = self.kit orelse return;
    if (pushFocusedToast(kit, self.window_focused, self.config.window.toast, title, description, kind)) {
        self.needs_redraw = true;
    }
}

fn showAlert(self: *App, kind: kit_alert.Kind, title: []const u8, description: []const u8) void {
    if (pushOrDeferBanner(
        self.kit,
        self.window_focused,
        self.config.window.banner.enabled,
        &self.pending_banner,
        kind,
        title,
        description,
    )) {
        self.needs_redraw = true;
    }
}

/// Surfaces a banner deferred while unfocused when this window gains focus.
pub fn applyPendingBanner(self: *App) void {
    if (flushDeferredBanner(self.kit, self.window_focused, self.config.window.banner.enabled, &self.pending_banner)) {
        self.needs_redraw = true;
    }
}

/// Sets the font size in logical pixels, clamped to the configured bounds,
/// and reports the result in a toast.
fn setFontSize(self: *App, new_size: u32) void {
    const clamped_size: u32 = @max(self.config.font.min_size, @min(new_size, self.config.font.max_size));
    if (clamped_size == self.font_size) return;
    if (!self.rebuildFont(clamped_size, self.content_scale)) return;

    var toast_buf: [64]u8 = undefined;
    const toast_msg = std.fmt.bufPrint(&toast_buf, "Font: {d} ({d} px at {d}%, cell {d}x{d})", .{
        clamped_size,
        Freetype.FontConfig.pixelSize(clamped_size, self.content_scale),
        @as(u32, @intFromFloat(@round(self.content_scale * 100))),
        self.rasterizer.cell_width,
        self.rasterizer.cell_height,
    }) catch "Font size updated";
    self.notifySimple(toast_msg, "", .info);
}

/// The one place that reacts to a new display scale. Today it rebuilds the
/// terminal font at the same logical size; UI layout hooks in here too.
fn applyContentScale(self: *App, scale: f32) void {
    if (scale == self.content_scale) return;
    log.info("display scale {d:.2} -> {d:.2}", .{ self.content_scale, scale });
    // On failure rebuildFont has logged why and the old font and scale stay.
    _ = self.rebuildFont(self.font_size, scale);
}

/// Recreates the rasterizer for `size` logical pixels at display `scale`,
/// clears the glyph atlas and recomputes the grid. Shared by font-size and
/// scale changes. Returns false, keeping the old font, if the new one
/// can't be created.
fn rebuildFont(self: *App, size: u32, scale: f32) bool {
    const font_config: Freetype.FontConfig = .{
        .faces = self.config.font.faces,
        .height = Freetype.FontConfig.pixelSize(size, scale),
    };
    // Initialize new rasterizer BEFORE deiniting old one (avoid dangling ptr on failure)
    const new_rasterizer = Rasterizer.init(self.allocator, font_config) catch |err| {
        log.err("rebuildFont: rasterizer.init failed: {}", .{err});
        return false;
    };
    self.rasterizer.deinit(self.allocator);
    self.rasterizer = new_rasterizer;
    self.renderer.setFontMetrics(self.rasterizer.metrics);

    // Invalidate atlas, all cached glyphs are wrong size now
    self.atlas.invalidate();
    if (self.kit) |kit| kit.glyphsLost(scale);

    // Invalidate frame builder cached generation
    self.frame_builder.last_generation = null;

    self.font_size = size;
    self.content_scale = scale;
    self.needs_redraw = true;

    // Reset cached fb size to force handleResize to recompute rows/cols
    self.frame_buffer_size = .empty;

    const fb = self.window.framebufferSize(u16);
    self.handleResize(fb);
    return true;
}

pub fn reloadConfig(self: *App) void {
    // Built from the defaults, not on top of the current config, so a
    // setting removed from a file falls back to its default. The current
    // config stays valid until the swap below.
    var loaded = Loaded.load(self.allocator, self.io, self.base_config, self.home_dir, &.{
        .file(rex.config.paths.system),
        .file(self.config_path),
    }) catch |err| {
        var err_buf: [128]u8 = undefined;
        const err_msg = std.fmt.bufPrint(&err_buf, "Failed to apply: {}", .{err}) catch "Apply failed";
        self.showAlert(.err, "Config error", err_msg);
        return;
    };

    defer loaded.deinit(self.allocator);
    logConfigDiagnostics(self.allocator, &loaded);

    if (!loaded.found()) {
        self.notifySimple("Configuration", "No config file found", .default);
        return;
    }

    // A running session keeps its config when a file has errors (decision
    // P4); a config with only warnings applies, and the banner shows the
    // first warning after `self.config` is swapped so changes to `[banner]`
    // take effect immediately.
    if (loaded.firstError() != null) {
        if (configBanner(&loaded)) |*banner| {
            const req = banner.request();
            self.showAlert(req.kind, req.title, req.description);
        }
        return;
    }
    useBuiltinFonts(self.io, loaded.arena.allocator(), &loaded, self.argv0) catch |err| switch (err) {
        error.OutOfMemory => {
            self.showAlert(.err, "Config error", "Out of memory");
            return;
        },
        error.BadExePath => {
            self.showAlert(.err, "Config error", "font.file is not set, and the executable path is not usable");
            return;
        },
        error.BuiltinFontMissing => {
            var buf: [128]u8 = undefined;
            const face = missingBuiltinFace(self.io, loaded.arena.allocator(), self.argv0);
            log.err("no font: set `file` in [font]; missing {s}", .{face});
            const name = std.fs.path.basename(face);
            const msg = std.fmt.bufPrint(&buf, "{s} is missing; set `file` in [font]", .{name}) catch "the built-in face is missing; set `file` in [font]";
            self.showAlert(.err, "Config error", msg);
            return;
        },
    };
    if (!hasFontFile(loaded.config.font)) {
        self.showAlert(.err, "Config error", "font.file is not set");
        return;
    }
    const new_config = loaded.config;
    const faces_changed = !self.config.font.faces.eql(new_config.font.faces);
    const decorations_changed = new_config.window.decorations != self.config.window.decorations;
    const padding_changed = new_config.window.padding_x != self.config.window.padding_x or
        new_config.window.padding_y != self.config.window.padding_y;

    if (new_config.window.platform != self.config.window.platform) {
        log.info("window.platform takes effect on the next start", .{});
    }

    // Freeing the old arena leaves the rasterizer with a dangling font path:
    // FreeType keeps the path pointer in its stream (src/base/ftsystem.c:252)
    // but never reads it after opening the file, so this is safe. A new
    // rasterizer (font size change below) gets the new path.
    const widget_default_visible_changed = self.config.window.wellbeing_widget.default_visible != new_config.window.wellbeing_widget.default_visible;
    self.config_arena.deinit();
    self.config_arena = loaded.takeArena();
    self.config = new_config;

    // Live update renderer background color, alpha, and terminal theme
    const resolved_theme = self.config.resolvedTheme();
    self.background_color = normalizedRgba(
        resolved_theme.background,
        self.config.window.effectiveBackgroundAlpha(self.window_focused),
    );
    self.renderer.setSelectionOption(rendererSelectionOption(self.config.selection));
    self.renderer.setScrollbarOption(rendererScrollbarOption(self.config.scrollbar));
    self.renderer.setCursorOption(rendererCursorOption(self.config.cursor));
    self.blink.setPeriod(self.config.cursor.blink_interval_ms);
    self.blink_rapid.setPeriod(self.config.cursor.rapid_blink_interval_ms);
    self.updateScrollbarHover();
    if (self.kit) |kit| {
        kit.configure(kitOverlayOptions(self.config.ui, self.config.window));
        if (!self.config.window.banner.enabled) {
            self.pending_banner = null;
            if (kit.dismissAlert()) self.needs_redraw = true;
        } else if (configBanner(&loaded)) |*banner| {
            const req = banner.request();
            self.showAlert(req.kind, req.title, req.description);
        } else {
            self.pending_banner = null;
            if (kit.dismissAlert()) self.needs_redraw = true;
        }
    } else if (!self.config.window.banner.enabled or configBanner(&loaded) == null) {
        self.pending_banner = null;
    }
    if (self.config.clipboard.osc52_write != .ask) self.clipboard_session.allow_write = false;
    if (self.config.clipboard.osc52_read != .ask) self.clipboard_session.allow_read = false;
    self.reconcilePendingClipboard();
    self.syncWindowEffects();
    self.renderer.setModalBlur(self.config.window.modal.blur, self.config.window.modal.blur_radius);
    self.tickPointerIdle(0);
    self.driver.setTheme(resolved_theme);
    self.updateWindowTitle();
    if (decorations_changed) {
        self.window.setDecorated(self.config.window.decorations == .full);
    }
    self.frame_builder.last_generation = null;
    self.renderer_dirty = true;

    self.frame_builder.dim_alpha = renderer_mod.Frame.alphaByte(self.config.window.dim_alpha);
    const decoration_option = decoration_config.build(&self.config);
    self.frame_builder.decoration = decoration_option;
    self.renderer.setDecoration(decoration_option, self.rasterizer.metrics);

    // A size change rebuilds the rasterizer with the new faces; a face
    // change at the same size needs its own rebuild.
    const size_before = self.font_size;
    if (self.config.font.size != self.font_size) {
        self.setFontSize(self.config.font.size);
    }
    if (faces_changed and self.font_size == size_before and !self.rebuildFont(self.font_size, self.content_scale)) {
        self.showAlert(.err, "Config error", "the new font could not be loaded; the previous one stays");
    }
    if (padding_changed) {
        self.frame_buffer_size = .empty;
        self.handleResize(self.window.framebufferSize(u16));
    }

    self.wellbeing_state.applyOption(self.config.wellbeing);
    if (self.ascii_frames) |*frames| frames.deinit(self.allocator);
    self.ascii_frames = loadAsciiFrames(self.allocator, self.io, self.config.window.wellbeing_ascii.file);
    if (self.kit) |kit| {
        if (widget_default_visible_changed) {
            if (self.config.window.wellbeing_widget.default_visible and self.wellbeing_state.option.enabled) {
                if (!kit.wellbeingWidgetShown()) _ = kit.toggleWellbeingWidget();
            } else {
                _ = kit.hideWellbeingWidget();
            }
        }
        self.syncWellbeingKit(false);
    }
    // The state directory, file name or `enabled` may have changed.
    if (self.wellbeing_watch) |watch| watch.destroy(self.allocator);
    self.wellbeing_watch = startWellbeingWatch(self.allocator, &self.wellbeing_state, self.dirs.state);
    // The keys accept only ASCII, so this fails only on a broken invariant;
    // keep the previous classifier then rather than lose word selection.
    if (unicode.Classifier.init(self.config.selection.classifier)) |classifier| {
        self.word_classifier = classifier;
    } else |err| {
        log.err("word characters not applied: {}", .{err});
    }

    self.needs_redraw = true;
    self.notifySimple("Configuration", "Configuration reloaded", .info);
}

fn handleAction(self: *App, action: rex.input.Action) void {
    switch (action) {
        .paste_clipboard => self.pasteFromClipboard(),
        .copy_selection => {
            if (self.selection.phase != .none) {
                self.copySelectionToClipboard();
                self.selection = .empty;
                self.needs_redraw = true;
            }
        },
        .scroll_up => {
            self.sendViewportInput(.{
                .viewport_scroll = .{ .lines = -@as(i32, @intCast(self.config.scroll.lines)) },
            });
            self.needs_redraw = true;
        },
        .scroll_down => {
            self.sendViewportInput(.{
                .viewport_scroll = .{ .lines = @as(i32, @intCast(self.config.scroll.lines)) },
            });
            self.needs_redraw = true;
        },
        .increase_font_size => {
            const target = (self.font_size_pending orelse self.font_size) +| self.config.font.size_step;
            self.font_size_pending = @min(target, self.config.font.max_size);
        },
        .decrease_font_size => {
            const target = (self.font_size_pending orelse self.font_size) -| self.config.font.size_step;
            self.font_size_pending = @max(target, self.config.font.min_size);
        },
        .reset_font_size => {
            self.font_size_pending = self.config.font.size;
        },
        .new_window => self.openNewWindow(),
        .quit => self.requestQuit(),
        .focus_toggle => {
            self.wellbeing_state.toggleFocus(self.wallMs());
            self.ringBell();
            self.syncWellbeingKit(false);
        },
        .focus_reset => {
            self.wellbeing_state.resetFocus(self.wallMs());
            self.syncWellbeingKit(false);
        },
        .focus_skip => {
            self.wellbeing_state.skipFocus(self.wallMs());
            self.ringBell();
            self.syncWellbeingKit(false);
        },
        .focus_toggle_phase_end => {
            self.wellbeing_state.toggleFocusPhaseEnd();
        },
        .wellbeing_dashboard => if (self.wellbeing_state.option.enabled) {
            self.openToolWindow("wellbeing", "wellbeing dashboard");
        },
        .wellbeing_widget => if (self.wellbeing_state.option.enabled) {
            if (self.kit) |kit| {
                if (kit.toggleWellbeingWidget()) self.needs_redraw = true;
                self.syncWellbeingKit(false);
            }
        },
        .wellbeing_clear => {
            if (self.purgeWellbeingHistory()) {
                self.wellbeing_state.current_alert = .{
                    .kind = .healthy_break,
                    .prompt = "Wellbeing history cleared.",
                    .remaining_s = 10,
                };
                self.syncWellbeingKit(true);
            }
        },
        .wellbeing_dismiss => {
            self.wellbeing_state.dismissAlert();
            self.wellbeing_toast_serial = null;
            if (self.kit) |kit| {
                _ = kit.dismissAll();
                _ = kit.dismissAlert();
                _ = kit.dialogInput(.dismiss);
            }
            self.needs_redraw = true;
            self.syncWellbeingKit(false);
        },
        .toast_dismiss => {
            if (self.kit != null and self.kit.?.dismissOldest()) {
                self.needs_redraw = true;
                self.syncWellbeingKit(false);
            } else if (self.wellbeing_state.current_alert.kind != .none) {
                self.wellbeing_state.dismissAlert();
                self.needs_redraw = true;
                self.syncWellbeingKit(false);
            } else if (self.kit != null and self.kit.?.dismissAlert()) {
                self.needs_redraw = true;
            }
        },
        .toast_activate => {
            const dismissed = self.kit != null and self.kit.?.dismissOldest();
            if (self.wellbeing_state.current_alert.kind != .none) {
                self.wellbeing_state.skipFocus(self.wallMs());
                self.ringBell();
                self.needs_redraw = true;
                self.syncWellbeingKit(false);
            } else if (dismissed) {
                self.needs_redraw = true;
            }
        },
        .reload_config => self.reloadConfig(),
        .open_settings => self.openToolWindow("settings", "settings window"),
        .send_to_pty => |seq| {
            self.driver.sendBytes(seq) catch |err| {
                log.err("handleAction: send to pty write failed: {}", .{err});
            };
        },
    }
}

fn resolveExe(self: *const App, buf: *[std.fs.max_path_bytes]u8, label: []const u8) []const u8 {
    // Linux reads /proc/self/exe here, which works whatever PATH and
    // the working directory have become since rex started.
    const len = std.process.executablePath(self.io, buf) catch |err| {
        log.warn("{s}: executable path unavailable ({}), using argv[0]", .{ label, err });
        return self.argv0;
    };
    return buf[0..len];
}

/// Starts a tool window (`rex <subcommand>`) as a separate process. A second
/// start hits the tool's lock and exits; `reapDetached` collects it.
fn openToolWindow(self: *App, subcommand: []const u8, label: []const u8) void {
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe = self.resolveExe(&exe_buf, label);
    const child = spawnDetached(self.io, &.{ exe, subcommand }, .inherit) catch |err| {
        log.err("{s}: cannot start {s}: {}", .{ label, exe, err });
        return;
    };
    reapDetached(child, label);
}

/// Starts another rex as a separate process in the shell's working
/// directory. The new window does not depend on this one: it has its
/// own process group and null stdio, and outlives this process. A
/// failure is logged and this window carries on.
fn openNewWindow(self: *App) void {
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe = self.resolveExe(&exe_buf, "new window");

    // chdir follows the /proc/<pid>/cwd link to wherever the shell is.
    var cwd_buf: [32]u8 = undefined;
    const pid = self.driver.getPid();
    const shell_cwd: ?[]const u8 = if (pid > 0)
        std.fmt.bufPrint(&cwd_buf, "/proc/{d}/cwd", .{pid}) catch null
    else
        null;

    const child = spawnDetached(self.io, &.{exe}, if (shell_cwd) |path| .{ .path = path } else .inherit) catch |err| retry: {
        if (shell_cwd == null) break :retry err;
        log.warn("new window: cannot start in the shell's directory ({}), retrying here", .{err});
        break :retry spawnDetached(self.io, &.{exe}, .inherit);
    } catch |err| {
        log.err("new window: cannot start {s}: {}", .{ exe, err });
        return;
    };

    reapDetached(child, "new window");
}

fn reapDetached(child: std.process.Child, label: []const u8) void {
    const child_pid = child.id orelse return;
    reapInBackground(child_pid) catch |err| {
        log.warn("{s}: no reaper thread ({}); pid {d} stays a zombie until rex exits", .{ label, err, child_pid });
    };
}

/// Waits for child `pid` on a detached thread, so it leaves no zombie.
/// If this process exits first, init adopts and reaps the child instead.
///
/// The thread keeps the default stack size. glibc puts static TLS on
/// each thread's stack, and rex's TLS (about 256 KiB, mostly std's
/// signal stack) does not fit a small stack: pthread_create then fails
/// with EINVAL, which std.Thread.spawn treats as unreachable and panics.
fn reapInBackground(pid: posix.pid_t) std.Thread.SpawnError!void {
    const reaper = try std.Thread.spawn(.{}, reapChild, .{pid});
    reaper.detach();
}

fn spawnDetached(io: std.Io, argv: []const []const u8, cwd: std.process.Child.Cwd) std.process.SpawnError!std.process.Child {
    return std.process.spawn(io, .{
        .argv = argv,
        .cwd = cwd,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        // Its own process group, so a hangup or Ctrl+C aimed at this
        // rex's group does not reach the child.
        .pgid = 0,
    });
}

fn reapChild(pid: posix.pid_t) void {
    var status: c_int = undefined;
    while (true) {
        const rc = system.waitpid(pid, &status, 0);
        if (rc == pid or posix.errno(rc) != .INTR) return;
    }
}

/// Returns the terminal view to the live position after input is written to
/// the PTY.
///
/// When the active buffer is the primary screen buffer and its viewport is
/// scrolled back, the viewport is reset to the live position and the current
/// selection is cleared. A redraw is always requested because PTY input may
/// produce terminal output that changes the displayed state.
fn snapToLiveView(self: *App) void {
    const frame = self.driver.getFrame();
    if (!frame.is_alternate and frame.viewport_offset > 0) {
        self.selection = .empty;
        self.sendViewportInput(.{ .set_viewport_offset = 0 });
    }

    self.needs_redraw = true;
}

/// Starts `shell` in a new pty and waits until its program replaced the
/// child, so a failed `chdir` or `execve` is `error.SpawnFailed` here, with
/// the failed step in `failure`. The argv array is freed on return: the
/// child got its own copy at fork.
fn spawnShell(
    gpa: std.mem.Allocator,
    io: std.Io,
    shell: Config.Shell,
    login_shell: [:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
    failure: *?rex.termio.pty.SpawnFailure,
) !Pty {
    const argv = try gpa.allocSentinel(?[*:0]const u8, 1 + shell.arguments.len, null);
    defer gpa.free(argv);
    argv[0] = shell.program orelse login_shell;
    for (shell.arguments, argv[1..]) |argument, *slot| slot.* = argument;

    const termio: rex.termio.pty.SpawnOption = .default;
    var pty = try Pty.spawn(.{
        .argv = argv.ptr,
        .capture_stdout = termio.capture_stdout,
        .cols = termio.cols,
        .cwd = if (shell.working_directory) |dir| dir.ptr else null,
        .envp = envp,
        .o_flags = termio.o_flags,
        .rows = termio.rows,
    });
    errdefer pty.close(io);
    pty.waitForSpawn() catch |err| {
        failure.* = pty.failure;
        return err;
    };
    return pty;
}

fn isDefaultShell(shell: Config.Shell) bool {
    return shell.program == null and shell.arguments.len == 0 and shell.working_directory == null;
}

/// The shell to start when `[shell] program` isn't set: `$SHELL`, else the
/// user's login shell from the passwd database, else /bin/sh. A relative or
/// empty path doesn't count.
fn defaultShell(env_shell: ?[]const u8, passwd_shell: ?[]const u8) []const u8 {
    for ([_]?[]const u8{ env_shell, passwd_shell }) |candidate| {
        const path = candidate orelse continue;
        if (std.fs.path.isAbsolute(path)) return path;
    }
    return "/bin/sh";
}

/// The current user's login shell, or null. Points into libc's static
/// passwd entry: valid until the next getpw* call, so copy it before then.
fn passwdShell() ?[]const u8 {
    if (!is_posix) return null;
    const entry = std.c.getpwuid(std.c.getuid()) orelse return null;
    return std.mem.span(entry.shell orelse return null);
}

/// Whether the config names a font. The built-in defaults don't: Rex has no
/// bundled font yet (#20).
fn hasFontFile(font: Config.Font) bool {
    return font.faces.regular[0] != 0;
}

/// Points faces the config left unset at the faces installed next to
/// this executable. A key the config set, including `none`, stays.
fn useBuiltinFonts(io: std.Io, arena: std.mem.Allocator, loaded: *rex.config.Loaded, argv0: []const u8) !void {
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe: []const u8 = if (std.process.executablePath(io, &exe_buf)) |len|
        exe_buf[0..len]
    else |_|
        argv0;
    try rex.config.builtin_font.apply(io, arena, loaded, exe);
}

/// The UI kit for a window at display `scale`, with the UI font installed
/// next to this executable, or null with an error log when it cannot be set
/// up. Needs a current GL context.
fn createKit(gpa: std.mem.Allocator, io: std.Io, argv0: []const u8, scale: f32, terminal_face: [*:0]const u8) ?*KitOverlay {
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe: []const u8 = if (std.process.executablePath(io, &exe_buf)) |len|
        exe_buf[0..len]
    else |_|
        argv0;
    return createKitFrom(gpa, exe, scale, terminal_face) catch |err| {
        log.err("cannot initialize the UI kit ({t}); overlays are disabled", .{err});
        return null;
    };
}

fn createKitFrom(gpa: std.mem.Allocator, exe: []const u8, scale: f32, terminal_face: [*:0]const u8) !*KitOverlay {
    const names = rex.config.font_files;
    const dir = try names.fontDir(gpa, exe);
    defer gpa.free(dir);
    // FreeType opens the files in `create`; the paths are not kept.
    const regular = try std.fs.path.joinZ(gpa, &.{ dir, names.ui_regular_name });
    defer gpa.free(regular);
    const medium = try std.fs.path.joinZ(gpa, &.{ dir, names.ui_medium_name });
    defer gpa.free(medium);
    const semibold = try std.fs.path.joinZ(gpa, &.{ dir, names.ui_semibold_name });
    defer gpa.free(semibold);
    return try KitOverlay.create(gpa, .{
        .regular = regular,
        .medium = medium,
        .semibold = semibold,
        // The face the terminal started with; a later `[font] file`
        // change does not reach the kit.
        .fallback = if (terminal_face[0] != 0) terminal_face else null,
    }, scale);
}

/// The shipped regular face this process would load, or its file name when
/// the executable path cannot be resolved.
fn missingBuiltinFace(io: std.Io, allocator: std.mem.Allocator, argv0: []const u8) []const u8 {
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe: []const u8 = if (std.process.executablePath(io, &exe_buf)) |len|
        exe_buf[0..len]
    else |_|
        argv0;
    return rex.config.builtin_font.regularPath(allocator, exe) catch rex.config.font_files.regular_name;
}

/// Logs every config problem in full: the banner shows only the first one,
/// and cuts long messages.
fn logConfigDiagnostics(gpa: std.mem.Allocator, loaded: *const Loaded) void {
    const counts = loaded.counts();
    if (counts.errors == 0 and counts.warnings == 0) return;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    loaded.writeDiagnostics(&out.writer, .{}) catch {
        log.warn("config: {d} errors and {d} warnings, out of memory listing them", .{ counts.errors, counts.warnings });
        return;
    };
    const text = std.mem.trimEnd(u8, out.written(), "\n");
    if (counts.errors > 0) log.err("config problems:\n{s}", .{text}) else log.warn("config warnings:\n{s}", .{text});
}

const PendingAlert = struct {
    kind: kit_alert.Kind,
    title_buf: [kit_alert.title_capacity]u8 = undefined,
    title_len: u8 = 0,
    description_buf: [kit_alert.description_capacity]u8 = undefined,
    description_len: u16 = 0,

    fn init(kind: kit_alert.Kind, title: []const u8, description: []const u8) PendingAlert {
        var out: PendingAlert = .{ .kind = kind };
        const tlen = @min(title.len, out.title_buf.len);
        @memcpy(out.title_buf[0..tlen], title[0..tlen]);
        out.title_len = @intCast(tlen);
        const mlen = @min(description.len, out.description_buf.len);
        @memcpy(out.description_buf[0..mlen], description[0..mlen]);
        out.description_len = @intCast(mlen);
        return out;
    }

    fn request(self: *const PendingAlert) kit_alert.Request {
        return .{
            .kind = self.kind,
            .title = self.title_buf[0..self.title_len],
            .description = self.description_buf[0..self.description_len],
        };
    }
};

/// The alert for the first error of `loaded`, else its first warning.
fn configBanner(loaded: *const Loaded) ?PendingAlert {
    if (loaded.firstError()) |problem| switch (problem) {
        .unreadable => |u| {
            var buf: [128]u8 = undefined;
            const name = std.fs.path.basename(u.layer.source.label);
            const message = std.fmt.bufPrint(&buf, "cannot read {s}: {s}", .{ name, @errorName(u.err) }) catch "cannot read a config file";
            return PendingAlert.init(.err, "Config error", message);
        },
        .syntax => |e| return diagnosticBanner(&e.layer.state.loaded, .{ .syntax = e.err }),
    };
    if (loaded.firstWarning()) |w| return diagnosticBanner(&w.layer.state.loaded, .{ .sema = w.err });
    return null;
}

fn diagnosticBanner(file: *const diagnostics.File, d: diagnostics.Diagnostic) PendingAlert {
    const kind: kit_alert.Kind, const prefix: []const u8 = switch (d.severity()) {
        .err => .{ .err, "Config error" },
        .warn => .{ .warn, "Config warning" },
    };
    const loc = file.tree.tokenLocation(d.token());
    var title_buf: [64]u8 = undefined;
    const title = std.fmt.bufPrint(&title_buf, "{s} (line {d}, col {d})", .{ prefix, loc.line + 1, loc.column + 1 }) catch prefix;
    var message_buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&message_buf);
    diagnostics.renderMessage(file, d, &w) catch {};
    return PendingAlert.init(kind, title, w.buffered());
}

/// Requests closing the terminal window, opening the quit confirmation modal
/// when `on_close` asks for it.
pub fn requestQuit(self: *App) void {
    const ask = switch (self.config.window.on_close) {
        .ask => true,
        .ask_if_running => self.programRunning(),
        .close => false,
    };
    const kit = self.kit orelse {
        self.confirmQuit();
        return;
    };
    if (!ask or self.dialog_kind == .quit) {
        self.confirmQuit();
        return;
    }
    if (self.dialog_kind == .clipboard_ask) {
        // Window close takes precedence over an open clipboard prompt.
        _ = kit.dialogInput(.dismiss);
        self.dialog_kind = .none;
        denyPendingClipboard(&self.pending_clipboard, &self.driver);
    }
    self.window.setShouldClose(false);
    // The body names the program that closing would end, and says
    // nothing of one when `ask` asks at an idle shell.
    var name_buf: [32]u8 = undefined;
    const running = switch (self.config.window.on_close) {
        .close => false,
        // `ask` above was true, so `programRunning` already was.
        .ask_if_running => true,
        .ask => self.programRunning(),
    };
    const program = if (running) self.foregroundProgram(&name_buf) else null;
    var body_buf: [alert_dialog.body_capacity]u8 = undefined;
    if (kit.openDialog(.{
        .media = alertDialogMedia(self.config.window.alert_dialog.icon).codepoint(icons.none),
        .title = "Close this window?",
        .body = quitDialogBodyFor(running, program, &body_buf),
        .actions = &quit_actions,
        .focus = switch (self.config.window.alert_dialog.default_focus) {
            .confirm => quit_close,
            .cancel => quit_cancel,
        },
        // Leave null so live-reloaded `modal.backdrop_opacity` updates open dialogs.
        .scrim_alpha = null,
    })) {
        self.dialog_kind = .quit;
        self.showPointer();
        self.updatePointerShape(false);
    }
    self.needs_redraw = true;
}

/// The quit prompt's buttons in the kit's dialog, and their indexes.
const quit_actions = [_]alert_dialog.Action{
    .{ .label = "Cancel", .role = .dismiss, .key_cap = "Esc" },
    .{ .label = "Close window", .variant = .destructive },
};
const quit_cancel = 0;
const quit_close = 1;

/// The body of the quit dialog. `running` is whether a program other than
/// the shell is in the foreground, and `program` its name, when that could
/// be read. The result is a literal or lies in `buf`.
fn quitDialogBodyFor(running: bool, program: ?[]const u8, buf: []u8) []const u8 {
    if (!running) return "This will end the active shell session.";
    const name = program orelse return "A program is still running. Closing this window will end it.";
    return std.fmt.bufPrint(buf, "{s} is still running. Closing this window will end it.", .{name}) catch
        "A program is still running. Closing this window will end it.";
}

/// The name of the program in the terminal's foreground, in `buf`, or
/// null when that is the shell, cannot be read, or is not printable ASCII.
fn foregroundProgram(self: *const App, buf: []u8) ?[]const u8 {
    const group = rex.termio.pty.foregroundGroup(self.driver.getMasterFd()) orelse return null;
    if (group == self.driver.getPid()) return null;
    const name = rex.termio.pty.foregroundCommForGroup(group, buf) orelse return null;
    for (name) |byte| if (byte < 0x20 or byte > 0x7e) return null;
    return name;
}

/// Which surface currently owns `KitOverlay.dialog`.
const DialogKind = enum(u8) {
    none,
    quit,
    clipboard_ask,
};

/// Applies an outcome of the kit's dialog across quit and clipboard prompts.
fn applyDialogOutcome(self: *App, outcome: alert_dialog.Outcome) void {
    if (outcome == .quiet) return;
    self.needs_redraw = true;
    const prev_kind = self.dialog_kind;
    switch (outcome) {
        .quiet => unreachable,
        .redraw => if (self.dialogTakesInput()) return,
        .closed => {},
        .chosen => {},
    }
    self.dialog_kind = .none;
    switch (prev_kind) {
        .none => {},
        .quit => switch (outcome) {
            .chosen => |action| {
                if (action == quit_close) {
                    self.confirmQuit();
                    return;
                }
                self.maybeOpenClipboardDialog();
            },
            .redraw, .closed => self.maybeOpenClipboardDialog(),
            .quiet => unreachable,
        },
        .clipboard_ask => {
            switch (outcome) {
                .chosen => |action| {
                    if (action == clipboard_allow_always) {
                        self.clipboard_session.grant(self.pending_clipboard);
                    }
                    if (action == clipboard_allow_once or action == clipboard_allow_always) {
                        allowPendingClipboard(
                            self.allocator,
                            &self.pending_clipboard,
                            self.clipboard_buf,
                            &self.window,
                            &self.driver,
                        );
                    } else {
                        denyPendingClipboard(&self.pending_clipboard, &self.driver);
                    }
                },
                .redraw, .closed => denyPendingClipboard(&self.pending_clipboard, &self.driver),
                .quiet => unreachable,
            }
            self.handleClipboard();
        },
    }
}

fn dialogTakesInput(self: *const App) bool {
    const kit = self.kit orelse return false;
    return kit.dialogTakesInput();
}

/// Whether a program other than the shell is in the terminal's foreground.
/// When that can't be read, true: better to ask once too often.
fn programRunning(self: *const App) bool {
    const group = rex.termio.pty.foregroundGroup(self.driver.getMasterFd()) orelse return true;
    return group != self.driver.getPid();
}

/// Marks the quit prompt as confirmed and signals the window to close on the next event loop iteration.
pub fn confirmQuit(self: *App) void {
    self.quit_confirmed = true;
    self.window.setShouldClose(true);
}

fn hasModalOverlay(self: *const App) bool {
    if (self.wellbeing_state.input_locked) return true;
    if (self.kit) |kit| return kit.hasScrim();
    return false;
}

fn unlockLockScreen(self: *App) void {
    self.wellbeing_state.skipFocus(self.wallMs());
    self.ringBell();
    self.syncWellbeingKit(false);
    self.maybeOpenClipboardDialog();
    self.needs_redraw = true;
}

fn dismissWellbeingOverlay(self: *App) void {
    if (self.wellbeing_state.input_locked) {
        self.unlockLockScreen();
        return;
    }
    if (self.ascii_state.break_overlay == .active) {
        self.ascii_state.break_overlay = .dismissed;
    }
    self.ascii_state.reminder_active = false;
    self.ascii_state.alert_total_s = 0;
    self.wellbeing_state.dismissAlert();
    self.syncWellbeingKit(false);
    self.maybeOpenClipboardDialog();
    self.renderer_dirty = true;
    self.needs_redraw = true;
}

/// Routes physical key events to active UI modals, overlays, and application keybindings.
/// Returns true when the event was consumed by the UI layer, signaling the input callback
/// to bypass terminal key encoding and suppress trailing text input callbacks.
fn routeKeyToUi(self: *App, maybe_key: ?rex.input.Key, mods: rex.input.Modifiers) bool {
    const k = maybe_key orelse return false;

    if (self.dialogTakesInput()) {
        self.handleDialogKey(k, mods);
        return true;
    }

    if (self.wellbeing_state.input_locked) {
        self.handleLockScreenKey(k, mods);
        return true;
    }

    if (self.kit) |kit| {
        if (kit.lockScreenTakesInput()) {
            if (!k.isModifier()) self.dismissWellbeingOverlay();
            return true;
        }
    }

    if (rex.input.matchBinding(self.config.keymap, k, mods)) |act| {
        self.handleAction(act);
        return true;
    }

    return false;
}

fn handleLockScreenKey(self: *App, k: rex.input.Key, mods: rex.input.Modifiers) void {
    // Ctrl+Shift+D is the emergency unlock shortcut alongside unlock keybindings.
    const ctrl_shift_d = mods.ctrl and mods.shift and !mods.alt and !mods.super and k == .d;
    const is_unlock_binding = if (rex.input.matchBinding(self.config.keymap, k, mods)) |act| switch (act) {
        .focus_skip, .wellbeing_dismiss, .toast_dismiss, .toast_activate => true,
        else => false,
    } else false;
    if (ctrl_shift_d or is_unlock_binding) {
        self.unlockLockScreen();
        return;
    }

    const kit = self.kit orelse return;
    if (!kit.lockScreenTakesInput() or mods.ctrl or mods.alt or mods.super) return;
    const event: kit_lock_screen.Event = switch (k) {
        .tab => .focus,
        .enter, .kp_enter, .space => .activate,
        else => return,
    };
    switch (kit.lockScreenInput(event)) {
        .quiet => {},
        .redraw => self.needs_redraw = true,
        .unlocked => self.unlockLockScreen(),
    }
}

fn handleDialogKey(self: *App, k: rex.input.Key, mods: rex.input.Modifiers) void {
    const kit = self.kit orelse {
        if (self.dialog_kind == .quit) self.confirmQuit();
        return;
    };
    const event: ?alert_dialog.Event = switch (self.dialog_kind) {
        .none => null,
        .quit => switch (k) {
            .tab => .{ .focus = if (mods.shift) .previous else .next },
            .left, .up => .{ .focus = .previous },
            .right, .down => .{ .focus = .next },
            .enter, .kp_enter, .space => .activate,
            // Y, Q, N and Backspace are the quit prompt's own shortcuts.
            .y, .q => .{ .take = quit_close },
            .escape, .n, .backspace => .dismiss,
            else => null,
        },
        // Do not bind bare letter keys to allow in clipboard prompts: an async
        // OSC 52 can open while the user is typing.
        .clipboard_ask => switch (k) {
            .tab => .{ .focus = if (mods.shift) .previous else .next },
            .left, .up => .{ .focus = .previous },
            .right, .down => .{ .focus = .next },
            .enter, .kp_enter, .space => .activate,
            .escape => .dismiss,
            else => null,
        },
    };
    if (event) |ev| self.applyDialogOutcome(kit.dialogInput(ev));
}

fn onText(self: *App, codepoint: u21) void {
    if (self.skip_next_char) {
        self.skip_next_char = false;
        return;
    }
    if (self.dialogTakesInput() or self.wellbeing_state.input_locked) return;
    self.wellbeing_state.recordActivity();
    self.selection = .empty;
    self.needs_redraw = true;

    if (codepoint == 0) return;

    var buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(codepoint, &buf) catch return;
    if (len > 0) {
        self.hidePointerOnTyping();
        const seq = if (latency_trace.enabled) self.latencyBeginSend() else {};
        self.driver.sendBytes(buf[0..len]) catch |err| {
            log.err("charCallback: driver sendBytes failed: {}", .{err});
            return;
        };
        if (latency_trace.enabled) self.latencyQueued(seq);
        self.snapToLiveView();
    }
}

/// A modifier's own key event carries the state before that event, so Ctrl
/// press reports ctrl = false. Fold the transition in to keep `mods_down`
/// aligned with what is actually held.
fn modsAfterEvent(event: PlatformEvents.KeyEvent) rex.input.Modifiers {
    var mods = event.mods;
    if (!event.key.isModifier()) return mods;
    const down = event.action != .release;
    switch (event.key) {
        .left_shift, .right_shift => mods.shift = down,
        .left_control, .right_control => mods.ctrl = down,
        .left_alt, .right_alt => mods.alt = down,
        .left_super, .right_super => mods.super = down,
        else => {},
    }
    return mods;
}

fn onKey(self: *App, event: PlatformEvents.KeyEvent) void {
    // Every key event carries the modifiers held at that moment, including
    // modifier releases. Keep our own copy for the link tooltip and repaint
    // when it changes.
    const mods = modsAfterEvent(event);
    const mods_bits: u8 = @bitCast(mods);
    if (mods_bits != @as(u8, @bitCast(self.mods_down))) {
        self.mods_down = mods;
        self.needs_redraw = true;
    }
    if (event.action == .release) return;
    const pressed_at = if (latency_trace.enabled) latency_trace.now(self.io) else {};
    self.wellbeing_state.recordActivity();

    // The backend drops keys Rex has no name for, so this is always present.
    const maybe_key: ?input.Key = event.key;
    const key_mods = event.mods;

    if (self.routeKeyToUi(maybe_key, key_mods)) {
        self.skip_next_char = true;
        return;
    }
    self.skip_next_char = false;

    // A bare modifier keeps the selection, since it may start a
    // combination such as Ctrl+Shift+C.
    if (maybe_key == null or !maybe_key.?.isModifier()) {
        self.selection = .empty;
        self.needs_redraw = true;
        if (maybe_key != null) self.hidePointerOnTyping();
        // Its bytes may come from here or from the char callback.
        if (latency_trace.enabled) self.latency.?.keyPressed(pressed_at);
    }

    // Terminal key encoding
    const driver_modes = self.driver.getModes();
    const key_modes: input.encode.Modes = .{
        .modify_other_keys = driver_modes.modify_other_keys,
        .cursor_keys = driver_modes.cursor_keys,
        .keypad_app = driver_modes.keypad_app,
        .eight_bit_controls = driver_modes.eight_bit_controls,
    };

    var buf: [input.encode.max_len]u8 = undefined;
    // A key Rex has no name for sends nothing by itself.
    const bytes = if (maybe_key) |k| input.encode.encode(k, key_mods, key_modes, &buf) else "";
    if (bytes.len > 0) {
        // The key went out encoded, so its character must not follow
        // (Shift+letter under modifyOtherKeys 2). The next key event
        // clears the flag if no character comes.
        self.skip_next_char = true;
        const seq = if (latency_trace.enabled) self.latencyBeginSend() else {};
        self.driver.sendBytes(bytes) catch |err| {
            log.err("keyCallback: driver sendBytes failed: {}", .{err});
            return;
        };
        if (latency_trace.enabled) self.latencyQueued(seq);
        self.snapToLiveView();
    }
}

fn mouseCellPos(self: *App, xpos: f32, ypos: f32) struct { u16, u16 } {
    return cellPosAt(
        xpos,
        ypos,
        self.grid_origin[0],
        self.grid_origin[1],
        self.rasterizer.cell_width,
        self.rasterizer.cell_height,
        terminal_option.max_cols,
        terminal_option.max_rows,
    );
}

/// Per-window OSC 52 permissions granted via "Always Allow".
const ClipboardSession = packed struct(u8) {
    allow_write: bool = false,
    allow_read: bool = false,
    _pad: u6 = 0,

    fn grant(self: *ClipboardSession, pending: PendingClipboard) void {
        switch (pending) {
            .none => {},
            .write => self.allow_write = true,
            .read => self.allow_read = true,
        }
    }
};

/// An OSC 52 request awaiting user confirmation under `ask`.
/// For `.write`, the decoded payload sits in `App.clipboard_buf[0..len]`
/// until resolved, so `handleClipboard` leaves the next terminal request
/// untouched until this one completes.
const PendingClipboard = union(enum) {
    none,
    write: struct {
        targets: rex.terminal.term.Clipboard.Targets,
        len: u32,
    },
    read: struct {
        targets: rex.terminal.term.Clipboard.Targets,
        control_format: rex.terminal.term.ControlFormat,
    },
};

const clipboard_actions = [_]alert_dialog.Action{
    .{ .label = "Allow Once" },
    .{ .label = "Always Allow", .variant = .primary },
    .{ .label = "Deny", .role = .dismiss, .variant = .destructive },
};
const clipboard_allow_once = 0;
const clipboard_allow_always = 1;
const clipboard_deny = 2;

/// What App does with an OSC 52 request (ADR 0006).
const ClipboardAction = union(enum) {
    ignore,
    /// Set these selections to the write's data.
    set: rex.terminal.term.Clipboard.Targets,
    /// Prompt before setting these selections.
    ask_write: rex.terminal.term.Clipboard.Targets,
    /// Reply with the content of the first of these selections that has
    /// text: CLIPBOARD, then PRIMARY.
    reply_selection: rex.terminal.term.Clipboard.Targets,
    /// Prompt before reading these selections.
    ask_read: rex.terminal.term.Clipboard.Targets,
    /// Reply with no data, so a waiting program (Neovim waits up to 10 s)
    /// doesn't hang on a refused read.
    reply_empty,
};

fn effectiveClipboardPolicy(policy: Config.Clipboard, session: ClipboardSession) Config.Clipboard {
    return .{
        .osc52_write = if (policy.osc52_write == .ask and session.allow_write) .allow else policy.osc52_write,
        .osc52_read = if (policy.osc52_read == .ask and session.allow_read) .allow else policy.osc52_read,
    };
}

fn clipboardAction(policy: Config.Clipboard, request: rex.driver.ClipboardRequest) ClipboardAction {
    return switch (request) {
        .write => |w| switch (policy.osc52_write) {
            .allow => .{ .set = w.targets },
            .ask => .{ .ask_write = w.targets },
            .deny => .ignore,
        },
        .read => |r| switch (policy.osc52_read) {
            .allow => .{ .reply_selection = r.targets },
            .ask => .{ .ask_read = r.targets },
            .deny => .reply_empty,
        },
    };
}

fn clipboardAskBodyFor(pending: PendingClipboard, program: ?[]const u8, buf: []u8) []const u8 {
    switch (pending) {
        .none => return "",
        .read => {
            if (program) |name| {
                return std.fmt.bufPrint(buf, "{s} is asking to read your clipboard via OSC 52.", .{name}) catch
                    "A program is asking to read your clipboard via OSC 52.";
            }
            return "A program in this terminal is asking to read your clipboard via OSC 52.";
        },
        .write => |w| {
            if (w.len == 0) {
                if (program) |name| {
                    return std.fmt.bufPrint(buf, "{s} is asking to clear your clipboard via OSC 52.", .{name}) catch
                        "A program is asking to clear your clipboard via OSC 52.";
                }
                return "A program in this terminal is asking to clear your clipboard via OSC 52.";
            }
            const unit = if (w.len == 1) "byte" else "bytes";
            if (program) |name| {
                return std.fmt.bufPrint(buf, "{s} is asking to copy {d} {s} to your clipboard via OSC 52.", .{ name, w.len, unit }) catch
                    "A program is asking to write to your clipboard via OSC 52.";
            }
            return std.fmt.bufPrint(buf, "A program in this terminal is asking to copy {d} {s} to your clipboard via OSC 52.", .{ w.len, unit }) catch
                "A program in this terminal is asking to write to your clipboard via OSC 52.";
        },
    }
}

fn clipboardAskDialogRequest(
    pending: PendingClipboard,
    icon: @import("config/overlay.zig").AlertDialog.Icon,
    program: ?[]const u8,
    body_buf: []u8,
) alert_dialog.Request {
    const title = switch (pending) {
        .read => "Allow clipboard read?",
        .write, .none => "Allow clipboard write?",
    };
    const fallback_icon: u21 = switch (pending) {
        .read => icons.alert_triangle,
        .write, .none => icons.info,
    };
    return .{
        .media = alertDialogMedia(icon).codepoint(fallback_icon),
        .title = title,
        .body = clipboardAskBodyFor(pending, program, body_buf),
        .actions = &clipboard_actions,
        // Always focus Deny so stray terminal input cannot accidentally
        // grant clipboard access if an OSC 52 arrives while typing.
        .focus = clipboard_deny,
        .scrim_alpha = null,
    };
}

const base64_encoder = std.base64.standard.Encoder;

/// Length of an OSC 52 read reply carrying `text_len` bytes.
fn readReplyLen(format: rex.terminal.term.ControlFormat, text_len: usize) usize {
    const term_ns = rex.terminal.term;
    return term_ns.seqIntroducer(.osc, format).len + "52;c;".len +
        base64_encoder.calcSize(text_len) + term_ns.seqIntroducer(.st, format).len;
}

/// Writes `OSC 52 ; selection ; base64(text) ST` into `dest`, which holds
/// exactly `readReplyLen(format, text.len)` bytes. Empty text is the empty
/// reply.
fn writeReadReply(dest: []u8, format: rex.terminal.term.ControlFormat, selection: u8, text: []const u8) []const u8 {
    std.debug.assert(dest.len == readReplyLen(format, text.len));
    const term_ns = rex.terminal.term;
    var w: std.Io.Writer = .fixed(dest);
    w.print("{s}52;{c};", .{ term_ns.seqIntroducer(.osc, format), selection }) catch unreachable; // sized above
    const encoded = base64_encoder.encode(dest[w.end..][0..base64_encoder.calcSize(text.len)], text);
    w.end += encoded.len;
    w.writeAll(term_ns.seqIntroducer(.st, format)) catch unreachable;
    return w.buffered();
}

/// Applies or answers the pending OSC 52 request.
fn handleClipboard(self: *App) void {
    if (self.pending_clipboard != .none) return;
    const request = self.driver.takeClipboard(self.clipboard_buf[0..terminal_option.max_clipboard_bytes]) orelse return;
    const policy = effectiveClipboardPolicy(self.config.clipboard, self.clipboard_session);
    switch (clipboardAction(policy, request)) {
        .ignore => log.debug("OSC 52: ignored {t}", .{request}),
        .set => |targets| applyClipboardWrite(targets, request.write.data, &self.window, self.clipboard_buf),
        .reply_selection => |targets| applyClipboardRead(self.allocator, targets, request.read.control_format, &self.window, &self.driver),
        .reply_empty => {
            const read = request.read;
            sendEmptyReply(&self.driver, read.control_format, if (read.targets.clipboard) 'c' else 'p');
        },
        .ask_write => |targets| {
            // Reject NUL-containing writes before prompting.
            if (std.mem.indexOfScalar(u8, request.write.data, 0) != null) {
                log.warn("OSC 52: ignored a {d}-byte write that contains a NUL byte", .{request.write.data.len});
                return;
            }
            self.pending_clipboard = .{
                .write = .{ .targets = targets, .len = @intCast(request.write.data.len) },
            };
            self.maybeOpenClipboardDialog();
        },
        .ask_read => |targets| {
            self.pending_clipboard = .{
                .read = .{ .targets = targets, .control_format = request.read.control_format },
            };
            self.maybeOpenClipboardDialog();
        },
    }
}

fn maybeOpenClipboardDialog(self: *App) void {
    if (self.pending_clipboard == .none) return;
    if (self.dialog_kind != .none or self.wellbeing_state.input_locked or !self.window_focused) return;
    const kit = self.kit orelse {
        denyPendingClipboard(&self.pending_clipboard, &self.driver);
        return;
    };
    var name_buf: [32]u8 = undefined;
    const program = self.foregroundProgram(&name_buf);
    var body_buf: [alert_dialog.body_capacity]u8 = undefined;
    const req = clipboardAskDialogRequest(
        self.pending_clipboard,
        self.config.window.alert_dialog.icon,
        program,
        &body_buf,
    );
    if (kit.openDialog(req)) {
        self.dialog_kind = .clipboard_ask;
        self.showPointer();
        self.updatePointerShape(false);
        self.needs_redraw = true;
    }
}

fn allowPendingClipboard(
    gpa: std.mem.Allocator,
    pending: *PendingClipboard,
    buf: *[terminal_option.max_clipboard_bytes + 1]u8,
    window: *Window,
    driver: *Driver,
) void {
    const req = pending.*;
    pending.* = .none;
    switch (req) {
        .none => {},
        .write => |w| applyClipboardWrite(w.targets, buf[0..w.len], window, buf),
        .read => |r| applyClipboardRead(gpa, r.targets, r.control_format, window, driver),
    }
}

fn denyPendingClipboard(pending: *PendingClipboard, driver: *Driver) void {
    const req = pending.*;
    pending.* = .none;
    switch (req) {
        .none => {},
        .write => log.debug("OSC 52: user denied write", .{}),
        .read => |r| sendEmptyReply(driver, r.control_format, if (r.targets.clipboard) 'c' else 'p'),
    }
}

fn reconcilePendingClipboard(self: *App) void {
    if (self.pending_clipboard == .none) return;
    const eff = effectiveClipboardPolicy(self.config.clipboard, self.clipboard_session);
    const direction_policy = switch (self.pending_clipboard) {
        .none => return,
        .write => eff.osc52_write,
        .read => eff.osc52_read,
    };
    switch (direction_policy) {
        .ask => {},
        .allow => {
            if (self.dialog_kind == .clipboard_ask) {
                if (self.kit) |kit| _ = kit.dialogInput(.dismiss);
                self.dialog_kind = .none;
            }
            allowPendingClipboard(self.allocator, &self.pending_clipboard, self.clipboard_buf, &self.window, &self.driver);
            self.needs_redraw = true;
            self.handleClipboard();
        },
        .deny => {
            if (self.dialog_kind == .clipboard_ask) {
                if (self.kit) |kit| _ = kit.dialogInput(.dismiss);
                self.dialog_kind = .none;
            }
            denyPendingClipboard(&self.pending_clipboard, &self.driver);
            self.needs_redraw = true;
            self.handleClipboard();
        },
    }
}

fn applyClipboardWrite(
    targets: rex.terminal.term.Clipboard.Targets,
    data: []const u8,
    window: *Window,
    buf: *[terminal_option.max_clipboard_bytes + 1]u8,
) void {
    // GLFW takes a NUL-terminated string: refuse rather than cut.
    if (std.mem.indexOfScalar(u8, data, 0) != null) {
        log.warn("OSC 52: ignored a {d}-byte write that contains a NUL byte", .{data.len});
        return;
    }
    buf[data.len] = 0;
    const text = buf[0..data.len :0];
    if (targets.clipboard) window.setClipboard(text);
    if (targets.primary) _ = window.setPrimarySelection(text);
}

fn applyClipboardRead(
    gpa: std.mem.Allocator,
    targets: rex.terminal.term.Clipboard.Targets,
    format: rex.terminal.term.ControlFormat,
    window: *Window,
    driver: *Driver,
) void {
    var selection: u8 = 'c';
    var text: ?[:0]const u8 = null;
    if (targets.clipboard) text = window.getClipboard();
    if (text == null and targets.primary) {
        selection = 'p';
        text = window.getPrimarySelection();
    }
    const content = text orelse "";
    if (content.len > terminal_option.max_clipboard_bytes) {
        log.warn("OSC 52: the selection ({d} bytes) is over the {d}-byte limit; sent an empty reply", .{ content.len, terminal_option.max_clipboard_bytes });
        return sendEmptyReply(driver, format, selection);
    }
    const reply = gpa.alloc(u8, readReplyLen(format, content.len)) catch {
        log.err("OSC 52: out of memory for a {d}-byte reply; sent an empty reply", .{content.len});
        return sendEmptyReply(driver, format, selection);
    };
    defer gpa.free(reply);
    driver.sendReply(writeReadReply(reply, format, selection, content)) catch |err|
        log.err("OSC 52: cannot send the reply: {}", .{err});
}

/// Applies or answers one OSC 52 request synchronously (ADR 0006). A write's
/// data lives in `buf`, which has room for the NUL GLFW needs. Main thread only.
fn serveClipboard(
    gpa: std.mem.Allocator,
    policy: Config.Clipboard,
    request: rex.driver.ClipboardRequest,
    window: *Window,
    driver: *Driver,
    buf: *[terminal_option.max_clipboard_bytes + 1]u8,
) void {
    switch (clipboardAction(policy, request)) {
        .ignore, .ask_write => log.debug("OSC 52: ignored {t}", .{request}),
        .set => |targets| applyClipboardWrite(targets, request.write.data, window, buf),
        .reply_selection => |targets| applyClipboardRead(gpa, targets, request.read.control_format, window, driver),
        .reply_empty, .ask_read => {
            const read = request.read;
            sendEmptyReply(driver, read.control_format, if (read.targets.clipboard) 'c' else 'p');
        },
    }
}

fn sendEmptyReply(driver: *Driver, format: rex.terminal.term.ControlFormat, selection: u8) void {
    var buf: [16]u8 = undefined;
    const reply = writeReadReply(buf[0..readReplyLen(format, 0)], format, selection, "");
    driver.sendBytes(reply) catch |err| log.err("OSC 52: cannot send the empty reply: {}", .{err});
}

fn copySelectionToClipboard(self: *App) void {
    var buf: [max_copy_size]u8 = undefined;
    const len = self.driver.copySelectionText(self.selection, &buf);
    if (len == 0) return;
    buf[len] = 0; // null-terminate for the platform
    self.window.setClipboard(buf[0..len :0]);
}

/// The xterm report button for a platform button.
fn mouseButtonOf(button: PlatformEvents.MouseButton) MouseButton {
    return switch (button) {
        .left => .left,
        .middle => .middle,
        .right => .right,
    };
}

fn trackMouseButton(self: *App, button: PlatformEvents.MouseButton, press: bool) void {
    const held = mouseButtonOf(button);
    if (press) self.mouse_held.press(held) else self.mouse_held.release(held);
}

fn vtModByte(mods: input.Modifiers) u8 {
    var m: u8 = 0;
    if (mods.shift) m |= 4;
    if (mods.alt) m |= 8;
    if (mods.ctrl) m |= 16;
    return m;
}

fn detectMouseClickKind(self: *App, anchor: i32, col: u16, mods: input.Modifiers, scroll_gen: i64, scrollback_used: i64) rex.Selection.Kind {
    const now_ms = self.platform.now(self.io) * 1000.0;

    self.mouse_click_count = blk: {
        const prev_anchor = resolveAnchor(self.mouse_last_click_pos, scroll_gen, scrollback_used);
        const same_spot = if (prev_anchor) |pca|
            (pca == @as(i64, anchor) and self.mouse_last_click_pos.col == col)
        else
            false;

        const within_time = (now_ms - self.mouse_last_click_ms) <= @as(f64, @floatFromInt(self.config.selection.mouse_double_click_interval_ms));

        if (same_spot and within_time)
            break :blk @min(self.mouse_click_count +| 1, 3)
        else
            break :blk 1;
    };
    self.mouse_last_click_ms = now_ms;
    self.mouse_last_click_pos = .{ .row = anchor, .col = col, .captured_scroll_gen = scroll_gen };

    const kind: rex.Selection.Kind = switch (self.mouse_click_count) {
        1 => .character,
        2 => .word,
        3 => .line,
        else => .character,
    };
    return if (mods.alt) .block else kind;
}

fn handleSelectionPress(self: *App, row: u16, col: u16, mods: input.Modifiers) void {
    const frame = self.driver.getFrame();
    const viewport_offset = @as(i32, @intCast(frame.viewport_offset));
    const anchor = @as(i32, row) - viewport_offset;
    const scroll_gen = frame.total_lines_scrolled;
    const scrollback_used = @as(i64, @intCast(frame.scrollback_used));

    self.selection.kind = self.detectMouseClickKind(anchor, col, mods, scroll_gen, scrollback_used);
    self.selection.phase = .dragging;

    switch (self.selection.kind) {
        .character, .block => {
            self.selection.range.start.set(anchor, col, scroll_gen);
            self.selection.range.end.set(anchor, col, scroll_gen);
        },
        .word => {
            const left, const right = frame.wordsBoundsAt(&self.word_classifier, row, col, self.word_classifier.option.join);
            self.selection.range.start.set(anchor, left, scroll_gen);
            self.selection.range.end.set(anchor, right, scroll_gen);
        },
        .line => {
            const last_col = frame.active_cols - 1;
            self.selection.range.start.set(anchor, 0, scroll_gen);
            self.selection.range.end.set(anchor, last_col, scroll_gen);
        },
    }

    self.needs_redraw = true;
}

fn handleSelectionRelease(self: *App) void {
    if (self.selection.phase == .dragging) {
        // log.debug("release: dragged={} phase_before={t}", .{ self.selection.dragged(), self.selection.phase });
        // log.debug("release: start={} end={} dragged={}", .{ self.selection.range.start, self.selection.range.end, self.selection.dragged() });
        self.selection.phase = if (self.selection.dragged()) .selected else .none;
    }
}

/// Opens an OSC 8 link with the configured command. The URI comes from pty
/// bytes, so its scheme is checked against the allowlist and it is passed as
/// a single argv element, never through a shell (ADR 0012).
fn activateHyperlink(self: *App, uri: []const u8) void {
    const option = self.config.hyperlink;
    if (!option.enabled) return;
    const colon = std.mem.indexOfScalar(u8, uri, ':') orelse return;
    const Scheme = rex.config.hyperlink.Scheme;
    const scheme = std.meta.stringToEnum(Scheme, uri[0..colon]) orelse return;
    if (!option.schemes.contains(scheme)) return;

    const command: []const u8 = if (option.open_command.len == 0)
        (if (builtin.os.tag == .macos) "open" else "xdg-open")
    else
        option.open_command;
    const child = spawnDetached(self.io, &.{ command, uri }, .inherit) catch |err| {
        log.err("hyperlink: cannot open {s}: {}", .{ command, err });
        return;
    };
    reapDetached(child, "hyperlink");
}

fn reportMouseButton(self: *App, col: u16, row: u16, button: PlatformEvents.MouseButton, mod_byte: u8, press: bool) void {
    const held = mouseButtonOf(button);
    self.mouse_report_col = col;
    self.mouse_report_row = row;
    self.driver.sendInput(.{
        .mouse_button = .{
            .col = col,
            .row = row,
            .button = @intFromEnum(held),
            .mods = mod_byte,
            .press = press,
        },
    }) catch |err| {
        log.err("reportMouseButton: sendInput failed: {}", .{err});
    };
}

fn onMouseButton(self: *App, event: PlatformEvents.MouseButtonEvent) void {
    self.wellbeing_state.recordActivity();
    self.showPointer();
    const press = (event.action == .press);

    self.trackMouseButton(event.button, press);
    const mod_byte = vtModByte(event.mods);
    const shift_held = event.mods.shift;
    defer self.updatePointerShape(shift_held);

    const col, const row = self.mouseCellPos(self.mouse_x, self.mouse_y);
    const driver_modes = self.driver.getModes();
    const mouse_reporting = driver_modes.mouse_reporting;
    const frame = self.driver.getFrame();
    const scrollback_used = frame.scrollback_used;

    const modal_active = self.hasModalOverlay();

    if (event.button == .left) {
        if (press) {
            if (self.kit) |kit| {
                const lx = self.mouse_x / self.content_scale;
                const ly = self.mouse_y / self.content_scale;
                if (!self.wellbeing_state.input_locked and kit.lockScreenTakesInput() and kit.lockScreenHit(lx, ly) == .scrim) {
                    self.dismissWellbeingOverlay();
                    return;
                }
                switch (kit.press(lx, ly)) {
                    .outside => {},
                    .taken => return,
                    .changed => {
                        self.needs_redraw = true;
                        return;
                    },
                    .scrim => {
                        const outcome: alert_dialog.Event = if (self.config.window.modal.on_outside_click == .close) .dismiss else .blur;
                        self.applyDialogOutcome(kit.dialogInput(outcome));
                        return;
                    },
                }
            }
            if (modal_active) return;
            if (scrollback_used > 0 and self.handleScrollbarClick()) return;
        } else {
            if (self.kit) |kit| {
                // A dialog button is taken when the pointer is let go
                // on it.
                if (kit.holdsPress()) {
                    switch (kit.release(self.mouse_x / self.content_scale, self.mouse_y / self.content_scale)) {
                        .quiet => {},
                        .redraw => self.needs_redraw = true,
                        .dialog => |outcome| self.applyDialogOutcome(outcome),
                        .lock_unlocked => self.dismissWellbeingOverlay(),
                        .wellbeing_widget => |act| {
                            switch (act) {
                                .toggle => {
                                    self.wellbeing_state.toggleFocus(self.wallMs());
                                    self.ringBell();
                                },
                                .skip => {
                                    self.wellbeing_state.skipFocus(self.wallMs());
                                    self.ringBell();
                                },
                                .reset => self.wellbeing_state.resetFocus(self.wallMs()),
                            }
                            self.needs_redraw = true;
                            self.syncWellbeingKit(false);
                        },
                    }
                    return;
                }
            }
            if (modal_active) {
                _ = self.handleScrollbarRelease();
                self.handleSelectionRelease();
                return;
            }
            if (self.handleScrollbarRelease()) return;
        }
    } else if (modal_active) {
        return;
    }

    const is_primary = !frame.is_alternate;
    // log.debug("mouse_reporting={} shift_held={} is_primary={}", .{ mouse_reporting, shift_held, is_primary });
    // Ctrl+click opens an OSC 8 link; it takes precedence over both selection
    // and mouse reporting, and must not start a selection drag.
    const link_id = if (event.mods.ctrl and is_primary) frame.styleOf(frame.cellAt(row, col)).linkId() else 0;
    const has_link = link_id != 0 and frame.hyperlink(link_id) != null;
    if (press and event.button == .left and has_link) {
        self.pending_link = .{ .row = row, .col = col, .id = link_id };
    } else if (!press and self.pending_link != null) {
        const pending = self.pending_link.?;
        self.pending_link = null;
        if (event.button == .left and event.mods.ctrl and
            pending.row == row and pending.col == col and
            frame.styleOf(frame.cellAt(row, col)).linkId() == pending.id)
        {
            if (frame.hyperlink(pending.id)) |uri| self.activateHyperlink(uri);
            return;
        }
    }

    if (is_primary and (!mouse_reporting or shift_held)) {
        if (press and event.button == .left and !has_link) {
            self.handleSelectionPress(row, col, event.mods);
        } else if (!press) {
            self.handleSelectionRelease();
        }
    }

    if (mouse_reporting and !shift_held) {
        self.reportMouseButton(col, row, event.button, mod_byte, press);
    }
}

fn handleScrollbarRelease(self: *App) bool {
    if (!self.scrollbar_dragging) return false;
    self.scrollbar_dragging = false;
    self.needs_redraw = true;
    return true;
}

fn handleScrollbarClick(self: *App) bool {
    const frame = self.driver.getFrame();
    if (frame.is_alternate or frame.scrollback_used == 0) return false;
    const frame_width: f32 = @floatFromInt(self.frame_buffer_size.width);
    const frame_height: f32 = @floatFromInt(self.frame_buffer_size.height);
    const mouse_x = self.mouse_x;
    const mouse_y = self.mouse_y;
    if (!self.renderer.scrollbar.containsClickX(frame_width, mouse_x)) return false;

    // A click on the thumb drags from that point. A click in the track
    // jumps the thumb's centre to it.
    const thumb = self.scrollbarThumb();
    if (mouse_y >= thumb.top and mouse_y <= thumb.top + thumb.height) {
        self.scrollbar_drag_offset_y = mouse_y - thumb.top;
    } else {
        const new_top = std.math.clamp(mouse_y - thumb.height / 2.0, 0.0, thumb.travel(frame_height));
        const target = self.viewportOffsetAt(thumb.topFracAt(frame_height, new_top));
        self.sendViewportInput(.{ .set_viewport_offset = target });

        // Drag from where the cursor sits on the moved thumb: its centre,
        // unless the thumb was clamped at either end of the track.
        self.scrollbar_drag_offset_y = mouse_y - new_top;
    }

    self.scrollbar_dragging = true;
    self.needs_redraw = true;
    return true;
}

fn handleScrollbarDrag(self: *App) bool {
    if (!self.scrollbar_dragging) return false;

    const frame = self.driver.getFrame();
    const frame_height: f32 = @floatFromInt(self.frame_buffer_size.height);
    const thumb = self.scrollbarThumb();
    if (thumb.travel(frame_height) <= 0) return true; // consumed, nothing to move

    const top = self.mouse_y - self.scrollbar_drag_offset_y;
    const target = self.viewportOffsetAt(thumb.topFracAt(frame_height, top));
    if (target == frame.viewport_offset) return true; // nothing moved, so no redraw

    self.sendViewportInput(.{ .set_viewport_offset = target });
    self.needs_redraw = true;
    return true;
}

/// The primary screen's scrollbar thumb, placed exactly as the renderer
/// draws it, minimum height included.
fn scrollbarThumb(self: *const App) Scrollbar.Thumb {
    const frame = self.driver.getFrame();
    const frame_height: f32 = @floatFromInt(self.frame_buffer_size.height);
    const fracs: Scrollbar.Fractions = .of(frame.active_rows, frame.scrollback_used, frame.viewport_offset);
    return .of(frame_height, fracs.top, fracs.height, self.renderer.scrollbar.option.min_thumb_height);
}

/// The primary screen's viewport offset for a thumb at `top_frac`.
fn viewportOffsetAt(self: *const App, top_frac: f32) u32 {
    const frame = self.driver.getFrame();
    return Scrollbar.Fractions.viewportOffsetAt(top_frac, frame.scrollback_used);
}

fn updateScrollbarHover(self: *App) void {
    const sb = &self.renderer.scrollbar;
    const frame = self.driver.getFrame();
    const new_hover = blk: {
        if (self.hasModalOverlay() or frame.scrollback_used == 0 or frame.is_alternate) break :blk false;
        const fb_w: f32 = @floatFromInt(self.frame_buffer_size.width);
        break :blk sb.containsHoverX(fb_w, self.mouse_x);
    };

    if (new_hover == sb.hover) return;
    sb.hover = new_hover;
    self.renderer_dirty = true;
    self.needs_redraw = true;
}

fn flushScroll(self: *App) void {
    if (self.scroll_accumulator_y == 0) return;

    const steps: i32 = @intFromFloat(self.scroll_accumulator_y);
    if (steps == 0) return; // fractional remainder only, not a full line/step yet
    self.scroll_accumulator_y -= @floatFromInt(steps);

    const col, const row = self.mouseCellPos(self.mouse_x, self.mouse_y);
    const button: u8 = if (steps > 0) 64 else 65;
    const abs_steps: u16 = @intCast(@abs(steps));

    self.driver.sendInput(.{
        .mouse_scroll = .{
            .col = col,
            .row = row,
            .button = button,
            .steps = abs_steps,
        },
    }) catch |err| {
        log.err("flushScroll: sendInput failed: {}", .{err});
    };
    self.needs_redraw = true;
}

/// Sends a viewport scroll or offset to the driver. When the input queue is
/// full the event is dropped on purpose: it only moves the view, and the next
/// keystroke, wheel step or drag sends a fresh one.
fn sendViewportInput(self: *App, event: InputEvent) void {
    self.driver.sendInput(event) catch {};
}

fn onScroll(self: *App, dx: f64, dy: f64) void {
    _ = dx; // horizontal wheel movement is not reported today
    self.wellbeing_state.recordActivity();
    self.showPointer();
    if (self.hasModalOverlay()) return;

    // Clear sub-line fractional remainder on scroll direction reversal to eliminate hysteresis
    if ((self.scroll_accumulator_y > 0 and dy < 0) or (self.scroll_accumulator_y < 0 and dy > 0)) {
        self.scroll_accumulator_y = 0;
    }

    const modes = self.driver.getModes();
    const multiplier: f64 = if (modes.reports_wheel)
        1.0
    else
        @as(f64, @floatFromInt(self.config.scroll.wheel_lines));

    self.scroll_accumulator_y += dy * multiplier;
    self.flushScroll();
}

fn sendMouseMotion(self: *App, col: u16, row: u16) void {
    if (col == self.mouse_report_col and row == self.mouse_report_row) return;
    self.mouse_report_col = col;
    self.mouse_report_row = row;
    const button: ?u8 = if (self.mouse_held.dragged()) |held| @intFromEnum(held) else null;
    self.driver.sendInput(.{
        .mouse_motion = .{
            .col = col,
            .row = row,
            .button = button,
            .mods = 0,
        },
    }) catch |err| {
        log.err("sendMouseMotion: sendInput failed: {}", .{err});
    };
}

/// Only leaving matters: the move that follows an enter says where the
/// pointer is.
fn onCursorEnter(self: *App, entered: bool) void {
    if (entered) return;
    self.showPointer();
    if (self.kit) |kit| {
        if (kit.pointerLeft()) self.needs_redraw = true;
    }
}

fn onCursorPos(self: *App, x: f64, y: f64) void {
    const new_x: f32 = @floatCast(x);
    const new_y: f32 = @floatCast(y);
    if (new_x != self.mouse_x or new_y != self.mouse_y) {
        self.showPointer();
    }
    self.mouse_x = new_x;
    self.mouse_y = new_y;
    const shift_held = self.selection.phase == .dragging or
        self.platform.isKeyDown(self.window, .left_shift) or
        self.platform.isKeyDown(self.window, .right_shift);
    defer self.updatePointerShape(shift_held);
    if (self.kit) |kit| {
        if (kit.pointerMoved(self.mouse_x / self.content_scale, self.mouse_y / self.content_scale)) self.needs_redraw = true;
        if (kit.holdsPress()) return;
    }

    // update scrollbar hover detection
    self.updateScrollbarHover();
    if (self.hasModalOverlay()) return;

    // Scrollbar drag
    if (self.handleScrollbarDrag()) return;

    const col, const row = self.mouseCellPos(self.mouse_x, self.mouse_y);

    const driver_modes = self.driver.getModes();
    const mouse_reporting = driver_modes.mouse_reporting;

    // A shift-drag selects text even while the host tracks the mouse.
    if (mouse_reporting and self.selection.phase != .dragging) {
        if (driver_modes.reports_motion) {
            self.sendMouseMotion(col, row);
        }
        return;
    }

    const left_held = self.mouse_held.isHeld(.left);

    if (left_held and self.selection.phase == .dragging) {
        const frame = self.driver.getFrame();
        if (frame.is_alternate) return;

        const viewport_offset = @as(i32, @intCast(frame.viewport_offset));
        const anchor: i32 = @as(i32, row) - viewport_offset;
        const scroll_gen = frame.total_lines_scrolled;
        const scrollback_used = @as(i64, @intCast(frame.scrollback_used));

        switch (self.selection.kind) {
            .character, .block => {
                _ = self.selection.range.set(.end, .{ .row = anchor, .col = col, .captured_scroll_gen = scroll_gen });
            },
            .word => {
                const join_option = self.word_classifier.option.join;
                // Union the drag-point's word bounds with the ORIGINAL click's word
                // bounds, extending outward from the click, not re-snapping independently.
                const left, const right = frame.wordsBoundsAt(&self.word_classifier, row, col, join_option);

                const click_anchor = resolveAnchor(
                    self.mouse_last_click_pos,
                    scroll_gen,
                    scrollback_used,
                ) orelse return; // click row evicted from scrollback, bail, don't extend a dead selection
                const click_col = self.mouse_last_click_pos.col;
                const click_row_i = click_anchor + @as(i64, @intCast(frame.viewport_offset));
                const click_row: usize = if (click_row_i >= 0 and click_row_i < frame.active_rows)
                    @intCast(click_row_i)
                else
                    @intCast(row);
                const click_left, const click_right = frame.wordsBoundsAt(&self.word_classifier, click_row, click_col, join_option);

                if (@as(i64, anchor) < click_anchor or (anchor == click_anchor and col < click_col)) {
                    // dragging backward: end snaps to the far-left word boundary,
                    // start stays pinned to the click's right boundary
                    self.selection.range.start.set(@intCast(click_anchor), click_right, scroll_gen);
                    self.selection.range.end.set(anchor, left, scroll_gen);
                } else {
                    self.selection.range.start.set(@intCast(click_anchor), click_left, scroll_gen);
                    self.selection.range.end.set(anchor, right, scroll_gen);
                }
            },
            .line => {
                const last_col = frame.active_cols - 1;
                const click_anchor = resolveAnchor(
                    self.mouse_last_click_pos,
                    scroll_gen,
                    scrollback_used,
                ) orelse return; // click row evicted from scrollback, bail, don't extend a dead selection
                if (@as(i64, anchor) < click_anchor) {
                    self.selection.range.start.set(@intCast(click_anchor), last_col, scroll_gen);
                    self.selection.range.end.set(anchor, 0, scroll_gen);
                } else {
                    self.selection.range.start.set(@intCast(click_anchor), 0, scroll_gen);
                    self.selection.range.end.set(anchor, last_col, scroll_gen);
                }
            },
        }

        self.needs_redraw = true;
    }
}

fn onFocus(self: *App, focused: bool) void {
    if (self.window_focused != focused) {
        self.window_focused = focused;
        if (!focused) self.mods_down = .{};
        self.syncWindowEffects();
        self.renderer_dirty = true;
        self.needs_redraw = true;
    }
    self.showPointer();
    self.wellbeing_state.windowFocusChanged(focused);
    if (focused) {
        self.applyPendingBanner();
        self.maybeOpenClipboardDialog();
    }
    const modes = self.driver.getModes();
    if (!modes.focus_events) return;
    self.driver.sendInput(.{ .focus = focused }) catch |err| {
        log.err("windowFocusCallback: sendInput failed: {}", .{err});
    };
}

fn onFramebufferSize(self: *App, width: u32, height: u32) void {
    // The backend reports a scale change just before the framebuffer size it
    // causes (wl_window.c, fractionalScaleHandlePreferredScale). Applying
    // the scale first resizes the grid once, with the new font; otherwise
    // the pty sees an extra resize computed with the old cell size.
    if (self.content_scale_pending) |scale| {
        self.content_scale_pending = null;
        self.applyContentScale(scale);
    }
    // A no-op when applyContentScale already resized to this size.
    self.handleResize(.{ .height = @intCast(height), .width = @intCast(width) });
}

fn onContentScale(self: *App, x: f32, y: f32) void {
    _ = y; // the backend reports one scale per axis; Rex uses the horizontal one
    self.content_scale_pending = x;
}

fn onClose(self: *App) void {
    self.requestQuit();
}

test "FrameLatch: starts at the monitor's refresh rate, or 60 Hz" {
    try std.testing.expectEqual(@as(u64, 1_000_000_000 / 60), FrameLatch.init(60).period_ns);
    try std.testing.expectEqual(@as(u64, 1_000_000_000 / 144), FrameLatch.init(144).period_ns);
    try std.testing.expectEqual(@as(u64, 1_000_000_000 / 60), FrameLatch.init(null).period_ns);
}

test "FrameLatch: a wrong starting period corrects itself after two agreeing swaps" {
    // Seeded for 165 Hz while the window refreshes at 60 Hz.
    var latch: FrameLatch = .init(165);
    const real: u64 = 16_666_667;
    var t: u64 = 100_000_000;
    // Each swap blocks 10 ms and returns at a 60 Hz vblank.
    for (0..3) |_| {
        latch.observe(t - 10_000_000, t, 300_000);
        t += real;
    }
    try std.testing.expect(latch.period_ns > 16_000_000 and latch.period_ns < 17_300_000);
}

/// Feeds `latch` `count` frames `gap_ns` apart, each drawn the moment it
/// was due, on a display refreshing every `refresh_ns`: the swap waits for
/// the next vblank after it starts.
fn runFrames(latch: *FrameLatch, start_ns: u64, gap_ns: u64, refresh_ns: u64, count: usize) void {
    var enter = start_ns;
    for (0..count) |_| {
        const vblank = (enter / refresh_ns + 1) * refresh_ns;
        latch.observe(enter, vblank, 300_000);
        enter += gap_ns;
    }
}

test "FrameLatch: frames at typing pace are not refresh samples" {
    // Key repeat every 33 ms on a 60 Hz and on a 165 Hz display, and a
    // key every 65 ms: the gaps are whole numbers of refreshes, alike
    // enough to pass for a period.
    const cases = [_]struct { hz: u32, gap_ns: u64 }{
        .{ .hz = 60, .gap_ns = 33_000_000 },
        .{ .hz = 165, .gap_ns = 33_000_000 },
        .{ .hz = 165, .gap_ns = 65_000_000 },
        .{ .hz = 60, .gap_ns = 65_000_000 },
    };
    for (cases) |case| {
        var latch: FrameLatch = .init(case.hz);
        const start = latch.period_ns;
        // Starts 1 ms after a vblank, so every swap waits a trusted time.
        runFrames(&latch, start * 10 + 1_000_000, case.gap_ns, start, 200);
        try std.testing.expectEqual(start, latch.period_ns);
        try std.testing.expectEqual(@as(u64, 0), latch.candidate_ns);
    }
}

test "FrameLatch: frames drawn every refresh keep the period" {
    var latch: FrameLatch = .init(165);
    const refresh: u64 = 1_000_000_000 / 165;
    runFrames(&latch, refresh * 10 + 1_000_000, refresh, refresh, 200);
    try std.testing.expect(latch.period_ns > refresh - refresh / 10 and latch.period_ns < refresh + refresh / 10);
}

test "FrameLatch: back-to-back frames correct a start that was too slow" {
    // Seeded for 60 Hz while the window refreshes at 165 Hz.
    var latch: FrameLatch = .init(60);
    const refresh: u64 = 1_000_000_000 / 165;
    runFrames(&latch, refresh * 10 + 1_000_000, refresh, refresh, 4);
    try std.testing.expect(latch.period_ns > refresh - refresh / 10 and latch.period_ns < refresh + refresh / 10);
}

test "FrameLatch: no run of swaps takes the period past 50 ms" {
    var latch: FrameLatch = .init(60);
    // The worst a swap can report: each one starts right at the last
    // vblank and waits a little longer than the one before.
    var t: u64 = 1_000_000_000;
    var wait: u64 = 17_000_000;
    for (0..400) |_| {
        latch.observe(t, t + wait, 300_000);
        t += wait;
        wait = @min(wait + wait / 3, FrameLatch.max_period_ns);
        try std.testing.expect(latch.period_ns <= FrameLatch.max_period_ns);
        try std.testing.expect(latch.period_ns >= FrameLatch.min_period_ns);
    }
}

test "FrameLatch: one missed vblank does not change the period" {
    var latch: FrameLatch = .init(60);
    const p = latch.period_ns;
    latch.observe(98_000_000, 100_000_000, 300_000);
    // Two refreshes later: a missed vblank.
    latch.observe(131_000_000, 133_333_334, 300_000);
    try std.testing.expectEqual(p, latch.period_ns);
    // The next swap is one refresh on: still the same period.
    latch.observe(148_000_000, 150_000_000, 300_000);
    try std.testing.expect(latch.period_ns > p - 200_000 and latch.period_ns < p + 200_000);
}

test "FrameLatch: no known vblank draws immediately" {
    const latch: FrameLatch = .{};
    try std.testing.expectEqual(@as(u64, 0), latch.sleepNs(1_000_000));
    try std.testing.expectEqual(false, latch.pending(1_000_000));
}

test "FrameLatch: a vblank left over from an idle gap draws immediately" {
    const latch: FrameLatch = .{
        .period_ns = 6_000_000,
        .next_vblank_ns = 20_000_000,
    };
    try std.testing.expectEqual(false, latch.pending(1_000_000));
    try std.testing.expectEqual(@as(u64, 0), latch.sleepNs(1_000_000));
}

test "FrameLatch: a vblank inside two refreshes sleeps" {
    const latch: FrameLatch = .{
        .period_ns = 6_000_000,
        .margin_ns = 1_500_000,
        .render_ns = 500_000,
        .next_vblank_ns = 9_000_000,
    };
    // 8 ms ahead is more than one period and less than two.
    try std.testing.expectEqual(true, latch.pending(1_000_000));
    try std.testing.expectEqual(@as(u64, 6_000_000), latch.sleepNs(1_000_000));
}

test "FrameLatch: sleep leaves the margin and the last render before vblank" {
    const latch: FrameLatch = .{
        .period_ns = 6_000_000,
        .margin_ns = 1_500_000,
        .render_ns = 1_000_000,
        .next_vblank_ns = 8_000_000,
    };
    try std.testing.expectEqual(true, latch.pending(3_000_000));
    try std.testing.expectEqual(@as(u64, 2_500_000), latch.sleepNs(3_000_000));
    try std.testing.expectEqual(@as(u64, 0), latch.sleepNs(6_000_000));
}

test "FrameLatch: a swap that waited anchors the next vblank" {
    var latch: FrameLatch = .{ .period_ns = 6_000_000 };
    latch.observe(1_000_000, 7_000_000, 300_000);
    try std.testing.expectEqual(@as(u64, 13_000_000), latch.next_vblank_ns);
    try std.testing.expectEqual(false, latch.used_prediction);
}

test "FrameLatch: a swap that did not wait forgets the vblank" {
    var latch: FrameLatch = .{
        .period_ns = 6_000_000,
        .next_vblank_ns = 10_000_000,
        .used_prediction = true,
    };
    latch.observe(10_000_000, 10_040_000, 300_000);
    try std.testing.expectEqual(@as(u64, 0), latch.next_vblank_ns);
    try std.testing.expectEqual(@as(i64, -500_000), latch.shift_ns);
    try std.testing.expectEqual(false, latch.used_prediction);
    // The following block reanchors, and the missed aim draws earlier.
    latch.observe(10_100_000, 16_100_000, 300_000);
    try std.testing.expectEqual(@as(u64, 21_600_000), latch.next_vblank_ns);
}

test "FrameLatch: a long block after a prediction draws later next time" {
    var latch: FrameLatch = .{
        .period_ns = 6_000_000,
        .margin_ns = 1_500_000,
        .last_vblank_ns = 1_000_000,
        .used_prediction = true,
    };
    // Block is 5 ms, 3.5 ms past the margin. One step is capped at 0.2 ms.
    latch.observe(2_000_000, 7_000_000, 300_000);
    try std.testing.expectEqual(@as(i64, 200_000), latch.shift_ns);
    try std.testing.expectEqual(@as(u64, 13_200_000), latch.next_vblank_ns);
}

test "FrameLatch: the refresh period follows the gap between vblanks" {
    var latch: FrameLatch = .{ .period_ns = 6_000_000, .last_vblank_ns = 1_000_000 };
    latch.observe(2_000_000, 7_060_606, 300_000);
    try std.testing.expectEqual((6_000_000 * 7 + 6_060_606) / 8, latch.period_ns);
}

test "PeriodicTimer: counts whole periods and keeps the remainder" {
    var timer: PeriodicTimer = .{ .period_ms = 500 };
    try std.testing.expectEqual(0, timer.tick(499));
    try std.testing.expectEqual(1, timer.remaining());
    try std.testing.expectEqual(3, timer.tick(1001));
    try std.testing.expectEqual(500, timer.remaining());
}

test "PeriodicTimer: a zero period never fires and sets no deadline" {
    var timer: PeriodicTimer = .{ .period_ms = 0 };
    try std.testing.expectEqual(0, timer.tick(1000));
    try std.testing.expectEqual(std.math.maxInt(u64), timer.remaining());
}

test "PeriodicTimer: any period works, not only the defaults" {
    var timer: PeriodicTimer = .{ .period_ms = 333 };
    try std.testing.expectEqual(3, timer.tick(1000));
    try std.testing.expectEqual(332, timer.remaining());
}

test "reapInBackground: reaps a finished child without a zombie" {
    const child = try std.process.spawn(std.testing.io, .{
        .argv = &.{"true"},
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const pid = child.id.?;
    try reapInBackground(pid);

    // A zombie still answers kill(pid, 0); a reaped child does not.
    var tries: usize = 0;
    while (true) : (tries += 1) {
        posix.kill(pid, @enumFromInt(0)) catch |err| {
            try std.testing.expectEqual(error.ProcessNotFound, err);
            return;
        };
        if (tries == 200) return error.ChildNotReaped;
        std.Io.sleep(std.testing.io, .fromMilliseconds(10), .awake) catch {};
    }
}

test "clipboardAction: writes and reads follow the policy" {
    const write: rex.driver.ClipboardRequest = .{ .write = .{ .targets = .{ .clipboard = true }, .data = "hi" } };
    const primary: rex.driver.ClipboardRequest = .{ .write = .{ .targets = .{ .primary = true }, .data = "hi" } };
    const both: rex.driver.ClipboardRequest = .{ .write = .{ .targets = .{ .clipboard = true, .primary = true }, .data = "" } };
    const read: rex.driver.ClipboardRequest = .{ .read = .{ .targets = .{ .clipboard = true }, .control_format = .s7c1t } };
    const allow_all: Config.Clipboard = .{ .osc52_write = .allow, .osc52_read = .allow };
    const deny_all: Config.Clipboard = .{ .osc52_write = .deny, .osc52_read = .deny };
    const ask_all: Config.Clipboard = .{ .osc52_write = .ask, .osc52_read = .ask };
    try std.testing.expectEqual(ClipboardAction{ .set = .{ .clipboard = true } }, clipboardAction(allow_all, write));
    try std.testing.expectEqual(ClipboardAction{ .set = .{ .primary = true } }, clipboardAction(allow_all, primary));
    try std.testing.expectEqual(ClipboardAction{ .set = .{ .clipboard = true, .primary = true } }, clipboardAction(allow_all, both));
    try std.testing.expectEqual(ClipboardAction.ignore, clipboardAction(deny_all, write));
    try std.testing.expectEqual(ClipboardAction{ .ask_write = .{ .clipboard = true } }, clipboardAction(ask_all, write));
    try std.testing.expectEqual(ClipboardAction{ .reply_selection = .{ .clipboard = true } }, clipboardAction(allow_all, read));
    try std.testing.expectEqual(ClipboardAction.reply_empty, clipboardAction(deny_all, read));
    try std.testing.expectEqual(ClipboardAction.reply_empty, clipboardAction(.{}, read)); // the default
    try std.testing.expectEqual(ClipboardAction{ .ask_read = .{ .clipboard = true } }, clipboardAction(ask_all, read));

    // Per-window session permission promotes `.ask` -> `.allow` per direction,
    // without overriding explicit `.deny`.
    const session_read: ClipboardSession = .{ .allow_read = true };
    try std.testing.expectEqual(
        Config.Clipboard{ .osc52_write = .ask, .osc52_read = .allow },
        effectiveClipboardPolicy(ask_all, session_read),
    );
    try std.testing.expectEqual(
        Config.Clipboard{ .osc52_write = .deny, .osc52_read = .deny },
        effectiveClipboardPolicy(deny_all, .{ .allow_write = true, .allow_read = true }),
    );
}

test "clipboard ask dialog: copy, focus safety, and icons" {
    const testing = std.testing;
    var buf: [alert_dialog.body_capacity]u8 = undefined;

    const read_req: PendingClipboard = .{ .read = .{ .targets = .{ .clipboard = true }, .control_format = .s7c1t } };
    try testing.expectEqualStrings(
        "nvim is asking to read your clipboard via OSC 52.",
        clipboardAskBodyFor(read_req, "nvim", &buf),
    );
    try testing.expectEqualStrings(
        "A program in this terminal is asking to read your clipboard via OSC 52.",
        clipboardAskBodyFor(read_req, null, &buf),
    );

    const clear_req: PendingClipboard = .{ .write = .{ .targets = .{ .clipboard = true }, .len = 0 } };
    try testing.expectEqualStrings(
        "tmux is asking to clear your clipboard via OSC 52.",
        clipboardAskBodyFor(clear_req, "tmux", &buf),
    );

    const write_one: PendingClipboard = .{ .write = .{ .targets = .{ .clipboard = true }, .len = 1 } };
    try testing.expectEqualStrings(
        "A program in this terminal is asking to copy 1 byte to your clipboard via OSC 52.",
        clipboardAskBodyFor(write_one, null, &buf),
    );

    const req = clipboardAskDialogRequest(read_req, .warning, "nvim", &buf);
    try testing.expectEqualStrings("Allow clipboard read?", req.title);
    try testing.expectEqual(icons.alert_triangle, req.media);
    try testing.expectEqual(@as(u8, clipboard_deny), req.focus);
    try testing.expectEqual(@as(usize, 3), req.actions.len);
}

test "OSC 52 ask: Deny replies empty while Allow Once and Always Allow answer or set clipboard" {
    const testing = std.testing;
    var rig: ClipboardRig = try .init();
    defer rig.deinit();
    if (rig.platform.choice.system != .x11) return error.SkipZigTest;
    const kit = try KitOverlay.create(testing.allocator, .{
        .regular = "assets/fonts/Inter-Regular.ttf",
        .medium = "assets/fonts/Inter-Medium.ttf",
        .semibold = "assets/fonts/Inter-SemiBold.ttf",
    }, 1);
    defer kit.destroy(testing.allocator);

    rig.window.setClipboard("secret");
    var body_buf: [alert_dialog.body_capacity]u8 = undefined;
    var out: [64]u8 = undefined;

    // 1. Read under ask -> Deny / Esc returns empty reply immediately.
    const read_1 = try rig.program("\x1b]52;c;?\x07");
    var pending: PendingClipboard = .{
        .read = .{ .targets = read_1.read.targets, .control_format = read_1.read.control_format },
    };
    try testing.expect(kit.openDialog(clipboardAskDialogRequest(pending, .warning, null, &body_buf)));
    try testing.expectEqual(@as(u8, clipboard_deny), kit.dialog.focus);
    try testing.expectEqual(alert_dialog.Outcome.redraw, kit.dialogInput(.dismiss));
    try testing.expect(!kit.dialogTakesInput());
    denyPendingClipboard(&pending, &rig.driver);
    try testing.expectEqual(PendingClipboard.none, pending);
    try testing.expectEqualStrings("\x1b]52;c;\x1b\\", try rig.reply(&out, "\x1b]52;c;\x1b\\".len));

    // Finish closing the fading dialog before opening the next one cleanly.
    _ = kit.tick(500);

    // 2. Read under ask -> Allow Once replies with clipboard content without granting session.
    var session: ClipboardSession = .{};
    const read_2 = try rig.program("\x1b]52;c;?\x07");
    pending = .{ .read = .{ .targets = read_2.read.targets, .control_format = read_2.read.control_format } };
    try testing.expect(kit.openDialog(clipboardAskDialogRequest(pending, .warning, "nvim", &body_buf)));
    try testing.expectEqual(
        alert_dialog.Outcome{ .chosen = clipboard_allow_once },
        kit.dialogInput(.{ .take = clipboard_allow_once }),
    );
    allowPendingClipboard(testing.allocator, &pending, rig.buf, &rig.window, &rig.driver);
    try testing.expect(!session.allow_read);
    const want_reply = "\x1b]52;c;c2VjcmV0\x1b\\"; // base64("secret")
    try testing.expectEqualStrings(want_reply, try rig.reply(&out, want_reply.len));

    // 3. Read under ask -> Always Allow grants session permission for future reads.
    const read_3 = try rig.program("\x1b]52;c;?\x07");
    pending = .{ .read = .{ .targets = read_3.read.targets, .control_format = read_3.read.control_format } };
    try testing.expect(kit.openDialog(clipboardAskDialogRequest(pending, .warning, "nvim", &body_buf)));
    try testing.expectEqual(
        alert_dialog.Outcome{ .chosen = clipboard_allow_always },
        kit.dialogInput(.{ .take = clipboard_allow_always }),
    );
    session.grant(pending);
    allowPendingClipboard(testing.allocator, &pending, rig.buf, &rig.window, &rig.driver);
    try testing.expect(session.allow_read);
    try testing.expect(!session.allow_write);
    try testing.expectEqualStrings(want_reply, try rig.reply(&out, want_reply.len));

    // 4. Write under ask -> Deny keeps clipboard; Allow Once writes staged payload.
    const write_deny = try rig.program("\x1b]52;c;bm9wZQ==\x07"); // "nope"
    pending = .{ .write = .{ .targets = write_deny.write.targets, .len = @intCast(write_deny.write.data.len) } };
    try testing.expect(kit.openDialog(clipboardAskDialogRequest(pending, .info, null, &body_buf)));
    try testing.expectEqual(alert_dialog.Outcome.redraw, kit.dialogInput(.dismiss));
    denyPendingClipboard(&pending, &rig.driver);
    try testing.expectEqualStrings("secret", rig.window.getClipboard().?);

    _ = kit.tick(500);
    const write_ok = try rig.program("\x1b]52;c;b2s=\x07"); // "ok"
    pending = .{ .write = .{ .targets = write_ok.write.targets, .len = @intCast(write_ok.write.data.len) } };
    try testing.expect(kit.openDialog(clipboardAskDialogRequest(pending, .info, null, &body_buf)));
    try testing.expectEqual(
        alert_dialog.Outcome{ .chosen = clipboard_allow_once },
        kit.dialogInput(.{ .take = clipboard_allow_once }),
    );
    allowPendingClipboard(testing.allocator, &pending, rig.buf, &rig.window, &rig.driver);
    try testing.expectEqualStrings("ok", rig.window.getClipboard().?);
}

test "writeReadReply: exact bytes in 7-bit and 8-bit form, empty and not" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("\x1b]52;c;aGVsbG8=\x1b\\", writeReadReply(buf[0..readReplyLen(.s7c1t, 5)], .s7c1t, 'c', "hello"));
    try std.testing.expectEqualStrings("\x9d52;p;aGk=\x9c", writeReadReply(buf[0..readReplyLen(.s8c1t, 2)], .s8c1t, 'p', "hi"));
    try std.testing.expectEqualStrings("\x1b]52;c;\x1b\\", writeReadReply(buf[0..readReplyLen(.s7c1t, 0)], .s7c1t, 'c', ""));
}

/// Readies the shared GL context used by display tests. A platform value is
/// needed only to reach the backend helper; no GLFW type appears here.
fn readyTestGlContext() !void {
    const probe: Platform = .{ .choice = .{ .system = .x11, .forced = false } };
    try probe.testGlContext();
}

/// A single driver on a socket pair and a real platform window, for OSC 52
/// round trips through `serveClipboard`. `child` is the program's end of the
/// pty.
const ClipboardRig = struct {
    driver: Driver,
    child: posix.fd_t,
    platform: Platform,
    window: Window,
    buf: *[terminal_option.max_clipboard_bytes + 1]u8,

    fn init() !ClipboardRig {
        // The backend context helper skips when there is no display.
        try readyTestGlContext();
        const session_type = if (std.c.getenv("XDG_SESSION_TYPE")) |v| std.mem.span(v) else "";
        const wayland_session = std.c.getenv("WAYLAND_DISPLAY") != null or
            std.mem.eql(u8, session_type, "wayland");
        const choice: Choice = Platform.choose(.auto, wayland_session);
        var app_platform: Platform = try .init(choice);
        errdefer app_platform.deinit();
        var win: Window = try app_platform.createWindow(.{ .width = 1, .height = 1, .title = "test" });
        errdefer win.deinit();
        var sv: [2]posix.fd_t = undefined;
        try rex.termio.pipe.openSocketPair(&sv, .{ .NONBLOCK = true });
        errdefer _ = system.close(sv[1]);
        const pty: rex.termio.pty.Posix = .{ .master = sv[0], .pid = -1, .stdout_read_fd = -1, .error_read_fd = -1 };
        var driver: Driver = .{ .single = try .init(std.testing.allocator, std.testing.io, pty, .{ .theme = .default, .sync_output_timeout_ms = 150 }) };
        errdefer driver.deinit();
        return .{
            .driver = driver,
            .child = sv[1],
            .platform = app_platform,
            .window = win,
            .buf = try std.testing.allocator.create([terminal_option.max_clipboard_bytes + 1]u8),
        };
    }

    fn deinit(self: *ClipboardRig) void {
        std.testing.allocator.destroy(self.buf);
        self.driver.deinit();
        _ = system.close(self.child);
        self.window.deinit();
        self.platform.deinit();
    }

    /// The program writes `bytes`; returns the request the terminal made.
    fn program(self: *ClipboardRig, bytes: []const u8) !rex.driver.ClipboardRequest {
        var done: usize = 0;
        var tries: usize = 0;
        while (tries < 10_000) : (tries += 1) {
            if (done < bytes.len) {
                const n = system.write(self.child, bytes[done..].ptr, bytes.len - done);
                if (n > 0) done += @intCast(n);
            }
            const events = try self.driver.pollAndDrain();
            if (events.has(.clipboard)) {
                if (self.driver.takeClipboard(self.buf[0..terminal_option.max_clipboard_bytes])) |request| return request;
            }
        }
        return error.NoClipboardRequest;
    }

    /// Everything the terminal sent the program, until `len` bytes or none
    /// arrive for a while.
    fn reply(self: *ClipboardRig, out: []u8, len: usize) ![]const u8 {
        var got: usize = 0;
        var idle: usize = 0;
        while (got < len and idle < 1000) {
            const n = system.read(self.child, out[got..].ptr, out.len - got);
            if (n > 0) {
                got += @intCast(n);
                idle = 0;
            } else {
                idle += 1;
                _ = try self.driver.pollAndDrain(); // flushes pending output
            }
        }
        return out[0..got];
    }
};

const clipboard_texts = [_][]const u8{
    "a",
    "hello",
    "line one\nline two\ttabbed",
    "h\u{e9}llo \u{2014} \u{4e16}\u{754c} \u{1f642}",
    "x" ** 10_000,
};

test "OSC 52 copy: the program's text reaches CLIPBOARD and PRIMARY unchanged" {
    var rig: ClipboardRig = try .init();
    defer rig.deinit();
    if (rig.platform.choice.system != .x11) return error.SkipZigTest;
    const allow: Config.Clipboard = .{ .osc52_write = .allow, .osc52_read = .allow };
    var seq: [16 + base64_encoder.calcSize(10_000)]u8 = undefined;

    for (clipboard_texts) |text| for ("cp") |selection| {
        errdefer std.debug.print("selection {c} text {d} bytes\n", .{ selection, text.len });
        const head = try std.fmt.bufPrint(&seq, "\x1b]52;{c};", .{selection});
        const encoded = base64_encoder.encode(seq[head.len..], text);
        seq[head.len + encoded.len] = 0x07;
        const request = try rig.program(seq[0 .. head.len + encoded.len + 1]);
        serveClipboard(std.testing.allocator, allow, request, &rig.window, &rig.driver, rig.buf);
        const got = if (selection == 'c') rig.window.getClipboard() else rig.window.getPrimarySelection();
        try std.testing.expectEqualStrings(text, got.?);
    };

    // Refused writes leave the clipboard as it was; so does a NUL byte.
    rig.window.setClipboard("kept");
    const deny: Config.Clipboard = .{ .osc52_write = .deny };
    serveClipboard(std.testing.allocator, deny, try rig.program("\x1b]52;c;aGk=\x07"), &rig.window, &rig.driver, rig.buf);
    try std.testing.expectEqualStrings("kept", rig.window.getClipboard().?);
    // The NUL write is refused with a warning, which this test expects.
    const shown = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = shown;
    serveClipboard(std.testing.allocator, allow, try rig.program("\x1b]52;c;aABp\x07"), &rig.window, &rig.driver, rig.buf); // "h\x00i"
    try std.testing.expectEqualStrings("kept", rig.window.getClipboard().?);
}

test "OSC 52 paste: the reply carries the selection's text unchanged" {
    var rig: ClipboardRig = try .init();
    defer rig.deinit();
    if (rig.platform.choice.system != .x11) return error.SkipZigTest;
    const allow: Config.Clipboard = .{ .osc52_write = .allow, .osc52_read = .allow };
    var text_z: [10_001]u8 = undefined;
    var out: [32 + base64_encoder.calcSize(10_000)]u8 = undefined;
    var decoded: [10_000]u8 = undefined;

    for (clipboard_texts) |text| for ("cp") |selection| {
        errdefer std.debug.print("selection {c} text {d} bytes\n", .{ selection, text.len });
        @memcpy(text_z[0..text.len], text);
        text_z[text.len] = 0;
        if (selection == 'c') rig.window.setClipboard(text_z[0..text.len :0]) else _ = rig.window.setPrimarySelection(text_z[0..text.len :0]);
        const query = if (selection == 'c') "\x1b]52;c;?\x07" else "\x1b]52;p;?\x07";
        serveClipboard(std.testing.allocator, allow, try rig.program(query), &rig.window, &rig.driver, rig.buf);

        const want_len = readReplyLen(.s7c1t, text.len);
        const reply = try rig.reply(&out, want_len);
        try std.testing.expectEqual(want_len, reply.len);
        const head = if (selection == 'c') "\x1b]52;c;" else "\x1b]52;p;";
        try std.testing.expectEqualStrings(head, reply[0..head.len]);
        try std.testing.expectEqualStrings("\x1b\\", reply[reply.len - 2 ..]);
        const payload = reply[head.len .. reply.len - 2];
        const size = try std.base64.standard.Decoder.calcSizeForSlice(payload);
        try std.base64.standard.Decoder.decode(decoded[0..size], payload);
        try std.testing.expectEqualStrings(text, decoded[0..size]);
    };

    // Refused reads get the empty reply, whatever is in the clipboard.
    rig.window.setClipboard("secret");
    serveClipboard(std.testing.allocator, .{}, try rig.program("\x1b]52;c;?\x07"), &rig.window, &rig.driver, rig.buf);
    try std.testing.expectEqualStrings("\x1b]52;c;\x1b\\", try rig.reply(&out, readReplyLen(.s7c1t, 0)));
}

test "windowTitle: configured text wins, then the program's title, then the default" {
    try std.testing.expectEqualStrings("fixed", windowTitle("fixed", "vim"));
    try std.testing.expectEqualStrings("fixed", windowTitle("fixed", ""));
    try std.testing.expectEqualStrings("vim", windowTitle(null, "vim"));
    try std.testing.expectEqualStrings(Config.Window.default_title, windowTitle(null, ""));
}

test "Driver: single and threaded polymorphic dispatch" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var sv_single: [2]posix.fd_t = undefined;
    try rex.termio.pipe.openSocketPair(&sv_single, .{ .NONBLOCK = true });
    defer _ = system.close(sv_single[1]);
    const pty_single = rex.termio.pty.Posix{
        .master = sv_single[0],
        .pid = -1,
        .stdout_read_fd = -1,
        .error_read_fd = -1,
    };

    const driver_options: rex.driver.Options = .{ .theme = .default, .sync_output_timeout_ms = 150 };
    const single_driver: SingleDriverType = try .init(allocator, testing.io, pty_single, driver_options);
    var driver_s: Driver = .{ .single = single_driver };
    defer driver_s.deinit();

    try testing.expectEqual(@as(posix.pid_t, -1), driver_s.getPid());
    try testing.expect(!driver_s.getModes().cursor_keys);
    _ = driver_s.getFrame();

    var sv_multi: [2]posix.fd_t = undefined;
    try rex.termio.pipe.openSocketPair(&sv_multi, .{ .NONBLOCK = true });
    defer _ = system.close(sv_multi[1]);
    const pty_multi = rex.termio.pty.Posix{
        .master = sv_multi[0],
        .pid = -1,
        .stdout_read_fd = -1,
        .error_read_fd = -1,
    };

    const threaded_driver = try ThreadedDriverType.create(allocator, testing.io, pty_multi, driver_options, latency_trace.none);
    var driver_m: Driver = .{ .threaded = threaded_driver };
    defer driver_m.deinit();

    try testing.expectEqual(@as(posix.pid_t, -1), driver_m.getPid());
    try testing.expect(!driver_m.getModes().cursor_keys);
    try testing.expect(!driver_s.hasNewFrame());
    try testing.expect(!driver_m.hasNewFrame());
    _ = driver_m.getFrame();
}

test "ScrollAccumulator: smooth line accumulation and direction reversal" {
    const testing = std.testing;

    var accum_y: f64 = 0;
    const wheel_lines: u32 = 3;

    // Fractional tick 1: +0.25 notch on a smooth wheel
    var y_offset: f64 = 0.25;
    if ((accum_y > 0 and y_offset < 0) or (accum_y < 0 and y_offset > 0)) {
        accum_y = 0;
    }
    accum_y += y_offset * @as(f64, @floatFromInt(wheel_lines));
    var steps: i32 = @intFromFloat(accum_y);
    try testing.expectEqual(@as(i32, 0), steps);
    try testing.expectApproxEqAbs(@as(f64, 0.75), accum_y, 0.0001);

    // Fractional tick 2: +0.25 notch (total 1.5 lines) -> should flush 1 line
    y_offset = 0.25;
    if ((accum_y > 0 and y_offset < 0) or (accum_y < 0 and y_offset > 0)) {
        accum_y = 0;
    }
    accum_y += y_offset * @as(f64, @floatFromInt(wheel_lines));
    steps = @intFromFloat(accum_y);
    try testing.expectEqual(@as(i32, 1), steps);
    accum_y -= @floatFromInt(steps);
    try testing.expectApproxEqAbs(@as(f64, 0.5), accum_y, 0.0001);

    // Reversal: scroll down -0.2 notch -> opposite fractional remainder (+0.5) must reset to 0
    y_offset = -0.2;
    if ((accum_y > 0 and y_offset < 0) or (accum_y < 0 and y_offset > 0)) {
        accum_y = 0;
    }
    try testing.expectEqual(@as(f64, 0), accum_y);
    accum_y += y_offset * @as(f64, @floatFromInt(wheel_lines));
    try testing.expectApproxEqAbs(@as(f64, -0.6), accum_y, 0.0001);
}

test "quit dialog copy: the running program, or the idle ask" {
    const testing = std.testing;
    var buf: [alert_dialog.body_capacity]u8 = undefined;
    try testing.expectEqualStrings("This will end the active shell session.", quitDialogBodyFor(false, null, &buf));
    try testing.expectEqualStrings("A program is still running. Closing this window will end it.", quitDialogBodyFor(true, null, &buf));
    try testing.expectEqualStrings(
        "nvim is still running. Closing this window will end it.",
        quitDialogBodyFor(true, "nvim", &buf),
    );
}

test "PendingAlert copies title and description into fixed buffers" {
    const testing = std.testing;
    const alert = PendingAlert.init(.warn, "Config warning (line 2, col 1)", "unknown key");
    const req = alert.request();
    try testing.expectEqual(kit_alert.Kind.warn, req.kind);
    try testing.expectEqualStrings("Config warning (line 2, col 1)", req.title);
    try testing.expectEqualStrings("unknown key", req.description);
}

test "App: routeKeyToUi unified dispatcher consumes modal keys and suppresses text leakage" {
    const testing = std.testing;

    // Simulate modal close with 'q': routeKeyToUi handles the key and returns true.
    // The caller in keyCb automatically sets skip_next_char = true without the modal handler
    // needing to manage any low-level GLFW callback suppression state.
    var quit_confirm_open = true;
    var skip_next_char = false;

    // Simulated routeKeyToUi
    const key_consumed = blk: {
        if (quit_confirm_open) {
            quit_confirm_open = false; // Dismissed by Escape
            break :blk true;
        }
        break :blk false;
    };

    if (key_consumed) {
        skip_next_char = true;
    }

    try testing.expect(key_consumed);
    try testing.expect(skip_next_char);
    try testing.expect(!quit_confirm_open);

    // In charCb: character callback is suppressed and skip flag consumed
    var char_sent = false;
    if (skip_next_char) {
        skip_next_char = false;
    } else if (!quit_confirm_open) {
        char_sent = true;
    }
    try testing.expect(!char_sent);
    try testing.expect(!skip_next_char);

    // Subsequent normal typing is unconsumed and reaches the terminal
    const normal_key_consumed = blk: {
        if (quit_confirm_open) {
            break :blk true;
        }
        break :blk false;
    };
    if (normal_key_consumed) {
        skip_next_char = true;
    } else {
        skip_next_char = false;
    }

    if (skip_next_char) {
        skip_next_char = false;
    } else if (!quit_confirm_open) {
        char_sent = true;
    }
    try testing.expect(char_sent);
}

test "defaultShell: $SHELL, then the passwd shell, then /bin/sh" {
    try std.testing.expectEqualStrings("/bin/zsh", defaultShell("/bin/zsh", "/bin/bash"));
    try std.testing.expectEqualStrings("/bin/bash", defaultShell(null, "/bin/bash"));
    try std.testing.expectEqualStrings("/bin/bash", defaultShell("zsh", "/bin/bash"));
    try std.testing.expectEqualStrings("/bin/bash", defaultShell("", "/bin/bash"));
    try std.testing.expectEqualStrings("/bin/sh", defaultShell(null, null));
    try std.testing.expectEqualStrings("/bin/sh", defaultShell("", ""));
}

test "spawnShell: a missing program or directory fails to spawn, the defaults start" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const envp: [*:null]const ?[*:0]const u8 = &.{null};

    var failure: ?rex.termio.pty.SpawnFailure = null;
    try std.testing.expectError(error.SpawnFailed, spawnShell(gpa, io, .{ .program = "/nonexistent/rex-test-shell" }, "/bin/sh", envp, &failure));
    try std.testing.expectEqual(.execve, failure.?.stage);
    try std.testing.expectError(error.SpawnFailed, spawnShell(gpa, io, .{ .working_directory = "/nonexistent/rex-test-dir" }, "/bin/sh", envp, &failure));
    try std.testing.expectEqual(.chdir, failure.?.stage);

    // The fallback: no program (the login shell) and no directory.
    var pty = try spawnShell(gpa, io, .{ .arguments = &.{ "-c", "exit 0" } }, "/bin/sh", envp, &failure);
    pty.close(io);
    try std.testing.expect(!isDefaultShell(.{ .arguments = &.{"-l"} }));
    try std.testing.expect(isDefaultShell(.{}));
}

test "App: a config reload starts from the defaults, in its own arena" {
    // reloadConfig builds every config as: base defaults + file, all
    // allocations in a fresh arena. Check both properties on that recipe:
    // the file's allocations are owned by the arena (testing.allocator
    // reports any leak), and a setting removed from the file falls back
    // to the default instead of keeping the previous value.
    const testing = std.testing;
    const gpa = testing.allocator;

    const base: Config = .{
        .font = .{
            .faces = .{ .regular = "/base/regular.ttf" },
            .size = 20,
            .max_size = 96,
            .min_size = 6,
        },
        .keymap = rex.input.default_keymap,
        .theme = Theme.default,
        .window = .default,
        .scroll = .{},
        .selection = .default,
        .environments = &.{},
    };

    // First load: the file sets the font and rebinds Ctrl+= to quit.
    const family = "/user/font.ttf";
    var first = try Loaded.load(gpa, testing.io, &base, null, &.{.{
        .label = "config",
        .from = .{ .text = .{ .bytes = "[font]\nfile = " ++ family ++ "\n[keybinds]\nctrl+equal = quit\n", .dir = "/" } },
    }});
    defer first.deinit(gpa);
    try testing.expectEqual(null, first.firstError());
    try testing.expectEqualStrings(family, std.mem.span(first.config.font.faces.regular));
    var ctrl_equal_quits = false;
    for (first.config.keymap) |b| {
        if (b.key == .equal and b.mods.ctrl and !b.mods.shift) ctrl_equal_quits = b.action == .quit;
    }
    try testing.expect(ctrl_equal_quits);

    // Reload: the settings were removed from the file. Built from the base
    // again, the config is back to the defaults.
    var second = try Loaded.load(gpa, testing.io, &base, null, &.{.{
        .label = "config",
        .from = .{ .text = .{ .bytes = "", .dir = "/" } },
    }});
    defer second.deinit(gpa);
    try testing.expectEqualStrings("/base/regular.ttf", std.mem.span(second.config.font.faces.regular));
    try testing.expectEqual(base.keymap.ptr, second.config.keymap.ptr);
}

/// Maps `Config.Selection` into the renderer's `Selection.Option`.
fn rendererSelectionOption(sel: Config.Selection) renderer_mod.Selection.Option {
    var out: renderer_mod.Selection.Option = .default;
    out.fill_color[3] = sel.opacity;
    out.border_color = normalizedRgba(sel.border_color, sel.border_opacity);
    out.border_width = sel.border_width;
    out.border_style = sel.border_style;
    out.radius = sel.radius;
    out.blur_radius = sel.blur_radius;
    return out;
}

/// Maps `Config.Cursor` into the renderer's `Cursor.Option`.
pub fn rendererCursorOption(cur: Config.Cursor) renderer_mod.Cursor.Option {
    return .{
        .radius = cur.radius,
        .underline_frac = cur.underline_thickness,
        .bar_frac = cur.beam_thickness,
        .bar_offset_y = cur.underline_position,
        .alpha = cur.opacity,
        .hollow_border_width = cur.hollow_border_width,
    };
}

/// Maps `Config.Scrollbar` into the renderer's `Scrollbar.Option`.
fn rendererScrollbarOption(sb: Config.Scrollbar) renderer_mod.Scrollbar.Option {
    var out: renderer_mod.Scrollbar.Option = .default;
    out.width = sb.width;
    out.hover_width = sb.hover_width;
    out.gap = sb.gap;
    out.min_thumb_height = sb.min_thumb_height;
    out.radius = sb.radius;
    out.lerp_speed = sb.animation_speed;
    out.auto_hide = sb.auto_hide;
    out.auto_hide_alpha = sb.auto_hide_opacity;
    out.track_color = normalizedRgba(sb.track_color, sb.track_opacity);
    out.thumb_color = normalizedRgba(sb.thumb_color, sb.thumb_opacity);
    out.thumb_hover_color = normalizedRgba(sb.thumb_hover_color, sb.thumb_hover_opacity);
    return out;
}

pub fn kitOverlayOptions(ui: Config.Ui, win: Config.Window) KitOverlay.Options {
    return .{
        .ui = ui,
        .banner = .{
            .max_width = win.banner.max_width,
            .placement = win.banner.placement,
            .position = win.banner.position,
            .margin = win.banner.margin,
            .padding = win.banner.padding,
            .drop = win.banner.slide_distance,
        },
        .toast = .{
            .width = win.toast.width,
            .scale_step = win.toast.scale_step,
            .position = win.toast.position,
            .layout = win.toast.layout,
            .margin = win.toast.margin,
            .padding = win.toast.padding,
            .gap = win.toast.gap,
            .peek = win.toast.peek,
            .rise_distance = win.toast.rise_distance,
            .glide_ms = win.toast.glide_ms,
        },
        .dialog = .{
            .width = win.alert_dialog.width,
            .position = win.modal.position,
            .margin = win.modal.margin,
            .padding = win.modal.padding,
            .gap = win.modal.gap,
            .scrim_alpha = win.modal.backdropAlpha(),
            .media = alertDialogMedia(win.alert_dialog.icon),
        },
        .wellbeing_widget = win.wellbeing_widget.toKitOption(),
    };
}

fn alertDialogMedia(icon: @import("config/overlay.zig").AlertDialog.Icon) alert_dialog.Media {
    return switch (icon) {
        .warning => .warning,
        .info => .info,
        .@"error" => .err,
        .none => .none,
    };
}

/// Explicit pacing and mode state for the fullscreen wellbeing ASCII overlay.
pub const AsciiOverlayState = struct {
    time_ms: u64 = 0,
    frame_accum_ms: u32 = 0,
    /// Latched initial duration for the active non-locking reminder so the HUD
    /// progress bar advances smoothly as `remaining_s` counts down.
    alert_total_s: u32 = 0,
    drawn_last: bool = false,
    /// True once this window opened a non-locking reminder overlay while focused,
    /// keeping it visible if focus later moves to another window.
    reminder_active: bool = false,
    /// Lifecycle of the non-locking focus-break animation overlay across one break phase.
    break_overlay: BreakOverlay = .idle,
    last_focus_phase: wellbeing.focus.Phase = .idle,

    pub const BreakOverlay = enum(u8) {
        idle,
        active,
        dismissed,
    };

    pub const Mode = enum(u8) {
        none,
        card_lock,
        ascii_lock,
        ascii_reminder,

        pub fn showsAscii(self: Mode) bool {
            return self == .ascii_lock or self == .ascii_reminder;
        }

        pub fn showsLockSurface(self: Mode) bool {
            return self != .none;
        }
    };

    /// Tracks transitions into and out of focus breaks when `on_break` includes
    /// `animation` (without requiring `lock_input`).
    pub fn syncFocusPhase(
        self: *AsciiOverlayState,
        phase: wellbeing.focus.Phase,
        break_animation: bool,
        window_focused: bool,
    ) void {
        const in_break = phase == .short_break or phase == .long_break;
        if (!in_break or !break_animation) {
            self.break_overlay = .idle;
        } else if (phase != self.last_focus_phase or self.break_overlay == .idle) {
            self.break_overlay = if (window_focused) .active else .dismissed;
        }
        self.last_focus_phase = phase;
    }

    pub fn resolveMode(
        wellbeing_enabled: bool,
        input_locked: bool,
        lock_screen_enabled: bool,
        has_active_alert: bool,
        break_overlay_active: bool,
        window_focused: bool,
        reminder_active: bool,
        ascii: @import("config/overlay.zig").WellbeingAscii,
    ) Mode {
        if (input_locked and lock_screen_enabled) {
            return if (ascii.enabled) .ascii_lock else .card_lock;
        }
        if (wellbeing_enabled and ascii.enabled and ascii.trigger == .all) {
            if (break_overlay_active) return .ascii_reminder;
            if (has_active_alert and (window_focused or reminder_active)) return .ascii_reminder;
        }
        return .none;
    }

    pub fn frameIntervalMs(fps: u8) u32 {
        return @divTrunc(1000, @as(u32, @max(@as(u8, 1), fps)));
    }

    /// Advances the overlay clock by `dt_ms` and returns whether a redraw is due.
    pub fn tick(
        self: *AsciiOverlayState,
        dt_ms: u64,
        active: bool,
        visible: bool,
        motion_mode: kit_motion.Mode,
        fps: u8,
    ) bool {
        if (!active) {
            self.time_ms = 0;
            self.frame_accum_ms = 0;
            return self.drawn_last;
        }
        if (motion_mode == .none) {
            const changed = !self.drawn_last or self.time_ms != 0;
            self.time_ms = 0;
            self.frame_accum_ms = 0;
            return changed;
        }
        if (!visible) {
            self.frame_accum_ms = 0;
            return false;
        }
        const interval = frameIntervalMs(fps);
        self.time_ms +|= dt_ms;
        self.frame_accum_ms +|= @intCast(@min(dt_ms, std.math.maxInt(u32)));
        if (!self.drawn_last or self.frame_accum_ms >= interval) {
            self.frame_accum_ms %= interval;
            return true;
        }
        return false;
    }

    /// Milliseconds until the next animation frame, or null when idle,
    /// minimized, or frozen by reduced motion.
    pub fn wakeMs(
        self: *const AsciiOverlayState,
        active: bool,
        visible: bool,
        motion_mode: kit_motion.Mode,
        fps: u8,
    ) ?u64 {
        if (!active or !visible or motion_mode == .none) return null;
        const interval = frameIntervalMs(fps);
        const rem = interval -| self.frame_accum_ms;
        return @max(@as(u64, 1), rem);
    }

    pub fn timeSeconds(self: *const AsciiOverlayState) f32 {
        return @as(f32, @floatFromInt(self.time_ms)) / 1000.0;
    }
};

fn wellbeingOverlayMode(self: *const App) AsciiOverlayState.Mode {
    const wb = &self.wellbeing_state;
    const has_active_alert = wb.current_alert.kind != .none and wb.current_alert.remaining_s > 0;
    return AsciiOverlayState.resolveMode(
        wb.option.enabled,
        wb.input_locked,
        wb.option.lock_screen.enabled,
        has_active_alert,
        self.ascii_state.break_overlay == .active,
        self.window_focused,
        self.ascii_state.reminder_active,
        self.config.window.wellbeing_ascii,
    );
}

fn ensureAsciiOverlay(self: *App) ?*renderer_mod.AsciiOverlay {
    if (self.ascii_overlay) |ao| return ao;
    const ao = renderer_mod.AsciiOverlay.create(self.allocator) catch |err| {
        log.err("cannot create ASCII overlay renderer: {t}", .{err});
        return null;
    };
    self.ascii_overlay = ao;
    return ao;
}

fn asciiSource(self: *const App) kit_ascii_canvas.Source {
    if (self.config.window.wellbeing_ascii.scene == .file) {
        if (self.ascii_frames) |*frames| return .{ .frames = frames };
        return .{ .procedural = .spin_3d };
    }
    return .{ .procedural = self.config.window.wellbeing_ascii.scene.toProcedural() orelse .spin_3d };
}

fn wellbeingAccent(self: *const App, theme: *const kit_theme) kit_theme.Color {
    const wb = &self.wellbeing_state;
    if (wb.current_alert.kind == .screen_limit) return theme.destructive;
    if (wb.isFocusPausedByAlert()) return theme.warning;
    return theme.success;
}

fn wellbeingProgress(self: *const App) f32 {
    const wb = &self.wellbeing_state;
    if (wb.focus_state.phase == .short_break or wb.focus_state.phase == .long_break) {
        const total_ms: f32 = @floatFromInt(if (wb.focus_state.phase == .short_break)
            wb.focus_state.option.short_break_ms
        else
            wb.focus_state.option.long_break_ms);
        if (total_ms > 0) {
            return std.math.clamp(1.0 - (@as(f32, @floatFromInt(wb.focus_state.remaining_ms)) / total_ms), 0.0, 1.0);
        }
    }
    if (self.ascii_state.alert_total_s > 0 and wb.current_alert.remaining_s > 0) {
        return std.math.clamp(
            1.0 - (@as(f32, @floatFromInt(wb.current_alert.remaining_s)) / @as(f32, @floatFromInt(self.ascii_state.alert_total_s))),
            0.0,
            1.0,
        );
    }
    return 0.0;
}

fn loadAsciiFrames(gpa: std.mem.Allocator, io: std.Io, maybe_path: ?[*:0]const u8) ?kit_ascii_canvas.Frames {
    const path_z = maybe_path orelse return null;
    const path = std.mem.span(path_z);
    if (path.len == 0) return null;
    const bytes = std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        gpa,
        .limited(kit_ascii_canvas.Frames.max_file_bytes + 1),
    ) catch |err| {
        log.warn("cannot read ASCII animation file {s}: {t}; falling back to built-in scene", .{ path, err });
        return null;
    };
    defer gpa.free(bytes);
    return kit_ascii_canvas.Frames.parse(gpa, bytes) catch |err| {
        log.warn("invalid ASCII animation file {s}: {t}; falling back to built-in scene", .{ path, err });
        return null;
    };
}

fn normalizedRgba(rgb: rex.color.Rgb, alpha: f32) [4]f32 {
    return .{
        @as(f32, @floatFromInt(rgb.r)) / 255.0,
        @as(f32, @floatFromInt(rgb.g)) / 255.0,
        @as(f32, @floatFromInt(rgb.b)) / 255.0,
        alpha,
    };
}

test "rendererSelectionOption: maps Config.Selection onto renderer Selection.Option" {
    const testing = std.testing;
    const def = rendererSelectionOption(.default);
    try testing.expectEqual(renderer_mod.Selection.Option.default, def);

    const custom: Config.Selection = .{
        .classifier = .default,
        .opacity = 0.75,
        .border_color = .{ .r = 0xFF, .g = 0x80, .b = 0x00 },
        .border_opacity = 0.5,
        .border_width = 2.0,
        .border_style = .split,
        .radius = 6.0,
        .blur_radius = 12,
    };
    const mapped = rendererSelectionOption(custom);
    try testing.expectApproxEqAbs(@as(f32, 0.75), mapped.fill_color[3], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1.0), mapped.border_color[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 128.0 / 255.0), mapped.border_color[1], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.0), mapped.border_color[2], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.5), mapped.border_color[3], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 2.0), mapped.border_width, 1e-6);
    try testing.expectEqual(renderer_mod.Selection.BorderStyle.split, mapped.border_style);
    try testing.expectApproxEqAbs(@as(f32, 6.0), mapped.radius, 1e-6);
    try testing.expectEqual(@as(u8, 12), mapped.blur_radius);
}

test "rendererScrollbarOption: maps Config.Scrollbar onto renderer Scrollbar.Option" {
    const testing = std.testing;
    const def = rendererScrollbarOption(.default);
    try testing.expectEqual(renderer_mod.Scrollbar.Option.default, def);

    const custom: Config.Scrollbar = .{
        .width = 7.0,
        .hover_width = 11.0,
        .gap = 3.0,
        .min_thumb_height = 28.0,
        .radius = 6.0,
        .auto_hide = false,
        .auto_hide_opacity = 0.4,
        .track_color = .{ .r = 0x10, .g = 0x20, .b = 0x30 },
        .track_opacity = 0.3,
        .thumb_color = .{ .r = 0x40, .g = 0x50, .b = 0x60 },
        .thumb_opacity = 0.65,
        .thumb_hover_color = .{ .r = 0x80, .g = 0x90, .b = 0xA0 },
        .thumb_hover_opacity = 0.9,
    };
    const mapped = rendererScrollbarOption(custom);
    try testing.expectApproxEqAbs(@as(f32, 7.0), mapped.width, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 11.0), mapped.hover_width, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 3.0), mapped.gap, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 28.0), mapped.min_thumb_height, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 6.0), mapped.radius, 1e-6);
    try testing.expect(!mapped.auto_hide);
    try testing.expectApproxEqAbs(@as(f32, 0.4), mapped.auto_hide_alpha, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 16.0 / 255.0), mapped.track_color[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.3), mapped.track_color[3], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 64.0 / 255.0), mapped.thumb_color[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.65), mapped.thumb_color[3], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 128.0 / 255.0), mapped.thumb_hover_color[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.9), mapped.thumb_hover_color[3], 1e-6);
}

test "normalizedRgba: scales 0..255 Rgb channels into 0..1 GL floats" {
    const testing = std.testing;
    const mocha_bg: rex.color.Rgb = .{ .r = 0x1E, .g = 0x1E, .b = 0x2E };
    const rgba = normalizedRgba(mocha_bg, 0.85);
    try testing.expectApproxEqAbs(@as(f32, 30.0 / 255.0), rgba[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 30.0 / 255.0), rgba[1], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 46.0 / 255.0), rgba[2], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.85), rgba[3], 1e-6);
}

test "kitOverlayOptions: maps overlay config sections onto KitOverlay options" {
    const testing = std.testing;
    var win: Config.Window = .default;
    win.banner.placement = .docked;
    win.banner.position = .bottom_left;
    win.banner.max_width = 700;
    win.banner.margin = 12;
    win.banner.padding = 18;
    win.toast.position = .top_center;
    win.toast.layout = .expanded;
    win.toast.width = 410;
    win.toast.margin = 20;
    win.toast.padding = 12;
    win.toast.gap = 8;
    win.toast.peek = 16;
    win.toast.scale_step = 0.08;
    win.modal.position = .top_center;
    win.modal.margin = 28;
    win.modal.padding = 18;
    win.modal.gap = 10;
    win.modal.backdrop_opacity = 0.5;
    win.alert_dialog.width = 512;

    const opts = kitOverlayOptions(.{}, win);
    try testing.expectEqual(kit_alert.Placement.docked, opts.banner.placement);
    try testing.expectEqual(kit_alert.Position.bottom_left, opts.banner.position);
    try testing.expectApproxEqAbs(@as(f32, 700), opts.banner.max_width, 1e-6);
    try testing.expectEqual(@as(u8, 12), opts.banner.margin);
    try testing.expectEqual(@as(u8, 18), opts.banner.padding);

    try testing.expectEqual(kit_toast.Position.top_center, opts.toast.position);
    try testing.expectEqual(kit_toast.Layout.expanded, opts.toast.layout);
    try testing.expectApproxEqAbs(@as(f32, 410), opts.toast.width, 1e-6);
    try testing.expectEqual(@as(u8, 20), opts.toast.margin);
    try testing.expectEqual(@as(u8, 12), opts.toast.padding);
    try testing.expectEqual(@as(u8, 8), opts.toast.gap);
    try testing.expectEqual(@as(u8, 16), opts.toast.peek);
    try testing.expectApproxEqAbs(@as(f32, 0.08), opts.toast.scale_step, 1e-6);

    try testing.expectEqual(@import("kit/dialog.zig").Position.top_center, opts.dialog.position);
    try testing.expectApproxEqAbs(@as(f32, 512), opts.dialog.width, 1e-6);
    try testing.expectEqual(@as(u8, 28), opts.dialog.margin);
    try testing.expectEqual(@as(u8, 18), opts.dialog.padding);
    try testing.expectEqual(@as(u8, 10), opts.dialog.gap);
    try testing.expectEqual(@as(?u8, 128), opts.dialog.scrim_alpha);
}

test "focus gating: unfocused window skips toasts and defers banners until focused" {
    const testing = std.testing;
    try readyTestGlContext();
    const kit = try KitOverlay.create(testing.allocator, .{
        .regular = "assets/fonts/Inter-Regular.ttf",
        .medium = "assets/fonts/Inter-Medium.ttf",
        .semibold = "assets/fonts/Inter-SemiBold.ttf",
    }, 1);
    defer kit.destroy(testing.allocator);

    const toast_cfg: @import("config/overlay.zig").Toast = .{};
    // Unfocused: toast is dropped; banner is deferred rather than shown immediately.
    try testing.expect(!pushFocusedToast(kit, false, toast_cfg, "Configuration", "Configuration reloaded", .info));
    try testing.expectEqual(@as(usize, 0), kit.toasts.len);

    var pending: ?PendingAlert = null;
    try testing.expect(!pushOrDeferBanner(kit, false, true, &pending, .err, "Config error", "bad key"));
    try testing.expect(!kit.alertShown());
    try testing.expect(pending != null);

    // Gaining focus surfaces the deferred banner once and clears `pending`.
    try testing.expect(flushDeferredBanner(kit, true, true, &pending));
    try testing.expect(kit.alertShown());
    try testing.expectEqual(@as(?PendingAlert, null), pending);
    try testing.expect(!flushDeferredBanner(kit, true, true, &pending));

    // While focused, both toasts and banners show immediately.
    try testing.expect(pushFocusedToast(kit, true, toast_cfg, "Configuration", "Configuration reloaded", .info));
    try testing.expectEqual(@as(usize, 1), kit.toasts.len);

    // Disabling banners clears any deferred banner.
    try testing.expect(!pushOrDeferBanner(kit, false, true, &pending, .warn, "Config warning", "deprecated"));
    try testing.expect(pending != null);
    try testing.expect(!pushOrDeferBanner(kit, false, false, &pending, .warn, "Config warning", "deprecated"));
    try testing.expectEqual(@as(?PendingAlert, null), pending);
}
