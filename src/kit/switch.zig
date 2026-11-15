//! A toggle switch for a boolean setting: a 36x20 px pill track with a
//! 16 px thumb that sits left when off and right when on.
//!
//! Stateless view function; the surface owns `checked`, `focused`, and
//! `disabled` and handles clicks by `id`.

const Theme = @import("Theme.zig");
const focus = @import("focus.zig");
const Tree = @import("Tree.zig");
const Id = Tree.Id;

pub const track_width: f32 = 36;
pub const track_height: f32 = 20;
pub const thumb_size: f32 = 16;
pub const pad: u8 = 2;

/// Focus wrapper, track, and thumb.
pub const node_max = 3;

pub const Options = struct {
    /// On the outer wrapper, focus ring included, for `Tree.hitTest`.
    id: Id,
    checked: bool = false,
    focused: bool = false,
    disabled: bool = false,
};

pub fn view(tree: *Tree, theme: *const Theme, options: Options) Tree.Error!void {
    const presence: f32 = if (options.disabled) 0.5 else 1.0;
    const ring = try focus.openRing(tree, .{
        .id = options.id,
        .pointer = if (options.disabled) .arrow else .hand,
        .border = focus.ringColor(theme, .{
            .focused = options.focused,
            .disabled = options.disabled,
        }),
        .inner_radius = 255,
        .shrink = false,
    });

    const track_fill = (if (options.checked) theme.primary else theme.input).fade(presence);
    const left_pad: u8 = if (options.checked)
        @as(u8, @intFromFloat(track_width - thumb_size)) - pad
    else
        pad;

    const track = try tree.open(.{
        .width = .{ .fixed = track_width },
        .height = .{ .fixed = track_height },
        .axis = .row,
        .cross = .center,
        .padding = .{ .left = left_pad, .right = pad, .top = pad, .bottom = pad },
        .fill = track_fill,
        .radius = 255,
    });
    _ = try tree.leaf(.{
        .width = .{ .fixed = thumb_size },
        .height = .{ .fixed = thumb_size },
        .fill = theme.background.fade(presence),
        .radius = 255,
    });
    tree.close(track);
    tree.close(ring);
}
