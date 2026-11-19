//! Tests for Wayland selection MIME precedence and ownership.

const std = @import("std");
const testing = std.testing;

const backend = @import("backend.zig");
const selection = @import("selection.zig");

const selected = @import("build_options").platform_backend;
const selected_wayland = std.mem.eql(u8, selected, "wayland");

test "Wayland selection: the MIME flags pack into one byte" {
    try testing.expectEqual(@as(usize, 1), @sizeOf(selection.OfferMime));
    try testing.expectEqual(@as(usize, 1), @alignOf(selection.OfferMime));
    try testing.expectEqual(@as(u8, 0), @as(u8, @bitCast(selection.OfferMime{})));
    try testing.expectEqual(@as(u8, 1), @as(u8, @bitCast(selection.OfferMime{ .utf8 = true })));
    try testing.expectEqual(@as(u8, 2), @as(u8, @bitCast(selection.OfferMime{ .plain = true })));
}

test "Wayland selection: MIME precedence prefers UTF-8 over plain text" {
    try testing.expectEqualStrings(selection.mime_utf8, selection.preferredMime(true, true).?);
    try testing.expectEqualStrings(selection.mime_utf8, selection.preferredMime(true, false).?);
    try testing.expectEqualStrings(selection.mime_plain, selection.preferredMime(false, true).?);
    try testing.expectEqual(@as(?[:0]const u8, null), selection.preferredMime(false, false));
}

test "Wayland selection: clipboard, primary, bell and attention on a compositor" {
    if (!selected_wayland) return;

    const was_ready = backend.state.phase == .ready;
    if (!was_ready) {
        backend.init(.{ .system = .wayland, .forced = false }) catch return error.SkipZigTest;
    }
    defer if (!was_ready) backend.deinit();

    const win = try backend.createWindow(.{
        .width = 200,
        .height = 120,
        .title = "rex-selection-test",
    });
    defer backend.destroyWindow(win);

    backend.windowSetClipboard(win, "hello-wayland-clipboard");
    const clip = backend.windowGetClipboard(win) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("hello-wayland-clipboard", clip);

    if (backend.windowSetPrimarySelection(win, "hello-wayland-primary")) {
        const prim = backend.windowGetPrimarySelection(win) orelse return error.TestUnexpectedResult;
        try testing.expectEqualStrings("hello-wayland-primary", prim);
    }

    // Bell and attention must not crash even when a compositor omits the protocol.
    backend.windowRingBell(win, 0.5);
    backend.windowRingBell(win, 0.0);
    backend.windowRequestAttention(win);
    backend.pollEvents();
}
