//! Tests for text-input staging and fractional-scale conversion.

const std = @import("std");
const testing = std.testing;

const events = @import("../Event.zig");
const backend = @import("backend.zig");
const text_input = @import("text_input.zig");
const WaylandWindow = @import("WaylandWindow.zig");

test "Wayland text-input-v3: preedit and commit double-buffer until done, oversized preedit dropped whole" {
    var dummy_win: WaylandWindow = .{};
    var ti: text_input.TextInput = .{ .focus = &dummy_win };

    // Stage preedit + commit; nothing emitted before done.
    ti.stageCommit("hi日");
    ti.stagePreedit("かな", 3, 6);
    var ev: events.Event = undefined;
    try testing.expect(!backend.nextEvent(&ev));

    ti.applyDone();
    try testing.expect(backend.nextEvent(&ev));
    try testing.expectEqual(@as(u21, 'h'), ev.text.codepoint);
    try testing.expect(backend.nextEvent(&ev));
    try testing.expectEqual(@as(u21, 'i'), ev.text.codepoint);
    try testing.expect(backend.nextEvent(&ev));
    try testing.expectEqual(@as(u21, 0x65E5), ev.text.codepoint); // '日'
    try testing.expect(backend.nextEvent(&ev));
    try testing.expectEqualStrings("かな", ev.preedit.text[0..ev.preedit.len]);
    try testing.expectEqual(@as(u8, 3), ev.preedit.cursor);
    try testing.expectEqual(@as(u8, 6), ev.preedit.selection);

    // Oversized preedit (> 32 bytes) must be dropped whole, never truncated.
    ti.stagePreedit("012345678901234567890123456789012", 0, 33);
    ti.applyDone();
    try testing.expect(!backend.nextEvent(&ev));

    // Focus leave clears active preedit.
    ti.clearPreeditOnLeave();
    try testing.expect(backend.nextEvent(&ev));
    try testing.expectEqual(@as(u8, 0), ev.preedit.len);
}

test "Wayland fractional scale: 1/120th scale conversion and pixel rounding" {
    try testing.expectApproxEqAbs(@as(f32, 1.0), WaylandWindow.scaleFrom120(0), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1.0), WaylandWindow.scaleFrom120(120), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1.25), WaylandWindow.scaleFrom120(150), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1.5), WaylandWindow.scaleFrom120(180), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 2.0), WaylandWindow.scaleFrom120(240), 1e-6);

    const win: WaylandWindow = .{
        .logical_width = 800,
        .logical_height = 600,
        .scale = 1.25,
    };
    try testing.expectEqual(@as(u32, 1000), win.pixelWidth());
    try testing.expectEqual(@as(u32, 750), win.pixelHeight());
}
