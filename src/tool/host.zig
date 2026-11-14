//! The process behind a tool window (ADR 0008): one window that draws only
//! the UI kit, with no terminal in it. The host owns the window, GL, the UI
//! font, the painter and the event loop; a tool is a surface in the kit's
//! model (ADR 0009) handed to `run` as a type.
//!
//! A tool declares `name` (the lock file), `title`, `node_max`, `line_max`,
//! a `State`, `update(*State, Event) bool` and
//! `view(*const State, *Tree, *const Theme) kit.tree.Error!void`. `State`
//! has an `empty` value, or the tool declares `init(Context) !State` and
//! `deinit(*State)`.
//!
//! The loop sleeps in `glfwWaitEvents` and draws only when `update` reports
//! a change, the framebuffer is resized or the scale changes, so an idle
//! window causes no wakeups. A tool may declare `wait(*const State) ?f64`,
//! the most seconds to sleep (null: until an event), and
//! `wake(*State) bool`, called after every sleep, true to redraw. One
//! instance of each tool runs at a time: a second start finds the lock
//! taken and exits with a message.
//!
//! Imports stay on leaf files: nothing here may reach `term/` or the driver
//! (ADR 0009 point 8).

const std = @import("std");
const Allocator = std.mem.Allocator;

const c = @import("glfw");

const dirs = @import("../dirs/root.zig");
const font_files = @import("../config/font_files.zig");
const config_defaults = @import("../config/default.zig");
const config_paths = @import("../config/paths.zig");
const Loaded = @import("../config/Loaded.zig");
const Config = @import("../config/Config.zig");
const kit = @import("../kit/root.zig");
const input_key = @import("../input/key.zig");
const gl = @import("../renderer/gl.zig");
const glfw_key = @import("../renderer/glfw_key.zig");
const Atlas = @import("../renderer/Atlas.zig");
const KitPainter = @import("../renderer/KitPainter.zig");
const Window = @import("../renderer/Window.zig");
const KitFont = @import("../freetype/KitFont.zig");

const Theme = kit.Theme;
const Tree = kit.tree.Tree;
const Id = kit.tree.Id;

const log = std.log.scoped(.tool);

const window_width: u16 = 960;
const window_height: u16 = 600;
/// Narrow enough for a phone-sized layout, still wide enough for a pane.
const window_min_width: u16 = 360;
const window_min_height: u16 = 240;

/// What the host tells a tool. Pointer positions are already resolved to
/// the node under them, from the last frame drawn.
pub const Event = union(enum) {
    /// The window is this many logical pixels wide and high now. Sent
    /// before the first frame and before every frame after a resize.
    size: struct { width: f32, height: f32 },
    /// The pointer moved onto the node with this id; `.none` for no node or
    /// off the window. `x` and `y` are in logical pixels (`-1` when off).
    pointer: struct { id: Id, x: f32 = 0, y: f32 = 0 },
    /// The left button went down on the node with this id.
    press: Id,
    /// The left button was let go, wherever the pointer is.
    release,
    key: KeyPress,
    /// A printable Unicode codepoint typed on the keyboard.
    char: u21,
    /// The wheel turned: `dy` logical pixels down (negative: up). `max` is
    /// how far the view's scroll region could move up when last laid out
    /// (`Tree.scroll_max`), so the tool can keep its offset in 0..max.
    scroll: struct { dy: f32, max: f32 },
};

/// Logical pixels one wheel notch scrolls.
pub const scroll_step = 48;

/// What a tool's `init` receives. Everything borrowed lives until the
/// tool's `deinit` returns.
/// Main-thread clipboard access decoupled from `Window` so tool state can
/// be unit-tested without a GLFW window.
pub const Clipboard = struct {
    ctx: ?*anyopaque = null,
    getFn: ?*const fn (ctx: *anyopaque) ?[:0]const u8 = null,
    setFn: ?*const fn (ctx: *anyopaque, text: [:0]const u8) void = null,

    pub fn get(self: Clipboard) ?[:0]const u8 {
        const ctx = self.ctx orelse return null;
        const f = self.getFn orelse return null;
        return f(ctx);
    }

    pub fn set(self: Clipboard, text: [:0]const u8) void {
        const ctx = self.ctx orelse return;
        const f = self.setFn orelse return;
        f(ctx, text);
    }
};

pub const NodeRect = struct {
    ctx: ?*const anyopaque = null,
    getFn: ?*const fn (ctx: *const anyopaque, id: Id) ?kit.tree.Rect = null,

    pub fn get(self: NodeRect, id: Id) ?kit.tree.Rect {
        const ctx = self.ctx orelse return null;
        const f = self.getFn orelse return null;
        return f(ctx, id);
    }
};

pub const Context = struct {
    gpa: Allocator,
    io: std.Io,
    /// The config read at start, system file then user file.
    config: *const Config,
    /// Rex's state directory (`dirs.Application.state`).
    state_dir: []const u8,
    /// User config file path (`config_paths.user`).
    config_path: []const u8 = "",
    /// User home directory (`$HOME`).
    home_dir: []const u8 = "",
    /// Ends the loop's current sleep; safe from any thread.
    wake_loop: *const fn () void,
    /// Window clipboard access (main thread only).
    clipboard: Clipboard = .{},
    /// Laid-out rectangle lookup for the most recently rendered frame.
    node_rect: NodeRect = .{},
};

pub const KeyPress = struct {
    key: input_key.Key,
    mods: input_key.Modifiers = .none,
};

/// Opens the window of `Tool` and runs it until it is closed.
pub fn run(comptime Tool: type, init: std.process.Init, argv0: []const u8, environ: *const std.process.Environ) !void {
    const H = Host(Tool);
    const self = try H.create(init.gpa, init.io, argv0, environ);
    defer self.destroy(init.gpa);
    self.loop();
}

fn Host(comptime Tool: type) type {
    return struct {
        const Self = @This();

        io: std.Io,
        window: Window,
        font: KitFont,
        painter: KitPainter,
        atlas: Atlas,
        lock: std.Io.File,
        /// The config and the directories read at start. `state` may
        /// borrow from both (`Context`), so they are freed after it.
        loaded: Loaded,
        directories: dirs.Application,
        home: []const u8,
        user_config_path: []const u8,
        state: Tool.State,
        nodes: [Tool.node_max]kit.tree.Node = undefined,
        lines: [Tool.line_max]kit.text.Line = undefined,
        /// The last frame drawn, for hit-testing. Points into `nodes` and
        /// `lines`, so the host lives on the heap and is never copied.
        tree: Tree,
        content_scale: f32,
        /// In logical pixels; negative while the pointer is off the window.
        pointer_x: f32 = -1,
        pointer_y: f32 = -1,
        /// The node under the pointer as last told to the tool.
        over: Id = .none,
        /// Node captured on left mouse press until release, for drag gestures.
        drag_id: Id = .none,
        /// The size last told to the tool, in logical pixels.
        width: f32 = 0,
        height: f32 = 0,
        redraw: bool = true,
        /// For the time to the first frame, logged once.
        started_ms: ?i64,
        /// From `[ui] color_scheme`, read once at start.
        theme: *const Theme,

        fn create(gpa: Allocator, io: std.Io, argv0: []const u8, environ: *const std.process.Environ) !*Self {
            const started_ms = awakeMs(io);
            var envmap = try environ.createMap(gpa);
            defer envmap.deinit();

            const home = try environ.getAlloc(gpa, "HOME");
            errdefer gpa.free(home);

            var directories = try dirs.Application.resolve(gpa, "rex", home, &envmap);
            errdefer directories.deinit(gpa);

            const user_config_path = try config_paths.user(gpa, &directories);
            errdefer gpa.free(user_config_path);

            const lock = try openLock(io, directories.state, Tool.name ++ ".lock");
            const alone = lock.tryLock(io, .exclusive) catch |err| {
                lock.close(io);
                return err;
            };
            if (!alone) {
                lock.close(io);
                writeStderr("rex: " ++ Tool.name ++ " is already open\n");
                std.process.exit(1);
            }
            errdefer {
                lock.unlock(io);
                lock.close(io);
            }

            var loaded = try loadConfig(gpa, io, home, &directories);
            errdefer loaded.deinit(gpa);
            const settings = Settings.of(&loaded.config);

            const wayland = envmap.get("WAYLAND_DISPLAY") != null or
                std.mem.eql(u8, envmap.get("XDG_SESSION_TYPE") orelse "", "wayland");
            var window: Window = try .init(.{
                .width = window_width,
                .height = window_height,
                .title = Tool.title,
                .platform = Window.choosePlatform(settings.platform, wayland),
            });
            errdefer window.deinit();
            window.setMinimumSize(window_min_width, window_min_height);

            const scale = window.getWindowContentScale().width;
            const content_scale: f32 = if (scale > 0) scale else 1;

            var font = try openFont(gpa, io, argv0, content_scale);
            errdefer font.destroy();

            var painter: KitPainter = try .init();
            errdefer painter.deinit();

            // A quarter of the terminal's 2048: UI text in five styles fits
            // with room even at 2x, and the textures take 5 MB instead of
            // 20 (measured: 15 MB less resident under Mesa's llvmpipe).
            var atlas: Atlas = try .create(gpa, .{ .width = 1024, .height = 1024 });
            errdefer atlas.destroy();

            const self = try gpa.create(Self);
            errdefer gpa.destroy(self);
            self.* = .{
                .io = io,
                .window = window,
                .font = font,
                .painter = painter,
                .atlas = atlas,
                .lock = lock,
                .loaded = loaded,
                .directories = directories,
                .home = home,
                .user_config_path = user_config_path,
                .state = undefined,
                .tree = undefined,
                .content_scale = content_scale,
                .started_ms = started_ms,
                .theme = settings.theme,
            };
            self.tree = .init(&self.nodes, &self.lines);
            // Last fallible step: nothing after it may fail, or the state
            // would need its `deinit` on the error path.
            self.state = if (@hasDecl(Tool, "init")) try Tool.init(.{
                .gpa = gpa,
                .io = io,
                .config = &self.loaded.config,
                .state_dir = self.directories.state,
                .config_path = self.user_config_path,
                .home_dir = self.home,
                .wake_loop = Window.glfwPostEmptyEvent,
                .clipboard = .{
                    .ctx = &self.window,
                    .getFn = clipboardGet,
                    .setFn = clipboardSet,
                },
                .node_rect = .{
                    .ctx = self,
                    .getFn = nodeRect,
                },
            }) else .empty;

            self.window.setWindowUserPointer(self);
            self.window.setFramebufferSizeCallback(onResize);
            self.window.setWindowContentScaleCallback(onScale);
            self.window.setCursorPosCallback(onCursor);
            self.window.setCursorEnterCallback(onEnter);
            self.window.setMouseButtonCallback(onMouse);
            self.window.setKeyCallback(onKey);
            self.window.setCharCallback(onChar);
            self.window.setScrollCallback(onScroll);
            return self;
        }

        fn destroy(self: *Self, gpa: Allocator) void {
            if (@hasDecl(Tool, "deinit")) Tool.deinit(&self.state);
            self.loaded.deinit(gpa);
            gpa.free(self.user_config_path);
            gpa.free(self.home);
            self.directories.deinit(gpa);
            self.painter.deinit();
            self.font.destroy();
            self.atlas.destroy();
            self.window.deinit();
            self.lock.unlock(self.io);
            self.lock.close(self.io);
            gpa.destroy(self);
        }

        fn loop(self: *Self) void {
            while (!self.window.windowShouldClose()) {
                if (self.redraw) {
                    self.sendSize();
                    self.redraw = false;
                    self.drawFrame();
                    if (self.started_ms) |started| {
                        log.info("first frame in {d} ms", .{awakeMs(self.io) - started});
                        self.started_ms = null;
                    }
                    // The frame may have moved a node under a pointer that
                    // stood still.
                    self.pointerMoved();
                    if (self.redraw) continue;
                }
                const timeout: ?f64 = if (@hasDecl(Tool, "wait")) Tool.wait(&self.state) else null;
                if (timeout) |seconds| Window.glfwWaitEventsTimeout(seconds) else Window.glfwWaitEvents();
                if (@hasDecl(Tool, "wake") and Tool.wake(&self.state)) self.redraw = true;
            }
        }

        fn drawFrame(self: *Self) void {
            const fb = self.window.frameBufferSize(f32);
            const scale = self.content_scale;
            const theme = self.theme;

            self.painter.begin();
            self.build(theme, fb.width / scale, fb.height / scale) catch |err| {
                // The same state fails the same way every frame: show the
                // background alone rather than half a view.
                log.err("cannot build the {s} view: {t}", .{ Tool.name, err });
                self.tree.reset();
                self.painter.begin();
            };

            gl.viewport(0, 0, @intFromFloat(@round(fb.width)), @intFromFloat(@round(fb.height)));
            const background = theme.background;
            gl.clearColor(
                @as(f32, @floatFromInt(background.r)) / 255.0,
                @as(f32, @floatFromInt(background.g)) / 255.0,
                @as(f32, @floatFromInt(background.b)) / 255.0,
                1,
            );
            gl.clear(gl.COLOR_BUFFER_BIT);
            self.painter.draw(&self.atlas, fb.width, fb.height);
            self.window.swapBuffers();
        }

        fn build(self: *Self, theme: *const Theme, width: f32, height: f32) !void {
            self.tree.reset();
            try Tool.view(&self.state, &self.tree, theme);
            try kit.layout.layout(&self.tree, self.font.measurer(), width, height);
            try self.painter.paint(&self.tree, &self.font, &self.atlas);
        }

        /// Tells the tool when the window's logical size changed, so the
        /// frame about to be drawn already follows it.
        fn sendSize(self: *Self) void {
            const fb = self.window.frameBufferSize(f32);
            const width = fb.width / self.content_scale;
            const height = fb.height / self.content_scale;
            if (width == self.width and height == self.height) return;
            self.width = width;
            self.height = height;
            self.send(.{ .size = .{ .width = width, .height = height } });
        }

        fn send(self: *Self, event: Event) void {
            if (Tool.update(&self.state, event)) self.redraw = true;
        }

        /// Tells the tool when the node under the pointer changed, and
        /// shows the shape that node asks for.
        fn pointerMoved(self: *Self) void {
            const node = if (self.pointer_x < 0) null else self.tree.hit(self.pointer_x, self.pointer_y);
            const id = if (node) |n| n.box.id else .none;
            self.window.setPointerShape(if (node) |n| switch (n.box.pointer) {
                .arrow => .arrow,
                .hand => .hand,
                .text => .text,
            } else .arrow);
            if (self.drag_id != .none) {
                self.over = id;
                self.send(.{ .pointer = .{ .id = self.drag_id, .x = self.pointer_x, .y = self.pointer_y } });
                return;
            }
            if (id == self.over) return;
            self.over = id;
            self.send(.{ .pointer = .{ .id = id, .x = self.pointer_x, .y = self.pointer_y } });
        }

        fn nodeRect(ctx: *const anyopaque, id: Id) ?kit.tree.Rect {
            const self: *const Self = @ptrCast(@alignCast(ctx));
            const n = self.tree.find(id) orelse return null;
            return n.rect;
        }

        fn fromWindow(window: ?*c.GLFWwindow) *Self {
            return @ptrCast(@alignCast(Window.glfwGetWindowUserPointer(window).?));
        }

        fn onResize(window: ?*c.GLFWwindow, _: c_int, _: c_int) callconv(.c) void {
            fromWindow(window).redraw = true;
        }

        fn onScale(window: ?*c.GLFWwindow, xscale: f32, _: f32) callconv(.c) void {
            const self = fromWindow(window);
            const scale: f32 = if (xscale > 0) xscale else 1;
            if (scale == self.content_scale) return;
            self.content_scale = scale;
            self.font.setScale(scale) catch |err| {
                log.err("cannot size the UI font for scale {d:.2}: {t}", .{ scale, err });
            };
            self.atlas.invalidate();
            self.painter.clearGlyphs();
            self.redraw = true;
        }

        fn onCursor(window: ?*c.GLFWwindow, x: f64, y: f64) callconv(.c) void {
            const self = fromWindow(window);
            // Framebuffer pixels divided by the scale, as in the terminal.
            // Where window coordinates are not pixels, that is #18.
            self.pointer_x = @as(f32, @floatCast(x)) / self.content_scale;
            self.pointer_y = @as(f32, @floatCast(y)) / self.content_scale;
            self.pointerMoved();
        }

        fn onEnter(window: ?*c.GLFWwindow, entered: c_int) callconv(.c) void {
            if (entered != 0) return;
            const self = fromWindow(window);
            self.pointer_x = -1;
            self.pointer_y = -1;
            self.pointerMoved();
        }

        fn onMouse(window: ?*c.GLFWwindow, button: c_int, action: c_int, _: c_int) callconv(.c) void {
            if (button != c.GLFW_MOUSE_BUTTON_LEFT) return;
            const self = fromWindow(window);
            switch (action) {
                c.GLFW_PRESS => {
                    self.drag_id = self.over;
                    self.send(.{ .press = self.over });
                },
                c.GLFW_RELEASE => {
                    self.drag_id = .none;
                    self.send(.release);
                },
                else => {},
            }
        }

        fn onScroll(window: ?*c.GLFWwindow, _: f64, y: f64) callconv(.c) void {
            const self = fromWindow(window);
            self.send(.{ .scroll = .{ .dy = scrollDelta(y), .max = self.tree.scroll_max } });
        }

        fn clipboardGet(ptr: *anyopaque) ?[:0]const u8 {
            const win: *Window = @ptrCast(@alignCast(ptr));
            return win.getClipboard();
        }

        fn clipboardSet(ptr: *anyopaque, text: [:0]const u8) void {
            const win: *Window = @ptrCast(@alignCast(ptr));
            win.setClipboard(text);
        }

        fn onKey(window: ?*c.GLFWwindow, code: c_int, _: c_int, action: c_int, mods: c_int) callconv(.c) void {
            if (action == c.GLFW_RELEASE) return;
            const key = glfw_key.key(code) orelse return;
            fromWindow(window).send(.{ .key = .{ .key = key, .mods = glfw_key.modifiers(mods) } });
        }

        fn onChar(window: ?*c.GLFWwindow, codepoint: c_uint) callconv(.c) void {
            const cp = std.math.cast(u21, codepoint) orelse return;
            if (!std.unicode.utf8ValidCodepoint(cp)) return;
            fromWindow(window).send(.{ .char = cp });
        }
    };
}

/// GLFW reports notches up as positive; content moves up when the wheel
/// turns down. A touchpad sends fractions of a notch.
pub fn scrollDelta(y_offset: f64) f32 {
    return @floatCast(-y_offset * scroll_step);
}

/// What the host itself takes from the config: the theme from `[ui]
/// color_scheme`, against the terminal theme's background for `auto`, and
/// `[window] platform`.
const Settings = struct {
    theme: *const Theme,
    platform: Window.Platform,

    fn of(config: *const Config) Settings {
        const background = config.theme.background;
        return .{
            .theme = config.ui.color_scheme.variant(.{ background.r, background.g, background.b }).theme(),
            .platform = config.window.platform,
        };
    }
};

/// The system file, then the user file, as the terminal reads them; the
/// terminal reports any problems in them.
fn loadConfig(gpa: Allocator, io: std.Io, home: []const u8, directories: *const dirs.Application) Allocator.Error!Loaded {
    const user_path = try config_paths.user(gpa, directories);
    defer gpa.free(user_path);
    return Loaded.load(gpa, io, &config_defaults.default, home, &.{ .file(config_paths.system), .file(user_path) });
}

fn awakeMs(io: std.Io) i64 {
    return std.Io.Clock.Timestamp.now(io, .awake).raw.toMilliseconds();
}

fn openLock(io: std.Io, state_dir: []const u8, comptime file_name: []const u8) !std.Io.File {
    const dir = try std.Io.Dir.createDirPathOpen(.cwd(), io, state_dir, .{});
    defer dir.close(io);
    return dir.createFile(io, file_name, .{ .truncate = false });
}

fn openFont(gpa: Allocator, io: std.Io, argv0: []const u8, scale: f32) !KitFont {
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe: []const u8 = if (std.process.executablePath(io, &exe_buf)) |len|
        exe_buf[0..len]
    else |_|
        argv0;

    const dir = try font_files.fontDir(gpa, exe);
    defer gpa.free(dir);

    const regular = try std.fs.path.joinZ(gpa, &.{ dir, font_files.ui_regular_name });
    defer gpa.free(regular);
    const medium = try std.fs.path.joinZ(gpa, &.{ dir, font_files.ui_medium_name });
    defer gpa.free(medium);
    const semibold = try std.fs.path.joinZ(gpa, &.{ dir, font_files.ui_semibold_name });
    defer gpa.free(semibold);

    return .create(.{
        .regular = regular,
        .medium = medium,
        .semibold = semibold,
    }, .{ .scale = scale });
}

/// Best effort: the process exits right after, with status 1 either way.
fn writeStderr(msg: []const u8) void {
    _ = std.posix.system.write(std.posix.STDERR_FILENO, msg.ptr, msg.len);
}
