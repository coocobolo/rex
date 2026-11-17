//! A GLFW window behind the opaque Rex handle. All GLFW types stay in this
//! file and its siblings under `src/platform/glfw/`.

const std = @import("std");

const c = @import("glfw");
const gl = @import("../../renderer/gl.zig");
const Dimension = @import("../../renderer/dimension.zig").Dimension;

const log = std.log.scoped(.platform);

/// The standard cursor shapes a window can show.
pub const PointerShape = enum(u8) {
    arrow,
    hand,
    text,
};

/// The two Xlib functions the bell needs. Rex does not link libX11; GLFW
/// loads it at runtime, so opening it again only takes another reference.
pub const Xlib = struct {
    /// The opaque X display type used by Xlib.
    pub const Display = opaque {};
    /// The runtime library that provides the bell entry points.
    pub const soname = "libX11.so.6";

    lib: std.DynLib,
    bell: *const fn (*Display, c_int) callconv(.c) c_int,
    flush: *const fn (*Display) callconv(.c) c_int,

    /// Loads the Xlib bell entry points at runtime.
    pub fn load() !Xlib {
        var lib = try std.DynLib.openZ(soname);
        errdefer lib.close();
        const bell = lib.lookup(*const fn (*Display, c_int) callconv(.c) c_int, "XBell") orelse
            return error.SymbolNotFound;
        const flush = lib.lookup(*const fn (*Display) callconv(.c) c_int, "XFlush") orelse
            return error.SymbolNotFound;
        return .{ .lib = lib, .bell = bell, .flush = flush };
    }

    /// Closes the Xlib library.
    pub fn close(self: *Xlib) void {
        self.lib.close();
        self.* = undefined;
    }
};

const has_x11 = @import("builtin").os.tag == .linux or @import("builtin").os.tag == .freebsd;

extern "c" fn glfwGetX11Display() ?*Xlib.Display;
extern "c" fn glfwSetX11SelectionString(string: [*:0]const u8) void;
extern "c" fn glfwGetX11SelectionString() ?[*:0]const u8;

/// The size and title requested for a new window.
pub const InitOption = struct {
    width: u16,
    height: u16,
    title: [:0]const u8,
};

/// A GLFW window and the state that belongs to it.
pub const WindowImpl = struct {
    handle: *c.GLFWwindow,
    /// Application context, set and read through the platform API. GLFW's
    /// user pointer is reserved for the window impl so callbacks can route.
    context: ?*anyopaque = null,
    xlib: union(enum) { unloaded, loaded: Xlib, failed } = .unloaded,
    silent_bell_logged: bool = false,
    no_primary_logged: bool = false,
    pointer_visible: bool = true,
    cursors: [@typeInfo(PointerShape).@"enum".fields.len]?*c.GLFWcursor = @splat(null),
    pointer_shape: PointerShape = .arrow,

    /// Creates a window with a GL context and loads GLAD through the given loader.
    pub fn init(option: InitOption, loader: gl.GLADloadproc) !WindowImpl {
        c.glfwWindowHint(c.GLFW_DECORATED, c.GLFW_TRUE);
        c.glfwWindowHint(c.GLFW_RESIZABLE, c.GLFW_TRUE);
        c.glfwWindowHint(c.GLFW_FOCUSED, c.GLFW_TRUE);
        c.glfwWindowHint(c.GLFW_TRANSPARENT_FRAMEBUFFER, c.GLFW_TRUE);
        c.glfwWindowHint(c.GLFW_SCALE_TO_MONITOR, c.GLFW_TRUE);
        c.glfwWindowHintString(c.GLFW_WAYLAND_APP_ID, "rex");
        c.glfwWindowHintString(c.GLFW_X11_CLASS_NAME, "rex");
        c.glfwWindowHintString(c.GLFW_X11_INSTANCE_NAME, "rex");

        const handle = c.glfwCreateWindow(
            @intCast(option.width),
            @intCast(option.height),
            option.title.ptr,
            null,
            null,
        ) orelse {
            log.err("cannot create a window with an OpenGL 3.3 core context", .{});
            return error.WindowCreatedFailed;
        };
        c.glfwMakeContextCurrent(handle);
        c.glfwSwapInterval(1);
        if (gl.gladLoadGLLoader(loader) == 0) return error.GladLoadFailed;

        var profile: c_int = 0;
        gl.getIntegerv(gl.CONTEXT_PROFILE_MASK, &profile);
        if (profile & gl.CONTEXT_CORE_PROFILE_BIT == 0) {
            log.warn("got compatibility profile, not core", .{});
        }

        // The user pointer is set by the backend once this value is in its
        // final slot; a pointer to this local would dangle on return.
        return .{ .handle = handle };
    }

    /// Destroys the window and its cursor and Xlib state.
    pub fn deinit(self: *WindowImpl) void {
        for (self.cursors) |cursor| if (cursor) |made| c.glfwDestroyCursor(made);
        switch (self.xlib) {
            .loaded => |*xlib| xlib.close(),
            .unloaded, .failed => {},
        }
        c.glfwDestroyWindow(self.handle);
        self.* = undefined;
    }

    /// Associates an application pointer with the window.
    pub fn setContext(self: *WindowImpl, ptr: ?*anyopaque) void {
        self.context = ptr;
    }

    /// The application pointer set on the window.
    pub fn getContext(self: *const WindowImpl) ?*anyopaque {
        return self.context;
    }

    /// Sets the title shown by the desktop.
    pub fn setTitle(self: *WindowImpl, title: [:0]const u8) void {
        c.glfwSetWindowTitle(self.handle, title.ptr);
    }

    /// Whether the window system has asked the window to close.
    pub fn shouldClose(self: *const WindowImpl) bool {
        return c.glfwWindowShouldClose(self.handle) != 0;
    }

    /// Marks the window to close on the next event loop pass.
    pub fn setShouldClose(self: *const WindowImpl, set: bool) void {
        c.glfwWindowShouldClose(self.handle, if (set) c.GLFW_TRUE else c.GLFW_FALSE);
    }

    /// Presents the rendered frame.
    pub fn swapBuffers(self: *const WindowImpl) void {
        c.glfwSwapBuffers(self.handle);
    }

    /// The drawable size in pixels, converted to T.
    pub fn framebufferSize(self: *const WindowImpl, comptime T: type) Dimension(T) {
        var width: c_int = 0;
        var height: c_int = 0;
        c.glfwGetFramebufferSize(self.handle, &width, &height);
        return .{
            .width = convert(T, width),
            .height = convert(T, height),
        };
    }

    fn convert(comptime T: type, value: c_int) T {
        return switch (@typeInfo(T)) {
            .int => @intCast(@max(value, 0)),
            .float => @floatFromInt(value),
            else => @compileError("Dimension only supports comptime int or float types"),
        };
    }

    /// The scale from logical to device pixels.
    pub fn contentScale(self: *const WindowImpl) Dimension(f32) {
        var scale: Dimension(f32) = .empty;
        c.glfwGetWindowContentScale(self.handle, &scale.width, &scale.height);
        return scale;
    }

    /// Whether the window currently has input focus.
    pub fn focused(self: *const WindowImpl) bool {
        return c.glfwGetWindowAttrib(self.handle, c.GLFW_FOCUSED) == c.GLFW_TRUE;
    }

    /// Sets the smallest size the user may resize to.
    pub fn setMinimumSize(self: *const WindowImpl, width: c_int, height: c_int) void {
        c.glfwSetWindowSizeLimits(self.handle, width, height, c.GLFW_DONT_CARE, c.GLFW_DONT_CARE);
    }

    /// Shows the given standard cursor while the pointer is over the window.
    pub fn setPointerShape(self: *WindowImpl, shape: PointerShape) void {
        if (shape == self.pointer_shape) return;
        const slot = &self.cursors[@intFromEnum(shape)];
        if (slot.* == null and shape != .arrow) {
            slot.* = c.glfwCreateStandardCursor(switch (shape) {
                .arrow => unreachable,
                .hand => c.GLFW_POINTING_HAND_CURSOR,
                .text => c.GLFW_IBEAM_CURSOR,
            });
            if (slot.* == null) return;
        }
        c.glfwSetCursor(self.handle, slot.*);
        self.pointer_shape = shape;
    }

    /// Shows or hides the pointer over the window.
    pub fn setPointerVisible(self: *WindowImpl, visible: bool) void {
        if (visible == self.pointer_visible) return;
        c.glfwSetInputMode(
            self.handle,
            c.GLFW_CURSOR,
            if (visible) c.GLFW_CURSOR_NORMAL else c.GLFW_CURSOR_HIDDEN,
        );
        self.pointer_visible = visible;
    }

    /// Sets the CLIPBOARD selection to the given text.
    pub fn setClipboard(self: *const WindowImpl, text: [:0]const u8) void {
        c.glfwSetClipboardString(self.handle, text.ptr);
    }

    /// The CLIPBOARD selection, or null when it holds no text. GLFW owns the
    /// bytes until the next selection call on the window.
    pub fn getClipboard(self: *const WindowImpl) ?[:0]const u8 {
        const raw = c.glfwGetClipboardString(self.handle) orelse return null;
        return std.mem.span(raw);
    }

    /// The PRIMARY selection where the platform provides one.
    pub fn getPrimarySelection(self: *const WindowImpl) ?[:0]const u8 {
        _ = self;
        if (!has_x11 or c.glfwGetPlatform() != c.GLFW_PLATFORM_X11) return null;
        const raw = glfwGetX11SelectionString() orelse return null;
        return std.mem.span(raw);
    }

    /// Sets PRIMARY where supported, returning false when unavailable.
    pub fn setPrimarySelection(self: *WindowImpl, text: [:0]const u8) bool {
        if (has_x11 and c.glfwGetPlatform() == c.GLFW_PLATFORM_X11) {
            glfwSetX11SelectionString(text.ptr);
            return true;
        }
        if (!self.no_primary_logged) {
            self.no_primary_logged = true;
            log.info("no PRIMARY selection on this platform; only CLIPBOARD is set", .{});
        }
        return false;
    }

    /// Asks the desktop to draw attention to the window.
    pub fn requestAttention(self: *const WindowImpl) void {
        c.glfwRequestWindowAttention(self.handle);
    }

    /// Clamps a volume fraction to the percent XBell accepts.
    pub fn bellVolume(volume: f32) u8 {
        const fraction = if (std.math.isFinite(volume)) std.math.clamp(volume, 0, 1) else 0;
        return @intFromFloat(@round(fraction * 100));
    }

    /// Asks for attention and, on X11, rings the bell at `volume` on GLFW's
    /// own display. Elsewhere this is logged once and only asks for attention.
    pub fn ringBell(self: *WindowImpl, volume: f32) void {
        self.requestAttention();
        if (!has_x11 or c.glfwGetPlatform() != c.GLFW_PLATFORM_X11) {
            self.logSilentBell("no audible bell on this platform");
            return;
        }
        const display = glfwGetX11Display() orelse return self.logSilentBell("GLFW has no X11 display");
        if (self.xlib == .unloaded) {
            self.xlib = if (Xlib.load()) |xlib| .{ .loaded = xlib } else |err| blk: {
                log.warn("bell: cannot load {s}: {}", .{ Xlib.soname, err });
                break :blk .failed;
            };
        }
        switch (self.xlib) {
            .loaded => |xlib| {
                _ = xlib.bell(display, bellVolume(volume));
                _ = xlib.flush(display);
            },
            .failed => self.logSilentBell("Xlib is unavailable"),
            .unloaded => unreachable,
        }
    }

    fn logSilentBell(self: *WindowImpl, reason: []const u8) void {
        if (self.silent_bell_logged) return;
        self.silent_bell_logged = true;
        log.info("bell: {s}; it only asks for window attention", .{reason});
    }
};
