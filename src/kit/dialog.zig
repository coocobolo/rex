//! A confirm dialog: a title, an optional body, and a cancel and a
//! confirm button over a scrim. The quit prompt is its first caller.
//!
//! `State` is plain data, `update` is the only code that changes it and
//! `view` writes its nodes (ADR 0009). Nothing allocates.
//!
//! The caller turns keys and clicks into events and acts on the outcome.
//! Confirming closes the dialog at once; cancelling fades it out, and it
//! takes no more input from then on.

const std = @import("std");

const Theme = @import("Theme.zig");
const motion = @import("motion.zig");
const text = @import("text.zig");
const Color = Theme.Color;
const tree_zig = @import("tree.zig");
const Tree = tree_zig.Tree;
const Id = tree_zig.Id;
const Index = tree_zig.Index;

/// The card's width in logical pixels, padding included. Fixed: layout
/// has no "at most" size, so a narrower window clips the card instead of
/// shrinking it.
pub const width = 420;
pub const padding = 24;
/// Between the title, the body and the actions.
pub const gap = 16;
/// Between the two buttons, and between a button's label and its key cap.
pub const button_gap = 8;
/// Horizontal padding inside a button.
pub const button_pad = 16;

pub const title_capacity = 96;
pub const body_capacity = 160;
pub const label_capacity = 64;

pub const scrim_id = Id.of("dialog.scrim");
pub const card_id = Id.of("dialog");

pub const Action = enum(u8) {
    cancel,
    /// The action the dialog asks about. Drawn last, on the right.
    confirm,

    pub fn id(self: Action) Id {
        return switch (self) {
            .cancel => Id.of("cancel"),
            .confirm => Id.of("confirm"),
        };
    }
};

/// Which button has the focus ring and is taken by `activate`. With
/// `none` there is no ring and `activate` does nothing.
pub const Focus = enum(u8) {
    none,
    cancel,
    confirm,

    fn matches(self: Focus, action: Action) bool {
        return switch (self) {
            .none => false,
            .cancel => action == .cancel,
            .confirm => action == .confirm,
        };
    }
};

pub const Phase = union(enum) {
    closed,
    /// Fading in; milliseconds since it started. It already takes input.
    entering: u16,
    open,
    /// Fading out after a cancel; milliseconds since it started. It no
    /// longer takes input.
    leaving: u16,
};

pub const State = struct {
    phase: Phase = .closed,
    focus: Focus = .none,
    /// The button under the pointer, if any.
    hover: ?Action = null,
    /// Set by the owner, from the user's setting.
    motion: motion.Mode = .full,
    title_len: u8 = 0,
    body_len: u8 = 0,
    confirm_len: u8 = 0,
    cancel_len: u8 = 0,
    title_bytes: [title_capacity]u8 = undefined,
    body_bytes: [body_capacity]u8 = undefined,
    confirm_bytes: [label_capacity]u8 = undefined,
    cancel_bytes: [label_capacity]u8 = undefined,

    pub const empty: State = .{};

    pub fn title(self: *const State) []const u8 {
        return self.title_bytes[0..self.title_len];
    }

    pub fn body(self: *const State) []const u8 {
        return self.body_bytes[0..self.body_len];
    }

    pub fn label(self: *const State, action: Action) []const u8 {
        return switch (action) {
            .confirm => self.confirm_bytes[0..self.confirm_len],
            .cancel => self.cancel_bytes[0..self.cancel_len],
        };
    }

    /// 0 (invisible) to 1 (fully shown): the opacity of everything drawn.
    fn presence(self: *const State) f32 {
        return switch (self.phase) {
            .closed => 0,
            .entering => |elapsed| motion.progress(self.motion, elapsed),
            .open => 1,
            .leaving => |elapsed| 1 - motion.progress(self.motion, elapsed),
        };
    }

    fn acceptsInput(self: *const State) bool {
        return switch (self.phase) {
            .entering, .open => true,
            .closed, .leaving => false,
        };
    }

    /// Milliseconds until the dialog needs a `tick`, or null when only an
    /// event can change it: it is closed, or open and at rest.
    pub fn wakeMs(self: *const State) ?u32 {
        return switch (self.phase) {
            .entering, .leaving => motion.frame_ms,
            .closed, .open => null,
        };
    }
};

/// What to ask. The four texts are copied and cut at their capacity on a
/// code point boundary, so they need not outlive the call.
pub const Request = struct {
    title: []const u8,
    /// Wrapped to the card's width; a line feed starts a new line. Empty
    /// for no body.
    body: []const u8 = "",
    confirm_label: []const u8,
    cancel_label: []const u8,
    /// The button that starts with the focus.
    focus: Focus = .confirm,
};

pub const Direction = enum(u8) { next, previous };

/// The part of the dialog a point is over.
pub const Target = enum(u8) { scrim, dialog, cancel, confirm };

pub const Event = union(enum) {
    open: Request,
    /// This many milliseconds passed.
    tick: u32,
    /// The pointer is over this button now, or over neither.
    pointer: ?Action,
    focus: Direction,
    /// Take the focused action.
    activate,
    /// Take the focus off the buttons, as a click beside them does.
    blur,
    /// Close without confirming, whichever button has the focus.
    cancel,
    /// Take this action.
    choose: Action,
};

/// What an event did, for the caller to act on.
pub const Outcome = enum {
    /// Nothing: the event did not apply, or changed nothing on screen.
    quiet,
    /// The view changed; a redraw is due.
    redraw,
    /// Confirm was taken. The dialog is closed and a redraw is due.
    confirm,
    /// The fade-out ended. The dialog is closed and a redraw is due.
    closed,
};

/// Applies `event` and returns what it did. This is the only function that
/// changes a `State`.
pub fn update(state: *State, event: Event) Outcome {
    return switch (event) {
        .open => |request| open(state, request),
        .tick => |dt_ms| tick(state, dt_ms),
        .pointer => |action| hoverAt(state, action),
        .focus => |direction| move(state, direction),
        .activate => activate(state),
        .blur => blur(state),
        .cancel => beginLeave(state),
        .choose => |action| take(state, action),
    };
}

fn open(self: *State, request: Request) Outcome {
    self.phase = switch (self.phase) {
        .entering, .open => return .quiet,
        .closed => .{ .entering = 0 },
        // Fades back in from as far as it had faded out.
        .leaving => |elapsed| .{ .entering = motion.duration(self.motion) - @min(elapsed, motion.duration(self.motion)) },
    };
    self.focus = request.focus;
    self.hover = null;
    self.title_len = put(request.title, &self.title_bytes);
    self.body_len = put(request.body, &self.body_bytes);
    self.confirm_len = put(request.confirm_label, &self.confirm_bytes);
    self.cancel_len = put(request.cancel_label, &self.cancel_bytes);
    return .redraw;
}

fn tick(self: *State, dt_ms: u32) Outcome {
    const dt: u16 = std.math.lossyCast(u16, dt_ms);
    switch (self.phase) {
        .closed, .open => return .quiet,
        .entering => |elapsed| {
            const now = elapsed +| dt;
            self.phase = if (now >= motion.duration(self.motion)) .open else .{ .entering = now };
            return .redraw;
        },
        .leaving => |elapsed| {
            const now = elapsed +| dt;
            if (now >= motion.duration(self.motion)) {
                self.phase = .closed;
                self.hover = null;
                return .closed;
            }
            self.phase = .{ .leaving = now };
            return .redraw;
        },
    }
}

fn hoverAt(self: *State, action: ?Action) Outcome {
    if (!self.acceptsInput()) return .quiet;
    if (self.hover == action) return .quiet;
    self.hover = action;
    return .redraw;
}

fn move(self: *State, direction: Direction) Outcome {
    if (!self.acceptsInput()) return .quiet;
    self.focus = switch (self.focus) {
        // Coming into the row: forwards lands on its first button,
        // backwards on its last.
        .none => switch (direction) {
            .next => .cancel,
            .previous => .confirm,
        },
        // With two buttons both directions lead to the other one.
        .cancel => .confirm,
        .confirm => .cancel,
    };
    return .redraw;
}

fn blur(self: *State) Outcome {
    if (!self.acceptsInput()) return .quiet;
    if (self.focus == .none) return .quiet;
    self.focus = .none;
    return .redraw;
}

fn activate(self: *State) Outcome {
    if (!self.acceptsInput()) return .quiet;
    return switch (self.focus) {
        .none => .quiet,
        .cancel => take(self, .cancel),
        .confirm => take(self, .confirm),
    };
}

fn take(self: *State, action: Action) Outcome {
    if (!self.acceptsInput()) return .quiet;
    switch (action) {
        .confirm => {
            self.phase = .closed;
            self.hover = null;
            return .confirm;
        },
        .cancel => return beginLeave(self),
    }
}

fn beginLeave(self: *State) Outcome {
    switch (self.phase) {
        .closed, .leaving => return .quiet,
        // Fades out from as far as it had faded in.
        .entering => |elapsed| self.phase = .{ .leaving = motion.duration(self.motion) - @min(elapsed, motion.duration(self.motion)) },
        .open => self.phase = .{ .leaving = 0 },
    }
    self.hover = null;
    return .redraw;
}

fn put(bytes: []const u8, dest: []u8) u8 {
    const len = text.cut(bytes, dest.len);
    @memcpy(dest[0..len], bytes[0..len]);
    return @intCast(len);
}

/// Confirm is a filled destructive button, slightly translucent while
/// hovered. Cancel is an outline button that fills while hovered.
fn buttonFill(theme: *const Theme, action: Action, hovered: bool) Color {
    return switch (action) {
        .confirm => theme.destructive.alpha(if (hovered) 90 else 100),
        .cancel => if (hovered) theme.accent else .transparent,
    };
}

/// The focused button's border takes the ring color, under the ring
/// drawn around it.
fn buttonBorder(theme: *const Theme, action: Action, focused: bool) Color {
    if (focused) return theme.ring;
    return switch (action) {
        .cancel => theme.input,
        .confirm => .transparent,
    };
}

/// Most nodes one view writes: scrim, card, title, body, the action row,
/// three per button (ring slot, face, label) and two for the key cap.
pub const node_max = 13;

/// Writes the dialog as one root, the scrim, and returns it, or null when
/// the dialog is closed and nothing was written. The texts point into
/// `state`: rebuild the view after every `update`.
pub fn view(state: *const State, tree: *Tree, theme: *const Theme) tree_zig.Error!?Index {
    if (state.phase == .closed) return null;
    const presence = state.presence();

    const scrim = try tree.open(.{
        .id = scrim_id,
        .width = .fill,
        .height = .fill,
        .main = .center,
        .cross = .center,
        .fill = theme.scrim.fade(presence),
    });
    const card = try tree.open(.{
        .id = card_id,
        .width = .{ .fixed = width },
        .padding = .all(padding),
        .gap = gap,
        .fill = theme.popover.fade(presence),
        .border = theme.border.fade(presence),
        .border_width = Theme.border_width,
        .radius = Theme.radius,
    });
    _ = try tree.text(state.title(), .{
        .color = theme.foreground.fade(presence),
        .style = .lg_semibold,
        .width = .fill,
    });
    if (state.body_len > 0) {
        _ = try tree.text(state.body(), .{
            .color = theme.muted_foreground.fade(presence),
            .width = .fill,
        });
    }
    const actions = try tree.open(.{
        .axis = .row,
        .width = .fill,
        .main = .end,
        .cross = .center,
        .gap = button_gap,
    });
    try button(tree, theme, state, .cancel, presence);
    try button(tree, theme, state, .confirm, presence);
    tree.close(actions);
    tree.close(card);
    tree.close(scrim);
    return scrim;
}

fn button(tree: *Tree, theme: *const Theme, state: *const State, action: Action, presence: f32) tree_zig.Error!void {
    const focused = state.focus.matches(action);
    // Every button sits in a slot with room for the ring, so the row does
    // not shift when the focus moves. The ring is the slot's border, not
    // its fill, which would show through the outline button.
    const slot = try tree.open(.{
        .padding = .all(Theme.ring_width),
        .border = if (focused) theme.ring.alpha(Theme.ring_opacity).fade(presence) else .transparent,
        .border_width = Theme.ring_width,
        .radius = Theme.radius_md + Theme.ring_width,
    });
    const hovered = state.hover == action;
    const face = try tree.open(.{
        .id = action.id(),
        .axis = .row,
        .height = .{ .fixed = Theme.control },
        .padding = .symmetric(button_pad, 0),
        .gap = button_gap,
        .main = .center,
        .cross = .center,
        .fill = buttonFill(theme, action, hovered).fade(presence),
        .border = buttonBorder(theme, action, focused).fade(presence),
        .border_width = Theme.border_width,
        .radius = Theme.radius_md,
    });
    const label_color: Color = switch (action) {
        .confirm => theme.destructive_foreground,
        .cancel => theme.foreground,
    };
    _ = try tree.text(state.label(action), .{
        .color = label_color.fade(presence),
        .style = .sm_medium,
    });
    // Esc cancels every dialog, whatever the caller labels the button.
    if (action == .cancel) try keyCap(tree, theme, presence);
    tree.close(face);
    tree.close(slot);
}

/// The key cap after the cancel label.
fn keyCap(tree: *Tree, theme: *const Theme, presence: f32) tree_zig.Error!void {
    const cap = try tree.open(.{
        .padding = .symmetric(6, 2),
        .fill = theme.muted.fade(presence),
        .radius = Theme.radius_sm,
        .main = .center,
        .cross = .center,
    });
    _ = try tree.text("Esc", .{
        .color = theme.muted_foreground.fade(presence),
        .style = .xs,
    });
    tree.close(cap);
}

/// The part of the dialog that node `id` belongs to, or null for a node
/// of another surface. Pass what `Tree.hitTest` returned.
pub fn hit(id: Id) ?Target {
    if (id == scrim_id) return .scrim;
    if (id == card_id) return .dialog;
    if (id == Action.cancel.id()) return .cancel;
    if (id == Action.confirm.id()) return .confirm;
    return null;
}
