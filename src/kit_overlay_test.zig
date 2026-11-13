//! The UI kit's glue as the app drives it, with the real font and a GL
//! context but no window content: frames are built, not looked at (the
//! pixels are checked in `renderer/kit_painter_test.zig`).

const std = @import("std");
const testing = std.testing;

const Atlas = @import("renderer/Atlas.zig");
const testGlContext = @import("renderer/Window.zig").testGlContext;
const KitOverlay = @import("KitOverlay.zig");
const dialog = @import("kit/dialog.zig");
const modal = @import("kit/modal.zig");
const toast = @import("kit/toast.zig");
const Theme = @import("kit/Theme.zig");
const motion = @import("kit/motion.zig");
const Id = @import("kit/tree.zig").Id;

const inter: @import("freetype/KitFont.zig").Files = .{
    .regular = "assets/fonts/Inter-Regular.ttf",
    .medium = "assets/fonts/Inter-Medium.ttf",
    .semibold = "assets/fonts/Inter-SemiBold.ttf",
    .icons = "assets/fonts/lucide.ttf",
};

const dark: [3]u8 = .{ 0x10, 0x10, 0x14 };

const Fixture = struct {
    atlas: Atlas,
    kit: *KitOverlay,

    fn init(scale: f32) !Fixture {
        try testGlContext();
        var atlas = try Atlas.create(testing.allocator, .{ .width = 512, .height = 512 });
        errdefer atlas.destroy();
        return .{ .atlas = atlas, .kit = try KitOverlay.create(testing.allocator, inter, scale) };
    }

    fn deinit(self: *Fixture) void {
        self.kit.destroy(testing.allocator);
        self.atlas.destroy();
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
    const confirm = centerOf(kit, dialog.actionId(1)).?;
    try testing.expect(kit.pointerMoved(confirm[0], confirm[1]));
    try testing.expectEqual(1, kit.dialog.hover);
    try testing.expect(kit.pointerLeft());
    try testing.expectEqual(dialog.no_action, kit.dialog.hover);
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

const prompt_actions = [_]dialog.Action{
    .{ .label = "Cancel", .role = .dismiss, .key_cap = "Esc" },
    .{ .label = "Close window", .variant = .destructive },
};

fn prompt() dialog.Request {
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

    try testing.expectEqual(dialog.Outcome.redraw, kit.dialogInput(.dismiss));
    try testing.expectEqual(motion.frame_ms, kit.wakeMs());
    // Keys do nothing while it is leaving.
    try testing.expectEqual(dialog.Outcome.quiet, kit.dialogInput(.activate));
    try testing.expect(!kit.dialogTakesInput());
    try testing.expect(kit.tick(Theme.duration));
    try testing.expectEqual(modal.Phase.closed, kit.dialog.phase);
    try testing.expect(!kit.tick(16));
}

test "KitOverlay: confirming a dialog closes it, the scrim does not" {
    var fixture: Fixture = try .init(1);
    defer fixture.deinit();
    const kit = fixture.kit;

    _ = kit.openDialog(prompt());
    _ = kit.tick(Theme.duration);
    try testing.expect(fixture.frame());
    const confirm = centerOf(kit, dialog.actionId(1)).?;
    const cancel = centerOf(kit, dialog.actionId(0)).?;
    try testing.expect(confirm[0] > cancel[0]);

    try testing.expect(kit.pointerMoved(confirm[0], confirm[1]));
    try testing.expect(!kit.pointerMoved(confirm[0], confirm[1]));
    try testing.expectEqual(KitOverlay.Press.scrim, kit.press(4, 4));
    try testing.expectEqual(modal.Phase.open, kit.dialog.phase);
    // The card, off both buttons: the ring drops and the dialog stays.
    const card = centerOf(kit, dialog.card_id).?;
    try testing.expectEqual(1, kit.dialog.focus);
    try testing.expectEqual(KitOverlay.Press.changed, kit.press(card[0], card[1]));
    try testing.expectEqual(dialog.no_action, kit.dialog.focus);
    try testing.expectEqual(KitOverlay.Press.taken, kit.press(card[0], card[1]));
    try testing.expectEqual(modal.Phase.open, kit.dialog.phase);
    // Going down on the button only presses it; letting go takes it.
    try testing.expect(!kit.holdsPress());
    try testing.expectEqual(KitOverlay.Press.changed, kit.press(confirm[0], confirm[1]));
    try testing.expect(kit.holdsPress());
    try testing.expectEqual(modal.Phase.open, kit.dialog.phase);
    // Moved off before letting go: nothing is taken.
    _ = kit.pointerMoved(card[0], card[1]);
    try testing.expectEqual(dialog.Outcome.quiet, kit.release());
    try testing.expect(!kit.holdsPress());
    try testing.expectEqual(modal.Phase.open, kit.dialog.phase);
    try testing.expectEqual(KitOverlay.Press.changed, kit.press(confirm[0], confirm[1]));
    try testing.expectEqual(dialog.Outcome{ .chosen = 1 }, kit.release());
    try testing.expectEqual(modal.Phase.closed, kit.dialog.phase);
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
    try testing.expectEqual(dialog.Outcome.redraw, kit.dialogInput(.dismiss));
    try testing.expect(kit.tick(Theme.duration));
    try testing.expect(fixture.frame());
    try testing.expectEqual(KitOverlay.Press.taken, kit.press(500, 550));
}

test "KitOverlay: its size" {
    // Reported in the ticket. Nearly all of it is two tables: the font's
    // kerning pairs, and the painter's 2048 instances of 36 bytes with its
    // glyph position cache.
    try testing.expectEqual(202520, @sizeOf(KitOverlay));
    try testing.expectEqual(92184, @sizeOf(@FieldType(KitOverlay, "painter")));
    try testing.expectEqual(95592, @sizeOf(@FieldType(KitOverlay, "font")));
    try testing.expectEqual(2600, @sizeOf(@FieldType(KitOverlay, "nodes")));
}
