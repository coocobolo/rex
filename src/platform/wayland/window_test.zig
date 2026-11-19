const std = @import("std");
const testing = std.testing;

const backend = @import("backend.zig");

const selected = @import("build_options").platform_backend;
const selected_wayland = std.mem.eql(u8, selected, "wayland");

test "Wayland choose: auto and wayland select wayland; forced x11 fails loudly at init" {
    const auto_choice = backend.choose(.auto, true);
    try testing.expectEqual(backend.System.wayland, auto_choice.system);
    try testing.expect(!auto_choice.forced);

    const wl_choice = backend.choose(.wayland, false);
    try testing.expectEqual(backend.System.wayland, wl_choice.system);
    try testing.expect(wl_choice.forced);

    const x11_choice = backend.choose(.x11, true);
    try testing.expectEqual(backend.System.x11, x11_choice.system);
    try testing.expect(x11_choice.forced);

    if (!selected_wayland) return;
    try testing.expectError(error.X11Unavailable, backend.init(x11_choice));
}

test "Wayland window lifecycle: create, title, size, wakeup, poll, destroy" {
    if (!selected_wayland) return;

    const was_ready = backend.state.phase == .ready;
    if (!was_ready) {
        backend.init(.{ .system = .wayland, .forced = false }) catch return error.SkipZigTest;
    }
    defer if (!was_ready) backend.deinit();

    const win = try backend.createWindow(.{
        .width = 320,
        .height = 240,
        .title = "rex-wayland-test",
    });
    defer backend.destroyWindow(win);

    var ctx_val: u32 = 42;
    backend.windowSetContext(win, &ctx_val);
    try testing.expectEqual(@as(?*anyopaque, &ctx_val), backend.windowGetContext(win));

    backend.windowSetTitle(win, "rex-wayland-renamed");
    backend.windowSetMinimumSize(win, 100, 80);
    try testing.expect(!backend.windowShouldClose(win));
    backend.windowSetShouldClose(win, true);
    try testing.expect(backend.windowShouldClose(win));

    const fb = backend.windowFramebufferSize(win, u32);
    try testing.expect(fb.width >= 1 and fb.height >= 1);
    const scale = backend.windowContentScale(win);
    try testing.expect(scale.width > 0 and scale.height > 0);

    backend.postWakeup();
    backend.waitEvents(10.0);
    backend.pollEvents();
    backend.windowSwapBuffers(win);
}
