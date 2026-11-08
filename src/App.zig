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
const Card = renderer_mod.Card;
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
const KeyContext = input.KeyContext;

const Pty = rex.termio.Pty;
const latency_trace = rex.driver.latency_trace;

const Theme = rex.terminal.Theme;
const Color = rex.terminal.cell.Color;
const Terminal = rex.terminal.Terminal;
const MouseButton = rex.terminal.term.MouseButton;
const HeldButtons = rex.terminal.term.HeldButtons;
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
        std.mem.eql(u8, a.version, b.version);
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
window_focused: bool = true,
frame_buffer_size: Dimension(u16),
last_title: std.Io.Clock.Timestamp,

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
    const startup_banner = configBanner(&loaded);
    var config_arena = loaded.takeArena();
    errdefer config_arena.deinit();
    var active_config = loaded.config;
    // Clamped like every later size change (setFontSize).
    active_config.font.size = @max(active_config.font.min_size, @min(active_config.font.size, active_config.font.max_size));
    if (!hasFontFile(active_config.font)) {
        log.err("no font: set `file` in [font] of {s}; Rex has no built-in font yet", .{user_cfg_path});
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

    // Without a configured argv, the user's shell, like other terminals.
    // The child gets its own copy at fork, so this can go after spawn.
    const shell = try gpa.dupeZ(u8, defaultShell(envmap.get("SHELL"), passwdShell()));
    defer gpa.free(shell);
    const shell_argv = [_:null]?[*:0]const u8{ shell, null };

    var pty = try Pty.spawn(.{
        .argv = active_config.termio.argv orelse &shell_argv,
        .capture_stdout = active_config.termio.capture_stdout,
        .cols = active_config.termio.cols,
        .cwd = active_config.termio.cwd,
        .envp = block.slice,
        .o_flags = active_config.termio.o_flags,
        .rows = active_config.termio.rows,
    });
    errdefer pty.close(io);

    pty.waitForSpawn() catch |err| {
        log.err("pty failed to spawn: {}", .{err});
        return err;
    };

    log.debug("termio.pty: {f}", .{pty});

    const platform = Window.choosePlatform(active_config.window.platform, wayland_session);
    log.debug("platform: {f}, forced: {}", .{ platform, platform.forced });

    var win: Window = try .init(.{
        .width = active_config.window.size.width,
        .height = active_config.window.size.height,
        .title = active_config.window.title,
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
    wellbeing_state.loadState(io, dirs.state);

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

    var driver: Driver = switch (active_config.threading.mode) {
        .single => .{ .single = try SingleDriverType.initWithTimeout(gpa, io, pty, active_config.theme, active_config.threading.sync_output_timeout_ms) },
        .multi => .{ .threaded = try ThreadedDriverType.create(gpa, io, pty, active_config.theme, active_config.threading.sync_output_timeout_ms, latency) },
    };
    errdefer driver.deinit();

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

    var wellbeing_overlay = wellbeing.overlay.Overlay{};
    wellbeing_overlay.card_opt = active_config.window.card;
    wellbeing_overlay.modal_opt = active_config.window.modal;
    wellbeing_overlay.toast_opt = active_config.window.toast;
    wellbeing_overlay.icon_opt = active_config.window.icon;
    wellbeing_overlay.tokens = rex.color.Tokens.fromThemeWithOverride(active_config.theme, active_config.tokens);

    const app = App{
        .io = io,
        .driver = driver,
        .latency = latency,
        .latency_path = latency_path,
        .window = win,
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
        .wellbeing_overlay = wellbeing_overlay,
        .toast_queue = .{},
        .config_banner = startup_banner,
        .frame_buffer_size = .empty,
        .last_frame = now,
        .last_title = now,
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

    self.wellbeing_state.saveState(self.io, self.dirs.state) catch |err| {
        log.err("failed to save wellbeing stats: {any}", .{err});
    };
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
    self.window.setWindowCloseCallback(windowCloseCb);
    self.window.setWindowContentScaleCallback(contentScaleCb);

    start: while (true) {
        if (self.window.windowShouldClose()) {
            if (!self.config.window.confirm_quit or self.quit_confirmed) break :start;
            self.requestQuit();
        }
        const now = std.Io.Clock.Timestamp.now(self.io, .awake);
        const dt = self.last_frame.durationTo(now);
        self.last_frame = now;
        const dt_ms: u64 = @intCast(dt.raw.toMilliseconds());
        const dt_clamped: u64 = @min(dt_ms, 500);

        const blink_changed = self.tick(dt_clamped);

        const now_real = std.Io.Clock.Timestamp.now(self.io, .real);
        const now_secs: i64 = @intCast(now_real.raw.toSeconds());

        const wb_res = self.wellbeing_state.tick(dt_clamped, self.driver.getMasterFd(), now_secs);
        self.renderer.grayscale = wb_res.grayscale;
        self.renderer.color_tint = wb_res.tint;
        if (wb_res.needs_redraw) {
            self.frame_builder.last_generation = null;
            self.needs_redraw = true;
        }
        if (wb_res.phase_changed) {
            self.wellbeing_state.saveState(self.io, self.dirs.state) catch {};
            self.ringBell();
            self.last_title = now;
            self.updateWindowTitle();
        } else if (wb_res.alert != null) {
            self.ringBell();
            self.updateWindowTitle();
        }

        const title_elapsed = self.last_title.durationTo(now);
        if (title_elapsed.raw.toMilliseconds() >= 1000) {
            self.last_title = self.last_title.addDuration(.{
                .raw = .fromNanoseconds(1_000_000_000),
                .clock = .awake,
            });
            // update title every second even without a phase transition
            self.updateWindowTitle();
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
            self.handleResize(self.window.frameBufferSize(u16));
        }

        if (f.selection_reset) {
            self.selection = .empty;
            self.needs_redraw = true;
        }

        if (f.title) {
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
                self.config.window.card,
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
            self.config.window.card,
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

    if (!frame.dirty.any()) return false;

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
    self.window.swapBuffers();
    if (latency_trace.enabled and swapped_seq != 0) {
        self.latency.?.stamp(swapped_seq, .swapped, latency_trace.now(self.io));
    }
    return true;
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
            @min(self.wellbeing_state.focus_state.msUntilTick(), self.toast_queue.msUntilNextTick()),
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
    const base = self.config.window.title;
    const focus_state = self.wellbeing_state.focus_state;
    const has_focus = focus_state.phase != .idle;
    const is_locked = self.wellbeing_state.input_locked;
    const is_paused = self.wellbeing_state.isFocusPausedByAlert() or focus_state.paused;

    if (!has_focus and !is_locked) {
        return self.window.setWindowTitle(base);
    }

    var title_buf: [128]u8 = undefined;
    const phase_label: []const u8 = switch (focus_state.phase) {
        .task => "FOCUS",
        .short_break => "BREAK",
        .long_break => "LONG BREAK",
        .idle => if (is_locked) "REST" else "",
    };

    const rem_s = if (has_focus)
        (focus_state.remaining_ms + 999) / 1000
    else
        self.wellbeing_state.current_alert.remaining_s;

    const mins = rem_s / 60;
    const secs = rem_s % 60;

    var formatted: [:0]const u8 = undefined;
    if (is_locked and is_paused) {
        formatted = std.fmt.bufPrintZ(&title_buf, "{s} │ {s} │ PAUSED │ LOCKED │ {d:0>2}:{d:0>2}", .{
            base, phase_label, mins, secs,
        }) catch base;
    } else if (is_locked) {
        formatted = std.fmt.bufPrintZ(&title_buf, "{s} │ {s} │ LOCKED │ {d:0>2}:{d:0>2}", .{
            base, phase_label, mins, secs,
        }) catch base;
    } else if (is_paused) {
        formatted = std.fmt.bufPrintZ(&title_buf, "{s} │ {s} │ PAUSED │ {d:0>2}:{d:0>2}", .{
            base, phase_label, mins, secs,
        }) catch base;
    } else {
        formatted = std.fmt.bufPrintZ(&title_buf, "{s} │ {s} │ {d:0>2}:{d:0>2}", .{
            base, phase_label, mins, secs,
        }) catch base;
    }

    self.window.setWindowTitle(formatted);
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

/// Pushes a concise toast notification configured with the window's card, toast, and icon options.
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
    _ = self.notifyToast(.{
        .title = title,
        .description = description,
        .icon = if (icon_str.len > 0) icon_str else null,
        .dismiss_str = dismiss_str,
        .action_prompt = self.config.window.toast.action_prompt,
        .variant = variant,
        .position = self.config.window.toast.position,
        .border_style = self.config.window.toast.border_style,
        .corner_radius = self.config.window.card.effectiveRadius(),
        .border_width = self.config.window.card.border_width,
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
    if (!hasFontFile(loaded.config.font)) {
        self.config_banner = Banner.init(.err, "Config error", "font.file is not set; Rex has no built-in font yet");
        self.frame_builder.last_generation = null;
        self.needs_redraw = true;
        return;
    }
    const new_config = loaded.config;

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
    self.frame_builder.last_generation = null;

    // Live update font size if modified
    if (self.config.font.size != self.font_size) {
        self.setFontSize(self.config.font.size);
    }

    // Live update wellbeing overlay options and tokens
    self.wellbeing_overlay.card_opt = self.config.window.card;
    self.wellbeing_overlay.modal_opt = self.config.window.modal;
    self.wellbeing_overlay.toast_opt = self.config.window.toast;
    self.wellbeing_overlay.icon_opt = self.config.window.icon;
    self.wellbeing_overlay.tokens = rex.color.Tokens.fromThemeWithOverride(self.config.theme, self.config.tokens);

    // Live update wellbeing tracking options
    self.wellbeing_state.option = self.config.wellbeing;

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
            self.driver.sendInput(.{
                .viewport_scroll = .{ .lines = -@as(i32, @intCast(self.config.scroll.lines)) },
            }) catch {};
            self.needs_redraw = true;
        },
        .scroll_down => {
            self.driver.sendInput(.{
                .viewport_scroll = .{ .lines = @as(i32, @intCast(self.config.scroll.lines)) },
            }) catch {};
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
            self.wellbeing_state.toggleFocus();
            self.ringBell();
            self.updateWindowTitle();
        },
        .focus_reset => {
            self.wellbeing_state.resetFocus();
            self.updateWindowTitle();
        },
        .focus_skip => {
            self.wellbeing_state.skipFocus();
            self.ringBell();
            self.updateWindowTitle();
        },
        .focus_auto_transition => {
            self.wellbeing_state.toggleFocusTransitionMode();
            self.updateWindowTitle();
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
                self.updateWindowTitle();
            }
        },
        .wellbeing_clear => {
            self.wellbeing_state.purgeHistory(self.io, self.dirs.state) catch {};
            self.wellbeing_state.current_alert = .{
                .kind = .healthy_break,
                .prompt = "Wellbeing history cleared.",
                .remaining_s = 10,
            };
            self.updateWindowTitle();
        },
        .wellbeing_dismiss => {
            self.wellbeing_state.dismissAlert();
            self.wellbeing_overlay.dashboard_open = false;
            self.quit_confirm_open = false;
            self.toast_queue.dismissAll();
            self.frame_builder.last_generation = null;
            self.needs_redraw = true;
            self.updateWindowTitle();
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
                self.wellbeing_state.skipFocus();
                self.ringBell();
                self.updateWindowTitle();
                self.needs_redraw = true;
            }
        },
        .wellbeing_toast_toggle => {
            const current = self.wellbeing_state.current_alert;
            const next_alert: wellbeing.reminders.Alert = switch (current.kind) {
                .none => .{
                    .kind = .healthy_break,
                    .prompt = "Time for a healthy break: step away and relax.",
                    .remaining_s = 60,
                },
                .healthy_break => .{
                    .kind = .hydration,
                    .prompt = "Stay hydrated: drink some fresh water.",
                    .remaining_s = 60,
                },
                .hydration => .{
                    .kind = .posture,
                    .prompt = "Check posture: roll shoulders back and align neck.",
                    .remaining_s = 60,
                },
                .posture => .{
                    .kind = .screen_limit,
                    .prompt = "Daily screen-time limit reached.",
                    .remaining_s = 60,
                },
                else => .{
                    .kind = .none,
                    .prompt = "",
                    .remaining_s = 0,
                },
            };
            if (next_alert.kind == .none) {
                self.wellbeing_state.dismissAlert();
            } else {
                self.wellbeing_state.current_alert = next_alert;
            }
            self.frame_builder.last_generation = null;
            self.needs_redraw = true;
            self.updateWindowTitle();
        },
        .debug => {
            log.debug("wellbeing_data={any}", .{self.wellbeing_state.data});
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
        self.driver.sendInput(.{ .set_viewport_offset = 0 }) catch {};
    }

    self.needs_redraw = true;
}

/// The shell to start when `termio.argv` isn't set: `$SHELL`, else the
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
    return switch (font.faces.family) {
        .variable => |variable| variable.upright[0] != 0,
        .static => |static| static.regular[0] != 0,
    };
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

fn quitConfirmModalRequest(card_opt: Card.Option, modal_opt: Modal.Option, quit_opt: Config.QuitDialog, actions: *[2]Modal.Action) Modal.Request {
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
        .border_style = modal_opt.border_style orelse card_opt.border_style,
        .dim_alpha = modal_opt.backdropAlpha(),
        .cols = modal_opt.cols,
        .icon_style = modal_opt.icon_style,
        .corner_radius = modal_opt.corner_radius orelse card_opt.effectiveRadius(),
        .border_width = modal_opt.border_width orelse card_opt.border_width,
    };
}

/// Requests closing the terminal window, opening the quit confirmation modal when `confirm_quit` is enabled.
pub fn requestQuit(self: *App) void {
    if (!self.config.window.confirm_quit or self.quit_confirm_open) {
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
                self.wellbeing_state.resetFocus();
                self.updateWindowTitle();
            } else {
                self.wellbeing_state.purgeHistory(self.io, self.dirs.state) catch {};
            }
            self.frame_builder.last_generation = null;
            self.needs_redraw = true;
        },
        .p => {
            self.wellbeing_state.toggleFocus();
            self.updateWindowTitle();
            self.frame_builder.last_generation = null;
            self.needs_redraw = true;
        },
        .s => {
            self.wellbeing_state.skipFocus();
            self.updateWindowTitle();
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

        const maybe_key = rex.input.Key.fromGlfw(key);
        const key_mods = rex.input.Modifiers.fromGlfw(mods);

        if (app.routeKeyToUi(maybe_key, key_mods)) {
            app.skip_next_char = true;
            return;
        }
        app.skip_next_char = false;

        // A bare modifier keeps the selection, since it may start a
        // combination such as Ctrl+Shift+C.
        if (!input.isModifierKey(key)) {
            app.selection = .empty;
            app.needs_redraw = true;
            // Its bytes may come from here or from the char callback.
            if (latency_trace.enabled) app.latency.?.keyPressed(pressed_at);
        }

        // Terminal key encoding
        const driver_modes = app.driver.getModes();
        const context: KeyContext = .{
            .modify_other_keys = driver_modes.modify_other_keys,
            .cursor_keys = driver_modes.cursor_keys,
            .keypad_app = driver_modes.keypad_app,
        };

        var buf: [32]u8 = undefined;
        const bytes = rex.input.encodeKey(key, mods, context, &buf);
        if (bytes.len > 0) {
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
                            self.updateWindowTitle();
                        },
                        .toggle_focus => {
                            self.wellbeing_state.toggleFocus();
                            self.updateWindowTitle();
                            self.frame_builder.last_generation = null;
                            self.needs_redraw = true;
                        },
                        .skip_focus => {
                            self.wellbeing_state.skipFocus();
                            self.updateWindowTitle();
                            self.frame_builder.last_generation = null;
                            self.needs_redraw = true;
                        },
                        .reset_focus => {
                            self.wellbeing_state.resetFocus();
                            self.updateWindowTitle();
                            self.frame_builder.last_generation = null;
                            self.needs_redraw = true;
                        },
                        .purge_history => {
                            self.wellbeing_state.purgeHistory(self.io, self.dirs.state) catch {};
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
            quitConfirmModalRequest(self.config.window.card, self.config.window.modal, self.config.window.quit_dialog, &actions),
            current_frame.active_cols,
            current_frame.active_rows,
            col,
            row,
        )) |hit| {
            if (hit == .outside and self.config.window.modal.close_on_outside_click) {
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
                if (self.config.window.modal.close_on_outside_click) {
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
        self.driver.sendInput(.{ .set_viewport_offset = target }) catch {};

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

    self.driver.sendInput(.{ .set_viewport_offset = target }) catch {};
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
    }) catch {};
    self.needs_redraw = true;
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

    const single_driver = try SingleDriverType.init(allocator, testing.io, pty_single, .graphite);
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

    const threaded_driver = try ThreadedDriverType.create(allocator, testing.io, pty_multi, .graphite, 150, latency_trace.none);
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

test "App: general UI renderer options and theme accent in Config" {
    const testing = std.testing;

    var theme = Theme.graphite;
    theme.accent = .{ .r = 138, .g = 110, .b = 240 };

    const card_opt = Card.Option{
        .corner_radius = 12.0,
        .border_width = 2.0,
        .border_shape = .sharp,
    };
    const toast_opt = Toast.Option{
        .enabled = true,
        .position = .bottom_right,
        .border_style = .subtle,
        .duration_ms = 4000,
    };
    const icon_opt = Icon.Option{
        .style = .nerd_font,
    };

    try testing.expectEqual(@as(f32, 12.0), card_opt.corner_radius);
    try testing.expectEqual(Card.BorderShape.sharp, card_opt.border_shape);
    try testing.expectEqual(Toast.Position.bottom_right, toast_opt.position);
    try testing.expectEqual(Toast.BorderStyle.subtle, toast_opt.border_style);
    try testing.expectEqual(Icon.IconStyle.nerd_font, icon_opt.style);

    const tokens = rex.color.Tokens.fromTheme(theme);
    try testing.expectEqual([3]u8{ 138, 110, 240 }, tokens.accent);
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
            .faces = .{ .family = .{ .variable = .{ .upright = "/base/upright.ttf" } } },
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
    try testing.expectEqualStrings(family, std.mem.span(first.config.font.faces.family.variable.upright));
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
    try testing.expectEqualStrings("/base/upright.ttf", std.mem.span(second.config.font.faces.family.variable.upright));
    try testing.expectEqual(base.keymap.ptr, second.config.keymap.ptr);
}
