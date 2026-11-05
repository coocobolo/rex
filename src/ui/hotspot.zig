//! Zero-allocation in-stream hotspot registration and hit-testing for interactive UI elements.
//!
//! Hotspots are registered linearly during the rendering pass into a pre-allocated table,
//! allowing mouse click routing without intermediate heap allocations or multi-pass translations.

const std = @import("std");

pub const UiActionTag = enum(u8) {
    none = 0,
    confirm_quit = 1,
    cancel_modal = 2,
    modal_action = 3,
    dismiss_toast = 4,
    activate_toast = 5,
    wellbeing_close = 6,
    wellbeing_toggle_focus = 7,
    wellbeing_reset = 8,
    wellbeing_copy_card = 9,
    dismiss_banner = 10,
};

pub const UiAction = union(UiActionTag) {
    none,
    confirm_quit,
    cancel_modal,
    modal_action: u8,
    dismiss_toast: u64,
    activate_toast: u64,
    wellbeing_close,
    wellbeing_toggle_focus,
    wellbeing_reset,
    wellbeing_copy_card,
    dismiss_banner,
};

pub const Hotspot = extern struct {
    col: u16,
    row: u16,
    width: u16,
    height: u16,
    action_tag: u8,
    _pad1: u8 = 0,
    _pad2: u16 = 0,
    action_payload: u64 = 0,

    pub fn toAction(self: Hotspot) UiAction {
        const tag: UiActionTag = @enumFromInt(self.action_tag);
        return switch (tag) {
            .none => .none,
            .confirm_quit => .confirm_quit,
            .cancel_modal => .cancel_modal,
            .modal_action => .{ .modal_action = @intCast(self.action_payload & 0xFF) },
            .dismiss_toast => .{ .dismiss_toast = self.action_payload },
            .activate_toast => .{ .activate_toast = self.action_payload },
            .wellbeing_close => .wellbeing_close,
            .wellbeing_toggle_focus => .wellbeing_toggle_focus,
            .wellbeing_reset => .wellbeing_reset,
            .wellbeing_copy_card => .wellbeing_copy_card,
            .dismiss_banner => .dismiss_banner,
        };
    }
};

pub const HotspotTable = struct {
    pub const capacity: usize = 32;

    items: [capacity]Hotspot = undefined,
    count: usize = 0,

    pub fn clear(self: *HotspotTable) void {
        self.count = 0;
    }

    pub fn add(self: *HotspotTable, col: u16, row: u16, width: u16, height: u16, action: UiAction) void {
        if (self.count >= capacity) return;
        const tag = std.meta.activeTag(action);
        const payload: u64 = switch (action) {
            .modal_action => |idx| idx,
            .dismiss_toast => |id| id,
            .activate_toast => |id| id,
            else => 0,
        };
        self.items[self.count] = .{
            .col = col,
            .row = row,
            .width = width,
            .height = height,
            .action_tag = @intFromEnum(tag),
            .action_payload = payload,
        };
        self.count += 1;
    }

    pub fn hitTest(self: *const HotspotTable, col: u16, row: u16) ?UiAction {
        var i = self.count;
        while (i > 0) {
            i -= 1;
            const h = self.items[i];
            if (col >= h.col and col < h.col + h.width and
                row >= h.row and row < h.row + h.height)
            {
                return h.toAction();
            }
        }
        return null;
    }
};

test "HotspotTable: zero-allocation add, clear, and reverse hit-testing" {
    const testing = std.testing;

    var table: HotspotTable = .{};
    try testing.expectEqual(@as(usize, 0), table.count);

    table.add(10, 5, 20, 2, .confirm_quit);
    table.add(12, 5, 5, 1, .cancel_modal);

    try testing.expectEqual(@as(usize, 2), table.count);

    // Hit overlapping sub-rectangle (returns newer/topmost element)
    const hit_top = table.hitTest(13, 5);
    try testing.expect(hit_top != null);
    try testing.expectEqual(UiActionTag.cancel_modal, std.meta.activeTag(hit_top.?));

    // Hit underlying rectangle outside sub-rectangle
    const hit_under = table.hitTest(25, 5);
    try testing.expect(hit_under != null);
    try testing.expectEqual(UiActionTag.confirm_quit, std.meta.activeTag(hit_under.?));

    // Hit outside
    try testing.expectEqual(@as(?UiAction, null), table.hitTest(0, 0));

    table.clear();
    try testing.expectEqual(@as(usize, 0), table.count);
    try testing.expectEqual(@as(?UiAction, null), table.hitTest(13, 5));
}

test "HotspotTable: wellbeing and toast payload round-trip" {
    const testing = std.testing;

    var table: HotspotTable = .{};
    table.add(0, 0, 10, 1, .wellbeing_close);
    table.add(10, 0, 10, 1, .wellbeing_toggle_focus);
    table.add(20, 0, 10, 1, .wellbeing_reset);
    table.add(30, 0, 10, 1, .wellbeing_copy_card);
    table.add(0, 5, 20, 3, .{ .activate_toast = 42 });
    table.add(18, 5, 2, 1, .{ .dismiss_toast = 42 });

    try testing.expectEqual(UiActionTag.wellbeing_close, std.meta.activeTag(table.hitTest(2, 0).?));
    try testing.expectEqual(UiActionTag.wellbeing_toggle_focus, std.meta.activeTag(table.hitTest(12, 0).?));
    try testing.expectEqual(UiActionTag.wellbeing_reset, std.meta.activeTag(table.hitTest(22, 0).?));
    try testing.expectEqual(UiActionTag.wellbeing_copy_card, std.meta.activeTag(table.hitTest(32, 0).?));

    const dismiss_hit = table.hitTest(19, 5);
    try testing.expect(dismiss_hit != null);
    try testing.expectEqual(UiActionTag.dismiss_toast, std.meta.activeTag(dismiss_hit.?));
    try testing.expectEqual(@as(u64, 42), dismiss_hit.?.dismiss_toast);

    const activate_hit = table.hitTest(5, 6);
    try testing.expect(activate_hit != null);
    try testing.expectEqual(UiActionTag.activate_toast, std.meta.activeTag(activate_hit.?));
    try testing.expectEqual(@as(u64, 42), activate_hit.?.activate_toast);
}
