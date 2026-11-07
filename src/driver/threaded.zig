//! ThreadedDriver: dedicated multi-threaded terminal driver.
//!
//! Spawns a dedicated background OS worker thread that owns the terminal emulator
//! and POSIX PTY. The worker runs an event-driven `poll()` loop monitoring the PTY
//! master fd and the SPSC `InputQueue` wakeup channel.
//!
//! Viewport frames are published to the GUI thread via a wait-free `TripleBuffer`
//! with Acquire/Release synchronization. Synchronized output (Mode 2026) is held
//! with bounded latency measured via `std.Io.Clock.Timestamp`.
//!
//! Memory layout keeps the triple buffer embedded inline to eliminate pointer indirection,
//! isolates atomic indices on 64-byte cache lines to prevent false sharing, batches
//! input queue wakeups to reduce syscall overhead, and guards cross-thread selection
//! text extraction with an uncontented futex mutex.

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

pub const InputQueue = @import("InputQueue.zig");
pub const InputEvent = InputQueue.InputEvent;
const OutboundQueue = @import("OutboundQueue.zig");
const paste = @import("paste.zig");

const triple_buffer = @import("triple_buffer.zig");
pub const TripleBuffer = triple_buffer.Buffer;

const root = @import("root.zig");
pub const Events = root.Events;
pub const SharedModes = root.SharedModes;
pub const EventBits = root.Events.Bits;
pub const EventSet = root.Events.Set;

/// Multi-threaded terminal driver parameterized by terminal capacity `Option`.
pub fn Driver(comptime option: Option) type {
    const TerminalType = Terminal(option);
    const FrameType = Frame(option);
    const TripleBufferType = TripleBuffer(option);

    return struct {
        const Self = @This();

        allocator: Allocator,
        io: std.Io,
        pty_pid: posix.pid_t,
        pty: Pty,
        /// Triple buffer embedded directly into driver struct to eliminate extra heap allocation.
        triple_buffer: TripleBufferType align(64),
        input_queue: InputQueue align(64),
        thread: ?std.Thread = null,
        should_exit: std.atomic.Value(bool) align(64),
        shared_modes: std.atomic.Value(u32) align(64),
        shared_events: EventSet.Atomic align(64),
        shared_resize: std.atomic.Value(u32) align(64),
        shared_title: [2][term.max_title_len]u8 align(64) = undefined,
        shared_title_len: [2]u16 = .{ 0, 0 },
        shared_title_idx: std.atomic.Value(u8) align(64),
        sync_output_timeout_ms: u32,
        /// Consumer-local cached frame pointer updated on GUI thread; aligned to 64B to prevent false sharing with worker atomics.
        last_frame: ?*const FrameType align(64) = null,
        terminal: ?*TerminalType = null,
        terminal_mutex: std.Io.Mutex align(64) = .init,
        wakeup_fn: ?*const fn () void = null,

        comptime {
            std.debug.assert(@offsetOf(Self, "last_frame") / 64 != @offsetOf(Self, "shared_modes") / 64);
            std.debug.assert(@offsetOf(Self, "last_frame") / 64 != @offsetOf(Self, "shared_events") / 64);
            std.debug.assert(@offsetOf(Self, "last_frame") / 64 != @offsetOf(Self, "shared_resize") / 64);
            std.debug.assert(@offsetOf(Self, "last_frame") / 64 != @offsetOf(Self, "shared_title_idx") / 64);
            std.debug.assert(@offsetOf(Self, "shared_modes") / 64 != @offsetOf(Self, "shared_events") / 64);
        }

        pub const Modes = SharedModes;

        /// Creates and starts the ThreadedDriver and its background worker thread.
        pub fn create(allocator: Allocator, io: std.Io, pty: Pty, theme: Theme, sync_output_timeout_ms: u32) !*Self {
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);

            var tb = try TripleBufferType.init(allocator);
            errdefer tb.deinit(allocator);

            // Publish an initial blank frame so acquireLatest never fails on start
            tb.publish();

            const iq = try InputQueue.init();

            self.* = .{
                .allocator = allocator,
                .io = io,
                .pty_pid = pty.pid,
                .pty = pty,
                .triple_buffer = tb,
                .input_queue = iq,
                .should_exit = std.atomic.Value(bool).init(false),
                .shared_modes = std.atomic.Value(u32).init(0),
                .shared_events = .{},
                .shared_resize = std.atomic.Value(u32).init(0),
                .shared_title_idx = std.atomic.Value(u8).init(0),
                .sync_output_timeout_ms = sync_output_timeout_ms,
                .last_frame = self.triple_buffer.acquireLatest(),
                .terminal = null,
                .terminal_mutex = .init,
                .wakeup_fn = null,
            };

            const thread = try std.Thread.spawn(.{}, workerThreadMain, .{ self, theme });
            self.thread = thread;

            return self;
        }

        /// Signals the worker thread to exit, waits for join, and frees all resources.
        pub fn destroy(self: *Self) void {
            self.should_exit.store(true, .release);
            self.input_queue.wake();

            if (self.thread) |th| {
                th.join();
                self.thread = null;
            }

            self.pty.close(self.io);
            self.input_queue.deinit();
            self.triple_buffer.deinit(self.allocator);
            self.allocator.destroy(self);
        }

        /// Sets the callback invoked to wake the GUI event loop on new frames or events.
        pub fn setWakeupFn(self: *Self, wake: ?*const fn () void) void {
            self.wakeup_fn = wake;
        }

        /// Background worker thread routine.
        fn workerThreadMain(self: *Self, theme: Theme) void {
            var terminal = TerminalType.create(self.allocator) catch |err| {
                log.err("worker: failed to create terminal: {}", .{err});
                return;
            };
            defer terminal.destroy(self.allocator);

            {
                self.terminal_mutex.lockUncancelable(self.io);
                self.terminal = &terminal;
                self.terminal_mutex.unlock(self.io);
            }
            defer {
                self.terminal_mutex.lockUncancelable(self.io);
                self.terminal = null;
                self.terminal_mutex.unlock(self.io);
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
            var reply_buffer: [term.Response.capacity]u8 = undefined;
            var sync_start: ?std.Io.Clock.Timestamp = null;
            var child_closed = false;

            // Bytes for the pty that the kernel hasn't accepted yet. Owned by
            // this thread; POLLOUT is watched only while it isn't empty.
            var outbound: OutboundQueue = .init(OutboundQueue.default_limit);
            defer {
                const dropped = outbound.discard(self.allocator);
                if (dropped > 0) log.warn("closing with {d} bytes never written to the pty", .{dropped});
                outbound.deinit(self.allocator);
            }

            while (!self.should_exit.load(.acquire)) {
                var timeout_ms: c_int = -1;

                if (terminal.mode.synchronized_output) {
                    const now = std.Io.Clock.Timestamp.now(self.io, .awake);
                    if (sync_start == null) sync_start = now;
                    const elapsed_ms = sync_start.?.durationTo(now).raw.toMilliseconds();
                    if (elapsed_ms >= self.sync_output_timeout_ms) {
                        timeout_ms = 0; // expired, force publish
                    } else {
                        const remaining = @as(i64, self.sync_output_timeout_ms) - @as(i64, @intCast(elapsed_ms));
                        timeout_ms = @intCast(std.math.clamp(remaining, 1, 50));
                    }
                } else {
                    sync_start = null;
                }

                pollfds[0].events = if (outbound.isEmpty()) system.POLL.IN else system.POLL.IN | system.POLL.OUT;
                pollfds[0].revents = 0;
                pollfds[1].revents = 0;

                _ = system.poll(&pollfds, 2, timeout_ms);

                if (self.should_exit.load(.acquire)) break;

                var had_input = false;
                var total_read: usize = 0;

                self.terminal_mutex.lockUncancelable(self.io);

                if (self.input_queue.hasPending() or (pollfds[1].revents & system.POLL.IN) != 0) {
                    self.input_queue.drainWakeup();
                    while (self.input_queue.pop()) |ev| {
                        self.processInputEvent(&terminal, &reply_buffer, &outbound, ev);
                        had_input = true;
                    }
                }

                if (!child_closed and pollfds[0].fd >= 0 and (pollfds[0].revents & (system.POLL.IN | system.POLL.HUP | system.POLL.ERR)) != 0) {
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
                        self.shared_events.set(EventSet.of(.had_data));

                        // Drain replies to PTY once per batch
                        self.drainRepliesToPty(&terminal, &reply_buffer, &outbound);

                        if (terminal.events.any()) {
                            self.accumulateEvents(&terminal);
                        }
                    }

                    if (child_closed) {
                        const dropped = outbound.discard(self.allocator);
                        if (dropped > 0) log.warn("child exited with {d} bytes never written to the pty", .{dropped});
                        // Invalidate PTY fd so poll() ignores it, completely eliminating 100% CPU busy-spin
                        pollfds[0].fd = -1;
                        terminal.end();
                        if (terminal.events.any()) {
                            self.accumulateEvents(&terminal);
                        }
                    }
                }

                // Write what the kernel accepts now: input queued this round, or
                // older bytes once POLLOUT says there's room again.
                if (!child_closed) self.flushOutbound(&outbound);

                self.updateSharedModes(&terminal);

                var should_publish = false;
                var in_sync_hold = false;
                var in_timeout_flush = false;

                if (terminal.mode.synchronized_output) {
                    const now = std.Io.Clock.Timestamp.now(self.io, .awake);
                    if (sync_start == null) sync_start = now;
                    const elapsed_ms = sync_start.?.durationTo(now).raw.toMilliseconds();
                    in_sync_hold = elapsed_ms < self.sync_output_timeout_ms;
                    in_timeout_flush = !in_sync_hold;
                } else {
                    sync_start = null;
                }

                if (!in_sync_hold and (total_read > 0 or had_input or child_closed or in_timeout_flush)) {
                    should_publish = terminal.snapshot(&local_frame);
                }

                self.terminal_mutex.unlock(self.io);

                if (child_closed) {
                    self.shared_events.set(EventSet.of(.child_closed));
                }

                if (should_publish) {
                    self.triple_buffer.getFillFrame().copyFrom(&local_frame);
                    self.triple_buffer.publish();
                    if (self.wakeup_fn) |wake| wake();
                } else if (child_closed or (terminal.events.any())) {
                    if (self.wakeup_fn) |wake| wake();
                }
            }
        }

        /// Queues the terminal's replies for the pty and reports replies it
        /// had to drop. A refused queue append is logged by `queue`.
        fn drainRepliesToPty(self: *Self, terminal: *TerminalType, buf: *[term.Response.capacity]u8, out: *OutboundQueue) void {
            const dropped = terminal.takeDroppedReplies();
            if (dropped > 0) {
                log.warn("dropped {d} terminal replies: the reply queue ({d} bytes) was full", .{ dropped, term.Response.capacity });
            }
            if (!terminal.hasReplies()) return;
            const n = terminal.drainReplies(buf);
            self.queue(out, &.{buf[0..n]}) catch {};
        }

        /// Queues `parts` for the pty as one unit, all or nothing. A refusal
        /// (queue full, out of memory) is logged here and returned, so the
        /// caller can stop; nothing is ever written partially.
        fn queue(self: *Self, out: *OutboundQueue, parts: []const []const u8) OutboundQueue.AppendError!void {
            var total: usize = 0;
            for (parts) |part| total += part.len;
            out.append(self.allocator, parts) catch |err| {
                log.err("dropping {d} bytes of pty input ({d} already pending): {}", .{ total, out.pending(), err });
                return err;
            };
        }

        /// Writes queued bytes until the kernel buffer is full. A child that
        /// has exited (EIO) is reported by the read side, which discards the
        /// queue; other errors are logged and the bytes stay queued.
        fn flushOutbound(self: *Self, out: *OutboundQueue) void {
            if (out.isEmpty()) return;
            _ = out.flush(self.allocator, self.pty.master) catch |err| switch (err) {
                error.InputOutput => {},
                else => log.err("pty write failed: {}", .{err}),
            };
        }

        fn processInputEvent(self: *Self, terminal: *TerminalType, reply_buf: *[term.Response.capacity]u8, out: *OutboundQueue, ev: InputEvent) void {
            switch (ev) {
                .bytes => |b| self.queue(out, &.{b.data[0..b.len]}) catch {},
                .paste => |slice| {
                    defer self.allocator.free(slice);
                    // The mode is read here, on the worker, so it is current
                    // when the paste is queued.
                    if (terminal.mode.bracketed_paste) {
                        paste.queueBracketed(out, self.allocator, slice) catch |err| {
                            log.err("dropping {d}-byte paste ({d} bytes already pending): {}", .{ slice.len, out.pending(), err });
                        };
                    } else {
                        self.queue(out, &.{slice}) catch {};
                    }
                },
                .mouse_button => |mev| {
                    terminal.sendMouse(mev.col, mev.row, mev.button, mev.mods, mev.press);
                    self.drainRepliesToPty(terminal, reply_buf, out);
                },
                .mouse_motion => |mev| {
                    const held_button: ?MouseButton = if (mev.button) |b| @enumFromInt(b) else null;
                    terminal.sendMouseMotion(mev.col, mev.row, held_button, mev.mods);
                    self.drainRepliesToPty(terminal, reply_buf, out);
                },
                .mouse_scroll => |mev| {
                    if (terminal.mode.mouse_tracking.reportsWheel()) {
                        var i: u16 = 0;
                        while (i < mev.steps) : (i += 1) {
                            terminal.sendMouse(mev.col, mev.row, mev.button, 0, true);
                            self.drainRepliesToPty(terminal, reply_buf, out);
                        }
                    } else if (terminal.active_buffer == .alternate) {
                        const seq = if (terminal.mode.cursor_keys)
                            (if (mev.button == 64) "\x1bOA" else "\x1bOB")
                        else
                            (if (mev.button == 64) "\x1b[A" else "\x1b[B");
                        var i: u16 = 0;
                        while (i < mev.steps) : (i += 1) {
                            self.queue(out, &.{seq}) catch break;
                        }
                    } else {
                        if (mev.button == 64) {
                            terminal.active().scrollViewportBack(mev.steps);
                        } else {
                            terminal.active().scrollViewportForward(mev.steps);
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
                        self.queue(out, &.{seq}) catch {};
                    }
                },
                .hard_reset => {
                    terminal.hardReset();
                    terminal.active().dirty_rows = .full;
                    terminal.active().bump();
                },
                .set_theme => |theme| {
                    terminal.setTheme(theme);
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
                .reports_motion = terminal.mode.mouse_tracking.reportsMotion(),
            };
            self.shared_modes.store(@bitCast(modes), .release);
        }

        fn accumulateEvents(self: *Self, terminal: *TerminalType) void {
            const term_ev = terminal.takeEvents();
            var ev = EventSet.fromInt(term_ev.flags.toInt());

            if (term_ev.has(.title)) {
                const cur_idx = self.shared_title_idx.load(.monotonic);
                const next_idx = 1 - cur_idx;
                const title = terminal.getTitle();
                const len: usize = @min(title.len, term.max_title_len);
                @memcpy(self.shared_title[next_idx][0..len], title[0..len]);
                self.shared_title_len[next_idx] = @intCast(len);
                self.shared_title_idx.store(next_idx, .release);
            }

            if (term_ev.has(.resize)) {
                const packed_res: u32 = (@as(u32, term_ev.resize.rows) << 16) | @as(u32, term_ev.resize.cols);
                self.shared_resize.store(packed_res, .release);
            }

            if (ev.any()) {
                self.shared_events.set(ev);
            }
        }

        // GUI Thread API:

        /// Returns the freshest viewport snapshot from the TripleBuffer.
        pub fn getFrame(self: *Self) *const FrameType {
            if (self.triple_buffer.acquireLatest()) |f| {
                self.last_frame = f;
            }
            return self.last_frame orelse &self.triple_buffer.frames[self.triple_buffer.read_idx];
        }

        /// Returns true if a fresh frame is ready in the TripleBuffer.
        pub inline fn hasNewFrame(self: *const Self) bool {
            return self.triple_buffer.hasNew();
        }

        /// Drains accumulated driver events and checks if a new frame is ready.
        pub fn pollAndDrain(self: *Self) !Events {
            var events = self.takeEvents();
            if (self.hasNewFrame()) {
                events.set(.had_data);
            }
            return events;
        }

        /// Atomically retrieves and resets driver events (bell, title, resize, child_closed).
        pub fn takeEvents(self: *Self) Events {
            const bits = self.shared_events.take();
            const resize_val = if (bits.has(.resize)) self.shared_resize.swap(0, .acq_rel) else 0;

            return .{
                .flags = bits,
                .resize = .{
                    .rows = @intCast(resize_val >> 16),
                    .cols = @intCast(resize_val & 0xFFFF),
                },
            };
        }

        /// Sends an input event to the driver worker thread.
        pub fn sendInput(self: *Self, event: InputEvent) bool {
            return self.input_queue.push(event);
        }

        /// Sends raw bytes to the driver worker thread with batched wakeups.
        /// All or nothing: fails with error.InputQueueFull, sending nothing,
        /// when the worker is too far behind.
        pub fn sendBytes(self: *Self, slice: []const u8) error{InputQueueFull}!void {
            if (!self.input_queue.pushBytes(slice)) return error.InputQueueFull;
        }

        /// Pastes clipboard text via the input queue.
        pub fn writePaste(self: *Self, text: []const u8) !void {
            const duped = try self.allocator.dupe(u8, text);
            if (!self.input_queue.push(.{ .paste = duped })) {
                self.allocator.free(duped);
                return error.InputQueueFull;
            }
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
            self.terminal_mutex.lockUncancelable(self.io);
            defer self.terminal_mutex.unlock(self.io);
            const term_ptr = self.terminal orelse return 0;
            return root.extractSelectionText(term_ptr.active(), selection, buf);
        }
    };
}

pub const ThreadedDriver = Driver;

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
    const DriverType = Driver(test_option);

    var sv: [2]posix.fd_t = undefined;
    const rc = system.socketpair(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.NONBLOCK, 0, &sv);
    try testing.expectEqual(@as(c_int, 0), rc);
    defer {
        _ = system.close(sv[1]);
    }

    const mock_pty: Pty = .{
        .master = sv[0],
        .pid = 1234,
        .stdout_read_fd = -1,
        .error_read_fd = -1,
    };

    var driver = try DriverType.create(testing.allocator, testing.io, mock_pty, Theme.graphite, 150);
    defer {
        driver.pty.pid = -1;
        driver.destroy();
    }

    try testing.expectEqual(@as(posix.pid_t, 1234), driver.getPid());
    try testing.expect(!driver.hasNewFrame());

    const frame = driver.getFrame();
    try testing.expectEqual(@as(u16, 24), frame.active_rows);
    try testing.expectEqual(@as(u16, 80), frame.active_cols);
}

test "ThreadedDriver: async PTY input, frame update, and GUI reply" {
    const testing = std.testing;
    const test_option: Option = .{
        .max_rows = 24,
        .max_cols = 80,
        .max_scrollback = 100,
    };
    const DriverType = Driver(test_option);

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

    var driver = try DriverType.create(testing.allocator, testing.io, mock_pty, Theme.graphite, 150);
    defer driver.destroy();

    // Simulate child outputting characters
    _ = system.write(sv[1], "AsyncRex\r\n", 10);

    // Wait briefly for worker thread to process and publish
    var retries: usize = 100;
    while (retries > 0) : (retries -= 1) {
        const events = try driver.pollAndDrain();
        if (events.has(.had_data) or driver.hasNewFrame()) break;
        std.Thread.yield() catch {};
        sleepNs(1_000_000); // 1ms
    }

    const frame = driver.getFrame();
    const row0 = frame.displayRow(0);
    try testing.expectEqual(@as(u21, 'A'), row0[0].codepoint);
    try testing.expectEqual(@as(u21, 's'), row0[1].codepoint);
    try testing.expectEqual(@as(u21, 'y'), row0[2].codepoint);

    // GUI sends keystroke to PTY
    try driver.sendBytes("input_test");

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
    const DriverType = Driver(test_option);

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

    var driver = try DriverType.create(testing.allocator, testing.io, mock_pty, Theme.graphite, 150);
    defer driver.destroy();

    // Begin synchronized output: \x1b[?2026h, write text
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

var test_wake_count = std.atomic.Value(u32).init(0);
fn testWakeup() void {
    _ = test_wake_count.fetchAdd(1, .release);
}

test "ThreadedDriver: wakeup_fn callback and alternate screen alt_scroll" {
    const testing = std.testing;
    const test_option: Option = .{
        .max_rows = 24,
        .max_cols = 80,
        .max_scrollback = 100,
    };
    const DriverType = Driver(test_option);

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

    var driver = try DriverType.create(testing.allocator, testing.io, mock_pty, Theme.graphite, 150);
    defer driver.destroy();

    test_wake_count.store(0, .release);
    driver.wakeup_fn = testWakeup;

    // Output text from child: should trigger publish and invoke wakeup_fn
    _ = system.write(sv[1], "WakeupTest\r\n", 12);

    var retries: usize = 100;
    while (retries > 0) : (retries -= 1) {
        if (test_wake_count.load(.acquire) > 0) break;
        std.Thread.yield() catch {};
        sleepNs(1_000_000);
    }
    try testing.expect(test_wake_count.load(.acquire) > 0);

    // Switch to alternate screen (\x1b[?1049h)
    _ = system.write(sv[1], "\x1b[?1049h", 8);

    retries = 100;
    while (retries > 0) : (retries -= 1) {
        const f = driver.getFrame();
        if (f.is_alternate) break;
        std.Thread.yield() catch {};
        sleepNs(1_000_000);
    }

    // Scroll up in alternate screen should emit cursor up keys (\x1b[A)
    _ = driver.sendInput(.{
        .mouse_scroll = .{
            .col = 5,
            .row = 5,
            .button = 64, // Wheel up
            .steps = 1,
        },
    });

    var read_buf: [32]u8 = undefined;
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
    try testing.expectEqualStrings("\x1b[A", read_buf[0..n_u]);
}

test "ThreadedDriver: a 1 MiB paste reaches a child that echoes it back" {
    // The deadlock case: the child echoes everything it reads, so its output
    // fills up unless the worker keeps reading while it waits to write.
    const testing = std.testing;
    const gpa = testing.allocator;
    const test_option: Option = .{ .max_rows = 24, .max_cols = 80, .max_scrollback = 100 };
    const DriverType = Driver(test_option);

    var sv: [2]posix.fd_t = undefined;
    const rc = system.socketpair(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.NONBLOCK, 0, &sv);
    try testing.expectEqual(@as(c_int, 0), rc);
    defer _ = system.close(sv[1]);

    const mock_pty: Pty = .{ .master = sv[0], .pid = -1, .stdout_read_fd = -1, .error_read_fd = -1 };
    var driver = try DriverType.create(gpa, testing.io, mock_pty, Theme.graphite, 150);
    defer driver.destroy();

    // Printable lines, so the echoed bytes are ordinary terminal output.
    const payload = try gpa.alloc(u8, 1024 * 1024);
    defer gpa.free(payload);
    for (payload, 0..) |*b, i| b.* = if (i % 80 == 79) '\n' else 'a' + @as(u8, @intCast(i % 26));

    try driver.writePaste(payload);

    var received: std.ArrayList(u8) = .empty;
    defer received.deinit(gpa);
    var echo: std.ArrayList(u8) = .empty;
    defer echo.deinit(gpa);
    var chunk: [4096]u8 = undefined;

    var rounds: usize = 0;
    while (received.items.len < payload.len) : (rounds += 1) {
        if (rounds > 200_000) return error.TestPasteNotDelivered;
        // A slow child: one chunk per round, echoed back.
        const n = system.read(sv[1], &chunk, chunk.len);
        if (posix.errno(n) == .SUCCESS and n > 0) {
            const got = chunk[0..@intCast(n)];
            try received.appendSlice(gpa, got);
            try echo.appendSlice(gpa, got);
        }
        if (echo.items.len > 0) {
            const w = system.write(sv[1], echo.items.ptr, echo.items.len);
            if (posix.errno(w) == .SUCCESS) {
                const written: usize = @intCast(w);
                echo.replaceRangeAssumeCapacity(0, written, &.{});
            }
        }
        _ = driver.pollAndDrain() catch {};
        std.Thread.yield() catch {};
    }
    try testing.expectEqualSlices(u8, payload, received.items);
}

test "ThreadedDriver: pasted text can't end a bracketed paste early" {
    const testing = std.testing;
    const gpa = testing.allocator;
    const test_option: Option = .{ .max_rows = 24, .max_cols = 80, .max_scrollback = 100 };
    const DriverType = Driver(test_option);

    var sv: [2]posix.fd_t = undefined;
    const rc = system.socketpair(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.NONBLOCK, 0, &sv);
    try testing.expectEqual(@as(c_int, 0), rc);
    defer _ = system.close(sv[1]);

    const mock_pty: Pty = .{ .master = sv[0], .pid = -1, .stdout_read_fd = -1, .error_read_fd = -1 };
    var driver = try DriverType.create(gpa, testing.io, mock_pty, Theme.graphite, 150);
    defer driver.destroy();

    // The child turns bracketed paste on; wait until the worker has seen it.
    _ = system.write(sv[1], "\x1b[?2004h", 8);
    var rounds: usize = 0;
    while (!driver.getModes().bracketed_paste) : (rounds += 1) {
        if (rounds > 2_000) return error.TestModeNotSet;
        _ = driver.pollAndDrain() catch {};
        sleepNs(1_000_000);
    }

    try driver.writePaste("ls\x1b[201~rm -rf ~\n");

    const expected = "\x1b[200~ls[201~rm -rf ~\n\x1b[201~";
    var received: std.ArrayList(u8) = .empty;
    defer received.deinit(gpa);
    var chunk: [64]u8 = undefined;
    rounds = 0;
    while (received.items.len < expected.len) : (rounds += 1) {
        if (rounds > 2_000) return error.TestPasteNotDelivered;
        const n = system.read(sv[1], &chunk, chunk.len);
        if (posix.errno(n) == .SUCCESS and n > 0) try received.appendSlice(gpa, chunk[0..@intCast(n)]);
        sleepNs(1_000_000);
    }
    try testing.expectEqualStrings(expected, received.items);
}
