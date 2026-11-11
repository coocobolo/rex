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
