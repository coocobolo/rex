const std = @import("std");
const testing = std.testing;

const Action = @import("binding.zig").Action;
const Binding = @import("binding.zig").Binding;
const matchBinding = @import("binding.zig").matchBinding;

test "matchBinding: the key and the exact modifiers must match" {
    const bindings: []const Binding = &.{
        .{ .key = .q, .mods = .{ .ctrl = true, .shift = true }, .action = .quit },
        .{ .key = .c, .mods = .{ .ctrl = true, .shift = true }, .action = .copy_selection },
    };
    try testing.expectEqual(Action.quit, matchBinding(bindings, .q, .{ .ctrl = true, .shift = true }).?);
    try testing.expectEqual(Action.copy_selection, matchBinding(bindings, .c, .{ .ctrl = true, .shift = true }).?);
    try testing.expectEqual(null, matchBinding(bindings, .q, .{}));
    try testing.expectEqual(null, matchBinding(bindings, .q, .{ .ctrl = true }));
}
