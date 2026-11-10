//! Cursor state, styles, saved cursor (DECSC/SCOSC), and cursor position helpers.

const std = @import("std");

const Attr = @import("cell.zig").Attr;
const AttrFlags = @import("cell.zig").AttrFlags;
const Colors = @import("Style.zig");
const CharsetState = @import("charset.zig").CharsetState;

pub const Cursor = @This();

/// Cursor rendering styles.
///
/// IMPORTANT: The numeric values are part of the implementation.
/// * even discriminants represents blinking styles.
/// * odd discriminants represents steady styles.
///
/// DO NOT reorder or renumber these values unless all parity-based
/// code (e.g. `CursorStyle.blink()`, shaders instance flags) is updated.
pub const Style = enum(u3) {
    blinking_block = 0,
    steady_block = 1,
    blinking_underline = 2,
    steady_underline = 3,
    blinking_beam = 4,
    steady_beam = 5,

    comptime {
        for ([_]Style{ .blinking_block, .blinking_underline, .blinking_beam }) |style| {
            std.debug.assert((@intFromEnum(style) & 1) == 0);
        }

        for ([_]Style{ .steady_block, .steady_underline, .steady_beam }) |style| {
            std.debug.assert((@intFromEnum(style) & 1) == 1);
        }
    }

    pub const default: Style = .blinking_block;

    pub const Blink = enum {
        /// steady (visible)
        off,
        /// blinking
        on,
    };

    /// Returns the geometric shape, independent of blink mode.
    /// Use this to select the draw path in the Renderer.
    pub const Shape = enum { block, underline, beam };

    /// Returns whether cursor style blinks.
    pub inline fn blink(self: Style) Blink {
        return if ((@intFromEnum(self) & 1) == 0) .on else .off;
    }

    /// Cursor Shape encoding:
    /// bits 1-2: shape (0 = block, 1 = underline, 2 = beam)
    pub fn shape(self: Style) Shape {
        return @enumFromInt(@intFromEnum(self) >> 1);
    }
};

/// 0-indexed logical row within the active screen grid.
row: u16 = 0,
/// 0-indexed column within the active screen grid.
col: u16 = 0,
/// Active pen attributes applied to printed cells.
attr: Attr = .{},
/// Pending wrap state: cursor reached the right margin and will wrap on next printable character.
wrap_pending: bool = false,
/// Origin mode (DECOM): cursor coordinates are relative to the scroll margins.
origin: bool = false,
/// Active visual style and blink mode.
style: Style = .default,
/// Active character set mapping state (G0-G3 slots and single-shift).
charset: CharsetState = .{},

pub fn position(self: *const Cursor) struct { u16, u16 } {
    return .{ self.row, self.col };
}

comptime {
    std.debug.assert(32 == @sizeOf(Cursor));
}

/// Saved cursor state for DECSC (`ESC 7`) and SCOSC (`CSI s`).
pub const Saved = struct {
    row: u16 = 0,
    col: u16 = 0,
    origin: bool = false,
    /// The pen's attributes and colors. Not its style IDs: they may be
    /// stale by DECRC, which interns the colors again.
    flags: AttrFlags = .{},
    colors: Colors = .default,
    style: Style = .steady_block,
    charset: CharsetState = .{},
    charset_is_identity: bool = true,
};

comptime {
    std.debug.assert(28 == @sizeOf(Saved));
}

test "Cursor: position and style shape" {
    const c = Cursor{ .row = 5, .col = 12 };
    const pos = c.position();
    try std.testing.expectEqual(5, pos[0]);
    try std.testing.expectEqual(12, pos[1]);
    try std.testing.expectEqual(32, @sizeOf(Cursor));

    try std.testing.expectEqual(Cursor.Style.Shape.block, Cursor.Style.blinking_block.shape());
    try std.testing.expectEqual(Cursor.Style.Blink.on, Cursor.Style.blinking_block.blink());
    try std.testing.expectEqual(Cursor.Style.Shape.underline, Cursor.Style.blinking_underline.shape());
    try std.testing.expectEqual(Cursor.Style.Shape.beam, Cursor.Style.steady_beam.shape());
    try std.testing.expectEqual(Cursor.Style.Blink.off, Cursor.Style.steady_beam.blink());

    const saved = Saved{};
    try std.testing.expectEqual(0, saved.row);
    try std.testing.expectEqual(0, saved.col);
    try std.testing.expectEqual(Cursor.Style.steady_block, saved.style);
    try std.testing.expectEqual(28, @sizeOf(Saved));
}
