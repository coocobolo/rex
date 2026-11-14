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
const MouseInput = term.term.MouseInput;
const HeldButtons = term.term.HeldButtons;

const pipe = @import("../termio/pipe.zig");
const termio = @import("../termio/root.zig");
const Pty = termio.pty.Posix;

pub const InputQueue = @import("InputQueue.zig");
pub const InputEvent = InputQueue.InputEvent;
const OutboundQueue = @import("OutboundQueue.zig");
const paste = @import("paste.zig");
const latency_trace = @import("latency_trace.zig");

const triple_buffer = @import("triple_buffer.zig");
pub const TripleBuffer = triple_buffer.Buffer;

const root = @import("root.zig");
pub const Events = root.Events;
pub const SharedModes = root.SharedModes;
pub const EventBits = root.Events.Bits;
pub const EventSet = root.Events.Set;

/// One pty read. Small enough that a key arriving during a drain waits out
/// tens of microseconds of parsing, not the whole pty buffer.
const read_chunk: usize = 4 * 1024;
/// Bytes a turn reads before it publishes, so a flood does not snapshot
/// once per syscall.
const turn_budget: usize = 256 * 1024;
/// How long after input is queued for the child its turns stay short. A
/// shell echoes well inside this; a program that does not echo costs a
/// few extra snapshots.
const echo_window_ns: u64 = 2 * std.time.ns_per_ms;
/// Bytes a turn reads inside that window. The echo of a key is published
/// within a few chunks of arriving instead of behind a full `turn_budget`.
const echo_budget: usize = 16 * 1024;

/// Read budget for a turn starting at `now_ns`. `echo_deadline_ns` ends
/// the short-turn window that follows input to the child.
fn readBudget(now_ns: u64, echo_deadline_ns: u64) usize {
    return if (now_ns < echo_deadline_ns) echo_budget else turn_budget;
}

fn awakeNs(io: std.Io) u64 {
    return @intCast(std.Io.Clock.awake.now(io).toNanoseconds());
}

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
        /// The terminal's title, copied in by the worker on each `title`
        /// event and out by the GUI in `copyTitle`. `title_mutex` guards
        /// both fields; each side holds it only for one copy.
        title_mutex: std.Io.Mutex = .init,
        title_len: u16 = 0,
        title: [term.max_title_len]u8 = undefined,
        sync_output_timeout_ms: u32,
        /// Consumer-local cached frame pointer updated on GUI thread; aligned to 64B to prevent false sharing with worker atomics.
        last_frame: ?*const FrameType align(64) = null,
        terminal: ?*TerminalType = null,
        terminal_mutex: std.Io.Mutex align(64) = .init,
        wakeup_fn: ?*const fn () void = null,
        /// The latency trace this driver writes to, owned by the caller of
        /// `create` and valid until `destroy` returns.
        latency: latency_trace.Handle,
        /// Per triple-buffer slot, the traced key whose echo is the newest
        /// in that slot's frame. The worker writes the fill slot before
        /// publishing it and the GUI reads the read slot after acquiring
        /// it, so the slots follow the frames' ownership.
        latency_slot_seq: if (latency_trace.enabled) [3]u32 else void =
            if (latency_trace.enabled) @splat(0) else {},

        comptime {
            std.debug.assert(@offsetOf(Self, "last_frame") / 64 != @offsetOf(Self, "shared_modes") / 64);
            std.debug.assert(@offsetOf(Self, "last_frame") / 64 != @offsetOf(Self, "shared_events") / 64);
            std.debug.assert(@offsetOf(Self, "last_frame") / 64 != @offsetOf(Self, "shared_resize") / 64);
            std.debug.assert(@offsetOf(Self, "shared_modes") / 64 != @offsetOf(Self, "shared_events") / 64);
        }

        pub const Modes = SharedModes;

        /// Creates and starts the ThreadedDriver and its background worker thread.
        /// The driver owns `pty` from here on and closes it in `destroy`.
        /// `latency` is `latency_trace.none` unless the caller traces.
        pub fn create(allocator: Allocator, io: std.Io, pty: Pty, options: root.Options, latency: latency_trace.Handle) !*Self {
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
                .sync_output_timeout_ms = options.sync_output_timeout_ms,
                .last_frame = self.triple_buffer.acquireLatest(),
                .terminal = null,
                .terminal_mutex = .init,
                .wakeup_fn = null,
                .latency = latency,
            };

            const thread = try std.Thread.spawn(.{}, workerThreadMain, .{ self, options });
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

            // The worker has stopped: free what it never took.
            while (self.input_queue.pop()) |ev| switch (ev) {
                .paste, .reply => |bytes| self.allocator.free(bytes),
                else => {},
            };
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
        fn workerThreadMain(self: *Self, options: root.Options) void {
            var terminal = TerminalType.init(self.allocator) catch |err| {
                log.err("worker: failed to create terminal: {}", .{err});
                return;
            };
            defer terminal.deinit(self.allocator);

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

            terminal.setTheme(options.theme);
            terminal.setTermName(options.term_name);

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
            // Awake-clock time until which turns use `echo_budget`; see
            // `readBudget`. 0 (or any past time) means no window.
            var echo_deadline_ns: u64 = 0;
            var reply_buffer: [term.Response.capacity]u8 = undefined;
            var sync_start: ?std.Io.Clock.Timestamp = null;
            var child_closed = false;

            // Bytes for the pty that the kernel hasn't accepted yet. Owned by
            // this thread; POLLOUT is watched only while it isn't empty.
            // Matches traced keys to their echo; used only with a trace.
            var latency_worker: latency_trace.Worker = .{};

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

                var queued_before = outbound.pending();
                if (self.takeQueuedInput(&terminal, &reply_buffer, &outbound, &latency_worker, (pollfds[1].revents & system.POLL.IN) != 0)) {
                    had_input = true;
                }
                if (outbound.pending() > queued_before) echo_deadline_ns = awakeNs(self.io) +| echo_window_ns;

                // The key's bytes go out before this turn's pty read. Under
                // load that read runs until EAGAIN, and writing after it
                // held the key for the whole drain.
                if (!child_closed) self.flushOutbound(&outbound);
                if (latency_trace.enabled and latency_worker.awaiting_write != 0) {
                    if (self.latency) |trace| latency_worker.flushed(trace, outbound.isEmpty(), latency_trace.now(self.io));
                }

                if (!child_closed and pollfds[0].fd >= 0 and (pollfds[0].revents & (system.POLL.IN | system.POLL.HUP | system.POLL.ERR)) != 0) {
                    // Stop before the budget, or before the next read once a
                    // key is queued, and publish this turn. The pty stays
                    // readable, so the next poll returns at once.
                    const budget = readBudget(awakeNs(self.io), echo_deadline_ns);
                    drain: while (total_read < budget) {
                        if (total_read > 0 and self.input_queue.hasPending()) break :drain;
                        const want = @min(read_chunk, budget - total_read);
                        const n = self.pty.readRaw(read_buffer[0..want]) catch |err| switch (err) {
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

                        if (latency_trace.enabled and latency_worker.awaiting_echo != 0 and latency_worker.first != null) {
                            if (self.latency) |trace| {
                                latency_worker.read(trace, read_buffer[0..n], latency_trace.now(self.io));
                            }
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

                // A key that arrived during the read is written before the
                // snapshot, still ahead of any further pty bytes. Its echo
                // comes in a later turn, which the window keeps short.
                queued_before = outbound.pending();
                if (self.takeQueuedInput(&terminal, &reply_buffer, &outbound, &latency_worker, false)) {
                    had_input = true;
                }
                if (outbound.pending() > queued_before) echo_deadline_ns = awakeNs(self.io) +| echo_window_ns;
                // Replies produced by the read, and any key byte the first
                // flush could not fit in the kernel buffer.
                if (!child_closed) self.flushOutbound(&outbound);
                if (latency_trace.enabled and latency_worker.awaiting_write != 0) {
                    if (self.latency) |trace| latency_worker.flushed(trace, outbound.isEmpty(), latency_trace.now(self.io));
                }

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
                    if (latency_trace.enabled) {
                        self.latency_slot_seq[self.triple_buffer.fill_idx] = latency_worker.echoed;
                    }
                    self.triple_buffer.publish();
                    if (latency_trace.enabled) {
                        if (self.latency) |trace| {
                            if (latency_worker.echoed != latency_worker.published) {
                                latency_worker.framePublished(trace, latency_trace.now(self.io));
                            }
                        }
                    }
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

        /// Pops every queued input event. `wake` is the poll bit for the
        /// input queue; during a drain only `hasPending` is known. Returns
        /// whether any event was handled. One key in flight: the first
        /// bytes event of this drain is that key.
        fn takeQueuedInput(
            self: *Self,
            terminal: *TerminalType,
            reply_buf: *[term.Response.capacity]u8,
            out: *OutboundQueue,
            latency_worker: *latency_trace.Worker,
            wake: bool,
        ) bool {
            if (!wake and !self.input_queue.hasPending()) return false;
            self.input_queue.drainWakeup();
            var traced_first: ?u8 = null;
            var had = false;
            while (self.input_queue.pop()) |ev| {
                if (latency_trace.enabled and traced_first == null) {
                    switch (ev) {
                        .bytes => |b| if (b.len > 0) {
                            traced_first = b.data[0];
                        },
                        else => {},
                    }
                }
                self.processInputEvent(terminal, reply_buf, out, ev);
                had = true;
            }
            if (latency_trace.enabled) {
                if (self.latency) |trace| latency_worker.inputHandled(trace, traced_first);
            }
            return had;
        }

        fn processInputEvent(self: *Self, terminal: *TerminalType, reply_buf: *[term.Response.capacity]u8, out: *OutboundQueue, ev: InputEvent) void {
            switch (ev) {
                .bytes => |b| self.queue(out, &.{b.data[0..b.len]}) catch {},
                .reply => |bytes| {
                    defer self.allocator.free(bytes);
                    self.queue(out, &.{bytes}) catch {}; // `queue` logs the drop
                },
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
                    if (std.enums.fromInt(MouseButton, mev.button)) |button| {
                        const input: MouseInput = if (mev.press) .{ .press = button } else .{ .release = button };
                        terminal.sendMouse(mev.col, mev.row, input, .fromByte(mev.mods));
                        self.drainRepliesToPty(terminal, reply_buf, out);
                    }
                },
                .mouse_motion => |mev| {
                    const held_button: ?MouseButton = if (mev.button) |b| std.enums.fromInt(MouseButton, b) else null;
                    terminal.sendMouseMotion(mev.col, mev.row, held_button, .fromByte(mev.mods));
                    self.drainRepliesToPty(terminal, reply_buf, out);
                },
                .mouse_scroll => |mev| {
                    if (terminal.mode.mouse_tracking.reportsWheel()) {
                        const dir: MouseInput.Wheel = if (mev.button == 64) .up else .down;
                        var i: u16 = 0;
                        while (i < mev.steps) : (i += 1) {
                            terminal.sendMouse(mev.col, mev.row, .{ .wheel = dir }, .none);
                            self.drainRepliesToPty(terminal, reply_buf, out);
                        }
                    } else if (terminal.active_buffer == .alternate and terminal.mode.alt_scroll) {
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
                        // A failure is logged by Posix.resize.
                        self.pty.resize(rev.rows, deccolm_cols, rev.pixel_width, rev.pixel_height) catch {};
                    } else {
                        terminal.resize(rev.rows, rev.cols);
                        // A failure is logged by Posix.resize.
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
                .eight_bit_controls = terminal.control_format == .s8c1t,
            };
            self.shared_modes.store(@bitCast(modes), .release);
        }

        fn accumulateEvents(self: *Self, terminal: *TerminalType) void {
            const term_ev = terminal.takeEvents();
            var ev = EventSet.fromInt(term_ev.flags.toInt());

            // RIS empties the title without a `title` event.
            if (term_ev.has(.title) or term_ev.has(.hard_reset)) {
                const title = terminal.getTitle();
                self.title_mutex.lockUncancelable(self.io);
                defer self.title_mutex.unlock(self.io);
                @memcpy(self.title[0..title.len], title);
                self.title_len = @intCast(title.len);
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

        /// The traced key whose echo is the newest in the frame `getFrame`
        /// returned last, or 0. GUI thread only.
        pub fn latencyFrameSeq(self: *const Self) u32 {
            return if (latency_trace.enabled) self.latency_slot_seq[self.triple_buffer.read_idx] else 0;
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

        /// Queues a reply too big for the terminal's reply queue, to be
        /// written as is. The bytes are copied.
        pub fn sendReply(self: *Self, bytes: []const u8) !void {
            const duped = try self.allocator.dupe(u8, bytes);
            if (!self.input_queue.push(.{ .reply = duped })) {
                self.allocator.free(duped);
                return error.InputQueueFull;
            }
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

        /// Copies the title the terminal last reported into `buf` and
        /// returns it. Empty until a program sets one or after RIS.
        pub fn copyTitle(self: *Self, buf: *[term.max_title_len:0]u8) [:0]const u8 {
            self.title_mutex.lockUncancelable(self.io);
            defer self.title_mutex.unlock(self.io);
            @memcpy(buf[0..self.title_len], self.title[0..self.title_len]);
            buf[self.title_len] = 0;
            return buf[0..self.title_len :0];
        }

        /// Takes the pending OSC 52 request, copying a write's data into
        /// `buf`. Null when none is pending or the worker has stopped.
        pub fn takeClipboard(self: *Self, buf: *[option.max_clipboard_bytes]u8) ?root.ClipboardRequest {
            self.terminal_mutex.lockUncancelable(self.io);
            defer self.terminal_mutex.unlock(self.io);
            const terminal = self.terminal orelse return null;
            const request, const data = terminal.takeClipboard();
            return switch (request) {
                .none => null,
                .write => |targets| blk: {
                    @memcpy(buf[0..data.len], data);
                    break :blk .{ .write = .{ .targets = targets, .data = buf[0..data.len] } };
                },
                .read => |targets| .{ .read = .{ .targets = targets, .control_format = terminal.control_format } },
            };
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

const test_options: root.Options = .{ .theme = Theme.graphite, .sync_output_timeout_ms = 150 };

test "readBudget: short turns only inside the echo window" {
    try std.testing.expectEqual(turn_budget, readBudget(5_000_000, 0));
    try std.testing.expectEqual(echo_budget, readBudget(5_000_000, 6_000_000));
    try std.testing.expectEqual(turn_budget, readBudget(6_000_000, 6_000_000));
    try std.testing.expectEqual(turn_budget, readBudget(9_000_000, 6_000_000));
}

/// Upper bound, in 1 ms polls, for a test to wait on the worker thread.
/// Each wait ends as soon as its condition holds; the bound only matters on
/// a loaded machine.
const test_wait_ms = 2000;

test "ThreadedDriver: create, destroy and basic frame acquisition" {
    const testing = std.testing;
    const test_option: Option = .{
        .max_rows = 24,
        .max_cols = 80,
        .max_scrollback = 100,
    };
    const DriverType = Driver(test_option);

    var sv: [2]posix.fd_t = undefined;
    try pipe.openSocketPair(&sv, .{ .NONBLOCK = true });
    defer {
        _ = system.close(sv[1]);
    }

    const mock_pty: Pty = .{
        .master = sv[0],
        .pid = 1234,
        .stdout_read_fd = -1,
        .error_read_fd = -1,
    };

    var driver = try DriverType.create(testing.allocator, testing.io, mock_pty, test_options, latency_trace.none);
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
    try pipe.openSocketPair(&sv, .{ .NONBLOCK = true });
    defer {
        _ = system.close(sv[1]);
    }

    const mock_pty: Pty = .{
        .master = sv[0],
        .pid = -1,
        .stdout_read_fd = -1,
        .error_read_fd = -1,
    };

    var driver = try DriverType.create(testing.allocator, testing.io, mock_pty, test_options, latency_trace.none);
    defer driver.destroy();

    // Simulate child outputting characters
    _ = system.write(sv[1], "AsyncRex\r\n", 10);

    // Wait for a published frame that shows the output. `had_data` is set
    // before the worker publishes, so it does not mean the frame is there.
    var retries: usize = test_wait_ms;
    while (retries > 0) : (retries -= 1) {
        _ = try driver.pollAndDrain();
        if (driver.getFrame().displayRow(0)[0].codepoint == 'A') break;
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
    retries = test_wait_ms;
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

test "ThreadedDriver: XTGETTCAP reports the TERM from Options" {
    const testing = std.testing;
    const test_option: Option = .{ .max_rows = 24, .max_cols = 80, .max_scrollback = 100 };

    var sv: [2]posix.fd_t = undefined;
    try pipe.openSocketPair(&sv, .{ .NONBLOCK = true });
    defer _ = system.close(sv[1]);
    const mock_pty: Pty = .{ .master = sv[0], .pid = -1, .stdout_read_fd = -1, .error_read_fd = -1 };

    var options = test_options;
    options.term_name = try .init("rex");
    var driver = try Driver(test_option).create(testing.allocator, testing.io, mock_pty, options, latency_trace.none);
    defer driver.destroy();

    const query = "\x1bP+q544E\x1b\\"; // TN
    _ = system.write(sv[1], query, query.len);

    const expected = "\x1bP1+r544E=726578\x1b\\";
    var reply_buf: [64]u8 = undefined;
    var len: usize = 0;
    var retries: usize = test_wait_ms;
    while (retries > 0 and len < expected.len) : (retries -= 1) {
        const n = system.read(sv[1], reply_buf[len..].ptr, reply_buf.len - len);
        if (n > 0) len += @intCast(n) else {
            std.Thread.yield() catch {};
            sleepNs(1_000_000);
        }
    }
    try testing.expectEqualStrings(expected, reply_buf[0..len]);
}

/// Writes all of `bytes` to the nonblocking `fd`, waiting while it is full.
fn writeAllTest(fd: posix.fd_t, bytes: []const u8) !void {
    var done: usize = 0;
    var retries: usize = test_wait_ms;
    while (done < bytes.len) {
        const n = system.write(fd, bytes[done..].ptr, bytes.len - done);
        if (n > 0) {
            done += @intCast(n);
            continue;
        }
        retries = std.math.sub(usize, retries, 1) catch return error.Timeout;
        sleepNs(1_000_000);
    }
}

fn waitForTitle(comptime opt: Option, driver: *Driver(opt), want: []const u8) ![]const u8 {
    var buf: [term.max_title_len:0]u8 = undefined;
    var retries: usize = test_wait_ms;
    while (retries > 0) : (retries -= 1) {
        _ = try driver.pollAndDrain();
        if (std.mem.eql(u8, driver.copyTitle(&buf), want)) break;
        sleepNs(1_000_000);
    }
    return driver.copyTitle(&buf);
}

test "ThreadedDriver: copyTitle returns the title a program set, and RIS empties it" {
    const testing = std.testing;
    const test_option: Option = .{ .max_rows = 24, .max_cols = 80, .max_scrollback = 100 };

    var sv: [2]posix.fd_t = undefined;
    try pipe.openSocketPair(&sv, .{ .NONBLOCK = true });
    defer _ = system.close(sv[1]);
    const mock_pty: Pty = .{ .master = sv[0], .pid = -1, .stdout_read_fd = -1, .error_read_fd = -1 };

    var driver = try Driver(test_option).create(testing.allocator, testing.io, mock_pty, test_options, latency_trace.none);
    defer driver.destroy();

    var buf: [term.max_title_len:0]u8 = undefined;
    try testing.expectEqualStrings("", driver.copyTitle(&buf));

    try writeAllTest(sv[1], "\x1b]2;vim notes.txt\x07");
    try testing.expectEqualStrings("vim notes.txt", try waitForTitle(test_option, driver, "vim notes.txt"));

    try writeAllTest(sv[1], "\x1bc"); // RIS
    try testing.expectEqualStrings("", try waitForTitle(test_option, driver, ""));
}

test "ThreadedDriver: copyTitle never returns a mix of two titles" {
    const testing = std.testing;
    const test_option: Option = .{ .max_rows = 24, .max_cols = 80, .max_scrollback = 100 };

    var sv: [2]posix.fd_t = undefined;
    try pipe.openSocketPair(&sv, .{ .NONBLOCK = true });
    defer _ = system.close(sv[1]);
    const mock_pty: Pty = .{ .master = sv[0], .pid = -1, .stdout_read_fd = -1, .error_read_fd = -1 };

    var driver = try Driver(test_option).create(testing.allocator, testing.io, mock_pty, test_options, latency_trace.none);
    defer driver.destroy();

    // Two full-length titles, alternating, while the GUI side copies.
    const a = "\x1b]2;" ++ "a" ** term.max_title_len ++ "\x07";
    const b = "\x1b]2;" ++ "b" ** term.max_title_len ++ "\x07";
    var buf: [term.max_title_len:0]u8 = undefined;
    for (0..200) |i| {
        try writeAllTest(sv[1], if (i % 2 == 0) a else b);
        _ = try driver.pollAndDrain();
        const title = driver.copyTitle(&buf);
        if (title.len == 0) continue; // before the first title arrives
        try testing.expectEqual(term.max_title_len, title.len);
        const first = title[0];
        try testing.expect(first == 'a' or first == 'b');
        for (title) |c| try testing.expectEqual(first, c);
    }
}

test "ThreadedDriver: takeClipboard hands over an OSC 52 read with its C1 format" {
    const testing = std.testing;
    const test_option: Option = .{ .max_rows = 24, .max_cols = 80, .max_scrollback = 100, .max_clipboard_bytes = 64 };

    var sv: [2]posix.fd_t = undefined;
    try pipe.openSocketPair(&sv, .{ .NONBLOCK = true });
    defer _ = system.close(sv[1]);
    const mock_pty: Pty = .{ .master = sv[0], .pid = -1, .stdout_read_fd = -1, .error_read_fd = -1 };

    var driver = try Driver(test_option).create(testing.allocator, testing.io, mock_pty, test_options, latency_trace.none);
    defer driver.destroy();

    try writeAllTest(sv[1], "\x1b]52;c;?\x1b\\");
    var buf: [test_option.max_clipboard_bytes]u8 = undefined;
    var request: ?root.ClipboardRequest = null;
    var retries: usize = test_wait_ms;
    while (retries > 0 and request == null) : (retries -= 1) {
        const events = try driver.pollAndDrain();
        if (events.has(.clipboard)) request = driver.takeClipboard(&buf);
        if (request == null) sleepNs(1_000_000);
    }
    try testing.expect(request.?.read.targets.clipboard);
    try testing.expectEqual(.s7c1t, request.?.read.control_format);
}

test "ThreadedDriver: sendReply is written as is, even with bracketed paste on" {
    const testing = std.testing;
    const test_option: Option = .{ .max_rows = 24, .max_cols = 80, .max_scrollback = 100, .max_clipboard_bytes = 64 };

    var sv: [2]posix.fd_t = undefined;
    try pipe.openSocketPair(&sv, .{ .NONBLOCK = true });
    defer _ = system.close(sv[1]);
    const mock_pty: Pty = .{ .master = sv[0], .pid = -1, .stdout_read_fd = -1, .error_read_fd = -1 };

    var driver = try Driver(test_option).create(testing.allocator, testing.io, mock_pty, test_options, latency_trace.none);
    defer driver.destroy();

    try writeAllTest(sv[1], "\x1b[?2004h");
    var retries: usize = test_wait_ms;
    while (retries > 0 and !driver.getModes().bracketed_paste) : (retries -= 1) {
        _ = try driver.pollAndDrain();
        sleepNs(1_000_000);
    }
    try testing.expect(driver.getModes().bracketed_paste);

    const reply = "\x1b]52;c;aGk=\x1b\\";
    try driver.sendReply(reply);
    var buf: [64]u8 = undefined;
    var len: usize = 0;
    retries = test_wait_ms;
    while (retries > 0 and len < reply.len) : (retries -= 1) {
        const n = system.read(sv[1], buf[len..].ptr, buf.len - len);
        if (n > 0) len += @intCast(n) else sleepNs(1_000_000);
    }
    try testing.expectEqualStrings(reply, buf[0..len]);
}

test "ThreadedDriver: destroy frees replies and pastes the worker never took" {
    const testing = std.testing;
    const test_option: Option = .{ .max_rows = 24, .max_cols = 80, .max_scrollback = 100, .max_clipboard_bytes = 64 };

    var sv: [2]posix.fd_t = undefined;
    try pipe.openSocketPair(&sv, .{ .NONBLOCK = true });
    defer _ = system.close(sv[1]);
    const mock_pty: Pty = .{ .master = sv[0], .pid = -1, .stdout_read_fd = -1, .error_read_fd = -1 };

    // Whether the worker takes them first or not, testing.allocator fails
    // the test on a leak.
    var driver = try Driver(test_option).create(testing.allocator, testing.io, mock_pty, test_options, latency_trace.none);
    try driver.sendReply("reply");
    try driver.writePaste("paste");
    driver.destroy();
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
    try pipe.openSocketPair(&sv, .{ .NONBLOCK = true });
    defer {
        _ = system.close(sv[1]);
    }

    const mock_pty: Pty = .{
        .master = sv[0],
        .pid = -1,
        .stdout_read_fd = -1,
        .error_read_fd = -1,
    };

    var driver = try DriverType.create(testing.allocator, testing.io, mock_pty, test_options, latency_trace.none);
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

    var retries: usize = test_wait_ms;
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
    try pipe.openSocketPair(&sv, .{ .NONBLOCK = true });
    defer {
        _ = system.close(sv[1]);
    }

    const mock_pty: Pty = .{
        .master = sv[0],
        .pid = -1,
        .stdout_read_fd = -1,
        .error_read_fd = -1,
    };

    var driver = try DriverType.create(testing.allocator, testing.io, mock_pty, test_options, latency_trace.none);
    defer driver.destroy();

    test_wake_count.store(0, .release);
    driver.wakeup_fn = testWakeup;

    // Output text from child: should trigger publish and invoke wakeup_fn
    _ = system.write(sv[1], "WakeupTest\r\n", 12);

    var retries: usize = test_wait_ms;
    while (retries > 0) : (retries -= 1) {
        if (test_wake_count.load(.acquire) > 0) break;
        std.Thread.yield() catch {};
        sleepNs(1_000_000);
    }
    try testing.expect(test_wake_count.load(.acquire) > 0);

    // Switch to alternate screen (\x1b[?1049h)
    _ = system.write(sv[1], "\x1b[?1049h", 8);

    retries = test_wait_ms;
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
    retries = test_wait_ms;
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

test "ThreadedDriver: the wheel on the alternate screen follows mode 1007" {
    const testing = std.testing;
    const test_option: Option = .{ .max_rows = 24, .max_cols = 80, .max_scrollback = 100 };

    var sv: [2]posix.fd_t = undefined;
    try pipe.openSocketPair(&sv, .{ .NONBLOCK = true });
    defer _ = system.close(sv[1]);
    const mock_pty: Pty = .{ .master = sv[0], .pid = -1, .stdout_read_fd = -1, .error_read_fd = -1 };

    var driver = try Driver(test_option).create(testing.allocator, testing.io, mock_pty, test_options, latency_trace.none);
    defer driver.destroy();

    // The title change is how the test knows the worker applied the modes.
    try writeAllTest(sv[1], "\x1b[?1049h\x1b[?1007l\x1b]2;off\x07");
    try testing.expectEqualStrings("off", try waitForTitle(test_option, driver, "off"));
    try testing.expect(driver.sendInput(.{ .mouse_scroll = .{ .col = 5, .row = 5, .button = 64, .steps = 2 } }));
    sleepNs(20_000_000);
    var read_buf: [32]u8 = undefined;
    try testing.expect(system.read(sv[1], &read_buf, read_buf.len) <= 0);

    try writeAllTest(sv[1], "\x1b[?1007h\x1b]2;on\x07");
    try testing.expectEqualStrings("on", try waitForTitle(test_option, driver, "on"));
    try testing.expect(driver.sendInput(.{ .mouse_scroll = .{ .col = 5, .row = 5, .button = 64, .steps = 1 } }));
    var n_read: isize = -1;
    var retries: usize = test_wait_ms;
    while (retries > 0 and n_read <= 0) : (retries -= 1) {
        n_read = system.read(sv[1], &read_buf, read_buf.len);
        if (n_read <= 0) sleepNs(1_000_000);
    }
    try testing.expectEqualStrings("\x1b[A", read_buf[0..@intCast(n_read)]);
}

test "ThreadedDriver: a 1 MiB paste reaches a child that echoes it back" {
    // The deadlock case: the child echoes everything it reads, so its output
    // fills up unless the worker keeps reading while it waits to write.
    const testing = std.testing;
    const gpa = testing.allocator;
    const test_option: Option = .{ .max_rows = 24, .max_cols = 80, .max_scrollback = 100 };
    const DriverType = Driver(test_option);

    var sv: [2]posix.fd_t = undefined;
    try pipe.openSocketPair(&sv, .{ .NONBLOCK = true });
    defer _ = system.close(sv[1]);

    const mock_pty: Pty = .{ .master = sv[0], .pid = -1, .stdout_read_fd = -1, .error_read_fd = -1 };
    var driver = try DriverType.create(gpa, testing.io, mock_pty, test_options, latency_trace.none);
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
    try pipe.openSocketPair(&sv, .{ .NONBLOCK = true });
    defer _ = system.close(sv[1]);

    const mock_pty: Pty = .{ .master = sv[0], .pid = -1, .stdout_read_fd = -1, .error_read_fd = -1 };
    var driver = try DriverType.create(gpa, testing.io, mock_pty, test_options, latency_trace.none);
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
