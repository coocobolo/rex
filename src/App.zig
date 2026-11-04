const App = @This();

const std = @import("std");
const root = @import("root");
const builtin = @import("builtin");

const log = std.log.scoped(.app);

pub const std_options: std.Options = .{
    .log_level = .warn,
};

const native_os = builtin.os.tag;

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

const pomodoro = rex.builtin.pomodoro;

/// Largest selection copied to the clipboard, in bytes.
const max_copy_size: usize = std.math.maxInt(u16) - 1;

const pomodoro_state_file = "pomodoro_stats.bin";

pub const Config = struct {
    blink: struct {
        /// Half period of SGR 5 blink, in ms. 0 turns blinking off.
        half_period: u64 = 500,
        /// Half period of SGR 6 rapid blink, in ms. 0 turns it off.
        rapid_half_period: u64 = 250,
    },
    font: Freetype.FontConfig,
    keymap: []const Binding,
    pomodoro: pomodoro.Option,
    termio: rex.termio.pty.SpawnOption,
    /// Bytes read from the pty per read call, default 65534. Bigger
    /// reads parse long output in fewer frames; 0 is treated as 1.
    read_buffer_size: usize = std.math.maxInt(u16) - 1,
    theme: Theme,
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
fn sameTerminalOption(comptime a: TerminalOption, comptime b: TerminalOption) bool {
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

pub const SingleDriverType = rex.driver.SingleDriver(terminal_option);
pub const ThreadedDriverType = rex.driver.ThreadedDriver(terminal_option);
pub const DriverEvents = rex.driver.DriverEvents;
pub const SharedModes = rex.driver.SharedModes;
pub const InputEvent = rex.driver.InputEvent;

pub const Driver = union(enum) {
    single: SingleDriverType,
    threaded: *ThreadedDriverType,

    pub fn deinit(self: *Driver, io: std.Io) void {
        switch (self.*) {
            .single => |*d| d.deinit(io),
            .threaded => |d| d.destroy(io),
        }
    }

    pub fn pollAndDrain(self: *Driver) !DriverEvents {
        return switch (self.*) {
            .single => |*d| d.pollAndDrain(),
            .threaded => |d| d.pollAndDrain(),
        };
    }

    pub fn getFrame(self: *const Driver) *const FrameType {
        return switch (self.*) {
            .single => |*d| d.getFrame(),
            .threaded => |d| d.getFrame(),
        };
    }

    pub fn sendInput(self: *Driver, event: InputEvent) !void {
        switch (self.*) {
            .single => |*d| try d.sendInput(event),
            .threaded => |d| _ = d.sendInput(event),
        }
    }

    pub fn sendBytes(self: *Driver, bytes: []const u8) !void {
        switch (self.*) {
            .single => |*d| try d.sendBytes(bytes),
            .threaded => |d| d.sendBytes(bytes),
        }
    }

    pub fn writePaste(self: *Driver, text: []const u8) !void {
        switch (self.*) {
            .single => |*d| try d.writePaste(text),
            .threaded => |d| try d.writePaste(text),
        }
    }

    pub fn getModes(self: *const Driver) SharedModes {
        return switch (self.*) {
            .single => |*d| d.getModes(),
            .threaded => |d| d.getModes(),
        };
    }

    pub fn getTitle(self: *const Driver) []const u8 {
        return switch (self.*) {
            .single => |*d| d.getTitle(),
            .threaded => |d| d.getTitle(),
        };
    }

    pub fn getPid(self: *const Driver) posix.pid_t {
        return switch (self.*) {
            .single => |*d| d.getPid(),
            .threaded => |d| d.getPid(),
        };
    }

    pub fn copySelectionText(self: *Driver, selection: anytype, buf: []u8) usize {
        return switch (self.*) {
            .single => |*d| d.copySelectionText(selection, buf),
            .threaded => |d| d.copySelectionText(selection, buf),
        };
    }
};

allocator: std.mem.Allocator,
atlas: Atlas,

config: *const Config,
background_color: [4]f32,

rasterizer: Rasterizer,
frame_builder: FrameBuilderType,

io: std.Io,
renderer: RendererType,
driver: Driver,

word_classifier: unicode.Classifier,

// Pomodoro state
pomodoro_state: pomodoro.State,
pomodoro_stats: pomodoro.Stats,

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
    comptime config: *const Config,
) !App {
    comptime if (!sameTerminalOption(config.terminal, terminal_option)) {
        @compileError("Config.terminal differs from the root rex_terminal_option");
    };

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

    // apply user's overrides environment values
    for (config.environments) |*envp| {
        try envmap.put(envp.key, envp.value);
    }

    const block: std.process.Environ.Block = switch (native_os) {
        .windows => try envmap.createWindowsBlock(gpa, .{}),
        else => try envmap.createPosixBlock(gpa, .{}),
    };
    defer block.deinit(gpa);

    var pty = try Pty.spawn(.{
        .argv = config.termio.argv,
        .capture_stdout = config.termio.capture_stdout,
        .cols = config.termio.cols,
        .cwd = config.termio.cwd,
        .envp = block.slice,
        .o_flags = config.termio.o_flags,
        .rows = config.termio.rows,
    });
    errdefer pty.close(io);

    pty.waitForSpawn() catch |err| {
        log.err("pty failed to spawn: {}", .{err});
        return err;
    };

    log.debug("termio.pty: {f}", .{pty});

    var win: Window = try .init(config.window.size.width, config.window.size.height, config.window.title);
    errdefer win.deinit();

    var rasterizer: Rasterizer = try .create(gpa, config.font);
    errdefer rasterizer.destroy(gpa);

    var atlas: Atlas = try .create(gpa, config.window.atlas);
    errdefer atlas.destroy();

    var frame_builder: FrameBuilderType = try .init(gpa, .{
        .dim_alpha = config.window.dim_alpha,
        .decoration = config.window.decoration,
    });
    errdefer frame_builder.deinit(gpa);

    atlas.preRasterize(gpa, &rasterizer, .{ .start = 0x20, .end = 0x7F });

    var renderer = try RendererType.init(.{
        .background = config.window.background,
        .font_metrics = rasterizer.metrics,
        .cursor = config.window.cursor,
        .decoration = config.window.decoration,
        .scrollbar = config.window.scrollbar,
        .selection = config.window.selection,
    });
    errdefer renderer.deinit();

    var pomodoro_state: pomodoro.State = .{
        .option = config.pomodoro,
        .phase = .idle,
        .paused = true,
        .waiting = false,
    };

    const pomodoro_report = pomodoro.load(io, dirs.state, pomodoro_state_file);
    if (pomodoro_report.toState()) |state| {
        pomodoro_state.phase = state.phase;
        pomodoro_state.remaining_ms = state.remaining_ms;
        pomodoro_state.tasks_in_cycle = state.tasks_in_cycle;
    }

    var driver: Driver = switch (config.threading.mode) {
        .single => .{ .single = try SingleDriverType.initWithTimeout(gpa, pty, config.theme, config.threading.sync_output_timeout_ms) },
        .multi => .{ .threaded = try ThreadedDriverType.create(gpa, pty, config.theme, config.threading.sync_output_timeout_ms) },
    };
    errdefer driver.deinit(io);

    const background_color = config.theme.background;
    const background_alpha = config.window.background.alpha;

    const classifier = try unicode.Classifier.init(config.selection.classifier);
    const now = std.Io.Clock.Timestamp.now(io, .awake);

    return App{
        .io = io,
        .driver = driver,
        .window = win,
        .background_color = .{ background_color.r, background_color.g, background_color.b, background_alpha },
        .blink = .{ .period_ms = config.blink.half_period },
        .blink_rapid = .{ .period_ms = config.blink.rapid_half_period },
        .dirs = dirs,
        .argv0 = argv0,
        .allocator = gpa,
        .renderer = renderer,
        .rasterizer = rasterizer,
        .atlas = atlas,
        .frame_builder = frame_builder,
        .config = config,
        .font_size = config.font.height,
        .pomodoro_state = pomodoro_state,
        .pomodoro_stats = pomodoro_report.toStats(),
        .frame_buffer_size = .empty,
        .last_frame = now,
        .last_title = now,
        .word_classifier = classifier,
    };
}

pub fn deinit(self: *App, gpa: std.mem.Allocator) void {
    self.renderer.deinit();
    self.frame_builder.deinit(gpa);
    self.atlas.destroy();
    self.rasterizer.destroy(gpa);
    self.window.deinit();
    self.driver.deinit(self.io);

    pomodoro.save(
        self.io,
        &self.pomodoro_stats,
        &self.pomodoro_state,
        self.dirs.state,
        pomodoro_state_file,
    ) catch |err| {
        log.err("failed to save pomodoro stats: {any}", .{err});
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

    start: while (!self.window.windowShouldClose()) {
        const now = std.Io.Clock.Timestamp.now(self.io, .awake);
        const dt = self.last_frame.durationTo(now);
        self.last_frame = now;
        const dt_ms: u64 = @intCast(dt.raw.toMilliseconds());
        const dt_clamped = @min(dt_ms, 500);

        const blink_changed = self.tick(dt_clamped);
        const elapsed = @min(dt_clamped, self.pomodoro_state.remaining_ms);

        // Update stats based on what phase just ended
        switch (self.pomodoro_state.phase) {
            .task => self.pomodoro_stats.focus_ms += elapsed,
            .short_break, .long_break => self.pomodoro_stats.break_ms += elapsed,
            .idle => {},
        }

        if (self.pomodoro_state.tick(dt_clamped)) {
            const was_task = self.pomodoro_state.phase == .task;
            const was_long_break = self.pomodoro_state.phase == .long_break;

            if (self.pomodoro_state.option.transition_mode == .auto) {
                self.pomodoro_state.advance();
            }

            if (was_task) self.pomodoro_stats.onTaskCompleted(self.io);
            if (was_long_break) self.pomodoro_stats.long_breaks_taken += 1;

            pomodoro.save(
                self.io,
                &self.pomodoro_stats,
                &self.pomodoro_state,
                self.dirs.state,
                pomodoro_state_file,
            ) catch {};

            self.ringBell();
            self.last_title = now;
            self.updateWindowTitle();
            self.needs_redraw = true;
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

        if (self.renderer.tick(dt_clamped)) self.needs_redraw = true;

        if (had_data or blink_changed or self.needs_redraw) {
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

    const frame = try self.frame_builder.build(
        self.allocator,
        current_frame,
        atlas,
        &self.rasterizer,
        self.blink_on,
        selection_state,
        null,
    );

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

/// Polls when pty data arrived, else sleeps until the next blink or
/// pomodoro tick or an input event.
fn waitForNextEvent(self: *App, had_data: bool) void {
    if (!had_data) {
        const ms = @min(
            self.blink.remaining(),
            @min(self.blink_rapid.remaining(), self.pomodoro_state.msUntilTick()),
        );
        Window.glfwWaitEventsTimeout(@max(0.001, @as(f64, @floatFromInt(ms)) / 1000.0));
    } else {
        Window.glfwPollEvents();
    }
}

fn resolveAnchor(position: rex.Selection.Position, total_line_scrolled: i64, scrollback_used: i64) ?i64 {
    const delta: i64 = total_line_scrolled - position.captured_scroll_gen;
    // The screen scrolled `delta` lines since the anchor was captured,
    // so the same text now sits `delta` rows higher.
    const anchor_now: i64 = @as(i64, position.row) - delta;

    if (anchor_now < -scrollback_used) return null; // evicted
    return anchor_now;
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
    var buf: [64]u8 = undefined;
    const pomodoro_title = self.pomodoro_state.fmt(&buf);
    const base = self.config.window.title;
    if (pomodoro_title.len == 0) return self.window.setWindowTitle(base);

    var title_buf: [256]u8 = undefined;
    const title = std.fmt.bufPrintZ(&title_buf, "{s}  |  {s}", .{ base, pomodoro_title }) catch base;
    self.window.setWindowTitle(title);
}

/// Rings the X bell at the configured volume, unless the bell is off.
fn ringBell(self: *App) void {
    if (self.config.window.bell == .off) return;
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

    const new_rows: u16 = frame_buffer_height / cell_height;
    const new_cols: u16 = frame_buffer_width / cell_width;
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
        frame_buffer_width,                         frame_buffer_height,
        cell_width,                                 cell_height,
        new_cols,                                   new_rows,
        frame_buffer_width - new_cols * cell_width, frame_buffer_height - new_rows * cell_height,
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
}

fn adjustFontSize(self: *App, delta: i32) void {
    const new_size: i32 = @as(i32, @intCast(self.font_size)) + delta;
    self.setFontSize(@intCast(@max(6, new_size)));
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
        .pomodoro_toggle => {
            const was_idle = self.pomodoro_state.phase == .idle;
            self.pomodoro_state.toggle();
            if (was_idle and self.pomodoro_state.phase == .task) {
                self.pomodoro_stats.sessions += 1;
            }
            self.ringBell();
            self.updateWindowTitle();
        },
        .pomodoro_reset => {
            self.pomodoro_state.reset();
            self.updateWindowTitle();
        },
        .pomodoro_skip => {
            self.pomodoro_state.skip();
            self.ringBell();
            self.updateWindowTitle();
        },
        .pomodoro_auto_transition => {
            self.pomodoro_state.setTransitionMode(
                if (self.pomodoro_state.option.transition_mode == .auto) .manual else .auto,
            );
            self.updateWindowTitle();
        },
        .debug => {
            log.debug("pomodoro_stats={any}", .{self.pomodoro_stats});
        },
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

const charCb: c.GLFWcharfun = struct {
    fn cb(window: ?*c.GLFWwindow, codepoint: c_uint) callconv(.c) void {
        const app: *App = @ptrCast(@alignCast(c.glfwGetWindowUserPointer(window) orelse return));
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

        // App keybindings first; handleAction redraws and resets the
        // selection itself.
        if (rex.input.matchBinding(app.config.keymap, key, mods)) |act| return app.handleAction(act);

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
        const press = (action == c.GLFW_PRESS);

        app.trackMouseButton(button, press);
        const mod_byte = vtModByte(mods);
        const shift_held = (mods & c.GLFW_MOD_SHIFT) != 0;

        const col, const row = app.mouseCellPos(app.mouse_x, app.mouse_y);
        const driver_modes = app.driver.getModes();
        const mouse_reporting = driver_modes.mouse_reporting;
        const frame = app.driver.getFrame();
        const scrollback_used = frame.scrollback_used;

        if (scrollback_used > 0 and app.handleScrollbarClick()) return;

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

    const bar_x: f32 = frame_width - option.width - option.gap;
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
    if (steps == 0) return; // fractional remainder only, not a full step yet
    self.scroll_accumulator_y -= @floatFromInt(steps);

    const col, const row = self.mouseCellPos(self.mouse_x, self.mouse_y);
    const button: u8 = if (steps > 0) 64 else 65;
    const abs_steps: u16 = @intCast(@abs(steps));
    const lines: u16 = abs_steps * @as(u16, @intCast(self.config.scroll.wheel_lines));

    self.driver.sendInput(.{
        .mouse_scroll = .{
            .col = col,
            .row = row,
            .button = button,
            .steps = lines,
        },
    }) catch {};
    self.needs_redraw = true;
}

const scrollCb: c.GLFWscrollfun = struct {
    fn cb(handle: ?*c.GLFWwindow, _: f64, y_offset: f64) callconv(.c) void {
        const app: *App = @ptrCast(@alignCast(c.glfwGetWindowUserPointer(handle) orelse return));

        app.scroll_accumulator_y += y_offset;
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

    const single_driver = try SingleDriverType.init(allocator, pty_single, .graphite);
    var driver_s: Driver = .{ .single = single_driver };
    defer driver_s.deinit(testing.io);

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

    const threaded_driver = try ThreadedDriverType.create(allocator, pty_multi, .graphite, 150);
    var driver_m: Driver = .{ .threaded = threaded_driver };
    defer driver_m.deinit(testing.io);

    try testing.expectEqual(@as(posix.pid_t, -1), driver_m.getPid());
    try testing.expect(!driver_m.getModes().cursor_keys);
    _ = driver_m.getFrame();
}
