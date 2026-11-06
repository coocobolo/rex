//! Sequential keyboard focus management for interactive UI components.
//!
//! Provides two-byte cyclic focus ordering supporting forward tab navigation,
//! backward shift-tab navigation, and boundary clamping without dynamic heap allocations.

const std = @import("std");

pub const FocusGroup = struct {
    focused_index: ?u8 = null,
    total_elements: u8 = 0,

    pub fn init(total: u8, initial: ?u8) FocusGroup {
        return .{
            .focused_index = if (total > 0) (initial orelse 0) else null,
            .total_elements = total,
        };
    }

    pub fn next(self: *FocusGroup) void {
        if (self.total_elements == 0) return;
        self.focused_index = if (self.focused_index) |idx|
            (idx + 1) % self.total_elements
        else
            0;
    }

    pub fn previous(self: *FocusGroup) void {
        if (self.total_elements == 0) return;
        self.focused_index = if (self.focused_index) |idx|
            (idx + self.total_elements - 1) % self.total_elements
        else
            self.total_elements - 1;
    }

    pub fn isFocused(self: *const FocusGroup, index: u8) bool {
        return self.focused_index != null and self.focused_index.? == index;
    }

    pub fn set(self: *FocusGroup, index: ?u8) void {
        if (index) |i| {
            if (i < self.total_elements) self.focused_index = i;
        } else {
            self.focused_index = null;
        }
    }
};

test "FocusGroup: forward cycling, reverse cycling, and clamping" {
    const testing = std.testing;

    var group = FocusGroup.init(3, 0);
    try testing.expect(group.isFocused(0));
    try testing.expect(!group.isFocused(1));

    // Next advances index
    group.next();
    try testing.expect(group.isFocused(1));

    group.next();
    try testing.expect(group.isFocused(2));

    // Wrap around to 0
    group.next();
    try testing.expect(group.isFocused(0));

    // Prev wraps backward to 2
    group.previous();
    try testing.expect(group.isFocused(2));

    group.previous();
    try testing.expect(group.isFocused(1));

    // Explicit set
    group.set(0);
    try testing.expect(group.isFocused(0));

    // Set out-of-bounds does nothing
    group.set(99);
    try testing.expect(group.isFocused(0));

    // Unfocus
    group.set(null);
    try testing.expect(!group.isFocused(0));
}
