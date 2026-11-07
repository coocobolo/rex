const std = @import("std");
const testing = std.testing;
const latency_trace = @import("latency_trace.zig");
const Trace = latency_trace.Trace;
const Worker = latency_trace.Worker;
const Stage = latency_trace.Stage;

fn at(trace: *const Trace, seq: u32, stage: Stage) u64 {
    return trace.records[seq % latency_trace.capacity].t[@intFromEnum(stage)];
}

/// Runs one key through every stage, `base` + 1..8.
fn traceKey(trace: *Trace, worker: *Worker, base: u64) u32 {
    trace.keyPressed(base + 1);
    const seq = trace.beginSend(base + 99);
    trace.stamp(seq, .queued, base + 2);
    trace.eventsHandled();
    worker.inputHandled(trace);
    worker.flushed(trace, true, base + 3);
    worker.read(trace, base + 4);
    worker.framePublished(trace, base + 5);
    trace.framePicked(worker.echoed, base + 6);
    const drawn = trace.frameDrawn(base + 7);
    trace.stamp(drawn, .swapped, base + 8);
    return seq;
}

test "a key passes every stage in order" {
    const trace = try Trace.create(testing.allocator);
    defer trace.destroy(testing.allocator);
    var worker: Worker = .{};

    const seq = traceKey(trace, &worker, 100);
    try testing.expectEqual(@as(u32, 1), seq);
    for (std.enums.values(Stage), 1..) |stage, offset| {
        try testing.expectEqual(100 + offset, at(trace, seq, stage));
    }
}

test "text without a key press is stamped when it is sent" {
    const trace = try Trace.create(testing.allocator);
    defer trace.destroy(testing.allocator);

    // A press that sent nothing must not lend its time to later text.
    trace.keyPressed(5);
    trace.eventsHandled();
    const seq = trace.beginSend(42);
    try testing.expectEqual(@as(u64, 42), at(trace, seq, .key));
}

test "a key written before the previous echo leaves that one unmatched" {
    const trace = try Trace.create(testing.allocator);
    defer trace.destroy(testing.allocator);
    var worker: Worker = .{};

    const first = trace.beginSend(1);
    worker.inputHandled(trace);
    worker.flushed(trace, true, 2);

    const second = trace.beginSend(3);
    worker.inputHandled(trace);
    worker.flushed(trace, true, 4);
    worker.read(trace, 5);

    try testing.expectEqual(@as(u64, 2), at(trace, first, .written));
    try testing.expectEqual(@as(u64, 0), at(trace, first, .echoed));
    try testing.expectEqual(@as(u64, 5), at(trace, second, .echoed));
}

test "written waits until every byte reached the pty" {
    const trace = try Trace.create(testing.allocator);
    defer trace.destroy(testing.allocator);
    var worker: Worker = .{};

    const seq = trace.beginSend(1);
    worker.inputHandled(trace);
    worker.flushed(trace, false, 2);
    // Output read before the write finished isn't the echo.
    worker.read(trace, 3);
    worker.flushed(trace, true, 4);
    worker.read(trace, 5);

    try testing.expectEqual(@as(u64, 4), at(trace, seq, .written));
    try testing.expectEqual(@as(u64, 5), at(trace, seq, .echoed));
}

test "later frames and draws don't restamp a key" {
    const trace = try Trace.create(testing.allocator);
    defer trace.destroy(testing.allocator);
    var worker: Worker = .{};

    const seq = traceKey(trace, &worker, 0);
    worker.framePublished(trace, 50);
    trace.framePicked(worker.echoed, 60);
    try testing.expectEqual(@as(u32, 0), trace.frameDrawn(70));

    try testing.expectEqual(@as(u64, 5), at(trace, seq, .published));
    try testing.expectEqual(@as(u64, 6), at(trace, seq, .picked));
    try testing.expectEqual(@as(u64, 7), at(trace, seq, .drawn));
}

test "frames without a traced echo stamp nothing" {
    const trace = try Trace.create(testing.allocator);
    defer trace.destroy(testing.allocator);
    var worker: Worker = .{};

    worker.read(trace, 1);
    worker.framePublished(trace, 2);
    trace.framePicked(0, 3);
    try testing.expectEqual(@as(u32, 0), trace.frameDrawn(4));
}

test "CSV has a header and one line per key, oldest first after wrapping" {
    const trace = try Trace.create(testing.allocator);
    defer trace.destroy(testing.allocator);
    var worker: Worker = .{};

    _ = traceKey(trace, &worker, 0);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try trace.writeCsv(&out.writer);
    try testing.expectEqualStrings(
        "seq,key,queued,written,echoed,published,picked,drawn,swapped\n" ++
            "1,1,2,3,4,5,6,7,8\n",
        out.written(),
    );

    // Wrap the table: the oldest kept key is capacity keys back.
    var i: usize = 1;
    while (i < latency_trace.capacity + 2) : (i += 1) _ = traceKey(trace, &worker, 0);
    out.clearRetainingCapacity();
    try trace.writeCsv(&out.writer);
    var lines = std.mem.splitScalar(u8, out.written(), '\n');
    _ = lines.next(); // header
    const oldest = latency_trace.capacity + 2 - latency_trace.capacity + 1;
    var prefix_buf: [16]u8 = undefined;
    const prefix = try std.fmt.bufPrint(&prefix_buf, "{d},", .{oldest});
    try testing.expect(std.mem.startsWith(u8, lines.next().?, prefix));
}
