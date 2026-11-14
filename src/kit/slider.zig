//! A horizontal range slider: a track with an active fill segment, a
//! draggable thumb, and an optional value readout.
//!
//! Stateless view function; the surface owns the current `value` in
//! `0.0..1.0`, `focused`, `hovered`, and `disabled`, and maps pointer `x`
//! coordinates via `ratioFromX`.

const std = @import("std");

const Theme = @import("Theme.zig");
const tree_zig = @import("tree.zig");
const Tree = tree_zig.Tree;
const Id = tree_zig.Id;
const Rect = tree_zig.Rect;

pub const track_height: f32 = 6;
pub const thumb_size: f32 = 16;
pub const default_track_width: f32 = 180;
pub const readout_width: f32 = 42;

/// Outer row, hit box, active segment, thumb ring, thumb, inactive segment, readout box & text.
pub const node_max = 8;

pub const Options = struct {
    /// On the track hit box, for `Tree.hitTest` and `ratioFromX`.
    id: Id,
    /// Normalized value in `0.0..1.0`.
    value: f32,
    /// Optional formatted value text shown to the right (e.g. `"85%"`).
    value_label: []const u8 = "",
    track_width: f32 = default_track_width,
    hovered: bool = false,
    focused: bool = false,
    disabled: bool = false,
};

pub fn view(tree: *Tree, theme: *const Theme, options: Options) tree_zig.Error!void {
    const clamped = std.math.clamp(options.value, 0.0, 1.0);
    const presence: f32 = if (options.disabled) 0.5 else 1.0;
    const ring_color = if (options.focused and !options.disabled)
        theme.ring.alpha(Theme.ring_opacity)
    else
        Theme.Color.transparent;

    const row = try tree.open(.{
        .axis = .row,
        .cross = .center,
        .gap = 10,
    });

    const track_w = @max(options.track_width, thumb_size);
    const travel = track_w - thumb_size;
    const active_w = @round(clamped * travel);

    const hit = try tree.open(.{
        .id = options.id,
        .axis = .row,
        .width = .{ .fixed = track_w + Theme.ring_width * 2 },
        .height = .{ .fixed = thumb_size + Theme.ring_width * 2 },
        .cross = .center,
        .pointer = if (options.disabled) .arrow else .hand,
    });

    if (active_w > 0) {
        _ = try tree.leaf(.{
            .width = .{ .fixed = active_w },
            .height = .{ .fixed = track_height },
            .fill = theme.primary.fade(presence),
            .radius = 255,
        });
    }

    const thumb_border = if ((options.hovered or options.focused) and !options.disabled)
        theme.ring
    else
        theme.primary.fade(presence);

    const thumb_ring = try tree.open(.{
        .width = .{ .fixed = thumb_size + Theme.ring_width * 2 },
        .height = .{ .fixed = thumb_size + Theme.ring_width * 2 },
        .padding = .all(Theme.ring_width),
        .main = .center,
        .cross = .center,
        .border = ring_color,
        .border_width = Theme.ring_width,
        .radius = 255,
    });
    _ = try tree.leaf(.{
        .width = .{ .fixed = thumb_size },
        .height = .{ .fixed = thumb_size },
        .fill = theme.background.fade(presence),
        .border = thumb_border,
        .border_width = 2,
        .radius = 255,
    });
    tree.close(thumb_ring);

    const inactive_w = travel - active_w;
    if (inactive_w > 0) {
        _ = try tree.leaf(.{
            .width = .{ .fixed = inactive_w },
            .height = .{ .fixed = track_height },
            .fill = theme.secondary.fade(presence),
            .radius = 255,
        });
    }

    tree.close(hit);

    if (options.value_label.len > 0) {
        const readout = try tree.open(.{
            .axis = .row,
            .width = .{ .fixed = readout_width },
            .main = .end,
            .cross = .center,
        });
        _ = try tree.text(options.value_label, .{
            .color = theme.muted_foreground.fade(presence),
            .style = .sm,
        });
        tree.close(readout);
    }

    tree.close(row);
}

/// Maps a logical pointer `x` coordinate onto `[0.0, 1.0]` along a laid-out
/// slider hit box returned by `view`.
pub fn ratioFromX(rect: Rect, x: f32) f32 {
    const ring: f32 = Theme.ring_width;
    const travel = rect.w - ring * 2 - thumb_size;
    if (travel <= 0) return 0;
    const origin = rect.x + ring + thumb_size * 0.5;
    return std.math.clamp((x - origin) / travel, 0.0, 1.0);
}
