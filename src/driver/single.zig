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

const InputQueue = @import("InputQueue.zig");
pub const InputEvent = InputQueue.InputEvent;
const OutboundQueue = @import("OutboundQueue.zig");
const paste = @import("paste.zig");

const root = @import("root.zig");
pub const Events = root.Events;
pub const SharedModes = root.SharedModes;
pub const resolveAnchor = root.resolveAnchor;
pub const extractSelectionText = root.extractSelectionText;

/// Synchronous terminal driver parameterized by terminal capacity `Option`.
pub fn Driver(comptime option: Option) type {
    const TerminalType = Terminal(option);
    const FrameType = Frame(option);

    return struct {
        const Self = @This();

        allocator: Allocator,
        io: std.Io,
        pty: Pty,
        terminal: TerminalType,
        frame_snapshot: FrameType,
        sync_start: ?std.Io.Clock.Timestamp = null,
        sync_output_timeout_ms: u32,
        /// Bytes for the pty that the kernel hasn't accepted yet. Flushed on
        /// every write and at the start of each `pollAndDrain`.
        outbound: OutboundQueue = .init(OutboundQueue.default_limit),

        pub const Modes = SharedModes;

        /// Creates the terminal with `options`. The driver owns `pty` from
        /// here on and closes it in `deinit`.
        pub fn init(allocator: Allocator, io: std.Io, pty: Pty, options: root.Options) !Self {
            var terminal = try TerminalType.create(allocator);
            errdefer terminal.destroy(allocator);

            terminal.setTheme(options.theme);
            terminal.setTermName(options.term_name);

            var frame_snapshot = try FrameType.init(allocator);
            errdefer frame_snapshot.deinit(allocator);

            return .{
                .allocator = allocator,
                .io = io,
                .pty = pty,
                .terminal = terminal,
                .frame_snapshot = frame_snapshot,
                .sync_output_timeout_ms = options.sync_output_timeout_ms,
            };
        }

        /// Releases resources owned by the driver, destroying the terminal,
        /// freeing the frame snapshot buffer, and closing the PTY.
        pub fn deinit(self: *Self) void {
            const dropped = self.outbound.discard(self.allocator);
            if (dropped > 0) log.warn("closing with {d} bytes never written to the pty", .{dropped});
            self.outbound.deinit(self.allocator);
            self.frame_snapshot.deinit(self.allocator);
            self.terminal.destroy(self.allocator);
            self.pty.close(self.io);
        }

        /// Non-blocking drain of all pending PTY output into the terminal parser,
        /// writing any protocol replies back to the PTY, and collecting events.
        pub fn pollAndDrain(self: *Self) !Events {
            var events: Events = .{};
            var buffer: [64 * 1024]u8 align(64) = undefined;
            var total_read: usize = 0;

            self.flushOutbound();

            drain: while (true) {
                const n = self.pty.readRaw(&buffer) catch |err| switch (err) {
                    error.WouldBlock => break :drain,
                    // On Linux, PTY reports EIO when the child side exits.
                    error.InputOutput => {
                        events.set(.child_closed);
                        break :drain;
                    },
                    else => return err,
                };

                if (n == 0) {
                    events.set(.child_closed);
                    break :drain;
                }

                self.terminal.feed(buffer[0..n]);
                total_read += n;
            }

            if (total_read > 0) {
                events.set(.had_data);

                // Drain replies to PTY once per batch
                self.drainAndWriteReplies();

                if (self.terminal.events.any()) {
                    events.accumulateTerm(self.terminal.takeEvents());
                }
            }

            if (events.has(.child_closed)) {
                const dropped = self.outbound.discard(self.allocator);
                if (dropped > 0) log.warn("child exited with {d} bytes never written to the pty", .{dropped});
                self.terminal.end();
                if (self.terminal.events.any()) {
                    events.accumulateTerm(self.terminal.takeEvents());
                }
            }

            var in_sync_hold = false;
            if (self.terminal.mode.synchronized_output) {
                const now = std.Io.Clock.Timestamp.now(self.io, .awake);
                if (self.sync_start == null) self.sync_start = now;
                const elapsed_ms = self.sync_start.?.durationTo(now).raw.toMilliseconds();
                in_sync_hold = elapsed_ms < self.sync_output_timeout_ms;
            } else {
                self.sync_start = null;
            }

            if (!in_sync_hold and (events.has(.had_data) or self.terminal.active().dirty_rows.count() > 0 or self.terminal.active().generation != self.frame_snapshot.generation)) {
                _ = self.terminal.snapshot(&self.frame_snapshot);
            }

            return events;
        }

        /// Flushes any pending responses generated by the terminal back to
        /// the PTY, and reports replies the terminal had to drop.
        pub fn drainAndWriteReplies(self: *Self) void {
            const dropped = self.terminal.takeDroppedReplies();
            if (dropped > 0) {
                log.warn("dropped {d} terminal replies: the reply queue ({d} bytes) was full", .{ dropped, term.Response.capacity });
            }
            if (!self.terminal.hasReplies()) return;
            var reply_buf: [term.Response.capacity]u8 = undefined;
            const n = self.terminal.drainReplies(&reply_buf);
            self.send(&.{reply_buf[0..n]}) catch |err| {
                log.err("dropping a {d}-byte terminal reply: {}", .{ n, err });
            };
        }

        /// Queues `parts` for the pty as one unit, all or nothing, and writes
        /// what the kernel accepts now. Fails with error.QueueFull when the
        /// queue limit would be exceeded.
        fn send(self: *Self, parts: []const []const u8) OutboundQueue.AppendError!void {
            try self.outbound.append(self.allocator, parts);
            self.flushOutbound();
        }

        /// Writes queued bytes until the kernel buffer is full. A child that
        /// has exited (EIO) is reported by the next read, which discards the
        /// queue; other errors are logged and the bytes stay queued.
        fn flushOutbound(self: *Self) void {
            if (self.outbound.isEmpty()) return;
            _ = self.outbound.flush(self.allocator, self.pty.master) catch |err| switch (err) {
                error.InputOutput => {},
                else => log.err("pty write failed: {}", .{err}),
            };
        }

        /// Processes an input event (keyboard, mouse, resize, focus, paste).
        pub fn sendInput(self: *Self, event: InputEvent) !void {
            switch (event) {
                .bytes => |b| try self.send(&.{b.data[0..b.len]}),
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
                    } else if (self.terminal.active_buffer == .alternate) {
                        const seq = if (self.terminal.mode.cursor_keys)
                            (if (ev.button == 64) "\x1bOA" else "\x1bOB")
                        else
                            (if (ev.button == 64) "\x1b[A" else "\x1b[B");
                        var i: u16 = 0;
                        while (i < ev.steps) : (i += 1) {
                            self.send(&.{seq}) catch |err| {
                                log.err("dropping {d} wheel steps: {}", .{ ev.steps - i, err });
                                break;
                            };
                        }
                    } else {
                        // Wheel up is button 64, wheel down is button 65
                        if (ev.button == 64) {
                            self.terminal.active().scrollViewportBack(ev.steps);
                        } else {
                            self.terminal.active().scrollViewportForward(ev.steps);
                        }
                        _ = self.terminal.snapshot(&self.frame_snapshot);
                    }
                },
                .viewport_scroll => |ev| {
                    if (ev.lines > 0) {
                        self.terminal.active().scrollViewportForward(@intCast(ev.lines));
                    } else if (ev.lines < 0) {
                        self.terminal.active().scrollViewportBack(@intCast(-ev.lines));
                    }
                    _ = self.terminal.snapshot(&self.frame_snapshot);
                },
                .set_viewport_offset => |offset| {
                    if (self.terminal.active_buffer == .primary) {
                        self.terminal.primary.viewport_offset = @min(offset, @as(u32, @intCast(self.terminal.primary.scrollback_used)));
                        self.terminal.primary.dirty_rows = .full;
                        self.terminal.primary.bump();
                        _ = self.terminal.snapshot(&self.frame_snapshot);
                    }
                },
                .resize => |ev| {
                    if (self.terminal.mode.column_132) {
                        const deccolm_cols = self.terminal.active().active_cols;
                        self.terminal.resize(ev.rows, deccolm_cols);
                        // A failure is logged by Posix.resize.
                        self.pty.resize(ev.rows, deccolm_cols, ev.pixel_width, ev.pixel_height) catch {};
                    } else {
                        self.terminal.resize(ev.rows, ev.cols);
                        // A failure is logged by Posix.resize.
                        self.pty.resize(ev.rows, ev.cols, ev.pixel_width, ev.pixel_height) catch {};
                    }
                    self.terminal.active().dirty_rows = .full;
                    self.terminal.active().bump();
                    _ = self.terminal.snapshot(&self.frame_snapshot);
                },
                .focus => |focused| {
                    if (self.terminal.mode.focus_events) {
                        const seq = if (focused) "\x1b[I" else "\x1b[O";
                        try self.send(&.{seq});
                    }
                },
                .hard_reset => {
                    self.terminal.hardReset();
                    self.terminal.active().dirty_rows = .full;
                    self.terminal.active().bump();
                },
                .set_theme => |theme| {
                    self.setTheme(theme);
                },
            }
        }

        /// Updates the active terminal color theme and marks the viewport dirty.
        pub fn setTheme(self: *Self, theme: Theme) void {
            self.terminal.setTheme(theme);
            self.terminal.active().dirty_rows = .full;
            self.terminal.active().bump();
            _ = self.terminal.snapshot(&self.frame_snapshot);
        }

        /// Writes pasted clipboard text. With bracketed paste on, it is
        /// wrapped in the paste markers and its ESC bytes are removed (see
        /// `paste.queueBracketed`).
        pub fn writePaste(self: *Self, text: []const u8) OutboundQueue.AppendError!void {
            if (self.terminal.mode.bracketed_paste) {
                try paste.queueBracketed(&self.outbound, self.allocator, text);
                self.flushOutbound();
            } else {
                try self.send(&.{text});
            }
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
                .reports_motion = self.terminal.mode.mouse_tracking.reportsMotion(),
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

        /// Queues raw bytes for the pty.
        pub fn sendBytes(self: *Self, bytes: []const u8) OutboundQueue.AppendError!void {
            try self.send(&.{bytes});
        }

        /// Copies selected text into `buf` without allocating. Returns bytes written.
        pub fn copySelectionText(self: *Self, selection: anytype, buf: []u8) usize {
            return root.extractSelectionText(self.terminal.active(), selection, buf);
        }
    };
}

pub const SingleDriver = Driver;

const test_options: root.Options = .{ .theme = Theme.graphite, .sync_output_timeout_ms = 150 };

test "SingleDriver: init, deinit, and snapshot" {
    const testing = std.testing;
    const test_option: Option = .{
        .max_rows = 24,
        .max_cols = 80,
        .max_scrollback = 100,
    };
    const DriverType = Driver(test_option);

    var driver = try DriverType.init(testing.allocator, testing.io, Pty.inactive, test_options);
    defer driver.deinit();

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

    var driver = try DriverType.init(testing.allocator, testing.io, mock_pty, test_options);
    defer driver.deinit();

    // Send input from GUI to PTY
    try driver.sendInput(InputEvent.makeBytes("hello"));

    // Verify it arrived at the other end of the socketpair
    var read_buf: [128]u8 = undefined;
    const n_read = system.read(sv[1], &read_buf, read_buf.len);
    try testing.expectEqual(@as(isize, 5), n_read);
    try testing.expectEqualStrings("hello", read_buf[0..5]);

    // Write data from simulated child into socketpair
    _ = system.write(sv[1], "RexTerm\r\n", 9);

    // Poll and drain through driver
    const events = try driver.pollAndDrain();
    try testing.expect(events.has(.had_data));
    try testing.expect(!events.has(.child_closed));

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

    var driver = try DriverType.init(testing.allocator, testing.io, mock_pty, test_options);
    defer driver.deinit();

    // Child sends CSI c (DA1 query)
    _ = system.write(sv[1], "\x1b[c", 3);

    const events = try driver.pollAndDrain();
    try testing.expect(events.has(.had_data));

    // SingleDriver should have processed query, generated response, and drained to PTY
    var reply_buf: [128]u8 = undefined;
    const n = system.read(sv[1], &reply_buf, reply_buf.len);
    try testing.expect(n > 0);
    const n_u: usize = @intCast(n);
    try testing.expectEqualStrings("\x1b[?62;22c", reply_buf[0..n_u]);
}

test "SingleDriver: XTGETTCAP reports the TERM from Options" {
    const testing = std.testing;
    const test_option: Option = .{ .max_rows = 24, .max_cols = 80, .max_scrollback = 100 };

    var sv: [2]posix.fd_t = undefined;
    try testing.expectEqual(@as(c_int, 0), system.socketpair(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.NONBLOCK, 0, &sv));
    defer _ = system.close(sv[1]);
    const mock_pty: Pty = .{ .master = sv[0], .pid = -1, .stdout_read_fd = -1, .error_read_fd = -1 };

    var options = test_options;
    options.term_name = try .init("rex");
    var driver = try Driver(test_option).init(testing.allocator, testing.io, mock_pty, options);
    defer driver.deinit();

    const query = "\x1bP+q544E\x1b\\"; // TN
    _ = system.write(sv[1], query, query.len);
    _ = try driver.pollAndDrain();

    var reply_buf: [64]u8 = undefined;
    const n = system.read(sv[1], &reply_buf, reply_buf.len);
    try testing.expect(n > 0);
    try testing.expectEqualStrings("\x1bP1+r544E=726578\x1b\\", reply_buf[0..@intCast(n)]);
}

test "SingleDriver: extractSelectionText for stream and block selections" {
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
    defer _ = system.close(sv[1]);

    const mock_pty: Pty = .{
        .master = sv[0],
        .pid = -1,
        .stdout_read_fd = -1,
        .error_read_fd = -1,
    };

    var driver = try DriverType.init(testing.allocator, testing.io, mock_pty, test_options);
    defer driver.deinit();

    // Write text to terminal
    _ = system.write(sv[1], "ABCDEF\r\n123456\r\n", 16);
    _ = try driver.pollAndDrain();

    var copy_buf: [128]u8 = undefined;

    // Character stream selection across row 0 col 1 ('B') to row 1 col 3 ('4')
    const char_sel = .{
        .kind = @import("../Selection.zig").Kind.character,
        .range = .{
            .start = .{ .row = 0, .col = 1, .captured_scroll_gen = 0 },
            .end = .{ .row = 1, .col = 3, .captured_scroll_gen = 0 },
        },
    };
    const len1 = driver.copySelectionText(char_sel, &copy_buf);
    try testing.expectEqualStrings("BCDEF\n1234", copy_buf[0..len1]);

    // Block rectangular selection spanning cols 1..3 on rows 0 and 1
    const block_sel = .{
        .kind = @import("../Selection.zig").Kind.block,
        .range = .{
            .start = .{ .row = 0, .col = 1, .captured_scroll_gen = 0 },
            .end = .{ .row = 1, .col = 3, .captured_scroll_gen = 0 },
        },
    };
    const len2 = driver.copySelectionText(block_sel, &copy_buf);
    try testing.expectEqualStrings("BCD\n234", copy_buf[0..len2]);
}

test "SingleDriver: mouse_scroll primary viewport vs alternate alt_scroll" {
    const testing = std.testing;
    const test_option: Option = .{
        .max_rows = 10,
        .max_cols = 40,
        .max_scrollback = 50,
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

    var driver = try DriverType.init(testing.allocator, testing.io, mock_pty, test_options);
    defer driver.deinit();

    var i: usize = 0;
    while (i < 20) : (i += 1) {
        _ = system.write(sv[1], "line\r\n", 6);
    }
    _ = try driver.pollAndDrain();
    try testing.expect(driver.terminal.primary.scrollback_used > 0);
    try testing.expectEqual(@as(u32, 0), driver.terminal.primary.viewport_offset);

    // Scroll up 3 lines in primary buffer
    try driver.sendInput(.{
        .mouse_scroll = .{
            .col = 5,
            .row = 5,
            .button = 64, // Wheel up
            .steps = 3,
        },
    });
    try testing.expectEqual(@as(u32, 3), driver.terminal.primary.viewport_offset);

    // Scroll down 2 lines in primary buffer
    try driver.sendInput(.{
        .mouse_scroll = .{
            .col = 5,
            .row = 5,
            .button = 65, // Wheel down
            .steps = 2,
        },
    });
    try testing.expectEqual(@as(u32, 1), driver.terminal.primary.viewport_offset);

    _ = system.write(sv[1], "\x1b[?1049h", 8);
    _ = try driver.pollAndDrain();
    try testing.expect(driver.terminal.active_buffer == .alternate);

    // Scroll up in alternate screen should emit cursor up keys (\x1b[A)
    try driver.sendInput(.{
        .mouse_scroll = .{
            .col = 5,
            .row = 5,
            .button = 64, // Wheel up
            .steps = 2,
        },
    });

    var read_buf: [32]u8 = undefined;
    var n_read = system.read(sv[1], &read_buf, read_buf.len);
    try testing.expectEqual(@as(isize, 6), n_read);
    try testing.expectEqualStrings("\x1b[A\x1b[A", read_buf[0..6]);

    // Scroll down in alternate screen should emit cursor down keys (\x1b[B)
    try driver.sendInput(.{
        .mouse_scroll = .{
            .col = 5,
            .row = 5,
            .button = 65, // Wheel down
            .steps = 1,
        },
    });
    n_read = system.read(sv[1], &read_buf, read_buf.len);
    try testing.expectEqual(@as(isize, 3), n_read);
    try testing.expectEqualStrings("\x1b[B", read_buf[0..3]);
}

test "SingleDriver: a 1 MiB paste is delivered whole across pollAndDrain calls" {
    const testing = std.testing;
    const gpa = testing.allocator;
    const opt: Option = .{ .max_rows = 24, .max_cols = 80, .max_scrollback = 100 };

    var sv: [2]posix.fd_t = undefined;
    const rc = system.socketpair(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.NONBLOCK, 0, &sv);
    try testing.expectEqual(@as(c_int, 0), rc);
    defer _ = system.close(sv[1]);

    const mock_pty: Pty = .{ .master = sv[0], .pid = -1, .stdout_read_fd = -1, .error_read_fd = -1 };
    var driver = try Driver(opt).init(gpa, testing.io, mock_pty, test_options);
    defer driver.deinit();

    const payload = try gpa.alloc(u8, 1024 * 1024);
    defer gpa.free(payload);
    for (payload, 0..) |*b, i| b.* = @truncate(i *% 31 +% 5);

    try driver.writePaste(payload);
    try testing.expect(!driver.outbound.isEmpty()); // the kernel took only part

    var received: std.ArrayList(u8) = .empty;
    defer received.deinit(gpa);
    var chunk: [16 * 1024]u8 = undefined;
    var rounds: usize = 0;
    while (received.items.len < payload.len) : (rounds += 1) {
        if (rounds > 100_000) return error.TestPasteNotDelivered;
        const n = system.read(sv[1], &chunk, chunk.len);
        if (posix.errno(n) == .SUCCESS and n > 0) try received.appendSlice(gpa, chunk[0..@intCast(n)]);
        _ = try driver.pollAndDrain();
    }
    try testing.expectEqualSlices(u8, payload, received.items);
    try testing.expect(driver.outbound.isEmpty());
}

test "SingleDriver: pasted text can't end a bracketed paste early" {
    const testing = std.testing;
    const gpa = testing.allocator;
    const opt: Option = .{ .max_rows = 24, .max_cols = 80, .max_scrollback = 100 };

    var sv: [2]posix.fd_t = undefined;
    const rc = system.socketpair(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.NONBLOCK, 0, &sv);
    try testing.expectEqual(@as(c_int, 0), rc);
    defer _ = system.close(sv[1]);

    const mock_pty: Pty = .{ .master = sv[0], .pid = -1, .stdout_read_fd = -1, .error_read_fd = -1 };
    var driver = try Driver(opt).init(gpa, testing.io, mock_pty, test_options);
    defer driver.deinit();

    const malicious = "ls\x1b[201~rm -rf ~\n";
    var read_buf: [64]u8 = undefined;

    // Off: the text goes through unchanged, ESC included.
    try driver.writePaste(malicious);
    var n = system.read(sv[1], &read_buf, read_buf.len);
    try testing.expectEqualStrings(malicious, read_buf[0..@intCast(n)]);

    // The child turns bracketed paste on.
    _ = system.write(sv[1], "\x1b[?2004h", 8);
    _ = try driver.pollAndDrain();
    try testing.expect(driver.terminal.mode.bracketed_paste);

    try driver.writePaste(malicious);
    n = system.read(sv[1], &read_buf, read_buf.len);
    try testing.expectEqualStrings("\x1b[200~ls[201~rm -rf ~\n\x1b[201~", read_buf[0..@intCast(n)]);
}

test "SingleDriver: a flood of queries is reported, the replies that fit arrive whole" {
    const testing = std.testing;
    const gpa = testing.allocator;
    // The drop warning is the expected outcome here; keep it out of the
    // test output (the runner resets the level for the next test).
    testing.log_level = .err;
    const opt: Option = .{ .max_rows = 24, .max_cols = 80, .max_scrollback = 100 };

    var sv: [2]posix.fd_t = undefined;
    const rc = system.socketpair(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.NONBLOCK, 0, &sv);
    try testing.expectEqual(@as(c_int, 0), rc);
    defer _ = system.close(sv[1]);

    const mock_pty: Pty = .{ .master = sv[0], .pid = -1, .stdout_read_fd = -1, .error_read_fd = -1 };
    var driver = try Driver(opt).init(gpa, testing.io, mock_pty, test_options);
    defer driver.deinit();

    // 300 CPR queries in one read: 1800 bytes of replies for a 1024-byte queue.
    const queries = "\x1b[6n" ** 300;
    try testing.expectEqual(@as(isize, queries.len), system.write(sv[1], queries, queries.len));
    _ = try driver.pollAndDrain();

    // The driver took the drop count (and logged it); nothing is left over.
    try testing.expectEqual(0, driver.terminal.response.dropped);
    try testing.expect(!driver.terminal.hasReplies());

    const cpr = "\x1b[1;1R";
    var buf: [4096]u8 = undefined;
    const n = system.read(sv[1], &buf, buf.len);
    try testing.expect(n > 0);
    const got = buf[0..@intCast(n)];
    try testing.expectEqual((term.Response.capacity / cpr.len) * cpr.len, got.len);
    var it = std.mem.window(u8, got, cpr.len, cpr.len);
    while (it.next()) |r| try testing.expectEqualStrings(cpr, r);
}
