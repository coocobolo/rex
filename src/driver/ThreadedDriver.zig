//! ThreadedDriver: dedicated multi-threaded terminal driver.
//!
//! Spawns a dedicated background OS worker thread that owns the Terminal emulator
//! and POSIX PTY. The worker thread runs a poll() loop monitoring the PTY fd and
//! the InputQueue wakeup channel.
//!
//! Communication topology:
//! - GUI -> Driver: lock-free SPSC InputQueue backed by an eventfd/pipe2 OS wakeup channel.
//! - Driver -> GUI: wait-free TripleBuffer publishing term.Frame snapshots with Release/Acquire semantics.
//! - Mode 2026: Synchronized Output hold with 150ms timeout.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const posix = std.posix;
const system = posix.system;

const log = std.log.scoped(.threaded_driver);

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
pub const InputQueue = InputQueueMod.InputQueue;
pub const InputEvent = InputQueueMod.InputEvent;

const TripleBufferMod = @import("TripleBuffer.zig");
pub const TripleBuffer = TripleBufferMod.TripleBuffer;

const SingleDriverMod = @import("SingleDriver.zig");
pub const DriverEvents = SingleDriverMod.DriverEvents;
pub const SharedModes = SingleDriverMod.SharedModes;

// Bitmasks for shared_events atomic word
const EVENT_BELL: u32 = 1 << 0;
const EVENT_TITLE: u32 = 1 << 1;
const EVENT_ICON_NAME: u32 = 1 << 2;
const EVENT_CURSOR_COLOR: u32 = 1 << 3;
const EVENT_SELECTION_RESET: u32 = 1 << 4;
const EVENT_HARD_RESET: u32 = 1 << 5;
const EVENT_CHILD_CLOSED: u32 = 1 << 6;
const EVENT_HAD_DATA: u32 = 1 << 7;

/// Low-overhead spinlock using atomic CAS and PAUSE hints.
const SpinLock = struct {
    state: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub inline fn lock(self: *SpinLock) void {
        while (self.state.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    pub inline fn unlock(self: *SpinLock) void {
        self.state.store(false, .release);
    }
};

/// Multi-threaded terminal driver parameterized by terminal capacity `Option`.
pub fn ThreadedDriver(comptime option: Option) type {
    const TerminalType = Terminal(option);
    const FrameType = Frame(option);
    const TripleBufferType = TripleBuffer(option);

    return struct {
        const Self = @This();

        allocator: Allocator,
        pty_pid: posix.pid_t,
        pty: Pty,
        triple_buffer: *TripleBufferType,
        input_queue: InputQueue,
        thread: ?std.Thread = null,
        should_exit: std.atomic.Value(bool) align(64),
        shared_modes: std.atomic.Value(u32) align(64),
        shared_events: std.atomic.Value(u32) align(64),
        shared_title: [2][term.max_title_len]u8 = undefined,
        shared_title_len: [2]u16 = .{ 0, 0 },
        shared_title_idx: std.atomic.Value(u8) align(64),
        sync_output_timeout_ms: u32,
        last_frame: ?*const FrameType = null,
        terminal: ?*TerminalType = null,
        terminal_lock: SpinLock = .{},

        pub const Events = DriverEvents;
        pub const Modes = SharedModes;

        /// Creates and starts the ThreadedDriver and its background worker thread.
        pub fn create(allocator: Allocator, pty: Pty, theme: Theme, sync_output_timeout_ms: u32) !*Self {
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);

            const tb = try allocator.create(TripleBufferType);
            errdefer allocator.destroy(tb);
            tb.* = try TripleBufferType.init(allocator);
            errdefer tb.deinit(allocator);

            // Publish an initial blank frame so acquireLatest never fails on start
            tb.publish();

            const iq = try InputQueue.init();

            self.* = .{
                .allocator = allocator,
                .pty_pid = pty.pid,
                .pty = pty,
                .triple_buffer = tb,
                .input_queue = iq,
                .should_exit = std.atomic.Value(bool).init(false),
                .shared_modes = std.atomic.Value(u32).init(0),
                .shared_events = std.atomic.Value(u32).init(0),
                .shared_title_idx = std.atomic.Value(u8).init(0),
                .sync_output_timeout_ms = sync_output_timeout_ms,
                .last_frame = tb.acquireLatest(),
                .terminal = null,
                .terminal_lock = .{},
            };

            const thread = try std.Thread.spawn(.{}, workerThreadMain, .{ self, theme });
            self.thread = thread;

            return self;
        }

        /// Signals the worker thread to exit, waits for join, and frees all resources.
        pub fn destroy(self: *Self, io: std.Io) void {
            self.should_exit.store(true, .release);
            self.input_queue.wake();

            if (self.thread) |th| {
                th.join();
                self.thread = null;
            }

            self.pty.close(io);
            self.input_queue.deinit();
            self.triple_buffer.deinit(self.allocator);
            self.allocator.destroy(self.triple_buffer);
            self.allocator.destroy(self);
        }

        /// Returns monotonic time in milliseconds using CLOCK_MONOTONIC.
        fn getMonotonicMs() i64 {
            var ts: posix.timespec = undefined;
            _ = system.clock_gettime(posix.CLOCK.MONOTONIC, &ts);
            return @as(i64, ts.sec) * 1000 + @divTrunc(ts.nsec, 1_000_000);
        }

        /// Background worker thread routine.
        fn workerThreadMain(self: *Self, theme: Theme) void {
            var terminal = TerminalType.create(self.allocator) catch |err| {
                log.err("worker: failed to create terminal: {}", .{err});
                return;
            };
            defer terminal.destroy(self.allocator);

            {
                self.terminal_lock.lock();
                self.terminal = &terminal;
                self.terminal_lock.unlock();
            }
            defer {
                self.terminal_lock.lock();
                self.terminal = null;
                self.terminal_lock.unlock();
            }

            terminal.setTheme(theme);

            var local_frame = FrameType.init(self.allocator) catch |err| {
                log.err("worker: failed to allocate local frame: {}", .{err});
                return;
            };
            defer local_frame.deinit(self.allocator);

            var pollfds = [_]system.pollfd{
                .{ .fd = self.pty.master, .events = system.POLL.IN, .revents = 0 },
                .{ .fd = self.input_queue.pollFd(), .events = system.POLL.IN, .revents = 0 },
            };

            var read_buffer: [64 * 1024]u8 align(64) = undefined;
            var reply_buffer: [1024]u8 = undefined;
            var sync_start_ms: i64 = 0;
            var child_closed = false;

            while (!self.should_exit.load(.acquire)) {
                var timeout_ms: c_int = -1;
                const now_ms = getMonotonicMs();

                if (terminal.mode.synchronized_output) {
                    if (sync_start_ms == 0) sync_start_ms = now_ms;
                    const elapsed = now_ms - sync_start_ms;
                    if (elapsed >= self.sync_output_timeout_ms) {
                        timeout_ms = 0; // expired, force publish
                    } else {
                        const remaining = @as(i64, self.sync_output_timeout_ms) - elapsed;
                        timeout_ms = @intCast(std.math.clamp(remaining, 1, 50));
                    }
                } else {
                    sync_start_ms = 0;
                }

                pollfds[0].revents = 0;
                pollfds[1].revents = 0;

                _ = system.poll(&pollfds, 2, timeout_ms);

                if (self.should_exit.load(.acquire)) break;

                var had_input = false;
                var total_read: usize = 0;

                self.terminal_lock.lock();

                // 1. Drain input events from GUI
                if (self.input_queue.hasPending() or (pollfds[1].revents & system.POLL.IN) != 0) {
                    self.input_queue.drainWakeup();
                    while (self.input_queue.pop()) |ev| {
                        self.processInputEvent(&terminal, &reply_buffer, ev);
                        had_input = true;
                    }
                }

                // 2. Read from PTY
                if (!child_closed and ((pollfds[0].revents & (system.POLL.IN | system.POLL.HUP | system.POLL.ERR)) != 0 or pollfds[0].revents == 0)) {
                    drain: while (true) {
                        const n = self.pty.readRaw(&read_buffer) catch |err| switch (err) {
                            error.WouldBlock => break :drain,
                            error.InputOutput => {
                                child_closed = true;
                                break :drain;
                            },
                            else => {
                                log.warn("pty readRaw error: {}", .{err});
                                break :drain;
                            },
                        };

                        if (n == 0) {
                            child_closed = true;
                            break :drain;
                        }

                        terminal.feed(read_buffer[0..n]);
                        total_read += n;
                    }

                    if (total_read > 0) {
                        _ = self.shared_events.fetchOr(EVENT_HAD_DATA, .release);

                        // Drain replies to PTY once per batch
                        self.drainRepliesToPty(&terminal, &reply_buffer);

                        if (terminal.events.any()) {
                            self.accumulateEvents(&terminal);
                        }
                    }

                    if (child_closed) {
                        terminal.end();
                        if (terminal.events.any()) {
                            self.accumulateEvents(&terminal);
                        }
                    }
                }

                // 3. Update shared modes while terminal is in consistent state
                self.updateSharedModes(&terminal);

                // 4. Publish frame if changed and not held by synchronized output
                var should_publish = false;
                const in_timeout_flush = terminal.mode.synchronized_output and
                    (sync_start_ms != 0 and (getMonotonicMs() - sync_start_ms >= self.sync_output_timeout_ms));

                if (total_read > 0 or had_input or child_closed or in_timeout_flush) {
                    var in_sync_hold = false;
                    if (terminal.mode.synchronized_output) {
                        if (sync_start_ms == 0) sync_start_ms = getMonotonicMs();
                        const elapsed = getMonotonicMs() - sync_start_ms;
                        in_sync_hold = elapsed < self.sync_output_timeout_ms;
                    } else {
                        sync_start_ms = 0;
                    }

                    if (!in_sync_hold) {
                        should_publish = terminal.snapshot(&local_frame);
                    }
                }

                self.terminal_lock.unlock();

                if (child_closed) {
                    _ = self.shared_events.fetchOr(EVENT_CHILD_CLOSED, .release);
                }

                if (should_publish) {
                    self.triple_buffer.getFillFrame().copyFrom(&local_frame);
                    self.triple_buffer.publish();
                }
            }
        }

        fn drainRepliesToPty(self: *Self, terminal: *TerminalType, buf: *[1024]u8) void {
            while (true) {
                const n = terminal.drainReplies(buf);
                if (n == 0) break;
                _ = self.pty.writeAll(buf[0..n]) catch break;
            }
        }

        fn processInputEvent(self: *Self, terminal: *TerminalType, reply_buf: *[1024]u8, ev: InputEvent) void {
            switch (ev) {
                .bytes => |b| {
                    _ = self.pty.writeAll(b.data[0..b.len]) catch |err| {
                        log.err("failed to write bytes to pty: {}", .{err});
                    };
                },
                .paste => |slice| {
                    defer self.allocator.free(slice);
                    if (terminal.mode.bracketed_paste) {
                        var iovecs = [_]posix.iovec_const{
                            .{ .base = "\x1b[200~", .len = 6 },
                            .{ .base = slice.ptr, .len = slice.len },
                            .{ .base = "\x1b[201~", .len = 6 },
                        };
                        self.pty.writevAll(&iovecs) catch |err| {
                            log.err("failed to write bracketed paste: {}", .{err});
                        };
                    } else {
                        _ = self.pty.writeAll(slice) catch |err| {
                            log.err("failed to write paste: {}", .{err});
                        };
                    }
                },
                .mouse_button => |mev| {
                    terminal.sendMouse(mev.col, mev.row, mev.button, mev.mods, mev.press);
                    self.drainRepliesToPty(terminal, reply_buf);
                },
                .mouse_motion => |mev| {
                    const held_button: ?MouseButton = if (mev.button) |b| @enumFromInt(b) else null;
                    terminal.sendMouseMotion(mev.col, mev.row, held_button, mev.mods);
                    self.drainRepliesToPty(terminal, reply_buf);
                },
                .mouse_scroll => |mev| {
                    if (terminal.mode.mouse_tracking.reportsWheel()) {
                        var i: u16 = 0;
                        while (i < mev.steps) : (i += 1) {
                            terminal.sendMouse(mev.col, mev.row, mev.button, 0, true);
                            self.drainRepliesToPty(terminal, reply_buf);
                        }
                    } else {
                        if (terminal.active_buffer != .alternate) {
                            if (mev.button == 64) {
                                terminal.active().scrollViewportBack(mev.steps);
                            } else {
                                terminal.active().scrollViewportForward(mev.steps);
                            }
                        }
                    }
                },
                .viewport_scroll => |vev| {
                    if (vev.lines > 0) {
                        terminal.active().scrollViewportForward(@intCast(vev.lines));
                    } else if (vev.lines < 0) {
                        terminal.active().scrollViewportBack(@intCast(-vev.lines));
                    }
                },
                .set_viewport_offset => |offset| {
                    if (terminal.active_buffer == .primary) {
                        terminal.primary.viewport_offset = @min(offset, @as(u32, @intCast(terminal.primary.scrollback_used)));
                        terminal.primary.dirty_rows = .full;
                        terminal.primary.bump();
                    }
                },
                .resize => |rev| {
                    if (terminal.mode.column_132) {
                        const deccolm_cols = terminal.active().active_cols;
                        terminal.resize(rev.rows, deccolm_cols);
                        self.pty.resize(rev.rows, deccolm_cols, rev.pixel_width, rev.pixel_height) catch {};
                    } else {
                        terminal.resize(rev.rows, rev.cols);
                        self.pty.resize(rev.rows, rev.cols, rev.pixel_width, rev.pixel_height) catch {};
                    }
                    terminal.active().dirty_rows = .full;
                    terminal.active().bump();
                },
                .focus => |focused| {
                    if (terminal.mode.focus_events) {
                        const seq = if (focused) "\x1b[I" else "\x1b[O";
                        _ = self.pty.writeAll(seq) catch {};
                    }
                },
                .hard_reset => {
                    terminal.hardReset();
                    terminal.active().dirty_rows = .full;
                    terminal.active().bump();
                },
            }
        }

        fn updateSharedModes(self: *Self, terminal: *const TerminalType) void {
            const modes = SharedModes{
                .cursor_keys = terminal.mode.cursor_keys,
                .keypad_app = terminal.mode.keypad_app,
                .modify_other_keys = terminal.mode.modify_other_keys,
                .mouse_reporting = terminal.mode.isMouseReporting(),
                .bracketed_paste = terminal.mode.bracketed_paste,
                .focus_events = terminal.mode.focus_events,
                .reports_wheel = terminal.mode.mouse_tracking.reportsWheel(),
            };
            self.shared_modes.store(@bitCast(modes), .release);
        }

        fn accumulateEvents(self: *Self, terminal: *TerminalType) void {
            const term_ev = terminal.takeEvents();
            var mask: u32 = 0;
            if (term_ev.bell) mask |= EVENT_BELL;
            if (term_ev.icon_name) mask |= EVENT_ICON_NAME;
            if (term_ev.cursor_color) mask |= EVENT_CURSOR_COLOR;
            if (term_ev.selection_reset) mask |= EVENT_SELECTION_RESET;
            if (term_ev.hard_reset) mask |= EVENT_HARD_RESET;

            if (term_ev.title) {
                mask |= EVENT_TITLE;
                const cur_idx = self.shared_title_idx.load(.monotonic);
                const next_idx = 1 - cur_idx;
                const title = terminal.getTitle();
                const len = @min(title.len, term.max_title_len);
                @memcpy(self.shared_title[next_idx][0..len], title[0..len]);
                self.shared_title_len[next_idx] = @intCast(len);
                self.shared_title_idx.store(next_idx, .release);
            }

            if (mask != 0) {
                _ = self.shared_events.fetchOr(mask, .release);
            }
        }

        // GUI Thread API:

        /// Returns the freshest viewport snapshot from the TripleBuffer.
        pub fn getFrame(self: *Self) *const FrameType {
            if (self.triple_buffer.acquireLatest()) |f| {
                self.last_frame = f;
            }
            return self.last_frame orelse &self.triple_buffer.frames[0];
        }

        /// Returns true if a fresh frame is ready in the TripleBuffer.
        pub inline fn hasNewFrame(self: *const Self) bool {
            return self.triple_buffer.hasNew();
        }

        /// Drains accumulated driver events and checks if a new frame is ready.
        pub fn pollAndDrain(self: *Self) !DriverEvents {
            var events = self.takeEvents();
            if (self.hasNewFrame()) {
                events.had_data = true;
            }
            return events;
        }

        /// Atomically retrieves and resets driver events (bell, title, child_closed).
        pub fn takeEvents(self: *Self) DriverEvents {
            const bits = self.shared_events.swap(0, .acq_rel);
            return .{
                .bell = (bits & EVENT_BELL) != 0,
                .title = (bits & EVENT_TITLE) != 0,
                .icon_name = (bits & EVENT_ICON_NAME) != 0,
                .cursor_color = (bits & EVENT_CURSOR_COLOR) != 0,
                .selection_reset = (bits & EVENT_SELECTION_RESET) != 0,
                .hard_reset = (bits & EVENT_HARD_RESET) != 0,
                .child_closed = (bits & EVENT_CHILD_CLOSED) != 0,
                .had_data = (bits & EVENT_HAD_DATA) != 0,
            };
        }

        /// Sends an input event to the driver worker thread.
        pub fn sendInput(self: *Self, event: InputEvent) bool {
            const pushed = self.input_queue.push(event);
            if (pushed) self.input_queue.wake();
            return pushed;
        }

        /// Sends raw bytes to the driver worker thread.
        pub fn sendBytes(self: *Self, slice: []const u8) void {
            if (slice.len == 0) return;
            var offset: usize = 0;
            while (offset < slice.len) {
                const chunk_len = @min(slice.len - offset, InputQueueMod.max_bytes_payload);
                _ = self.input_queue.push(InputEvent.makeBytes(slice[offset..][0..chunk_len]));
                offset += chunk_len;
            }
            self.input_queue.wake();
        }

        /// Pastes clipboard text via the input queue.
        pub fn writePaste(self: *Self, text: []const u8) !void {
            const duped = try self.allocator.dupe(u8, text);
            if (!self.input_queue.push(.{ .paste = duped })) {
                self.allocator.free(duped);
                return error.InputQueueFull;
            }
            self.input_queue.wake();
        }

        /// Returns the current terminal modes snapshot.
        pub fn getModes(self: *const Self) SharedModes {
            return @bitCast(self.shared_modes.load(.acquire));
        }

        /// Returns the current window title snapshot.
        pub fn getTitle(self: *const Self) []const u8 {
            const idx = self.shared_title_idx.load(.acquire);
            return self.shared_title[idx][0..self.shared_title_len[idx]];
        }

        /// Returns the child process PID.
        pub fn getPid(self: *const Self) posix.pid_t {
            return self.pty_pid;
        }

        /// Copies selected text into `buf` without allocating. Returns bytes written.
        pub fn copySelectionText(self: *Self, selection: anytype, buf: []u8) usize {
            self.terminal_lock.lock();
            defer self.terminal_lock.unlock();
            const term_ptr = self.terminal orelse return 0;
            return SingleDriverMod.extractSelectionText(term_ptr.active(), selection, buf);
        }
    };
}

fn sleepNs(ns: u64) void {
    const req = posix.timespec{
        .sec = @intCast(ns / 1_000_000_000),
        .nsec = @intCast(ns % 1_000_000_000),
    };
    var rem: posix.timespec = undefined;
    _ = system.nanosleep(&req, &rem);
}

test "ThreadedDriver: create, destroy and basic frame acquisition" {
    const testing = std.testing;
    const test_option: Option = .{
        .max_rows = 24,
        .max_cols = 80,
        .max_scrollback = 100,
    };
    const Driver = ThreadedDriver(test_option);

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

    var driver = try Driver.create(testing.allocator, mock_pty, Theme.graphite, 150);
    defer driver.destroy(testing.io);

    const initial_frame = driver.getFrame();
    try testing.expectEqual(@as(u16, 24), initial_frame.active_rows);
    try testing.expectEqual(@as(u16, 80), initial_frame.active_cols);
}

test "ThreadedDriver: async PTY input, frame update, and GUI reply" {
    const testing = std.testing;
    const test_option: Option = .{
        .max_rows = 24,
        .max_cols = 80,
        .max_scrollback = 100,
    };
    const Driver = ThreadedDriver(test_option);

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

    var driver = try Driver.create(testing.allocator, mock_pty, Theme.graphite, 150);
    defer driver.destroy(testing.io);

    // 1. Simulate child outputting characters
    _ = system.write(sv[1], "AsyncRex\r\n", 10);

    // Wait briefly for worker thread to process and publish
    var retries: usize = 100;
    while (retries > 0) : (retries -= 1) {
        const events = try driver.pollAndDrain();
        if (events.had_data or driver.hasNewFrame()) break;
        std.Thread.yield() catch {};
        sleepNs(1_000_000); // 1ms
    }

    const frame = driver.getFrame();
    const row0 = frame.displayRow(0);
    try testing.expectEqual(@as(u21, 'A'), row0[0].codepoint);
    try testing.expectEqual(@as(u21, 's'), row0[1].codepoint);
    try testing.expectEqual(@as(u21, 'y'), row0[2].codepoint);

    // 2. GUI sends keystroke to PTY
    driver.sendBytes("input_test");

    var read_buf: [64]u8 = undefined;
    retries = 100;
    var n_read: isize = -1;
    while (retries > 0) : (retries -= 1) {
        n_read = system.read(sv[1], &read_buf, read_buf.len);
        if (n_read > 0) break;
        std.Thread.yield() catch {};
        sleepNs(1_000_000);
    }
    try testing.expect(n_read > 0);
    const n_u: usize = @intCast(n_read);
    try testing.expectEqualStrings("input_test", read_buf[0..n_u]);
}

test "ThreadedDriver: Mode 2026 synchronized output hold and release" {
    const testing = std.testing;
    const test_option: Option = .{
        .max_rows = 24,
        .max_cols = 80,
        .max_scrollback = 100,
    };
    const Driver = ThreadedDriver(test_option);

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

    var driver = try Driver.create(testing.allocator, mock_pty, Theme.graphite, 150);
    defer driver.destroy(testing.io);

    // 1. Begin synchronized output: \x1b[?2026h, write text
    _ = system.write(sv[1], "\x1b[?2026hSyncText", 16);

    // Sleep 15ms (well within 150ms timeout)
    sleepNs(15_000_000);

    // Drain events - should not have published new frame yet because sync hold is active
    _ = try driver.pollAndDrain();
    try testing.expect(!driver.hasNewFrame());

    // End synchronized output: \x1b[?2026l
    _ = system.write(sv[1], "\x1b[?2026l", 8);

    var retries: usize = 100;
    while (retries > 0) : (retries -= 1) {
        _ = try driver.pollAndDrain();
        if (driver.hasNewFrame()) break;
        std.Thread.yield() catch {};
        sleepNs(1_000_000);
    }

    const frame = driver.getFrame();
    const row0 = frame.displayRow(0);
    try testing.expectEqual(@as(u21, 'S'), row0[0].codepoint);
    try testing.expectEqual(@as(u21, 'y'), row0[1].codepoint);
    try testing.expectEqual(@as(u21, 'n'), row0[2].codepoint);
    try testing.expectEqual(@as(u21, 'c'), row0[3].codepoint);
}
