//! A tab list: a muted track with one raised tab, or a transparent track
//! with a short indicator on the current tab.
//!
//! It is a view function and keeps nothing. The surface that shows it
//! holds which tab is current, hovered or focused and passes that in.
//! The page under the list is the surface's, not this component's.

const std = @import("std");
const assert = std.debug.assert;

const Theme = @import("Theme.zig");
const Color = Theme.Color;
const Tree = @import("Tree.zig");
const Id = Tree.Id;

/// Padding inside the track, on every side.
pub const inset = 3;
/// Horizontal padding inside a tab face.
pub const pad = 8;
/// Vertical padding inside a horizontal tab face. The face is 26 tall and
/// `sm_medium` has a 20 pixel line height, so three pixels on each side fit.
pub const vertical_pad = 3;

/// No tab: the pointer is elsewhere, or the focus is not on the list.
pub const none: u8 = std.math.maxInt(u8);

pub const Tab = struct {
    /// On the face, for `Tree.hitTest`.
    id: Id,
    /// Borrowed until the view is rebuilt.
    label: []const u8,
};

pub const Variant = enum(u8) {
    /// A muted track with a raised face on the current tab.
    default,
    /// A transparent track with a short indicator on the current tab.
    line,
};

pub const Orientation = enum(u8) {
    horizontal,
    vertical,
};

pub const Options = struct {
    tabs: []const Tab,
    /// Index of the current tab.
    current: u8,
    /// Index under the pointer. `none` when it is elsewhere.
    hovered: u8 = none,
    /// Index with the focus ring. `none` when nothing has it.
    focused: u8 = none,
    /// Width of a horizontal track. `.fill` shares it between the tab faces.
    /// A vertical track sizes itself; it has no equivalent of this field.
    horizontal_width: Tree.Size = .fit,
    variant: Variant = .default,
    orientation: Orientation = .horizontal,
};

/// The track, then each tab's face and label, plus one indicator per tab in
/// the line variant.
pub fn nodeMax(count: usize) usize {
    return 1 + count * 3;
}

/// The horizontal face's height: the track minus the inset above and below it.
pub const horizontal_face_height = Theme.control_sm - 2 * inset;
/// The smallest height of a vertical face. Text and padding make it taller.
pub const vertical_min_height = Theme.control_sm;
/// Thickness of the current-tab indicator in the line variant.
pub const indicator = 2;

/// Writes the list into the innermost open box.
pub fn view(tree: *Tree, theme: *const Theme, options: Options) Tree.Error!void {
    assert(options.tabs.len > 0 and options.tabs.len <= std.math.maxInt(u8));
    assert(options.current < options.tabs.len);
    const horizontal = options.orientation == .horizontal;
    const line = options.variant == .line;
    const track = try tree.open(.{
        .axis = if (horizontal) .row else .column,
        .width = if (horizontal) options.horizontal_width else .{ .fixed = Theme.control_sm },
        .height = if (horizontal) .{ .fixed = Theme.control_sm } else .fit,
        .padding = .all(inset),
        .cross = .center,
        .fill = if (line) .transparent else theme.muted,
        .radius = if (line) 0 else Theme.radius,
        .shrink = false,
    });
    for (options.tabs, 0..) |tab, index| {
        const i: u8 = @intCast(index);
        const current = i == options.current;
        const face = try tree.open(.{
            .id = tab.id,
            .pointer = .hand,
            .axis = if (line) (if (horizontal) .column else .row) else .row,
            .width = if (horizontal) (if (options.horizontal_width == .fill) .fill else .fit) else .fill,
            .height = if (horizontal) .{ .fixed = horizontal_face_height } else .{ .at_least = vertical_min_height },
            .padding = if (horizontal) .symmetric(pad, vertical_pad) else .symmetric(vertical_pad, pad),
            .main = if (horizontal or line) .center else .start,
            .cross = .center,
            .fill = if (current and !line) raisedFill(theme) else .transparent,
            .border = if (line)
                (if (i == options.focused) theme.ring else .transparent)
            else
                border(theme, current, i == options.focused),
            .border_width = Theme.border_width,
            .radius = if (line) 0 else Theme.radius_md,
            .shrink = false,
        });
        _ = try tree.text(tab.label, .{
            .color = if (current or i == options.hovered) theme.foreground else theme.muted_foreground,
            .style = .sm_medium,
        });
        if (line) {
            const mark = try tree.open(.{
                .width = if (horizontal) .fill else .{ .fixed = indicator },
                .height = if (horizontal) .{ .fixed = indicator } else .fill,
                .fill = if (current) theme.foreground else .transparent,
            });
            tree.close(mark);
        }
        tree.close(face);
    }
    tree.close(track);
}

/// Light: the window background on the muted track. Dark: `input` at 30%
/// of its own opacity (white at 4.5%), the active tab in the nova list.
fn raisedFill(theme: *const Theme) Color {
    return if (theme == &Theme.dark) theme.input.fade(0.3) else theme.background;
}

fn border(theme: *const Theme, current: bool, focused: bool) Color {
    if (focused) return theme.ring;
    if (current and theme == &Theme.dark) return theme.input;
    return .transparent;
}
