//! Layout checks for the vendored Wayland protocol interface table and
//! listener structs, which must match the C ABI exactly.

const std = @import("std");
const testing = std.testing;

const proto = @import("proto.zig");

test "Wayland protocol: interface table and listeners match the C ABI layout" {
    inline for (.{
        .{ proto.Interfaces, 160 },
        .{ proto.registry.Listener, 16 },
        .{ proto.xdg_wm_base.Listener, 8 },
        .{ proto.xdg_surface.Listener, 8 },
        .{ proto.xdg_toplevel.Listener, 32 },
        .{ proto.xdg_toplevel_decoration.Listener, 8 },
        .{ proto.seat.Listener, 16 },
        .{ proto.keyboard.Listener, 48 },
        .{ proto.pointer.Listener, 88 },
        .{ proto.fractional_scale.Listener, 8 },
        .{ proto.text_input.Listener, 48 },
        .{ proto.data_device.Listener, 48 },
        .{ proto.data_source.Listener, 48 },
        .{ proto.data_offer.Listener, 24 },
        .{ proto.primary_selection_device.Listener, 16 },
        .{ proto.primary_selection_source.Listener, 16 },
        .{ proto.primary_selection_offer.Listener, 8 },
        .{ proto.xdg_activation_token.Listener, 8 },
    }) |entry| {
        try testing.expectEqual(@as(usize, entry[1]), @sizeOf(entry[0]));
        try testing.expectEqual(@as(usize, @alignOf(usize)), @alignOf(entry[0]));
    }
}
