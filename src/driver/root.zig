//! Driver subsystem managing communication between the terminal emulator core,
//! the OS pseudo-terminal (PTY), and the GUI thread.
//!
//! Exposes a polymorphic `Driver(option)` union dispatching between synchronous
//! `SingleDriver` execution and asynchronous `ThreadedDriver` execution backed
//! by `TripleBuffer` frame publishing and lock-free `InputQueue` event delivery.
//! Also provides canonical selection extraction and scrollback anchor resolution.

const std = @import("std");
const Allocator = std.mem.Allocator;
const posix = std.posix;
const term = @import("../term/root.zig");
const Option = term.Option;
const termio = @import("../termio/root.zig");
const Pty = termio.pty.Posix;
const Theme = @import("../color/Theme.zig");
const Selection = @import("../Selection.zig");

pub const single = @import("single.zig");
pub const threaded = @import("threaded.zig");
pub const triple_buffer = @import("triple_buffer.zig");
pub const InputQueue = @import("InputQueue.zig");
pub const OutboundQueue = @import("OutboundQueue.zig");
pub const latency_trace = @import("latency_trace.zig");

pub const Events = @import("Events.zig");
pub const EventBits = Events.Bits;
pub const EventSet = Events.Set;

pub const Single = single.Driver;
pub const Threaded = threaded.Driver;
pub const TripleBuffer = triple_buffer.Buffer;

pub const SingleDriver = Single;
pub const ThreadedDriver = Threaded;
pub const InputEvent = InputQueue.InputEvent;
pub const WakeupChannel = InputQueue.WakeupChannel;

test {
    _ = @import("Events.zig");
    _ = @import("InputQueue.zig");
    _ = @import("latency_trace_test.zig");
    _ = @import("OutboundQueue.zig");
    _ = @import("paste_test.zig");
    _ = @import("triple_buffer.zig");
    _ = @import("single.zig");
    _ = @import("threaded.zig");
    std.testing.refAllDecls(@This());
}

/// Terminal modes shared atomically between driver and GUI thread.
pub const SharedModes = packed struct(u32) {
    cursor_keys: bool = false,
    keypad_app: bool = false,
    modify_other_keys: u2 = 0,
    mouse_reporting: bool = false,
    bracketed_paste: bool = false,
    focus_events: bool = false,
    reports_wheel: bool = false,
    reports_motion: bool = false,
    _pad: u23 = 0,

    /// Bitcast helper to u32 for atomic storage.
    pub inline fn toU32(self: SharedModes) u32 {
        return @bitCast(self);
    }

    /// Bitcast helper from u32 from atomic storage.
    pub inline fn fromU32(val: u32) SharedModes {
        return @bitCast(val);
    }
};

/// Settings both drivers start the terminal with. Every field without a
/// default is the caller's to choose, since the defaults live in the
/// config. Passed by value, so it holds no pointers. Read only when the
/// driver starts; a setting that changes later takes its own route, as the
/// theme does through `setTheme`.
pub const Options = struct {
    theme: Theme,
    /// Longest a synchronized-output (mode 2026) hold lasts.
    sync_output_timeout_ms: u32,
    /// The TERM the shell started with, reported by XTGETTCAP `TN`.
    term_name: term.term.TermName = .empty,
};

/// An OSC 52 request taken from the terminal (ADR 0006).
pub const ClipboardRequest = union(enum) {
    /// Set the targets to `data`, a slice of the caller's buffer. Empty
    /// data clears them.
    write: struct { targets: term.term.Clipboard.Targets, data: []const u8 },
    /// Reply with the targets' content, framed in `control_format`.
    read: struct { targets: term.term.Clipboard.Targets, control_format: term.term.ControlFormat },
};

pub const resolveAnchor = Selection.resolveAnchor;
pub const extractSelectionText = Selection.extractText;

/// Unified polymorphic driver interface dispatching between Single and Threaded drivers.
pub fn Driver(comptime option: Option) type {
    const SingleType = Single(option);
    const ThreadedType = Threaded(option);
    const FrameType = term.Frame(option);

    return union(enum) {
        single: SingleType,
        threaded: *ThreadedType,

        const Self = @This();

        /// Releases resources owned by the driver, destroying the terminal,
        /// freeing buffers, and closing the PTY.
        pub fn deinit(self: *Self) void {
            switch (self.*) {
                .single => |*d| d.deinit(),
                .threaded => |d| d.destroy(),
            }
        }

        /// Sets the callback invoked to wake the GUI event loop on new frames or events.
        pub fn setWakeupFn(self: *Self, wake: ?*const fn () void) void {
            switch (self.*) {
                .single => {},
                .threaded => |d| d.setWakeupFn(wake),
            }
        }

        /// Updates the active terminal color theme dynamically.
        pub fn setTheme(self: *Self, theme: Theme) void {
            switch (self.*) {
                .single => |*d| d.setTheme(theme),
                .threaded => |d| _ = d.sendInput(.{ .set_theme = theme }),
            }
        }

        /// Drains accumulated driver events and checks if a fresh frame is ready.
        pub fn pollAndDrain(self: *Self) !Events {
            return switch (self.*) {
                .single => |*d| d.pollAndDrain(),
                .threaded => |d| d.pollAndDrain(),
            };
        }

        /// Returns the freshest viewport snapshot.
        pub fn getFrame(self: *const Self) *const FrameType {
            return switch (self.*) {
                .single => |*d| d.getFrame(),
                .threaded => |d| d.getFrame(),
            };
        }

        /// The traced key whose echo is the newest one in the frame
        /// `getFrame` returned last, or 0. Only the threaded driver traces.
        pub fn latencyFrameSeq(self: *const Self) u32 {
            return switch (self.*) {
                .single => 0,
                .threaded => |d| d.latencyFrameSeq(),
            };
        }

        /// Returns true if a fresh frame is waiting in the triple buffer.
        pub fn hasNewFrame(self: *const Self) bool {
            return switch (self.*) {
                .single => false,
                .threaded => |d| d.hasNewFrame(),
            };
        }

        /// Sends an input event (keystroke, mouse, resize, focus) to the driver.
        pub fn sendInput(self: *Self, event: InputEvent) !void {
            switch (self.*) {
                .single => |*d| try d.sendInput(event),
                .threaded => |d| {
                    if (!d.sendInput(event)) return error.InputQueueFull;
                },
            }
        }

        /// Sends raw bytes to the child process via the PTY.
        pub fn sendBytes(self: *Self, bytes: []const u8) !void {
            switch (self.*) {
                .single => |*d| try d.sendBytes(bytes),
                .threaded => |d| try d.sendBytes(bytes),
            }
        }

        /// Writes a reply too big for the terminal's reply queue (an OSC 52
        /// read) to the PTY as is, never bracketed.
        pub fn sendReply(self: *Self, bytes: []const u8) !void {
            switch (self.*) {
                .single => |*d| try d.sendReply(bytes),
                .threaded => |d| try d.sendReply(bytes),
            }
        }

        /// Writes pasted clipboard text to the PTY.
        pub fn writePaste(self: *Self, text: []const u8) !void {
            switch (self.*) {
                .single => |*d| try d.writePaste(text),
                .threaded => |d| try d.writePaste(text),
            }
        }

        /// Returns a snapshot of shared terminal modes (cursor keys, mouse tracking, etc.).
        pub fn getModes(self: *const Self) SharedModes {
            return switch (self.*) {
                .single => |*d| d.getModes(),
                .threaded => |d| d.getModes(),
            };
        }

        /// Takes the pending OSC 52 request, copying a write's data into
        /// `buf`. Null when none is pending.
        pub fn takeClipboard(self: *Self, buf: *[option.max_clipboard_bytes]u8) ?ClipboardRequest {
            return switch (self.*) {
                .single => |*d| d.takeClipboard(buf),
                .threaded => |d| d.takeClipboard(buf),
            };
        }

        /// Copies the terminal's title into `buf` and returns it. Empty
        /// until a program sets one with OSC 0 or 2, and after RIS.
        pub fn copyTitle(self: *const Self, buf: *[term.max_title_len:0]u8) [:0]const u8 {
            return switch (self.*) {
                .single => |*d| d.copyTitle(buf),
                .threaded => |d| d.copyTitle(buf),
            };
        }

        /// Returns the process ID of the child process running on the PTY.
        pub fn getPid(self: *const Self) posix.pid_t {
            return switch (self.*) {
                .single => |*d| d.getPid(),
                .threaded => |d| d.getPid(),
            };
        }

        /// Returns the file descriptor of the master PTY end.
        pub fn getMasterFd(self: *const Self) posix.fd_t {
            return switch (self.*) {
                .single => |*d| d.pty.master,
                .threaded => |d| d.pty.master,
            };
        }

        /// Copies selected text into `buf` without allocating. Returns bytes written.
        pub fn copySelectionText(self: *Self, selection: anytype, buf: []u8) usize {
            return switch (self.*) {
                .single => |*d| d.copySelectionText(selection, buf),
                .threaded => |d| d.copySelectionText(selection, buf),
            };
        }
    };
}

test "driver: SharedModes packing and bit conversion" {
    const testing = std.testing;
    var modes = SharedModes{
        .cursor_keys = true,
        .keypad_app = true,
        .modify_other_keys = 2,
        .mouse_reporting = true,
        .bracketed_paste = true,
        .focus_events = true,
        .reports_wheel = true,
        .reports_motion = true,
    };

    const raw = modes.toU32();
    const unpacked = SharedModes.fromU32(raw);

    try testing.expect(unpacked.cursor_keys);
    try testing.expect(unpacked.keypad_app);
    try testing.expectEqual(@as(u2, 2), unpacked.modify_other_keys);
    try testing.expect(unpacked.mouse_reporting);
    try testing.expect(unpacked.bracketed_paste);
    try testing.expect(unpacked.focus_events);
    try testing.expect(unpacked.reports_wheel);
    try testing.expect(unpacked.reports_motion);
}

test "driver: resolveAnchor coordinate calculations" {
    const testing = std.testing;

    // Normal anchor within viewport (captured_scroll_gen == total_lines_scrolled -> delta = 0)
    const norm = resolveAnchor(
        .{ .row = 5, .captured_scroll_gen = 100 },
        100, // total_lines_scrolled
        50, // scrollback_used
    );
    try testing.expect(norm != null);
    try testing.expectEqual(@as(i64, 5), norm.?);

    // Anchor scrolled backwards by 10 lines (delta = 110 - 100 = 10)
    const scrolled = resolveAnchor(
        .{ .row = 5, .captured_scroll_gen = 100 },
        110, // total_lines_scrolled
        50, // scrollback_used
    );
    try testing.expect(scrolled != null);
    try testing.expectEqual(@as(i64, -5), scrolled.?);

    // Anchor evicted past scrollback capacity
    const evicted = resolveAnchor(
        .{ .row = 0, .captured_scroll_gen = 0 },
        100, // total_lines_scrolled
        50, // scrollback_used (evicted since -100 < -50)
    );
    try testing.expect(evicted == null);
}

test "driver: Driver polymorphic union dispatch" {
    const testing = std.testing;
    const opt: Option = .{
        .max_rows = 24,
        .max_cols = 80,
        .max_scrollback = 100,
    };

    {
        const s: Single(opt) = try .init(testing.allocator, testing.io, Pty.inactive, .{ .theme = Theme.graphite, .sync_output_timeout_ms = 150 });
        var driver: Driver(opt) = .{ .single = s };
        defer driver.deinit();

        try testing.expect(!driver.hasNewFrame());
        const frame = driver.getFrame();
        try testing.expectEqual(@as(u16, 24), frame.active_rows);
        try testing.expectEqual(@as(u16, 80), frame.active_cols);

        const modes = driver.getModes();
        try testing.expect(!modes.mouse_reporting);
        try testing.expectEqual(Pty.inactive.master, driver.getMasterFd());
    }

    {
        const th: *Threaded(opt) = try .create(testing.allocator, testing.io, Pty.inactive, .{ .theme = Theme.graphite, .sync_output_timeout_ms = 200 }, latency_trace.none);
        var driver: Driver(opt) = .{ .threaded = th };
        defer driver.deinit();

        const frame = driver.getFrame();
        try testing.expectEqual(@as(u16, 24), frame.active_rows);
        try testing.expectEqual(@as(u16, 80), frame.active_cols);

        const modes = driver.getModes();
        try testing.expect(!modes.mouse_reporting);
        try testing.expect(!modes.reports_motion);
        try testing.expectEqual(Pty.inactive.master, driver.getMasterFd());

        driver.setWakeupFn(null);
        driver.setTheme(Theme.graphite);
    }
}

test "driver: extractSelectionText omits newline on soft-wrapped rows" {
    const testing = std.testing;
    const opt: Option = .{
        .max_rows = 10,
        .max_cols = 5,
        .max_scrollback = 10,
    };

    var t = try term.Terminal(opt).create(testing.allocator);
    defer t.destroy(testing.allocator);

    // "HELLO" soft-wraps into "WORLD", followed by hard newline and "DONE"
    t.feed("HELLOWORLDDONE");

    var buf: [64]u8 = undefined;
    const n = extractSelectionText(
        t.active(),
        .{
            .kind = .character,
            .range = .{
                .start = .{ .row = 0, .col = 0, .captured_scroll_gen = 0 },
                .end = .{ .row = 2, .col = 4, .captured_scroll_gen = 0 },
            },
        },
        &buf,
    );
    try testing.expectEqualStrings("HELLOWORLDDONE", buf[0..n]);

    // Block selection still preserves newline breaks per visual row
    const n_block = extractSelectionText(
        t.active(),
        .{
            .kind = .block,
            .range = .{
                .start = .{ .row = 0, .col = 0, .captured_scroll_gen = 0 },
                .end = .{ .row = 1, .col = 4, .captured_scroll_gen = 0 },
            },
        },
        &buf,
    );
    try testing.expectEqualStrings("HELLO\nWORLD", buf[0..n_block]);
}
