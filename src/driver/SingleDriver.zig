//! SingleDriver: synchronous single-threaded terminal driver.
//!
//! Encapsulates a Terminal emulator and POSIX PTY running directly on the
//! main/GUI thread. All PTY reading, terminal parsing, reply writing, and
//! viewport snapshotting happen synchronously without thread hops.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const posix = std.posix;
const system = posix.system;

const log = std.log.scoped(.single_driver);

const term = @import("../term/root.zig");
const Terminal = term.Terminal;
const Frame = term.Frame;
const Option = term.Option;
const Theme = term.Theme;
const Cell = term.cell.Cell;
const MouseButton = term.term.MouseButton;
const HeldButtons = term.term.HeldButtons;

const termio = @import("../termio/root.zig");
const Pty = termio.pty.Posix;

const InputQueueMod = @import("InputQueue.zig");
pub const InputEvent = InputQueueMod.InputEvent;
const getMonotonicMs = @import("root.zig").getMonotonicMs;

/// Aggregated driver events returned from `pollAndDrain`.
pub const DriverEvents = struct {
    bell: bool = false,
    title: bool = false,
    icon_name: bool = false,
    cursor_color: bool = false,
    selection_reset: bool = false,
    hard_reset: bool = false,
    resize: ?term.Events.Resize = null,
    child_closed: bool = false,
    had_data: bool = false,

    pub inline fn any(self: DriverEvents) bool {
        return self.bell or self.title or self.icon_name or
            self.cursor_color or self.selection_reset or
            self.hard_reset or self.resize != null or
            self.child_closed or self.had_data;
    }
};

/// Terminal modes shared between driver and GUI thread.
pub const SharedModes = packed struct(u32) {
    cursor_keys: bool = false,
    keypad_app: bool = false,
    modify_other_keys: u2 = 0,
    mouse_reporting: bool = false,
    bracketed_paste: bool = false,
    focus_events: bool = false,
    reports_wheel: bool = false,
    _pad: u24 = 0,
};

/// Synchronous terminal driver parameterized by terminal capacity `Option`.
pub fn SingleDriver(comptime option: Option) type {
    const TerminalType = Terminal(option);
    const FrameType = Frame(option);

    return struct {
        const Self = @This();

        allocator: Allocator,
        pty: Pty,
        terminal: TerminalType,
        frame_snapshot: FrameType,
        sync_start_ms: i64 = 0,
        sync_output_timeout_ms: u32 = 150,

        pub const Events = DriverEvents;
        pub const Modes = SharedModes;

        /// Initializes the SingleDriver with default 150ms synchronized output timeout.
        pub fn init(allocator: Allocator, pty: Pty, theme: Theme) !Self {
            return initWithTimeout(allocator, pty, theme, 150);
        }

        /// Initializes the SingleDriver with a custom synchronized output timeout.
        pub fn initWithTimeout(allocator: Allocator, pty: Pty, theme: Theme, sync_output_timeout_ms: u32) !Self {
            var terminal = try TerminalType.create(allocator);
            errdefer terminal.destroy(allocator);

            terminal.setTheme(theme);

            var frame_snapshot = try FrameType.init(allocator);
            errdefer frame_snapshot.deinit(allocator);

            return .{
                .allocator = allocator,
                .pty = pty,
                .terminal = terminal,
                .frame_snapshot = frame_snapshot,
                .sync_output_timeout_ms = sync_output_timeout_ms,
            };
        }

        /// Releases resources owned by the driver, destroying the terminal,
        /// freeing the frame snapshot buffer, and closing the PTY.
        pub fn deinit(self: *Self, io: std.Io) void {
            self.frame_snapshot.deinit(self.allocator);
            self.terminal.destroy(self.allocator);
            self.pty.close(io);
        }

        /// Non-blocking drain of all pending PTY output into the terminal parser,
        /// writing any protocol replies back to the PTY, and collecting events.
        pub fn pollAndDrain(self: *Self) !Events {
            var events: Events = .{};
            var buffer: [64 * 1024]u8 align(64) = undefined;
            var total_read: usize = 0;

            drain: while (true) {
                const n = self.pty.readRaw(&buffer) catch |err| switch (err) {
                    error.WouldBlock => break :drain,
                    // On Linux, PTY reports EIO when the child side exits.
                    error.InputOutput => {
                        events.child_closed = true;
                        break :drain;
                    },
                    else => return err,
                };

                if (n == 0) {
                    events.child_closed = true;
                    break :drain;
                }

                self.terminal.feed(buffer[0..n]);
                total_read += n;
            }

            if (total_read > 0) {
                events.had_data = true;

                // Drain replies once per batch
                self.drainAndWriteReplies();

                if (self.terminal.events.any()) {
                    self.accumulateEvents(&events, self.terminal.takeEvents());
                }
            }

            if (events.child_closed) {
                self.terminal.end();
                if (self.terminal.events.any()) {
                    self.accumulateEvents(&events, self.terminal.takeEvents());
                }
            }

            var in_sync_hold = false;
            if (self.terminal.mode.synchronized_output) {
                if (self.sync_start_ms == 0) self.sync_start_ms = getMonotonicMs();
                const elapsed = getMonotonicMs() - self.sync_start_ms;
                in_sync_hold = elapsed < self.sync_output_timeout_ms;
            } else {
                self.sync_start_ms = 0;
            }

            if (events.had_data and !in_sync_hold) {
                _ = self.terminal.snapshot(&self.frame_snapshot);
            }

            return events;
        }

        fn accumulateEvents(self: *Self, dst: *Events, src: term.Events) void {
            _ = self;
            if (src.bell) dst.bell = true;
            if (src.title) dst.title = true;
            if (src.icon_name) dst.icon_name = true;
            if (src.cursor_color) dst.cursor_color = true;
            if (src.selection_reset) dst.selection_reset = true;
            if (src.hard_reset) dst.hard_reset = true;
            if (src.resize) |r| dst.resize = r;
        }

        /// Flushes any pending responses generated by the terminal back to the PTY.
        pub fn drainAndWriteReplies(self: *Self) void {
            var reply_buf: [1024]u8 = undefined;
            while (true) {
                const n = self.terminal.drainReplies(&reply_buf);
                if (n == 0) break;
                _ = self.pty.writeAll(reply_buf[0..n]) catch |err| {
                    log.err("failed to write terminal reply to pty: {}", .{err});
                    break;
                };
            }
        }

        /// Processes an input event (keyboard, mouse, resize, focus, paste).
        pub fn sendInput(self: *Self, event: InputEvent) !void {
            switch (event) {
                .bytes => |b| {
                    _ = self.pty.writeAll(b.data[0..b.len]) catch |err| {
                        log.err("failed to write bytes to pty: {}", .{err});
                        return err;
                    };
                },
                .paste => |text| {
                    try self.writePaste(text);
                },
                .mouse_button => |ev| {
                    self.terminal.sendMouse(ev.col, ev.row, ev.button, ev.mods, ev.press);
                    self.drainAndWriteReplies();
                },
                .mouse_motion => |ev| {
                    const held_button: ?MouseButton = if (ev.button) |b|
                        @enumFromInt(b)
                    else
                        null;
                    self.terminal.sendMouseMotion(ev.col, ev.row, held_button, ev.mods);
                    self.drainAndWriteReplies();
                },
                .mouse_scroll => |ev| {
                    if (self.terminal.mode.mouse_tracking.reportsWheel()) {
                        var i: u16 = 0;
                        while (i < ev.steps) : (i += 1) {
                            self.terminal.sendMouse(ev.col, ev.row, ev.button, 0, true);
                            self.drainAndWriteReplies();
                        }
                    } else {
                        if (self.terminal.active_buffer != .alternate) {
                            // Wheel up is button 64, wheel down is button 65
                            if (ev.button == 64) {
                                self.terminal.active().scrollViewportBack(ev.steps);
                            } else {
                                self.terminal.active().scrollViewportForward(ev.steps);
                            }
                        }
                    }
                },
                .viewport_scroll => |ev| {
                    if (ev.lines > 0) {
                        self.terminal.active().scrollViewportForward(@intCast(ev.lines));
                    } else if (ev.lines < 0) {
                        self.terminal.active().scrollViewportBack(@intCast(-ev.lines));
                    }
                },
                .set_viewport_offset => |offset| {
                    if (self.terminal.active_buffer == .primary) {
                        self.terminal.primary.viewport_offset = @min(offset, @as(u32, @intCast(self.terminal.primary.scrollback_used)));
                        self.terminal.primary.dirty_rows = .full;
                        self.terminal.primary.bump();
                    }
                },
                .resize => |ev| {
                    if (self.terminal.mode.column_132) {
                        const deccolm_cols = self.terminal.active().active_cols;
                        self.terminal.resize(ev.rows, deccolm_cols);
                        self.pty.resize(ev.rows, deccolm_cols, ev.pixel_width, ev.pixel_height) catch {};
                    } else {
                        self.terminal.resize(ev.rows, ev.cols);
                        self.pty.resize(ev.rows, ev.cols, ev.pixel_width, ev.pixel_height) catch {};
                    }
                    self.terminal.active().dirty_rows = .full;
                    self.terminal.active().bump();
                },
                .focus => |focused| {
                    if (self.terminal.mode.focus_events) {
                        const seq = if (focused) "\x1b[I" else "\x1b[O";
                        _ = self.pty.writeAll(seq) catch |err| {
                            log.err("failed to write focus event: {}", .{err});
                            return err;
                        };
                    }
                },
                .hard_reset => {
                    self.terminal.hardReset();
                    self.terminal.active().dirty_rows = .full;
                    self.terminal.active().bump();
                },
            }
        }

        /// Writes pasted clipboard text, wrapping in bracketed paste escape sequences if enabled.
        pub fn writePaste(self: *Self, text: []const u8) !void {
            if (self.terminal.mode.bracketed_paste) {
                var iovecs = [_]posix.iovec_const{
                    .{ .base = "\x1b[200~", .len = 6 },
                    .{ .base = text.ptr, .len = text.len },
                    .{ .base = "\x1b[201~", .len = 6 },
                };
                self.pty.writevAll(&iovecs) catch |err| {
                    log.err("pty write failed: {}", .{err});
                    return err;
                };
            } else {
                _ = self.pty.writeAll(text) catch |err| {
                    log.err("pty write failed: {}", .{err});
                    return err;
                };
            }
        }

        /// Raw unformatted write to PTY.
        pub fn writeRaw(self: *Self, bytes: []const u8) !usize {
            try self.pty.writeAll(bytes);
            return bytes.len;
        }

        /// Updates the internal viewport snapshot from the terminal and returns a pointer to it.
        pub fn snapshot(self: *Self) *const FrameType {
            _ = self.terminal.snapshot(&self.frame_snapshot);
            return &self.frame_snapshot;
        }

        /// Updates the internal viewport snapshot. Returns true if modified.
        pub fn updateSnapshot(self: *Self) bool {
            return self.terminal.snapshot(&self.frame_snapshot);
        }

        /// Returns the most recently captured viewport snapshot.
        pub fn getFrame(self: *const Self) *const FrameType {
            return &self.frame_snapshot;
        }

        /// Returns terminal mode flags.
        pub fn getModes(self: *const Self) SharedModes {
            return .{
                .cursor_keys = self.terminal.mode.cursor_keys,
                .keypad_app = self.terminal.mode.keypad_app,
                .modify_other_keys = self.terminal.mode.modify_other_keys,
                .mouse_reporting = self.terminal.mode.isMouseReporting(),
                .bracketed_paste = self.terminal.mode.bracketed_paste,
                .focus_events = self.terminal.mode.focus_events,
                .reports_wheel = self.terminal.mode.mouse_tracking.reportsWheel(),
            };
        }

        /// Returns the window title set by OSC 0/2.
        pub fn getTitle(self: *const Self) []const u8 {
            return self.terminal.getTitle();
        }

        /// Returns the child process PID.
        pub fn getPid(self: *const Self) posix.pid_t {
            return self.pty.pid;
        }

        /// Helper to send raw bytes directly.
        pub fn sendBytes(self: *Self, bytes: []const u8) !void {
            _ = try self.writeRaw(bytes);
        }

        /// Copies selected text into `buf` without allocating. Returns bytes written.
        pub fn copySelectionText(self: *Self, selection: anytype, buf: []u8) usize {
            return extractSelectionText(self.terminal.active(), selection, buf);
        }
    };
}

/// Resolves an anchor row in scrollback history space, returning null if evicted.
pub fn resolveAnchor(position: anytype, total_lines_scrolled: i64, scrollback_used: i64) ?i64 {
    const delta: i64 = total_lines_scrolled - position.captured_scroll_gen;
    const anchor_now: i64 = @as(i64, position.row) - delta;
    if (anchor_now < -scrollback_used) return null;
    return anchor_now;
}

/// Extracts UTF-8 text within `selection` from `screen` into `buf`.
pub fn extractSelectionText(screen: anytype, selection: anytype, buf: []u8) usize {
    const total_lines_scrolled = screen.total_lines_scrolled;
    const scrollback_used = screen.scrollbackUsedAs(i64);

    const start_anchor = resolveAnchor(selection.range.start, total_lines_scrolled, scrollback_used) orelse return 0;
    const end_anchor = resolveAnchor(selection.range.end, total_lines_scrolled, scrollback_used) orelse return 0;

    const start_col = selection.range.start.col;
    const end_col = selection.range.end.col;

    const lo_anchor, const lo_col, const hi_anchor, const hi_col = blk: {
        if (start_anchor < end_anchor or (start_anchor == end_anchor and start_col <= end_col)) {
            break :blk .{ start_anchor, start_col, end_anchor, end_col };
        } else {
            break :blk .{ end_anchor, end_col, start_anchor, start_col };
        }
    };

    const active_rows: i64 = @intCast(screen.active_rows);
    const clamped_lo: i64 = std.math.clamp(lo_anchor, -scrollback_used, active_rows - 1);
    const clamped_hi: i64 = std.math.clamp(hi_anchor, -scrollback_used, active_rows - 1);
    if (clamped_hi < clamped_lo) return 0;

    var pos: usize = 0;
    var anchor_row: i64 = clamped_lo;
    while (anchor_row <= clamped_hi) : (anchor_row += 1) {
        var col_start: usize = if (anchor_row == clamped_lo) lo_col else 0;
        const col_end: usize = if (anchor_row == clamped_hi) hi_col else @max(screen.active_cols, 1) - 1;

        if (col_start > 0) {
            const maybe_placeholder = screen.cellAtAnchor(anchor_row, col_start);
            if (maybe_placeholder.kind == .wide_right) col_start -= 1;
        }

        const row_start = pos;

        for (col_start..col_end + 1) |col| {
            const cell = screen.cellAtAnchor(anchor_row, col);
            if (pos + 4 > buf.len) break;

            switch (cell.kind) {
                .wide_right => continue,
                .empty => {
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
                .shaped => {},
            }
        }

        while (pos > row_start and buf[pos - 1] == ' ') pos -= 1;

        if (anchor_row < clamped_hi and pos < buf.len - 1) {
            buf[pos] = '\n';
            pos += 1;
        }
    }

    return pos;
}

test "SingleDriver: init, deinit, and snapshot" {
    const testing = std.testing;
    const test_option: Option = .{
        .max_rows = 24,
        .max_cols = 80,
        .max_scrollback = 100,
    };
    const Driver = SingleDriver(test_option);

    var driver = try Driver.init(testing.allocator, Pty.inactive, Theme.graphite);
    defer driver.deinit(testing.io);

    const frame = driver.snapshot();
    try testing.expectEqual(@as(u16, 24), frame.active_rows);
    try testing.expectEqual(@as(u16, 80), frame.active_cols);
    try testing.expect(!frame.is_alternate);
}

test "SingleDriver: mock socketpair PTY input and pollAndDrain" {
    const testing = std.testing;
    const test_option: Option = .{
        .max_rows = 24,
        .max_cols = 80,
        .max_scrollback = 100,
    };
    const Driver = SingleDriver(test_option);

    var sv: [2]posix.fd_t = undefined;
    const rc = system.socketpair(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.NONBLOCK, 0, &sv);
    try testing.expectEqual(@as(c_int, 0), rc);
    defer {
        _ = system.close(sv[1]);
    }

    const mock_pty: Pty = .{
        .master = sv[0],
        .pid = -1,
        .stdout_read_fd = -1,
        .error_read_fd = -1,
    };

    var driver = try Driver.init(testing.allocator, mock_pty, Theme.graphite);
    defer driver.deinit(testing.io);

    // 1. Send input from GUI to PTY
    try driver.sendInput(InputEvent.makeBytes("hello"));

    // Verify it arrived at the other end of the socketpair
    var read_buf: [128]u8 = undefined;
    const n_read = system.read(sv[1], &read_buf, read_buf.len);
    try testing.expectEqual(@as(isize, 5), n_read);
    try testing.expectEqualStrings("hello", read_buf[0..5]);

    // 2. Write data from simulated child into socketpair
    _ = system.write(sv[1], "RexTerm\r\n", 9);

    // Poll and drain through driver
    const events = try driver.pollAndDrain();
    try testing.expect(events.had_data);
    try testing.expect(!events.child_closed);

    // Snapshot and verify screen contents
    const frame = driver.snapshot();
    const row0 = frame.displayRow(0);
    try testing.expectEqual(@as(u21, 'R'), row0[0].codepoint);
    try testing.expectEqual(@as(u21, 'e'), row0[1].codepoint);
    try testing.expectEqual(@as(u21, 'x'), row0[2].codepoint);
}

test "SingleDriver: DA1 reply drained back to mock PTY" {
    const testing = std.testing;
    const test_option: Option = .{
        .max_rows = 24,
        .max_cols = 80,
        .max_scrollback = 100,
    };
    const Driver = SingleDriver(test_option);

    var sv: [2]posix.fd_t = undefined;
    const rc = system.socketpair(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.NONBLOCK, 0, &sv);
    try testing.expectEqual(@as(c_int, 0), rc);
    defer {
        _ = system.close(sv[1]);
    }

    const mock_pty: Pty = .{
        .master = sv[0],
        .pid = -1,
        .stdout_read_fd = -1,
        .error_read_fd = -1,
    };

    var driver = try Driver.init(testing.allocator, mock_pty, Theme.graphite);
    defer driver.deinit(testing.io);

    // Child sends CSI c (DA1 query)
    _ = system.write(sv[1], "\x1b[c", 3);

    const events = try driver.pollAndDrain();
    try testing.expect(events.had_data);

    // SingleDriver should have processed query, generated response, and drained to PTY
    var reply_buf: [128]u8 = undefined;
    const n = system.read(sv[1], &reply_buf, reply_buf.len);
    try testing.expect(n > 0);
    const n_u: usize = @intCast(n);
    try testing.expectEqualStrings("\x1b[?62;22;52c", reply_buf[0..n_u]);
}
