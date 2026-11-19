//! Tests for the platform event types and bounded ring.

const std = @import("std");
const testing = std.testing;

const events = @import("Event.zig");
const Event = events.Event;
const Ring = events.Ring;
const Window = @import("Window.zig");

fn window() Window {
    return .{ .impl = @ptrFromInt(0x1000) };
}

fn text(codepoint: u21) Event {
    return .{ .text = .{ .window = window(), .codepoint = codepoint } };
}

fn next(ring: *Ring) ?Event {
    var event: Event = undefined;
    return if (ring.next(&event)) event else null;
}

test "Ring: events come back in push order" {
    var ring: Ring = .{};
    try testing.expectEqual(@as(usize, 0), ring.count());
    try testing.expect(next(&ring) == null);

    ring.push(text('a'));
    ring.push(text('b'));
    ring.push(text('c'));
    try testing.expectEqual(@as(usize, 3), ring.count());

    try testing.expectEqual(@as(u21, 'a'), (next(&ring).?.text).codepoint);
    try testing.expectEqual(@as(u21, 'b'), (next(&ring).?.text).codepoint);
    try testing.expectEqual(@as(u21, 'c'), (next(&ring).?.text).codepoint);
    try testing.expect(next(&ring) == null);
    try testing.expectEqual(@as(usize, 0), ring.count());
}

test "Ring: wraps around at capacity" {
    var ring: Ring = .{};
    var i: usize = 0;
    while (i < events.capacity) : (i += 1) ring.push(text(@intCast(i)));
    try testing.expectEqual(events.capacity, ring.count());

    var drained: usize = 0;
    while (next(&ring)) |event| : (drained += 1) {
        try testing.expectEqual(@as(u21, @intCast(drained)), event.text.codepoint);
    }
    try testing.expectEqual(events.capacity, drained);

    // Reuse after a full drain must not lose slots.
    ring.push(text('z'));
    try testing.expectEqual(@as(u21, 'z'), next(&ring).?.text.codepoint);
}

test "Ring: a full ring drops the newest event and counts it" {
    var ring: Ring = .{};
    var i: usize = 0;
    while (i < events.capacity) : (i += 1) ring.push(text(@intCast(i)));

    ring.push(text('X'));
    try testing.expectEqual(@as(u32, 1), ring.takeDropped());
    try testing.expectEqual(@as(u32, 0), ring.takeDropped());

    // The oldest events are still intact; the dropped one never got a slot.
    try testing.expectEqual(@as(u21, 0), next(&ring).?.text.codepoint);
    var last: u21 = 0;
    while (next(&ring)) |event| last = event.text.codepoint;
    try testing.expectEqual(@as(u21, @intCast(events.capacity - 1)), last);
}

test "Ring: an empty ring reports no drops" {
    var ring: Ring = .{};
    try testing.expectEqual(@as(u32, 0), ring.takeDropped());
}

test "layout: the event structs keep their measured sizes and offsets" {
    // Measured on 2026-11-17; a change here must be deliberate and reported.
    try testing.expectEqual(@as(usize, 56), @sizeOf(Event));
    try testing.expectEqual(@as(usize, 8), @alignOf(Event));
    try testing.expectEqual(@as(usize, 48), @sizeOf(events.PreeditEvent));
    try testing.expectEqual(@as(usize, 14_344), @sizeOf(Ring));
    try testing.expectEqual(@as(usize, 8), @sizeOf(Window));

    try testing.expectEqual(@as(usize, 8), @offsetOf(events.PreeditEvent, "text"));
    try testing.expectEqual(@as(usize, 40), @offsetOf(events.PreeditEvent, "len"));
    try testing.expectEqual(@as(usize, 14_336), @offsetOf(Ring, "dropped"));
    try testing.expectEqual(@as(usize, 14_340), @offsetOf(Ring, "read"));
    try testing.expectEqual(@as(usize, 14_342), @offsetOf(Ring, "len"));
}
