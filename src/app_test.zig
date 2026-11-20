//! App-level state machines and pointer-shape resolution. These types are
//! pure, so the tests need no window or GL context.

const std = @import("std");

const App = @import("App.zig");
const Config = @import("config/Config.zig");
const config = @import("config/root.zig");
const config_default = @import("config/default.zig").default;
const Window = @import("platform/Window.zig");
const Blur = @import("renderer/root.zig").Blur;
const Cursor = @import("renderer/Cursor.zig");

const PeriodicTimer = App.PeriodicTimer;
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

test "resolvePointerShape: kit overlays, modals, scrollbar, links and mouse reporting" {
    const testing = std.testing;
    try testing.expectEqual(Window.PointerShape.hand, resolvePointerShape(.hand, false, false, false, false, false));
    try testing.expectEqual(Window.PointerShape.arrow, resolvePointerShape(.arrow, false, false, false, false, false));
    try testing.expectEqual(Window.PointerShape.text, resolvePointerShape(.text, true, true, true, false, false));
    try testing.expectEqual(Window.PointerShape.arrow, resolvePointerShape(null, true, false, false, false, false));
    try testing.expectEqual(Window.PointerShape.arrow, resolvePointerShape(null, false, true, false, false, false));
    try testing.expectEqual(Window.PointerShape.arrow, resolvePointerShape(null, false, false, true, false, false));
    try testing.expectEqual(Window.PointerShape.text, resolvePointerShape(null, false, false, true, true, false));
    try testing.expectEqual(Window.PointerShape.text, resolvePointerShape(null, false, false, false, false, false));
    // A link keeps the hand over mouse reporting, but not over a modal or scrollbar.
    try testing.expectEqual(Window.PointerShape.hand, resolvePointerShape(null, false, false, true, false, true));
    try testing.expectEqual(Window.PointerShape.arrow, resolvePointerShape(null, true, false, false, false, true));
    try testing.expectEqual(Window.PointerShape.arrow, resolvePointerShape(null, false, true, false, false, true));
}

test "PeriodicTimer.setPeriod: shrinking period clamps elapsed_ms without underflow" {
    const testing = std.testing;
    var timer: PeriodicTimer = .{ .period_ms = 1000 };
    try testing.expectEqual(@as(u64, 0), timer.tick(850));
    try testing.expectEqual(@as(u64, 150), timer.remaining());

    timer.setPeriod(200);
    try testing.expectEqual(@as(u64, 50), timer.elapsed_ms);
    try testing.expectEqual(@as(u64, 150), timer.remaining());

    timer.setPeriod(0);
    try testing.expectEqual(@as(u64, 0), timer.elapsed_ms);
    try testing.expectEqual(std.math.maxInt(u64), timer.remaining());
}

test "rendererCursorOption: maps Config.Cursor onto renderer Cursor.Option" {
    const testing = std.testing;
    try testing.expectEqual(@as(usize, 28), @sizeOf(Config.Cursor));
    try testing.expectEqual(Cursor.Option.default, App.rendererCursorOption(.default));

    const custom: Config.Cursor = .{
        .opacity = 0.75,
        .radius = 2.5,
        .underline_thickness = 0.25,
        .underline_position = 0.9,
        .beam_thickness = 0.2,
        .hollow_border_width = 1.5,
        .blink_interval_ms = 300,
    };
    const mapped = App.rendererCursorOption(custom);
    try testing.expectApproxEqAbs(@as(f32, 0.75), mapped.alpha, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 2.5), mapped.radius, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.25), mapped.underline_frac, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.9), mapped.bar_offset_y, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.2), mapped.bar_frac, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1.5), mapped.hollow_border_width, 1e-6);
}

test "gridLayout and cellPosAt: inner padding scales, shrinks on tiny windows, and offsets hit-testing" {
    const testing = std.testing;
    try testing.expectEqual(@as(u16, 0), App.scaledPaddingPx(0, 1.5));
    try testing.expectEqual(@as(u16, 15), App.scaledPaddingPx(12, 1.25));
    try testing.expectEqual(@as(u16, 24), App.scaledPaddingPx(12, 2.0));

    // Normal window: symmetric padding reduces available grid area and sets origin.
    const normal = App.gridLayout(1000, 600, 10, 20, 20, 10, 220, 200);
    try testing.expectEqual(@as(u16, 20), normal.origin_x);
    try testing.expectEqual(@as(u16, 10), normal.origin_y);
    try testing.expectEqual(@as(u16, 96), normal.cols);
    try testing.expectEqual(@as(u16, 29), normal.rows);

    // Tiny window: padding clamps so at least 1x1 cell still fits.
    const tiny = App.gridLayout(30, 40, 10, 20, 100, 100, 220, 200);
    try testing.expectEqual(@as(u16, 10), tiny.origin_x);
    try testing.expectEqual(@as(u16, 10), tiny.origin_y);
    try testing.expectEqual(@as(u16, 1), tiny.cols);
    try testing.expectEqual(@as(u16, 1), tiny.rows);

    // Hit-testing clamps clicks in the left/top margin to (0, 0) and offsets interior cells.
    try testing.expectEqual(.{ @as(u16, 0), @as(u16, 0) }, App.cellPosAt(5, 3, 20, 10, 10, 20, 220, 200));
    try testing.expectEqual(.{ @as(u16, 0), @as(u16, 0) }, App.cellPosAt(25, 15, 20, 10, 10, 20, 220, 200));
    try testing.expectEqual(.{ @as(u16, 2), @as(u16, 3) }, App.cellPosAt(45, 75, 20, 10, 10, 20, 220, 200));
}

test "kitOverlayOptions: forwards [wellbeing.widget] options to KitOverlay" {
    const testing = std.testing;
    var win: Config.Window = .default;
    win.wellbeing_widget = .{
        .default_visible = true,
        .anchor = .top_left,
        .width = 180,
        .height = 96,
        .progress_style = .half_rings,
        .tooltip = false,
    };

    const opts = App.kitOverlayOptions(.{}, win);
    try testing.expectEqual(.top_left, opts.wellbeing_widget.anchor);
    try testing.expectEqual(@as(f32, 180), opts.wellbeing_widget.default_width);
    try testing.expectEqual(@as(f32, 96), opts.wellbeing_widget.default_height);
    try testing.expectEqual(.half_rings, opts.wellbeing_widget.progress_style);
    try testing.expect(!opts.wellbeing_widget.tooltip);
}

test "AsciiOverlayState: mode resolution honors enabled opt-out, trigger, and focus" {
    const testing = std.testing;
    const State = App.AsciiOverlayState;
    const default_ascii = (Config.Window.default).wellbeing_ascii;

    // Default (enabled = true, trigger = all): locking breaks show on every window;
    // non-locking reminders open only on the focused window and persist if focus leaves.
    try testing.expectEqual(State.Mode.ascii_lock, State.resolveMode(true, true, true, false, false, false, false, default_ascii));
    try testing.expectEqual(State.Mode.ascii_reminder, State.resolveMode(true, false, true, true, false, true, false, default_ascii));
    try testing.expectEqual(State.Mode.none, State.resolveMode(true, false, true, true, false, false, false, default_ascii));
    try testing.expectEqual(State.Mode.ascii_reminder, State.resolveMode(true, false, true, true, false, false, true, default_ascii));
    try testing.expectEqual(State.Mode.ascii_reminder, State.resolveMode(true, false, true, false, true, false, false, default_ascii));
    try testing.expectEqual(State.Mode.none, State.resolveMode(true, false, true, false, false, true, false, default_ascii));

    // Opt-out (enabled = false): locking falls back to centered card, reminders stay toasts.
    var opt_out = default_ascii;
    opt_out.enabled = false;
    try testing.expectEqual(State.Mode.card_lock, State.resolveMode(true, true, true, false, false, false, false, opt_out));
    try testing.expectEqual(State.Mode.none, State.resolveMode(true, false, true, true, true, true, false, opt_out));

    // trigger = lock_only: locking shows ASCII, non-locking reminders stay toasts.
    var lock_only = default_ascii;
    lock_only.trigger = .lock_only;
    try testing.expectEqual(State.Mode.ascii_lock, State.resolveMode(true, true, true, false, false, false, false, lock_only));
    try testing.expectEqual(State.Mode.none, State.resolveMode(true, false, true, true, true, true, false, lock_only));
}

test "AsciiOverlayState: focus break animation activates in focused window and stays dismissed until next break" {
    const testing = std.testing;
    var state: App.AsciiOverlayState = .{};

    // Entering a short break while focused opens the break overlay.
    state.syncFocusPhase(.task, true, true);
    try testing.expectEqual(App.AsciiOverlayState.BreakOverlay.idle, state.break_overlay);
    state.syncFocusPhase(.short_break, true, true);
    try testing.expectEqual(App.AsciiOverlayState.BreakOverlay.active, state.break_overlay);

    // Losing focus after opening keeps it active.
    state.syncFocusPhase(.short_break, true, false);
    try testing.expectEqual(App.AsciiOverlayState.BreakOverlay.active, state.break_overlay);

    // Dismissing keeps it dismissed for the rest of the break.
    state.break_overlay = .dismissed;
    state.syncFocusPhase(.short_break, true, true);
    try testing.expectEqual(App.AsciiOverlayState.BreakOverlay.dismissed, state.break_overlay);

    // Returning to task and entering long_break re-arms it in the focused window only.
    state.syncFocusPhase(.task, true, true);
    try testing.expectEqual(App.AsciiOverlayState.BreakOverlay.idle, state.break_overlay);
    state.syncFocusPhase(.long_break, true, false);
    try testing.expectEqual(App.AsciiOverlayState.BreakOverlay.dismissed, state.break_overlay);
    state.syncFocusPhase(.task, true, true);
    state.syncFocusPhase(.long_break, true, true);
    try testing.expectEqual(App.AsciiOverlayState.BreakOverlay.active, state.break_overlay);
}

test "AsciiOverlayState: frame pacing, minimized pause, and reduced motion freeze" {
    const testing = std.testing;
    var state: App.AsciiOverlayState = .{};

    // Inactive: no wakeups, no redraw.
    try testing.expectEqual(@as(?u64, null), state.wakeMs(false, true, .full, 20));
    try testing.expect(!state.tick(50, false, true, .full, 20));

    // Active & visible (focused or unfocused) at 20 fps (50 ms interval): first tick triggers redraw.
    try testing.expect(state.tick(10, true, true, .full, 20));
    state.drawn_last = true;
    try testing.expectEqual(@as(?u64, 40), state.wakeMs(true, true, .full, 20));
    try testing.expect(!state.tick(20, true, true, .full, 20));
    try testing.expect(state.tick(20, true, true, .full, 20));

    // Minimized (not visible): pauses animation wakeups and redraws.
    try testing.expectEqual(@as(?u64, null), state.wakeMs(true, false, .full, 20));
    try testing.expect(!state.tick(100, true, false, .full, 20));

    // Reduced motion (.none): resets clock to static frame 0 and asks for no wakeups.
    try testing.expectEqual(@as(?u64, null), state.wakeMs(true, true, .none, 20));
    try testing.expect(state.tick(100, true, true, .none, 20));
    try testing.expectEqual(@as(u64, 0), state.time_ms);
    try testing.expect(!state.tick(100, true, true, .none, 20));

    // Deactivating after drawing requests one final redraw to clear the last frame.
    try testing.expect(state.tick(16, false, true, .full, 20));
}

test "production Frame: URL snapshot size and alignment" {
    const testing = std.testing;
    try testing.expectEqual(@as(usize, 36520), @sizeOf(App.FrameType));
    try testing.expectEqual(@as(usize, 8), @alignOf(App.FrameType));
}

test "rendererDecorationOption: one value carries config into both consumers" {
    const testing = std.testing;
    var cfg = config_default;
    cfg.decoration.skip_ink = false;
    cfg.decoration.order = .under_text;
    cfg.decoration.alpha = 0.5;
    cfg.decoration.underline_color = .{ .r = 1, .g = 2, .b = 3 };
    cfg.hyperlink.underline = .hover;

    const option = App.rendererDecorationOption(&cfg);
    try testing.expect(!option.skip_ink.enabled);
    try testing.expectEqual(config.decoration.Order.under_text, option.order);
    try testing.expectEqual(@as(f32, 0.5), option.alpha);
    try testing.expectEqual([3]u8{ 1, 2, 3 }, option.color.underline.?);
    try testing.expectEqual(config.hyperlink.UnderlineVisibility.hover, option.link.underline);
}
