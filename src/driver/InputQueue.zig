//! Bounded Single-Producer Single-Consumer (SPSC) lock-free ring buffer
//! for transmitting user input events from the GUI thread to the Driver thread.
//!
//! Includes an OS-level wakeup channel (Linux eventfd with POSIX self-pipe fallback)
//! allowing the Driver thread's `poll()` loop to sleep with zero CPU usage and wake
//! instantaneously on new input.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const system = posix.system;

/// Maximum payload for an inlined bytes event.
pub const max_bytes_payload = 128;

/// Single input event sent from GUI thread to Driver thread.
pub const InputEvent = union(enum) {
    /// Printable text / character bytes to write to PTY (typed text, escape codes, paste chunks).
    bytes: struct {
        data: [max_bytes_payload]u8,
        len: u8,
    },
    /// Clipboard paste payload.
    paste: []const u8,
    /// Mouse button press or release.
    mouse_button: struct {
        col: u16,
        row: u16,
        button: u8,
        mods: u8,
        press: bool,
    },
    /// Mouse motion / drag.
    mouse_motion: struct {
        col: u16,
        row: u16,
        button: ?u8,
        mods: u8,
    },
    /// Mouse wheel scroll steps.
    mouse_scroll: struct {
        col: u16,
        row: u16,
        button: u8,
        steps: u16,
    },
    /// Viewport scrollback adjustment (user scrolled scrollbar or trackpad).
    viewport_scroll: struct {
        lines: i32,
    },
    /// Explicit viewport offset assignment (scrollbar drag or snap to live).
    set_viewport_offset: u32,
    /// Window & PTY resize.
    resize: struct {
        rows: u16,
        cols: u16,
        pixel_width: u16,
        pixel_height: u16,
    },
    /// Window focus in / out.
    focus: bool,
    /// Terminal hard reset request.
    hard_reset,

    /// Helper to create a bytes event from a slice (up to max_bytes_payload).
    pub fn makeBytes(slice: []const u8) InputEvent {
        std.debug.assert(slice.len <= max_bytes_payload);
        var ev: InputEvent = .{
            .bytes = .{
                .data = undefined,
                .len = @intCast(slice.len),
            },
        };
        @memcpy(ev.bytes.data[0..slice.len], slice);
        return ev;
    }
};

/// Cross-platform OS notification channel for waking `poll()` loops.
pub const WakeupChannel = struct {
    read_fd: posix.fd_t,
    write_fd: posix.fd_t,
    is_eventfd: bool,

    pub fn init() !WakeupChannel {
        if (builtin.os.tag == .linux) {
            const rc = std.os.linux.eventfd(0, std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK);
            switch (posix.errno(rc)) {
                .SUCCESS => {
                    const fd: posix.fd_t = @intCast(rc);
                    return .{
                        .read_fd = fd,
                        .write_fd = fd,
                        .is_eventfd = true,
                    };
                },
                else => {}, // fallback to pipe2
            }
        }

        var pipe_fds: [2]posix.fd_t = undefined;
        const pipe_flags: posix.O = .{ .CLOEXEC = true, .NONBLOCK = true };
        if (system.pipe2(&pipe_fds, pipe_flags) == -1) return error.PipeFailed;

        return .{
            .read_fd = pipe_fds[0],
            .write_fd = pipe_fds[1],
            .is_eventfd = false,
        };
    }

    pub fn deinit(self: *WakeupChannel) void {
        if (self.is_eventfd) {
            _ = system.close(self.read_fd);
        } else {
            _ = system.close(self.read_fd);
            _ = system.close(self.write_fd);
        }
        self.* = undefined;
    }

    /// Wakes up the listener blocked in `poll()`.
    pub fn notify(self: WakeupChannel) void {
        if (self.is_eventfd) {
            const val: u64 = 1;
            const bytes = std.mem.asBytes(&val);
            _ = system.write(self.write_fd, bytes.ptr, bytes.len);
        } else {
            const b: [1]u8 = .{1};
            _ = system.write(self.write_fd, &b, 1);
        }
    }

    /// Drains pending wakeup signals.
    pub fn drain(self: WakeupChannel) void {
        if (self.is_eventfd) {
            var val: u64 = undefined;
            const bytes = std.mem.asBytes(&val);
            _ = system.read(self.read_fd, bytes.ptr, bytes.len);
        } else {
            var buf: [64]u8 = undefined;
            while (true) {
                const rc = system.read(self.read_fd, &buf, buf.len);
                if (rc <= 0) break;
            }
        }
    }
};

const InputQueue = @This();
pub const Event = InputEvent;

pub const capacity = 256;
comptime {
    std.debug.assert(std.math.isPowerOfTwo(capacity));
}

/// Producer index written only by GUI thread. Aligned to 64B to prevent false sharing.
head: std.atomic.Value(usize) align(64),

/// Consumer index written only by Driver thread. Aligned to 64B to prevent false sharing.
tail: std.atomic.Value(usize) align(64),

/// Flat contiguous event buffer aligned to CPU cache lines (64 bytes).
buffer: [capacity]InputEvent align(64),

/// OS wakeup channel for waking poll() when items are pushed.
wakeup: WakeupChannel,

pub fn init() !InputQueue {
    return .{
        .head = std.atomic.Value(usize).init(0),
        .tail = std.atomic.Value(usize).init(0),
        .buffer = undefined,
        .wakeup = try WakeupChannel.init(),
    };
}

pub fn deinit(self: *InputQueue) void {
    self.wakeup.deinit();
    self.* = undefined;
}

/// Pushes an event into the queue without triggering an OS wakeup syscall.
/// Use when enqueueing multiple events in a batch, followed by an explicit `wake()`.
/// Returns false if the queue is full.
pub fn pushNoNotify(self: *InputQueue, event: InputEvent) bool {
    const h = self.head.load(.monotonic);
    const t = self.tail.load(.acquire);

    if (h -% t >= capacity) return false;

    self.buffer[h & (capacity - 1)] = event;
    self.head.store(h +% 1, .release);
    return true;
}

/// Pushes an event into the queue and notifies the wakeup channel.
/// Returns false if the queue is full.
pub fn push(self: *InputQueue, event: InputEvent) bool {
    if (!self.pushNoNotify(event)) return false;
    self.wakeup.notify();
    return true;
}

/// Pushes an arbitrary slice of bytes into the queue, splitting into chunks if needed.
/// Uses batching with a single wakeup syscall at the end to minimize kernel transitions.
/// Returns false if the queue ran out of capacity before pushing all bytes.
pub fn pushBytes(self: *InputQueue, bytes: []const u8) bool {
    var rest = bytes;
    var any_pushed = false;
    while (rest.len > 0) {
        const chunk_len: u8 = @intCast(@min(rest.len, max_bytes_payload));
        var ev: InputEvent = .{
            .bytes = .{
                .data = undefined,
                .len = chunk_len,
            },
        };
        @memcpy(ev.bytes.data[0..chunk_len], rest[0..chunk_len]);
        if (!self.pushNoNotify(ev)) {
            if (any_pushed) self.wake();
            return false;
        }
        any_pushed = true;
        rest = rest[chunk_len..];
    }
    if (any_pushed) self.wake();
    return true;
}

/// Pops the next pending event from the queue.
/// Returns null if the queue is empty.
pub fn pop(self: *InputQueue) ?InputEvent {
    const t = self.tail.load(.monotonic);
    const h = self.head.load(.acquire);

    if (t == h) return null;

    const event = self.buffer[t & (capacity - 1)];
    self.tail.store(t +% 1, .release);
    return event;
}

/// Explicitly signals the OS wakeup channel (e.g. on shutdown).
pub inline fn wake(self: *InputQueue) void {
    self.wakeup.notify();
}

/// Drains any pending wakeup signal from the OS wakeup channel.
pub inline fn drainWakeup(self: *InputQueue) void {
    self.wakeup.drain();
}

/// Returns the file descriptor to include in `poll()` fd sets.
pub inline fn pollFd(self: *const InputQueue) posix.fd_t {
    return self.wakeup.read_fd;
}

/// Returns true if the queue currently has pending events.
pub inline fn hasPending(self: *const InputQueue) bool {
    return self.head.load(.monotonic) != self.tail.load(.monotonic);
}

test "InputQueue: init and push pop single event" {
    const testing = std.testing;
    var queue = try InputQueue.init();
    defer queue.deinit();

    try testing.expect(!queue.hasPending());
    try testing.expectEqual(@as(?InputEvent, null), queue.pop());

    const ev: InputEvent = .{
        .mouse_button = .{
            .col = 10,
            .row = 20,
            .button = 0,
            .mods = 4,
            .press = true,
        },
    };
    try testing.expect(queue.push(ev));
    try testing.expect(queue.hasPending());

    const popped = queue.pop();
    try testing.expect(popped != null);
    try testing.expectEqual(@as(u16, 10), popped.?.mouse_button.col);
    try testing.expectEqual(@as(u16, 20), popped.?.mouse_button.row);
    try testing.expect(!queue.hasPending());
}

test "InputQueue: pushBytes splits long slices" {
    const testing = std.testing;
    var queue = try InputQueue.init();
    defer queue.deinit();

    var sample: [300]u8 = undefined;
    for (&sample, 0..) |*b, i| b.* = @intCast(i % 256);

    try testing.expect(queue.pushBytes(&sample));

    var total_received: usize = 0;
    while (queue.pop()) |ev| {
        switch (ev) {
            .bytes => |b| {
                try testing.expectEqualSlices(u8, sample[total_received .. total_received + b.len], b.data[0..b.len]);
                total_received += b.len;
            },
            else => unreachable,
        }
    }
    try testing.expectEqual(@as(usize, 300), total_received);
}

test "InputQueue: wakeup channel signaling" {
    const testing = std.testing;
    var queue = try InputQueue.init();
    defer queue.deinit();

    var poll_fds = [_]system.pollfd{
        .{ .fd = queue.pollFd(), .events = system.POLL.IN, .revents = 0 },
    };

    // Before push: poll with 0 timeout returns 0 (not readable)
    const n0 = system.poll(&poll_fds, 1, 0);
    try testing.expectEqual(@as(c_int, 0), n0);

    // After push: poll returns 1 (readable)
    _ = queue.push(.hard_reset);
    const n1 = system.poll(&poll_fds, 1, 0);
    try testing.expectEqual(@as(c_int, 1), n1);

    // After drain: poll returns 0 again
    queue.drainWakeup();
    poll_fds[0].revents = 0;
    const n2 = system.poll(&poll_fds, 1, 0);
    try testing.expectEqual(@as(c_int, 0), n2);
}

test "InputQueue: multi-threaded producer consumer stress test" {
    const testing = std.testing;
    var queue = try InputQueue.init();
    defer queue.deinit();

    const iterations = 50_000;

    const Context = struct {
        q: *InputQueue,
        done: std.atomic.Value(bool),
        received: usize,

        fn producer(ctx: *@This()) void {
            var i: usize = 0;
            while (i < iterations) {
                const ev: InputEvent = .{
                    .viewport_scroll = .{ .lines = @intCast(i) },
                };
                if (ctx.q.push(ev)) {
                    i += 1;
                } else {
                    std.Thread.yield() catch {};
                }
            }
            ctx.done.store(true, .release);
        }

        fn consumer(ctx: *@This()) void {
            while (!ctx.done.load(.acquire) or ctx.q.hasPending()) {
                if (ctx.q.pop()) |ev| {
                    std.debug.assert(ev.viewport_scroll.lines == @as(i32, @intCast(ctx.received)));
                    ctx.received += 1;
                } else {
                    std.Thread.yield() catch {};
                }
            }
        }
    };

    var ctx = Context{
        .q = &queue,
        .done = std.atomic.Value(bool).init(false),
        .received = 0,
    };

    const prod_thread = try std.Thread.spawn(.{}, Context.producer, .{&ctx});
    const cons_thread = try std.Thread.spawn(.{}, Context.consumer, .{&ctx});

    prod_thread.join();
    cons_thread.join();

    try testing.expectEqual(iterations, ctx.received);
}
