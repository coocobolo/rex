const std = @import("std");
const testing = std.testing;

const backend = @import("backend.zig");
const selected = @import("build_options").platform_backend;
const selected_glfw = std.mem.eql(u8, selected, "glfw");
const Platform = @import("../Platform.zig");
const Event = @import("../Event.zig").Event;

test "window: create, read state and drain events on a display" {
    if (!selected_glfw) return;
    // testGlContext skips without a display and readies GLFW for the test.
    try backend.testGlContext();

    // GLFW's own startup messages would otherwise fail the build runner.
    const old_level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = old_level;

    var p: Platform = try .init(Platform.choose(.auto, false));
    defer p.deinit();

    const window = try p.createWindow(.{ .width = 80, .height = 25, .title = "stage1-window-test" });
    defer window.deinit();

    const size = window.framebufferSize(u32);
    try testing.expect(size.width > 0);
    try testing.expect(size.height > 0);
    // Clipboard round-trip is covered by the existing renderer window test;
    // this test must not touch the user's clipboard when DISPLAY is live.

    // A real callback must resolve the window through GLFW's user pointer.
    // This catches a user pointer aimed at a temporary instead of the slot.
    backend.testKeyEvent(window, .a);
    var event: Event = undefined;
    if (!p.nextEvent(&event)) return error.EventNotDelivered;
    const key_event = switch (event) {
        .key => |k| k,
        else => return error.UnexpectedEvent,
    };
    try testing.expectEqual(@as(@import("../../input/key.zig").Key, .a), key_event.key);
    try testing.expectEqual(@as(std.meta.Tag(Event), .key), std.meta.activeTag(event));
    try testing.expectEqual(@as(u32, 0), p.takeDropped());
}

test "deinit: a GL test context survives platform shutdown" {
    if (!selected_glfw) return;
    try backend.testGlContext();
    const old_level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = old_level;

    var p: Platform = try .init(Platform.choose(.auto, false));
    p.deinit();

    // The platform did not own this GLFW instance, so the hidden test context
    // must still be current and usable.
    try backend.testGlContext();
    const gl = @import("../../renderer/gl.zig");
    var major: c_int = 0;
    gl.getIntegerv(gl.MAJOR_VERSION, &major);
    try testing.expect(major >= 3);
}
