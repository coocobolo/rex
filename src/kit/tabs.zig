//! A tab list: a muted track with one raised tab for the current item.
//!
//! It is a view function and keeps nothing. The surface that shows it
//! holds which tab is current, hovered or focused and passes that in.
//! The page under the list is the surface's, not this component's.

const std = @import("std");
const assert = std.debug.assert;

const Theme = @import("Theme.zig");
const Color = Theme.Color;
const tree_zig = @import("tree.zig");
const Tree = tree_zig.Tree;
const Id = tree_zig.Id;

/// Padding inside the track, on every side.
pub const inset = 3;
/// Horizontal padding inside a tab face.
pub const pad = 8;

/// No tab: the pointer is elsewhere, or the focus is not on the list.
pub const none: u8 = std.math.maxInt(u8);

pub const Tab = struct {
    /// On the face, for `Tree.hitTest`.
    id: Id,
    /// Borrowed until the view is rebuilt.
    label: []const u8,
};

pub const Options = struct {
    tabs: []const Tab,
    /// Index of the raised tab.
    current: u8,
    /// Index under the pointer. `none` when it is elsewhere.
    hovered: u8 = none,
    /// Index with the focus ring. `none` when nothing has it.
    focused: u8 = none,
};

/// The track, then each tab's face and its label.
pub fn nodeMax(count: usize) usize {
    return 1 + count * 2;
}

/// The face's height: the track minus the inset above and below it.
pub const face_height = Theme.control_sm - 2 * inset;

/// Writes the list into the innermost open box.
pub fn view(tree: *Tree, theme: *const Theme, options: Options) tree_zig.Error!void {
    assert(options.tabs.len > 0 and options.tabs.len <= std.math.maxInt(u8));
    assert(options.current < options.tabs.len);
    const track = try tree.open(.{
        .axis = .row,
        .height = .{ .fixed = Theme.control_sm },
        .padding = .all(inset),
        .cross = .center,
        .fill = theme.muted,
        .radius = Theme.radius,
    });
    for (options.tabs, 0..) |tab, index| {
        const i: u8 = @intCast(index);
        const current = i == options.current;
        const face = try tree.open(.{
            .id = tab.id,
            .pointer = .hand,
            .height = .{ .fixed = face_height },
            .padding = .symmetric(pad, 0),
            .main = .center,
            .cross = .center,
            .fill = if (current) raisedFill(theme) else .transparent,
            .border = border(theme, current, i == options.focused),
            .border_width = Theme.border_width,
            .radius = Theme.radius_md,
        });
        _ = try tree.text(tab.label, .{
            .color = if (current or i == options.hovered) theme.foreground else theme.muted_foreground,
            .style = .sm_medium,
        });
        tree.close(face);
    }
    tree.close(track);
}

/// Light: the window background on the muted track. Dark: `input` at 30%,
/// the active tab in the nova list.
fn raisedFill(theme: *const Theme) Color {
    return if (theme == &Theme.dark) theme.input.alpha(30) else theme.background;
}

fn border(theme: *const Theme, current: bool, focused: bool) Color {
    if (focused) return theme.ring;
    if (current and theme == &Theme.dark) return theme.input;
    return .transparent;
}
