//! The parts every dialog is composed of: `open` .. `close` write the scrim
//! and the card, which holds a `header` (a `title` and a `description`) and
//! a `footer` (a row of buttons). `Phase` fades the whole in and out; a
//! surface keeps one in its state. What opens a dialog is an event to its
//! surface's `update`.

const std = @import("std");

const Theme = @import("Theme.zig");
const button = @import("button.zig");
const motion = @import("motion.zig");
const Tree = @import("Tree.zig");
const Id = Tree.Id;
const Index = Tree.Index;

/// Inside the card.
pub const padding = 24;
/// Between the card's children: the header, any content and the footer.
pub const gap = 16;
/// Between the title and the description.
pub const header_gap = 8;
/// The least distance between the card and the window's edge.
pub const margin = 16;

pub const Phase = union(enum) {
    closed,
    /// Fading in; milliseconds since it started. It already takes input.
    entering: u16,
    open,
    /// Fading out; milliseconds since it started. It no longer takes
    /// input.
    leaving: u16,

    /// 0 (invisible) to 1 (fully shown): the opacity of everything drawn.
    pub fn presence(self: Phase, mode: motion.Mode) f32 {
        return switch (self) {
            .closed => 0,
            .entering => |elapsed| motion.progress(mode, elapsed),
            .open => 1,
            .leaving => |elapsed| 1 - motion.progress(mode, elapsed),
        };
    }

    pub fn acceptsInput(self: Phase) bool {
        return switch (self) {
            .entering, .open => true,
            .closed, .leaving => false,
        };
    }

    /// Milliseconds until the phase needs a `tick`, or null when only an
    /// event can change it: it is closed, or open and at rest.
    pub fn wakeMs(self: Phase) ?u32 {
        return switch (self) {
            .entering, .leaving => motion.frame_ms,
            .closed, .open => null,
        };
    }

    /// Starts fading in, from as far as it had faded out. Returns false,
    /// changing nothing, when it is already entering or open.
    pub fn enter(self: *Phase, mode: motion.Mode) bool {
        const duration = motion.duration(mode);
        self.* = switch (self.*) {
            .entering, .open => return false,
            .closed => .{ .entering = 0 },
            .leaving => |elapsed| .{ .entering = duration - @min(elapsed, duration) },
        };
        return true;
    }

    /// Starts fading in, or jumps straight to `.open` when `mode` has zero duration.
    pub fn enterImmediate(self: *Phase, mode: motion.Mode) bool {
        if (mode == .none) {
            const was_open = self.acceptsInput();
            self.* = .open;
            return !was_open;
        }
        return self.enter(mode);
    }

    /// Starts fading out, from as far as it had faded in. Returns false,
    /// changing nothing, when it is already leaving or closed.
    pub fn leave(self: *Phase, mode: motion.Mode) bool {
        const duration = motion.duration(mode);
        self.* = switch (self.*) {
            .closed, .leaving => return false,
            .entering => |elapsed| .{ .leaving = duration - @min(elapsed, duration) },
            .open => .{ .leaving = 0 },
        };
        return true;
    }

    /// Starts fading out, or jumps straight to `.closed` when `mode` has zero duration.
    pub fn leaveImmediate(self: *Phase, mode: motion.Mode) bool {
        if (mode == .none) {
            const was_open = self.* != .closed;
            self.* = .closed;
            return was_open;
        }
        return self.leave(mode);
    }

    pub const Step = enum {
        /// Nothing moved.
        quiet,
        /// The fade advanced; a redraw is due.
        redraw,
        /// The fade-out ended; a redraw is due.
        closed,
    };

    /// `dt_ms` milliseconds passed.
    pub fn tick(self: *Phase, mode: motion.Mode, dt_ms: u32) Step {
        const dt: u16 = std.math.lossyCast(u16, dt_ms);
        const duration = motion.duration(mode);
        switch (self.*) {
            .closed, .open => return .quiet,
            .entering => |elapsed| {
                const now = elapsed +| dt;
                self.* = if (now >= duration) .open else .{ .entering = now };
                return .redraw;
            },
            .leaving => |elapsed| {
                const now = elapsed +| dt;
                if (now >= duration) {
                    self.* = .closed;
                    return .closed;
                }
                self.* = .{ .leaving = now };
                return .redraw;
            },
        }
    }
};

pub const Position = enum(u8) {
    center,
    top_center,
    bottom_center,

    fn mainAlign(self: Position) Tree.Align {
        return switch (self) {
            .center => .center,
            .top_center => .start,
            .bottom_center => .end,
        };
    }
};

pub const Options = struct {
    /// On the scrim: a click here is beside the card.
    scrim_id: Id,
    card_id: Id,
    /// The card's width in logical pixels, padding included. A narrower
    /// window shrinks it, keeping `margin` on both sides.
    width: f32,
    /// `Phase.presence`.
    presence: f32,
    /// Scrim opacity before `presence` scaling; null keeps `theme.scrim.a`.
    scrim_alpha: ?u8 = null,
    position: Position = .center,
    margin: u8 = margin,
    padding: u8 = padding,
    gap: u8 = gap,
};

/// The two boxes `open` leaves open.
pub const Frame = struct { scrim: Index, card: Index };

/// Nodes the parts write, the texts and the footer's buttons aside: the
/// scrim, the card, the header and the footer.
pub const node_max = 4;

/// Starts a root, the scrim, and the card on it. What is written until
/// `close` is the card's content, top to bottom.
pub fn open(tree: *Tree, theme: *const Theme, options: Options) Tree.Error!Frame {
    return openScrimCard(tree, theme, options, .all(options.padding), options.gap);
}

/// Opens the scrim and card with explicit card padding and child gap so a
/// caller can place full-bleed dividers above a padded footer.
pub fn openScrimCard(
    tree: *Tree,
    theme: *const Theme,
    options: Options,
    card_padding: Tree.Edges,
    card_gap: u8,
) Tree.Error!Frame {
    const scrim_base: Theme.Color = if (options.scrim_alpha) |alpha|
        .{ .r = theme.scrim.r, .g = theme.scrim.g, .b = theme.scrim.b, .a = alpha }
    else
        theme.scrim;
    const scrim = try tree.open(.{
        .id = options.scrim_id,
        .width = .fill,
        .height = .fill,
        .padding = .all(options.margin),
        .main = options.position.mainAlign(),
        .cross = .center,
        .fill = scrim_base.fade(options.presence),
    });
    const card = try tree.open(.{
        .id = options.card_id,
        .width = .{ .at_most = options.width },
        .padding = card_padding,
        .gap = card_gap,
        .fill = theme.popover.fade(options.presence),
        .border = theme.border.fade(options.presence),
        .border_width = Theme.border_width,
        .radius = Theme.radius,
    });
    return .{ .scrim = scrim, .card = card };
}

/// Full-width 1 px horizontal divider for edge-to-edge card sections.
pub fn separator(tree: *Tree, theme: *const Theme, presence: f32) Tree.Error!void {
    _ = try tree.leaf(.{
        .width = .fill,
        .height = .{ .fixed = Theme.border_width },
        .fill = theme.border.fade(presence),
    });
}

pub fn close(tree: *Tree, frame: Frame) void {
    tree.close(frame.card);
    tree.close(frame.scrim);
}

/// Starts the header: `title`, then `description` if there is one. End it
/// with `Tree.close`.
pub fn header(tree: *Tree) Tree.Error!Index {
    return tree.open(.{ .width = .fill, .gap = header_gap });
}

/// What the dialog asks or says, in a few words. `presence` is
/// `Phase.presence`, as for `description`.
pub fn title(tree: *Tree, theme: *const Theme, bytes: []const u8, presence: f32) Tree.Error!void {
    _ = try tree.text(bytes, .{
        .color = theme.foreground.fade(presence),
        .style = .lg_semibold,
        .width = .fill,
    });
}

/// What the title leaves open. Wraps to the card; a line feed starts a new
/// line.
pub fn description(tree: *Tree, theme: *const Theme, bytes: []const u8, presence: f32) Tree.Error!void {
    _ = try tree.text(bytes, .{
        .color = theme.muted_foreground.fade(presence),
        .width = .fill,
    });
}

/// Starts the footer: buttons left to right, pushed to the right edge. By
/// convention the action the dialog is about comes last. End it with
/// `Tree.close`.
pub fn footer(tree: *Tree) Tree.Error!Index {
    return footerPadded(tree, .zero);
}

/// Starts the footer with explicit inner padding inside a zero-padded card.
pub fn footerPadded(tree: *Tree, card_padding: Tree.Edges) Tree.Error!Index {
    return footerBox(tree, card_padding, .row);
}

/// Starts a vertically stacked footer with full-width button slots for narrow cards.
pub fn footerColumn(tree: *Tree, card_padding: Tree.Edges) Tree.Error!Index {
    return footerBox(tree, card_padding, .column);
}

fn footerBox(tree: *Tree, card_padding: Tree.Edges, axis: Tree.Axis) Tree.Error!Index {
    return tree.open(.{
        .axis = axis,
        .width = .fill,
        .padding = card_padding,
        .main = if (axis == .row) .end else .start,
        .cross = .center,
        .gap = button.gap,
    });
}
