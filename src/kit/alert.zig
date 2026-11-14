//! Persistent status banner (shadcn Alert composition): an icon, a title,
//! an optional description and a close action. Unlike a toast, it stays on
//! screen until its cause is resolved or the user dismisses it.
//!
//! `State` is plain data, `update` is the only code that changes it, and
//! `view` writes its nodes into a `Tree` (ADR 0009). Nothing allocates.

const std = @import("std");
const assert = std.debug.assert;

const Theme = @import("Theme.zig");
const Color = Theme.Color;
const button = @import("button.zig");
const dialog = @import("dialog.zig");
const icons = @import("icons.zig");
const motion_zig = @import("motion.zig");
const text = @import("text.zig");
const tree_zig = @import("tree.zig");
const Tree = tree_zig.Tree;
const Id = tree_zig.Id;
const Index = tree_zig.Index;

pub const max_width: f32 = 560;
pub const padding: f32 = 14;
pub const margin: f32 = 16;
const drop: f32 = 12;
const line_height = text.Style.sm_medium.metrics().line_height;

pub const title_capacity = 96;
pub const description_capacity = 256;

pub const card_id = Id.of("alert.card");
pub const close_id = Id.of("alert.close");

pub const Kind = enum(u8) {
    err,
    warn,
    info,

    fn accent(self: Kind, theme: *const Theme) struct { codepoint: u21, icon_color: Color, border: Color } {
        return switch (self) {
            .err => .{
                .codepoint = icons.circle_x,
                .icon_color = theme.destructive,
                .border = theme.destructive.alpha(45),
            },
            .warn => .{
                .codepoint = icons.triangle_alert,
                .icon_color = theme.warning,
                .border = theme.warning.alpha(45),
            },
            .info => .{
                .codepoint = icons.info,
                .icon_color = theme.info,
                .border = theme.border,
            },
        };
    }
};

pub const ButtonTouch = enum(u8) {
    normal,
    hovered,
    pressed,
};

pub const Request = struct {
    kind: Kind = .err,
    /// Copied; cut at `title_capacity` bytes on a code point boundary.
    title: []const u8,
    /// Copied; cut at `description_capacity` bytes. Empty for none.
    description: []const u8 = "",
};

pub const State = struct {
    phase: dialog.Phase = .closed,
    kind: Kind = .err,
    touch: ButtonTouch = .normal,
    motion: motion_zig.Mode = .full,
    title_len: u8 = 0,
    description_len: u16 = 0,
    title_bytes: [title_capacity]u8 = undefined,
    description_bytes: [description_capacity]u8 = undefined,

    pub const empty: State = .{};

    pub fn title(self: *const State) []const u8 {
        return self.title_bytes[0..self.title_len];
    }

    pub fn description(self: *const State) []const u8 {
        return self.description_bytes[0..self.description_len];
    }

    pub fn isShown(self: *const State) bool {
        return self.phase.acceptsInput();
    }

    pub fn wakeMs(self: *const State) ?u32 {
        return self.phase.wakeMs();
    }

    pub fn hit(self: *const State, id: Id) Hit {
        if (!self.phase.acceptsInput() or id == .none) return .none;
        if (id == close_id) return .close;
        if (id == card_id) return .card;
        return .none;
    }
};

pub const Hit = enum { none, card, close };

pub const Pointer = enum(u8) { away, close };

pub const Event = union(enum) {
    show: Request,
    dismiss,
    tick: u32,
    pointer: Pointer,
    press,
    release: Pointer,
};

/// Applies `event` and returns whether anything on screen changed.
pub fn update(state: *State, event: Event) bool {
    return switch (event) {
        .show => |req| show(state, req),
        .dismiss => beginLeave(state),
        .tick => |dt_ms| switch (state.phase.tick(state.motion, dt_ms)) {
            .quiet => false,
            .redraw => true,
            .closed => {
                state.touch = .normal;
                return true;
            },
        },
        .pointer => |over| hoverAt(state, over),
        .press => pressClose(state),
        .release => |over| releaseClose(state, over),
    };
}

fn show(self: *State, req: Request) bool {
    const new_title_len: u8 = @intCast(text.cut(req.title, title_capacity));
    const new_desc_len: u16 = @intCast(text.cut(req.description, description_capacity));
    const content_same = self.phase.acceptsInput() and
        self.kind == req.kind and
        std.mem.eql(u8, self.title(), req.title[0..new_title_len]) and
        std.mem.eql(u8, self.description(), req.description[0..new_desc_len]);

    self.kind = req.kind;
    self.title_len = new_title_len;
    self.description_len = new_desc_len;
    @memcpy(self.title_bytes[0..new_title_len], req.title[0..new_title_len]);
    @memcpy(self.description_bytes[0..new_desc_len], req.description[0..new_desc_len]);
    self.touch = .normal;

    const entered = if (self.motion == .none) blk: {
        const was_open = self.phase.acceptsInput();
        self.phase = .open;
        break :blk !was_open;
    } else self.phase.enter(self.motion);
    return entered or !content_same;
}

fn beginLeave(self: *State) bool {
    self.touch = .normal;
    if (self.motion == .none) {
        const was_open = self.phase != .closed;
        self.phase = .closed;
        return was_open;
    }
    return self.phase.leave(self.motion);
}

fn hoverAt(self: *State, over: Pointer) bool {
    if (!self.phase.acceptsInput()) return false;
    if (self.touch == .pressed) return false;
    const next: ButtonTouch = switch (over) {
        .close => .hovered,
        .away => .normal,
    };
    if (self.touch == next) return false;
    self.touch = next;
    return true;
}

fn pressClose(self: *State) bool {
    if (!self.phase.acceptsInput()) return false;
    if (self.touch == .pressed) return false;
    self.touch = .pressed;
    return true;
}

fn releaseClose(self: *State, over: Pointer) bool {
    if (self.touch != .pressed) return false;
    self.touch = switch (over) {
        .close => .hovered,
        .away => .normal,
    };
    if (over == .close) return beginLeave(self) or true;
    return true;
}

/// Lines of wrapped text one view needs at most.
pub const line_max = title_capacity + 1 + description_capacity + 1;

/// Most nodes one view writes: root + card + icon slot + icon + body + title +
/// description + close button.
pub const node_max = 7 + button.node_max;

/// Writes the alert banner anchored at the top-center of the window, or
/// returns null when closed.
pub fn view(state: *const State, tree: *Tree, theme: *const Theme) tree_zig.Error!?Index {
    if (state.phase == .closed) return null;
    const presence = state.phase.presence(state.motion);
    const style = state.kind.accent(theme);

    const root = try tree.open(.{
        .width = .fill,
        .height = .fill,
        .padding = .all(margin),
        .main = .start,
        .cross = .center,
    });
    const card = try tree.open(.{
        .id = card_id,
        .axis = .row,
        .width = .{ .at_most = max_width },
        .padding = .all(padding),
        .gap = 12,
        .cross = .start,
        .fill = theme.popover.fade(presence),
        .border = style.border.fade(presence),
        .border_width = Theme.border_width,
        .radius = Theme.radius,
    });
    const icon_slot = try tree.open(.{
        .height = .{ .fixed = line_height },
        .main = .center,
    });
    _ = try tree.icon(.{
        .codepoint = style.codepoint,
        .color = style.icon_color.fade(presence),
        .size = Theme.icon,
    });
    tree.close(icon_slot);

    const body = try tree.open(.{ .width = .fill, .gap = 2 });
    _ = try tree.text(state.title(), .{
        .color = if (state.kind == .err) theme.destructive.fade(presence) else theme.foreground.fade(presence),
        .style = .sm_medium,
        .width = .fill,
    });
    if (state.description_len > 0) {
        _ = try tree.text(state.description(), .{
            .color = theme.muted_foreground.fade(presence),
            .width = .fill,
        });
    }
    tree.close(body);

    const close_state: button.State = switch (state.touch) {
        .normal => .normal,
        .hovered => .hovered,
        .pressed => .pressed,
    };
    try button.view(tree, theme, .{
        .id = close_id,
        .label = "",
        .icon = icons.x,
        .variant = .ghost,
        .size = .sm,
        .state = close_state,
        .presence = presence,
    });

    tree.close(card);
    tree.close(root);
    return root;
}

/// Applies enter/leave vertical slide after `layout.layout`.
pub fn place(state: *const State, tree: *Tree, root: ?Index) void {
    const start = root orelse return;
    if (state.motion == .none) return;
    const presence = state.phase.presence(state.motion);
    if (presence >= 1) return;
    const card: Index = start + 1;
    assert(tree.nodes[card].box.id == card_id);
    tree.translate(card, 0, -(1 - presence) * drop);
}
