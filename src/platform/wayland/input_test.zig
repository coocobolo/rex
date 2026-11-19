const std = @import("std");
const testing = std.testing;

const c_xkb = @import("xkbcommon");
const Key = @import("../../input/key.zig").Key;
const events = @import("../Event.zig");
const backend = @import("backend.zig");
const key = @import("key.zig");
const proto = @import("proto.zig");
const seat = @import("seat.zig");
const WaylandWindow = @import("WaylandWindow.zig");

test "Wayland key translation: keysyms, mouse buttons, cursor shapes, fixed-point and scroll" {
    try testing.expectEqual(@as(?Key, .escape), key.fromKeysym(c_xkb.XKB_KEY_Escape));
    try testing.expectEqual(@as(?Key, .enter), key.fromKeysym(c_xkb.XKB_KEY_Return));
    try testing.expectEqual(@as(?Key, .tab), key.fromKeysym(c_xkb.XKB_KEY_ISO_Left_Tab));
    try testing.expectEqual(@as(?Key, .a), key.fromKeysym('a'));
    try testing.expectEqual(@as(?Key, .z), key.fromKeysym('Z'));
    try testing.expectEqual(@as(?Key, .num_0), key.fromKeysym('0'));
    try testing.expectEqual(@as(?Key, .num_9), key.fromKeysym('9'));
    try testing.expectEqual(@as(?Key, .f12), key.fromKeysym(c_xkb.XKB_KEY_F12));
    try testing.expectEqual(@as(?Key, .left_control), key.fromKeysym(c_xkb.XKB_KEY_Control_L));
    try testing.expectEqual(@as(?Key, null), key.fromKeysym(0));

    try testing.expectEqual(@as(?events.MouseButton, .left), key.mouseButton(key.btn_left));
    try testing.expectEqual(@as(?events.MouseButton, .right), key.mouseButton(key.btn_right));
    try testing.expectEqual(@as(?events.MouseButton, .middle), key.mouseButton(key.btn_middle));
    try testing.expectEqual(@as(?events.MouseButton, null), key.mouseButton(0x113));

    try testing.expectEqual(proto.cursor_shape_device.shape_default, key.cursorShape(.arrow));
    try testing.expectEqual(proto.cursor_shape_device.shape_pointer, key.cursorShape(.hand));
    try testing.expectEqual(proto.cursor_shape_device.shape_text, key.cursorShape(.text));

    try testing.expectApproxEqAbs(@as(f64, 12.5), key.fixedToF64(12 * 256 + 128), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, -1.0), key.verticalScroll(10.0), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 1.0), key.verticalScroll(-10.0), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 1.0), key.horizontalScroll(10.0), 1e-9);
}

test "Wayland seat repeat timer emits Action.repeat and respects delay/stop" {
    var dummy_win: WaylandWindow = .{};
    var s: seat.Seat = .{
        .kb_focus = &dummy_win,
        .repeat_rate_hz = 20, // 50 ms period
        .repeat_delay_ms = 200,
    };

    const t0: i64 = 1_000_000_000;
    try testing.expectEqual(@as(?f64, null), s.repeatTimeoutMs(t0));

    s.startRepeat(38, .a, 'a', t0);
    try testing.expectApproxEqAbs(@as(f64, 200.0), s.repeatTimeoutMs(t0).?, 1e-6);

    // Before delay expires: nothing emitted.
    s.tickRepeat(t0 + 100 * std.time.ns_per_ms);
    var ev: events.Event = undefined;
    try testing.expect(!backend.nextEvent(&ev));

    // At delay: emits repeat key + text event and schedules next tick +50ms.
    const t1 = t0 + 200 * std.time.ns_per_ms;
    s.tickRepeat(t1);
    try testing.expect(backend.nextEvent(&ev));
    try testing.expectEqual(events.Action.repeat, ev.key.action);
    try testing.expectEqual(Key.a, ev.key.key);
    try testing.expect(backend.nextEvent(&ev));
    try testing.expectEqual(@as(u21, 'a'), ev.text.codepoint);
    try testing.expectApproxEqAbs(@as(f64, 50.0), s.repeatTimeoutMs(t1).?, 1e-6);

    // Stopping on key release clears repeat timeout.
    s.stopRepeat(38);
    try testing.expectEqual(@as(?f64, null), s.repeatTimeoutMs(t1));
}
