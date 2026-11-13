//! A tool with nothing in it, to prove the host and the sidebar frame
//! (ticket 95): a few sections under headings and a pane that names the
//! current one. Opened by the hidden `rex tool` subcommand.

const std = @import("std");

const kit = @import("../kit/root.zig");
const Key = @import("../input/key.zig").Key;
const host = @import("host.zig");

const sidebar = kit.sidebar;
const Theme = kit.Theme;
const Tree = kit.tree.Tree;

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

/// The pane: a column with a title and one line.
pub const node_max = sidebar.nodeMax(&groups) + 3;
pub const line_max = sidebar.lineMax(&groups) + labels_line_max + description.len + 1;

const labels_line_max = blk: {
    var longest = 0;
    for (labels) |label| longest = @max(longest, label.len);
    break :blk longest + 1;
};

pub const State = struct {
    frame: sidebar.State = .empty,

    pub const empty: State = .{};
};

pub fn update(state: *State, event: host.Event) bool {
    const frame = &state.frame;
    return switch (event) {
        .size => |size| frame.update(count, .{ .width = size.width }),
        .pointer => |id| frame.update(count, .{ .pointer = sidebar.hit(id, count) }),
        .press => |id| frame.update(count, .{ .press = sidebar.hit(id, count) }),
        .release => frame.update(count, .release),
        .key => |press| switch (press.key) {
            .up => frame.update(count, .{ .move = .previous }),
            .down => frame.update(count, .{ .move = .next }),
            .home => frame.update(count, .first),
            .end => frame.update(count, .last),
            .f9 => frame.update(count, .toggle),
            else => false,
        },
    };
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
    try sidebar.end(tree, theme, &groups, &state.frame, frame);
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

    var nodes: [node_max]kit.tree.Node = undefined;
    var lines: [line_max]kit.text.Line = undefined;
    var tree = Tree.init(&nodes, &lines);
    try view(&state, &tree, &Theme.dark);
    try testing.expectEqualStrings("Font", tree.nodes[tree.len - 2].content.text.bytes);
}
