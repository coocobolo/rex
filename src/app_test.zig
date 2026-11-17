//! App-level state machines and pointer-shape resolution. These types are
//! pure, so the tests need no window or GL context.

const std = @import("std");

const App = @import("App.zig");
const Window = @import("platform/Window.zig");
const Blur = @import("renderer/root.zig").Blur;

const PointerVisibility = App.PointerVisibility;
const resolvePointerShape = App.resolvePointerShape;

test "PointerVisibility: typing while unfocused or in a modal does not hide" {
    const typing_only: PointerVisibility.Rules = .{ .mode = .on_typing, .timeout_ms = null };
    var vis: PointerVisibility = .{ .visible = .{} };
    try std.testing.expect(!vis.onTyping(typing_only, .{ .focused = false, .modal_active = false }));
    try std.testing.expect(!vis.onTyping(typing_only, .{ .focused = true, .modal_active = true }));
    try std.testing.expect(vis.isVisible());
}

test "PointerVisibility: typing auto-hide, idle timeout, and modal/focus restore" {
    const testing = std.testing;
    const Rules = PointerVisibility.Rules;
    const State = PointerVisibility.State;

    const typing_idle: Rules = .{ .mode = .on_typing, .timeout_ms = 3000 };
    const typing_only: Rules = .{ .mode = .on_typing };
    const never_off: Rules = .{ .mode = .never };

    const active: State = .{ .focused = true, .modal_active = false };
    const unfocused: State = .{ .focused = false, .modal_active = false };
    const modal: State = .{ .focused = true, .modal_active = true };

    var vis: PointerVisibility = .{ .visible = .{} };
    try testing.expect(vis.isVisible());
    try testing.expectEqual(@as(usize, 16), @sizeOf(PointerVisibility));
    try testing.expectEqual(@as(usize, 56), @sizeOf(Blur.SceneKey));
    try testing.expectEqual(@as(usize, 8), @sizeOf(Window));

    // `never` keeps the pointer visible when typing.
    try testing.expect(!vis.onTyping(never_off, active));
    try testing.expect(vis.isVisible());

    // `on_typing` hides a visible pointer once, and is a no-op while hidden.
    try testing.expect(vis.onTyping(typing_idle, active));
    try testing.expect(!vis.isVisible());
    try testing.expect(!vis.onTyping(typing_idle, active));
    try testing.expectEqual(std.math.maxInt(u64), vis.wakeMs(typing_idle, active));

    // Moving or clicking restores visibility and resets idle time.
    try testing.expect(vis.show());
    try testing.expect(vis.isVisible());
    try testing.expect(!vis.show());

    // Idle timeout accumulates only while focused without a modal overlay.
    try testing.expectEqual(@as(u64, 3000), vis.wakeMs(typing_idle, active));
    try testing.expect(!vis.tick(1200, typing_idle, active));
    try testing.expect(vis.isVisible());
    try testing.expectEqual(@as(u64, 1800), vis.wakeMs(typing_idle, active));

    // Reaching the idle timeout hides the pointer.
    try testing.expect(vis.tick(1800, typing_idle, active));
    try testing.expect(!vis.isVisible());

    // Losing focus or opening a modal unhides a hidden pointer.
    try testing.expect(vis.tick(0, typing_idle, unfocused));
    try testing.expect(vis.isVisible());
    try testing.expect(vis.onTyping(typing_idle, active));
    try testing.expect(vis.tick(0, typing_only, modal));
    try testing.expect(vis.isVisible());

    // Disabling both `mouse_auto_hide` and `mouse_idle_timeout` unhides a hidden pointer.
    try testing.expect(vis.onTyping(typing_only, active));
    try testing.expect(vis.tick(0, never_off, active));
    try testing.expect(vis.isVisible());
}

test "resolvePointerShape: kit overlays, modals, scrollbar, and mouse reporting" {
    const testing = std.testing;
    try testing.expectEqual(Window.PointerShape.hand, resolvePointerShape(.hand, false, false, false, false));
    try testing.expectEqual(Window.PointerShape.arrow, resolvePointerShape(.arrow, false, false, false, false));
    try testing.expectEqual(Window.PointerShape.text, resolvePointerShape(.text, true, true, true, false));
    try testing.expectEqual(Window.PointerShape.arrow, resolvePointerShape(null, true, false, false, false));
    try testing.expectEqual(Window.PointerShape.arrow, resolvePointerShape(null, false, true, false, false));
    try testing.expectEqual(Window.PointerShape.arrow, resolvePointerShape(null, false, false, true, false));
    try testing.expectEqual(Window.PointerShape.text, resolvePointerShape(null, false, false, true, true));
    try testing.expectEqual(Window.PointerShape.text, resolvePointerShape(null, false, false, false, false));
}
