const std = @import("std");
const testing = std.testing;

const OutboundQueue = @import("OutboundQueue.zig");
const paste = @import("paste.zig");

/// Queues `text` as a bracketed paste and returns what would reach the child.
fn bracketed(queue: *OutboundQueue, text: []const u8) ![]const u8 {
    try paste.queueBracketed(queue, testing.allocator, text);
    return queue.buf.items[queue.head..];
}

fn expectPaste(expected_text: []const u8, text: []const u8) !void {
    var queue: OutboundQueue = .init(1024);
    defer queue.deinit(testing.allocator);

    const queued = try bracketed(&queue, text);
    try testing.expectEqualStrings(paste.start, queued[0..paste.start.len]);
    try testing.expectEqualStrings(paste.end, queued[queued.len - paste.end.len ..]);
    try testing.expectEqualStrings(expected_text, queued[paste.start.len .. queued.len - paste.end.len]);
}

test "paste: text without ESC is wrapped unchanged" {
    try expectPaste("", "");
    try expectPaste("echo hi\nls -l\n", "echo hi\nls -l\n");
}

test "paste: an end marker in the text can't end the paste" {
    try expectPaste("ls[201~rm -rf ~\n", "ls\x1b[201~rm -rf ~\n");
}

test "paste: removing an inner marker doesn't form a new one" {
    // Removing only the inner `ESC[201~` would leave `ESC[201~` behind.
    try expectPaste("[20[201~1~", "\x1b[20\x1b[201~1~");
}

test "paste: every ESC is removed, wherever it is" {
    try expectPaste("", "\x1b");
    try expectPaste("", "\x1b\x1b\x1b");
    try expectPaste("[31mred[0m", "\x1b[31mred\x1b[0m");
    try expectPaste("ab", "\x1ba\x1bb\x1b");
}

test "paste: multi-byte UTF-8 survives, including 0x9B continuation bytes" {
    // U+011B is C4 9B: byte 0x9B is part of the character here, not a
    // C1 CSI, and must be kept.
    try expectPaste("\u{011B}\u{221E}x", "\u{011B}\x1b\u{221E}x");
}

test "paste: a paste over the limit is refused whole" {
    var queue: OutboundQueue = .init(16);
    defer queue.deinit(testing.allocator);

    try queue.append(testing.allocator, &.{"ab"});
    // 12 bytes of markers + 3 of text + 2 pending > 16.
    try testing.expectError(error.QueueFull, paste.queueBracketed(&queue, testing.allocator, "xyz"));
    try testing.expectEqualStrings("ab", queue.buf.items[queue.head..]);

    // Exactly at the limit.
    _ = try bracketed(&queue, "xy");
    try testing.expectEqual(16, queue.pending());
}
