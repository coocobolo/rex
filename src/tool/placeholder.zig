//! A tool with nothing real in it, to prove the host, the sidebar frame
//! and the popup layer (ticket 95): a few sections under headings, a pane
//! that names the current one, and a dropdown whose list is a popup. The
//! dropdown changes only its own label. Opened by the hidden `rex tool`
//! subcommand.

const std = @import("std");

const kit = @import("../kit/root.zig");
const host = @import("host.zig");

const sidebar = kit.sidebar;
const popup = kit.popup;
const Theme = kit.Theme;
const Tree = kit.tree.Tree;
const Id = kit.tree.Id;

/// Names the lock file and the window.
pub const name = "tool";
pub const title = "Rex tool";

const groups = [_]sidebar.Group{
    .{ .label = "Terminal", .items = &.{
        .{ .label = "Appearance" },
        .{ .label = "Font" },
        .{ .label = "Keyboard" },
    } },
    .{ .label = "Wellbeing", .items = &.{
        .{ .label = "Breaks" },
        .{ .label = "Focus" },
    } },
    .{ .items = &.{.{ .label = "About" }} },
};
const count = sidebar.itemCount(&groups);

/// Each item's label, by item index.
const labels = blk: {
    var result: [count][]const u8 = undefined;
    var index = 0;
    for (groups) |group| {
        for (group.items) |item| {
            result[index] = item.label;
            index += 1;
        }
    }
    break :blk result;
};

const description = "Nothing here yet.";
const choice_label = "Theme";
const choices = [_][]const u8{ "Dark", "Light", "System" };

const trigger_id = Id.of("placeholder.trigger");
const layer_id = Id.of("placeholder.layer");

fn choiceId(index: u8) Id {
    return Id.of("placeholder.choice").item(index);
}

/// The pane: a title, a line, and the dropdown's row, label, trigger,
/// value and chevron; then the popup and its items.
pub const node_max = sidebar.nodeMax(&groups) + 2 + 5 + popup.node_max + choices.len * popup.item_node_max;
pub const line_max = sidebar.lineMax(&groups) + longest(&labels) + description.len + 1 +
    choice_label.len + 1 + longest(&choices) + choices.len * (longest(&choices) + 1);

fn longest(comptime strings: []const []const u8) comptime_int {
    var result = 0;
    for (strings) |s| result = @max(result, s.len);
    return result + 1;
}

/// What the pointer is on, outside the sidebar.
const Over = union(enum) {
    none,
    trigger,
    choice: u8,
};

const Dropdown = union(enum) {
    closed,
    /// The highlighted choice, under the pointer or the keyboard.
    open: u8,
};

pub const State = struct {
    frame: sidebar.State = .empty,
    choice: u8 = 0,
    dropdown: Dropdown = .closed,
    hover: Over = .none,
    pressed: Over = .none,

    pub const empty: State = .{};
};

fn over(id: Id) Over {
    if (id == trigger_id) return .trigger;
    for (0..choices.len) |index| {
        if (id == choiceId(@intCast(index))) return .{ .choice = @intCast(index) };
    }
    return .none;
}

pub fn update(state: *State, event: host.Event) bool {
    const before = state.*;
    switch (event) {
        .size => |size| _ = state.frame.update(count, .{ .width = size.width }),
        .pointer => |id| {
            _ = state.frame.update(count, .{ .pointer = sidebar.hit(id, count) });
            state.hover = over(id);
            switch (state.hover) {
                .choice => |index| if (state.dropdown == .open) {
                    state.dropdown = .{ .open = index };
                },
                .none, .trigger => {},
            }
        },
        .press => |id| switch (state.dropdown) {
            // Like a dialog's scrim, a press beside the list acts at once.
            .open => if (id == layer_id) {
                state.dropdown = .closed;
            } else {
                state.pressed = over(id);
            },
            .closed => if (over(id) == .trigger) {
                state.pressed = .trigger;
            } else {
                _ = state.frame.update(count, .{ .press = sidebar.hit(id, count) });
            },
        },
        .release => {
            _ = state.frame.update(count, .release);
            const pressed = state.pressed;
            state.pressed = .none;
            if (std.meta.eql(pressed, state.hover)) switch (pressed) {
                .none => {},
                .trigger => state.dropdown = .{ .open = state.choice },
                .choice => |index| choose(state, index),
            };
        },
        .key => |press| switch (state.dropdown) {
            .open => |highlight| switch (press.key) {
                .up => state.dropdown = .{ .open = highlight -| 1 },
                .down => state.dropdown = .{ .open = @min(highlight + 1, choices.len - 1) },
                .enter => choose(state, highlight),
                .escape => state.dropdown = .closed,
                else => {},
            },
            .closed => _ = switch (press.key) {
                .up => state.frame.update(count, .{ .move = .previous }),
                .down => state.frame.update(count, .{ .move = .next }),
                .home => state.frame.update(count, .first),
                .end => state.frame.update(count, .last),
                .f9 => state.frame.update(count, .toggle),
                else => false,
            },
        },
    }
    return !std.meta.eql(before, state.*);
}

fn choose(state: *State, index: u8) void {
    state.choice = index;
    state.dropdown = .closed;
}

pub fn view(state: *const State, tree: *Tree, theme: *const Theme) kit.tree.Error!void {
    const frame = try sidebar.begin(tree, theme, &groups, &state.frame, .{ .padding = .symmetric(24, 0), .gap = 8 });
    _ = try tree.text(labels[state.frame.current], .{
        .color = theme.foreground,
        .style = .lg_semibold,
    });
    _ = try tree.text(description, .{
        .color = theme.muted_foreground,
        .style = .sm,
        .width = .fill,
    });
    try dropdownRow(state, tree, theme);
    try sidebar.end(tree, theme, &groups, &state.frame, frame);

    switch (state.dropdown) {
        .closed => {},
        .open => |highlight| {
            const card = try popup.open(tree, theme, .{ .layer_id = layer_id, .anchor = trigger_id });
            for (choices, 0..) |label, index| {
                try popup.item(tree, theme, .{
                    .id = choiceId(@intCast(index)),
                    .label = label,
                    .highlighted = index == highlight,
                    .selected = index == state.choice,
                });
            }
            popup.close(tree, card);
        },
    }
}

fn dropdownRow(state: *const State, tree: *Tree, theme: *const Theme) kit.tree.Error!void {
    const row = try tree.open(.{ .axis = .row, .gap = 16, .cross = .center });
    _ = try tree.text(choice_label, .{ .color = theme.foreground, .style = .sm_medium });
    const touched = state.hover == .trigger or state.dropdown == .open;
    const trigger = try tree.open(.{
        .id = trigger_id,
        .axis = .row,
        .width = .{ .at_least = 160 },
        .height = .{ .fixed = Theme.control },
        .padding = .symmetric(12, 0),
        .gap = 8,
        .cross = .center,
        .fill = if (touched) theme.accent else .transparent,
        .border = theme.input,
        .border_width = Theme.border_width,
        .radius = Theme.radius_md,
    });
    _ = try tree.text(choices[state.choice], .{ .color = theme.foreground, .width = .fill });
    _ = try tree.icon(.{ .codepoint = kit.icons.chevron_down, .color = theme.muted_foreground, .size = Theme.icon });
    tree.close(trigger);
    tree.close(row);
}

test "placeholder: the pane follows the menu, by keyboard and by pointer" {
    const testing = std.testing;
    var state: State = .empty;
    try testing.expect(update(&state, .{ .key = .{ .key = .down } }));
    try testing.expect(update(&state, .{ .key = .{ .key = .down } }));
    try testing.expectEqual(2, state.frame.current);
    try testing.expect(update(&state, .{ .key = .{ .key = .end } }));
    try testing.expectEqual(count - 1, state.frame.current);
    try testing.expect(!update(&state, .{ .key = .{ .key = .a } }));

    try testing.expect(update(&state, .{ .press = sidebar.itemId(1) }));
    try testing.expect(update(&state, .release));
    try testing.expectEqual(1, state.frame.current);
    try testing.expect(!state.frame.focused);

    try testing.expect(update(&state, .{ .key = .{ .key = .f9 } }));
    try testing.expect(!state.frame.shown());
}

test "placeholder: the dropdown opens on release, chooses, and closes beside the list" {
    const testing = std.testing;
    var state: State = .empty;
    try testing.expect(update(&state, .{ .pointer = trigger_id }));
    try testing.expect(update(&state, .{ .press = trigger_id }));
    try testing.expectEqual(Dropdown.closed, state.dropdown);
    try testing.expect(update(&state, .release));
    try testing.expectEqual(Dropdown{ .open = 0 }, state.dropdown);

    // The keyboard belongs to the list while it is open.
    try testing.expect(update(&state, .{ .key = .{ .key = .down } }));
    try testing.expectEqual(0, state.frame.current);
    try testing.expect(update(&state, .{ .key = .{ .key = .enter } }));
    try testing.expectEqual(1, state.choice);
    try testing.expectEqual(Dropdown.closed, state.dropdown);

    // By pointer: the highlight follows it, release takes the choice.
    _ = update(&state, .{ .pointer = trigger_id });
    _ = update(&state, .{ .press = trigger_id });
    _ = update(&state, .release);
    try testing.expect(update(&state, .{ .pointer = choiceId(2) }));
    try testing.expectEqual(Dropdown{ .open = 2 }, state.dropdown);
    _ = update(&state, .{ .press = choiceId(2) });
    try testing.expect(update(&state, .release));
    try testing.expectEqual(2, state.choice);

    // A press beside the list closes it and reaches nothing else.
    _ = update(&state, .{ .pointer = trigger_id });
    _ = update(&state, .{ .press = trigger_id });
    _ = update(&state, .release);
    try testing.expect(update(&state, .{ .press = layer_id }));
    try testing.expectEqual(Dropdown.closed, state.dropdown);
    try testing.expect(!update(&state, .release));
    try testing.expectEqual(2, state.choice);

    // Esc closes it without choosing.
    _ = update(&state, .{ .pointer = trigger_id });
    _ = update(&state, .{ .press = trigger_id });
    _ = update(&state, .release);
    try testing.expect(update(&state, .{ .key = .{ .key = .escape } }));
    try testing.expectEqual(Dropdown.closed, state.dropdown);
    try testing.expectEqual(2, state.choice);
}

test "placeholder: the worst view fits its buffers" {
    const testing = std.testing;
    var nodes: [node_max]kit.tree.Node = undefined;
    var lines: [line_max]kit.text.Line = undefined;
    var tree = Tree.init(&nodes, &lines);
    var state: State = .empty;
    _ = update(&state, .{ .size = .{ .width = 500, .height = 400 } });
    _ = update(&state, .{ .key = .{ .key = .f9 } });
    state.dropdown = .{ .open = 0 };
    try view(&state, &tree, &Theme.dark);
    try testing.expect(tree.anchor_len == 1);
}
