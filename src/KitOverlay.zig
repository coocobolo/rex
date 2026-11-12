//! The UI kit's surfaces inside a terminal window (trial of ADR 0009):
//! the toast stack and one confirm dialog. It owns the UI font, the
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
const confirm = @import("kit/dialog.zig");
const toast = @import("kit/toast.zig");
const tree_zig = @import("kit/tree.zig");

const log = std.log.scoped(.kit_overlay);

/// Lines of wrapped text one frame can hold. A stack whose texts need more
/// (a description that is mostly line feeds) is dropped with an error in
/// the log.
const line_capacity = 64;

font: KitFont,
painter: KitPainter,
nodes: [toast.node_max]tree_zig.Node = undefined,
lines: [line_capacity]text.Line = undefined,
/// The last built frame, for hit-testing. Empty after `skipFrame`.
tree: tree_zig.Tree,
toasts: toast.State = .empty,
dialog: confirm.State = .empty,
/// Where each toast was last drawn.
table: memory.Table = .empty,
/// Milliseconds ticked since the last built frame while a toast was
/// gliding: how far the glide advances in the next one. Time that passes
/// at rest does not count, or a glide that starts after a long rest would
/// be over in its first frame.
elapsed_ms: u32 = 0,
/// Whether the last built frame left a toast short of its place.
motion: toast.Motion = .settled,

comptime {
    // A frame shows the dialog or the toast stack, never both, so `nodes`
    // is sized for the stack and the dialog has to fit in it.
    if (confirm.node_max > toast.node_max) @compileError("dialog does not fit the kit node buffer");
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

/// Applies the user's motion setting to every surface, from now on.
pub fn setMotion(self: *KitOverlay, mode: motion_zig.Mode) void {
    self.toasts.motion = mode;
    self.dialog.motion = mode;
}

/// Shows a toast. Returns whether a redraw is due.
pub fn push(self: *KitOverlay, request: toast.Push) bool {
    return toast.update(&self.toasts, .{ .push = request });
}

/// Asks `request` in the confirm dialog. Returns whether a redraw is due.
/// A dialog that is already up keeps its own question.
pub fn openDialog(self: *KitOverlay, request: confirm.Request) bool {
    return confirm.update(&self.dialog, .{ .open = request }) == .redraw;
}

/// Sends the dialog an event the caller made from a key or a click, and
/// returns what it did: on `.confirm` the caller does what was asked.
pub fn dialogInput(self: *KitOverlay, event: confirm.Event) confirm.Outcome {
    return confirm.update(&self.dialog, event);
}

/// Whether the dialog is up and taking keys and clicks. False from the
/// moment it starts to fade out: input is the terminal's again by then.
pub fn dialogTakesInput(self: *const KitOverlay) bool {
    return switch (self.dialog.phase) {
        .entering, .open => true,
        .closed, .leaving => false,
    };
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
    return toasts_changed or confirm.update(&self.dialog, .{ .tick = dt }) != .quiet;
}

/// Milliseconds until `tick` has something to do, or null when only an
/// event can change what is shown.
pub fn wakeMs(self: *const KitOverlay) ?u32 {
    if (self.dialog.wakeMs()) |ms| return ms;
    if (self.motion == .moving) return motion_zig.frame_ms;
    return self.toasts.wakeMs();
}

/// The pointer moved to `x`, `y` in logical pixels. Returns whether a
/// redraw is due, which is when it came onto or off a dialog button.
/// Toasts keep their time while it is over one of them.
pub fn pointerMoved(self: *KitOverlay, x: f32, y: f32) bool {
    const id = self.tree.hitTest(x, y);
    if (self.dialog.phase != .closed) {
        const action: ?confirm.Action = switch (confirm.hit(id) orelse return false) {
            .confirm => .confirm,
            .cancel => .cancel,
            .scrim, .dialog => null,
        };
        return confirm.update(&self.dialog, .{ .pointer = action }) == .redraw;
    }
    const over = self.toasts.hit(id) != .none;
    _ = toast.update(&self.toasts, .{ .pointer = if (over) .over else .away });
    return false;
}

pub const Click = enum {
    /// Not on the kit's UI: the click belongs to the terminal.
    outside,
    /// Taken by the kit, nothing to redraw.
    taken,
    /// Taken by the kit, and a redraw is due.
    changed,
    /// On the dialog's confirm button: the dialog has closed and the
    /// caller does what was asked.
    confirm,
    /// On the scrim around the dialog. Nothing happened yet: the caller
    /// decides whether that cancels it.
    scrim,
};

/// A press of the left button at `x`, `y` in logical pixels.
pub fn click(self: *KitOverlay, x: f32, y: f32) Click {
    const id = self.tree.hitTest(x, y);
    if (self.dialog.phase != .closed) {
        return switch (confirm.hit(id) orelse return .taken) {
            .confirm => self.chooseDialog(.confirm),
            .cancel => self.chooseDialog(.cancel),
            .scrim => .scrim,
            // On the card, beside the buttons.
            .dialog => if (confirm.update(&self.dialog, .blur) == .redraw) .changed else .taken,
        };
    }
    switch (self.toasts.hit(id)) {
        .none => return .outside,
        .toast => return .taken,
        .close => |serial| return if (toast.update(&self.toasts, .{ .dismiss = serial })) .changed else .taken,
    }
}

fn chooseDialog(self: *KitOverlay, action: confirm.Action) Click {
    return switch (confirm.update(&self.dialog, .{ .choose = action })) {
        .quiet => .taken,
        .redraw, .closed => .changed,
        .confirm => .confirm,
    };
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
    self.build(atlas, width, height, Theme.variantFor(background).theme(), dt_ms) catch |err| {
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
        _ = try confirm.view(&self.dialog, &self.tree, theme);
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
