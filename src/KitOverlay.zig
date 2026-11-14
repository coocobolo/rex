//! The UI kit's surfaces inside a terminal window (ADR 0009):
//! the persistent alert banner, toast stack, modal dialog and lock screen.
//! It owns the UI font, the painter, the node array and each surface's state,
//! and is what `App` talks to.
//!
//! One frame is `buildFrame` (view, layout, motion, paint into the
//! painter's instance array) and, after the terminal is drawn, `draw`.
//! Nothing allocates after `create`.
//!
//! The object points into itself (`tree` into `nodes` and `lines`), so it
//! lives on the heap and is never copied.

const KitOverlay = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const Atlas = @import("renderer/Atlas.zig");
const KitPainter = @import("renderer/KitPainter.zig");
const KitFont = @import("freetype/KitFont.zig");
const Theme = @import("kit/Theme.zig");
const layout = @import("kit/layout.zig");
const memory = @import("kit/memory.zig");
const motion_zig = @import("kit/motion.zig");
const text = @import("kit/text.zig");
const alert_mod = @import("kit/alert.zig");
const alert_dialog = @import("kit/alert_dialog.zig");
const lock_mod = @import("kit/lock_screen.zig");
const toast = @import("kit/toast.zig");
const tree_zig = @import("kit/tree.zig");
const Ui = @import("config/Config.zig").Ui;

const log = std.log.scoped(.kit_overlay);

/// Nodes and lines of wrapped text one frame can hold: enough for the worst
/// combination of simultaneously visible surfaces (alert banner + toast stack,
/// or modal dialog / lock screen).
const node_capacity = @max(@max(alert_mod.node_max + toast.node_max, alert_dialog.node_max), lock_mod.node_max);
const line_capacity = @max(@max(alert_mod.line_max + toast.line_max, alert_dialog.line_max), lock_mod.line_max);

font: KitFont,
painter: KitPainter,
/// Lock screen and modal dialogs take the full frame under a scrim; alert
/// banner and toast stack share non-scrim frames.
nodes: [node_capacity]tree_zig.Node = undefined,
lines: [line_capacity]text.Line = undefined,
/// The last built frame, for hit-testing. Empty after `skipFrame`.
tree: tree_zig.Tree,
toasts: toast.State = .empty,
alert: alert_mod.State = .empty,
dialog: alert_dialog.State = .empty,
lock_screen: lock_mod.State = .empty,
/// Where each toast was last drawn.
table: memory.Table = .empty,
/// Milliseconds ticked since the last built frame while a toast was
/// gliding: how far the glide advances in the next one. Time that passes
/// at rest does not count, or a glide that starts after a long rest would
/// be over in its first frame.
elapsed_ms: u32 = 0,
/// Whether the last built frame left a toast short of its place.
motion: toast.Motion = .settled,
color_scheme: Theme.ColorScheme = .auto,

pub const CreateError = Allocator.Error || @import("freetype/root.zig").FtError || @import("renderer/Shader.zig").Error;

/// Needs a current GL context. `scale` is the window's display scale.
pub fn create(gpa: Allocator, files: KitFont.Files, scale: f32) CreateError!*KitOverlay {
    const self = try gpa.create(KitOverlay);
    errdefer gpa.destroy(self);
    var font = try KitFont.create(files, .{ .scale = scale });
    errdefer font.destroy();
    self.* = .{
        .font = font,
        .painter = try KitPainter.init(),
        .tree = undefined,
    };
    self.tree = .init(&self.nodes, &self.lines);
    return self;
}

pub fn destroy(self: *KitOverlay, gpa: Allocator) void {
    self.painter.deinit();
    self.font.destroy();
    gpa.destroy(self);
}

/// Applies the user's `[ui]` settings, from the next frame on.
pub fn configure(self: *KitOverlay, ui: Ui) void {
    self.toasts.motion = ui.motion;
    self.alert.motion = ui.motion;
    self.dialog.motion = ui.motion;
    self.lock_screen.motion = ui.motion;
    self.color_scheme = ui.color_scheme;
}

/// Shows or updates the persistent alert banner. Returns whether a redraw is due.
pub fn showAlert(self: *KitOverlay, request: alert_mod.Request) bool {
    return alert_mod.update(&self.alert, .{ .show = request });
}

/// Dismisses the persistent alert banner. Returns whether a redraw is due.
pub fn dismissAlert(self: *KitOverlay) bool {
    return alert_mod.update(&self.alert, .dismiss);
}

pub fn alertShown(self: *const KitOverlay) bool {
    return self.alert.isShown();
}

/// Shows or updates the wellbeing lock screen. Returns whether a redraw is due.
pub fn syncLockScreen(self: *KitOverlay, request: lock_mod.Request) bool {
    const outcome = lock_mod.update(&self.lock_screen, .{ .sync = request });
    if (outcome != .redraw) return false;
    _ = toast.update(&self.toasts, .{ .pointer = .away });
    _ = alert_mod.update(&self.alert, .{ .pointer = .away });
    return true;
}

pub fn closeLockScreen(self: *KitOverlay) bool {
    return lock_mod.update(&self.lock_screen, .close) == .redraw;
}

pub fn lockScreenInput(self: *KitOverlay, event: lock_mod.Event) lock_mod.Outcome {
    return lock_mod.update(&self.lock_screen, event);
}

pub fn lockScreenShown(self: *const KitOverlay) bool {
    return self.lock_screen.isShown();
}

pub fn lockScreenTakesInput(self: *const KitOverlay) bool {
    return self.lock_screen.acceptsInput();
}

/// Whether a modal scrim (lock screen or alert dialog) currently covers the window.
pub fn hasScrim(self: *const KitOverlay) bool {
    return self.lock_screen.isShown() or self.dialog.phase != .closed;
}

/// Shows a toast. Returns whether a redraw is due.
pub fn push(self: *KitOverlay, request: toast.Push) bool {
    return toast.update(&self.toasts, .{ .push = request });
}

/// Shows a toast and returns its assigned serial along with whether a redraw
/// is due, so callers can track or dismiss that specific entry later.
pub fn pushTracked(self: *KitOverlay, request: toast.Push) struct { changed: bool, serial: u32 } {
    const serial = self.toasts.next_serial;
    const changed = toast.update(&self.toasts, .{ .push = request });
    return .{ .changed = changed, .serial = serial };
}

/// Whether toast `serial` is still queued or visible and not yet leaving.
pub fn hasToast(self: *const KitOverlay, serial: u32) bool {
    for (self.toasts.entries[0..self.toasts.len]) |entry| {
        if (entry.serial == serial) return entry.phase != .leaving;
    }
    return false;
}

/// Dismisses toast `serial`. Returns whether a redraw is due.
pub fn dismissToast(self: *KitOverlay, serial: u32) bool {
    return toast.update(&self.toasts, .{ .dismiss = serial });
}

/// Asks `request` in the dialog. Returns whether a redraw is due.
/// A dialog that is already up keeps its own question.
pub fn openDialog(self: *KitOverlay, request: alert_dialog.Request) bool {
    if (alert_dialog.update(&self.dialog, .{ .open = request }) != .redraw) return false;
    // The scrim is between the pointer and the stack/banner now.
    _ = toast.update(&self.toasts, .{ .pointer = .away });
    _ = alert_mod.update(&self.alert, .{ .pointer = .away });
    return true;
}

/// Sends the dialog an event the caller made from a key or a click, and
/// returns what it did: on `.chosen` the caller does what that action
/// stands for.
pub fn dialogInput(self: *KitOverlay, event: alert_dialog.Event) alert_dialog.Outcome {
    return alert_dialog.update(&self.dialog, event);
}

/// Whether the dialog is up and taking keys and clicks. False from the
/// moment it starts to fade out: input is the terminal's again by then.
pub fn dialogTakesInput(self: *const KitOverlay) bool {
    return self.dialog.phase.acceptsInput();
}

/// Advances timers and motion by `dt_ms`. Returns whether a redraw is due.
/// While a modal scrim is up the non-scrim surfaces' motion stands still.
pub fn tick(self: *KitOverlay, dt_ms: u64) bool {
    const dt = std.math.lossyCast(u32, dt_ms);
    const scrim_up = self.hasScrim();
    if (scrim_up) {
        self.elapsed_ms = 0;
        self.motion = .settled;
    } else {
        self.elapsed_ms = switch (self.motion) {
            .moving => self.elapsed_ms +| dt,
            .settled => 0,
        };
    }
    const toasts_changed = toast.update(&self.toasts, .{ .tick = dt });
    const alert_changed = alert_mod.update(&self.alert, .{ .tick = dt });
    const dialog_changed = if (self.dialog.phase != .closed) alert_dialog.update(&self.dialog, .{ .tick = dt }) != .quiet else false;
    const lock_changed = if (self.lock_screen.isShown()) lock_mod.update(&self.lock_screen, .{ .tick = dt }) != .quiet else false;
    return dialog_changed or lock_changed or (!scrim_up and (toasts_changed or alert_changed or self.motion == .moving));
}

fn minWake(a: ?u32, b: ?u32) ?u32 {
    return if (a) |av| (if (b) |bv| @min(av, bv) else av) else b;
}

/// Milliseconds until `tick` has something to do, or null when only an
/// event can change what is shown.
pub fn wakeMs(self: *const KitOverlay) ?u32 {
    var best: ?u32 = self.lock_screen.wakeMs();
    best = minWake(best, self.dialog.phase.wakeMs());
    best = minWake(best, self.alert.wakeMs());
    if (!self.hasScrim() and self.motion == .moving) {
        best = minWake(best, motion_zig.frame_ms);
    }
    best = minWake(best, self.toasts.wakeMs());
    return best;
}

/// The pointer moved to `x`, `y` in logical pixels. Returns whether a
/// redraw is due. Toasts keep their time while it is over one of them.
pub fn pointerMoved(self: *KitOverlay, x: f32, y: f32) bool {
    const id = self.tree.hitTest(x, y);
    if (self.lock_screen.isShown()) {
        const over: lock_mod.Pointer = if (self.lock_screen.hit(id) == .unlock) .unlock else .away;
        return lock_mod.update(&self.lock_screen, .{ .pointer = over }) == .redraw;
    }
    if (self.dialog.phase != .closed) {
        const over: u8 = switch (alert_dialog.hit(id) orelse return false) {
            .action => |index| index,
            .scrim, .card => alert_dialog.no_action,
        };
        return alert_dialog.update(&self.dialog, .{ .pointer = over }) == .redraw;
    }
    const alert_over: alert_mod.Pointer = if (self.alert.hit(id) == .close) .close else .away;
    const alert_changed = alert_mod.update(&self.alert, .{ .pointer = alert_over });
    const over = self.toasts.hit(id) != .none;
    _ = toast.update(&self.toasts, .{ .pointer = if (over) .over else .away });
    return alert_changed;
}

/// The pointer left the window. Returns whether a redraw is due.
pub fn pointerLeft(self: *KitOverlay) bool {
    _ = toast.update(&self.toasts, .{ .pointer = .away });
    const alert_changed = alert_mod.update(&self.alert, .{ .pointer = .away });
    const dialog_changed = alert_dialog.update(&self.dialog, .{ .pointer = alert_dialog.no_action }) == .redraw;
    const lock_changed = lock_mod.update(&self.lock_screen, .{ .pointer = .away }) == .redraw;
    return alert_changed or dialog_changed or lock_changed;
}

pub const Press = union(enum) {
    /// Not on the kit's UI: the press belongs to the terminal.
    outside,
    /// Taken by the kit, nothing to redraw.
    taken,
    /// Taken by the kit, and a redraw is due.
    changed,
    /// On the scrim around the dialog. Nothing happened yet: the caller
    /// decides whether that dismisses it.
    scrim,
};

pub const Release = union(enum) {
    quiet,
    redraw,
    dialog: alert_dialog.Outcome,
    lock_unlocked,
};

/// The left button went down at `x`, `y` in logical pixels. Buttons only look
/// pressed from here on; `release` is what takes them.
pub fn press(self: *KitOverlay, x: f32, y: f32) Press {
    const id = self.tree.hitTest(x, y);
    if (self.lock_screen.isShown()) {
        return switch (self.lock_screen.hit(id)) {
            .unlock => if (lock_mod.update(&self.lock_screen, .press) == .redraw) .changed else .taken,
            .scrim, .card, .none => if (lock_mod.update(&self.lock_screen, .blur) == .redraw) .changed else .taken,
        };
    }
    if (self.dialog.phase != .closed) {
        return switch (alert_dialog.hit(id) orelse return .taken) {
            .action => |index| if (alert_dialog.update(&self.dialog, .{ .press = index }) == .redraw) .changed else .taken,
            .scrim => .scrim,
            .card => if (alert_dialog.update(&self.dialog, .blur) == .redraw) .changed else .taken,
        };
    }
    switch (self.alert.hit(id)) {
        .close => return if (alert_mod.update(&self.alert, .press)) .changed else .taken,
        .card => return .taken,
        .none => {},
    }
    switch (self.toasts.hit(id)) {
        .none => return .outside,
        .toast => return .taken,
        .close => |serial| return if (toast.update(&self.toasts, .{ .dismiss = serial })) .changed else .taken,
    }
}

/// Whether the left button went down on a kit button and has not been
/// let go: its release is the kit's, wherever the pointer is by then.
pub fn holdsPress(self: *const KitOverlay) bool {
    return self.lock_screen.touch == .pressed or
        self.dialog.pressed != alert_dialog.no_action or
        self.alert.touch == .pressed;
}

/// The left button was let go after a press the kit holds at `(x, y)`.
pub fn release(self: *KitOverlay, x: f32, y: f32) Release {
    if (self.lock_screen.touch == .pressed) {
        const id = self.tree.hitTest(x, y);
        const over: lock_mod.Pointer = if (self.lock_screen.hit(id) == .unlock) .unlock else .away;
        return switch (lock_mod.update(&self.lock_screen, .{ .release = over })) {
            .quiet => .quiet,
            .redraw => .redraw,
            .unlocked => .lock_unlocked,
        };
    }
    if (self.alert.touch == .pressed) {
        const id = self.tree.hitTest(x, y);
        const over: alert_mod.Pointer = if (self.alert.hit(id) == .close) .close else .away;
        return if (alert_mod.update(&self.alert, .{ .release = over })) .redraw else .quiet;
    }
    if (self.dialog.pressed != alert_dialog.no_action) {
        return .{ .dialog = alert_dialog.update(&self.dialog, .release) };
    }
    return .quiet;
}

/// Dismisses the oldest toast that is not already leaving. Returns whether
/// there was one, which is also when a redraw is due.
pub fn dismissOldest(self: *KitOverlay) bool {
    for (self.toasts.visible()) |entry| {
        if (entry.phase == .leaving) continue;
        return toast.update(&self.toasts, .{ .dismiss = entry.serial });
    }
    return false;
}

/// Returns whether a redraw is due.
pub fn dismissAll(self: *KitOverlay) bool {
    return toast.update(&self.toasts, .dismiss_all);
}

/// The display scale changed, or the atlas was cleared (pass the current
/// scale): glyphs are rasterized again at `scale` on their next use.
pub fn glyphsLost(self: *KitOverlay, scale: f32) void {
    self.painter.clearGlyphs();
    self.font.setScale(scale) catch |err| {
        log.err("cannot size the UI font for scale {d:.2}: {t}", .{ scale, err });
    };
}

/// Builds this frame's UI for a window of `width` by `height` logical
/// pixels over a terminal whose background is `background` (sRGB).
/// Returns whether the window has to be drawn for the kit's sake: there
/// is UI to draw, or the last frame's to take away.
pub fn buildFrame(self: *KitOverlay, atlas: *Atlas, width: f32, height: f32, background: [3]u8) bool {
    const dt_ms = self.elapsed_ms;
    self.elapsed_ms = 0;
    const drawn_before = self.painter.len > 0;
    self.painter.begin();
    self.tree.reset();
    self.build(atlas, width, height, self.color_scheme.variant(background).theme(), dt_ms) catch |err| {
        // The same state would fail the same way every frame.
        if (self.lock_screen.isShown()) {
            log.err("cannot show the lock screen, dropping it: {t}", .{err});
            self.lock_screen = .empty;
        } else if (self.dialog.phase != .closed) {
            log.err("cannot show the dialog, dropping it: {t}", .{err});
            self.dialog = .empty;
        } else {
            log.err("cannot show overlays ({d} toasts), dropping them: {t}", .{ self.toasts.len, err });
            self.alert = .empty;
            self.toasts = .empty;
        }
        _ = self.skipFrame();
    };
    return drawn_before or self.painter.len > 0;
}

fn build(self: *KitOverlay, atlas: *Atlas, width: f32, height: f32, theme: *const Theme, dt_ms: u32) !void {
    if (self.lock_screen.isShown()) {
        try lock_mod.view(&self.lock_screen, &self.tree, theme);
        try layout.layout(&self.tree, self.font.measurer(), width, height);
        self.motion = .settled;
        try self.painter.paint(&self.tree, &self.font, atlas);
        return;
    }
    if (self.dialog.phase != .closed) {
        // The scrim covers the window, so non-modal surfaces are not built.
        _ = try alert_dialog.view(&self.dialog, &self.tree, theme);
        try layout.layout(&self.tree, self.font.measurer(), width, height);
        self.motion = .settled;
        try self.painter.paint(&self.tree, &self.font, atlas);
        return;
    }
    const banner = try alert_mod.view(&self.alert, &self.tree, theme);
    const stack = try toast.view(&self.toasts, &self.tree, theme);
    try layout.layout(&self.tree, self.font.measurer(), width, height);
    alert_mod.place(&self.alert, &self.tree, banner);
    self.motion = try toast.place(&self.toasts, &self.tree, stack, &self.table, dt_ms);
    try self.painter.paint(&self.tree, &self.font, atlas);
}

/// A frame in which the kit's UI is hidden: nothing is drawn and nothing
/// can be hit. Returns whether the last frame's UI has to be taken away.
pub fn skipFrame(self: *KitOverlay) bool {
    const drawn_before = self.painter.len > 0;
    self.painter.begin();
    self.tree.reset();
    self.motion = .settled;
    return drawn_before;
}

/// Draws what `buildFrame` built into the bound framebuffer of `width` by
/// `height` physical pixels.
pub fn draw(self: *const KitOverlay, atlas: *const Atlas, width: f32, height: f32) void {
    self.painter.draw(atlas, width, height);
}
