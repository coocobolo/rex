//! The toast stack: up to `visible_max` toasts anchored to a window corner or
//! edge, each leaving when its time is up. In `.stacked` layout (default) the
//! newest toast sits full-width in front with older toasts peeking behind it
//! and expanding into a vertical list on hover; in `.expanded` layout every
//! visible toast stays listed with `gap` between them. Timers stop while the
//! pointer is over the stack.
//!
//! The surface follows ADR 0009. `State` is plain data and `update` is the
//! only code that changes it. `view` writes the nodes for a state, layout
//! gives them rectangles, and `place` then applies the motion layout knows
//! nothing about: a toast rising in or sinking out, the deck expanding or
//! collapsing on hover, and cards gliding to their new place when the stack
//! changes. Nothing allocates.

const std = @import("std");
const assert = std.debug.assert;

const Theme = @import("Theme.zig");
const Color = Theme.Color;
const icons = @import("icons.zig");
const memory = @import("memory.zig");
const motion = @import("motion.zig");
const text = @import("text.zig");
const Tree = @import("Tree.zig");
const Id = Tree.Id;
const Index = Tree.Index;

/// In logical pixels.
pub const width = 356;
pub const padding = 16;
/// Between expanded toasts.
pub const gap = 14;
/// Visible vertical lip of each card behind the front toast when stacked.
pub const peek = 12;
/// Width shrink fraction per depth step behind the front toast when stacked.
pub const scale_step: f32 = 0.05;
/// From the window's edges.
pub const margin = 24;
pub const visible_max = 3;

/// Toasts the stack holds, on screen and waiting. One more evicts the
/// oldest.
pub const capacity = 8;
pub const title_capacity = 96;
pub const description_capacity = 160;

/// How far below its place a toast starts and ends.
const rise = 16;
/// Time constant of the glide to a new place: a move of one toast's
/// height (about 70 pixels) is within half a pixel after `Theme.duration`.
const glide_ms = 40;
/// The title's line, which the icon and the close button center on.
const line_height = text.Style.sm_medium.metrics().line_height;

pub const Position = Tree.ScreenAnchor;

/// How multiple visible toasts are arranged on screen.
pub const Layout = enum(u8) {
    expanded,
    stacked,
};

pub const Option = struct {
    width: f32 = width,
    scale_step: f32 = scale_step,
    position: Position = .bottom_right,
    layout: Layout = .stacked,
    margin: u8 = margin,
    padding: u8 = padding,
    gap: u8 = gap,
    peek: u8 = peek,
    /// How far a toast slides in from its place, in pixels.
    rise_distance: f32 = rise,
    /// Time constant of the glide to a new place, in milliseconds.
    glide_ms: u32 = glide_ms,
};

pub const Kind = enum(u8) {
    default,
    success,
    info,
    warning,
    err,

    const Mark = struct { codepoint: u21, color: Color };

    /// The icon before the title; a default toast has none.
    fn mark(self: Kind, theme: *const Theme) ?Mark {
        return switch (self) {
            .default => null,
            .success => .{ .codepoint = icons.check_circle_2, .color = theme.success },
            .info => .{ .codepoint = icons.info, .color = theme.info },
            .warning => .{ .codepoint = icons.alert_triangle, .color = theme.warning },
            .err => .{ .codepoint = icons.circle_x, .color = theme.destructive },
        };
    }
};

pub const Phase = union(enum) {
    /// Not on screen: `visible_max` older toasts are ahead of it.
    waiting,
    /// Rising in; milliseconds since it started.
    entering: u16,
    /// At rest; milliseconds until it leaves.
    shown: u32,
    /// Sinking out; milliseconds since it started.
    leaving: u16,
};

pub const Entry = struct {
    phase: Phase,
    /// Names this toast for as long as the stack lives; never reused.
    serial: u32,
    /// How long it stays once it has entered.
    duration_ms: u32,
    kind: Kind,
    title_len: u8,
    description_len: u8,
    title_bytes: [title_capacity]u8,
    description_bytes: [description_capacity]u8,

    pub fn title(self: *const Entry) []const u8 {
        return self.title_bytes[0..self.title_len];
    }

    pub fn description(self: *const Entry) []const u8 {
        return self.description_bytes[0..self.description_len];
    }

    /// 0 (invisible, `rise` below its place) to 1 (at rest).
    fn presence(self: *const Entry, mode: motion.Mode, duration_ms: u16) f32 {
        return switch (self.phase) {
            .waiting => 0,
            .entering => |elapsed| motion.progress(mode, elapsed, duration_ms),
            .shown => 1,
            .leaving => |elapsed| 1 - motion.progress(mode, elapsed, duration_ms),
        };
    }
};

pub const Pointer = enum(u8) { away, over };

/// Lines of wrapped text one view needs at most. A text yields one line
/// more than it has line breaks, so at most one more than it has bytes.
pub const line_max = visible_max * (title_capacity + 1 + description_capacity + 1);

pub const State = struct {
    /// `entries[0..len]`, oldest first. The first `visible_max` of them are
    /// on screen (entering, shown or leaving); the rest are waiting.
    entries: [capacity]Entry = undefined,
    /// The serial the next toast gets.
    next_serial: u32 = 1,
    len: u8 = 0,
    /// Timers stand still while the pointer is over the stack.
    pointer: Pointer = .away,
    /// Set by the owner, from the user's setting.
    motion: motion.Mode = .full,
    /// Enter/leave duration from `[ui] animation_duration`.
    duration_ms: u16 = Theme.duration,
    option: Option = .{},

    pub const empty: State = .{};

    /// The toasts on screen, oldest first.
    pub fn visible(self: *const State) []const Entry {
        return self.entries[0..@min(self.len, visible_max)];
    }

    fn remove(self: *State, index: usize) void {
        std.mem.copyForwards(Entry, self.entries[index .. self.len - 1], self.entries[index + 1 .. self.len]);
        self.len -= 1;
    }

    /// Lets waiting toasts in where there is room. Returns whether one
    /// entered.
    fn admit(self: *State) bool {
        var entered = false;
        for (self.entries[0..@min(self.len, visible_max)]) |*entry| {
            if (entry.phase != .waiting) continue;
            entry.phase = .{ .entering = 0 };
            entered = true;
        }
        return entered;
    }

    fn push(self: *State, toast: Push) bool {
        var changed = false;
        if (self.len == capacity) {
            // The oldest is always on screen.
            self.remove(0);
            changed = true;
        }
        const entry = &self.entries[self.len];
        entry.* = .{
            .phase = .waiting,
            .serial = self.next_serial,
            .duration_ms = toast.duration_ms,
            .kind = toast.kind,
            .title_len = @intCast(text.cut(toast.title, title_capacity)),
            .description_len = @intCast(text.cut(toast.description, description_capacity)),
            .title_bytes = undefined,
            .description_bytes = undefined,
        };
        @memcpy(entry.title_bytes[0..entry.title_len], toast.title[0..entry.title_len]);
        @memcpy(entry.description_bytes[0..entry.description_len], toast.description[0..entry.description_len]);
        self.next_serial += 1;
        self.len += 1;
        return self.admit() or changed;
    }

    fn tick(self: *State, dt_ms: u32) bool {
        const duration = motion.duration(self.motion, self.duration_ms);
        const dt_short = std.math.lossyCast(u16, dt_ms);
        var changed = false;
        var index: usize = 0;
        while (index < self.len) {
            const entry = &self.entries[index];
            switch (entry.phase) {
                .waiting => {},
                .entering => |elapsed| {
                    const now = elapsed +| dt_short;
                    entry.phase = if (now >= duration) .{ .shown = entry.duration_ms } else .{ .entering = now };
                    changed = true;
                },
                // Counting down changes nothing on screen until it ends.
                .shown => |remaining| switch (self.pointer) {
                    .over => {},
                    .away => if (dt_ms >= remaining) {
                        entry.phase = .{ .leaving = 0 };
                        changed = true;
                    } else {
                        entry.phase = .{ .shown = remaining - dt_ms };
                    },
                },
                .leaving => |elapsed| {
                    changed = true;
                    const now = elapsed +| dt_short;
                    if (now >= duration) {
                        self.remove(index);
                        continue;
                    }
                    entry.phase = .{ .leaving = now };
                },
            }
            index += 1;
        }
        return self.admit() or changed;
    }

    /// Starts `entry` leaving, or drops it at once if it never showed.
    /// Returns whether the screen changes.
    fn dismissAt(self: *State, index: usize) bool {
        const entry = &self.entries[index];
        switch (entry.phase) {
            .waiting => {
                self.remove(index);
                return false;
            },
            // Leaves from as far as it got, so it does not jump to full
            // presence first.
            .entering => |elapsed| {
                const duration = motion.duration(self.motion, self.duration_ms);
                entry.phase = .{ .leaving = duration - @min(elapsed, duration) };
            },
            .shown => entry.phase = .{ .leaving = 0 },
            .leaving => return false,
        }
        return true;
    }

    fn dismiss(self: *State, serial: u32) bool {
        for (self.entries[0..self.len], 0..) |entry, index| {
            if (entry.serial == serial) return self.dismissAt(index);
        }
        return false;
    }

    fn dismissAll(self: *State) bool {
        var changed = false;
        // Backwards: dropping a waiting toast moves the later ones down.
        var index: usize = self.len;
        while (index > 0) {
            index -= 1;
            if (self.dismissAt(index)) changed = true;
        }
        return changed;
    }

    /// Milliseconds until the stack needs a `tick`, or null when only an
    /// event can change it: it is empty, or the pointer holds every timer.
    pub fn wakeMs(self: *const State) ?u32 {
        var wake: ?u32 = null;
        for (self.visible()) |entry| {
            switch (entry.phase) {
                .waiting => unreachable, // `visible` holds none
                .entering, .leaving => return motion.frame_ms,
                .shown => |remaining| if (self.pointer == .away) {
                    wake = @min(wake orelse remaining, remaining);
                },
            }
        }
        return wake;
    }

    /// What the node `id` of the last view is.
    pub fn hit(self: *const State, id: Id) Hit {
        if (id == .none) return .none;
        if (id == stack_id) return .stack;
        for (self.visible()) |entry| {
            if (id == closeId(entry.serial)) return .{ .close = entry.serial };
            if (id == cardId(entry.serial)) return .{ .toast = entry.serial };
        }
        return .none;
    }
};

pub const Hit = union(enum) {
    none,
    /// The toast with this serial, outside its close button.
    toast: u32,
    /// The close button of the toast with this serial.
    close: u32,
    /// Inside the expanded stacked-toast footprint (gap between cards).
    stack,
};

pub const Push = struct {
    /// Copied; cut at `title_capacity` bytes on a code point boundary.
    title: []const u8,
    /// Copied; cut at `description_capacity` bytes. Empty for none.
    description: []const u8 = "",
    kind: Kind = .default,
    duration_ms: u32,
};

pub const Event = union(enum) {
    push: Push,
    /// This many milliseconds passed.
    tick: u32,
    /// The pointer came over the stack or left it.
    pointer: Pointer,
    /// Dismiss the toast with this serial.
    dismiss: u32,
    dismiss_all,
};

/// Applies `event` and returns whether the view changed, which is when a
/// redraw is due. A pointer change triggers a redraw when a stacked deck of
/// multiple toasts expands or collapses; otherwise it only changes when the
/// stack next wakes (`State.wakeMs`).
pub fn update(state: *State, event: Event) bool {
    return switch (event) {
        .push => |toast| state.push(toast),
        .tick => |dt_ms| state.tick(dt_ms),
        .pointer => |pointer| {
            const changed = state.pointer != pointer and
                state.option.layout == .stacked and
                state.visible().len > 1;
            state.pointer = pointer;
            return changed;
        },
        .dismiss => |serial| state.dismiss(serial),
        .dismiss_all => state.dismissAll(),
    };
}

/// Transparent hit target bridging gaps between cards while a stacked deck is
/// hovered or mid-expansion.
pub const stack_id: Id = Id.of("toast.stack");
const expand_id: Id = Id.of("toast.expand");

pub fn cardId(serial: u32) Id {
    return Id.of("toast").item(serial);
}

pub fn closeId(serial: u32) Id {
    return Id.of("toast.close").item(serial);
}

/// Most nodes one view of a full stack writes (root, optional hover bridge,
/// and up to `visible_max` cards of 8 nodes each).
pub const node_max = 2 + visible_max * 8;

/// Writes the stack as one root that fills the window, and returns it, or
/// null when no toast is on screen and nothing was written. The texts
/// point into `state`: rebuild the view after every `update`.
pub fn view(state: *const State, tree: *Tree, theme: *const Theme) Tree.Error!?Index {
    const entries = state.visible();
    if (entries.len == 0) return null;

    const stack = try tree.open(.{
        .width = .fill,
        .height = .fill,
        .padding = .all(state.option.margin),
        .gap = state.option.gap,
        .main = state.option.position.mainAlign(),
        .cross = state.option.position.crossAlign(),
    });
    if (state.option.layout == .stacked and entries.len > 1) {
        _ = try tree.leaf(.{
            .id = stack_id,
            .overlay = true,
        });
    }
    for (entries, 0..) |*entry, i| {
        const depth = entries.len - 1 - i;
        const stacked_behind = state.option.layout == .stacked and depth > 0;
        const close_active = !(stacked_behind and state.pointer == .away);
        const presence = entry.presence(state.motion, state.duration_ms);
        const card = try tree.open(.{
            .id = cardId(entry.serial),
            .axis = .row,
            .width = .{ .at_most = state.option.width },
            .padding = .all(state.option.padding),
            .gap = 10,
            .fill = theme.popover.fade(presence),
            .border = theme.border.fade(presence),
            .border_width = Theme.border_width,
            .radius = Theme.radius,
            .overflow = if (stacked_behind) .clip else .visible,
        });
        if (entry.kind.mark(theme)) |mark| {
            // As tall as the title's line, so the icon centers on it.
            const slot = try tree.open(.{ .height = .{ .fixed = line_height }, .main = .center });
            _ = try tree.icon(.{ .codepoint = mark.codepoint, .color = mark.color.fade(presence), .size = Theme.icon });
            tree.close(slot);
        }
        const body = try tree.open(.{ .width = .fill });
        _ = try tree.text(entry.title(), .{ .color = theme.foreground.fade(presence), .style = .sm_medium, .width = .fill });
        if (entry.description_len > 0) {
            _ = try tree.text(entry.description(), .{ .color = theme.muted_foreground.fade(presence), .width = .fill });
        }
        tree.close(body);
        const close = try tree.open(.{
            .id = if (close_active) closeId(entry.serial) else .none,
            .pointer = if (close_active) .hand else .arrow,
            .width = .{ .fixed = line_height },
            .height = .{ .fixed = line_height },
            .main = .center,
            .cross = .center,
        });
        _ = try tree.icon(.{ .codepoint = icons.x, .color = theme.muted_foreground.fade(presence), .size = Theme.icon });
        tree.close(close);
        tree.close(card);
    }
    tree.close(stack);
    return stack;
}

pub const Motion = enum { settled, moving };

/// After layout: moves each toast of `stack` (what `view` returned) from
/// where layout put it to where it is drawn `dt_ms` after the last call,
/// remembering that in `table`. `moving` means another frame is due even
/// if no `tick` changes the state.
pub fn place(state: *const State, tree: *Tree, stack: ?Index, table: *memory.Table, dt_ms: u32) memory.Error!Motion {
    defer table.sweep();
    var status: Motion = .settled;
    const root = stack orelse return status;
    const entries = state.visible();
    if (entries.len == 0) return status;

    var cursor: Index = root + 1;
    var bridge: ?Index = null;
    if (cursor < tree.len and tree.nodes[cursor].box.id == stack_id) {
        bridge = cursor;
        cursor = tree.nodes[cursor].end;
    }

    if (state.option.layout == .expanded) {
        for (entries) |*entry| {
            const node = &tree.nodes[cursor];
            assert(node.box.id == cardId(entry.serial));
            const target = node.rect.y;
            // A toast seen for the first time starts in its place.
            const drawn = switch (state.motion) {
                .full => glide(table.get(node.box.id) orelse target, target, dt_ms, state.option.glide_ms),
                .none => target,
            };
            try table.set(node.box.id, drawn);
            if (drawn != target) status = .moving;
            const rise_offset: f32 = if (state.option.position.isTop()) -state.option.rise_distance else state.option.rise_distance;
            tree.translate(cursor, 0, drawn - target + (1 - entry.presence(state.motion, state.duration_ms)) * rise_offset);
            cursor = node.end;
        }
        return status;
    }

    var cards: [visible_max]Index = undefined;
    var orig: [visible_max]Tree.Rect = undefined;
    for (entries, 0..) |*entry, i| {
        const node = &tree.nodes[cursor];
        assert(node.box.id == cardId(entry.serial));
        cards[i] = cursor;
        orig[i] = node.rect;
        cursor = node.end;
    }

    const n = entries.len;
    const front = n - 1;
    const is_top = state.option.position.isTop();
    const expand_target: f32 = if (state.pointer == .over and n > 1) 1 else 0;
    const expand: f32 = if (n > 1) blk: {
        const drawn_expand = switch (state.motion) {
            .full => glideUnit(table.get(expand_id) orelse expand_target, expand_target, dt_ms, state.option.glide_ms),
            .none => expand_target,
        };
        try table.set(expand_id, drawn_expand);
        if (drawn_expand != expand_target) status = .moving;
        break :blk drawn_expand;
    } else 0;

    const front_w = orig[front].w;
    const front_h = orig[front].h;
    const front_x = orig[front].x;
    const anchor_edge = if (is_top) orig[0].y else orig[front].y + orig[front].h;
    const gap_f: f32 = @floatFromInt(state.option.gap);
    const peek_f: f32 = @floatFromInt(state.option.peek);
    const step = if (std.math.isFinite(state.option.scale_step)) std.math.clamp(state.option.scale_step, 0, 0.25) else 0;
    const rise_offset: f32 = if (is_top) -state.option.rise_distance else state.option.rise_distance;

    var expanded_y: [visible_max]f32 = undefined;
    var offset_y: f32 = 0;
    var depth: usize = 0;
    while (depth < n) : (depth += 1) {
        const i = front - depth;
        expanded_y[i] = if (is_top) anchor_edge + offset_y else anchor_edge - offset_y - orig[i].h;
        offset_y += orig[i].h + gap_f;
    }

    var min_x: f32 = std.math.inf(f32);
    var min_y: f32 = std.math.inf(f32);
    var max_x: f32 = -std.math.inf(f32);
    var max_y: f32 = -std.math.inf(f32);

    for (entries, 0..) |*entry, i| {
        const card = cards[i];
        const node = &tree.nodes[card];
        const d = front - i;
        const d_f: f32 = @floatFromInt(d);

        const scale = @max(0.5, 1 - d_f * step);
        const target_w = front_w * (scale + (1 - scale) * expand);
        const target_h = front_h + (orig[i].h - front_h) * expand;
        const target_x = front_x + (front_w - target_w) * 0.5;
        const collapsed_y = if (is_top) anchor_edge + d_f * peek_f else anchor_edge - front_h - d_f * peek_f;
        const target_y = collapsed_y + (expanded_y[i] - collapsed_y) * expand;

        const drawn_y = switch (state.motion) {
            .full => glide(table.get(node.box.id) orelse target_y, target_y, dt_ms, state.option.glide_ms),
            .none => target_y,
        };
        try table.set(node.box.id, drawn_y);
        if (drawn_y != target_y) status = .moving;

        const final_y = drawn_y + (1 - entry.presence(state.motion, state.duration_ms)) * rise_offset;
        tree.translate(card, target_x - orig[i].x, final_y - orig[i].y);
        node.rect.w = target_w;
        node.rect.h = target_h;
        if (d > 0) fadeDescendants(tree, card, expand);

        min_x = @min(min_x, node.rect.x);
        min_y = @min(min_y, node.rect.y);
        max_x = @max(max_x, node.rect.x + node.rect.w);
        max_y = @max(max_y, node.rect.y + node.rect.h);
    }

    if (bridge) |b| {
        tree.nodes[b].rect = if (state.pointer == .over or expand > 0) .{
            .x = min_x,
            .y = min_y,
            .w = @max(0, max_x - min_x),
            .h = @max(0, max_y - min_y),
        } else .{};
    }
    return status;
}

fn fadeDescendants(tree: *Tree, card: Index, factor: f32) void {
    if (factor >= 1) return;
    for (tree.nodes[card + 1 .. tree.nodes[card].end]) |*node| {
        node.box.fill = node.box.fill.fade(factor);
        node.box.border = node.box.border.fade(factor);
        switch (node.content) {
            .text => |*t| t.color = t.color.fade(factor),
            .icon => |*ic| ic.color = ic.color.fade(factor),
            .box, .dash, .border_sweep, .arc, .coil => {},
        }
    }
}

/// `from` after `dt_ms` of closing in on `to`: the distance left decays
/// exponentially, so the result is the same however the time is split
/// into frames.
fn glide(from: f32, to: f32, dt_ms: u32, glide_constant: u32) f32 {
    const left = (from - to) * @exp(-@as(f32, @floatFromInt(dt_ms)) / @as(f32, @floatFromInt(glide_constant)));
    return if (@abs(left) < 0.5) to else to + left;
}

fn glideUnit(from: f32, to: f32, dt_ms: u32, glide_constant: u32) f32 {
    const left = (from - to) * @exp(-@as(f32, @floatFromInt(dt_ms)) / @as(f32, @floatFromInt(glide_constant)));
    return if (@abs(left) < 0.005) to else to + left;
}
