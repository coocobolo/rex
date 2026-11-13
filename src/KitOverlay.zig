//! The UI kit's surfaces inside a terminal window (trial of ADR 0009):
//! the toast stack and one dialog. It owns the UI font, the
//! painter, the node array and each surface's state, and is what `App`
//! talks to. `App` only creates one when `REX_UI_KIT=1` is in the
//! environment, so the default window pays nothing for it.
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
const alert_dialog = @import("kit/alert_dialog.zig");
const toast = @import("kit/toast.zig");
const tree_zig = @import("kit/tree.zig");
const Ui = @import("config/Config.zig").Ui;

const log = std.log.scoped(.kit_overlay);

/// Lines of wrapped text one frame can hold: enough for the worst texts
/// either surface accepts, so a text of nothing but line feeds still
/// shows. A frame holds the dialog or the stack, never both.
const line_capacity = @max(toast.line_max, alert_dialog.line_max);

font: KitFont,
painter: KitPainter,
nodes: [toast.node_max]tree_zig.Node = undefined,
lines: [line_capacity]text.Line = undefined,
/// The last built frame, for hit-testing. Empty after `skipFrame`.
tree: tree_zig.Tree,
toasts: toast.State = .empty,
dialog: alert_dialog.State = .empty,
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

comptime {
    // A frame shows the dialog or the toast stack, never both, so `nodes`
    // is sized for the stack and the dialog has to fit in it.
    if (alert_dialog.node_max > toast.node_max) @compileError("dialog does not fit the kit node buffer");
}

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
    self.dialog.motion = ui.motion;
    self.color_scheme = ui.color_scheme;
}

/// Shows a toast. Returns whether a redraw is due.
pub fn push(self: *KitOverlay, request: toast.Push) bool {
    return toast.update(&self.toasts, .{ .push = request });
}

/// Asks `request` in the dialog. Returns whether a redraw is due.
/// A dialog that is already up keeps its own question.
pub fn openDialog(self: *KitOverlay, request: alert_dialog.Request) bool {
    if (alert_dialog.update(&self.dialog, .{ .open = request }) != .redraw) return false;
    // The scrim is between the pointer and the stack now: a toast it was
    // resting on runs its time again.
    _ = toast.update(&self.toasts, .{ .pointer = .away });
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
/// While the dialog is up the toasts' glide stands still, so the time
/// the dialog took is not spent on it in one step afterwards.
pub fn tick(self: *KitOverlay, dt_ms: u64) bool {
    const dt = std.math.lossyCast(u32, dt_ms);
    const dialog_up = self.dialog.phase != .closed;
    if (dialog_up) {
        self.elapsed_ms = 0;
        self.motion = .settled;
    } else {
        self.elapsed_ms = switch (self.motion) {
            .moving => self.elapsed_ms +| dt,
            .settled => 0,
        };
    }
    const toasts_changed = toast.update(&self.toasts, .{ .tick = dt });
    if (!dialog_up) return toasts_changed or self.motion == .moving;
    return toasts_changed or alert_dialog.update(&self.dialog, .{ .tick = dt }) != .quiet;
}

/// Milliseconds until `tick` has something to do, or null when only an
/// event can change what is shown.
pub fn wakeMs(self: *const KitOverlay) ?u32 {
    if (self.dialog.phase.wakeMs()) |ms| return ms;
    if (self.motion == .moving) return motion_zig.frame_ms;
    return self.toasts.wakeMs();
}

/// The pointer moved to `x`, `y` in logical pixels. Returns whether a
/// redraw is due, which is when it came onto or off a dialog button.
/// Toasts keep their time while it is over one of them.
pub fn pointerMoved(self: *KitOverlay, x: f32, y: f32) bool {
    const id = self.tree.hitTest(x, y);
    if (self.dialog.phase != .closed) {
        const over: u8 = switch (alert_dialog.hit(id) orelse return false) {
            .action => |index| index,
            .scrim, .card => alert_dialog.no_action,
        };
        return alert_dialog.update(&self.dialog, .{ .pointer = over }) == .redraw;
    }
    const over = self.toasts.hit(id) != .none;
    _ = toast.update(&self.toasts, .{ .pointer = if (over) .over else .away });
    return false;
}

/// The pointer left the window. Returns whether a redraw is due, which is
/// when it left from a dialog button. A toast it left from runs its time
/// again; `wakeMs` says when.
pub fn pointerLeft(self: *KitOverlay) bool {
    _ = toast.update(&self.toasts, .{ .pointer = .away });
    return alert_dialog.update(&self.dialog, .{ .pointer = alert_dialog.no_action }) == .redraw;
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

/// The left button went down at `x`, `y` in logical pixels. A dialog
/// button only looks pressed from here on; `release` is what takes it.
pub fn press(self: *KitOverlay, x: f32, y: f32) Press {
    const id = self.tree.hitTest(x, y);
    if (self.dialog.phase != .closed) {
        return switch (alert_dialog.hit(id) orelse return .taken) {
            .action => |index| if (alert_dialog.update(&self.dialog, .{ .press = index }) == .redraw) .changed else .taken,
            .scrim => .scrim,
            .card => if (alert_dialog.update(&self.dialog, .blur) == .redraw) .changed else .taken,
        };
    }
    switch (self.toasts.hit(id)) {
        .none => return .outside,
        .toast => return .taken,
        .close => |serial| return if (toast.update(&self.toasts, .{ .dismiss = serial })) .changed else .taken,
    }
}

/// Whether the left button went down on a dialog button and has not been
/// let go: its release is the kit's, wherever the pointer is by then.
pub fn holdsPress(self: *const KitOverlay) bool {
    return self.dialog.pressed != alert_dialog.no_action;
}

/// The left button was let go after a press the kit holds. Returns what
/// the dialog did: on `.chosen` the caller does what that action stands
/// for.
pub fn release(self: *KitOverlay) alert_dialog.Outcome {
    return alert_dialog.update(&self.dialog, .release);
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
        if (self.dialog.phase != .closed) {
            log.err("cannot show the dialog, dropping it: {t}", .{err});
            self.dialog = .empty;
        } else {
            log.err("cannot show {d} toasts, dropping them: {t}", .{ self.toasts.len, err });
            self.toasts = .empty;
        }
        _ = self.skipFrame();
    };
    return drawn_before or self.painter.len > 0;
}

fn build(self: *KitOverlay, atlas: *Atlas, width: f32, height: f32, theme: *const Theme, dt_ms: u32) !void {
    if (self.dialog.phase != .closed) {
        // The scrim covers the window, so the toast stack is not built.
        _ = try alert_dialog.view(&self.dialog, &self.tree, theme);
        try layout.layout(&self.tree, self.font.measurer(), width, height);
        self.motion = .settled;
        try self.painter.paint(&self.tree, &self.font, atlas);
        return;
    }
    const stack = try toast.view(&self.toasts, &self.tree, theme);
    try layout.layout(&self.tree, self.font.measurer(), width, height);
    self.motion = try toast.place(&self.toasts, &self.tree, stack, &self.table, dt_ms);
    try self.painter.paint(&self.tree, &self.font, atlas);
}

/// A frame in which the kit's UI is hidden (the lock screen covers the
/// window): nothing is drawn and nothing can be hit. Returns whether the
/// last frame's UI has to be taken away.
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
