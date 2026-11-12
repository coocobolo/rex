//! The toast stack, after Sonner: up to `visible_max` toasts in the
//! window's bottom right corner, the newest lowest, each leaving when its
//! time is up. Timers stop while the pointer is over the stack.
//!
//! The surface follows ADR 0009. `State` is plain data and `update` is the
//! only code that changes it. `view` writes the nodes for a state, layout
//! gives them rectangles, and `place` then applies the motion layout knows
//! nothing about: a toast rising in or sinking out, and the others gliding
//! to their new place when the stack changes. Nothing allocates.

const std = @import("std");
const assert = std.debug.assert;

const Theme = @import("Theme.zig");
const Color = Theme.Color;
const memory = @import("memory.zig");
const motion_zig = @import("motion.zig");
const text = @import("text.zig");
const tree_zig = @import("tree.zig");
const Tree = tree_zig.Tree;
const Id = tree_zig.Id;
const Index = tree_zig.Index;

/// Sonner's measures, in logical pixels.
pub const width = 356;
pub const padding = 16;
/// Between toasts.
pub const gap = 14;
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

pub const Kind = enum(u8) {
    default,
    success,
    info,
    warning,
    err,

    /// The icon's color; a default toast has no icon.
    fn color(self: Kind, theme: *const Theme) ?Color {
        return switch (self) {
            .default => null,
            .success => theme.success,
            .info => theme.info,
            .warning => theme.warning,
            .err => theme.destructive,
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
    fn presence(self: *const Entry) f32 {
        return switch (self.phase) {
            .waiting => 0,
            .entering => |elapsed| motion_zig.progress(elapsed),
            .shown => 1,
            .leaving => |elapsed| 1 - motion_zig.progress(elapsed),
        };
    }
};

pub const Pointer = enum(u8) { away, over };

pub const State = struct {
    /// `entries[0..len]`, oldest first. The first `visible_max` of them are
    /// on screen (entering, shown or leaving); the rest are waiting.
    entries: [capacity]Entry = undefined,
    /// The serial the next toast gets.
    next_serial: u32 = 1,
    len: u8 = 0,
    /// Timers stand still while the pointer is over the stack.
    pointer: Pointer = .away,

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
        const dt_short = std.math.lossyCast(u16, dt_ms);
        var changed = false;
        var index: usize = 0;
        while (index < self.len) {
            const entry = &self.entries[index];
            switch (entry.phase) {
                .waiting => {},
                .entering => |elapsed| {
                    const now = elapsed +| dt_short;
                    entry.phase = if (now >= Theme.duration) .{ .shown = entry.duration_ms } else .{ .entering = now };
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
                    if (now >= Theme.duration) {
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
            .entering => |elapsed| entry.phase = .{ .leaving = Theme.duration - @min(elapsed, Theme.duration) },
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
                .entering, .leaving => return motion_zig.frame_ms,
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
/// redraw is due. A pointer event changes only when the stack next wakes
/// (`State.wakeMs`).
pub fn update(state: *State, event: Event) bool {
    return switch (event) {
        .push => |toast| state.push(toast),
        .tick => |dt_ms| state.tick(dt_ms),
        .pointer => |pointer| {
            state.pointer = pointer;
            return false;
        },
        .dismiss => |serial| state.dismiss(serial),
        .dismiss_all => state.dismissAll(),
    };
}

pub fn cardId(serial: u32) Id {
    return Id.of("toast").item(serial);
}

pub fn closeId(serial: u32) Id {
    return Id.of("toast.close").item(serial);
}

/// Most nodes one view of a full stack writes.
pub const node_max = 1 + visible_max * 8;

/// Writes the stack as one root that fills the window, and returns it, or
/// null when no toast is on screen and nothing was written. The texts
/// point into `state`: rebuild the view after every `update`.
pub fn view(state: *const State, tree: *Tree, theme: *const Theme) tree_zig.Error!?Index {
    const entries = state.visible();
    if (entries.len == 0) return null;

    const stack = try tree.open(.{
        .width = .fill,
        .height = .fill,
        .padding = .all(margin),
        .gap = gap,
        .main = .end,
        .cross = .end,
    });
    for (entries) |*entry| {
        const presence = entry.presence();
        const card = try tree.open(.{
            .id = cardId(entry.serial),
            .axis = .row,
            .width = .{ .fixed = width },
            .padding = .all(padding),
            .gap = 10,
            .fill = theme.popover.fade(presence),
            .border = theme.border.fade(presence),
            .border_width = Theme.border_width,
            .radius = Theme.radius,
        });
        if (entry.kind.color(theme)) |color| {
            // As tall as the title's line, so the icon centers on it.
            const slot = try tree.open(.{ .height = .{ .fixed = line_height }, .main = .center });
            _ = try tree.icon(.{ .codepoint = 0, .color = color.fade(presence), .size = Theme.icon });
            tree.close(slot);
        }
        const body = try tree.open(.{ .width = .fill });
        _ = try tree.text(entry.title(), .{ .color = theme.foreground.fade(presence), .style = .sm_medium, .width = .fill });
        if (entry.description_len > 0) {
            _ = try tree.text(entry.description(), .{ .color = theme.muted_foreground.fade(presence), .width = .fill });
        }
        tree.close(body);
        const close = try tree.open(.{
            .id = closeId(entry.serial),
            .width = .{ .fixed = line_height },
            .height = .{ .fixed = line_height },
            .main = .center,
            .cross = .center,
        });
        _ = try tree.text("\u{00D7}", .{ .color = theme.muted_foreground.fade(presence), .style = .sm_medium });
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
    var motion: Motion = .settled;
    var card: Index = (stack orelse return motion) + 1;
    for (state.visible()) |*entry| {
        const node = &tree.nodes[card];
        assert(node.box.id == cardId(entry.serial));
        const target = node.rect.y;
        // A toast seen for the first time starts in its place.
        const drawn = glide(table.get(node.box.id) orelse target, target, dt_ms);
        try table.set(node.box.id, drawn);
        if (drawn != target) motion = .moving;
        tree.translate(card, 0, drawn - target + (1 - entry.presence()) * rise);
        card = node.end;
    }
    return motion;
}

/// `from` after `dt_ms` of closing in on `to`: the distance left decays
/// exponentially, so the result is the same however the time is split
/// into frames.
fn glide(from: f32, to: f32, dt_ms: u32) f32 {
    const left = (from - to) * @exp(-@as(f32, @floatFromInt(dt_ms)) / glide_ms);
    return if (@abs(left) < 0.5) to else to + left;
}
