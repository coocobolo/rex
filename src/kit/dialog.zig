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
/// Between two buttons, and between a button's label and its key cap.
pub const button_gap = 8;
/// Horizontal padding inside a button.
pub const button_pad = 16;

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

/// How a button looks.
pub const Variant = enum(u8) {
    /// Bordered, no fill: an action of no special weight.
    outline,
    /// Filled with `primary`: the action the dialog suggests.
    primary,
    /// Filled with `destructive`: an action that cannot be undone.
    destructive,
};

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
    variant: Variant = .outline,
    role: Role = .choose,
    /// The key that takes this action, shown in a cap after the label
    /// ("Esc"). Empty for none. Display only: the caller binds the key.
    key_cap: []const u8 = "",
};

const Button = struct {
    variant: Variant,
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

pub const Phase = union(enum) {
    closed,
    /// Fading in; milliseconds since it started. It already takes input.
    entering: u16,
    open,
    /// Fading out after a dismissal; milliseconds since it started. It no
    /// longer takes input.
    leaving: u16,
};

pub const State = struct {
    phase: Phase = .closed,
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

pub const Direction = enum(u8) { next, previous };

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
    focus: Direction,
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
    const duration = motion.duration(self.motion);
    self.phase = switch (self.phase) {
        .entering, .open => return .quiet,
        .closed => .{ .entering = 0 },
        // Fades back in from as far as it had faded out.
        .leaving => |elapsed| .{ .entering = duration - @min(elapsed, duration) },
    };
    self.focus = request.focus;
    self.hover = no_action;
    self.title_len = put(request.title, &self.title_bytes);
    self.body_len = put(request.body, &self.body_bytes);
    self.count = @intCast(request.actions.len);
    for (request.actions, self.buttons[0..self.count]) |action, *button| {
        button.variant = action.variant;
        button.role = action.role;
        button.label_len = put(action.label, &button.label_bytes);
        button.key_cap_len = put(action.key_cap, &button.key_cap_bytes);
    }
    return .redraw;
}

fn tick(self: *State, dt_ms: u32) Outcome {
    const dt: u16 = std.math.lossyCast(u16, dt_ms);
    const duration = motion.duration(self.motion);
    switch (self.phase) {
        .closed, .open => return .quiet,
        .entering => |elapsed| {
            const now = elapsed +| dt;
            self.phase = if (now >= duration) .open else .{ .entering = now };
            return .redraw;
        },
        .leaving => |elapsed| {
            const now = elapsed +| dt;
            if (now >= duration) {
                self.phase = .closed;
                self.hover = no_action;
                return .closed;
            }
            self.phase = .{ .leaving = now };
            return .redraw;
        },
    }
}

fn hoverAt(self: *State, index: u8) Outcome {
    if (!self.acceptsInput()) return .quiet;
    const over = if (index < self.count) index else no_action;
    if (self.hover == over) return .quiet;
    self.hover = over;
    return .redraw;
}

fn move(self: *State, direction: Direction) Outcome {
    if (!self.acceptsInput()) return .quiet;
    const before = self.focus;
    self.focus = switch (direction) {
        // Coming into the row forwards lands on its first button.
        .next => if (before == no_action) 0 else (before + 1) % self.count,
        // Coming into it backwards lands on its last.
        .previous => if (before == no_action or before == 0) self.count - 1 else before - 1,
    };
    return if (self.focus == before) .quiet else .redraw;
}

fn blur(self: *State) Outcome {
    if (!self.acceptsInput()) return .quiet;
    if (self.focus == no_action) return .quiet;
    self.focus = no_action;
    return .redraw;
}

fn take(self: *State, index: u8) Outcome {
    if (!self.acceptsInput() or index >= self.count) return .quiet;
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
    const duration = motion.duration(self.motion);
    switch (self.phase) {
        .closed, .leaving => return .quiet,
        // Fades out from as far as it had faded in.
        .entering => |elapsed| self.phase = .{ .leaving = duration - @min(elapsed, duration) },
        .open => self.phase = .{ .leaving = 0 },
    }
    self.hover = no_action;
    return .redraw;
}

fn put(bytes: []const u8, dest: []u8) u8 {
    const len = text.cut(bytes, dest.len);
    @memcpy(dest[0..len], bytes[0..len]);
    return @intCast(len);
}

const Look = struct { fill: Color, border: Color, label: Color };

/// A filled button is slightly translucent while hovered; an outline
/// button fills. The focused button's border takes the ring color, under
/// the ring drawn around it.
fn look(theme: *const Theme, variant: Variant, hovered: bool, focused: bool) Look {
    const solid: u8 = if (hovered) 90 else 100;
    var result: Look = switch (variant) {
        .outline => .{
            .fill = if (hovered) theme.accent else .transparent,
            .border = theme.input,
            .label = theme.foreground,
        },
        .primary => .{
            .fill = theme.primary.alpha(solid),
            .border = .transparent,
            .label = theme.primary_foreground,
        },
        .destructive => .{
            .fill = theme.destructive.alpha(solid),
            .border = .transparent,
            .label = theme.destructive_foreground,
        },
    };
    if (focused) result.border = theme.ring;
    return result;
}

/// Most nodes one view writes: scrim, card, title, body, the action row,
/// and five per button (ring slot, face, label, key cap and its text).
pub const node_max = 5 + actions_max * 5;

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
    for (state.buttons[0..state.count], 0..) |*button, index| {
        try buttonView(tree, theme, state, button, @intCast(index), presence);
    }
    tree.close(actions);
    tree.close(card);
    tree.close(scrim);
    return scrim;
}

fn buttonView(tree: *Tree, theme: *const Theme, state: *const State, button: *const Button, index: u8, presence: f32) tree_zig.Error!void {
    const focused = state.focus == index;
    const colors = look(theme, button.variant, state.hover == index, focused);
    // Every button sits in a slot with room for the ring, so the row does
    // not shift when the focus moves. The ring is the slot's border, not
    // its fill, which would show through an outline button.
    const slot = try tree.open(.{
        .padding = .all(Theme.ring_width),
        .border = if (focused) theme.ring.alpha(Theme.ring_opacity).fade(presence) else .transparent,
        .border_width = Theme.ring_width,
        .radius = Theme.radius_md + Theme.ring_width,
    });
    const face = try tree.open(.{
        .id = actionId(index),
        .axis = .row,
        .height = .{ .fixed = Theme.control },
        .padding = .symmetric(button_pad, 0),
        .gap = button_gap,
        .main = .center,
        .cross = .center,
        .fill = colors.fill.fade(presence),
        .border = colors.border.fade(presence),
        .border_width = Theme.border_width,
        .radius = Theme.radius_md,
    });
    _ = try tree.text(button.label(), .{
        .color = colors.label.fade(presence),
        .style = .sm_medium,
    });
    if (button.key_cap_len > 0) {
        const cap = try tree.open(.{
            .padding = .symmetric(6, 2),
            .fill = theme.muted.fade(presence),
            .radius = Theme.radius_sm,
            .main = .center,
            .cross = .center,
        });
        _ = try tree.text(button.keyCap(), .{
            .color = theme.muted_foreground.fade(presence),
            .style = .xs,
        });
        tree.close(cap);
    }
    tree.close(face);
    tree.close(slot);
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
