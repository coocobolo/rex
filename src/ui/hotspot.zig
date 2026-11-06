//! Zero-allocation in-stream hotspot registration and hit-testing for interactive UI elements.
//!
//! Hotspots are registered linearly during the rendering pass into a pre-allocated table,
//! allowing mouse click routing to generic UI widget actions without intermediate heap
//! allocations or domain-specific coupling.

const std = @import("std");

pub const Tag = enum(u8) {
    none = 0,
    button = 1,
    modal_action = 2,
    modal_dismiss = 3,
    toast_dismiss = 4,
    toast_action = 5,
    banner_dismiss = 6,
    tab_select = 7,
    chart_select = 8,
};

pub const Action = union(Tag) {
    none,
    button: u64,
    modal_action: u8,
    modal_dismiss,
    toast_dismiss: u64,
    toast_action: u64,
    banner_dismiss: u64,
    tab_select: u8,
    chart_select: u16,
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

    pub fn toAction(self: Hotspot) Action {
        const tag: Tag = @enumFromInt(self.action_tag);
        return switch (tag) {
            .none => .none,
            .button => .{ .button = self.action_payload },
            .modal_action => .{ .modal_action = @intCast(self.action_payload & 0xFF) },
            .modal_dismiss => .modal_dismiss,
            .toast_dismiss => .{ .toast_dismiss = self.action_payload },
            .toast_action => .{ .toast_action = self.action_payload },
            .banner_dismiss => .{ .banner_dismiss = self.action_payload },
            .tab_select => .{ .tab_select = @intCast(self.action_payload & 0xFF) },
            .chart_select => .{ .chart_select = @intCast(self.action_payload & 0xFFFF) },
        };
    }
};

pub const Table = struct {
    pub const capacity: usize = 64;

    items: [capacity]Hotspot = undefined,
    count: usize = 0,

    pub fn clear(self: *Table) void {
        self.count = 0;
    }

    pub fn add(self: *Table, col: u16, row: u16, width: u16, height: u16, action: Action) void {
        if (self.count >= capacity) return;
        const tag = std.meta.activeTag(action);
        const payload: u64 = switch (action) {
            .button => |id| id,
            .modal_action => |idx| idx,
            .toast_dismiss => |id| id,
            .toast_action => |id| id,
            .banner_dismiss => |id| id,
            .tab_select => |idx| idx,
            .chart_select => |idx| idx,
            .none, .modal_dismiss => 0,
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

    pub fn hitTest(self: *const Table, col: u16, row: u16) ?Action {
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

test "Table: zero-allocation add, clear, and reverse hit-testing" {
    const testing = std.testing;

    var table: Table = .{};
    try testing.expectEqual(@as(usize, 0), table.count);

    table.add(10, 5, 20, 2, .{ .modal_action = 0 });
    table.add(12, 5, 5, 1, .modal_dismiss);

    try testing.expectEqual(@as(usize, 2), table.count);

    // Hit overlapping sub-rectangle (returns newer/topmost element)
    const hit_top = table.hitTest(13, 5);
    try testing.expect(hit_top != null);
    try testing.expectEqual(Tag.modal_dismiss, std.meta.activeTag(hit_top.?));

    // Hit underlying rectangle outside sub-rectangle
    const hit_under = table.hitTest(25, 5);
    try testing.expect(hit_under != null);
    try testing.expectEqual(Tag.modal_action, std.meta.activeTag(hit_under.?));
    try testing.expectEqual(@as(u8, 0), hit_under.?.modal_action);

    // Hit outside
    try testing.expectEqual(@as(?Action, null), table.hitTest(0, 0));

    table.clear();
    try testing.expectEqual(@as(usize, 0), table.count);
    try testing.expectEqual(@as(?Action, null), table.hitTest(13, 5));
}

test "Table: generic widget payload round-trip" {
    const testing = std.testing;

    var table: Table = .{};
    table.add(0, 0, 10, 1, .{ .button = 101 });
    table.add(10, 0, 10, 1, .{ .tab_select = 2 });
    table.add(20, 0, 10, 1, .{ .chart_select = 13 });
    table.add(30, 0, 10, 1, .{ .banner_dismiss = 7 });
    table.add(0, 5, 20, 3, .{ .toast_action = 42 });
    table.add(18, 5, 2, 1, .{ .toast_dismiss = 42 });

    try testing.expectEqual(@as(u64, 101), table.hitTest(2, 0).?.button);
    try testing.expectEqual(@as(u8, 2), table.hitTest(12, 0).?.tab_select);
    try testing.expectEqual(@as(u16, 13), table.hitTest(22, 0).?.chart_select);
    try testing.expectEqual(@as(u64, 7), table.hitTest(32, 0).?.banner_dismiss);

    const dismiss_hit = table.hitTest(19, 5);
    try testing.expect(dismiss_hit != null);
    try testing.expectEqual(Tag.toast_dismiss, std.meta.activeTag(dismiss_hit.?));
    try testing.expectEqual(@as(u64, 42), dismiss_hit.?.toast_dismiss);

    const activate_hit = table.hitTest(5, 6);
    try testing.expect(activate_hit != null);
    try testing.expectEqual(Tag.toast_action, std.meta.activeTag(activate_hit.?));
    try testing.expectEqual(@as(u64, 42), activate_hit.?.toast_action);
}
