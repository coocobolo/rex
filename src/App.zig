const App = @This();

const std = @import("std");
const root = @import("root");
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

const unicode = rex.unicode;

const renderer_mod = rex.renderer;
const Atlas = renderer_mod.Atlas;
const gl = renderer_mod.gl;
const Window = renderer_mod.Window;
const c = @import("glfw");

const Background = renderer_mod.Background;
const Cursor = renderer_mod.Cursor;
const Scrollbar = renderer_mod.Scrollbar;
const SelectionState = renderer_mod.Selection.State;

const Renderer = renderer_mod.Renderer;
const Dimension = renderer_mod.Dimension;
const FrameBuilder = renderer_mod.Frame.Builder;
const ui_mod = rex.ui;
const Modal = ui_mod.Modal;
const Toast = ui_mod.Toast;
const Icon = ui_mod.Icon;
const Button = ui_mod.Button;
const FocusGroup = ui_mod.FocusGroup;
const Table = ui_mod.Table;
const Action = ui_mod.Action;
const Tag = ui_mod.Tag;
const Text = ui_mod.Text;
const Drawer = ui_mod.Drawer;
const Banner = ui_mod.Banner;

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

/// Largest selection copied to the clipboard, in bytes.
const max_copy_size: usize = std.math.maxInt(u16) - 1;

const Config = rex.config.Config;
const Loaded = rex.config.Loaded;
const diagnostics = rex.config.diagnostics;

/// Terminal limits the screen, frame and renderer types are built
/// with: the root rex_terminal_option when declared, else the defaults.
pub const terminal_option: TerminalOption = if (@hasDecl(root, "rex_terminal_option"))
    root.rex_terminal_option
else
    Config.default_terminal;

/// Whether two terminal options are the same, comparing strings by
/// content.
fn sameTerminalOption(a: TerminalOption, b: TerminalOption) bool {
    return a.max_rows == b.max_rows and
        a.max_cols == b.max_cols and
        a.tab_width == b.tab_width and
        a.max_scrollback == b.max_scrollback and
        a.ambiguous_width == b.ambiguous_width and
        std.mem.eql(u8, a.name, b.name) and
        std.mem.eql(u8, a.version, b.version) and
        a.max_clipboard_bytes == b.max_clipboard_bytes;
}

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
local_clock: wellbeing.localtime.Clock = .{},
wellbeing_overlay: wellbeing.overlay.Overlay = .{},
toast_queue: Toast.Queue = .{},
config_banner: ?Banner = null,

window: Window,

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

// Selection state
selection: rex.Selection = .empty,

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
quit_confirm_open: bool = false,
quit_confirmed: bool = false,
quit_modal_focus: FocusGroup = FocusGroup.init(2, 0),
hotspots: Table = .{},
skip_next_char: bool = false,

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
/// Main-thread copy of an OSC 52 write, with room for the NUL GLFW needs.
/// Owned; freed in `deinit`.
clipboard_buf: *[terminal_option.max_clipboard_bytes + 1]u8,

// Environment data
dirs: rex.dirs.Application,
/// How rex was started, for when /proc/self/exe cannot be read.
argv0: []const u8,

/// Counts whole `period_ms` periods as time passes. A period of 0
/// disables the timer: it never fires and sets no deadline.
const PeriodicTimer = struct {
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
};

/// Picks the moment to draw so `swapBuffers` blocks for about `margin_ns`
/// instead of a whole refresh. `next_vblank_ns == 0` means the next vblank
/// is not known: startup, an idle gap, or a swap that did not wait.
const FrameLatch = struct {
    /// Nanoseconds between refreshes. Starts at the monitor's rate (`init`)
    /// and follows the gap between swaps that actually waited.
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

        if (self.last_vblank_ns != 0 and swap_return_ns > self.last_vblank_ns) {
            self.samplePeriod(swap_return_ns - self.last_vblank_ns);
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

    /// Folds the gap between two waited swaps into `period_ns`. Half to one
    /// and a half periods is one refresh and refines the average. Anything
    /// else between 2 and 50 ms is a missed vblank, a stall, or a wrong
    /// period: it becomes the period only when the next such gap agrees
    /// within 10%.
    fn samplePeriod(self: *FrameLatch, gap: u64) void {
        if (gap >= self.period_ns / 2 and gap <= self.period_ns + self.period_ns / 2) {
            self.period_ns = (self.period_ns *| 7 +| gap) / 8;
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
    gpa: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ,
    argv0: []const u8,
    config: *const Config,
    custom_config_path: ?[]const u8,
) !App {
    if (!sameTerminalOption(config.terminal, terminal_option)) {
        return error.TerminalOptionMismatch;
    }

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
    var pty = spawnShell(gpa, io, active_config.termio, active_config.shell, login_shell, block.slice, &failure) catch |err| switch (err) {
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
            startup_banner = Banner.init(.err, "Shell error", message);
            break :blk try spawnShell(gpa, io, active_config.termio, .{}, login_shell, block.slice, &failure);
        },
        else => return err,
    };
    errdefer pty.close(io);

    log.debug("termio.pty: {f}", .{pty});

    const platform = Window.choosePlatform(active_config.window.platform, wayland_session);
    log.debug("platform: {f}, forced: {}", .{ platform, platform.forced });

    var win: Window = try .init(.{
        .width = active_config.window.size.width,
        .height = active_config.window.size.height,
        .title = active_config.window.title orelse Config.Window.default_title,
        .platform = platform,
    });
    errdefer win.deinit();

    // The font is rasterized at the display's scale; the config's size is
    // in logical pixels.
    const content_scale = win.getWindowContentScale().width;
    const font_pixels: Freetype.FontConfig = .{
        .faces = active_config.font.faces,
        .height = Freetype.FontConfig.pixelSize(active_config.font.size, content_scale),
    };
    log.info("display scale {d:.2}, font {d} px for size {d}", .{
        content_scale,
        font_pixels.height,
        active_config.font.size,
    });
    var rasterizer: Rasterizer = try .create(gpa, font_pixels);
    errdefer rasterizer.destroy(gpa);

    var atlas: Atlas = try .create(gpa, active_config.window.atlas);
    errdefer atlas.destroy();

    var frame_builder: FrameBuilderType = try .init(gpa, .{
        .dim_alpha = active_config.window.dim_alpha,
        .decoration = active_config.window.decoration,
    });
    errdefer frame_builder.deinit(gpa);

    atlas.preRasterize(gpa, &rasterizer, .{ .start = 0x20, .end = 0x7F });

    var renderer = try RendererType.init(.{
        .background = active_config.window.background,
        .font_metrics = rasterizer.metrics,
        .cursor = active_config.window.cursor,
        .decoration = active_config.window.decoration,
        .scrollbar = active_config.window.scrollbar,
        .selection = active_config.window.selection,
    });
    errdefer renderer.deinit();

    var wellbeing_state = wellbeing.Wellbeing.init(active_config.wellbeing);
    const open_ms: i64 = @intCast(std.Io.Clock.Timestamp.now(io, .real).raw.toMilliseconds());
    wellbeing_state.open(io, dirs.state, open_ms) catch |err| {
        log.warn("cannot read wellbeing state in {s}: {t}; starting empty", .{ wellbeing_state.stateDir(dirs.state), err });
    };

    // Created before the driver, which writes to it, and destroyed after it.
    const latency: latency_trace.Handle = if (latency_trace.enabled) try latency_trace.Trace.create(gpa) else {};
    errdefer if (latency_trace.enabled) latency.?.destroy(gpa);
    const latency_path = if (latency_trace.enabled) environ.getAlloc(gpa, "REX_LATENCY_TRACE") catch |err| switch (err) {
        error.EnvironmentVariableMissing => try std.fmt.allocPrint(gpa, "{s}/latency-{d}.csv", .{ dirs.state, std.c.getpid() }),
        else => |e| return e,
    } else {};
    errdefer if (latency_trace.enabled) gpa.free(latency_path);
    if (latency_trace.enabled) {
        if (active_config.threading.mode == .single) log.warn("latency trace: the single-threaded driver isn't traced", .{});
        log.info("latency trace: writing to {s} on exit", .{latency_path});
    }

    // XTGETTCAP reports the TERM the shell got, config override included.
    const term_name: TermName = TermName.init(envmap.get("TERM") orelse "") catch blk: {
        log.warn("TERM is longer than {d} bytes; XTGETTCAP will not report it", .{rex.terminal.term.max_term_name_len});
        break :blk .empty;
    };
    const driver_options: rex.driver.Options = .{
        .theme = active_config.theme,
        .sync_output_timeout_ms = active_config.threading.sync_output_timeout_ms,
        .term_name = term_name,
    };
    var driver: Driver = switch (active_config.threading.mode) {
        .single => .{ .single = try SingleDriverType.init(gpa, io, pty, driver_options) },
        .multi => .{ .threaded = try ThreadedDriverType.create(gpa, io, pty, driver_options, latency) },
    };
    errdefer driver.deinit();

    const clipboard_buf = try gpa.create([terminal_option.max_clipboard_bytes + 1]u8);
    errdefer gpa.destroy(clipboard_buf);

    driver.setWakeupFn(Window.glfwPostEmptyEvent);

    const background_color = active_config.theme.background;
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

    const app = App{
        .io = io,
        .driver = driver,
        .latency = latency,
        .latency_path = latency_path,
        .window = win,
        .frame_latch = .init(Window.primaryRefreshHz()),
        .background_color = .{ background_color.r, background_color.g, background_color.b, background_alpha },
        .blink = .{ .period_ms = active_config.blink.half_period_ms },
        .blink_rapid = .{ .period_ms = active_config.blink.rapid_half_period_ms },
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
        // Its options and tokens come with every `build`.
        .wellbeing_overlay = .{},
        .toast_queue = .{},
        .config_banner = startup_banner,
        .frame_buffer_size = .empty,
        .clipboard_buf = clipboard_buf,
        .last_frame = now,
        .word_classifier = classifier,
    };

    return app;
}

pub fn deinit(self: *App, gpa: std.mem.Allocator) void {
    if (self.config_watcher) |*w| w.deinit();
    gpa.free(self.config_path);
    gpa.free(self.home_dir);

    self.renderer.deinit();
    self.frame_builder.deinit(gpa);
    self.atlas.destroy();
    self.rasterizer.destroy(gpa);
    self.window.deinit();
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
    self.wellbeing_overlay.deinit(gpa);

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
    // initialize glfw window size and pty window size
    {
        const frame_buffer_size = self.window.frameBufferSize(u16);
        self.handleResize(frame_buffer_size);
    }

    // Register current window callbacks
    self.window.setWindowUserPointer(self);
    self.window.setCharCallback(charCb);
    self.window.setCursorPosCallback(cursorPosCb);
    self.window.setFramebufferSizeCallback(framebufferSizeCb);
    self.window.setKeyCallback(keyCb);
    self.window.setMouseButtonCallback(mouseButtonCb);
    self.window.setScrollCallback(scrollCb);
    self.window.setWindowFocusCallback(windowFocusCb);
    // A window can open unfocused and then never get a focus event. Both
    // flags start true, so that window would count screen time and fire
    // reminders. Assigning the flag skips `windowFocusChanged`, which would
    // count the open itself as activity.
    const focused_now = self.window.focused();
    self.window_focused = focused_now;
    self.wellbeing_state.window_focused = focused_now;
    self.window.setWindowCloseCallback(windowCloseCb);
    self.window.setWindowContentScaleCallback(contentScaleCb);

    start: while (true) {
        if (self.window.windowShouldClose()) {
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
        self.renderer.grayscale = wb_res.grayscale;
        self.renderer.color_tint = wb_res.tint;
        if (wb_res.needs_redraw) {
            self.frame_builder.last_generation = null;
            self.needs_redraw = true;
        }
        self.syncWellbeing(@intCast(now_real.raw.toSeconds()));
        if (wb_res.phase_changed or wb_res.alert != null) self.ringBell();

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
            self.handleResize(self.window.frameBufferSize(u16));
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

        if (self.toast_queue.tick(dt_clamped)) self.needs_redraw = true;
        if (self.renderer.tick(dt_clamped)) self.needs_redraw = true;

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
            if (try self.renderFrame()) self.needs_redraw = false;
        }

        self.waitForNextEvent(had_data);
        if (latency_trace.enabled) self.latency.?.eventsHandled();
        self.flushScroll();
    }
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

    var frame = try self.frame_builder.build(
        self.allocator,
        current_frame,
        atlas,
        &self.rasterizer,
        self.blink_on,
        selection_state,
        null,
    );

    const total_cols = current_frame.active_cols;
    const total_rows = current_frame.active_rows;

    self.hotspots.clear();

    const tokens = rex.color.Tokens.fromThemeWithOverride(self.config.theme, self.config.tokens);

    if (self.quit_confirm_open) {
        self.wellbeing_overlay.bg_buffer.clearRetainingCapacity();
        self.wellbeing_overlay.card_buffer.clearRetainingCapacity();
        self.wellbeing_overlay.gray_buffer.clearRetainingCapacity();
        self.wellbeing_overlay.color_buffer.clearRetainingCapacity();
        self.wellbeing_overlay.toast_active = false;
        self.wellbeing_overlay.lock_screen_active = false;
        self.wellbeing_overlay.last_toast_layout = null;

        const drawer: Drawer = .{
            .allocator = self.allocator,
            .atlas = atlas,
            .rasterizer = &self.rasterizer,
            .gray_buffer = &self.wellbeing_overlay.gray_buffer,
            .color_buffer = &self.wellbeing_overlay.color_buffer,
        };
        var actions: [2]Modal.Action = undefined;
        _ = Modal.render(
            quitConfirmModalRequest(
                self.config.window.surfaceFor(.modal),
                self.config.window.modal,
                self.config.window.quit_dialog,
                &actions,
            ),
            tokens,
            total_cols,
            total_rows,
            &self.wellbeing_overlay.bg_buffer,
            &self.wellbeing_overlay.card_buffer,
            drawer,
            &self.quit_modal_focus,
            &self.hotspots,
        );
    } else {
        self.wellbeing_overlay.build(
            self.allocator,
            atlas,
            &self.rasterizer,
            &self.wellbeing_state,
            tokens,
            overlaySurfaces(&self.config.window),
            self.config.window.toast,
            self.config.window.icon,
            self.config.window.modal,
            total_cols,
            total_rows,
            &self.hotspots,
        );

        if (self.config.window.toast.enabled and self.toast_queue.isActive()) {
            const drawer: Drawer = .{
                .allocator = self.allocator,
                .atlas = atlas,
                .rasterizer = &self.rasterizer,
                .gray_buffer = &self.wellbeing_overlay.gray_buffer,
                .color_buffer = &self.wellbeing_overlay.color_buffer,
            };
            self.toast_queue.build(
                tokens,
                total_cols,
                total_rows,
                self.wellbeing_overlay.toastRowOffset(),
                &self.wellbeing_overlay.card_buffer,
                drawer,
                &self.hotspots,
            );
        }
    }

    if (self.config_banner) |*b| {
        if (self.config.window.banner.enabled) {
            const drawer: Drawer = .{
                .allocator = self.allocator,
                .atlas = atlas,
                .rasterizer = &self.rasterizer,
                .gray_buffer = &self.wellbeing_overlay.gray_buffer,
                .color_buffer = &self.wellbeing_overlay.color_buffer,
            };
            _ = b.render(
                tokens,
                total_cols,
                total_rows,
                self.config.window.banner,
                self.config.window.surfaceFor(.banner),
                &self.wellbeing_overlay.card_buffer,
                drawer,
                &self.hotspots,
            );
        }
    }

    const banner_active = self.config_banner != null and self.config.window.banner.enabled;
    const app_toasts_active = !self.quit_confirm_open and self.config.window.toast.enabled and self.toast_queue.isActive();
    const overlay_active = self.quit_confirm_open or self.wellbeing_overlay.isActive() or app_toasts_active or banner_active;
    const overlay_changed = overlay_active or self.wellbeing_overlay.was_active;
    self.wellbeing_overlay.was_active = overlay_active;

    if (overlay_active) {
        frame.overlay_background_instances = self.wellbeing_overlay.bg_buffer.items;
        frame.overlay_card_instances = self.wellbeing_overlay.card_buffer.items;
        frame.overlay_gray_instances = self.wellbeing_overlay.gray_buffer.items;
        frame.overlay_color_instances = self.wellbeing_overlay.color_buffer.items;
        const has_modal = self.quit_confirm_open or self.wellbeing_overlay.dashboard_open;
        frame.overlay_has_modal = has_modal;
        frame.modal_blur = self.config.window.modal.blur;
        frame.modal_blur_radius = self.config.window.modal.blur_radius;
        frame.modal_dim_alpha = self.config.window.modal.backdropAlpha();
        frame.dirty.overlay = true;
    } else if (overlay_changed) {
        frame.dirty.overlay = true;
    }

    if (!frame.dirty.any()) {
        self.frame_latch.used_prediction = false;
        return false;
    }

    if (latency_trace.enabled) self.latency.?.frameBuilt(latency_trace.now(self.io));

    const dimension = self.window.frameBufferSize(f32);
    self.renderer.draw(
        frame,
        atlas,
        dimension,
        self.background_color,
        self.window_focused,
        if (selection_state) |state| state.bg else null,
        .{ .blink_on = self.blink_on, .blink_rapid_on = self.blink_rapid_on },
    );

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

/// Sleeps until this frame's draw should start. The long gap is one sleep:
/// `glfwWaitEventsTimeout` returns on the worker's empty event and was
/// ending the wait early. The last 1.5 ms is polled in short slices so a
/// key and its character are delivered while the echo can still publish.
fn waitUntilFrame(self: *App) void {
    self.frame_latch.used_prediction = self.frame_latch.pending(awakeNs(self.io));
    Window.glfwPollEvents();
    while (true) {
        const sleep = self.frame_latch.sleepNs(awakeNs(self.io));
        if (sleep == 0) break;
        const slice: i96 = @intCast(if (sleep > 1_500_000) sleep - 1_500_000 else @min(sleep, 250_000));
        std.Io.sleep(self.io, .fromNanoseconds(slice), .awake) catch |err| switch (err) {
            // The Io is shutting down: stop waiting and draw now.
            error.Canceled => break,
        };
        Window.glfwPollEvents();
    }
}

/// Polls when pty data arrived or a new frame is ready, else sleeps until the next blink or
/// focus tick or an input event (capped to 8ms if a redraw is pending).
fn waitForNextEvent(self: *App, had_data: bool) void {
    if (had_data or self.driver.hasNewFrame()) {
        Window.glfwPollEvents();
        return;
    }

    const alert = self.wellbeing_state.current_alert;
    const animating = alert.kind != .none and alert.remaining_s > 0 and alert.show_animation and alert.animation != .none;
    const overlay_active = self.wellbeing_overlay.isActive();

    var ms = @min(
        self.blink.remaining(),
        @min(
            self.blink_rapid.remaining(),
            @min(
                @min(self.wellbeing_state.focus_state.msUntilTick(), self.toast_queue.msUntilNextTick()),
                self.wellbeing_state.msUntilSync(self.wallMs()),
            ),
        ),
    );
    if (animating) ms = @min(ms, 33);
    if (overlay_active) ms = @min(ms, 250);
    if (self.needs_redraw) ms = @min(ms, 8);

    Window.glfwWaitEventsTimeout(@max(0.001, @as(f64, @floatFromInt(ms)) / 1000.0));
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

    const foreground = blk: {
        if (frame.selection_foreground) |fg| break :blk fg;
        if (is_primary) break :blk self.config.theme.selection_foreground.toArray();
        break :blk null;
    };

    const background = blk: {
        if (frame.selection_background) |bg| break :blk bg;
        if (is_primary) break :blk self.config.theme.selection_background.toArray();
        break :blk null;
    };

    return .{
        .active = true,
        .start_row = start_row,
        .start_col = start_col,
        .end_row = end_row,
        .end_col = end_col,
        .bg = background,
        .fg = foreground,
        .kind = self.selection.kind,
    };
}

fn updateWindowTitle(self: *App) void {
    var buf: [rex.terminal.max_title_len:0]u8 = undefined;
    self.window.setWindowTitle(windowTitle(self.config.window.title, self.driver.copyTitle(&buf)));
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

pub fn handleResize(self: *App, dimension: Dimension(u16)) void {
    const frame_buffer_width = dimension.width;
    const frame_buffer_height = dimension.height;

    if (std.meta.eql(self.frame_buffer_size, dimension)) return;

    self.frame_buffer_size = dimension;

    const cell_width = self.rasterizer.cell_width;
    const cell_height = self.rasterizer.cell_height;
    if (cell_width == 0 or cell_height == 0) return;

    const new_rows: u16 = @min(frame_buffer_height / cell_height, terminal_option.max_rows);
    const new_cols: u16 = @min(frame_buffer_width / cell_width, terminal_option.max_cols);
    if (new_rows == 0 or new_cols == 0) return;

    self.driver.sendInput(.{
        .resize = .{
            .rows = new_rows,
            .cols = new_cols,
            .pixel_width = frame_buffer_width,
            .pixel_height = frame_buffer_height,
        },
    }) catch |err| {
        log.err("handleResize: driver sendInput failed: {}", .{err});
    };

    log.debug("fb={}x{} cell={}x{} grid={}cols {}rows (unused: {}px right, {}px bottom)", .{
        frame_buffer_width,                           frame_buffer_height,
        cell_width,                                   cell_height,
        new_cols,                                     new_rows,
        frame_buffer_width -| new_cols *| cell_width, frame_buffer_height -| new_rows *| cell_height,
    });

    gl.viewport(0, 0, @intCast(frame_buffer_width), @intCast(frame_buffer_height));

    self.selection = .empty; // clear selection on resize
    self.needs_redraw = true;
}

fn pasteFromClipboard(self: *App) void {
    const raw = c.glfwGetClipboardString(self.window.handle) orelse return;
    const text: []const u8 = std.mem.span(raw);

    self.selection = .empty;
    self.driver.writePaste(text) catch |err| {
        log.err("pasteFromClipboard: writePaste failed: {}", .{err});
    };
    self.snapToLiveView();
}

/// Pushes a structured toast notification into the application toast queue.
pub fn notifyToast(self: *App, req: Toast.Request) u64 {
    if (!self.config.window.toast.enabled) return 0;
    const id = self.toast_queue.push(req, self.config.window.toast.duration_ms);
    self.needs_redraw = true;
    return id;
}

/// Polls the shared wellbeing state (at most once a second, see
/// `Wellbeing.sync`). A failure is reported when it starts or changes, not
/// on every retry, and the return to working is reported too.
fn syncWellbeing(self: *App, utc_s: i64) void {
    if (self.wellbeing_state.sync(self.io, self.dirs.state, utc_s, .poll)) |_| {
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
    self.notifySimple(title, desc, .critical);
}

/// Pushes a concise toast notification with the configured toast surface, toast and icon options.
pub fn notifySimple(self: *App, title: []const u8, description: []const u8, variant: Toast.Variant) void {
    if (!self.config.window.toast.enabled) return;
    const icon_id: Icon.IconId = switch (variant) {
        .neutral, .info => .info,
        .success => .success,
        .warning => .warning,
        .critical => .error_icon,
    };
    const icon_str = Icon.getGlyphWithOption(icon_id, self.config.window.icon);
    const icon_style = Icon.resolveStyle(self.config.window.icon.style);
    const dismiss_str = self.config.window.toast.dismiss_str orelse (if (icon_style == .ascii) "x" else "✕");
    const toast_surface = self.config.window.surfaceFor(.toast);
    _ = self.notifyToast(.{
        .title = title,
        .description = description,
        .icon = if (icon_str.len > 0) icon_str else null,
        .dismiss_str = dismiss_str,
        .action_prompt = self.config.window.toast.action_prompt,
        .variant = variant,
        .position = self.config.window.toast.position,
        .border_style = toast_surface.border_style,
        .corner_radius = toast_surface.effectiveRadius(),
        .border_width = toast_surface.border_width,
        .min_cols = self.config.window.toast.min_cols,
        .max_cols = self.config.window.toast.max_cols,
        .margin_cols = self.config.window.toast.margin_cols,
        .margin_rows = self.config.window.toast.margin_rows,
        .icon_style = self.config.window.icon.style,
    });
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
    // Create new rasterizer BEFORE destroying old one (avoid dangling ptr on failure)
    const new_rasterizer = Rasterizer.create(self.allocator, font_config) catch |err| {
        log.err("rebuildFont: rasterizer.create failed: {}", .{err});
        return false;
    };
    self.rasterizer.destroy(self.allocator);
    self.rasterizer = new_rasterizer;
    self.renderer.setFontMetrics(self.rasterizer.metrics);

    // Invalidate atlas, all cached glyphs are wrong size now
    self.atlas.invalidate();

    // Invalidate frame builder cached generation
    self.frame_builder.last_generation = null;

    self.font_size = size;
    self.content_scale = scale;
    self.needs_redraw = true;

    // Reset cached fb size to force handleResize to recompute rows/cols
    self.frame_buffer_size = .empty;

    const fb = self.window.frameBufferSize(u16);
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
        self.config_banner = Banner.init(.err, "Config error", err_msg);
        self.frame_builder.last_generation = null;
        self.needs_redraw = true;
        return;
    };

    defer loaded.deinit(self.allocator);
    logConfigDiagnostics(self.allocator, &loaded);

    if (!loaded.found()) {
        self.notifySimple("Configuration", "No config file found", .neutral);
        return;
    }

    // A running session keeps its config when a file has errors (decision
    // P4); a config with only warnings applies, and the banner shows the
    // first warning. Without either, the banner goes.
    self.config_banner = configBanner(&loaded);
    if (loaded.firstError() != null) {
        self.frame_builder.last_generation = null;
        self.needs_redraw = true;
        return;
    }
    useBuiltinFonts(self.io, loaded.arena.allocator(), &loaded, self.argv0) catch |err| switch (err) {
        error.OutOfMemory => {
            self.config_banner = Banner.init(.err, "Config error", "Out of memory");
            self.frame_builder.last_generation = null;
            self.needs_redraw = true;
            return;
        },
        error.BadExePath => {
            self.config_banner = Banner.init(.err, "Config error", "font.file is not set, and the executable path is not usable");
            self.frame_builder.last_generation = null;
            self.needs_redraw = true;
            return;
        },
        error.BuiltinFontMissing => {
            var buf: [128]u8 = undefined;
            const face = missingBuiltinFace(self.io, loaded.arena.allocator(), self.argv0);
            log.err("no font: set `file` in [font]; missing {s}", .{face});
            const name = std.fs.path.basename(face);
            const msg = std.fmt.bufPrint(&buf, "{s} is missing; set `file` in [font]", .{name}) catch "the built-in face is missing; set `file` in [font]";
            self.config_banner = Banner.init(.err, "Config error", msg);
            self.frame_builder.last_generation = null;
            self.needs_redraw = true;
            return;
        },
    };
    if (!hasFontFile(loaded.config.font)) {
        self.config_banner = Banner.init(.err, "Config error", "font.file is not set");
        self.frame_builder.last_generation = null;
        self.needs_redraw = true;
        return;
    }
    const new_config = loaded.config;
    const faces_changed = !self.config.font.faces.eql(new_config.font.faces);

    if (new_config.window.platform != self.config.window.platform) {
        log.info("window.platform takes effect on the next start", .{});
    }

    // Freeing the old arena leaves the rasterizer with a dangling font path:
    // FreeType keeps the path pointer in its stream (src/base/ftsystem.c:252)
    // but never reads it after opening the file, so this is safe. A new
    // rasterizer (font size change below) gets the new path.
    self.config_arena.deinit();
    self.config_arena = loaded.takeArena();
    self.config = new_config;

    // Live update renderer background color, alpha, and terminal theme
    const bg = self.config.theme.background;
    self.background_color = .{ bg.r, bg.g, bg.b, self.config.window.background.alpha };
    self.renderer.background.option.alpha = self.config.window.background.alpha;
    self.driver.setTheme(self.config.theme);
    self.updateWindowTitle();
    self.frame_builder.last_generation = null;

    self.frame_builder.dim_alpha = renderer_mod.Frame.alphaByte(self.config.window.dim_alpha);

    // A size change rebuilds the rasterizer with the new faces; a face
    // change at the same size needs its own rebuild.
    const size_before = self.font_size;
    if (self.config.font.size != self.font_size) {
        self.setFontSize(self.config.font.size);
    }
    if (faces_changed and self.font_size == size_before and !self.rebuildFont(self.font_size, self.content_scale)) {
        self.config_banner = Banner.init(.err, "Config error", "the new font could not be loaded; the previous one stays");
    }

    self.wellbeing_state.applyOption(self.config.wellbeing);
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
        },
        .focus_reset => {
            self.wellbeing_state.resetFocus(self.wallMs());
        },
        .focus_skip => {
            self.wellbeing_state.skipFocus(self.wallMs());
            self.ringBell();
        },
        .focus_toggle_phase_end => {
            self.wellbeing_state.toggleFocusPhaseEnd();
        },
        .wellbeing_dashboard => {
            if (self.wellbeing_state.option.dashboard.modal_enabled) {
                self.wellbeing_overlay.dashboard_open = !self.wellbeing_overlay.dashboard_open;
                self.needs_redraw = true;
            } else {
                var card_buf: [2048]u8 = undefined;
                const card = self.wellbeing_state.renderDashboard(&card_buf);
                if (card.len < card_buf.len) {
                    card_buf[card.len] = 0;
                    c.glfwSetClipboardString(self.window.handle, card_buf[0..card.len :0].ptr);
                }
                self.wellbeing_state.current_alert = .{
                    .kind = .healthy_break,
                    .prompt = "Wellbeing dashboard copied to clipboard.",
                    .remaining_s = 10,
                };
            }
        },
        .wellbeing_clear => {
            if (self.purgeWellbeingHistory()) {
                self.wellbeing_state.current_alert = .{
                    .kind = .healthy_break,
                    .prompt = "Wellbeing history cleared.",
                    .remaining_s = 10,
                };
            }
        },
        .wellbeing_dismiss => {
            self.wellbeing_state.dismissAlert();
            self.wellbeing_overlay.dashboard_open = false;
            self.quit_confirm_open = false;
            self.toast_queue.dismissAll();
            self.frame_builder.last_generation = null;
            self.needs_redraw = true;
        },
        .toast_dismiss => {
            if (self.toast_queue.isActive()) {
                _ = self.toast_queue.dismiss(self.toast_queue.entries[0].id);
                self.needs_redraw = true;
            } else if (self.wellbeing_state.current_alert.kind != .none) {
                self.wellbeing_state.dismissAlert();
                self.needs_redraw = true;
            }
        },
        .toast_activate => {
            if (self.toast_queue.isActive()) {
                const id = self.toast_queue.entries[0].id;
                _ = self.toast_queue.dismiss(id);
                self.needs_redraw = true;
            } else if (self.wellbeing_state.current_alert.kind != .none) {
                self.wellbeing_state.skipFocus(self.wallMs());
                self.ringBell();
                self.needs_redraw = true;
            }
        },
        .reload_config => self.reloadConfig(),
        .send_to_pty => |seq| {
            self.driver.sendBytes(seq) catch |err| {
                log.err("handleAction: send to pty write failed: {}", .{err});
            };
        },
    }
}

/// Starts another rex as a separate process in the shell's working
/// directory. The new window does not depend on this one: it has its
/// own process group and null stdio, and outlives this process. A
/// failure is logged and this window carries on.
fn openNewWindow(self: *App) void {
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    // Linux reads /proc/self/exe here, which works whatever PATH and
    // the working directory have become since rex started.
    const exe: []const u8 = if (std.process.executablePath(self.io, &exe_buf)) |len|
        exe_buf[0..len]
    else |err| blk: {
        log.warn("new window: executable path unavailable ({}), using argv[0]", .{err});
        break :blk self.argv0;
    };

    // chdir follows the /proc/<pid>/cwd link to wherever the shell is.
    var cwd_buf: [32]u8 = undefined;
    const pid = self.driver.getPid();
    const shell_cwd: ?[]const u8 = if (pid > 0)
        std.fmt.bufPrint(&cwd_buf, "/proc/{d}/cwd", .{pid}) catch null
    else
        null;

    const child = spawnWindow(self.io, exe, if (shell_cwd) |path| .{ .path = path } else .inherit) catch |err| retry: {
        if (shell_cwd == null) break :retry err;
        log.warn("new window: cannot start in the shell's directory ({}), retrying here", .{err});
        break :retry spawnWindow(self.io, exe, .inherit);
    } catch |err| {
        log.err("new window: cannot start {s}: {}", .{ exe, err });
        return;
    };

    const child_pid = child.id orelse return;
    reapInBackground(child_pid) catch |err| {
        log.warn("new window: no reaper thread ({}); pid {d} stays a zombie until rex exits", .{ err, child_pid });
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

fn spawnWindow(io: std.Io, exe: []const u8, cwd: std.process.Child.Cwd) std.process.SpawnError!std.process.Child {
    return std.process.spawn(io, .{
        .argv = &.{exe},
        .cwd = cwd,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        // Its own process group, so a hangup or Ctrl+C aimed at this
        // rex's group does not reach the new window.
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
    termio: rex.termio.pty.SpawnOption,
    shell: Config.Shell,
    login_shell: [:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
    failure: *?rex.termio.pty.SpawnFailure,
) !Pty {
    const argv = try gpa.allocSentinel(?[*:0]const u8, 1 + shell.arguments.len, null);
    defer gpa.free(argv);
    argv[0] = shell.program orelse login_shell;
    for (shell.arguments, argv[1..]) |argument, *slot| slot.* = argument;

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

/// The shipped regular face this process would load, or its file name when
/// the executable path cannot be resolved.
fn missingBuiltinFace(io: std.Io, allocator: std.mem.Allocator, argv0: []const u8) []const u8 {
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe: []const u8 = if (std.process.executablePath(io, &exe_buf)) |len|
        exe_buf[0..len]
    else |_|
        argv0;
    return rex.config.builtin_font.regularPath(allocator, exe) catch rex.config.builtin_font.regular_name;
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

/// The banner for the first error of `loaded`, else its first warning.
fn configBanner(loaded: *const Loaded) ?Banner {
    if (loaded.firstError()) |problem| switch (problem) {
        .unreadable => |u| {
            var buf: [128]u8 = undefined;
            const name = std.fs.path.basename(u.layer.source.label);
            const message = std.fmt.bufPrint(&buf, "cannot read {s}: {s}", .{ name, @errorName(u.err) }) catch "cannot read a config file";
            return Banner.init(.err, "Config error", message);
        },
        .syntax => |e| return diagnosticBanner(&e.layer.state.loaded, .{ .syntax = e.err }),
    };
    if (loaded.firstWarning()) |w| return diagnosticBanner(&w.layer.state.loaded, .{ .sema = w.err });
    return null;
}

fn diagnosticBanner(file: *const diagnostics.File, d: diagnostics.Diagnostic) Banner {
    const level: Banner.Level, const prefix: []const u8 = switch (d.severity()) {
        .err => .{ .err, "Config error" },
        .warn => .{ .warn, "Config warning" },
    };
    const loc = file.tree.tokenLocation(d.token());
    var title_buf: [64]u8 = undefined;
    const title = std.fmt.bufPrint(&title_buf, "{s} (line {d}, col {d})", .{ prefix, loc.line + 1, loc.column + 1 }) catch prefix;
    // Banner.init copies both strings. A message longer than its buffer is
    // cut here; the log has it in full.
    var message_buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&message_buf);
    diagnostics.renderMessage(file, d, &w) catch {};
    return Banner.init(level, title, w.buffered());
}

/// The resolved looks of the surfaces the wellbeing overlay draws.
fn overlaySurfaces(window: *const Config.Window) wellbeing.overlay.Surfaces {
    return .{
        .card = window.surfaceFor(.card),
        .toast = window.surfaceFor(.toast),
        .modal = window.surfaceFor(.modal),
    };
}

fn quitConfirmModalRequest(surface: Config.Surface, modal_opt: Modal.Option, quit_opt: Config.QuitDialog, actions: *[2]Modal.Action) Modal.Request {
    actions.* = .{
        .{ .shortcut = "Enter / Y", .label = quit_opt.confirm_label },
        .{ .shortcut = "Esc / N", .label = quit_opt.cancel_label },
    };
    return .{
        .title = quit_opt.title,
        .line1 = quit_opt.line1,
        .line2 = quit_opt.line2,
        .actions = actions,
        .variant = .warning,
        .border_style = surface.border_style,
        .dim_alpha = modal_opt.backdropAlpha(),
        .cols = modal_opt.cols,
        .icon_style = modal_opt.icon_style,
        .corner_radius = surface.effectiveRadius(),
        .border_width = surface.border_width,
    };
}

/// Requests closing the terminal window, opening the quit confirmation modal
/// when `on_close` asks for it.
pub fn requestQuit(self: *App) void {
    const ask = switch (self.config.window.on_close) {
        .ask => true,
        .ask_if_running => self.programRunning(),
        .close => false,
    };
    if (!ask or self.quit_confirm_open) {
        self.confirmQuit();
        return;
    }
    self.window.setWindowShouldClose(false);
    const initial_idx: u8 = switch (self.config.window.modal.default_focus) {
        .confirm => 0,
        .cancel => 1,
    };
    self.quit_modal_focus = FocusGroup.init(2, initial_idx);
    self.quit_confirm_open = true;
    self.frame_builder.last_generation = null;
    self.needs_redraw = true;
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
    self.quit_confirm_open = false;
    self.window.setWindowShouldClose(true);
}

/// Routes physical key events to active UI modals, overlays, and application keybindings.
/// Returns true when the event was consumed by the UI layer, signaling the input callback
/// to bypass terminal key encoding and suppress trailing text input callbacks.
fn routeKeyToUi(self: *App, maybe_key: ?rex.input.Key, mods: rex.input.Modifiers) bool {
    const k = maybe_key orelse return false;

    if (self.config_banner != null and k == .escape) {
        self.config_banner = null;
        self.frame_builder.last_generation = null;
        self.needs_redraw = true;
        return true;
    }

    if (self.quit_confirm_open) {
        self.handleQuitModalKey(k, mods);
        return true;
    }

    if (self.wellbeing_overlay.dashboard_open) {
        self.handleDashboardKey(k);
        return true;
    }

    if (self.wellbeing_state.input_locked) {
        return true;
    }

    if (rex.input.matchBinding(self.config.keymap, k, mods)) |act| {
        self.handleAction(act);
        return true;
    }

    return false;
}

fn handleQuitModalKey(self: *App, k: rex.input.Key, mods: rex.input.Modifiers) void {
    switch (k) {
        .tab => {
            if (mods.shift) {
                self.quit_modal_focus.previous();
            } else {
                self.quit_modal_focus.next();
            }
            self.frame_builder.last_generation = null;
            self.needs_redraw = true;
        },
        .left, .up => {
            self.quit_modal_focus.previous();
            self.frame_builder.last_generation = null;
            self.needs_redraw = true;
        },
        .right, .down => {
            self.quit_modal_focus.next();
            self.frame_builder.last_generation = null;
            self.needs_redraw = true;
        },
        .enter, .kp_enter, .space => {
            if (self.quit_modal_focus.isFocused(0)) {
                self.confirmQuit();
            } else {
                self.quit_confirm_open = false;
                self.frame_builder.last_generation = null;
                self.needs_redraw = true;
            }
        },
        .y, .q => {
            self.confirmQuit();
        },
        .escape, .n, .backspace => {
            self.quit_confirm_open = false;
            self.frame_builder.last_generation = null;
            self.needs_redraw = true;
        },
        else => {},
    }
}

fn handleDashboardKey(self: *App, k: rex.input.Key) void {
    switch (k) {
        .escape, .q => {
            self.wellbeing_overlay.dashboard_open = false;
            self.frame_builder.last_generation = null;
            self.needs_redraw = true;
        },
        .tab => {
            self.wellbeing_overlay.nextTab();
            self.frame_builder.last_generation = null;
            self.needs_redraw = true;
        },
        .num_1, .kp_1 => {
            self.wellbeing_overlay.selectTab(0);
            self.frame_builder.last_generation = null;
            self.needs_redraw = true;
        },
        .num_2, .kp_2 => {
            self.wellbeing_overlay.selectTab(1);
            self.frame_builder.last_generation = null;
            self.needs_redraw = true;
        },
        .num_3, .kp_3 => {
            self.wellbeing_overlay.selectTab(2);
            self.frame_builder.last_generation = null;
            self.needs_redraw = true;
        },
        .left, .h => {
            if (self.wellbeing_overlay.active_tab == .activity) {
                self.wellbeing_overlay.moveSelectedDay(-1, self.wellbeing_state.data.history_count);
                self.frame_builder.last_generation = null;
                self.needs_redraw = true;
            }
        },
        .right, .l => {
            if (self.wellbeing_overlay.active_tab == .activity) {
                self.wellbeing_overlay.moveSelectedDay(1, self.wellbeing_state.data.history_count);
                self.frame_builder.last_generation = null;
                self.needs_redraw = true;
            }
        },
        .c => {
            var card_buf: [2048]u8 = undefined;
            const card = self.wellbeing_state.renderDashboard(&card_buf);
            if (card.len < card_buf.len) {
                card_buf[card.len] = 0;
                c.glfwSetClipboardString(self.window.handle, card_buf[0..card.len :0].ptr);
            }
            self.wellbeing_state.current_alert = .{
                .kind = .healthy_break,
                .prompt = "Dashboard card copied to clipboard.",
                .remaining_s = 5,
            };
            self.frame_builder.last_generation = null;
            self.needs_redraw = true;
        },
        .r => {
            if (self.wellbeing_overlay.active_tab == .pomodoro) {
                self.wellbeing_state.resetFocus(self.wallMs());
            } else {
                _ = self.purgeWellbeingHistory();
            }
            self.frame_builder.last_generation = null;
            self.needs_redraw = true;
        },
        .p => {
            self.wellbeing_state.toggleFocus(self.wallMs());
            self.frame_builder.last_generation = null;
            self.needs_redraw = true;
        },
        .s => {
            self.wellbeing_state.skipFocus(self.wallMs());
            self.frame_builder.last_generation = null;
            self.needs_redraw = true;
        },
        else => {},
    }
}

const charCb: c.GLFWcharfun = struct {
    fn cb(window: ?*c.GLFWwindow, codepoint: c_uint) callconv(.c) void {
        const app: *App = @ptrCast(@alignCast(c.glfwGetWindowUserPointer(window) orelse return));
        if (app.skip_next_char) {
            app.skip_next_char = false;
            return;
        }
        if (app.quit_confirm_open or app.wellbeing_overlay.dashboard_open or app.wellbeing_state.input_locked) return;
        app.wellbeing_state.recordActivity();
        app.selection = .empty;
        app.needs_redraw = true;

        // GLFW passes a u32; anything that is not a code point is dropped.
        const cp = std.math.cast(u21, codepoint) orelse return;
        if (cp == 0) return;

        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cp, &buf) catch return;
        if (len > 0) {
            const seq = if (latency_trace.enabled) app.latencyBeginSend() else {};
            app.driver.sendBytes(buf[0..len]) catch |err| {
                log.err("charCallback: driver sendBytes failed: {}", .{err});
                return;
            };
            if (latency_trace.enabled) app.latencyQueued(seq);
            app.snapToLiveView();
        }
    }
}.cb;

const keyCb: c.GLFWkeyfun = struct {
    fn cb(window: ?*c.GLFWwindow, key: c_int, _: c_int, action: c_int, mods: c_int) callconv(.c) void {
        const app: *App = @ptrCast(@alignCast(c.glfwGetWindowUserPointer(window) orelse return));
        if (action == c.GLFW_RELEASE) return;
        const pressed_at = if (latency_trace.enabled) latency_trace.now(app.io) else {};
        app.wellbeing_state.recordActivity();

        const maybe_key = rex.renderer.glfw_key.key(key);
        const key_mods = rex.renderer.glfw_key.modifiers(mods);

        if (app.routeKeyToUi(maybe_key, key_mods)) {
            app.skip_next_char = true;
            return;
        }
        app.skip_next_char = false;

        // A bare modifier keeps the selection, since it may start a
        // combination such as Ctrl+Shift+C.
        if (maybe_key == null or !maybe_key.?.isModifier()) {
            app.selection = .empty;
            app.needs_redraw = true;
            // Its bytes may come from here or from the char callback.
            if (latency_trace.enabled) app.latency.?.keyPressed(pressed_at);
        }

        // Terminal key encoding
        const driver_modes = app.driver.getModes();
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
            app.skip_next_char = true;
            const seq = if (latency_trace.enabled) app.latencyBeginSend() else {};
            app.driver.sendBytes(bytes) catch |err| {
                log.err("keyCallback: driver sendBytes failed: {}", .{err});
                return;
            };
            if (latency_trace.enabled) app.latencyQueued(seq);
            app.snapToLiveView();
        }
    }
}.cb;

fn mouseCellPos(self: *App, xpos: f32, ypos: f32) struct { u16, u16 } {
    const cw, const ch = .{ self.rasterizer.cell_width, self.rasterizer.cell_height };
    const col: u16 = @intCast(@min(@as(u32, @intFromFloat(@max(0, xpos))) / cw, terminal_option.max_cols - 1));
    const row: u16 = @intCast(@min(@as(u32, @intFromFloat(@max(0, ypos))) / ch, terminal_option.max_rows - 1));
    return .{ col, row };
}

/// What App does with an OSC 52 request (ADR 0006).
const ClipboardAction = union(enum) {
    ignore,
    /// Set these selections to the write's data.
    set: rex.terminal.term.Clipboard.Targets,
    /// Reply with the content of the first of these selections that has
    /// text: CLIPBOARD, then PRIMARY.
    reply_selection: rex.terminal.term.Clipboard.Targets,
    /// Reply with no data, so a waiting program (Neovim waits up to 10 s)
    /// doesn't hang on a refused read.
    reply_empty,
};

fn clipboardAction(policy: Config.Clipboard, request: rex.driver.ClipboardRequest) ClipboardAction {
    return switch (request) {
        .write => |w| if (policy.osc52_write == .allow) .{ .set = w.targets } else .ignore,
        .read => |r| if (policy.osc52_read == .allow) .{ .reply_selection = r.targets } else .reply_empty,
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
    const request = self.driver.takeClipboard(self.clipboard_buf[0..terminal_option.max_clipboard_bytes]) orelse return;
    serveClipboard(self.allocator, self.config.clipboard, request, &self.window, &self.driver, self.clipboard_buf);
}

/// Applies or answers one OSC 52 request (ADR 0006). A write's data lives in
/// `buf`, which has room for the NUL GLFW needs. Main thread only.
fn serveClipboard(
    gpa: std.mem.Allocator,
    policy: Config.Clipboard,
    request: rex.driver.ClipboardRequest,
    window: *Window,
    driver: *Driver,
    buf: *[terminal_option.max_clipboard_bytes + 1]u8,
) void {
    switch (clipboardAction(policy, request)) {
        .ignore => log.debug("OSC 52: ignored {t}", .{request}),
        .set => |targets| {
            const data = request.write.data;
            // GLFW takes a NUL-terminated string: refuse rather than cut.
            if (std.mem.indexOfScalar(u8, data, 0) != null) {
                log.warn("OSC 52: ignored a {d}-byte write that contains a NUL byte", .{data.len});
                return;
            }
            buf[data.len] = 0;
            const text = buf[0..data.len :0];
            if (targets.clipboard) window.setClipboard(text);
            if (targets.primary) _ = window.setPrimarySelection(text);
        },
        .reply_selection => |targets| {
            const format = request.read.control_format;
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
        },
        .reply_empty => {
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
    buf[len] = 0; // null-terminate for GLFW
    c.glfwSetClipboardString(self.window.handle, buf[0..len :0].ptr);
}

/// The report number of a GLFW button, or null for buttons past the
/// first three. GLFW numbers right before middle; xterm the reverse.
fn mouseButtonOf(glfw_button: c_int) ?MouseButton {
    return switch (glfw_button) {
        c.GLFW_MOUSE_BUTTON_LEFT => .left,
        c.GLFW_MOUSE_BUTTON_MIDDLE => .middle,
        c.GLFW_MOUSE_BUTTON_RIGHT => .right,
        else => null,
    };
}

fn trackMouseButton(self: *App, button: c_int, press: bool) void {
    const held = mouseButtonOf(button) orelse return;
    if (press) self.mouse_held.press(held) else self.mouse_held.release(held);
}

fn vtModByte(mods: c_int) u8 {
    var m: u8 = 0;
    if (mods & c.GLFW_MOD_SHIFT != 0) m |= 4;
    if (mods & c.GLFW_MOD_ALT != 0) m |= 8;
    if (mods & c.GLFW_MOD_CONTROL != 0) m |= 16;
    return m;
}

fn detectMouseClickKind(self: *App, anchor: i32, col: u16, mods: c_int, scroll_gen: i64, scrollback_used: i64) rex.Selection.Kind {
    const now_ms = Window.glfwGetTime() * 1000.0;

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
    return if (mods & c.GLFW_MOD_ALT != 0) .block else kind;
}

fn handleSelectionPress(self: *App, row: u16, col: u16, mods: c_int) void {
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

fn reportMouseButton(self: *App, col: u16, row: u16, button: c_int, mod_byte: u8, press: bool) void {
    const held = mouseButtonOf(button) orelse return;
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

const mouseButtonCb: c.GLFWmousebuttonfun = struct {
    fn cb(handle: ?*c.GLFWwindow, button: c_int, action: c_int, mods: c_int) callconv(.c) void {
        const app: *App = @ptrCast(@alignCast(c.glfwGetWindowUserPointer(handle) orelse return));
        app.wellbeing_state.recordActivity();
        const press = (action == c.GLFW_PRESS);

        app.trackMouseButton(button, press);
        const mod_byte = vtModByte(mods);
        const shift_held = (mods & c.GLFW_MOD_SHIFT) != 0;

        const col, const row = app.mouseCellPos(app.mouse_x, app.mouse_y);
        const driver_modes = app.driver.getModes();
        const mouse_reporting = driver_modes.mouse_reporting;
        const frame = app.driver.getFrame();
        const scrollback_used = frame.scrollback_used;

        if (button == c.GLFW_MOUSE_BUTTON_LEFT) {
            if (press) {
                if (app.handleOverlayClick(col, row)) return;
                if (scrollback_used > 0 and app.handleScrollbarClick()) return;
            } else {
                if (app.handleScrollbarRelease()) return;
            }
        }

        const is_primary = !frame.is_alternate;
        // log.debug("mouse_reporting={} shift_held={} is_primary={}", .{ mouse_reporting, shift_held, is_primary });
        if (is_primary and (!mouse_reporting or shift_held)) {
            if (press and button == c.GLFW_MOUSE_BUTTON_LEFT) {
                app.handleSelectionPress(row, col, mods);
            } else if (!press) {
                app.handleSelectionRelease();
            }
        }

        if (mouse_reporting and !shift_held) {
            app.reportMouseButton(col, row, button, mod_byte, press);
        }
    }
}.cb;

fn handleOverlayClick(self: *App, col: u16, row: u16) bool {
    if (self.hotspots.hitTest(col, row)) |action| {
        switch (action) {
            .modal_action => |idx| if (idx == 0) self.confirmQuit() else {
                self.quit_confirm_open = false;
                self.frame_builder.last_generation = null;
                self.needs_redraw = true;
            },
            .modal_dismiss => {
                self.quit_confirm_open = false;
                self.frame_builder.last_generation = null;
                self.needs_redraw = true;
            },
            .toast_dismiss, .toast_action => |id| {
                _ = self.toast_queue.dismiss(id);
                self.needs_redraw = true;
            },
            .banner_dismiss => {
                self.config_banner = null;
                self.frame_builder.last_generation = null;
                self.needs_redraw = true;
                return true;
            },
            .tab_select => |idx| {
                self.wellbeing_overlay.selectTab(idx);
                self.frame_builder.last_generation = null;
                self.needs_redraw = true;
            },
            .chart_select => |idx| {
                self.wellbeing_overlay.selected_day_idx = idx;
                self.frame_builder.last_generation = null;
                self.needs_redraw = true;
            },
            .button => |id| {
                if (std.enums.fromInt(wellbeing.overlay.ButtonId, id)) |btn_id| {
                    switch (btn_id) {
                        .close => {
                            if (self.wellbeing_overlay.dashboard_open) {
                                self.wellbeing_overlay.dashboard_open = false;
                            } else if (self.wellbeing_overlay.toast_active) {
                                self.wellbeing_state.dismissAlert();
                                self.wellbeing_overlay.toast_active = false;
                            }
                            self.frame_builder.last_generation = null;
                            self.needs_redraw = true;
                        },
                        .toggle_focus => {
                            self.wellbeing_state.toggleFocus(self.wallMs());
                            self.frame_builder.last_generation = null;
                            self.needs_redraw = true;
                        },
                        .skip_focus => {
                            self.wellbeing_state.skipFocus(self.wallMs());
                            self.frame_builder.last_generation = null;
                            self.needs_redraw = true;
                        },
                        .reset_focus => {
                            self.wellbeing_state.resetFocus(self.wallMs());
                            self.frame_builder.last_generation = null;
                            self.needs_redraw = true;
                        },
                        .purge_history => {
                            _ = self.purgeWellbeingHistory();
                            self.frame_builder.last_generation = null;
                            self.needs_redraw = true;
                        },
                        .copy_card => {
                            var card_buf: [2048]u8 = undefined;
                            const card = self.wellbeing_state.renderDashboard(&card_buf);
                            if (card.len < card_buf.len) {
                                card_buf[card.len] = 0;
                                c.glfwSetClipboardString(self.window.handle, card_buf[0..card.len :0].ptr);
                            }
                            self.wellbeing_state.current_alert = .{
                                .kind = .healthy_break,
                                .prompt = "Dashboard card copied to clipboard.",
                                .remaining_s = 5,
                            };
                            self.frame_builder.last_generation = null;
                            self.needs_redraw = true;
                        },
                    }
                }
            },
            .none => {},
        }
        return true;
    }

    if (self.quit_confirm_open) {
        const current_frame = self.driver.getFrame();
        var actions: [2]Modal.Action = undefined;
        if (Modal.hitTest(
            quitConfirmModalRequest(self.config.window.surfaceFor(.modal), self.config.window.modal, self.config.window.quit_dialog, &actions),
            current_frame.active_cols,
            current_frame.active_rows,
            col,
            row,
        )) |hit| {
            if (hit == .outside and self.config.window.modal.on_outside_click == .close) {
                self.quit_confirm_open = false;
                self.frame_builder.last_generation = null;
                self.needs_redraw = true;
            }
        }
        return true;
    }

    if (self.wellbeing_overlay.dashboard_open) {
        if (self.wellbeing_overlay.card_buffer.items.len > 0) {
            const c_item = self.wellbeing_overlay.card_buffer.items[0];
            if (col < c_item.col or col >= c_item.col + c_item.width or
                row < c_item.row or row >= c_item.row + c_item.height)
            {
                if (self.config.window.modal.on_outside_click == .close) {
                    self.wellbeing_overlay.dashboard_open = false;
                    self.frame_builder.last_generation = null;
                    self.needs_redraw = true;
                }
            }
        }
        return true;
    }

    if (self.wellbeing_overlay.lock_screen_active) {
        return true;
    }

    if (self.config.window.toast.enabled and self.toast_queue.isActive()) {
        const current_frame = self.driver.getFrame();
        if (self.toast_queue.hitTest(
            col,
            row,
            current_frame.active_cols,
            current_frame.active_rows,
            self.wellbeing_overlay.toastRowOffset(),
        )) |hit| {
            switch (hit.part) {
                .dismiss, .action => {
                    _ = self.toast_queue.dismiss(hit.id);
                    self.needs_redraw = true;
                },
                .body => {},
            }
            return true;
        }
    }

    return false;
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
    const option = self.config.window.scrollbar;
    const effective_width = if (self.renderer.scrollbar.hover) option.hover_width else option.width;

    const bar_x: f32 = frame_width - effective_width - option.gap;
    if (mouse_x < bar_x) return false;

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
    return .of(frame_height, fracs.top, fracs.height, self.config.window.scrollbar.min_thumb_height);
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
        if (frame.scrollback_used == 0 or frame.is_alternate) break :blk false;
        const fb_w: f32 = @floatFromInt(self.frame_buffer_size.width);
        const bar_x = fb_w - sb.option.hover_width - sb.option.gap;
        break :blk self.mouse_x >= bar_x;
    };

    if (new_hover == sb.hover) return;
    sb.hover = new_hover;
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

const scrollCb: c.GLFWscrollfun = struct {
    fn cb(handle: ?*c.GLFWwindow, _: f64, y_offset: f64) callconv(.c) void {
        const app: *App = @ptrCast(@alignCast(c.glfwGetWindowUserPointer(handle) orelse return));
        app.wellbeing_state.recordActivity();

        // Clear sub-line fractional remainder on scroll direction reversal to eliminate hysteresis
        if ((app.scroll_accumulator_y > 0 and y_offset < 0) or (app.scroll_accumulator_y < 0 and y_offset > 0)) {
            app.scroll_accumulator_y = 0;
        }

        const modes = app.driver.getModes();
        const multiplier: f64 = if (modes.reports_wheel)
            1.0
        else
            @as(f64, @floatFromInt(app.config.scroll.wheel_lines));

        app.scroll_accumulator_y += y_offset * multiplier;
        app.flushScroll();
    }
}.cb;

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

const cursorPosCb: c.GLFWcursorposfun = struct {
    fn cb(handle: ?*c.GLFWwindow, xpos: f64, ypos: f64) callconv(.c) void {
        const app: *App = @ptrCast(@alignCast(c.glfwGetWindowUserPointer(handle) orelse return));

        app.mouse_x = @floatCast(xpos);
        app.mouse_y = @floatCast(ypos);

        // update scrollbar hover detection
        app.updateScrollbarHover();

        // Scrollbar drag
        if (app.handleScrollbarDrag()) return;

        const col, const row = app.mouseCellPos(app.mouse_x, app.mouse_y);

        const driver_modes = app.driver.getModes();
        const mouse_reporting = driver_modes.mouse_reporting;

        // A shift-drag selects text even while the host tracks the mouse.
        if (mouse_reporting and app.selection.phase != .dragging) {
            if (driver_modes.reports_motion) {
                app.sendMouseMotion(col, row);
            }
            return;
        }

        const left_held = app.mouse_held.isHeld(.left);

        if (left_held and app.selection.phase == .dragging) {
            const frame = app.driver.getFrame();
            if (frame.is_alternate) return;

            const viewport_offset = @as(i32, @intCast(frame.viewport_offset));
            const anchor: i32 = @as(i32, row) - viewport_offset;
            const scroll_gen = frame.total_lines_scrolled;
            const scrollback_used = @as(i64, @intCast(frame.scrollback_used));

            switch (app.selection.kind) {
                .character, .block => {
                    _ = app.selection.range.set(.end, .{ .row = anchor, .col = col, .captured_scroll_gen = scroll_gen });
                },
                .word => {
                    const join_option = app.word_classifier.option.join;
                    // Union the drag-point's word bounds with the ORIGINAL click's word
                    // bounds, extending outward from the click, not re-snapping independently.
                    const left, const right = frame.wordsBoundsAt(&app.word_classifier, row, col, join_option);

                    const click_anchor = resolveAnchor(
                        app.mouse_last_click_pos,
                        scroll_gen,
                        scrollback_used,
                    ) orelse return; // click row evicted from scrollback, bail, don't extend a dead selection
                    const click_col = app.mouse_last_click_pos.col;
                    const click_row_i = click_anchor + @as(i64, @intCast(frame.viewport_offset));
                    const click_row: usize = if (click_row_i >= 0 and click_row_i < frame.active_rows)
                        @intCast(click_row_i)
                    else
                        @intCast(row);
                    const click_left, const click_right = frame.wordsBoundsAt(&app.word_classifier, click_row, click_col, join_option);

                    if (@as(i64, anchor) < click_anchor or (anchor == click_anchor and col < click_col)) {
                        // dragging backward: end snaps to the far-left word boundary,
                        // start stays pinned to the click's right boundary
                        app.selection.range.start.set(@intCast(click_anchor), click_right, scroll_gen);
                        app.selection.range.end.set(anchor, left, scroll_gen);
                    } else {
                        app.selection.range.start.set(@intCast(click_anchor), click_left, scroll_gen);
                        app.selection.range.end.set(anchor, right, scroll_gen);
                    }
                },
                .line => {
                    const last_col = frame.active_cols - 1;
                    const click_anchor = resolveAnchor(
                        app.mouse_last_click_pos,
                        scroll_gen,
                        scrollback_used,
                    ) orelse return; // click row evicted from scrollback, bail, don't extend a dead selection
                    if (@as(i64, anchor) < click_anchor) {
                        app.selection.range.start.set(@intCast(click_anchor), last_col, scroll_gen);
                        app.selection.range.end.set(anchor, 0, scroll_gen);
                    } else {
                        app.selection.range.start.set(@intCast(click_anchor), 0, scroll_gen);
                        app.selection.range.end.set(anchor, last_col, scroll_gen);
                    }
                },
            }

            app.needs_redraw = true;
        }
    }
}.cb;

const windowFocusCb: c.GLFWwindowfocusfun = struct {
    fn cb(handle: ?*c.GLFWwindow, focused: c_int) callconv(.c) void {
        const app: *App = @ptrCast(@alignCast(c.glfwGetWindowUserPointer(handle) orelse return));
        const is_focused = (focused != 0);
        app.window_focused = is_focused;
        app.wellbeing_state.windowFocusChanged(is_focused);
        const modes = app.driver.getModes();
        if (!modes.focus_events) return;
        app.driver.sendInput(.{ .focus = is_focused }) catch |err| {
            log.err("windowFocusCallback: sendInput failed: {}", .{err});
        };
    }
}.cb;

const framebufferSizeCb: c.GLFWframebuffersizefun = struct {
    fn cb(handle: ?*c.GLFWwindow, w: c_int, h: c_int) callconv(.c) void {
        const app: *App = @ptrCast(@alignCast(c.glfwGetWindowUserPointer(handle) orelse return));
        // GLFW reports a scale change just before the framebuffer size it
        // causes (wl_window.c, fractionalScaleHandlePreferredScale). Applying
        // the scale first resizes the grid once, with the new font; otherwise
        // the pty sees an extra resize computed with the old cell size.
        if (app.content_scale_pending) |scale| {
            app.content_scale_pending = null;
            app.applyContentScale(scale);
        }
        // A no-op when applyContentScale already resized to this size.
        app.handleResize(.{ .height = @intCast(h), .width = @intCast(w) });
    }
}.cb;

const contentScaleCb: c.GLFWwindowcontentscalefun = struct {
    fn cb(handle: ?*c.GLFWwindow, xscale: f32, yscale: f32) callconv(.c) void {
        _ = yscale; // GLFW reports one scale per axis; Rex uses the horizontal one
        const app: *App = @ptrCast(@alignCast(c.glfwGetWindowUserPointer(handle) orelse return));
        app.content_scale_pending = xscale;
    }
}.cb;

const windowCloseCb: c.GLFWwindowclosefun = struct {
    fn cb(handle: ?*c.GLFWwindow) callconv(.c) void {
        const app: *App = @ptrCast(@alignCast(c.glfwGetWindowUserPointer(handle) orelse return));
        app.requestQuit();
    }
}.cb;

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
    try std.testing.expectEqual(ClipboardAction{ .set = .{ .clipboard = true } }, clipboardAction(allow_all, write));
    try std.testing.expectEqual(ClipboardAction{ .set = .{ .primary = true } }, clipboardAction(allow_all, primary));
    try std.testing.expectEqual(ClipboardAction{ .set = .{ .clipboard = true, .primary = true } }, clipboardAction(allow_all, both));
    try std.testing.expectEqual(ClipboardAction.ignore, clipboardAction(deny_all, write));
    try std.testing.expectEqual(ClipboardAction{ .reply_selection = .{ .clipboard = true } }, clipboardAction(allow_all, read));
    try std.testing.expectEqual(ClipboardAction.reply_empty, clipboardAction(deny_all, read));
    try std.testing.expectEqual(ClipboardAction.reply_empty, clipboardAction(.{}, read)); // the default
}

test "writeReadReply: exact bytes in 7-bit and 8-bit form, empty and not" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("\x1b]52;c;aGVsbG8=\x1b\\", writeReadReply(buf[0..readReplyLen(.s7c1t, 5)], .s7c1t, 'c', "hello"));
    try std.testing.expectEqualStrings("\x9d52;p;aGk=\x9c", writeReadReply(buf[0..readReplyLen(.s8c1t, 2)], .s8c1t, 'p', "hi"));
    try std.testing.expectEqualStrings("\x1b]52;c;\x1b\\", writeReadReply(buf[0..readReplyLen(.s7c1t, 0)], .s7c1t, 'c', ""));
}

/// A single driver on a socket pair and the test's hidden GLFW window, for
/// OSC 52 round trips through `serveClipboard`. `child` is the program's
/// end of the pty.
const ClipboardRig = struct {
    driver: Driver,
    child: posix.fd_t,
    window: Window,
    buf: *[terminal_option.max_clipboard_bytes + 1]u8,

    fn init() !ClipboardRig {
        try Window.testGlContext();
        var sv: [2]posix.fd_t = undefined;
        if (system.socketpair(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.NONBLOCK, 0, &sv) != 0) return error.SocketPair;
        errdefer _ = system.close(sv[1]);
        const pty: rex.termio.pty.Posix = .{ .master = sv[0], .pid = -1, .stdout_read_fd = -1, .error_read_fd = -1 };
        var driver: Driver = .{ .single = try SingleDriverType.init(std.testing.allocator, std.testing.io, pty, .{ .theme = .graphite, .sync_output_timeout_ms = 150 }) };
        errdefer driver.deinit();
        return .{
            .driver = driver,
            .child = sv[1],
            .window = .{ .handle = c.glfwGetCurrentContext().? },
            .buf = try std.testing.allocator.create([terminal_option.max_clipboard_bytes + 1]u8),
        };
    }

    fn deinit(self: *ClipboardRig) void {
        std.testing.allocator.destroy(self.buf);
        self.driver.deinit();
        _ = system.close(self.child);
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
    var rig = try ClipboardRig.init();
    defer rig.deinit();
    if (c.glfwGetPlatform() != c.GLFW_PLATFORM_X11) return error.SkipZigTest;
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
    var rig = try ClipboardRig.init();
    defer rig.deinit();
    if (c.glfwGetPlatform() != c.GLFW_PLATFORM_X11) return error.SkipZigTest;
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
    try testing.expectEqual(@as(c_int, 0), system.socketpair(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.NONBLOCK, 0, &sv_single));
    defer _ = system.close(sv_single[1]);
    const pty_single = rex.termio.pty.Posix{
        .master = sv_single[0],
        .pid = -1,
        .stdout_read_fd = -1,
        .error_read_fd = -1,
    };

    const driver_options: rex.driver.Options = .{ .theme = .graphite, .sync_output_timeout_ms = 150 };
    const single_driver = try SingleDriverType.init(allocator, testing.io, pty_single, driver_options);
    var driver_s: Driver = .{ .single = single_driver };
    defer driver_s.deinit();

    try testing.expectEqual(@as(posix.pid_t, -1), driver_s.getPid());
    try testing.expect(!driver_s.getModes().cursor_keys);
    _ = driver_s.getFrame();

    var sv_multi: [2]posix.fd_t = undefined;
    try testing.expectEqual(@as(c_int, 0), system.socketpair(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.NONBLOCK, 0, &sv_multi));
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

test "App: quitConfirmModalRequest layout and hitTest" {
    const testing = std.testing;

    var actions: [2]Modal.Action = undefined;
    const req = quitConfirmModalRequest(.{ .corner_radius = 8.0, .border_width = 1.0, .border_shape = .rounded }, .{}, .{}, &actions);
    try testing.expectEqual(@as(f32, 8.0), req.corner_radius);
    try testing.expectEqualStrings("Quit terminal", actions[0].label);
    try testing.expectEqualStrings("Cancel and stay", actions[1].label);

    // Outside click cancels
    try testing.expectEqual(Modal.HitResult.outside, Modal.hitTest(req, 80, 24, 2, 2).?);

    // Action 0 ("Quit terminal" at row 13)
    try testing.expectEqual(Modal.HitResult{ .action = 0 }, Modal.hitTest(req, 80, 24, 25, 13).?);

    // Action 1 ("Cancel and stay" at row 14)
    try testing.expectEqual(Modal.HitResult{ .action = 1 }, Modal.hitTest(req, 80, 24, 25, 14).?);

    // Custom configuration overrides
    var custom_actions: [2]Modal.Action = undefined;
    const custom_req = quitConfirmModalRequest(.{}, .{
        .backdrop_opacity = 100.0 / 255.0,
        .cols = 50,
    }, .{
        .title = "TERMINATE NOW?",
        .confirm_label = "Yes, kill it",
        .cancel_label = "No, go back",
    }, &custom_actions);
    try testing.expectEqualStrings("TERMINATE NOW?", custom_req.title);
    try testing.expectEqualStrings("Yes, kill it", custom_actions[0].label);
    try testing.expectEqualStrings("No, go back", custom_actions[1].label);
    try testing.expectEqual(@as(u8, 100), custom_req.dim_alpha);
    try testing.expectEqual(@as(u16, 50), custom_req.cols);
}

test "App: quit confirm modal focus cycling and hotspot routing" {
    const testing = std.testing;

    var focus = FocusGroup.init(2, 0);
    try testing.expect(focus.isFocused(0));
    try testing.expect(!focus.isFocused(1));

    // Tab forward cycles to cancel button
    focus.next();
    try testing.expect(focus.isFocused(1));
    try testing.expect(!focus.isFocused(0));

    // Tab wraps around to quit button
    focus.next();
    try testing.expect(focus.isFocused(0));

    // Shift-Tab cycles backward
    focus.previous();
    try testing.expect(focus.isFocused(1));

    // Hotspot table routing
    var table: Table = .{};
    table.add(17, 13, 40, 1, .{ .modal_action = 0 });
    table.add(17, 14, 40, 1, .{ .modal_action = 1 });

    const hit_quit = table.hitTest(25, 13);
    try testing.expect(hit_quit != null);
    try testing.expectEqual(Tag.modal_action, std.meta.activeTag(hit_quit.?));
    try testing.expectEqual(@as(u8, 0), hit_quit.?.modal_action);

    const hit_cancel = table.hitTest(25, 14);
    try testing.expect(hit_cancel != null);
    try testing.expectEqual(Tag.modal_action, std.meta.activeTag(hit_cancel.?));
    try testing.expectEqual(@as(u8, 1), hit_cancel.?.modal_action);
}

test "App: routeKeyToUi unified dispatcher consumes modal keys and suppresses text leakage" {
    const testing = std.testing;

    // Simulate modal close with 'q': routeKeyToUi handles the key and returns true.
    // The caller in keyCb automatically sets skip_next_char = true without the modal handler
    // needing to manage any low-level GLFW callback suppression state.
    var dashboard_open = true;
    var skip_next_char = false;

    // Simulated routeKeyToUi
    const key_consumed = blk: {
        if (dashboard_open) {
            dashboard_open = false; // Closed by 'q'
            break :blk true;
        }
        break :blk false;
    };

    if (key_consumed) {
        skip_next_char = true;
    }

    try testing.expect(key_consumed);
    try testing.expect(skip_next_char);
    try testing.expect(!dashboard_open);

    // In charCb: character callback is suppressed and skip flag consumed
    var char_sent = false;
    if (skip_next_char) {
        skip_next_char = false;
    } else if (!dashboard_open) {
        char_sent = true;
    }
    try testing.expect(!char_sent);
    try testing.expect(!skip_next_char);

    // Subsequent normal typing is unconsumed and reaches the terminal
    const normal_key_consumed = blk: {
        if (dashboard_open) {
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
    } else if (!dashboard_open) {
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
    try std.testing.expectError(error.SpawnFailed, spawnShell(gpa, io, .default, .{ .program = "/nonexistent/rex-test-shell" }, "/bin/sh", envp, &failure));
    try std.testing.expectEqual(.execve, failure.?.stage);
    try std.testing.expectError(error.SpawnFailed, spawnShell(gpa, io, .default, .{ .working_directory = "/nonexistent/rex-test-dir" }, "/bin/sh", envp, &failure));
    try std.testing.expectEqual(.chdir, failure.?.stage);

    // The fallback: no program (the login shell) and no directory.
    var pty = try spawnShell(gpa, io, .default, .{ .arguments = &.{ "-c", "exit 0" } }, "/bin/sh", envp, &failure);
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
        .blink = .default,
        .font = .{
            .faces = .{ .regular = "/base/regular.ttf" },
            .size = 20,
            .max_size = 96,
            .min_size = 6,
        },
        .keymap = rex.input.default_keymap,
        .termio = .{},
        .theme = Theme.graphite,
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
