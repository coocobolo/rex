//! A dialog that asks one question: a title, an optional body and a row
//! of one to three actions over a scrim. The quit prompt is its first
//! caller.
//!
//! `State` is plain data, `update` is the only code that changes it and
//! `view` writes its nodes (ADR 0009). Nothing allocates.
//!
//! The caller turns keys and clicks into events and acts on the outcome.
//! Choosing an action closes the dialog at once and reports which;
//! dismissing fades it out, and it takes no more input from then on.

const std = @import("std");
const assert = std.debug.assert;

const Theme = @import("Theme.zig");
const button = @import("button.zig");
const focus = @import("focus.zig");
const modal = @import("modal.zig");
const motion = @import("motion.zig");
const text = @import("text.zig");
const tree_zig = @import("tree.zig");
const Tree = tree_zig.Tree;
const Id = tree_zig.Id;
const Index = tree_zig.Index;

/// The card's width in logical pixels, padding included. A narrower window
/// shrinks it.
pub const width = 420;

pub const actions_max = 3;
pub const title_capacity = 96;
pub const body_capacity = 160;
pub const label_capacity = 48;
pub const key_cap_capacity = 8;

pub const scrim_id = Id.of("dialog.scrim");
pub const card_id = Id.of("dialog");

/// The id of the button of action `index`.
pub fn actionId(index: u8) Id {
    return Id.of("dialog.action").item(index);
}

/// No action: the value of `State.focus` and `State.hover` when no button
/// has the focus or the pointer.
pub const no_action = actions_max;

/// What taking a button does.
pub const Role = enum(u8) {
    /// Reports `Outcome.chosen` with the action's index.
    choose,
    /// Dismisses the dialog, as Esc does.
    dismiss,
};

/// One button of a request. The texts are copied.
pub const Action = struct {
    label: []const u8,
    variant: button.Variant = .outline,
    role: Role = .choose,
    /// The key that takes this action, shown in a cap after the label
    /// ("Esc"). Empty for none. Display only: the caller binds the key.
    key_cap: []const u8 = "",
};

const Button = struct {
    variant: button.Variant,
    role: Role,
    label_len: u8,
    key_cap_len: u8,
    label_bytes: [label_capacity]u8,
    key_cap_bytes: [key_cap_capacity]u8,

    fn label(self: *const Button) []const u8 {
        return self.label_bytes[0..self.label_len];
    }

    fn keyCap(self: *const Button) []const u8 {
        return self.key_cap_bytes[0..self.key_cap_len];
    }
};

pub const State = struct {
    phase: modal.Phase = .closed,
    /// The action with the focus ring, taken by `activate`; `no_action`
    /// for none, when `activate` does nothing.
    focus: u8 = no_action,
    /// The action under the pointer, or `no_action`.
    hover: u8 = no_action,
    /// Buttons in use: `buttons[0..count]`, drawn left to right.
    count: u8 = 0,
    /// Set by the owner, from the user's setting.
    motion: motion.Mode = .full,
    title_len: u8 = 0,
    body_len: u8 = 0,
    title_bytes: [title_capacity]u8 = undefined,
    body_bytes: [body_capacity]u8 = undefined,
    buttons: [actions_max]Button = undefined,

    pub const empty: State = .{};

    pub fn title(self: *const State) []const u8 {
        return self.title_bytes[0..self.title_len];
    }

    pub fn body(self: *const State) []const u8 {
        return self.body_bytes[0..self.body_len];
    }

    /// The label of action `index`.
    pub fn label(self: *const State, index: u8) []const u8 {
        return self.buttons[index].label();
    }
};

/// What to ask. Every text is copied and cut at its capacity on a code
/// point boundary, so nothing needs to outlive the call.
pub const Request = struct {
    title: []const u8,
    /// Wrapped to the card's width; a line feed starts a new line. Empty
    /// for no body.
    body: []const u8 = "",
    /// One to `actions_max` buttons, left to right. By convention the
    /// action the dialog is about comes last.
    actions: []const Action,
    /// The action that starts with the focus, or `no_action`.
    focus: u8 = no_action,
};

/// The part of the dialog a point is over.
pub const Target = union(enum) {
    scrim,
    /// The card, beside its buttons.
    card,
    /// The button of this action.
    action: u8,
};

pub const Event = union(enum) {
    open: Request,
    /// This many milliseconds passed.
    tick: u32,
    /// The pointer is over this action's button now, or over none
    /// (`no_action`).
    pointer: u8,
    focus: focus.Direction,
    /// Take the focused action.
    activate,
    /// Take the focus off the buttons, as a click beside them does.
    blur,
    /// Close without choosing: Esc, or a click outside.
    dismiss,
    /// Take this action, as a click on its button does.
    take: u8,
};

/// What an event did, for the caller to act on.
pub const Outcome = union(enum) {
    /// Nothing: the event did not apply, or changed nothing on screen.
    quiet,
    /// The view changed; a redraw is due.
    redraw,
    /// This action was chosen. The dialog is closed and a redraw is due.
    chosen: u8,
    /// The fade-out ended. The dialog is closed and a redraw is due.
    closed,
};

/// Applies `event` and returns what it did. This is the only function that
/// changes a `State`.
pub fn update(state: *State, event: Event) Outcome {
    return switch (event) {
        .open => |request| open(state, request),
        .tick => |dt_ms| tick(state, dt_ms),
        .pointer => |index| hoverAt(state, index),
        .focus => |direction| move(state, direction),
        .activate => if (state.focus == no_action) .quiet else take(state, state.focus),
        .blur => blur(state),
        .dismiss => beginLeave(state),
        .take => |index| take(state, index),
    };
}

fn open(self: *State, request: Request) Outcome {
    assert(request.actions.len >= 1 and request.actions.len <= actions_max);
    assert(request.focus < request.actions.len or request.focus == no_action);
    if (!self.phase.enter(self.motion)) return .quiet;
    self.focus = request.focus;
    self.hover = no_action;
    self.title_len = put(request.title, &self.title_bytes);
    self.body_len = put(request.body, &self.body_bytes);
    self.count = @intCast(request.actions.len);
    for (request.actions, self.buttons[0..self.count]) |action, *stored| {
        stored.variant = action.variant;
        stored.role = action.role;
        stored.label_len = put(action.label, &stored.label_bytes);
        stored.key_cap_len = put(action.key_cap, &stored.key_cap_bytes);
    }
    return .redraw;
}

fn tick(self: *State, dt_ms: u32) Outcome {
    switch (self.phase.tick(self.motion, dt_ms)) {
        .quiet => return .quiet,
        .redraw => return .redraw,
        .closed => {
            self.hover = no_action;
            return .closed;
        },
    }
}

fn hoverAt(self: *State, index: u8) Outcome {
    if (!self.phase.acceptsInput()) return .quiet;
    const over = if (index < self.count) index else no_action;
    if (self.hover == over) return .quiet;
    self.hover = over;
    return .redraw;
}

fn move(self: *State, direction: focus.Direction) Outcome {
    if (!self.phase.acceptsInput()) return .quiet;
    const before = self.focus;
    self.focus = focus.move(before, self.count, direction);
    return if (self.focus == before) .quiet else .redraw;
}

fn blur(self: *State) Outcome {
    if (!self.phase.acceptsInput()) return .quiet;
    if (self.focus == no_action) return .quiet;
    self.focus = no_action;
    return .redraw;
}

fn take(self: *State, index: u8) Outcome {
    if (!self.phase.acceptsInput() or index >= self.count) return .quiet;
    switch (self.buttons[index].role) {
        .dismiss => return beginLeave(self),
        .choose => {
            self.phase = .closed;
            self.hover = no_action;
            return .{ .chosen = index };
        },
    }
}

fn beginLeave(self: *State) Outcome {
    if (!self.phase.leave(self.motion)) return .quiet;
    self.hover = no_action;
    return .redraw;
}

fn put(bytes: []const u8, dest: []u8) u8 {
    const len = text.cut(bytes, dest.len);
    @memcpy(dest[0..len], bytes[0..len]);
    return @intCast(len);
}

/// Most nodes one view writes: the modal frame, the title, the body, the
/// action row and the buttons.
pub const node_max = modal.node_max + 3 + actions_max * button.node_max;

/// Writes the dialog as one root, the scrim, and returns it, or null when
/// the dialog is closed and nothing was written. The texts point into
/// `state`: rebuild the view after every `update`.
pub fn view(state: *const State, tree: *Tree, theme: *const Theme) tree_zig.Error!?Index {
    if (state.phase == .closed) return null;
    const presence = state.phase.presence(state.motion);

    const frame = try modal.open(tree, theme, .{
        .scrim_id = scrim_id,
        .card_id = card_id,
        .width = width,
        .presence = presence,
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
        .gap = button.gap,
    });
    for (state.buttons[0..state.count], 0..) |*action, index| {
        try button.view(tree, theme, .{
            .id = actionId(@intCast(index)),
            .label = action.label(),
            .key_cap = action.keyCap(),
            .variant = action.variant,
            .state = if (state.hover == index) .hovered else .normal,
            .focused = state.focus == index,
            .presence = presence,
        });
    }
    tree.close(actions);
    modal.close(tree, frame);
    return frame.scrim;
}

/// The part of the dialog that node `id` belongs to, or null for a node
/// of another surface. Pass what `Tree.hitTest` returned.
pub fn hit(id: Id) ?Target {
    if (id == scrim_id) return .scrim;
    if (id == card_id) return .card;
    for (0..actions_max) |index| {
        if (id == actionId(@intCast(index))) return .{ .action = @intCast(index) };
    }
    return null;
}
