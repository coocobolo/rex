const App = @This();

const std = @import("std");
const builtin = @import("builtin");

const log = std.log.scoped(.app);

pub const std_options: std.Options = .{
    .log_level = .debug,
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
const c = Window.c;

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

const pomodoro = rex.builtin.pomodoro;

// Common Power-of-Two Targets to Aim for:
// 4,096 total rows (e.g., 200 rows + 3,896 scrollback)
//
// 8,192 total rows (e.g., 500 rows + 7,692 scrollback)
//
// 16,384 total rows (e.g., 1,000 rows + 15,384 scrollback)

const max_rows: usize = 200;
const max_cols: usize = 220;
const max_scrollback: usize = 3896;
const tab_width: usize = 8;
const emulator_version = "0.1.0";
const emulator_name = "rex";
const max_read_size: usize = std.math.maxInt(u16) - 1;
const scroll_lines = 3;

/// XBell volume, as a percent of the X server bell volume.
const bell_volume: u8 = 100;
const blink_half_period_ms: u64 = 500;
const blink_rapid_half_period_ms: u64 = 250;

const pomodoro_state_file = "pomodoro_stats.bin";

pub const Config = struct {
    blink: struct {
        /// Normal blink half period in ms.
        /// Default: 1Hz.
        half_period: u64 = 500,

        /// Rapid blink half period (ms).
        /// Default: 2Hz.
        rapid_half_period: u64 = 250,
    },
    font: Freetype.FontConfig,
    keymap: []const Binding,
    pomodoro: pomodoro.Option,
    termio: rex.termio.pty.SpawnOption,
    theme: Theme,
    window: struct {
        background: Background.Option,
        bell: enum { on, off } = .on,
        scrollbar: Scrollbar.Option,
        cursor: Cursor.Option,
        selection: renderer_mod.Selection.Option,
        buffer_size: Dimension(u16),
    },
    selection: struct {
        mouse_double_click_interval_ms: f64 = 500,
        classifier: unicode.Classifier.Option,
    },
    /// Stores list of plain environment variable using "KEY=VALUE" format
    environments: []const rex.env.PlainVar,
    terminal: TerminalOption = terminal_option,
};

const terminal_option: TerminalOption = .{
    .max_rows = max_rows,
    .max_cols = max_cols,
    .tab_width = tab_width,
    .name = emulator_name,
    .version = emulator_version,
    .max_scrollback = max_scrollback,
};

pub const FrameBuilderType = FrameBuilder(terminal_option);
pub const RendererType = Renderer(terminal_option);
pub const ScreenType = Screen(terminal_option);
pub const TerminalType = Terminal(terminal_option);

allocator: std.mem.Allocator,
atlas: Atlas,

config: *const Config,
background_color: [4]f32,

rasterizer: Rasterizer,
frame_builder: FrameBuilderType,

io: std.Io,
renderer: RendererType,
terminal: TerminalType,

word_classifier: unicode.Classifier,

pty: Pty,

// Pomodoro state
pomodoro_state: pomodoro.State,
pomodoro_stats: pomodoro.Stats,

// Config state

// Window state

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
scroll_lines_per_tick: u32 = 3,
scrollbar_dragging: bool = false,

// Font state
font_size: u32,
font_size_pending: ?u32 = null,

needs_redraw: bool = true,

// Blink state
blink_on: bool = true,
blink_rapid_on: bool = true,
blink: PeriodicTimer(blink_half_period_ms),
blink_rapid: PeriodicTimer(blink_rapid_half_period_ms),

// Window state
last_frame: std.Io.Clock.Timestamp,
// Frame buffer resize tracking
window_focused: bool = true,
frame_buffer_size: Dimension(u16),
last_title: std.Io.Clock.Timestamp,

// Environment data
dirs: rex.dirs.Application,

const Callback = struct {
    fn getApp(window: ?*Window.GlfwWindow) ?*App {
        const ptr = Window.glfwGetWindowUserPointer(window) orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    pub fn onChar(window: ?*Window.GlfwWindow, codepoint: c_uint) callconv(.c) void {
        const app: *App = getApp(window) orelse return;
        const cp = std.math.cast(u21, codepoint) orelse return;
        if (cp == 0) return;

        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cp, &buf) catch return;
        if (len > 0) {
            app.pty.writeAll(buf[0..len]) catch |err| {
                log.err("charCallback: pty write failed: {}", .{err});
                return;
            };
            app.snapToLiveView();
        }
    }

    pub fn onKey(window: ?*Window.GlfwWindow, key: c_int, _: c_int, action: c_int, mods: c_int) callconv(.c) void {
        const app: *App = getApp(window) orelse return;
        const is_key_down = action == c.GLFW_PRESS or action == c.GLFW_REPEAT;
        if (!is_key_down) return;

        // Application-level keybindings take priority over terminal input.
        if (input.matchBinding(app.config.keymap, key, mods)) |act| {
            app.handleAction(act);
            return;
        }

        // A normal key starts new input and replaces the current selection.
        if (action == c.GLFW_PRESS and !input.isModifierKey(key)) {
            app.selection = .empty;
            app.needs_redraw = true;
        }

        // Terminal key encoding
        const terminal = &app.terminal;
        const context: KeyContext = .{
            .modify_other_keys = app.terminal.mode.modify_other_keys,
            .cursor_keys = terminal.mode.cursor_keys,
            .keypad_app = terminal.mode.keypad_app,
        };

        var buf: [32]u8 = undefined;
        const bytes = rex.input.encodeKey(key, mods, context, &buf);
        if (bytes.len == 0) return;

        app.pty.writeAll(bytes) catch |err| {
            log.err("keyCallback: pty write failed: {}", .{err});
            return;
        };
        app.snapToLiveView();
    }

    pub fn onFrameBufferSize(window: ?*Window.GlfwWindow, w: c_int, h: c_int) callconv(.c) void {
        const app: *App = getApp(window) orelse return;
        app.handleResize(.{ .height = @intCast(h), .width = @intCast(w) });
    }

    pub fn onWindowFocus(window: ?*Window.GlfwWindow, focused: c_int) callconv(.c) void {
        const app: *App = getApp(window) orelse return;
        app.window_focused = (focused != 0);
        if (!app.terminal.mode.focus_events) return;
        const seq = if (focused != 0) "\x1b[I" else "\x1b[O";
        _ = app.pty.writeAll(seq) catch |err| {
            log.err("windowFocusCallback: pty write failed: {}", .{err});
        };
    }
};

/// A periodic timer that toggles a boolean value at each elapsed period.
fn PeriodicTimer(comptime period_ms: u64) type {
    return struct {
        elapsed_ms: u64 = 0,
        const Self = @This();

        pub fn tick(self: *Self, dt_ms: u64) u64 {
            const total = self.elapsed_ms + dt_ms;
            const periods = total / period_ms;
            self.elapsed_ms = total % period_ms;
            return periods;
        }

        pub fn remaining(self: *const Self) u64 {
            if (period_ms == 0) return 0;
            return period_ms - self.elapsed_ms;
        }
    };
}

pub fn init(gpa: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ, comptime config: *const Config) !App {
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
        emulator_name,
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

    // for (block.view().slice) |v| {
    //     log.debug("block | ${s}", .{v});
    // }

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
        return err; // or handle differently
    };

    log.debug("termio.pty: {f}", .{pty});

    var win: Window = try .init(1920, 1080, "rex");
    errdefer win.deinit();

    var rasterizer: Rasterizer = try .create(gpa, config.font);
    errdefer rasterizer.destroy(gpa);

    var atlas: Atlas = try .create(gpa);
    errdefer atlas.destroy();

    var frame_builder: FrameBuilderType = try .init(gpa);
    errdefer frame_builder.deinit(gpa);

    atlas.preRasterize(gpa, &rasterizer, .{ .start = 0x20, .end = 0x7F });

    var renderer = try RendererType.init(.{
        .background = config.window.background,
        .font_metrics = .{
            .ascender = rasterizer.ascender,
            .dimension = .{
                .width = @floatFromInt(rasterizer.cell_width),
                .height = @floatFromInt(rasterizer.cell_height),
            },
        },
        .cursor = config.window.cursor,
        .scrollbar = config.window.scrollbar,
        .selection = config.window.selection,
    });
    errdefer renderer.deinit();

    // const data_home = std.posix.system.getenv("XDG_DATA_HOME") orelse "";
    // const data_home_dir = if (std.mem.len(data_home) > 0)
    //     try std.fmt.allocPrint(gpa, "{s}/rex/pomodoro_stats.bin", .{data_home})
    // else
    //     try std.fmt.allocPrint(
    //         gpa,
    //         "{s}/.local/state/rex/pomodoro_stats.bin",
    //         .{
    //             std.posix.system.getenv("HOME") orelse return error.NoHome,
    //         },
    //     );
    //
    // log.debug("data_home_dir: {s}\n", .{data_home_dir});

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

    var terminal = try TerminalType.create(gpa);
    errdefer terminal.destroy(gpa);

    terminal.setTheme(config.theme);

    const background_color = config.theme.background;
    const background_alpha = config.window.background.alpha;

    const classifier = try unicode.Classifier.init(config.selection.classifier);
    const now = std.Io.Clock.Timestamp.now(io, .awake);

    return App{
        .io = io,
        .pty = pty,
        .window = win,
        .background_color = .{ background_color.r, background_color.g, background_color.b, background_alpha },
        .blink_rapid = blk: {
            if (config.blink.rapid_half_period != blink_rapid_half_period_ms) {
                break :blk PeriodicTimer(config.blink.rapid_half_period){};
            } else {
                break :blk .{};
            }
        },
        .blink = blk: {
            if (config.blink.half_period != blink_half_period_ms) {
                break :blk PeriodicTimer(config.blink.half_period){};
            } else {
                break :blk .{};
            }
        },
        .dirs = dirs,
        .allocator = gpa,
        .terminal = terminal,
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
    self.pty.close(self.io);
    self.terminal.destroy(gpa);

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

    var buffer: [max_read_size]u8 = undefined;

    // FIXME! The main loop is doing three different jobs:
    // 1. Reading the PTY.
    // 2. Parsing terminal output and generating responses.
    // 3. Rendering and handling GLFW input.
    //
    // To separate them, make the PTY side producer/consumer based:
    // GLFW thread
    //  a. receives events keyboard/mouse input
    //  b. sends input, write queue
    //  c. receives immutable terminal snapshots/events
    //  d. renders
    //
    // PTY read thread
    //  a. blocks on PTY read()
    //  b. feeds the terminal vt-parser
    //  c. sends parser respoonses, write queue
    //  d. publishes terminal snapshots/events
    //
    // PTY write thread
    //  a. owns all writes to the PTY master
    start: while (!self.window.windowShouldClose()) {
        const terminal = &self.terminal;

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

            // FIXME! DO NOT blocking persistence in the render loop
            // update data persistence: fire and forget
            pomodoro.save(
                self.io,
                &self.pomodoro_stats,
                &self.pomodoro_state,
                self.dirs.state,
                pomodoro_state_file,
            ) catch {};

            self.window.ringBell(bell_volume);
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
        var child_closed = false;

        drain: while (true) {
            const n = self.pty.readRaw(&buffer) catch |err| switch (err) {
                // Replace this with the would-block error used by your PTY wrapper.
                error.WouldBlock => break :drain,
                // On Linux, a PTY can report EIO when the child side closes.
                error.InputOutput => {
                    child_closed = true;
                    break :drain;
                },
                else => return err,
            };

            if (n == 0) { // EOF.
                child_closed = true;
                break :drain;
            }

            terminal.feed(buffer[0..n]);
            had_data = true;

            if (terminal.events.any()) {
                const events = &terminal.events;
                if (!events.response.isEmpty()) {
                    const resp = events.response.slice();
                    _ = self.pty.writeAll(resp) catch |err| {
                        log.err("drain: pty write failed: {}", .{err});
                    };
                }

                if (events.bell) self.window.ringBell(bell_volume);

                if (events.resize) |resize| {
                    self.pty.resize(
                        resize.rows,
                        resize.cols,
                        self.frame_buffer_size.width,
                        self.frame_buffer_size.height,
                    ) catch |err| {
                        log.err("drain: pty resize failed: {}", .{err});
                    };

                    self.needs_redraw = true;
                }

                if (events.hard_reset) {
                    // Force full recalculation from framebuffer, bypasses the early-return guard
                    self.selection = .empty;
                    self.frame_buffer_size = .empty;
                    self.handleResize(self.window.frameBufferSize(u16));
                }

                if (events.selection_reset) {
                    self.selection = .empty;
                    self.needs_redraw = true;
                }

                self.terminal.events.clear();
            }
        }

        // Only finalize UTF-8 when the PTY is actually closed.
        if (child_closed) {
            terminal.end();
            // FIXME! terminal.end() may flush a pending grapheme or create events,
            // so process those events here too.
        }

        if (self.font_size_pending) |size| {
            self.setFontSize(size);
            self.font_size_pending = null;
        }

        if (self.renderer.tick(dt_clamped)) self.needs_redraw = true;
        var is_frame_dirty = false;

        if (had_data or blink_changed or self.needs_redraw) {
            const rendered = try self.renderFrame();
            if (rendered) {
                self.needs_redraw = false;
                is_frame_dirty = true;
            }
        }

        self.waitForNextEvent(had_data, is_frame_dirty);
        self.flushScroll();

        if (child_closed) break :start;
    }
}

fn renderFrame(self: *App) !bool {
    const terminal = &self.terminal;
    const atlas = &self.atlas;
    const screen = self.terminal.active();

    const cursor_color: ?[3]u8 = if (terminal.cursor_color) |color| .{ color.r, color.g, color.b } else null;
    const selection_state = self.buildSelectionState();

    const frame = try self.frame_builder.build(
        self.allocator,
        screen,
        atlas,
        &self.rasterizer,
        self.blink_on,
        selection_state,
        cursor_color,
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

fn waitForNextEvent(self: *App, had_data: bool, frame_dirty: bool) void {
    if (!had_data) {
        const ms = @min(
            self.blink.remaining(),
            @min(self.blink_rapid.remaining(), self.pomodoro_state.msUntilTick()),
        );
        Window.glfwWaitEventsTimeout(@max(0.001, @as(f64, @floatFromInt(ms)) / 1000.0));
    } else {
        _ = frame_dirty; // both branches poll
        Window.glfwPollEvents();
    }
}

fn resolveAnchor(position: rex.Selection.Position, total_line_scrolled: i64, scrollback_used: i64) ?i64 {
    const delta: i64 = total_line_scrolled - position.captured_scroll_gen;
    // Why anchor_now = pos.row - delta (not + delta) Think through it directionally: a full-screen
    // scroll-up (delta > 0, content moves up, meaning what used to be at the bottom of the active area is now further down in scrollback relative to the live bottom) means a previously-captured anchor now needs to shift further into positive "further back" territory relative to the live view... actually the cleanest way to verify this is empirically once you wire it up — scroll up several times without moving the mouse mid-drag, and confirm the highlighted rows stay locked onto the same text rather than sliding by count rows per scroll event. If it slides in the wrong direction, flip the sign (anchor_now = pos.row + delta). I don't have a running instance of your code to test this against, so treat the sign here as a testable hypothesis, not a guarantee — verify with the reverse-scroll case too (CSI T / RI), since that's the specific case this fix is for and it's the one most likely to reveal a sign error if there is one.
    const anchor_now: i64 = @as(i64, position.row) - delta;

    if (anchor_now < -scrollback_used) return null; // evicted
    return anchor_now;
}

fn buildSelectionState(self: *App) ?SelectionState {
    if (self.selection.phase == .none) return null;

    const is_primary = self.terminal.active_buffer == .primary;
    const screen = self.terminal.active();

    const active_rows: i64 = @intCast(screen.active_rows);
    const active_cols: u16 = screen.active_cols;
    const total_lines_scrolled = screen.total_lines_scrolled;
    const scrollback_used = screen.scrollbackUsedAs(i64);

    const start_anchor = resolveAnchor(self.selection.range.start, total_lines_scrolled, scrollback_used) orelse return null;
    const end_anchor = resolveAnchor(self.selection.range.end, total_lines_scrolled, scrollback_used) orelse return null;
    const viewport_offset = screen.viewportOffsetAs(i64);

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
        if (self.terminal.selection_foreground) |fg| break :blk fg.toArray();
        if (is_primary) break :blk self.config.theme.selection_foreground.toArray();
        break :blk null;
    };

    const background = blk: {
        if (self.terminal.selection_background) |bg| break :blk bg.toArray();
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
    var title_buf: [128]u8 = undefined;
    const title =
        if (pomodoro_title.len > 0)
            std.fmt.bufPrintZ(&title_buf, "rex  |  {s}", .{pomodoro_title}) catch return
        else
            std.fmt.bufPrintZ(&title_buf, "rex", .{}) catch return;

    self.window.setWindowTitle(title);
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

    if (self.terminal.mode.column_132) {
        const deccolm_cols = self.terminal.active().active_cols;
        self.terminal.resize(new_rows, deccolm_cols);
        self.pty.resize(new_rows, deccolm_cols, frame_buffer_width, frame_buffer_height) catch {};
    } else {
        self.terminal.resize(new_rows, new_cols);
        self.pty.resize(new_rows, new_cols, frame_buffer_width, frame_buffer_height) catch {};
    }

    log.debug("fb={}x{} cell={}x{} → {}cols {}rows (unused: {}px right, {}px bottom)", .{
        frame_buffer_width,                         frame_buffer_height,
        cell_width,                                 cell_height,
        new_cols,                                   new_rows,
        frame_buffer_width - new_cols * cell_width, frame_buffer_height - new_rows * cell_height,
    });

    gl.viewport(0, 0, @intCast(frame_buffer_width), @intCast(frame_buffer_height));

    self.terminal.active().dirty_rows = .full;
    self.terminal.active().bump();
    self.selection = .empty; // clear selection on resize
    self.needs_redraw = true;
}

fn pasteFromClipboard(self: *App) void {
    const raw = c.glfwGetClipboardString(self.window.handle) orelse return;
    const text: []const u8 = std.mem.span(raw);

    log.debug("paste text: 0x{x} | '{s}'", .{ text, text });
    log.debug("terminal modes: {any}", .{self.terminal.mode});
    log.debug("active screen buffer modes: {any}", .{self.terminal.active().mode});

    self.selection = .empty;
    self.terminal.active().dirty_rows = .full;
    self.terminal.active().bump();
    self.needs_redraw = true;

    // If the PTY is O_NONBLOCK and somehow the PTY buffer is full mid-paste,
    // the second or third write (text or \x1b[201~) can fail with WouldBlock,
    // leaving the terminal in a broken state (paste started but never closed).
    // The closing bracket \x1b[201~ is especially critical, without it, the
    // application receiving the paste (e.g., Neovim) will treat all subsequent
    // keyboard input as pasted text.
    if (self.terminal.mode.bracketed_paste) {
        const paste_start = "\x1b[200~";
        const paste_end = "\x1b[201~";
        var iovecs = [_]posix.iovec_const{
            .{ .base = paste_start, .len = 6 },
            .{ .base = text.ptr, .len = text.len },
            .{ .base = paste_end, .len = 6 },
        };

        self.pty.writevAll(&iovecs) catch |err| {
            log.err("pasteFromClipboard: pty write failed: {}", .{err});
            self.snapToLiveView();
            return;
        };

        // _ = self.pty.write("\x1b[200~") catch |err| {
        //     log.err("pasteFromClipboard: pty write failed: {}", .{err});
        //     self.snapToLiveView();
        //     return;
        // };
        //
        // _ = self.pty.write(text) catch |err| {
        //     log.err("pasteFromClipboard: pty write failed: {}", .{err});
        //     // still try to close the bracket
        // };
        //
        // _ = self.pty.write("\x1b[201~") catch |err| {
        //     log.err("pasteFromClipboard: pty write failed: {}", .{err});
        // };
    } else {
        // Strip NUL bytes; convert \n to \r outside bracketed mode
        var tmp: [4096]u8 = undefined;
        var out_len: usize = 0;
        for (text) |ch| {
            if (ch == 0) continue;
            tmp[out_len] = if (ch == '\n') '\r' else ch;
            out_len += 1;
            if (out_len == tmp.len) {
                _ = self.pty.writeAll(tmp[0..out_len]) catch |err| {
                    log.err("pasteFromClipboard: pty write failed: {}", .{err});
                    break; // don't continue dropping chunks
                };
                out_len = 0;
            }
        }

        if (out_len > 0) {
            _ = self.pty.writeAll(tmp[0..out_len]) catch |err| {
                log.err("pasteFromClipboard: pty write failed: {}", .{err});
            };
        }
    }

    self.snapToLiveView();
}

fn setFontSize(self: *App, new_size: u32) void {
    const clamped_size: u32 = @max(self.config.font.min_size, @min(new_size, self.config.font.max_size));
    if (clamped_size == self.font_size) return;

    // self.config.font.height = clamped;
    var font_config = self.config.font;
    font_config.height = clamped_size;
    // Create new rasterizer BEFORE destroying old one (avoid dangling ptr on failure)
    const new_rasterizer = Rasterizer.create(self.allocator, font_config) catch |err| {
        log.err("setFontSize: rasterizer.create failed: {}", .{err});
        return;
    };
    self.rasterizer.destroy(self.allocator);
    self.rasterizer = new_rasterizer;
    self.renderer.cell_dimension = .{
        .width = @floatFromInt(self.rasterizer.cell_width),
        .height = @floatFromInt(self.rasterizer.cell_height),
    };
    self.renderer.cell_ascender = self.rasterizer.ascender;

    // Invalidate atlas, all cached glyphs are wrong size now
    self.atlas.invalidate();

    // Force full rebuild next frame via generation bump
    self.terminal.primary.dirty_rows = .full;
    self.terminal.alternate.dirty_rows = .full;
    self.terminal.primary.bump();
    self.terminal.alternate.bump();

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
                self.terminal.active().bump();
            }
        },
        .scroll_up => {
            self.terminal.active().scrollViewportBack(scroll_lines);
            self.needs_redraw = true;
        },
        .scroll_down => {
            self.terminal.active().scrollViewportForward(scroll_lines);
            self.needs_redraw = true;
        },
        .increase_font_size => {
            const target = (self.font_size_pending orelse self.font_size) + 2;
            self.font_size_pending = @min(target, self.config.font.max_size);
            // self.font_size_pending = @min(target, MAX_FONT_SIZE);
        },
        .decrease_font_size => {
            const current = self.font_size_pending orelse self.font_size;
            const target = if (current > 2) current - 2 else 6;
            // self.font_size_pending = @max(target, MIN_FONT_SIZE);
            self.font_size_pending = @max(target, self.config.font.min_size);
        },
        .reset_font_size => {
            // reset_font_size doesn't repeat on key hold (it's idempotent),
            // but it still benefits from going through font_size_pending
            // it keeps the flush path consistent and avoids calling setFontSize
            // twice if somehow both reset and increase fire in the same frame.
            self.font_size_pending = self.config.font.height;
        },
        .new_window => {
            var buf: [std.fs.max_path_bytes]u8 = undefined;

            const exe_n = std.process.executablePath(self.io, &buf) catch return;
            if (exe_n == 0) return;
            const exe_path = buf[0..exe_n];

            log.debug("exe_path: {s}", .{exe_path});

            // _ = std.process.spawn(self.io, .{
            //     .argv = &.{exe_path},
            //     .stderr = .ignore,
            //     .stdout = .ignore,
            //     .stdin = .ignore,
            // }) catch return;

            // const posix = std.posix;
            //
            // const pid = posix.system.fork();
            //
            // if (pid == 0) {
            //     // First child
            //     _ = posix.system.setsid(); // new session, detach from terminal
            //
            //     // const pid2 = posix.system.fork();
            //
            //     // if (pid2 == 0) {
            //     //     // Grandchild: independent process
            //     //
            //
            //     log.debug("exe: {s}\n", .{buf[0..exe_n]});
            //     _ = std.process.spawn(self.io, .{
            //         .argv = &.{buf[0..exe_n]},
            //         .stdin = .ignore,
            //         .stdout = .ignore,
            //         .stderr = .ignore,
            //         .pgid = 0,
            //     }) catch return;
            //
            //     posix.system.exit(0);
            // }

            // TODO
            // open new independent "term emulator"
        },
        .pomodoro_toggle => {
            const was_idle = self.pomodoro_state.phase == .idle;
            self.pomodoro_state.toggle();
            if (was_idle and self.pomodoro_state.phase == .task) {
                self.pomodoro_stats.sessions += 1;
            }
            self.window.ringBell(bell_volume);
            self.updateWindowTitle();
        },
        .pomodoro_reset => {
            self.pomodoro_state.reset();
            self.updateWindowTitle();
        },
        .pomodoro_skip => {
            self.pomodoro_state.skip();
            self.window.ringBell(bell_volume);
            self.updateWindowTitle();
        },
        .pomodoro_auto_transition => {
            self.pomodoro_state.setTransitionMode(
                if (self.pomodoro_state.option.transition_mode == .auto) .manual else .auto,
            );
            self.updateWindowTitle();
        },
        .debug => {
            // FIXME display pomodoro stats
            log.debug("pomodoro_stats={any}", .{self.pomodoro_stats});
        },
        .send_to_pty => |seq| {
            _ = self.pty.writeAll(seq) catch |err| {
                log.err("handleAction: send to pty write failed: {}", .{err});
            };
        },
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
    if (self.terminal.active_buffer == .primary and self.terminal.active().viewportReset()) {
        self.selection = .empty;
    }

    // A key was written to the PTY. The terminal may produce output,
    // and the current view may need repainting.
    self.needs_redraw = true;
}

const charCb: c.GLFWcharfun = struct {
    fn cb(window: ?*c.GLFWwindow, codepoint: c_uint) callconv(.c) void {
        const app: *App = @ptrCast(@alignCast(c.glfwGetWindowUserPointer(window) orelse return));
        app.selection = .empty;
        app.needs_redraw = true;

        // codepoint is c_uint (u32). utf8Encode takes u21.
        // If GLFW ever passes a value > 0x10FFFF (invalid Unicode),
        // @intCast panics in debug mode.
        const cp = std.math.cast(u21, codepoint) orelse return;
        if (cp == 0) return;

        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cp, &buf) catch return;
        if (len > 0) {
            app.pty.writeAll(buf[0..len]) catch |err| {
                log.err("charCallback: pty write failed: {}", .{err});
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

        // app-level keybindings
        // the handleAction does the bump and selection reset state
        if (rex.input.matchBinding(app.config.keymap, key, mods)) |act| return app.handleAction(act);

        // Don't clear selection when a bare modifier key is pressed —
        // the user may be building a modifier+key combination (e.g. Ctrl+Shift+C to copy).
        const is_modifier = switch (key) {
            c.GLFW_KEY_LEFT_SHIFT, c.GLFW_KEY_RIGHT_SHIFT, c.GLFW_KEY_LEFT_CONTROL, c.GLFW_KEY_RIGHT_CONTROL, c.GLFW_KEY_LEFT_ALT, c.GLFW_KEY_RIGHT_ALT, c.GLFW_KEY_LEFT_SUPER, c.GLFW_KEY_RIGHT_SUPER => true,
            else => false,
        };
        if (!is_modifier) {
            app.selection = .empty;
            app.needs_redraw = true;
        }

        // Terminal key encoding
        const terminal = &app.terminal;
        const context: KeyContext = .{
            .modify_other_keys = app.terminal.mode.modify_other_keys,
            .cursor_keys = terminal.mode.cursor_keys,
            .keypad_app = terminal.mode.keypad_app,
        };

        var buf: [32]u8 = undefined;
        const bytes = rex.input.encodeKey(key, mods, context, &buf);
        if (bytes.len > 0) {
            app.pty.writeAll(bytes) catch |err| {
                log.err("keyCallback: pty write failed: {}", .{err});
                return;
            };
            app.snapToLiveView();
        }
    }
}.cb;

fn mouseCellPos(self: *App, xpos: f32, ypos: f32) struct { u16, u16 } {
    const cw, const ch = .{ self.rasterizer.cell_width, self.rasterizer.cell_height };
    const col: u16 = @intCast(@min(@as(u32, @intFromFloat(@max(0, xpos))) / cw, max_cols - 1));
    const row: u16 = @intCast(@min(@as(u32, @intFromFloat(@max(0, ypos))) / ch, max_rows - 1));
    return .{ col, row };
}

fn copySelectionToClipboard(self: *App) void {
    const screen = self.terminal.active();
    const total_lines_scrolled = screen.total_lines_scrolled;
    const scrollback_used = screen.scrollbackUsedAs(i64);

    // Resolve raw anchors -> drift-corrected anchors (relative to viewport_offset == 0),
    // bailing out if either endpoint has been evicted from retained scrollback.
    const start_anchor = resolveAnchor(self.selection.range.start, total_lines_scrolled, scrollback_used) orelse return;
    const end_anchor = resolveAnchor(self.selection.range.end, total_lines_scrolled, scrollback_used) orelse return;

    const start_col = self.selection.range.start.col;
    const end_col = self.selection.range.end.col;

    // Ordering by raw stored anchor (pre-resolve) is equivalent to ordering by
    // resolved anchor here, since drift is a uniform shift applied identically
    // to both endpoints. Using the *resolved* values directly for the ordering
    // check too, so there's no risk of divergence if that assumption ever breaks.
    const lo_anchor, const lo_col, const hi_anchor, const hi_col = blk: {
        if (start_anchor < end_anchor or (start_anchor == end_anchor and start_col <= end_col)) {
            break :blk .{ start_anchor, start_col, end_anchor, end_col };
        } else {
            break :blk .{ end_anchor, end_col, start_anchor, start_col };
        }
    };

    const active_rows: i64 = @intCast(screen.active_rows);

    // Clamp to what's actually retrievable right now, purely in anchor space.
    // Live bottom is anchor == active_rows - 1; deepest retained scrollback
    // line is anchor == -scrollback_used. No viewport_offset involved at all.
    const clamped_lo: i64 = std.math.clamp(lo_anchor, -scrollback_used, active_rows - 1);
    const clamped_hi: i64 = std.math.clamp(hi_anchor, -scrollback_used, active_rows - 1);
    if (clamped_hi < clamped_lo) return; // nothing retained to copy

    var buf: [max_read_size]u8 = undefined;
    var pos: usize = 0;

    var anchor_row: i64 = clamped_lo;
    while (anchor_row <= clamped_hi) : (anchor_row += 1) {
        var col_start: usize = if (anchor_row == clamped_lo) lo_col else 0;
        const col_end: usize = if (anchor_row == clamped_hi) hi_col else @max(screen.active_cols, 1) - 1;

        // If col_start lands on a placeholder, back up to the real cell
        if (col_start > 0) {
            const maybe_placeholder = screen.cellAtAnchor(anchor_row, col_start);
            if (maybe_placeholder.kind == .wide_right) col_start -= 1;
        }

        // save buffer offset at the start of this row
        const row_start = pos;

        for (col_start..col_end + 1) |col| {
            const cell = screen.cellAtAnchor(anchor_row, col);
            if (pos + 4 > buf.len) break;

            switch (cell.kind) {
                .wide_right => continue, // placeholder — skip
                .empty => {
                    // blank cell — emit space so trailing-space trim works
                    buf[pos] = ' ';
                    pos += 1;
                },
                .narrow, .wide_left => {
                    const cp: u21 = std.math.cast(u21, cell.codepoint) orelse ' ';
                    const len = std.unicode.utf8Encode(cp, buf[pos..][0..4]) catch continue;
                    pos += len;
                },
                .grapheme, .grapheme_wide => {
                    const cps = screen.getGrapheme(cell.codepoint) orelse continue;
                    for (cps) |cp| {
                        const len = std.unicode.utf8Encode(cp, buf[pos..][0..4]) catch continue;
                        pos += len;
                    }
                },
                .shaped => {}, // not yet implemented, skip
            }
        }

        while (pos > row_start and buf[pos - 1] == ' ') pos -= 1;

        if (anchor_row < clamped_hi and pos < buf.len - 1) {
            buf[pos] = '\n';
            pos += 1;
        }
    }

    if (pos == 0) return;
    if (pos >= buf.len) pos = buf.len - 1;
    buf[pos] = 0; // null-terminate for GLFW
    c.glfwSetClipboardString(self.window.handle, buf[0..pos :0].ptr);
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

fn fullRedraw(self: *App) void {
    self.terminal.active().dirty_rows = .full;
    self.terminal.active().bump();
    self.needs_redraw = true;
}

fn handleSelectionPress(self: *App, row: u16, col: u16, mods: c_int) void {
    const terminal = &self.terminal;
    const screen = terminal.active();
    const viewport_offset = screen.viewportOffsetAs(i32);
    const anchor = @as(i32, row) - viewport_offset;
    const scroll_gen = screen.total_lines_scrolled;
    const scrollback_used = screen.scrollbackUsedAs(i64);

    self.selection.kind = self.detectMouseClickKind(anchor, col, mods, scroll_gen, scrollback_used);
    self.selection.phase = .dragging;
    self.selection.beginPress(screen, &self.word_classifier, anchor, col, scroll_gen);

    self.fullRedraw();
}

fn handleSelectionRelease(self: *App) void {
    if (self.selection.phase == .dragging) {
        log.debug("release: dragged={} phase_before={t}", .{ self.selection.dragged(), self.selection.phase });
        log.debug("release: start={} end={} dragged={}", .{ self.selection.range.start, self.selection.range.end, self.selection.dragged() });
        self.selection.phase = if (self.selection.dragged()) .selected else .none;
    }
}

fn reportMouseButton(self: *App, col: u16, row: u16, button: c_int, mod_byte: u8, press: bool) void {
    const held = mouseButtonOf(button) orelse return;
    self.mouse_report_col = col;
    self.mouse_report_row = row;
    self.terminal.sendMouse(col, row, @intFromEnum(held), mod_byte, press);
    self.pty.writeAll(self.terminal.events.response.slice()) catch |err| {
        log.err("mouseButtonCallback: pty write failed: {}", .{err});
    };
    self.terminal.events.response.clear();
}

const mouseButtonCb: c.GLFWmousebuttonfun = struct {
    fn cb(handle: ?*c.GLFWwindow, button: c_int, action: c_int, mods: c_int) callconv(.c) void {
        const app: *App = @ptrCast(@alignCast(c.glfwGetWindowUserPointer(handle) orelse return));
        const press = (action == c.GLFW_PRESS);

        app.trackMouseButton(button, press);
        const mod_byte = vtModByte(mods);
        const shift_held = (mods & c.GLFW_MOD_SHIFT) != 0;

        const col, const row = app.mouseCellPos(app.mouse_x, app.mouse_y);
        const terminal = &app.terminal;
        const mouse_reporting = terminal.mode.isMouseReporting();
        const scrollback_used = terminal.active().scrollbackUsedAs(i64);

        if (scrollback_used > 0 and app.handleScrollbarClick()) return;

        const is_primary = terminal.active_buffer == .primary;
        log.debug("mouse_reporting={} shift_held={} is_primary={}", .{ mouse_reporting, shift_held, is_primary });
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
    self.terminal.active().bump();
    self.needs_redraw = true;
    return true;
}

fn handleScrollbarClick(self: *App) bool {
    const screen = &self.terminal.primary;
    // if (!screen.scrollbackIsUsed()) return false;

    // Scrollbar hit test
    const frame_width: f32 = @floatFromInt(self.frame_buffer_size.width);
    const frame_height: f32 = @floatFromInt(self.frame_buffer_size.height);
    const mouse_x = self.mouse_x;
    const mouse_y = self.mouse_y;
    const option = self.config.window.scrollbar;

    const bar_x: f32 = frame_width - option.width - option.gap;

    // click was not on the scrollbar
    if (mouse_x < bar_x) return false;

    const active_rows: f32 = @floatFromInt(screen.active_rows);
    const scrollback_used: f32 = @floatFromInt(screen.scrollback_used);
    const viewport_offset: f32 = @floatFromInt(screen.viewport_offset);

    const total_rows = active_rows + scrollback_used;
    const thumb_h = frame_height * active_rows / total_rows;
    const track_h = frame_height - thumb_h;

    // If viewport_offset somehow exceeds scrollback_used
    // (e.g., a resize race), scroll_frac > 1.0 and thumb_top_y goes negative.
    const scroll_frac = std.math.clamp(viewport_offset / scrollback_used, 0.0, 1.0);
    const thumb_top_y = (1.0 - scroll_frac) * track_h;
    const thumb_bottom_y = thumb_top_y + thumb_h;

    // Click-in-track behavior
    // If the user clicks in the track area (below or above the thumb),
    // scrollbar_drag_offset_y will be larger than thumb_h. During the
    // subsequent drag, adjusted_y = mouse_y - drag_offset_y will be
    // negative or very large, causing the viewpot to just to the top or bottom..
    // The UX needs to handle it properly, will not crash but, either jump
    // the thumb to the click position or page-scroll.

    // Two option:
    // Jump thumb to click position or Page scrolling.
    // i think the first option seems reasonable, since
    // the thumb immediately centers on the click point, and drag continues naturally.
    if (mouse_y >= thumb_top_y and mouse_y <= thumb_bottom_y) {
        // Click landed on the thumb, drag from where the user clicked
        self.scrollbar_drag_offset_y = mouse_y - thumb_top_y;
    } else {
        // Click landed in the track, jump thumb center to click position
        const new_thumb_top = std.math.clamp(mouse_y - thumb_h / 2.0, 0.0, track_h);
        const new_frac = 1.0 - (new_thumb_top / track_h);
        const target: f32 = @round(new_frac * scrollback_used);
        screen.viewport_offset = @intFromFloat(@min(target, scrollback_used));
        screen.dirty_rows = .full;

        // Set drag offset so subsequent drag feels natural (dragging from thumb center)
        // HACK: after a track click, set scrollbar_drag_offset_y = thumb_h / 2.0 (center of thumb).
        // This means handleScrollbarDrag's formula adjusted_y = mouse_y - drag_offset_y will keep
        // the thumb centered under the cursor as the user drags, which feels natural.
        self.scrollbar_drag_offset_y = thumb_h / 2.0;
    }

    // Record where within the thumb the user clicked
    self.scrollbar_drag_offset_y = mouse_y - thumb_top_y;
    self.scrollbar_dragging = true;
    self.terminal.active().bump();
    self.needs_redraw = true;
    return true;
}

fn handleScrollbarDrag(self: *App) bool {
    if (!self.scrollbar_dragging) return false;

    const buffer_height: f32 = @floatFromInt(self.frame_buffer_size.height);
    const screen = &self.terminal.primary;
    const active_rows: f32 = @floatFromInt(screen.active_rows);
    const scrollback_used: f32 = @floatFromInt(screen.scrollback_used);
    const total_rows = active_rows + scrollback_used;
    const thumb_h = buffer_height * active_rows / total_rows;
    const track_h = buffer_height - thumb_h;
    if (track_h == 0) return true; // consumed but no-op

    const adjusted_y = self.mouse_y - self.scrollbar_drag_offset_y;
    const raw_frac = std.math.clamp(adjusted_y / track_h, 0.0, 1.0);
    const scroll_frac = 1.0 - raw_frac;
    const target = @round(scroll_frac * scrollback_used);

    // no-op, dont need to redraw if nothing changes
    const prev_viewport_offset: f32 = @floatFromInt(screen.viewport_offset);
    if (target == prev_viewport_offset) return true;

    screen.viewport_offset = @intFromFloat(@min(target, scrollback_used));
    screen.dirty_rows = .full;
    screen.bump(); // keep: marks primary viewport as dirty
    self.terminal.active().bump(); // add: triggers redraw of displayed screen
    self.needs_redraw = true;
    return true;
}

fn updateScrollbarHover(self: *App) void {
    const sb = &self.renderer.scrollbar;
    const new_hover = blk: {
        if (self.terminal.primary.scrollback_used == 0) break :blk false;
        const fb_w: f32 = @floatFromInt(self.frame_buffer_size.width);
        const bar_x = fb_w - sb.option.hover_width - sb.option.gap;
        break :blk self.mouse_x >= bar_x;
    };

    if (new_hover == sb.hover) return;
    sb.hover = new_hover;
    self.terminal.active().bump();
    self.needs_redraw = true;
}

fn flushScroll(self: *App) void {
    if (self.scroll_accumulator_y == 0) return;

    const steps: i32 = @intFromFloat(self.scroll_accumulator_y);
    if (steps == 0) return; // fractional remainder only, not a full step yet
    self.scroll_accumulator_y -= @floatFromInt(steps);

    const terminal = &self.terminal;
    if (terminal.mode.mouse_tracking.reportsWheel()) {
        const col, const row = self.mouseCellPos(self.mouse_x, self.mouse_y);

        // Type of scroll
        // Scroll up   = button 64
        // Scroll down = button 65
        const button: u8 = if (steps > 0) 64 else 65;

        var i: u32 = 0;
        while (i < @abs(steps)) : (i += 1) {
            terminal.sendMouse(col, row, button, 0, true);
            _ = self.pty.writeAll(terminal.events.response.slice()) catch |err| {
                log.err("flushScroll: pty write failed: {}", .{err});
            };
            terminal.events.response.clear();
        }

        return;
    }

    if (terminal.active_buffer == .alternate) return;

    // NOTE both viewport back and forward call already
    // set the dirty_rows to .full and bump, no need for that.

    const prev_offset = terminal.active().viewport_offset;
    const lines: u32 = @as(u32, @intCast(@abs(steps))) * self.scroll_lines_per_tick;

    if (steps > 0) {
        terminal.active().scrollViewportBack(lines);
    } else {
        terminal.active().scrollViewportForward(lines);
    }

    if (terminal.active().viewport_offset != prev_offset) {
        self.needs_redraw = true;
    }
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
    self.terminal.sendMouseMotion(col, row, self.mouse_held.dragged(), 0);
    if (self.terminal.events.response.isEmpty()) return;
    _ = self.pty.writeAll(self.terminal.events.response.slice()) catch |err| {
        log.err("sendMouseMotion: pty write failed: {}", .{err});
    };
    self.terminal.events.response.clear();
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

        const terminal = &app.terminal;
        const screen = terminal.active();
        const mouse_reporting = terminal.mode.isMouseReporting();

        // A shift-drag selects text even while the host tracks the mouse.
        if (mouse_reporting and app.selection.phase != .dragging) {
            app.sendMouseMotion(col, row);
            return;
        }

        const left_held = app.mouse_held.isHeld(.left);

        if (left_held and app.selection.phase == .dragging) {
            if (terminal.active_buffer != .primary) return;

            const anchor: i32 = @as(i32, row) - screen.viewportOffsetAs(i32);
            const scroll_gen = screen.total_lines_scrolled;

            switch (app.selection.kind) {
                .character, .block => {
                    _ = app.selection.range.set(.end, .{ .row = anchor, .col = col, .captured_scroll_gen = scroll_gen });
                },
                .word => {
                    const join_option = app.word_classifier.option.join;
                    // Union the drag-point's word bounds with the ORIGINAL click's word
                    // bounds, extending outward from the click, not re-snapping independently.
                    const left, const right = screen.wordsBoundsAt(&app.word_classifier, anchor, col, join_option);

                    const click_anchor = resolveAnchor(
                        app.mouse_last_click_pos,
                        scroll_gen,
                        screen.scrollbackUsedAs(i64),
                    ) orelse return; // click row evicted from scrollback, bail, don't extend a dead selection
                    const click_col = app.mouse_last_click_pos.col;
                    const click_left, const click_right = screen.wordsBoundsAt(&app.word_classifier, click_anchor, click_col, join_option);

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
                    const last_col = screen.active_cols - 1;
                    const click_anchor = resolveAnchor(
                        app.mouse_last_click_pos,
                        scroll_gen,
                        screen.scrollbackUsedAs(i64),
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

            terminal.active().dirty_rows = .full;
            terminal.active().bump();
            app.needs_redraw = true;
        }
    }
}.cb;

const windowFocusCb: c.GLFWwindowfocusfun = struct {
    fn cb(handle: ?*c.GLFWwindow, focused: c_int) callconv(.c) void {
        const app: *App = @ptrCast(@alignCast(c.glfwGetWindowUserPointer(handle) orelse return));
        app.window_focused = (focused != 0);
        if (!app.terminal.mode.focus_events) return;
        const seq = if (focused != 0) "\x1b[I" else "\x1b[O";
        _ = app.pty.writeAll(seq) catch |err| {
            log.err("windowFocusCallback: pty write failed: {}", .{err});
        };
    }
}.cb;

const framebufferSizeCb: c.GLFWframebuffersizefun = struct {
    fn cb(handle: ?*c.GLFWwindow, w: c_int, h: c_int) callconv(.c) void {
        const app: *App = @ptrCast(@alignCast(c.glfwGetWindowUserPointer(handle) orelse return));
        app.handleResize(.{ .height = @intCast(h), .width = @intCast(w) });
    }
}.cb;
