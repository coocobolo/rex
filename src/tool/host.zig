//! The process behind a tool window (ADR 0008): one window that draws only
//! the UI kit, with no terminal in it. The host owns the window, GL, the UI
//! font, the painter and the event loop; a tool is a surface in the kit's
//! model (ADR 0009) handed to `run` as a type.
//!
//! A tool declares `name` (the lock file), `title`, `node_max`, `line_max`,
//! a `State`, `update(*State, Event) bool` and
//! `view(*const State, *Tree, *const Theme) kit.Tree.Error!void`. `State`
//! has an `empty` value, or the tool declares `init(Context) !State` and
//! `deinit(*State)`.
//!
//! The loop sleeps in the platform event wait and draws only when `update` reports
//! a change, the framebuffer is resized or the scale changes, so an idle
//! window causes no wakeups. A tool may declare `wait(*const State) ?f64`,
//! the most seconds to sleep (null: until an event),
//! `wake(*State) bool`, called after every sleep, true to redraw, and
//! `currentTheme(*const State) *const Theme` to resolve the window theme
//! dynamically each frame instead of reading `[ui] color_scheme` once at
//! startup. One
//! instance of each tool runs at a time: a second start finds the lock
//! taken and exits with a message.
//!
//! Imports stay on leaf files: nothing here may reach `term/` or the driver
//! (ADR 0009 point 8).

const std = @import("std");
const Allocator = std.mem.Allocator;

const Platform = @import("../platform/Platform.zig");
const PlatformEvent = @import("../platform/Event.zig").Event;
const window_config = @import("../config/window.zig");

const dirs = @import("../dirs/root.zig");
const font_files = @import("../config/font_files.zig");
const config_defaults = @import("../config/default.zig");
const config_paths = @import("../config/paths.zig");
const Loaded = @import("../config/Loaded.zig");
const Config = @import("../config/Config.zig");
const kit = @import("../kit/root.zig");
const input_key = @import("../input/key.zig");
const gl = @import("../renderer/gl.zig");

const Atlas = @import("../renderer/Atlas.zig");
const KitPainter = @import("../renderer/KitPainter.zig");
const Window = @import("../platform/Window.zig");
const KitFont = @import("../freetype/KitFont.zig");

const Theme = kit.Theme;
const Tree = kit.Tree;
const Id = kit.Tree.Id;

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
    pointer: struct { id: Id, x: f32 = 0, y: f32 = 0, mods: input_key.Modifiers = .none },
    /// The left button went down on the node with this id.
    press: Id,
    /// The left button was let go, wherever the pointer is.
    release,
    key: KeyPress,
    /// A printable Unicode codepoint typed on the keyboard.
    char: u21,
    /// The wheel turned over the scroll region with `id` (or `.none` when
    /// occluded or outside any region): `dx`/`dy` logical pixels right/down
    /// (negative: left/up). `max_x` and `max_y` are the region's bounds.
    scroll: struct {
        id: Id = .none,
        dx: f32 = 0,
        dy: f32 = 0,
        max_x: f32 = 0,
        max_y: f32 = 0,
    },
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
    getFn: ?*const fn (ctx: *const anyopaque, id: Id) ?kit.Tree.Rect = null,

    /// Looks rectangles up with `f(ctx, id)`; `ctx` must outlive every `get`.
    pub fn init(
        comptime T: type,
        ctx: *const T,
        comptime f: fn (*const T, Id) ?kit.Tree.Rect,
    ) NodeRect {
        const Wrap = struct {
            fn call(p: *const anyopaque, id: Id) ?kit.Tree.Rect {
                return f(@ptrCast(@alignCast(p)), id);
            }
        };
        return .{ .ctx = ctx, .getFn = Wrap.call };
    }

    pub fn get(self: NodeRect, id: Id) ?kit.Tree.Rect {
        const ctx = self.ctx orelse return null;
        const f = self.getFn orelse return null;
        return f(ctx, id);
    }
};

/// Screen-space `x` origin lookup for laid-out `kit.input` fields so tools can
/// map pointer clicks to text offsets without referencing the host's `Tree`.
pub const InputOrigin = struct {
    ctx: ?*const anyopaque = null,
    getFn: ?*const fn (ctx: *const anyopaque, id: Id) ?f32 = null,

    pub fn init(
        comptime T: type,
        ctx: *const T,
        comptime f: fn (*const T, Id) ?f32,
    ) InputOrigin {
        const Wrap = struct {
            fn call(p: *const anyopaque, id: Id) ?f32 {
                return f(@ptrCast(@alignCast(p)), id);
            }
        };
        return .{ .ctx = ctx, .getFn = Wrap.call };
    }

    pub fn get(self: InputOrigin, id: Id) ?f32 {
        const ctx = self.ctx orelse return null;
        const f = self.getFn orelse return null;
        return f(ctx, id);
    }
};

pub const ToolLauncher = struct {
    ctx: ?*anyopaque = null,
    openFn: ?*const fn (ctx: *anyopaque, subcommand: []const u8) void = null,

    pub fn open(self: ToolLauncher, subcommand: []const u8) void {
        const ctx = self.ctx orelse return;
        const f = self.openFn orelse return;
        f(ctx, subcommand);
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
    /// Laid-out byte-0 `x` origin lookup for `kit.input` fields.
    input_origin: InputOrigin = .{},
    /// UI font measurer for pointer-to-caret mapping (`null` in headless tests).
    text_measurer: ?kit.text.Measurer = null,
    /// Spawns a detached sibling tool window (`rex <subcommand>`).
    tool_launcher: ToolLauncher = .{},
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
        argv0: []const u8,
        platform: Platform,
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
        nodes: [Tool.node_max]kit.Tree.Node = undefined,
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
        /// Scroll region whose overlay scrollbar is hovered, or `.none`.
        hovered_scrollbar: Id = .none,
        /// Active scrollbar thumb drag or track-click gesture.
        scrollbar_drag: ScrollbarDrag = .idle,
        /// Per-region auto-hide hold/fade timers for overlay scrollbars.
        scrollbar_visibility: ScrollbarVisibility = .{},
        /// The size last told to the tool, in logical pixels.
        width: f32 = 0,
        height: f32 = 0,
        redraw: bool = true,
        /// For the time to the first frame, logged once.
        started_ms: ?i64,
        /// Fallback when the tool has no `currentTheme` hook: from `[ui]
        /// color_scheme`, read once at start.
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
            var plat: Platform = try .init(Platform.choose(settings.platform, wayland));
            errdefer plat.deinit();
            var window = try plat.createWindow(.{
                .width = window_width,
                .height = window_height,
                .title = Tool.title,
            });
            errdefer window.deinit();
            window.setMinimumSize(.{ .width = window_min_width, .height = window_min_height });

            const scale = window.contentScale().width;
            const content_scale: f32 = if (scale > 0) scale else 1;

            var font = try openFont(gpa, io, argv0, content_scale);
            errdefer font.deinit();

            var painter: KitPainter = try .init();
            errdefer painter.deinit();

            // A quarter of the terminal's 2048: UI text in five styles fits
            // with room even at 2x, and the textures take 5 MB instead of
            // 20 (measured: 15 MB less resident under Mesa's llvmpipe).
            var atlas: Atlas = try .init(gpa, .{ .width = 1024, .height = 1024 });
            errdefer atlas.deinit();

            const self = try gpa.create(Self);
            errdefer gpa.destroy(self);
            self.* = .{
                .io = io,
                .argv0 = argv0,
                .platform = plat,
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
                .wake_loop = Platform.postWakeup,
                .clipboard = .{
                    .ctx = &self.window,
                    .getFn = clipboardGet,
                    .setFn = clipboardSet,
                },
                .node_rect = .init(Self, self, nodeRect),
                .input_origin = .init(Self, self, inputOriginX),
                .text_measurer = self.font.measurer(),
                .tool_launcher = .{
                    .ctx = self,
                    .openFn = openTool,
                },
            }) else .empty;

            self.window.setContext(self);
            return self;
        }

        fn destroy(self: *Self, gpa: Allocator) void {
            if (@hasDecl(Tool, "deinit")) Tool.deinit(&self.state);
            self.loaded.deinit(gpa);
            gpa.free(self.user_config_path);
            gpa.free(self.home);
            self.directories.deinit(gpa);
            self.painter.deinit();
            self.font.deinit();
            self.atlas.deinit();
            self.window.deinit();
            self.platform.deinit();
            self.lock.unlock(self.io);
            self.lock.close(self.io);
            gpa.destroy(self);
        }

        fn loop(self: *Self) void {
            while (!self.window.shouldClose()) {
                if (self.redraw) {
                    self.sendSize();
                    self.redraw = false;
                    self.drawFrame();
                    if (self.started_ms) |started| {
                        log.info("first frame in {d} ms", .{awakeMs(self.io) - started});
                        self.started_ms = null;
                    }
                    // The frame may have moved a node under a pointer that
                    // stood still. Skip during an active scrollbar drag: the
                    // pointer has not moved and `build` already synced or
                    // cancelled the drag.
                    if (self.scrollbar_drag == .idle) self.pointerMoved();
                    if (self.redraw) continue;
                }
                const tool_ms: ?f64 = if (@hasDecl(Tool, "wait"))
                    if (Tool.wait(&self.state)) |seconds| seconds * 1000.0 else null
                else
                    null;
                const scroll_ms = self.scrollbar_visibility.nextWaitMs(awakeMs(self.io));
                const wait_ms: ?f64 = if (tool_ms) |t|
                    if (scroll_ms) |s| @min(t, s) else t
                else
                    scroll_ms;
                self.platform.waitEvents(wait_ms);
                self.drainEvents();
                if (self.scrollbar_visibility.tick(awakeMs(self.io))) self.redraw = true;
                if (@hasDecl(Tool, "wake") and Tool.wake(&self.state)) self.redraw = true;
            }
        }

        fn activeTheme(self: *const Self) *const Theme {
            if (@hasDecl(Tool, "currentTheme")) return Tool.currentTheme(&self.state);
            return self.theme;
        }

        fn drawFrame(self: *Self) void {
            const fb = self.window.framebufferSize(f32);
            const scale = self.content_scale;
            const theme = self.activeTheme();

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
            try self.tree.layout(self.font.measurer(), width, height);
            if (@hasDecl(Tool, "place")) Tool.place(&self.state, &self.tree);
            const now_ms = awakeMs(self.io);
            self.scrollbar_drag.sync(&self.tree);
            self.scrollbar_visibility.sync(&self.tree, self.hovered_scrollbar, self.scrollbar_drag.activeId(), now_ms);
            applyScrollbarHighlight(&self.tree, theme, &self.scrollbar_visibility, self.hovered_scrollbar, self.scrollbar_drag.activeId(), now_ms);
            try self.painter.paint(&self.tree, &self.font, &self.atlas);
        }

        /// Tells the tool when the window's logical size changed, so the
        /// frame about to be drawn already follows it.
        fn sendSize(self: *Self) void {
            const fb = self.window.framebufferSize(f32);
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

        fn setHoveredScrollbar(self: *Self, id: Id) void {
            if (self.hovered_scrollbar == id) return;
            const prev = self.hovered_scrollbar;
            self.hovered_scrollbar = id;
            if (prev != .none and prev != self.scrollbar_drag.activeId()) {
                self.scrollbar_visibility.unpin(prev, awakeMs(self.io));
            }
            if (id != .none) self.scrollbar_visibility.pin(id);
            self.redraw = true;
        }

        /// Tells the tool when the node under the pointer changed, and
        /// shows the shape that node asks for.
        fn pointerMoved(self: *Self) void {
            if (self.scrollbar_drag == .dragging) {
                self.window.setPointerShape(.hand);
                if (self.scrollbar_drag.moveTo(self.pointer_x, self.pointer_y)) |scroll_event| {
                    self.send(scroll_event);
                }
                return;
            }
            if (self.drag_id == .none and self.pointer_x >= 0) {
                if (self.tree.scrollbarAt(self.pointer_x, self.pointer_y)) |hit| {
                    if (hit.region.id != .none) {
                        self.window.setPointerShape(.hand);
                        self.setHoveredScrollbar(hit.region.id);
                        if (self.over != .none) {
                            self.over = .none;
                            self.send(.{ .pointer = .{ .id = .none, .x = self.pointer_x, .y = self.pointer_y } });
                        }
                        return;
                    }
                }
            }
            self.setHoveredScrollbar(.none);
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

        fn nodeRect(self: *const Self, id: Id) ?kit.Tree.Rect {
            const n = self.tree.find(id) orelse return null;
            return n.rect;
        }

        fn inputOriginX(self: *const Self, id: Id) ?f32 {
            return kit.input.textOriginX(&self.tree, id);
        }

        fn openTool(ctx: *anyopaque, subcommand: []const u8) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
            const exe: []const u8 = if (std.process.executablePath(self.io, &exe_buf)) |len|
                exe_buf[0..len]
            else |_|
                self.argv0;
            const child = std.process.spawn(self.io, .{
                .argv = &.{ exe, subcommand },
                .cwd = .inherit,
                .stdin = .ignore,
                .stdout = .ignore,
                .stderr = .ignore,
                .pgid = 0,
            }) catch |err| {
                log.err("cannot start rex {s}: {t}", .{ subcommand, err });
                return;
            };
            if (child.id) |pid| {
                if (std.Thread.spawn(.{}, reapChild, .{pid})) |reaper| {
                    reaper.detach();
                } else |err| {
                    log.warn("no reaper thread for rex {s} ({t}); pid {d} stays a zombie until exit", .{ subcommand, err, pid });
                }
            }
        }

        fn drainEvents(self: *Self) void {
            var event: PlatformEvent = undefined;
            while (self.platform.nextEvent(&event)) switch (event) {
                .key => |e| {
                    if (e.action == .release) continue;
                    self.send(.{ .key = .{ .key = e.key, .mods = e.mods } });
                },
                .text => |e| {
                    if (!std.unicode.utf8ValidCodepoint(e.codepoint)) continue;
                    self.send(.{ .char = e.codepoint });
                },
                .preedit => {},
                .mouse_button => |e| {
                    if (e.button != .left) continue;
                    switch (e.action) {
                        .press => {
                            if (self.pointer_x >= 0) {
                                if (self.tree.scrollbarAt(self.pointer_x, self.pointer_y)) |hit| {
                                    if (hit.region.id != .none) {
                                        self.drag_id = .none;
                                        self.hovered_scrollbar = hit.region.id;
                                        self.scrollbar_visibility.pin(hit.region.id);
                                        self.window.setPointerShape(.hand);
                                        if (self.over != .none) {
                                            self.over = .none;
                                            self.send(.{ .pointer = .{ .id = .none, .x = self.pointer_x, .y = self.pointer_y } });
                                        }
                                        if (self.scrollbar_drag.begin(hit, self.pointer_x, self.pointer_y)) |scroll_event| {
                                            self.send(scroll_event);
                                        }
                                        self.redraw = true;
                                        continue;
                                    }
                                }
                            }
                            self.drag_id = self.over;
                            self.send(.{ .pointer = .{ .id = self.over, .x = self.pointer_x, .y = self.pointer_y, .mods = e.mods } });
                            self.send(.{ .press = self.over });
                        },
                        .release => {
                            if (self.scrollbar_drag == .dragging) {
                                const released_id = self.scrollbar_drag.activeId();
                                self.scrollbar_drag = .idle;
                                self.redraw = true;
                                self.pointerMoved();
                                if (self.hovered_scrollbar != released_id) {
                                    self.scrollbar_visibility.unpin(released_id, awakeMs(self.io));
                                }
                                continue;
                            }
                            self.drag_id = .none;
                            self.send(.release);
                        },
                        .repeat => {},
                    }
                },
                .cursor_pos => |e| {
                    // Framebuffer pixels divided by the scale, as in the terminal.
                    // Where window coordinates are not pixels, that is #18.
                    self.pointer_x = @as(f32, @floatCast(e.x)) / self.content_scale;
                    self.pointer_y = @as(f32, @floatCast(e.y)) / self.content_scale;
                    self.pointerMoved();
                },
                .scroll => |e| {
                    const dx = scrollDelta(e.dx);
                    const dy = scrollDelta(e.dy);
                    if (dx == 0 and dy == 0) continue;
                    if (self.tree.scrollTargetAt(self.pointer_x, self.pointer_y, dx, dy)) |region| {
                        if (self.scrollbar_visibility.reveal(region.id, awakeMs(self.io))) self.redraw = true;
                        self.send(.{ .scroll = .{
                            .id = region.id,
                            .dx = dx,
                            .dy = dy,
                            .max_x = region.max.x,
                            .max_y = region.max.y,
                        } });
                    } else {
                        // Occluded popups without their own `scrollRegion` still handle wheel via `id == .none`.
                        self.send(.{ .scroll = .{ .id = .none, .dx = dx, .dy = dy } });
                    }
                },
                .cursor_enter => |e| {
                    if (e.entered) continue;
                    if (self.scrollbar_drag == .dragging or self.drag_id != .none) continue;
                    self.pointer_x = -1;
                    self.pointer_y = -1;
                    self.pointerMoved();
                },
                .focus => {},
                .framebuffer_size => {
                    self.scrollbar_visibility.revealAll(awakeMs(self.io));
                    self.redraw = true;
                },
                .content_scale => |e| {
                    const scale: f32 = if (e.x > 0) e.x else 1;
                    if (scale == self.content_scale) continue;
                    self.content_scale = scale;
                    self.font.setScale(scale) catch |err| {
                        log.err("cannot size the UI font for scale {d:.2}: {t}", .{ scale, err });
                    };
                    self.atlas.invalidate();
                    self.painter.clearGlyphs();
                    self.redraw = true;
                },
                .close => self.window.setShouldClose(true),
            };
            const dropped = self.platform.takeDropped();
            if (dropped > 0) log.warn("dropped {d} platform events", .{dropped});
        }

        fn clipboardGet(ptr: *anyopaque) ?[:0]const u8 {
            const win: *Window = @ptrCast(@alignCast(ptr));
            return win.getClipboard();
        }

        fn clipboardSet(ptr: *anyopaque, text: [:0]const u8) void {
            const win: *Window = @ptrCast(@alignCast(ptr));
            win.setClipboard(text);
        }
    };
}

/// GLFW reports notches up as positive; content moves up when the wheel
/// turns down. A touchpad sends fractions of a notch.
pub fn scrollDelta(y_offset: f64) f32 {
    return @floatCast(-y_offset * scroll_step);
}

/// Active scrollbar thumb drag or track-click jump gesture tracked by `Host`.
pub const ScrollbarDrag = union(enum) {
    idle,
    dragging: Drag,

    pub const Drag = struct {
        id: Id,
        track_start: f32,
        travel: f32,
        grab_offset: f32,
        max_x: f32,
        max_y: f32,
        current_offset: f32,
        axis: Tree.Axis,

        fn maxForAxis(self: Drag) f32 {
            return switch (self.axis) {
                .column => self.max_y,
                .row => self.max_x,
            };
        }

        fn targetOffset(self: Drag, cursor: f32) f32 {
            const max = self.maxForAxis();
            if (!(self.travel > 0) or !(max > 0) or std.math.isNan(cursor)) return 0;
            const thumb_pos = cursor - self.grab_offset;
            const ratio = std.math.clamp((thumb_pos - self.track_start) / self.travel, 0, 1);
            return ratio * max;
        }
    };

    pub fn activeId(self: ScrollbarDrag) Id {
        return switch (self) {
            .idle => .none,
            .dragging => |d| d.id,
        };
    }

    /// Starts dragging `hit` at `(x, y)`. Clicking the thumb preserves the grab
    /// offset and returns `null`; clicking the track centers the thumb under
    /// the pointer and returns the immediate `.scroll` event.
    pub fn begin(self: *ScrollbarDrag, hit: Tree.Scroll.ScrollbarHit, x: f32, y: f32) ?Event {
        if (hit.region.id == .none) {
            self.* = .idle;
            return null;
        }
        const cursor = switch (hit.axis) {
            .column => y,
            .row => x,
        };
        const current_raw = switch (hit.axis) {
            .column => hit.region.offset.y,
            .row => hit.region.offset.x,
        };
        const max = switch (hit.axis) {
            .column => hit.region.max.y,
            .row => hit.region.max.x,
        };
        const current = if (std.math.isNan(current_raw)) 0 else std.math.clamp(current_raw, 0, @max(0, max));
        const travel = @max(0, hit.track_len - hit.thumb_len);
        const grab_offset = switch (hit.part) {
            .thumb => cursor - hit.thumb_start,
            .track => hit.thumb_len / 2,
        };
        self.* = .{ .dragging = .{
            .id = hit.region.id,
            .track_start = hit.track_start,
            .travel = travel,
            .grab_offset = grab_offset,
            .max_x = hit.region.max.x,
            .max_y = hit.region.max.y,
            .current_offset = current,
            .axis = hit.axis,
        } };
        return switch (hit.part) {
            .thumb => null,
            .track => self.moveTo(x, y),
        };
    }

    /// Updates the drag to pointer `(x, y)` and returns the incremental `.scroll`
    /// delta since the previous target, or `null` when idle or unchanged.
    pub fn moveTo(self: *ScrollbarDrag, x: f32, y: f32) ?Event {
        return switch (self.*) {
            .idle => null,
            .dragging => |*drag| {
                const cursor = switch (drag.axis) {
                    .column => y,
                    .row => x,
                };
                const next = drag.targetOffset(cursor);
                const max = drag.maxForAxis();
                const delta = next - drag.current_offset;
                if (delta == 0) return null;
                if (next != 0 and next != max and @abs(delta) < 1e-3) return null;
                drag.current_offset = next;
                return .{ .scroll = .{
                    .id = drag.id,
                    .dx = if (drag.axis == .row) delta else 0,
                    .dy = if (drag.axis == .column) delta else 0,
                    .max_x = drag.max_x,
                    .max_y = drag.max_y,
                } };
            },
        };
    }

    /// Refreshes track geometry from the newly laid-out `tree`, or resets to
    /// `.idle` if the dragged scroll region disappeared or stopped overflowing.
    pub fn sync(self: *ScrollbarDrag, tree: *const Tree) void {
        const drag = switch (self.*) {
            .idle => return,
            .dragging => |*d| d,
        };
        for (tree.scrolls[0..tree.scroll_len]) |region| {
            if (region.id != drag.id) continue;
            if (region.thumb == Tree.none) {
                self.* = .idle;
                return;
            }
            const thumb_rect = tree.nodes[region.thumb].rect;
            if (thumb_rect.w <= 0 or thumb_rect.h <= 0) {
                self.* = .idle;
                return;
            }
            const viewport = tree.nodes[region.node].rect;
            switch (drag.axis) {
                .column => {
                    if (!(region.max.y > 0)) {
                        self.* = .idle;
                        return;
                    }
                    const track_len = viewport.h - Tree.Scroll.thumb_track_pad * 2;
                    drag.track_start = viewport.y + Tree.Scroll.thumb_track_pad;
                    drag.travel = @max(0, track_len - thumb_rect.h);
                    drag.max_x = region.max.x;
                    drag.max_y = region.max.y;
                    drag.current_offset = if (std.math.isNan(region.offset.y)) 0 else std.math.clamp(region.offset.y, 0, region.max.y);
                },
                .row => {
                    if (!(region.max.x > 0)) {
                        self.* = .idle;
                        return;
                    }
                    const track_len = viewport.w - Tree.Scroll.thumb_track_pad * 2;
                    drag.track_start = viewport.x + Tree.Scroll.thumb_track_pad;
                    drag.travel = @max(0, track_len - thumb_rect.w);
                    drag.max_x = region.max.x;
                    drag.max_y = region.max.y;
                    drag.current_offset = if (std.math.isNan(region.offset.x)) 0 else std.math.clamp(region.offset.x, 0, region.max.x);
                },
            }
            return;
        }
        self.* = .idle;
    }
};

/// Auto-hide timer state for overlay scrollbars in `Host`.
///
/// Tracks up to `Tree.Scroll.max` overflowing regions without heap allocation:
/// newly overflowing, scrolled, or resized regions stay visible for `hold_ms`,
/// fade to transparent over `fade_ms`, and then stop waking the event loop.
/// Hovered or dragged regions stay `.pinned` until interaction ends.
pub const ScrollbarVisibility = struct {
    pub const hold_ms: i64 = 1000;
    pub const fade_ms: i64 = 200;
    pub const fade_frame_ms: f64 = 16.0;

    pub const Phase = union(enum) {
        /// Kept visible while hovered or dragged.
        pinned,
        /// Visible after activity; starts fading once `now_ms >= until_ms`.
        holding: i64,
        /// Fading linearly to transparent over `fade_ms` from `start_ms`.
        fading: i64,
        /// Fully transparent; `Tree.scrollbarAt` still hits the grab strip.
        hidden,
    };

    pub const Entry = struct {
        phase: Phase,
        id: Id,
    };

    entries: [Tree.Scroll.max]Entry = undefined,
    len: u8 = 0,

    fn find(self: *ScrollbarVisibility, id: Id) ?*Entry {
        for (self.entries[0..self.len]) |*entry| {
            if (entry.id == id) return entry;
        }
        return null;
    }

    fn findConst(self: *const ScrollbarVisibility, id: Id) ?Entry {
        for (self.entries[0..self.len]) |entry| {
            if (entry.id == id) return entry;
        }
        return null;
    }

    /// Reconciles tracked regions against the newly laid-out `tree`.
    /// Newly overflowing regions start `.holding`; hovered/dragged regions are
    /// `.pinned`; regions that stop overflowing or vanish are dropped.
    pub fn sync(self: *ScrollbarVisibility, tree: *const Tree, hovered_id: Id, dragged_id: Id, now_ms: i64) void {
        var next: [Tree.Scroll.max]Entry = undefined;
        var next_len: u8 = 0;

        for (tree.scrolls[0..tree.scroll_len]) |region| {
            if (region.id == .none or region.thumb == Tree.none) continue;
            const thumb = tree.nodes[region.thumb].rect;
            if (thumb.w <= 0 or thumb.h <= 0) continue;

            const active = region.id == hovered_id or region.id == dragged_id;
            const phase: Phase = if (active)
                .pinned
            else if (self.findConst(region.id)) |prev| switch (prev.phase) {
                .pinned => .{ .holding = now_ms + hold_ms },
                .holding => |until_ms| if (now_ms >= until_ms)
                    .{ .fading = now_ms }
                else
                    .{ .holding = until_ms },
                .fading => |start_ms| if (now_ms >= start_ms + fade_ms)
                    .hidden
                else
                    .{ .fading = start_ms },
                .hidden => .hidden,
            } else .{ .holding = now_ms + hold_ms };

            next[next_len] = .{ .id = region.id, .phase = phase };
            next_len += 1;
        }

        self.entries = next;
        self.len = next_len;
    }

    /// Marks `id` as hovered/dragged so it stays visible until unpinned.
    pub fn pin(self: *ScrollbarVisibility, id: Id) void {
        if (id == .none) return;
        if (self.find(id)) |entry| {
            entry.phase = .pinned;
        } else if (self.len < Tree.Scroll.max) {
            self.entries[self.len] = .{ .id = id, .phase = .pinned };
            self.len += 1;
        }
    }

    /// Starts the hold timer for `id` if it was `.pinned`.
    pub fn unpin(self: *ScrollbarVisibility, id: Id, now_ms: i64) void {
        if (id == .none) return;
        if (self.find(id)) |entry| {
            if (entry.phase == .pinned) entry.phase = .{ .holding = now_ms + hold_ms };
        }
    }

    /// Reveals `id` after scroll activity; returns true if the thumb was
    /// hidden or fading and needs a redraw even if scroll offset clamped.
    pub fn reveal(self: *ScrollbarVisibility, id: Id, now_ms: i64) bool {
        if (id == .none) return false;
        if (self.find(id)) |entry| {
            switch (entry.phase) {
                .pinned => return false,
                .holding => {
                    entry.phase = .{ .holding = now_ms + hold_ms };
                    return false;
                },
                .fading, .hidden => {
                    entry.phase = .{ .holding = now_ms + hold_ms };
                    return true;
                },
            }
        }
        if (self.len < Tree.Scroll.max) {
            self.entries[self.len] = .{ .id = id, .phase = .{ .holding = now_ms + hold_ms } };
            self.len += 1;
            return true;
        }
        return false;
    }

    /// Resets every non-pinned tracked scrollbar to `.holding` (e.g. on resize).
    pub fn revealAll(self: *ScrollbarVisibility, now_ms: i64) void {
        for (self.entries[0..self.len]) |*entry| {
            if (entry.phase != .pinned) {
                entry.phase = .{ .holding = now_ms + hold_ms };
            }
        }
    }

    /// Advances hold and fade timers to `now_ms`; returns true if a frame must
    /// be drawn (fade started, fade stepped, or fade reached `.hidden`).
    pub fn tick(self: *ScrollbarVisibility, now_ms: i64) bool {
        var changed = false;
        for (self.entries[0..self.len]) |*entry| {
            switch (entry.phase) {
                .pinned, .hidden => {},
                .holding => |until_ms| {
                    if (now_ms >= until_ms) {
                        entry.phase = .{ .fading = now_ms };
                        changed = true;
                    }
                },
                .fading => |start_ms| {
                    if (now_ms >= start_ms + fade_ms) {
                        entry.phase = .hidden;
                    }
                    changed = true;
                },
            }
        }
        return changed;
    }

    /// Milliseconds until the next visibility transition or fade frame, or
    /// `null` when every scrollbar is `.hidden` or `.pinned` (zero idle wakeups).
    pub fn nextWaitMs(self: *const ScrollbarVisibility, now_ms: i64) ?f64 {
        var best: ?f64 = null;
        for (self.entries[0..self.len]) |entry| {
            const wait: f64 = switch (entry.phase) {
                .pinned, .hidden => continue,
                .holding => |until_ms| @floatFromInt(@max(0, until_ms - now_ms)),
                .fading => |start_ms| blk: {
                    const rem = start_ms + fade_ms - now_ms;
                    if (rem <= 0) break :blk 0;
                    break :blk @min(fade_frame_ms, @as(f64, @floatFromInt(rem)));
                },
            };
            best = if (best) |b| @min(b, wait) else wait;
        }
        return best;
    }

    /// Effective opacity for region `id` at `now_ms`.
    pub fn opacityOf(self: *const ScrollbarVisibility, id: Id, hovered_id: Id, dragged_id: Id, now_ms: i64) f32 {
        if (id == .none) return 0;
        if (id == dragged_id) return kit.scroll_area.thumb_drag_opacity;
        if (id == hovered_id) return kit.scroll_area.thumb_hover_opacity;
        const entry = self.findConst(id) orelse return 0;
        return switch (entry.phase) {
            .pinned, .holding => kit.scroll_area.thumb_opacity,
            .fading => |start_ms| blk: {
                const elapsed = now_ms - start_ms;
                if (elapsed <= 0) break :blk kit.scroll_area.thumb_opacity;
                if (elapsed >= fade_ms) break :blk 0;
                const remaining = 1.0 - @as(f32, @floatFromInt(elapsed)) / @as(f32, @floatFromInt(fade_ms));
                break :blk kit.scroll_area.thumb_opacity * remaining;
            },
            .hidden => 0,
        };
    }
};

/// Applies auto-hide opacity and active hover/drag widening to every laid-out
/// scrollbar thumb on `tree` before painting.
pub fn applyScrollbarHighlight(
    tree: *Tree,
    theme: *const Theme,
    visibility: *const ScrollbarVisibility,
    hovered_id: Id,
    dragged_id: Id,
    now_ms: i64,
) void {
    for (tree.scrolls[0..tree.scroll_len]) |region| {
        if (region.id == .none or region.thumb == Tree.none) continue;
        const thumb = &tree.nodes[region.thumb];
        if (thumb.rect.w <= 0 or thumb.rect.h <= 0) continue;

        const active = region.id == dragged_id or region.id == hovered_id;
        const opacity = visibility.opacityOf(region.id, hovered_id, dragged_id, now_ms);
        if (opacity <= 0) {
            thumb.box.fill = .transparent;
            continue;
        }
        if (active) {
            const viewport = tree.nodes[region.node].rect;
            const vertical = region.max.y > 0 and
                viewport.w > Tree.Scroll.thumb_thickness + Tree.Scroll.thumb_inset * 2 and
                viewport.h > Tree.Scroll.thumb_track_pad * 2;
            if (vertical) {
                const right = thumb.rect.x + thumb.rect.w;
                thumb.rect.w = kit.scroll_area.thumb_active_thickness;
                thumb.rect.x = right - thumb.rect.w;
            } else {
                const bottom = thumb.rect.y + thumb.rect.h;
                thumb.rect.h = kit.scroll_area.thumb_active_thickness;
                thumb.rect.y = bottom - thumb.rect.h;
            }
            thumb.box.radius = kit.scroll_area.thumb_active_radius;
        }
        thumb.box.fill = theme.muted_foreground.fade(opacity);
    }
}

/// What the host itself takes from the config: the theme from `[ui]
/// color_scheme`, against the terminal theme's background for `auto`, and
/// `[window] platform`.
const Settings = struct {
    theme: *const Theme,
    platform: window_config.Platform,

    fn of(config: *const Config) Settings {
        const background = config.resolvedTheme().background;
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

    return .init(.{
        .regular = regular,
        .medium = medium,
        .semibold = semibold,
    }, .{ .scale = scale });
}

/// Best effort: the process exits right after, with status 1 either way.
fn writeStderr(msg: []const u8) void {
    _ = std.posix.system.write(std.posix.STDERR_FILENO, msg.ptr, msg.len);
}

fn reapChild(pid: std.posix.pid_t) void {
    var status: c_int = undefined;
    while (true) {
        const rc = std.posix.system.waitpid(pid, &status, 0);
        if (rc == pid or std.posix.errno(rc) != .INTR) return;
    }
}
