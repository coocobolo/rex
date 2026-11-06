//! Bytes waiting to be written to the pty, in the order they were queued.
//!
//! The pty master is non-blocking, and the kernel accepts only a small
//! amount of input at a time (about 14 KB on Linux). Everything the driver
//! sends to the child (keystrokes, pastes, terminal replies, focus and
//! mouse reports) goes through one queue, so nothing is dropped when the
//! kernel buffer is full and the order is kept. `flush` writes what the
//! kernel accepts and leaves the rest for the next call; the owner calls it
//! again when the fd becomes writable (POLLOUT).
//!
//! Ownership: the queue owns its buffer, allocated with the allocator passed
//! to each call; it must be the same allocator throughout, and `deinit`
//! frees the buffer. Appended bytes are copied, so callers keep ownership of
//! what they pass in.

const std = @import("std");
const posix = std.posix;
const system = posix.system;
const Allocator = std.mem.Allocator;

const OutboundQueue = @This();

/// Queued bytes. The first `head` of them have already been written.
buf: std.ArrayList(u8) = .empty,
head: usize = 0,
/// Most bytes that may be pending at once. An append that would exceed it
/// is refused whole.
limit: usize,

/// Default `limit`: far above any normal paste, so it only stops a child
/// that has stopped reading from accumulating input without bound.
pub const default_limit = 64 * 1024 * 1024;

/// Capacity kept after the queue drains; a larger buffer (left by a big
/// paste) is freed, so memory returns to normal once the paste is sent.
pub const retained_capacity = 64 * 1024;

pub const AppendError = error{QueueFull} || Allocator.Error;

pub const FlushError = error{
    /// The child side is gone (Linux reports EIO on the master).
    InputOutput,
} || posix.UnexpectedError;

pub fn init(limit: usize) OutboundQueue {
    return .{ .limit = limit };
}

pub fn deinit(self: *OutboundQueue, gpa: Allocator) void {
    self.buf.deinit(gpa);
    self.* = undefined;
}

/// Bytes queued and not yet written.
pub fn pending(self: *const OutboundQueue) usize {
    return self.buf.items.len - self.head;
}

pub fn isEmpty(self: *const OutboundQueue) bool {
    return self.pending() == 0;
}

/// Queues `parts` as one unit, in order: all of them or none. Fails with
/// `error.QueueFull`, queuing nothing, when the pending bytes would exceed
/// `limit`.
pub fn append(self: *OutboundQueue, gpa: Allocator, parts: []const []const u8) AppendError!void {
    var total: usize = 0;
    for (parts) |part| total += part.len;
    if (total > self.limit - self.pending()) return error.QueueFull;

    self.compact();
    try self.buf.ensureUnusedCapacity(gpa, total);
    for (parts) |part| self.buf.appendSliceAssumeCapacity(part);
}

/// Writes as much of the queue to `fd` as it accepts without blocking and
/// returns the number of bytes written. Stops at EAGAIN; the rest stays
/// queued. On an error the unwritten bytes stay queued too, so the caller
/// decides whether to `discard` them.
pub fn flush(self: *OutboundQueue, gpa: Allocator, fd: posix.fd_t) FlushError!usize {
    var written: usize = 0;
    while (self.pending() > 0) {
        const rest = self.buf.items[self.head..];
        const rc = system.write(fd, rest.ptr, rest.len);
        switch (posix.errno(rc)) {
            .SUCCESS => {
                const n: usize = @intCast(rc);
                self.head += n;
                written += n;
            },
            .INTR => continue,
            .AGAIN => break,
            .IO => return error.InputOutput,
            else => |err| return posix.unexpectedErrno(err),
        }
    }
    if (self.pending() == 0) self.reset(gpa);
    return written;
}

/// Drops every pending byte, for when the child is gone. Returns how many
/// were dropped, so the caller can report the loss.
pub fn discard(self: *OutboundQueue, gpa: Allocator) usize {
    const dropped = self.pending();
    self.reset(gpa);
    return dropped;
}

/// Empties the buffer, freeing it if a big append left it larger than
/// `retained_capacity`.
fn reset(self: *OutboundQueue, gpa: Allocator) void {
    if (self.buf.capacity > retained_capacity) {
        self.buf.clearAndFree(gpa);
    } else {
        self.buf.clearRetainingCapacity();
    }
    self.head = 0;
}

/// Moves the unwritten bytes to the front once at least half the buffer is
/// already written, so a queue that is never fully drained doesn't keep
/// growing.
fn compact(self: *OutboundQueue) void {
    if (self.head == 0 or self.head < self.buf.items.len / 2) return;
    const rest = self.buf.items[self.head..];
    std.mem.copyForwards(u8, self.buf.items[0..rest.len], rest);
    self.buf.shrinkRetainingCapacity(rest.len);
    self.head = 0;
}

// Tests run against a non-blocking socketpair, which behaves like the pty
// master for these purposes: writes stop with EAGAIN when its buffer is full.

const testing = std.testing;

const Pair = struct {
    writer: posix.fd_t,
    reader: posix.fd_t,

    fn open() !Pair {
        var sv: [2]posix.fd_t = undefined;
        const rc = system.socketpair(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.NONBLOCK, 0, &sv);
        if (posix.errno(rc) != .SUCCESS) return error.SocketPairFailed;
        return .{ .writer = sv[0], .reader = sv[1] };
    }

    fn close(self: Pair) void {
        _ = system.close(self.writer);
        _ = system.close(self.reader);
    }

    /// Reads up to `max` bytes that are available now, appending to `out`.
    fn drain(self: Pair, out: *std.ArrayList(u8), max: usize) !void {
        var chunk: [4096]u8 = undefined;
        var left = max;
        while (left > 0) {
            const want = @min(left, chunk.len);
            const rc = system.read(self.reader, &chunk, want);
            switch (posix.errno(rc)) {
                .SUCCESS => {
                    const n: usize = @intCast(rc);
                    if (n == 0) return;
                    try out.appendSlice(testing.allocator, chunk[0..n]);
                    left -= n;
                },
                .AGAIN => return,
                else => return error.ReadFailed,
            }
        }
    }
};

/// Deterministic test data that makes a misplaced byte visible.
fn pattern(buf: []u8, seed: u8) void {
    for (buf, 0..) |*b, i| b.* = @truncate(i *% 31 +% seed);
}

test "OutboundQueue: a payload larger than the kernel buffer arrives whole and in order" {
    const gpa = testing.allocator;
    const pair = try Pair.open();
    defer pair.close();

    const payload = try gpa.alloc(u8, 1024 * 1024);
    defer gpa.free(payload);
    pattern(payload, 7);

    var queue: OutboundQueue = .init(64 * 1024 * 1024);
    defer queue.deinit(gpa);
    try queue.append(gpa, &.{payload});

    // The first flush stops at EAGAIN well before the end.
    _ = try queue.flush(gpa, pair.writer);
    try testing.expect(queue.pending() > 0);

    var received: std.ArrayList(u8) = .empty;
    defer received.deinit(gpa);
    // A slow reader: a little at a time, flushing in between. The bound
    // turns a lost byte into a failure instead of a hang.
    var rounds: usize = 0;
    while (!queue.isEmpty() or received.items.len < payload.len) : (rounds += 1) {
        if (rounds > 100_000) return error.TestNotDelivered;
        try pair.drain(&received, 8 * 1024);
        _ = try queue.flush(gpa, pair.writer);
    }
    try testing.expectEqualSlices(u8, payload, received.items);
}

test "OutboundQueue: parts of one append stay together, appends keep their order" {
    const gpa = testing.allocator;
    const pair = try Pair.open();
    defer pair.close();

    var queue: OutboundQueue = .init(1024 * 1024);
    defer queue.deinit(gpa);

    var paste: [200 * 1024]u8 = undefined;
    pattern(&paste, 3);
    try queue.append(gpa, &.{"a"});
    try queue.append(gpa, &.{ "\x1b[200~", &paste, "\x1b[201~" });
    try queue.append(gpa, &.{"b"});

    var received: std.ArrayList(u8) = .empty;
    defer received.deinit(gpa);
    while (!queue.isEmpty()) {
        _ = try queue.flush(gpa, pair.writer);
        try pair.drain(&received, 16 * 1024);
    }
    try pair.drain(&received, std.math.maxInt(usize));

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(gpa);
    try expected.appendSlice(gpa, "a\x1b[200~");
    try expected.appendSlice(gpa, &paste);
    try expected.appendSlice(gpa, "\x1b[201~b");
    try testing.expectEqualSlices(u8, expected.items, received.items);
}

test "OutboundQueue: an append over the limit is refused whole" {
    const gpa = testing.allocator;

    var queue: OutboundQueue = .init(10);
    defer queue.deinit(gpa);

    try queue.append(gpa, &.{"12345678"});
    try testing.expectError(error.QueueFull, queue.append(gpa, &.{ "9", "ab" }));
    try testing.expectEqual(8, queue.pending());
    try queue.append(gpa, &.{ "9", "a" }); // exactly at the limit
    try testing.expectEqual(10, queue.pending());
}

test "OutboundQueue: discard drops and reports pending bytes" {
    const gpa = testing.allocator;

    var queue: OutboundQueue = .init(1024);
    defer queue.deinit(gpa);

    try queue.append(gpa, &.{"hello"});
    try testing.expectEqual(5, queue.discard(gpa));
    try testing.expect(queue.isEmpty());
    try testing.expectEqual(0, queue.discard(gpa));
}

test "OutboundQueue: frees a large buffer once drained, keeps a small one" {
    const gpa = testing.allocator;
    const pair = try Pair.open();
    defer pair.close();

    var queue: OutboundQueue = .init(64 * 1024 * 1024);
    defer queue.deinit(gpa);

    try queue.append(gpa, &.{"small"});
    _ = try queue.flush(gpa, pair.writer);
    try testing.expect(queue.isEmpty());
    try testing.expect(queue.buf.capacity > 0 and queue.buf.capacity <= retained_capacity);

    var received: std.ArrayList(u8) = .empty;
    defer received.deinit(gpa);
    const big = try gpa.alloc(u8, 4 * retained_capacity);
    defer gpa.free(big);
    pattern(big, 1);
    try queue.append(gpa, &.{big});
    while (!queue.isEmpty()) {
        _ = try queue.flush(gpa, pair.writer);
        try pair.drain(&received, std.math.maxInt(usize));
    }
    try testing.expectEqual(0, queue.buf.capacity);
}

test "OutboundQueue: compaction keeps unwritten bytes and their order" {
    const gpa = testing.allocator;

    var queue: OutboundQueue = .init(1024);
    defer queue.deinit(gpa);

    try queue.append(gpa, &.{"0123456789"});
    queue.head = 6; // as if a flush had written "012345"
    try queue.append(gpa, &.{"ab"});
    try testing.expectEqual(0, queue.head);
    try testing.expectEqualStrings("6789ab", queue.buf.items);
}
