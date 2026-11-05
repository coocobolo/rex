//! Wait-free triple buffer for publishing `term.Frame` snapshots from the Driver
//! to the GUI thread.
//!
//! Three pre-allocated frame buffers are partitioned among a private fill buffer owned
//! by the producer, a private read buffer owned by the consumer, and a shared atomic
//! mailbox slot (`ready_idx`). Publishing swaps the fill buffer into the mailbox slot
//! using atomic exchange with Release ordering. Consuming retrieves the latest published
//! frame via atomic compare-exchange with Acquire ordering, dropping stale intermediate frames.
//!
//! Neither thread ever blocks or waits. Reader and writer state indices are aligned to
//! 64-byte boundaries to prevent CPU cache-line ping-ponging across cores.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Frame = @import("../term/root.zig").Frame;
const Option = @import("../term/root.zig").Option;

/// Wait-free triple buffer parameterized by terminal capacity `Option`.
pub fn Buffer(comptime option: Option) type {
    const FrameType = Frame(option);

    return struct {
        const Self = @This();

        /// Three pre-allocated viewport frames.
        frames: [3]FrameType,

        /// Private buffer index currently owned by producer (Driver thread).
        /// Aligned to 64 bytes to eliminate false sharing with consumer thread.
        fill_idx: u8 align(64) = 0,

        /// Private buffer index currently owned by consumer (GUI thread).
        /// Aligned to 64 bytes to eliminate false sharing with producer thread.
        read_idx: u8 align(64) = 1,

        /// Shared atomic status word packing ready_idx (bits 0..1) and has_new flag (bit 2).
        /// Aligned to 64 bytes to eliminate false sharing between producer and consumer cores.
        shared_state: std.atomic.Value(u32) align(64),

        /// Pre-allocates all 3 frames with 64-byte alignment. Free with `deinit`.
        pub fn init(allocator: Allocator) !Self {
            var f0 = try FrameType.init(allocator);
            errdefer f0.deinit(allocator);

            var f1 = try FrameType.init(allocator);
            errdefer f1.deinit(allocator);

            var f2 = try FrameType.init(allocator);
            errdefer f2.deinit(allocator);

            return .{
                .frames = [_]FrameType{ f0, f1, f2 },
                .fill_idx = 0,
                .read_idx = 1,
                // Initial ready slot is buffer 2, has_new = 0
                .shared_state = std.atomic.Value(u32).init(2),
            };
        }

        /// Releases all pre-allocated frame memory.
        pub fn deinit(self: *Self, allocator: Allocator) void {
            for (&self.frames) |*f| {
                f.deinit(allocator);
            }
        }

        /// Returns mutable pointer to the frame currently owned by the producer.
        pub inline fn getFillFrame(self: *Self) *FrameType {
            return &self.frames[self.fill_idx];
        }

        /// Atomically publishes the current fill_idx as the new ready frame.
        /// Reclaims the previously ready buffer as the next fill buffer.
        /// Wait-free: executes in a single atomic swap instruction.
        pub fn publish(self: *Self) void {
            const new_ready = self.fill_idx;
            // Pack: ready_idx = new_ready, has_new = 1 (bit 2 set)
            const state_word: u32 = (@as(u32, new_ready) & 0x3) | (1 << 2);
            const prev = self.shared_state.swap(state_word, .release);
            // The previously ready index becomes our next fill buffer
            self.fill_idx = @intCast(prev & 0x3);
        }

        /// Returns true if a fresh frame has been published since the last acquire.
        pub inline fn hasNew(self: *const Self) bool {
            return (self.shared_state.load(.monotonic) & (1 << 2)) != 0;
        }

        /// Atomically acquires the freshest published frame if available.
        /// Returns a const pointer to the frame owned by the consumer.
        /// Returns null if no new frame has been published since the last acquire.
        pub fn acquireLatest(self: *Self) ?*const FrameType {
            var cur = self.shared_state.load(.acquire);
            while (true) {
                // If has_new flag (bit 2) is not set, no new frame has been published
                if ((cur & (1 << 2)) == 0) return null;

                const ready_idx = cur & 0x3;
                // Next state: ready_idx becomes our old read_idx, has_new is cleared (0)
                const next_state: u32 = @as(u32, self.read_idx) & 0x3;

                if (self.shared_state.cmpxchgWeak(cur, next_state, .acquire, .monotonic)) |stale| {
                    cur = stale;
                } else {
                    self.read_idx = @intCast(ready_idx);
                    return &self.frames[self.read_idx];
                }
            }
        }

        /// Returns the currently acquired read frame without checking for updates.
        pub inline fn getCurrentFrame(self: *const Self) *const FrameType {
            return &self.frames[self.read_idx];
        }
    };
}

pub const TripleBuffer = Buffer;

test "TripleBuffer: initialization and distinct buffer ownership" {
    const testing = std.testing;
    const test_option = @import("../term/test_fixtures.zig").test_option;
    const TB = TripleBuffer(test_option);

    var tb = try TB.init(testing.allocator);
    defer tb.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), tb.fill_idx);
    try testing.expectEqual(@as(u8, 1), tb.read_idx);
    try testing.expectEqual(false, tb.hasNew());
    try testing.expectEqual(@as(?*const Frame(test_option), null), tb.acquireLatest());
}

test "TripleBuffer: publish and acquire latest frame" {
    const testing = std.testing;
    const test_option = @import("../term/test_fixtures.zig").test_option;
    const TB = TripleBuffer(test_option);

    var tb = try TB.init(testing.allocator);
    defer tb.deinit(testing.allocator);

    // Producer writes to fill frame
    var fill = tb.getFillFrame();
    fill.generation = 42;
    fill.cells[0].codepoint = 'A';
    tb.publish();

    try testing.expect(tb.hasNew());

    // Consumer acquires latest
    const frame = tb.acquireLatest();
    try testing.expect(frame != null);
    try testing.expectEqual(@as(u32, 42), frame.?.generation);
    try testing.expectEqual('A', frame.?.cells[0].codepoint);

    // Subsequent acquire without new publish returns null
    try testing.expect(!tb.hasNew());
    try testing.expectEqual(@as(?*const Frame(test_option), null), tb.acquireLatest());
    // But getCurrentFrame returns the existing acquired frame
    try testing.expectEqual(@as(u32, 42), tb.getCurrentFrame().generation);
}

test "TripleBuffer: overwrite drops intermediate frame without corruption" {
    const testing = std.testing;
    const test_option = @import("../term/test_fixtures.zig").test_option;
    const TB = TripleBuffer(test_option);

    var tb = try TB.init(testing.allocator);
    defer tb.deinit(testing.allocator);

    // Publish frame 1
    tb.getFillFrame().generation = 1;
    tb.publish();

    // Publish frame 2 before consumer reads frame 1
    tb.getFillFrame().generation = 2;
    tb.publish();

    // Consumer should get frame 2 directly
    const frame = tb.acquireLatest();
    try testing.expect(frame != null);
    try testing.expectEqual(@as(u32, 2), frame.?.generation);
}

test "TripleBuffer: multi-threaded producer consumer stress test" {
    const testing = std.testing;
    const test_option = @import("../term/test_fixtures.zig").test_option;
    const TB = TripleBuffer(test_option);

    var tb = try TB.init(testing.allocator);
    defer tb.deinit(testing.allocator);

    const iterations = 50_000;

    const Context = struct {
        tb: *TB,
        done: std.atomic.Value(bool),
        read_count: usize,
        last_seen_gen: u32,

        fn producer(ctx: *@This()) void {
            var i: u32 = 1;
            while (i <= iterations) : (i += 1) {
                const fill = ctx.tb.getFillFrame();
                fill.generation = i;
                fill.cells[0].codepoint = @intCast('0' + (i % 10));
                ctx.tb.publish();
            }
            ctx.done.store(true, .release);
        }

        fn consumer(ctx: *@This()) void {
            while (!ctx.done.load(.acquire) or ctx.tb.hasNew()) {
                if (ctx.tb.acquireLatest()) |f| {
                    ctx.read_count += 1;
                    // Generation must be strictly monotonic
                    std.debug.assert(f.generation >= ctx.last_seen_gen);
                    // Cell codepoint must match generation
                    std.debug.assert(f.cells[0].codepoint == @as(u21, @intCast('0' + (f.generation % 10))));
                    ctx.last_seen_gen = f.generation;
                }
            }
        }
    };

    var ctx = Context{
        .tb = &tb,
        .done = std.atomic.Value(bool).init(false),
        .read_count = 0,
        .last_seen_gen = 0,
    };

    const prod_thread = try std.Thread.spawn(.{}, Context.producer, .{&ctx});
    const cons_thread = try std.Thread.spawn(.{}, Context.consumer, .{&ctx});

    prod_thread.join();
    cons_thread.join();

    try testing.expect(ctx.read_count > 0);
    try testing.expect(ctx.last_seen_gen == iterations);
}
