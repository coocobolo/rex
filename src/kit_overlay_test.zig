//! The UI kit's glue as the app drives it, with the real font and a GL
//! context but no window content: frames are built, not looked at (the
//! pixels are checked in `renderer/kit_painter_test.zig`).

const std = @import("std");
const testing = std.testing;

const Atlas = @import("renderer/Atlas.zig");
const testGlContext = @import("platform/root.zig").testGlContext;
const KitOverlay = @import("KitOverlay.zig");
const alert = @import("kit/alert.zig");
const alert_dialog = @import("kit/alert_dialog.zig");
const dialog = @import("kit/dialog.zig");
const lock_screen = @import("kit/lock_screen.zig");
const toast = @import("kit/toast.zig");
const wellbeing_widget = @import("kit/wellbeing_widget.zig");
const Theme = @import("kit/Theme.zig");
const motion = @import("kit/motion.zig");
const Id = @import("kit/Tree.zig").Id;
const Rect = @import("kit/Tree.zig").Rect;

const inter: @import("freetype/KitFont.zig").Files = .{
    .regular = "assets/fonts/Inter-Regular.ttf",
    .medium = "assets/fonts/Inter-Medium.ttf",
    .semibold = "assets/fonts/Inter-SemiBold.ttf",
};

const dark: [3]u8 = .{ 0x10, 0x10, 0x14 };

const Fixture = struct {
    atlas: Atlas,
    kit: *KitOverlay,

    fn init(scale: f32) !Fixture {
        try testGlContext();
        var atlas = try Atlas.init(testing.allocator, .{ .width = 512, .height = 512 });
        errdefer atlas.deinit();
        return .{ .atlas = atlas, .kit = try KitOverlay.create(testing.allocator, inter, scale) };
    }

    fn deinit(self: *Fixture) void {
        self.kit.destroy(testing.allocator);
        self.atlas.deinit();
    }

    /// A frame of an 800 by 600 window (logical pixels).
    fn frame(self: *Fixture) bool {
        return self.kit.buildFrame(&self.atlas, 800, 600, dark);
    }
};

test "KitOverlay: idle, it asks for no frame and no wakeup" {
    var fixture: Fixture = try .init(1);
    defer fixture.deinit();
    const kit = fixture.kit;

    try testing.expect(!kit.tick(1000));
    try testing.expectEqual(null, kit.wakeMs());
    try testing.expect(!fixture.frame());
    try testing.expectEqual(0, kit.painter.len);
    try testing.expectEqual(KitOverlay.Press.outside, kit.press(700, 550));
}

test "KitOverlay: a toast from push to gone, with the frames it asks for" {
    var fixture: Fixture = try .init(1.25);
    defer fixture.deinit();
    const kit = fixture.kit;

    try testing.expect(kit.push(.{ .title = "Configuration reloaded", .kind = .info, .duration_ms = 3000 }));
    try testing.expect(fixture.frame());
    try testing.expect(kit.painter.len > 20); // card, icon and a glyph per letter
    try testing.expectEqual(16, kit.wakeMs());

    try testing.expect(kit.tick(Theme.duration));
    try testing.expect(fixture.frame());
    // At rest: one wakeup, when its time is up, and no frame until then.
    try testing.expectEqual(3000, kit.wakeMs());
    try testing.expect(!kit.tick(1000));
    try testing.expectEqual(2000, kit.wakeMs());

    try testing.expect(kit.tick(2000));
    try testing.expect(fixture.frame());
    try testing.expect(kit.tick(Theme.duration));
    // Gone: this frame only takes the last one's toast away.
    try testing.expect(fixture.frame());
    try testing.expectEqual(0, kit.painter.len);
    try testing.expect(!fixture.frame());
    try testing.expectEqual(null, kit.wakeMs());
}

test "KitOverlay: the pointer holds a toast, a click on its close button dismisses it" {
    var fixture: Fixture = try .init(1);
    defer fixture.deinit();
    const kit = fixture.kit;

    _ = kit.push(.{ .title = "Copied", .duration_ms = 3000 });
    _ = kit.tick(Theme.duration);
    _ = fixture.frame();
    // The card is 356 by 52 with its bottom right corner at 776, 576; the
    // close button is the 20 px square inside its padding.
    try testing.expect(!kit.pointerMoved(500, 550));
    try testing.expectEqual(null, kit.wakeMs());
    try testing.expect(!kit.tick(60_000));
    try testing.expect(!kit.pointerMoved(100, 100));
    try testing.expectEqual(3000, kit.wakeMs());

    try testing.expectEqual(KitOverlay.Press.outside, kit.press(100, 100));
    try testing.expectEqual(KitOverlay.Press.taken, kit.press(500, 550));
    try testing.expectEqual(KitOverlay.Press.changed, kit.press(750, 550));
    try testing.expectEqual(KitOverlay.Press.taken, kit.press(750, 550));
    try testing.expect(!kit.dismissOldest());
}

test "KitOverlay: a pointer that leaves the window lets go of what it was over" {
    var fixture: Fixture = try .init(1);
    defer fixture.deinit();
    const kit = fixture.kit;

    _ = kit.push(.{ .title = "Copied", .duration_ms = 3000 });
    _ = kit.tick(Theme.duration);
    _ = fixture.frame();
    _ = kit.pointerMoved(500, 550);
    try testing.expectEqual(null, kit.wakeMs());
    // Nothing to redraw, but the toast's time runs again.
    try testing.expect(!kit.pointerLeft());
    try testing.expectEqual(3000, kit.wakeMs());

    _ = kit.openDialog(prompt());
    _ = kit.tick(Theme.duration);
    _ = fixture.frame();
    const confirm = centerOf(kit, alert_dialog.actionId(1)).?;
    try testing.expect(kit.pointerMoved(confirm[0], confirm[1]));
    try testing.expectEqual(1, kit.dialog.hover);
    try testing.expect(kit.pointerLeft());
    try testing.expectEqual(alert_dialog.no_action, kit.dialog.hover);
    try testing.expect(!kit.pointerLeft());
}

test "KitOverlay: a dialog takes the pointer off a toast" {
    var fixture: Fixture = try .init(1);
    defer fixture.deinit();
    const kit = fixture.kit;

    _ = kit.push(.{ .title = "Copied", .duration_ms = 3000 });
    _ = kit.tick(Theme.duration);
    _ = fixture.frame();
    _ = kit.pointerMoved(500, 550);
    try testing.expectEqual(toast.Pointer.over, kit.toasts.pointer);

    // Opened from the keyboard, the pointer still where the toast is.
    try testing.expect(kit.openDialog(prompt()));
    try testing.expectEqual(toast.Pointer.away, kit.toasts.pointer);
    _ = kit.tick(Theme.duration);
    _ = fixture.frame();
    // A move over the scrim does not bring the hover back.
    _ = kit.pointerMoved(500, 550);
    try testing.expectEqual(toast.Pointer.away, kit.toasts.pointer);
}

test "KitOverlay: texts of nothing but line feeds still show" {
    var fixture: Fixture = try .init(1);
    defer fixture.deinit();
    const kit = fixture.kit;

    const feeds = "\n" ** 200;
    for (0..3) |_| _ = kit.push(.{ .title = feeds, .description = feeds, .duration_ms = 3000 });
    try testing.expect(fixture.frame());
    try testing.expectEqual(3, kit.toasts.visible().len);

    _ = kit.openDialog(.{ .title = feeds, .body = feeds, .actions = &prompt_actions });
    try testing.expect(fixture.frame());
    try testing.expect(kit.dialog.phase != .closed);
}

test "KitOverlay: the others keep asking for frames while they glide" {
    var fixture: Fixture = try .init(1);
    defer fixture.deinit();
    const kit = fixture.kit;

    _ = kit.push(.{ .title = "older", .duration_ms = 60_000 });
    _ = kit.push(.{ .title = "newer", .duration_ms = 60_000 });
    _ = kit.tick(Theme.duration);
    _ = fixture.frame();
    try testing.expectEqual(60_000, kit.wakeMs());

    // The newer, lower one goes; the older has 66 px to come down.
    try testing.expectEqual(KitOverlay.Press.changed, kit.press(750, 550));
    _ = kit.tick(Theme.duration - 16);
    _ = fixture.frame();
    // The frame in which it is gone starts the glide.
    _ = kit.tick(16);
    try testing.expect(fixture.frame());
    try testing.expectEqual(16, kit.wakeMs());
    try testing.expect(kit.tick(16));
    // Long enough to arrive, then it rests again.
    _ = kit.tick(400);
    try testing.expect(fixture.frame());
    try testing.expectEqual(60_000 - 200 - 416, kit.wakeMs());
    try testing.expect(!kit.tick(16));
}

test "KitOverlay: a glide that starts after a long rest is not over at once" {
    var fixture: Fixture = try .init(1);
    defer fixture.deinit();
    const kit = fixture.kit;

    _ = kit.push(.{ .title = "older", .duration_ms = 60_000 });
    _ = kit.tick(Theme.duration);
    _ = fixture.frame();
    // Three seconds at rest, in one sleep; then a second toast pushes the
    // first one up.
    try testing.expect(!kit.tick(3000));
    try testing.expect(kit.push(.{ .title = "newer", .duration_ms = 60_000 }));
    try testing.expect(fixture.frame());
    try testing.expectEqual(.moving, kit.motion);
    try testing.expect(kit.tick(16));
    try testing.expect(fixture.frame());
    try testing.expectEqual(.moving, kit.motion);
}

test "KitOverlay: hidden under a modal, nothing is drawn or hit" {
    var fixture: Fixture = try .init(1);
    defer fixture.deinit();
    const kit = fixture.kit;

    _ = kit.push(.{ .title = "Copied", .duration_ms = 3000 });
    _ = kit.tick(Theme.duration);
    try testing.expect(fixture.frame());
    try testing.expect(kit.skipFrame());
    try testing.expectEqual(0, kit.painter.len);
    try testing.expectEqual(KitOverlay.Press.outside, kit.press(500, 550));
    try testing.expect(!kit.skipFrame());
}

test "KitOverlay: after the atlas is cleared, glyphs are rasterized again" {
    var fixture: Fixture = try .init(1);
    defer fixture.deinit();
    const kit = fixture.kit;

    _ = kit.push(.{ .title = "Copied", .duration_ms = 3000 });
    _ = fixture.frame();
    const before = kit.painter.len;
    fixture.atlas.invalidate();
    kit.glyphsLost(1.5);
    try testing.expectEqual(1.5, kit.font.scale);
    try testing.expect(fixture.frame());
    try testing.expectEqual(before, kit.painter.len);
}

const prompt_actions = [_]alert_dialog.Action{
    .{ .label = "Cancel", .role = .dismiss, .key_cap = "Esc" },
    .{ .label = "Close window", .variant = .destructive },
};

fn prompt() alert_dialog.Request {
    return .{
        .title = "Close this window?",
        .body = "A program is still running.",
        .actions = &prompt_actions,
        .focus = 1,
    };
}

fn centerOf(kit: *KitOverlay, id: Id) ?[2]f32 {
    for (kit.tree.items()) |node| {
        if (node.box.id == id) return .{ node.rect.x + node.rect.w / 2, node.rect.y + node.rect.h / 2 };
    }
    return null;
}

test "KitOverlay: a dialog enters, rests, and leaves" {
    var fixture: Fixture = try .init(1);
    defer fixture.deinit();
    const kit = fixture.kit;

    try testing.expect(kit.openDialog(prompt()));
    try testing.expectEqual(motion.frame_ms, kit.wakeMs());
    try testing.expect(kit.tick(Theme.duration));
    try testing.expectEqual(null, kit.wakeMs());
    try testing.expect(kit.dialogTakesInput());
    try testing.expect(fixture.frame());
    try testing.expect(kit.painter.len > 20);

    try testing.expectEqual(alert_dialog.Outcome.redraw, kit.dialogInput(.dismiss));
    try testing.expectEqual(motion.frame_ms, kit.wakeMs());
    // Keys do nothing while it is leaving.
    try testing.expectEqual(alert_dialog.Outcome.quiet, kit.dialogInput(.activate));
    try testing.expect(!kit.dialogTakesInput());
    try testing.expect(kit.tick(Theme.duration));
    try testing.expectEqual(dialog.Phase.closed, kit.dialog.phase);
    try testing.expect(!kit.tick(16));
}

test "KitOverlay: confirming a dialog closes it, the scrim does not" {
    var fixture: Fixture = try .init(1);
    defer fixture.deinit();
    const kit = fixture.kit;

    _ = kit.openDialog(prompt());
    _ = kit.tick(Theme.duration);
    try testing.expect(fixture.frame());
    const confirm = centerOf(kit, alert_dialog.actionId(1)).?;
    const cancel = centerOf(kit, alert_dialog.actionId(0)).?;
    try testing.expect(confirm[0] > cancel[0]);

    try testing.expect(kit.pointerMoved(confirm[0], confirm[1]));
    try testing.expect(!kit.pointerMoved(confirm[0], confirm[1]));
    try testing.expectEqual(KitOverlay.Press.scrim, kit.press(4, 4));
    try testing.expectEqual(dialog.Phase.open, kit.dialog.phase);
    // The card, off both buttons: the ring drops and the dialog stays.
    const card = centerOf(kit, alert_dialog.card_id).?;
    try testing.expectEqual(1, kit.dialog.focus);
    try testing.expectEqual(KitOverlay.Press.changed, kit.press(card[0], card[1]));
    try testing.expectEqual(alert_dialog.no_action, kit.dialog.focus);
    try testing.expectEqual(KitOverlay.Press.taken, kit.press(card[0], card[1]));
    try testing.expectEqual(dialog.Phase.open, kit.dialog.phase);
    // Going down on the button only presses it; letting go takes it.
    try testing.expect(!kit.holdsPress());
    try testing.expectEqual(KitOverlay.Press.changed, kit.press(confirm[0], confirm[1]));
    try testing.expect(kit.holdsPress());
    try testing.expectEqual(dialog.Phase.open, kit.dialog.phase);
    // Moved off before letting go: nothing is taken.
    _ = kit.pointerMoved(card[0], card[1]);
    try testing.expectEqual(KitOverlay.Release{ .dialog = .quiet }, kit.release(card[0], card[1]));
    try testing.expect(!kit.holdsPress());
    try testing.expectEqual(dialog.Phase.open, kit.dialog.phase);
    try testing.expectEqual(KitOverlay.Press.changed, kit.press(confirm[0], confirm[1]));
    try testing.expectEqual(KitOverlay.Release{ .dialog = .{ .chosen = 1 } }, kit.release(confirm[0], confirm[1]));
    try testing.expectEqual(dialog.Phase.closed, kit.dialog.phase);
}

test "KitOverlay: alert banner shares frame with toasts and closes on button release" {
    var fixture: Fixture = try .init(1);
    defer fixture.deinit();
    const kit = fixture.kit;

    try testing.expect(kit.showAlert(.{ .kind = .err, .title = "Bad config", .description = "Line 3" }));
    try testing.expect(kit.push(.{ .title = "Saved", .duration_ms = 60_000 }));
    _ = kit.tick(Theme.duration);
    try testing.expect(fixture.frame());
    try testing.expect(kit.alertShown());

    const close = centerOf(kit, alert.close_id).?;
    try testing.expectEqual(KitOverlay.Press.changed, kit.press(close[0], close[1]));
    try testing.expect(kit.holdsPress());
    try testing.expectEqual(KitOverlay.Release.redraw, kit.release(close[0], close[1]));
    try testing.expect(!kit.alertShown());
}

test "KitOverlay: lock screen takes scrim priority and unlocks on release" {
    var fixture: Fixture = try .init(1);
    defer fixture.deinit();
    const kit = fixture.kit;

    try testing.expect(kit.syncLockScreen(.{
        .title = "Break time",
        .subtitle = "Focus cycle 1 of 4",
        .prompt = "Look away.",
        .remaining_s = 15,
        .total_s = 20,
        .steps_total = 4,
        .steps_done = 1,
    }));
    _ = kit.tick(Theme.duration);
    try testing.expect(kit.hasScrim());
    try testing.expect(kit.lockScreenTakesInput());
    try testing.expect(fixture.frame());

    const unlock = centerOf(kit, lock_screen.unlock_id).?;
    // First click outside button blurs the focused unlock button; second click stays taken.
    try testing.expect(kit.lock_screen.focused);
    try testing.expectEqual(KitOverlay.Press.changed, kit.press(8, 8));
    try testing.expect(!kit.lock_screen.focused);
    try testing.expectEqual(KitOverlay.Press.taken, kit.press(8, 8));
    try testing.expectEqual(KitOverlay.Press.changed, kit.press(unlock[0], unlock[1]));
    try testing.expect(kit.holdsPress());
    try testing.expectEqual(KitOverlay.Release.lock_unlocked, kit.release(unlock[0], unlock[1]));
}

test "KitOverlay: the dialog covers the toast stack" {
    var fixture: Fixture = try .init(1);
    defer fixture.deinit();
    const kit = fixture.kit;

    _ = kit.push(.{ .title = "Copied", .duration_ms = 60_000 });
    _ = kit.tick(Theme.duration);
    _ = fixture.frame();
    _ = kit.openDialog(prompt());
    _ = kit.tick(Theme.duration);
    try testing.expect(fixture.frame());
    // Where the toast's close button was: the scrim has it now.
    try testing.expectEqual(KitOverlay.Press.scrim, kit.press(750, 550));
    try testing.expectEqual(alert_dialog.Outcome.redraw, kit.dialogInput(.dismiss));
    try testing.expect(kit.tick(Theme.duration));
    try testing.expect(fixture.frame());
    try testing.expectEqual(KitOverlay.Press.taken, kit.press(500, 550));
}

test "KitOverlay: its size" {
    // Nearly all of it is two tables: the font's kerning pairs, and
    // the painter's 2048 instances of 64 bytes with its glyph position cache.
    try testing.expectEqual(378304, @sizeOf(KitOverlay));
    try testing.expectEqual(161048, @sizeOf(@FieldType(KitOverlay, "painter")));
    try testing.expectEqual(190424, @sizeOf(@FieldType(KitOverlay, "font")));
    try testing.expectEqual(9152, @sizeOf(@FieldType(KitOverlay, "nodes")));
}

test "KitOverlay: configure applies surface options and resets toast glide table on position or layout change" {
    var fixture: Fixture = try .init(1);
    defer fixture.deinit();
    const kit = fixture.kit;

    kit.configure(.{
        .banner = .{ .placement = .docked, .position = .bottom_center, .margin = 10, .padding = 12, .max_width = 640 },
        .toast = .{ .width = 300, .position = .bottom_right, .layout = .stacked, .margin = 16, .padding = 14, .gap = 10 },
        .dialog = .{ .width = 480, .position = .top_center, .margin = 20, .padding = 22, .gap = 14, .scrim_alpha = 90 },
    });
    try testing.expectEqual(alert.Placement.docked, kit.alert.option.placement);
    try testing.expectEqual(alert.Position.bottom_center, kit.alert.option.position);
    try testing.expectEqual(@as(f32, 300), kit.toasts.option.width);
    try testing.expectEqual(toast.Layout.stacked, kit.toasts.option.layout);
    try testing.expectEqual(dialog.Position.top_center, kit.dialog.option.position);
    try testing.expectEqual(@as(?u8, 90), kit.dialog.option.scrim_alpha);

    try testing.expect(kit.push(.{ .title = "Anchored", .duration_ms = 5000 }));
    _ = kit.tick(Theme.duration);
    try testing.expect(fixture.frame());
    try testing.expect(kit.table.len > 0);

    // Same toast position and layout keeps glide memory intact; switching either clears it.
    kit.configure(.{
        .toast = .{ .width = 320, .position = .bottom_right, .layout = .stacked },
    });
    try testing.expect(kit.table.len > 0);

    kit.configure(.{
        .toast = .{ .width = 320, .position = .bottom_right, .layout = .expanded },
    });
    try testing.expectEqual(@as(usize, 0), kit.table.len);

    try testing.expect(fixture.frame());
    try testing.expect(kit.table.len > 0);
    kit.configure(.{
        .toast = .{ .width = 320, .position = .top_left, .layout = .expanded },
    });
    try testing.expectEqual(@as(usize, 0), kit.table.len);
}

test "KitOverlay: wellbeing widget toggles, drags, resizes and fires control actions" {
    var fixture: Fixture = try .init(1);
    defer fixture.deinit();
    const kit = fixture.kit;

    try testing.expect(!kit.wellbeingWidgetShown());
    try testing.expect(kit.toggleWellbeingWidget());
    try testing.expect(kit.syncWellbeingWidget(.{ .phase = .task, .run = .running, .fraction = 0.4, .seconds = 900 }));
    try testing.expect(fixture.frame());

    const card = centerOf(kit, wellbeing_widget.card_id).?;
    const orig_x = kit.wellbeing_widget.x;
    const orig_y = kit.wellbeing_widget.y;

    // Drag the card body left and down.
    try testing.expectEqual(KitOverlay.Press.taken, kit.press(card[0], card[1]));
    try testing.expect(kit.holdsPress());
    try testing.expect(kit.pointerMoved(card[0] - 80, card[1] + 50));
    try testing.expectEqual(KitOverlay.Release.redraw, kit.release(card[0] - 80, card[1] + 50));
    try testing.expect(!kit.holdsPress());
    try testing.expectEqual(orig_x - 80, kit.wellbeing_widget.x);
    try testing.expectEqual(orig_y + 50, kit.wellbeing_widget.y);
    try testing.expect(fixture.frame());

    // Drag the bottom-right corner grip inward to resize into mini horizontal grid.
    const grip = centerOf(kit, wellbeing_widget.resize_id).?;
    try testing.expectEqual(KitOverlay.Press.changed, kit.press(grip[0], grip[1]));
    try testing.expect(kit.holdsPress());
    try testing.expect(kit.pointerMoved(grip[0] - 110, grip[1] - 60));
    try testing.expectEqual(KitOverlay.Release.redraw, kit.release(grip[0] - 110, grip[1] - 60));
    try testing.expectEqual(@as(f32, 152), kit.wellbeing_widget.width);
    try testing.expectEqual(@as(f32, 76), kit.wellbeing_widget.height);
    try testing.expect(fixture.frame());

    // Leaving the widget clears hover; hovering back over play/pause shows tooltip and click toggles.
    const play = centerOf(kit, wellbeing_widget.play_pause_id).?;
    try testing.expect(kit.pointerMoved(10, 10));
    try testing.expect(fixture.frame());
    try testing.expect(kit.pointerMoved(play[0], play[1]));
    try testing.expect(fixture.frame());
    var saw_tooltip_label = false;
    for (kit.tree.nodes[0..kit.tree.len]) |node| {
        switch (node.content) {
            .text => |t| if (std.mem.eql(u8, t.bytes, "Focus")) {
                saw_tooltip_label = true;
            },
            else => {},
        }
    }
    try testing.expect(saw_tooltip_label);
    try testing.expectEqual(KitOverlay.Press.changed, kit.press(play[0], play[1]));
    try testing.expectEqual(KitOverlay.Release{ .wellbeing_widget = .toggle }, kit.release(play[0], play[1]));

    try testing.expect(kit.hideWellbeingWidget());
    try testing.expect(fixture.frame());
    try testing.expect(!fixture.frame());
}

test "KitOverlay: mini timer digits stay inside progress border across sizes" {
    var fixture: Fixture = try .init(1);
    defer fixture.deinit();
    const kit = fixture.kit;

    try testing.expect(kit.toggleWellbeingWidget());
    // 5338s -> "88:58", exercising tabular digit cell width across every mini breakpoint.
    try testing.expect(kit.syncWellbeingWidget(.{ .phase = .task, .run = .running, .fraction = 0.5, .seconds = 5338 }));

    const sizes = [_][2]f32{
        .{ 96, 96 },
        .{ 112, 112 },
        .{ 132, 132 },
        .{ 152, 152 },
        .{ 144, 72 },
        .{ 164, 82 },
        .{ 180, 90 },
        .{ 212, 106 },
        .{ 236, 118 },
    };
    for (sizes) |sz| {
        kit.wellbeing_widget.width = sz[0];
        kit.wellbeing_widget.height = sz[1];
        try testing.expect(fixture.frame());

        var tile_rect: ?Rect = null;
        var bw: f32 = 0;
        for (kit.tree.nodes[0..kit.tree.len]) |node| {
            if (node.box.id == wellbeing_widget.play_pause_id) {
                tile_rect = node.rect;
                bw = @floatFromInt(node.box.border_width);
                break;
            }
        }
        const tile = tile_rect.?;
        var saw_text = false;
        for (kit.tree.nodes[0..kit.tree.len]) |node| {
            switch (node.content) {
                .text => {
                    saw_text = true;
                    try testing.expect(node.rect.x >= tile.x + bw);
                    try testing.expect(node.rect.x + node.rect.w <= tile.x + tile.w - bw);
                    try testing.expect(node.rect.y >= tile.y + bw);
                    try testing.expect(node.rect.y + node.rect.h <= tile.y + tile.h - bw);
                },
                else => {},
            }
        }
        try testing.expect(saw_text);
    }
}

test "KitOverlay: normal widget badge stays single-line across every size and phase" {
    var fixture: Fixture = try .init(1);
    defer fixture.deinit();
    const kit = fixture.kit;

    try testing.expect(kit.toggleWellbeingWidget());

    const sizes = [_][2]f32{
        .{ 240, 120 },
        .{ 264, 132 },
        .{ 288, 144 },
        .{ 290, 144 },
        .{ 320, 160 },
    };
    const states = [_]wellbeing_widget.Snapshot{
        .{ .phase = .idle, .run = .paused, .seconds = 0 },
        .{ .phase = .task, .run = .waiting, .fraction = 0, .seconds = 1500, .tasks_in_cycle = 2, .tasks_before_long_break = 4 },
        .{ .phase = .task, .run = .running, .fraction = 0.5, .seconds = 1200, .tasks_in_cycle = 2, .tasks_before_long_break = 4 },
        .{ .phase = .short_break, .run = .paused, .fraction = 0.25, .seconds = 180, .tasks_in_cycle = 3, .tasks_before_long_break = 4 },
        .{ .phase = .long_break, .run = .running, .fraction = 0.75, .seconds = 600, .tasks_in_cycle = 4, .tasks_before_long_break = 4 },
    };

    for (sizes) |sz| {
        kit.wellbeing_widget.width = sz[0];
        kit.wellbeing_widget.height = sz[1];
        for (states) |snap| {
            _ = kit.syncWellbeingWidget(snap);
            try testing.expect(fixture.frame());
            for (kit.tree.nodes[0..kit.tree.len]) |node| {
                switch (node.content) {
                    .text => |t| try testing.expectEqual(@as(u32, 1), t.line_count),
                    else => {},
                }
            }
        }
    }
}

test "KitOverlay: pointerShape reports hand on buttons, arrow on cards, and null outside" {
    var fixture: Fixture = try .init(1);
    defer fixture.deinit();
    const kit = fixture.kit;

    const pushed = kit.pushTracked(.{ .title = "Copied", .duration_ms = 3000 });
    try testing.expect(pushed.changed);
    _ = kit.tick(Theme.duration);
    _ = fixture.frame();

    const card = kit.tree.find(toast.cardId(pushed.serial)) orelse return error.ToastCardMissing;
    const close = kit.tree.find(toast.closeId(pushed.serial)) orelse return error.ToastCloseMissing;

    // Outside both nodes.
    try testing.expectEqual(null, kit.pointerShape(100, 100));
    // Over the card body, away from the close button: arrow.
    try testing.expectEqual(.arrow, kit.pointerShape(card.rect.x + card.rect.w / 2, card.rect.y + card.rect.h / 2));
    // Over the close button: hand.
    try testing.expectEqual(.hand, kit.pointerShape(close.rect.x + close.rect.w / 2, close.rect.y + close.rect.h / 2));
}

test "KitOverlay: modal dialog pauses toast lifetime and suppresses toast wakeups" {
    var fixture: Fixture = try .init(1);
    defer fixture.deinit();
    const kit = fixture.kit;

    const pushed = kit.pushTracked(.{ .title = "Saved", .duration_ms = 2000 });
    try testing.expect(pushed.changed);
    _ = kit.tick(Theme.duration);
    try testing.expectEqual(@as(?u32, 2000), kit.wakeMs());

    // Advance near expiry: 500 ms left.
    try testing.expect(!kit.tick(1500));
    try testing.expectEqual(@as(?u32, 500), kit.wakeMs());

    // Open dialog and let it settle; scrim suppresses toast wakeups and freezes its countdown.
    try testing.expect(kit.openDialog(prompt()));
    _ = kit.tick(Theme.duration);
    try testing.expect(kit.hasScrim());
    try testing.expectEqual(@as(?u32, null), kit.wakeMs());

    try testing.expect(!kit.tick(5000));
    try testing.expectEqual(@as(usize, 1), kit.toasts.visible().len);
    try testing.expectEqual(pushed.serial, kit.toasts.entries[0].serial);
    try testing.expectEqual(toast.Phase{ .shown = 500 }, kit.toasts.entries[0].phase);
    try testing.expectEqual(@as(?u32, null), kit.wakeMs());

    // Dismiss dialog and let it finish leaving; toast resumes with its remaining 500 ms.
    try testing.expectEqual(alert_dialog.Outcome.redraw, kit.dialogInput(.dismiss));
    _ = kit.tick(Theme.duration);
    try testing.expect(!kit.hasScrim());
    try testing.expectEqual(@as(?u32, 500), kit.wakeMs());

    try testing.expect(!kit.tick(499));
    try testing.expectEqual(@as(?u32, 1), kit.wakeMs());
    try testing.expect(kit.tick(1));
    try testing.expectEqual(toast.Phase{ .leaving = 0 }, kit.toasts.entries[0].phase);
    try testing.expectEqual(@as(?u32, motion.frame_ms), kit.wakeMs());
    try testing.expect(kit.tick(Theme.duration));
    try testing.expectEqual(@as(u8, 0), kit.toasts.len);
    try testing.expectEqual(@as(?u32, null), kit.wakeMs());
}

test "KitOverlay: lock screen pauses toast lifetime and suppresses toast wakeups" {
    var fixture: Fixture = try .init(1);
    defer fixture.deinit();
    const kit = fixture.kit;

    const pushed = kit.pushTracked(.{ .title = "Copied", .duration_ms = 2000 });
    try testing.expect(pushed.changed);
    _ = kit.tick(Theme.duration);
    try testing.expect(!kit.tick(1000));
    try testing.expectEqual(@as(?u32, 1000), kit.wakeMs());

    try testing.expect(kit.syncLockScreen(.{
        .title = "Break time",
        .subtitle = "Focus cycle 1 of 4",
        .prompt = "Look away.",
        .remaining_s = 15,
        .total_s = 20,
        .steps_total = 4,
        .steps_done = 1,
    }));
    _ = kit.tick(Theme.duration);
    try testing.expect(kit.hasScrim());
    try testing.expectEqual(@as(?u32, null), kit.wakeMs());

    try testing.expect(!kit.tick(5000));
    try testing.expectEqual(pushed.serial, kit.toasts.entries[0].serial);
    try testing.expectEqual(toast.Phase{ .shown = 1000 }, kit.toasts.entries[0].phase);
    try testing.expectEqual(@as(?u32, null), kit.wakeMs());

    try testing.expect(kit.closeLockScreen());
    _ = kit.tick(Theme.duration);
    try testing.expect(!kit.hasScrim());
    try testing.expectEqual(@as(?u32, 1000), kit.wakeMs());

    try testing.expect(kit.tick(1000));
    try testing.expect(kit.tick(Theme.duration));
    try testing.expectEqual(@as(u8, 0), kit.toasts.len);
}

test "KitOverlay: hovering a stacked toast deck triggers redraw, expands, and collapses on leave" {
    var fixture: Fixture = try .init(1);
    defer fixture.deinit();
    const kit = fixture.kit;

    const first = kit.pushTracked(.{ .title = "Older", .duration_ms = 60_000 });
    const second = kit.pushTracked(.{ .title = "Front", .duration_ms = 60_000 });
    _ = kit.tick(Theme.duration);
    try testing.expect(fixture.frame());

    const front_rect = kit.tree.find(toast.cardId(second.serial)).?.rect;
    const older_collapsed = kit.tree.find(toast.cardId(first.serial)).?.rect;
    try testing.expect(older_collapsed.w < front_rect.w);

    // Hovering over the front card requests a redraw and begins smooth expansion.
    try testing.expect(kit.pointerMoved(front_rect.x + 40, front_rect.y + front_rect.h / 2));
    try testing.expect(fixture.frame());
    try testing.expectEqual(toast.Motion.moving, kit.motion);
    try testing.expectEqual(@as(?u32, motion.frame_ms), kit.wakeMs());

    // Advance until settled; older card now matches front width and sits above with gap.
    _ = kit.tick(400);
    try testing.expect(fixture.frame());
    try testing.expectEqual(toast.Motion.settled, kit.motion);
    const older_expanded = kit.tree.find(toast.cardId(first.serial)).?.rect;
    try testing.expectApproxEqAbs(front_rect.w, older_expanded.w, 1e-3);
    try testing.expect(older_expanded.y < older_collapsed.y);

    // Leaving the window triggers redraw and collapses back.
    try testing.expect(kit.pointerLeft());
    try testing.expect(fixture.frame());
    try testing.expectEqual(toast.Motion.moving, kit.motion);
}

test "KitOverlay: configure applies wellbeing_widget options and renders all progress styles" {
    var fixture: Fixture = try .init(1);
    defer fixture.deinit();
    const kit = fixture.kit;

    try testing.expect(kit.toggleWellbeingWidget());
    try testing.expect(kit.syncWellbeingWidget(.{
        .phase = .task,
        .run = .running,
        .fraction = 0.5,
        .seconds = 750,
        .tasks_in_cycle = 1,
        .tasks_before_long_break = 4,
    }));

    for ([_]wellbeing_widget.ProgressStyle{ .auto, .bar, .ring, .border, .half_rings, .coil }) |style| {
        kit.configure(.{
            .wellbeing_widget = .{
                .default_width = 264,
                .default_height = 132,
                .anchor = .top_left,
                .progress_style = style,
                .tooltip = false,
            },
        });
        try testing.expectEqual(style, kit.wellbeing_widget.option.progress_style);
        try testing.expectEqual(.top_left, kit.wellbeing_widget.option.anchor);
        try testing.expect(!kit.wellbeing_widget.option.tooltip);
        try testing.expect(fixture.frame());
        const card = kit.tree.find(wellbeing_widget.card_id).?;
        try testing.expectEqual(Rect{ .x = 16, .y = 16, .w = 264, .h = 132 }, card.rect);
    }
}
