//! Tests for GLFW backend platform choice and formatting.

const std = @import("std");
const testing = std.testing;

const backend = @import("backend.zig");
const window_config = @import("../../config/window.zig");

test "choose: auto follows the session, an explicit choice is forced" {
    const macos = @import("builtin").os.tag == .macos;
    const Case = struct {
        requested: window_config.Platform,
        wayland_session: bool,
        system: backend.System,
        forced: bool,
    };
    const cases = [_]Case{
        .{ .requested = .auto, .wayland_session = true, .system = if (macos) .cocoa else .wayland, .forced = false },
        .{ .requested = .auto, .wayland_session = false, .system = if (macos) .cocoa else .x11, .forced = false },
        .{ .requested = .wayland, .wayland_session = true, .system = .wayland, .forced = true },
        .{ .requested = .wayland, .wayland_session = false, .system = .wayland, .forced = true },
        .{ .requested = .x11, .wayland_session = true, .system = .x11, .forced = true },
        .{ .requested = .x11, .wayland_session = false, .system = .x11, .forced = true },
    };
    for (cases) |case| {
        const choice = backend.choose(case.requested, case.wayland_session);
        try testing.expectEqual(case.system, choice.system);
        try testing.expectEqual(case.forced, choice.forced);
    }
}

test "Choice: formats as the system name for the startup log" {
    var buf: [16]u8 = undefined;
    const x11: backend.Choice = .{ .system = .x11, .forced = false };
    try testing.expectEqualStrings("x11", try std.fmt.bufPrint(&buf, "{f}", .{x11}));
    const wayland: backend.Choice = .{ .system = .wayland, .forced = true };
    try testing.expectEqualStrings("wayland", try std.fmt.bufPrint(&buf, "{f}", .{wayland}));
}
