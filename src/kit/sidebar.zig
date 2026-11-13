//! The frame of a tool window: sections grouped under headings in a column
//! on the left, and beside it the pane that shows the current section. A
//! button at the top of the pane shows and hides the column.
//!
//! In a window narrower than `narrow_below` the column is hidden; shown
//! from there, it lies over the pane instead of pushing it aside, and
//! choosing a section hides it again. Crossing that width hands the choice
//! back to the window's width.
//!
//! A view calls `begin`, writes the section, then calls `end`. These are
//! view functions and keep nothing: what the frame shows is a `State` in
//! the surface that shows it, changed only by `State.update`.

const std = @import("std");
const assert = std.debug.assert;

const Theme = @import("Theme.zig");
const icons = @import("icons.zig");
const focus = @import("focus.zig");
const tree_zig = @import("tree.zig");
const Tree = tree_zig.Tree;
const Id = tree_zig.Id;
const Index = tree_zig.Index;

/// The column's width in logical pixels.
pub const width = 256;
/// Windows narrower than this, in logical pixels, hide the column unless
/// it is asked for.
pub const narrow_below = 600;
/// The height of a menu button, of a group label and of the toggle.
pub const row_height = 32;
/// Around a group, around the toggle, and inside a menu button.
pub const padding = 8;
/// The width of the keyboard focus ring on a menu button. It is drawn
/// inside the button, so nothing moves when the focus does.
pub const ring_width = 2;
/// How much of the foreground color a group label keeps, in percent.
pub const label_opacity = 70;

pub const toggle_id = Id.of("sidebar.toggle");
/// The dimmed layer under the column while it lies over the pane.
pub const scrim_id = Id.of("sidebar.scrim");

/// One section. The texts are borrowed until the view is rebuilt.
pub const Item = struct {
    label: []const u8,
    /// A code point of `icons.zig` drawn before the label, or 0 for none.
    icon: u21 = 0,
};

/// Sections under one heading. Items are numbered across groups, in order.
pub const Group = struct {
    /// Empty for a group without a heading.
    label: []const u8 = "",
    items: []const Item,
};

pub fn itemCount(groups: []const Group) u8 {
    var count: usize = 0;
    for (groups) |group| count += group.items.len;
    assert(count > 0 and count <= std.math.maxInt(u8));
    return @intCast(count);
}

/// Most nodes the frame writes for `groups`, the section excluded: the
/// root, the pane, its header, the toggle and its icon, the section's box,
/// the column, its edge, and over the pane the scrim and the row that
/// holds the column; then a
/// box and a two-node label per group and a button, icon and text per item.
pub fn nodeMax(comptime groups: []const Group) comptime_int {
    var count = 10;
    for (groups) |group| count += 3 + group.items.len * 3;
    return count;
}

/// Lines of text the frame needs for `groups`. Nothing in the column
/// wraps, but a text yields one line more than it has line breaks.
pub fn lineMax(comptime groups: []const Group) comptime_int {
    var count = 0;
    for (groups) |group| {
        count += group.label.len + 1;
        for (group.items) |item| count += item.label.len + 1;
    }
    return count;
}

/// The id of the menu button of item `index`.
pub fn itemId(index: u8) Id {
    return Id.of("sidebar.item").item(index);
}

/// A control of the frame the pointer can be on.
pub const Target = union(enum) {
    none,
    item: u8,
    toggle,
    /// Beside the column while it lies over the pane.
    scrim,
};

/// The control that node `id` belongs to, for a menu of `count` items.
/// Pass what `Tree.hitTest` returned.
pub fn hit(id: Id, count: u8) Target {
    if (id == .none) return .none;
    if (id == toggle_id) return .toggle;
    if (id == scrim_id) return .scrim;
    for (0..count) |index| {
        if (id == itemId(@intCast(index))) return .{ .item = @intCast(index) };
    }
    return .none;
}

/// Whether the column is shown.
pub const Panel = enum(u8) {
    /// As the window's width says: shown unless the window is narrow.
    auto,
    /// Asked for with the toggle.
    shown,
    /// Put away with the toggle.
    hidden,
};

pub const State = struct {
    /// The section the pane shows.
    current: u8 = 0,
    /// The control under the pointer.
    hover: Target = .none,
    /// The control the pointer went down on and has not let go of.
    pressed: Target = .none,
    /// Whether the current item shows the focus ring: set by the keyboard,
    /// cleared by the pointer.
    focused: bool = false,
    panel: Panel = .auto,
    /// The window is narrower than `narrow_below`.
    narrow: bool = false,

    pub const empty: State = .{};

    pub fn shown(self: *const State) bool {
        return switch (self.panel) {
            .auto => !self.narrow,
            .shown => true,
            .hidden => false,
        };
    }

    pub const Event = union(enum) {
        /// The window is this many logical pixels wide now.
        width: f32,
        /// The pointer is over this control now.
        pointer: Target,
        /// The pointer went down on this control.
        press: Target,
        /// The pointer was let go: takes the pressed control if the
        /// pointer is still over it.
        release,
        /// Make the next or previous item current. Stops at both ends.
        move: focus.Direction,
        /// Make the first item current.
        first,
        /// Make the last item current.
        last,
        /// Show the column if it is hidden, hide it if it is shown.
        toggle,
        /// Show the focus ring.
        focus,
        /// Hide the focus ring.
        blur,
    };

    /// Applies `event` to a frame of `count` items and returns whether the
    /// view changed.
    pub fn update(self: *State, count: u8, event: Event) bool {
        assert(count > 0 and self.current < count);
        const before = self.*;
        switch (event) {
            .width => |value| {
                const narrow = value < narrow_below;
                if (narrow != self.narrow) {
                    self.narrow = narrow;
                    self.panel = .auto;
                }
            },
            .pointer => |target| self.hover = valid(target, count),
            .press => |target| {
                const pressed = valid(target, count);
                if (pressed == .none) return false;
                // Like a dialog's scrim, it acts on the press.
                if (pressed == .scrim) {
                    if (self.narrow and self.panel == .shown) self.panel = .auto;
                    return !std.meta.eql(before, self.*);
                }
                // The pointer is over the control it went down on, whether
                // or not a move said so before.
                self.hover = pressed;
                self.pressed = pressed;
                self.focused = false;
            },
            .release => {
                const pressed = self.pressed;
                if (pressed == .none) return false;
                self.pressed = .none;
                if (std.meta.eql(self.hover, pressed)) self.take(pressed);
            },
            .move => |direction| {
                self.current = switch (direction) {
                    .next => @min(self.current + 1, count - 1),
                    .previous => self.current -| 1,
                };
                self.focused = true;
            },
            .first => {
                self.current = 0;
                self.focused = true;
            },
            .last => {
                self.current = count - 1;
                self.focused = true;
            },
            .toggle => self.toggle(),
            .focus => self.focused = true,
            .blur => self.focused = false,
        }
        return !std.meta.eql(before, self.*);
    }

    fn take(self: *State, target: Target) void {
        switch (target) {
            .none, .scrim => {},
            .item => |index| {
                self.current = index;
                // Lying over the pane, the column has done its job.
                if (self.narrow and self.panel == .shown) self.panel = .auto;
            },
            .toggle => self.toggle(),
        }
    }

    fn toggle(self: *State) void {
        const shown_now = self.shown();
        // Back to what the width says when that is what was asked for, so
        // the next crossing of `narrow_below` acts as if nothing was asked.
        self.panel = if (shown_now == self.narrow) .auto else if (shown_now) .hidden else .shown;
    }

    fn valid(target: Target, count: u8) Target {
        return switch (target) {
            .item => |index| if (index < count) target else .none,
            .none, .toggle, .scrim => target,
        };
    }
};

/// What `begin` opened, for `end`.
pub const Frame = struct {
    root: Index,
    pane: Index,
    section: Index,
};

pub const SectionOptions = struct {
    padding: tree_zig.Edges = .zero,
    /// Between the section's children.
    gap: u8 = 0,
};

/// Writes the frame up to the section's box, which is left open: a column
/// whose children the caller writes, then calls `end`.
pub fn begin(
    tree: *Tree,
    theme: *const Theme,
    groups: []const Group,
    state: *const State,
    section: SectionOptions,
) tree_zig.Error!Frame {
    const root = try tree.open(.{
        .axis = .row,
        .width = .fill,
        .height = .fill,
        .fill = theme.background,
    });
    if (state.shown() and !state.narrow) try column(tree, theme, groups, state);
    const pane = try tree.open(.{ .width = .fill, .height = .fill });
    const header = try tree.open(.{ .axis = .row, .width = .fill, .padding = .all(padding) });
    try toggleButton(tree, theme, state);
    tree.close(header);
    const box = try tree.open(.{
        .width = .fill,
        .height = .fill,
        .padding = section.padding,
        .gap = section.gap,
    });
    return .{ .root = root, .pane = pane, .section = box };
}

/// Closes what `begin` opened and, in a narrow window, writes the column
/// over the pane, with the rest of the pane dimmed.
pub fn end(tree: *Tree, theme: *const Theme, groups: []const Group, state: *const State, frame: Frame) tree_zig.Error!void {
    tree.close(frame.section);
    tree.close(frame.pane);
    tree.close(frame.root);
    if (state.shown() and state.narrow) {
        _ = try tree.leaf(.{ .id = scrim_id, .width = .fill, .height = .fill, .fill = theme.scrim });
        const over = try tree.open(.{ .axis = .row, .height = .fill });
        try column(tree, theme, groups, state);
        tree.close(over);
    }
}

/// The column of `groups` and the line on its right edge.
fn column(tree: *Tree, theme: *const Theme, groups: []const Group, state: *const State) tree_zig.Error!void {
    const box = try tree.open(.{
        .width = .{ .fixed = width },
        .height = .fill,
        .fill = theme.sidebar,
    });
    var index: u8 = 0;
    for (groups) |group| {
        const group_box = try tree.open(.{ .width = .fill, .padding = .all(padding) });
        if (group.label.len > 0) {
            const label = try tree.open(.{
                .axis = .row,
                .width = .fill,
                .height = .{ .fixed = row_height },
                .padding = .symmetric(padding, 0),
                .cross = .center,
            });
            _ = try tree.text(group.label, .{
                .color = theme.foreground.alpha(label_opacity),
                .style = .xs,
            });
            tree.close(label);
        }
        for (group.items) |item| {
            try menuButton(tree, theme, item, index, state);
            index += 1;
        }
        tree.close(group_box);
    }
    tree.close(box);
    _ = try tree.leaf(.{
        .width = .{ .fixed = Theme.border_width },
        .height = .fill,
        .fill = theme.border,
    });
}

fn menuButton(tree: *Tree, theme: *const Theme, item: Item, index: u8, state: *const State) tree_zig.Error!void {
    const active = state.current == index;
    const hovered = std.meta.eql(state.hover, Target{ .item = index });
    const face = try tree.open(.{
        .id = itemId(index),
        .pointer = .hand,
        .axis = .row,
        .width = .fill,
        .height = .{ .fixed = row_height },
        .padding = .symmetric(padding, 0),
        .gap = padding,
        .cross = .center,
        .fill = if (active or hovered) theme.accent else .transparent,
        .border = if (active and state.focused) theme.ring else .transparent,
        .border_width = ring_width,
        .radius = Theme.radius_md,
    });
    if (item.icon != 0) {
        _ = try tree.icon(.{ .codepoint = item.icon, .color = theme.foreground, .size = Theme.icon });
    }
    _ = try tree.text(item.label, .{
        .color = theme.foreground,
        .style = if (active) .sm_medium else .sm,
    });
    tree.close(face);
}

fn toggleButton(tree: *Tree, theme: *const Theme, state: *const State) tree_zig.Error!void {
    const face = try tree.open(.{
        .id = toggle_id,
        .pointer = .hand,
        .width = .{ .fixed = row_height },
        .height = .{ .fixed = row_height },
        .main = .center,
        .cross = .center,
        .fill = if (state.hover == .toggle) theme.accent else .transparent,
        .radius = Theme.radius_md,
    });
    _ = try tree.icon(.{ .codepoint = icons.panel_left, .color = theme.foreground, .size = Theme.icon });
    tree.close(face);
}
