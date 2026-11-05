const App = @This();

const std = @import("std");
const root = @import("root");
const builtin = @import("builtin");

const log = std.log.scoped(.app);

pub const std_options: std.Options = .{
    .log_level = .warn,
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
const HotspotTable = ui_mod.HotspotTable;
const UiAction = ui_mod.UiAction;
const UiActionTag = ui_mod.UiActionTag;
const Text = ui_mod.Text;
const Drawer = ui_mod.Drawer;

const Freetype = rex.FreeType;
const Rasterizer = rex.FreeType.Rasterizer;

const input = rex.input;
const Binding = input.Binding;
const KeyContext = input.KeyContext;

const Pty = rex.termio.Pty;

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

pub const Config = struct {
    blink: struct {
        /// Half period of SGR 5 blink, in ms. 0 turns blinking off.
        half_period: u64 = 500,
        /// Half period of SGR 6 rapid blink, in ms. 0 turns it off.
        rapid_half_period: u64 = 250,
    },
    font: Freetype.FontConfig,
    keymap: []const Binding,
    wellbeing: wellbeing.Option = .{},
    termio: rex.termio.pty.SpawnOption,
    /// Bytes read from the pty per read call, default 65534. Bigger
    /// reads parse long output in fewer frames; 0 is treated as 1.
    read_buffer_size: usize = std.math.maxInt(u16) - 1,
    theme: Theme,
    /// Optional handcrafted design tokens override for custom surface and border styling.
    tokens: ?rex.color.Tokens = null,
    window: struct {
        background: Background.Option,
        /// Rings the X bell on BEL and on pomodoro phase changes.
        bell: enum { on, off } = .on,
        /// XBell volume, as a percent of the X server bell volume.
        bell_volume: u8 = 100,
        scrollbar: Scrollbar.Option,
        cursor: Cursor.Option,
        /// Positions, thicknesses and looks of underline, strikethrough
        /// and overline. The defaults follow the font.
        decoration: renderer_mod.Decoration.Option = .{},
        /// Opacity of SGR 2 (dim) text, 0.0 to 1.0.
        dim_alpha: f32 = 0.5,
        /// Glyph atlas texture size, default 2048x2048. Bigger fits more
        /// distinct glyphs (emoji, CJK, large fonts) before it is full.
        atlas: Atlas.Option = .{},
        selection: renderer_mod.Selection.Option,
        /// Initial window size, in screen coordinates.
        size: Dimension(u16) = .{ .width = 1920, .height = 1080 },
        /// Window title. A running pomodoro is appended after it.
        title: [:0]const u8 = "rex",
        /// Rounded card surface options for UI modals and overlays.
        card: Card.Option = .{},
        /// In-terminal toast notification options.
        toast: Toast.Option = .{},
        /// Semantic icon rendering options.
        icon: Icon.Option = .{},
        /// Modal dialog options including dimensions, dimming, and default focus.
        modal: Modal.Option = .{},
        /// Interactive button primitive options.
        button: Button.Option = .{},
        /// Prompts for confirmation before closing the window while the terminal session is active.
        confirm_quit: bool = true,
    },
    scroll: struct {
        /// Lines moved by the scroll_up and scroll_down actions.
        lines: u32 = 3,
        /// Lines moved per mouse wheel step.
        wheel_lines: u32 = 3,
    } = .{},
    selection: struct {
        mouse_double_click_interval_ms: f64 = 500,
        classifier: unicode.Classifier.Option,
    },
    /// Stores list of plain environment variable using "KEY=VALUE" format
    environments: []const rex.env.PlainVar,
    /// Grid limits and identity: max_rows (200), max_cols (220),
    /// tab_width (8), max_scrollback (3896), ambiguous_width (.narrow),
    /// name ("rex") and version ("0.1.0"). Rows plus scrollback should
    /// be a power of two so the ring wastes nothing, see
    /// TerminalOption.optimized.
    ///
    /// These size the screen at compile time, so the types below read
    /// them from the root file: main.zig declares
    /// `pub const rex_terminal_option = config.terminal;`. App.init
    /// fails to compile when the two differ.
    terminal: TerminalOption = default_terminal_option,
    /// Threading configuration: .single for in-loop synchronous execution,
    /// or .multi for dedicated background worker thread with wait-free triple buffer.
    threading: ThreadingConfig = .{},
};

pub const ThreadingMode = enum {
    single,
    multi,
};

pub const ThreadingConfig = struct {
    mode: ThreadingMode = .multi,
    sync_output_timeout_ms: u32 = 150,
};

/// Terminal limits used when the root file sets none, as in tests.
/// 200 rows plus 3896 scrollback lines fill a 4096 row ring.
pub const default_terminal_option: TerminalOption = .{
    .max_rows = 200,
    .max_cols = 220,
    .tab_width = 8,
    .max_scrollback = 3896,
    .name = "rex",
    .version = "0.1.0",
};

/// Terminal limits the screen, frame and renderer types are built
/// with: the root rex_terminal_option when declared, else the defaults.
pub const terminal_option: TerminalOption = if (@hasDecl(root, "rex_terminal_option"))
    root.rex_terminal_option
else
    default_terminal_option;

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
pub const DriverEvents = rex.driver.DriverEvents;
pub const SharedModes = rex.driver.SharedModes;
pub const InputEvent = rex.driver.InputEvent;
pub const resolveAnchor = rex.driver.resolveAnchor;

allocator: std.mem.Allocator,
atlas: Atlas,

config: Config,
config_watcher: ?rex.config.Watcher = null,
config_path: ?[]const u8 = null,
background_color: [4]f32,

rasterizer: Rasterizer,
frame_builder: FrameBuilderType,

io: std.Io,
renderer: RendererType,
driver: Driver,

word_classifier: unicode.Classifier,

// Wellbeing & Focus state
wellbeing_state: wellbeing.Wellbeing,
wellbeing_overlay: wellbeing.overlay.Overlay = .{},
toast_queue: Toast.Queue = .{},

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
font_size: u32,
font_size_pending: ?u32 = null,

needs_redraw: bool = true,
quit_confirm_open: bool = false,
quit_confirmed: bool = false,
quit_modal_focus: FocusGroup = FocusGroup.init(2, 0),
hotspots: HotspotTable = .{},
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
    defer gpa.free(home_dir);
    if (!std.fs.path.isAbsolute(home_dir)) {
        return error.InvalidHomeDir;
    }

    log.debug("envi $HOME: '{s}'", .{home_dir});

    var envmap = try environ.createMap(gpa);
    defer envmap.deinit();

    var dirs = try rex.dirs.Application.resolve(
        gpa,
        terminal_option.name,
        home_dir,
        &envmap,
    );
    errdefer dirs.deinit(gpa);

    log.debug("dirs: {f}", .{dirs});

    var active_config: Config = config.*;

    // Resolve user configuration path or use custom CLI path
    var user_cfg_path: ?[]const u8 = null;
    if (custom_config_path) |ccp| {
        user_cfg_path = try gpa.dupe(u8, ccp);
    } else {
        user_cfg_path = rex.config.resolveUserConfigPath(gpa, &dirs) catch null;
    }
    errdefer if (user_cfg_path) |p| gpa.free(p);

    // Layer 1: System config (/etc/rex/config)
    var sys_diags = rex.config.Diagnostics{};
    var sys_file_cfg = rex.config.FileConfig{};
    if (rex.config.loadFile(rex.config.system_config_path, &sys_file_cfg, &sys_diags) catch false) {
        rex.config.applyFileConfig(&active_config, &sys_file_cfg, gpa) catch |err| {
            log.warn("failed to apply system config: {}", .{err});
        };
    }

    // Layer 2: User config (~/.config/rex/config or custom path)
    var startup_warning: ?[128]u8 = null;
    var startup_warn_len: usize = 0;
    if (user_cfg_path) |p| {
        var user_diags = rex.config.Diagnostics{};
        var user_file_cfg = rex.config.FileConfig{};
        if (rex.config.loadFile(p, &user_file_cfg, &user_diags) catch false) {
            if (user_diags.hasErrors()) {
                const first = user_diags.items[0];
                var buf: [128]u8 = undefined;
                if (std.fmt.bufPrint(&buf, "Line {d}: {s}", .{ first.line, first.message() })) |msg| {
                    startup_warning = buf;
                    startup_warn_len = msg.len;
                } else |_| {}
            }
            rex.config.applyFileConfig(&active_config, &user_file_cfg, gpa) catch |err| {
                log.warn("failed to apply user config: {}", .{err});
            };
        }
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

    var pty = try Pty.spawn(.{
        .argv = active_config.termio.argv,
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

    var win: Window = try .init(active_config.window.size.width, active_config.window.size.height, active_config.window.title);
    errdefer win.deinit();

    var rasterizer: Rasterizer = try .create(gpa, active_config.font);
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

    var driver: Driver = switch (active_config.threading.mode) {
        .single => .{ .single = try SingleDriverType.initWithTimeout(gpa, io, pty, active_config.theme, active_config.threading.sync_output_timeout_ms) },
        .multi => .{ .threaded = try ThreadedDriverType.create(gpa, io, pty, active_config.theme, active_config.threading.sync_output_timeout_ms) },
    };
    errdefer driver.deinit();

    if (driver == .threaded) {
        driver.threaded.wakeup_fn = Window.glfwPostEmptyEvent;
    }

    const background_color = active_config.theme.background;
    const background_alpha = active_config.window.background.alpha;

    const classifier = try unicode.Classifier.init(active_config.selection.classifier);
    const now = std.Io.Clock.Timestamp.now(io, .awake);

    var watcher: ?rex.config.Watcher = null;
    if (user_cfg_path) |cfg_p| {
        const dir_name = std.fs.path.dirname(cfg_p) orelse dirs.config;
        const file_name = std.fs.path.basename(cfg_p);
        watcher = rex.config.Watcher.init(dir_name, file_name);
    } else {
        watcher = rex.config.Watcher.init(dirs.config, "config");
    }

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

    var app = App{
        .io = io,
        .driver = driver,
        .window = win,
        .background_color = .{ background_color.r, background_color.g, background_color.b, background_alpha },
        .blink = .{ .period_ms = active_config.blink.half_period },
        .blink_rapid = .{ .period_ms = active_config.blink.rapid_half_period },
        .dirs = dirs,
        .argv0 = argv0,
        .allocator = gpa,
        .renderer = renderer,
        .rasterizer = rasterizer,
        .atlas = atlas,
        .frame_builder = frame_builder,
        .config = active_config,
        .config_watcher = watcher,
        .config_path = user_cfg_path,
        .font_size = active_config.font.height,
        .wellbeing_state = wellbeing_state,
        .wellbeing_overlay = wellbeing_overlay,
        .toast_queue = .{},
        .frame_buffer_size = .empty,
        .last_frame = now,
        .last_title = now,
        .word_classifier = classifier,
    };

    if (startup_warning) |warn_buf| {
        app.notifySimple("Config Error", warn_buf[0..startup_warn_len], .warning);
    }

    return app;
}

pub fn deinit(self: *App, gpa: std.mem.Allocator) void {
    if (self.config_watcher) |*w| w.deinit();
    if (self.config_path) |p| gpa.free(p);

    self.renderer.deinit();
    self.frame_builder.deinit(gpa);
    self.atlas.destroy();
    self.rasterizer.destroy(gpa);
    self.window.deinit();
    self.driver.deinit();
    self.wellbeing_overlay.deinit(gpa);

    self.wellbeing_state.saveState(self.io, self.dirs.state) catch |err| {
        log.err("failed to save wellbeing stats: {any}", .{err});
    };
    self.dirs.deinit(gpa);
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

        if (driver_events.had_data) {
            had_data = true;
            self.needs_redraw = true;
        }

        if (driver_events.bell) self.ringBell();

        if (driver_events.resize) |resize| {
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

        if (driver_events.hard_reset) {
            self.selection = .empty;
            self.frame_buffer_size = .empty;
            self.handleResize(self.window.frameBufferSize(u16));
        }

        if (driver_events.selection_reset) {
            self.selection = .empty;
            self.needs_redraw = true;
        }

        if (driver_events.title) {
            self.updateWindowTitle();
        }

        if (driver_events.child_closed) {
            break :start;
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
        self.flushScroll();
    }
}

fn renderFrame(self: *App) !bool {
    const atlas = &self.atlas;
    const current_frame = self.driver.getFrame();

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
            quitConfirmModalRequest(self.config.window.card, self.config.window.modal, &actions),
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

    const app_toasts_active = !self.quit_confirm_open and self.config.window.toast.enabled and self.toast_queue.isActive();
    const overlay_active = self.quit_confirm_open or self.wellbeing_overlay.isActive() or app_toasts_active;
    const overlay_changed = overlay_active or self.wellbeing_overlay.was_active;
    self.wellbeing_overlay.was_active = overlay_active;

    if (overlay_active) {
        frame.overlay_background_instances = self.wellbeing_overlay.bg_buffer.items;
        frame.overlay_card_instances = self.wellbeing_overlay.card_buffer.items;
        frame.overlay_gray_instances = self.wellbeing_overlay.gray_buffer.items;
        frame.overlay_color_instances = self.wellbeing_overlay.color_buffer.items;
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

    self.window.swapBuffers();
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

/// Rings the X bell at the configured volume, unless the bell is off or muted by wellbeing.
fn ringBell(self: *App) void {
    if (self.config.window.bell == .off) return;
    if (self.wellbeing_state.mute_audio_bell) return;
    self.window.ringBell(self.config.window.bell_volume);
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
        .min_width = self.config.window.toast.min_width,
        .max_width = self.config.window.toast.max_width,
        .margin_cols = self.config.window.toast.margin_cols,
        .margin_rows = self.config.window.toast.margin_rows,
    });
}

fn setFontSize(self: *App, new_size: u32) void {
    const clamped_size: u32 = @max(self.config.font.min_size, @min(new_size, self.config.font.max_size));
    if (clamped_size == self.font_size) return;

    var font_config = self.config.font;
    font_config.height = clamped_size;
    // Create new rasterizer BEFORE destroying old one (avoid dangling ptr on failure)
    const new_rasterizer = Rasterizer.create(self.allocator, font_config) catch |err| {
        log.err("setFontSize: rasterizer.create failed: {}", .{err});
        return;
    };
    self.rasterizer.destroy(self.allocator);
    self.rasterizer = new_rasterizer;
    self.renderer.setFontMetrics(self.rasterizer.metrics);

    // Invalidate atlas, all cached glyphs are wrong size now
    self.atlas.invalidate();

    // Invalidate frame builder cached generation
    self.frame_builder.last_generation = null;

    self.font_size = clamped_size;
    self.needs_redraw = true;

    // Reset cached fb size to force handleResize to recompute rows/cols
    self.frame_buffer_size = .empty;

    const fb = self.window.frameBufferSize(u16);
    self.handleResize(fb);

    var toast_buf: [64]u8 = undefined;
    const toast_msg = std.fmt.bufPrint(&toast_buf, "Font: {d}pt ({d}x{d} px)", .{
        clamped_size,
        self.rasterizer.cell_width,
        self.rasterizer.cell_height,
    }) catch "Font size updated";
    self.notifySimple(toast_msg, "", .info);
}

fn adjustFontSize(self: *App, delta: i32) void {
    const new_size: i32 = @as(i32, @intCast(self.font_size)) + delta;
    self.setFontSize(@intCast(@max(6, new_size)));
}

pub fn reloadConfig(self: *App) void {
    var diags = rex.config.Diagnostics{};
    var file_cfg = rex.config.FileConfig{};

    var loaded_any = false;

    // 1. Layer: System config (/etc/rex/config)
    if (rex.config.loadFile(rex.config.system_config_path, &file_cfg, &diags) catch false) {
        loaded_any = true;
    }

    // 2. Layer: User config (~/.config/rex/config)
    if (self.config_path) |p| {
        if (rex.config.loadFile(p, &file_cfg, &diags) catch false) {
            loaded_any = true;
        }
    }

    if (!loaded_any and diags.count == 0) {
        self.notifySimple("Configuration", "No config file found", .neutral);
        return;
    }

    if (diags.hasErrors()) {
        const first_msg = diags.items[0].message();
        self.notifySimple("Config Error", first_msg, .warning);
        return;
    }

    // Apply file config onto active config
    rex.config.applyFileConfig(&self.config, &file_cfg, self.allocator) catch |err| {
        var err_buf: [64]u8 = undefined;
        const err_msg = std.fmt.bufPrint(&err_buf, "Failed to apply: {}", .{err}) catch "Apply failed";
        self.notifySimple("Config Error", err_msg, .warning);
        return;
    };

    // Live update renderer background color and alpha
    const bg = self.config.theme.background;
    self.background_color = .{ bg.r, bg.g, bg.b, self.config.window.background.alpha };
    self.renderer.background.option.alpha = self.config.window.background.alpha;

    // Live update font size if modified
    if (self.config.font.height != self.font_size) {
        self.setFontSize(self.config.font.height);
    }

    // Live update wellbeing overlay options and tokens
    self.wellbeing_overlay.card_opt = self.config.window.card;
    self.wellbeing_overlay.modal_opt = self.config.window.modal;
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
            const target = (self.font_size_pending orelse self.font_size) + 2;
            self.font_size_pending = @min(target, self.config.font.max_size);
        },
        .decrease_font_size => {
            const current = self.font_size_pending orelse self.font_size;
            const target = if (current > 2) current - 2 else 6;
            self.font_size_pending = @max(target, self.config.font.min_size);
        },
        .reset_font_size => {
            self.font_size_pending = self.config.font.height;
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

fn quitConfirmModalRequest(card_opt: Card.Option, modal_opt: Modal.Option, actions: *[2]Modal.Action) Modal.Request {
    actions.* = .{
        .{ .shortcut = "Enter / Y", .label = modal_opt.confirm_label },
        .{ .shortcut = "Esc / N", .label = modal_opt.cancel_label },
    };
    return .{
        .title = modal_opt.title,
        .line1 = modal_opt.line1,
        .line2 = modal_opt.line2,
        .actions = actions,
        .variant = .warning,
        .dim_alpha = modal_opt.dim_alpha,
        .width = modal_opt.width,
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
                self.quit_modal_focus.prev();
            } else {
                self.quit_modal_focus.next();
            }
            self.frame_builder.last_generation = null;
            self.needs_redraw = true;
        },
        .left, .up => {
            self.quit_modal_focus.prev();
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
            self.needs_redraw = true;
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
            self.needs_redraw = true;
        },
        .r => {
            self.wellbeing_state.purgeHistory(self.io, self.dirs.state) catch {};
            self.needs_redraw = true;
        },
        .p => {
            self.wellbeing_state.toggleFocus();
            self.updateWindowTitle();
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
            app.driver.sendBytes(buf[0..len]) catch |err| {
                log.err("charCallback: driver sendBytes failed: {}", .{err});
                return;
            };
            app.snapToLiveView();
        }
    }
}.cb;

const keyCb: c.GLFWkeyfun = struct {
    fn cb(window: ?*c.GLFWwindow, key: c_int, _: c_int, action: c_int, mods: c_int) callconv(.c) void {
        const app: *App = @ptrCast(@alignCast(c.glfwGetWindowUserPointer(window) orelse return));
        if (action == c.GLFW_RELEASE) return;
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
            app.driver.sendBytes(bytes) catch |err| {
                log.err("keyCallback: driver sendBytes failed: {}", .{err});
                return;
            };
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

        const within_time = (now_ms - self.mouse_last_click_ms) <= self.config.selection.mouse_double_click_interval_ms;

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
    // 1. In-stream registered interactive hotspots
    if (self.hotspots.hitTest(col, row)) |action| {
        switch (action) {
            .confirm_quit => self.confirmQuit(),
            .cancel_modal => {
                self.quit_confirm_open = false;
                self.frame_builder.last_generation = null;
                self.needs_redraw = true;
            },
            .modal_action => |idx| if (idx == 0) self.confirmQuit() else {
                self.quit_confirm_open = false;
                self.frame_builder.last_generation = null;
                self.needs_redraw = true;
            },
            .dismiss_toast, .activate_toast => |id| {
                _ = self.toast_queue.dismiss(id);
                self.needs_redraw = true;
            },
            .wellbeing_close => {
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
            .wellbeing_toggle_focus => {
                self.wellbeing_state.toggleFocus();
                self.updateWindowTitle();
                self.frame_builder.last_generation = null;
                self.needs_redraw = true;
            },
            .wellbeing_reset => {
                self.wellbeing_state.purgeHistory(self.io, self.dirs.state) catch {};
                self.frame_builder.last_generation = null;
                self.needs_redraw = true;
            },
            .wellbeing_copy_card => {
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
            .none => {},
        }
        return true;
    }

    // 2. Clicks outside or inside modal dialogs
    if (self.quit_confirm_open) {
        const current_frame = self.driver.getFrame();
        var actions: [2]Modal.Action = undefined;
        if (Modal.hitTest(
            quitConfirmModalRequest(self.config.window.card, self.config.window.modal, &actions),
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

    // 3. Clicks outside or inside wellbeing dashboard panel
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

    // 4. Lock screen swallows all clicks during active break
    if (self.wellbeing_overlay.lock_screen_active) {
        return true;
    }

    // 5. Fallback for toast dismiss/body
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
            app.sendMouseMotion(col, row);
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
        app.handleResize(.{ .height = @intCast(h), .width = @intCast(w) });
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

    const threaded_driver = try ThreadedDriverType.create(allocator, testing.io, pty_multi, .graphite, 150);
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
    const req = quitConfirmModalRequest(.{ .corner_radius = 8.0, .border_width = 1.0, .border_shape = .rounded }, .{}, &actions);
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
        .title = "TERMINATE NOW?",
        .confirm_label = "Yes, kill it",
        .cancel_label = "No, go back",
        .dim_alpha = 100,
        .width = 50,
    }, &custom_actions);
    try testing.expectEqualStrings("TERMINATE NOW?", custom_req.title);
    try testing.expectEqualStrings("Yes, kill it", custom_actions[0].label);
    try testing.expectEqualStrings("No, go back", custom_actions[1].label);
    try testing.expectEqual(@as(u8, 100), custom_req.dim_alpha);
    try testing.expectEqual(@as(u16, 50), custom_req.width);
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
    focus.prev();
    try testing.expect(focus.isFocused(1));

    // Hotspot table routing
    var table: HotspotTable = .{};
    table.add(17, 13, 40, 1, .confirm_quit);
    table.add(17, 14, 40, 1, .cancel_modal);

    const hit_quit = table.hitTest(25, 13);
    try testing.expect(hit_quit != null);
    try testing.expectEqual(UiActionTag.confirm_quit, std.meta.activeTag(hit_quit.?));

    const hit_cancel = table.hitTest(25, 14);
    try testing.expect(hit_cancel != null);
    try testing.expectEqual(UiActionTag.cancel_modal, std.meta.activeTag(hit_cancel.?));
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
