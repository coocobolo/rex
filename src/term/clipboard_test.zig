const std = @import("std");
const testing = std.testing;

const Clipboard = @import("Clipboard.zig");

/// Runs one OSC 52 body (the bytes after `52;`) through `cb`, fed whole and
/// then one byte at a time, and checks both give the same request.
fn run(cb: *Clipboard, body: []const u8) !struct { bool, Clipboard.Request, []const u8 } {
    cb.begin();
    cb.put(body);
    const whole_made = cb.end();
    const whole_request, const whole_data = cb.take();
    var whole_copy: [64]u8 = undefined;
    @memcpy(whole_copy[0..whole_data.len], whole_data);

    cb.begin();
    for (body) |b| cb.put(&.{b});
    const made = cb.end();
    const request, const data = cb.take();
    try testing.expectEqual(whole_made, made);
    try testing.expectEqual(whole_request, request);
    try testing.expectEqualStrings(whole_copy[0..whole_data.len], data);
    return .{ made, request, data };
}

test "Clipboard: decodes a write whatever the split" {
    var cb: Clipboard = try .init(testing.allocator, 64);
    defer cb.deinit(testing.allocator);

    for ([_]struct { []const u8, []const u8 }{
        .{ "c;aGVsbG8=", "hello" },
        .{ "c;aGVsbG8", "hello" }, // unpadded tail of 3
        .{ "c;aGk=", "hi" },
        .{ "c;aGk", "hi" }, // unpadded tail of 2
        .{ "c;aGVsbG8gd29ybGQh", "hello world!" }, // whole groups only
        .{ "c;", "" }, // empty data
    }) |case| {
        errdefer std.debug.print("body {s}\n", .{case[0]});
        const made, const request, const data = try run(&cb, case[0]);
        try testing.expect(made);
        try testing.expectEqual(Clipboard.Targets{ .clipboard = true }, request.write);
        try testing.expectEqualStrings(case[1], data);
    }
}

test "Clipboard: targets c, s and empty mean the clipboard, p primary, the rest nothing" {
    var cb: Clipboard = try .init(testing.allocator, 64);
    defer cb.deinit(testing.allocator);

    for ([_]struct { []const u8, Clipboard.Targets }{
        .{ "c;aGk=", .{ .clipboard = true } },
        .{ "s;aGk=", .{ .clipboard = true } },
        .{ ";aGk=", .{ .clipboard = true } },
        .{ "p;aGk=", .{ .primary = true } },
        .{ "cp;aGk=", .{ .clipboard = true, .primary = true } },
        .{ "s0;aGk=", .{ .clipboard = true } },
    }) |case| {
        errdefer std.debug.print("body {s}\n", .{case[0]});
        const made, const request, _ = try run(&cb, case[0]);
        try testing.expect(made);
        try testing.expectEqual(case[1], request.write);
    }
    // Only secondary or cut buffers: nothing Rex writes to.
    const made, const request, _ = try run(&cb, "q7;aGk=");
    try testing.expect(!made);
    try testing.expectEqual(Clipboard.Request.none, request);
}

test "Clipboard: data that is neither base64 nor ? clears" {
    var cb: Clipboard = try .init(testing.allocator, 64);
    defer cb.deinit(testing.allocator);

    for ([_][]const u8{
        "c;not base64!",
        "c;aGk=aGk=", // padding before the end
        "c;a", // one character left over
        "c;a=Gk", // padding inside a group
        "c;??", // more than ?
        "c;?aGk=",
    }) |body| {
        errdefer std.debug.print("body {s}\n", .{body});
        const made, const request, const data = try run(&cb, body);
        try testing.expect(made);
        try testing.expect(request == .write);
        try testing.expectEqualStrings("", data);
    }
}

test "Clipboard: ? asks for the selection" {
    var cb: Clipboard = try .init(testing.allocator, 64);
    defer cb.deinit(testing.allocator);

    const made, const request, _ = try run(&cb, "c;?");
    try testing.expect(made);
    try testing.expectEqual(Clipboard.Request{ .read = .{ .clipboard = true } }, request);
}

test "Clipboard: a write too big is dropped whole and counted" {
    var cb: Clipboard = try .init(testing.allocator, 4);
    defer cb.deinit(testing.allocator);

    // "hello" is 5 bytes, one more than the buffer, padded and unpadded.
    for ([_][]const u8{ "c;aGVsbG8=", "c;aGVsbG8" }) |body| {
        const dropped = cb.dropped;
        cb.begin();
        cb.put(body);
        try testing.expect(!cb.end());
        try testing.expectEqual(Clipboard.Request.none, cb.take()[0]);
        try testing.expectEqual(dropped + 1, cb.dropped);
    }
    // Exactly the buffer's size fits.
    const made, _, const data = try run(&cb, "c;aGVsbA==");
    try testing.expect(made);
    try testing.expectEqualStrings("hell", data);
}

test "Clipboard: no Pd, no request; a new sequence replaces a pending one" {
    var cb: Clipboard = try .init(testing.allocator, 64);
    defer cb.deinit(testing.allocator);

    cb.begin();
    cb.put("c");
    try testing.expect(!cb.end());

    cb.begin();
    cb.put("c;aGk=");
    try testing.expect(cb.end());
    cb.begin(); // not taken: replaced
    cb.put("c;?");
    try testing.expect(cb.end());
    try testing.expectEqual(Clipboard.Request{ .read = .{ .clipboard = true } }, cb.take()[0]);
    try testing.expectEqual(Clipboard.Request.none, cb.take()[0]);
}

/// Feeds `body` (the bytes after `52;`) split at `split`, or one byte at a
/// time when `split` is null, and ends the sequence.
fn feedSplit(cb: *Clipboard, body: []const u8, split: ?usize) bool {
    cb.begin();
    if (split) |k| {
        cb.put(body[0..k]);
        cb.put(body[k..]);
    } else for (body) |b| cb.put(&.{b});
    return cb.end();
}

test "Clipboard: every length, both paddings and every split decode to the original bytes" {
    const max = 256;
    var cb: Clipboard = try .init(testing.allocator, max);
    defer cb.deinit(testing.allocator);
    var prng: std.Random.DefaultPrng = .init(0x52);

    var data: [max + 1]u8 = undefined;
    var body_buf: [2 + std.base64.standard.Encoder.calcSize(max + 1)]u8 = undefined;
    body_buf[0] = 'c';
    body_buf[1] = ';';

    // Short lengths cover every carry and padding state; the last ones
    // cross the limit, and length 256 of the first pattern holds every
    // byte value.
    const lengths = [_][2]usize{ .{ 0, 70 }, .{ max - 6, max + 1 } };
    for (lengths) |range| for (range[0]..range[1] + 1) |len| {
        for (0..2) |pattern| {
            for (data[0..len], 0..) |*b, i| b.* = if (pattern == 0) @truncate(i + len * 7) else prng.random().int(u8);
            const codecs = [_]std.base64.Codecs{ std.base64.standard, std.base64.standard_no_pad };
            for (codecs) |codec| {
                const encoded = codec.Encoder.encode(body_buf[2..], data[0..len]);
                const body = body_buf[0 .. 2 + encoded.len];
                var split: usize = 0;
                while (split <= body.len + 1) : (split += 1) {
                    // body.len + 1 stands for one byte at a time.
                    const at: ?usize = if (split <= body.len) split else null;
                    errdefer std.debug.print("len {d} pattern {d} split {?d} body {s}\n", .{ len, pattern, at, body });
                    const dropped = cb.dropped;
                    const made = feedSplit(&cb, body, at);
                    const request, const decoded = cb.take();
                    if (len <= max) {
                        try testing.expect(made);
                        try testing.expectEqual(Clipboard.Request{ .write = .{ .clipboard = true } }, request);
                        try testing.expectEqualSlices(u8, data[0..len], decoded);
                    } else {
                        try testing.expect(!made);
                        try testing.expectEqual(Clipboard.Request.none, request);
                        try testing.expectEqual(dropped + 1, cb.dropped);
                    }
                }
            }
        }
    };
}
