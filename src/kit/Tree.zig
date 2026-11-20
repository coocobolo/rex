//! The flat node array a view builds: boxes, texts and icons in the order
//! they are drawn, each knowing its parent and where its descendants end.
//! Layout (`layout.zig`) fills in every node's rectangle; painting and
//! hit-testing then read the same array.
//!
//! A view rebuilds the whole array whenever its state changes. The array
//! and the texts it points to belong to the caller: `Tree` allocates
//! nothing, and running out of nodes is `error.OutOfNodes`, never a
//! silently missing box (ADR 0009).

const std = @import("std");
const assert = std.debug.assert;

const Color = @import("Theme.zig").Color;
const Figures = @import("text.zig").Figures;
const Line = @import("text.zig").Line;
const Lines = @import("text.zig").Lines;
const Measurer = @import("text.zig").Measurer;
const Style = @import("text.zig").Style;

const Tree = @This();

pub const Index = u16;
/// No node: the parent of a root.
pub const none: Index = std.math.maxInt(Index);

/// Laid-out bounds of a `Node` in logical pixels (origin at window top-left).
///
/// Computed by `layout` from `Box` rules; views never construct `Rect` directly.
/// Read by hit-testing (`Tree.hit`), painting (`KitPainter`), and `node_rect` lookups.
pub const Rect = struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,

    pub fn contains(self: Rect, x: f32, y: f32) bool {
        return x >= self.x and x < self.x + self.w and y >= self.y and y < self.y + self.h;
    }
};

/// A stable name for a node, so hit-testing and per-widget memory can find
/// it again after the array is rebuilt. `none` for nodes nothing refers to.
pub const Id = enum(u32) {
    none = 0,
    _,

    /// The id for `name`, which must be unique in its view.
    pub fn of(comptime name: []const u8) Id {
        return comptime fromHash(std.hash.Fnv1a_32.hash(name));
    }

    /// The id of entry `index` in a list named by `self`, such as one
    /// toast in a stack.
    pub fn item(self: Id, index: u32) Id {
        var hasher = std.hash.Fnv1a_32.init();
        hasher.update(std.mem.asBytes(&@intFromEnum(self)));
        hasher.update(std.mem.asBytes(&index));
        return fromHash(hasher.final());
    }

    fn fromHash(hash: u32) Id {
        // 0 is `none`.
        return @enumFromInt(if (hash == 0) 1 else hash);
    }
};

/// Sizing constraint along one axis, set on `Box.width` and `Box.height`.
///
///   `.fit`: shrink-wraps content; may shrink on overflow unless `Box.shrink == false`.
///   `.fill`: divides remaining parent space equally among `.fill` siblings.
///   `.fixed`: exact logical pixel size; never shrinks or grows.
///   `.at_most`: prefers this size, shrinking only if the parent has less room (`min(n, parent)`).
///   `.fit_at_most`: shrink-wraps content, capped at this many logical pixels (`min(content, n)`), and shrinks further if the parent has less room.
///   `.at_least`: shrink-wraps content, clamped up to at least this many logical pixels.
///   `.fraction`: fraction (`0..1`) of the parent's inner extent; ignored when computing a `.fit` parent's size.
pub const Size = union(enum) {
    /// As large as its content.
    fit,
    /// Shares the space its parent has left with the other `fill` nodes.
    fill,
    /// This many logical pixels.
    fixed: f32,
    /// This many logical pixels, or what the parent has room for when that
    /// is less.
    at_most: f32,
    /// As large as its content, up to this many logical pixels (and less
    /// when the parent is smaller).
    fit_at_most: f32,
    /// As large as its content, but not smaller than this many logical
    /// pixels.
    at_least: f32,
    /// This fraction of the parent's inner size, from 0 to 1. A value
    /// outside that range is clamped. It does not enlarge a parent that
    /// is sizing to its content.
    fraction: f32,
};

/// The direction a box lays its children out in.
pub const Axis = enum(u1) { row, column };

/// Where children sit along an axis when there is room to spare.
pub const Align = enum(u2) { start, center, end };

/// Screen edge or corner for pinning viewport-sized overlay surfaces (`toast`, `alert`, `wellbeing_widget`).
///
/// Use `ScreenAnchor` when docking relative to the whole window; use `Anchor` (`anchorTo` / `anchorAt`)
/// when placing a popup or tooltip beside another node or pointer coordinate.
pub const ScreenAnchor = enum(u8) {
    top_left,
    top_center,
    top_right,
    bottom_left,
    bottom_center,
    bottom_right,

    /// Vertical alignment along a full-viewport column root.
    pub fn mainAlign(self: ScreenAnchor) Align {
        return if (self.isTop()) .start else .end;
    }

    /// Horizontal alignment across a full-viewport column root.
    pub fn crossAlign(self: ScreenAnchor) Align {
        return switch (self) {
            .top_left, .bottom_left => .start,
            .top_center, .bottom_center => .center,
            .top_right, .bottom_right => .end,
        };
    }

    /// Whether the anchor attaches to the top edge of the viewport.
    pub fn isTop(self: ScreenAnchor) bool {
        return switch (self) {
            .top_left, .top_center, .top_right => true,
            .bottom_left, .bottom_center, .bottom_right => false,
        };
    }
};

/// Descendant clipping behavior when children extend past this node's `Rect`.
///
/// Use `.clip` on scroll viewports, rounded cards/popups, or truncated panes; keep `.visible` elsewhere.
pub const Overflow = enum(u1) {
    /// Draws them and lets them be hit anywhere.
    visible,
    /// Cuts them at its rectangle (following `Box.radius` when positive),
    /// for painting and rectangular hit-testing.
    clip,
};

/// Cursor shape requested when hovering a node with a non-`.none` `Id`.
pub const PointerShape = enum(u2) {
    arrow,
    /// Interactive target such as a button, switch, or menu item.
    hand,
    /// Editable or selectable text input.
    text,
};

/// Four-sided spacing in logical pixels, used on `Box.padding`.
pub const Edges = struct {
    left: u8 = 0,
    top: u8 = 0,
    right: u8 = 0,
    bottom: u8 = 0,

    pub const zero: Edges = .{};

    pub fn all(value: u8) Edges {
        return .{ .left = value, .top = value, .right = value, .bottom = value };
    }

    pub fn symmetric(horizontal: u8, vertical: u8) Edges {
        return .{ .left = horizontal, .top = vertical, .right = horizontal, .bottom = vertical };
    }
};

/// Input layout rules, appearance, and hit identity for a `Node`.
///
/// Passed to `Tree.open` (container with children), `Tree.leaf` (styled rectangle/spacer/rule),
/// or `Tree.arc`. Holds what the view *asks for*; `Node.rect` holds the resulting coordinates
/// after `layout` runs.
pub const Box = struct {
    width: Size = .fit,
    height: Size = .fit,
    fill: Color = .transparent,
    border: Color = .transparent,
    id: Id = .none,
    padding: Edges = .zero,
    /// Space between children along `axis`.
    gap: u8 = 0,
    radius: u8 = 0,
    border_width: u8 = 0,
    axis: Axis = .column,
    /// Along `axis`.
    main: Align = .start,
    /// Across `axis`.
    cross: Align = .start,
    overflow: Overflow = .visible,
    /// Applies only to a node with an id: the shape is taken from the node
    /// `Tree.hit` finds.
    pointer: PointerShape = .arrow,
    /// Drawn over the parent's padding box, and not counted in the
    /// parent's size. Several share one square, as the slices of a donut do.
    overlay: bool = false,
    /// Whether `.fit`/`.at_most`/`.fit_at_most`/`.at_least` children may shrink below intrinsic size on overflow.
    shrink: bool = true,
    /// Wrap overflowing `.row` children onto extra lines using `gap` between lines (`axis == .row` only).
    wrap: bool = false,
};

/// Internal payload for a text `Node` stored in `Node.Content.text`.
///
/// Views construct text nodes via `Tree.text(bytes, Text.Options)` rather than filling `Text`
/// directly; `first_line` and `line_count` are populated by `layout`.
pub const Text = struct {
    /// How lines fit within the laid-out text node width.
    pub const Wrap = enum(u8) {
        /// Wraps at spaces and `\n` to fit the width.
        word,
        /// Never wraps at spaces; breaks only at explicit `\n`.
        none,
        /// Single line, truncated at UTF-8 codepoint boundaries with `"…"` if wider than the box.
        ellipsis,
    };

    /// Text presentation and flow options passed to `Tree.text`.
    pub const Options = struct {
        color: Color,
        style: Style = .sm,
        figures: Figures = .proportional,
        wrap: Wrap = .word,
        alignment: Align = .start,
        /// `fit` keeps the text on one line where there is room; `fill`
        /// takes the width the parent has left and wraps to it.
        width: Size = .fit,
        id: Id = .none,
        shrink: bool = true,
    };

    /// Borrowed: must stay valid until the view is rebuilt.
    bytes: []const u8,
    color: Color,
    style: Style = .sm,
    /// Digit spacing. Proportional leaves the font's advances alone.
    figures: Figures = .proportional,
    wrap: Wrap = .word,
    alignment: Align = .start,
    /// Its lines in the tree's `Lines`, set by layout.
    first_line: u32 = 0,
    line_count: u32 = 0,
};

/// Bundled icon glyph specification passed to `Tree.icon`.
pub const Icon = struct {
    /// Glyph code point from `icons.zig`.
    codepoint: u21,
    color: Color,
    /// Square edge length in logical pixels.
    size: u8,
};

/// Horizontal dashed rule specification passed to `Tree.dash`.
pub const Dash = struct {
    color: Color,
    /// Dash and gap length in logical pixels; `0` draws a solid rule.
    step: u8,
};

/// Circular ring or gauge segment specification passed to `Tree.arc`.
///
/// Sized as a square of side `2 * radius`; `thickness` extends inward and angles run
/// clockwise in radians from 12 o'clock.
pub const Arc = struct {
    /// Endpoint finish for an `Arc` stroke: `.butt` for flat pie/donut segments, `.round` for gauges.
    pub const Caps = enum(u8) {
        butt,
        round,
    };

    radius: f32,
    thickness: f32,
    /// Starting angle in radians (`0` = top).
    start: f32 = 0,
    /// Clockwise sweep length in radians (`2π` = full circle).
    sweep: f32,
    fill: Color,
    caps: Caps = .butt,
};

/// Serpentine progress ribbon specification passed to `Tree.coil`.
///
/// Snakes continuously down and up across `columns` vertical legs joined by alternating
/// 180-degree semicircular U-turns, filling `fraction` (`0..1`) of total arc length in
/// `fill` over an optional `track` color.
pub const Coil = struct {
    fill: Color,
    track: Color = .transparent,
    /// Elapsed fraction of total ribbon arc length, clamped to `0..1`.
    fraction: f32,
    /// Stroke thickness in logical pixels.
    thickness: f32,
    /// Number of vertical legs across the node's width (`>= 2`).
    columns: u8 = 16,
};

/// One flat entry in `Tree.nodes`: pairs input rules (`box`, `content`), computed `layout`
/// geometry (`rect`), and array slice bounds (`parent`, `end`).
pub const Node = struct {
    /// Payload variant of a `Node` (`box` container/leaf vs `text`, `icon`, `dash`, `border_sweep`, `arc`, or `coil` primitive).
    pub const Content = union(enum) {
        box,
        text: Text,
        icon: Icon,
        dash: Dash,
        border_sweep: u16,
        arc: Arc,
        coil: Coil,
    };

    /// Set by layout.
    rect: Rect = .{},
    content: Content,
    box: Box,
    parent: Index,
    /// One past this node's last descendant, so its children are found by
    /// stepping from `index + 1` by each child's `end`.
    end: Index,
};

pub const Error = error{ OutOfNodes, OutOfAnchors, OutOfScrollRegions };

/// Attachment record binding a top-level root to an earlier node or point (`popup`, `tooltip`).
///
/// Use for popups/tooltips positioned against a trigger or cursor; use `ScreenAnchor` for screen corners.
pub const Anchor = struct {
    /// Preferred placement side relative to the target rectangle; `.auto` tries all four sides.
    pub const Side = enum(u8) { auto, below, above, left, right };

    /// Cross-axis alignment along the anchored edge; `.flush` centers and snaps inside viewport margins.
    pub const Alignment = enum(u8) { start, center, end, flush };

    /// Placement rules stored inline on an `Anchor`.
    pub const Options = struct {
        side: Side = .below,
        alignment: Alignment = .start,
        match_anchor_width: bool = true,
        gap: u8 = 4,
        margin: u8 = 8,
    };

    pub const Point = extern struct { x: f32, y: f32 };

    /// What a floating root anchors against: an earlier node's `Id` (`anchorTo`) or screen point (`anchorAt`).
    pub const Target = union(enum) {
        node: Id,
        point: Point,
    };

    const Payload = extern union {
        node: Id,
        point: Point,
    };

    payload: Payload,
    /// Root node index being positioned.
    node: Index,
    kind: enum(u8) { node, point },
    side: Side = .below,
    alignment: Alignment = .start,
    match_anchor_width: bool = true,
    gap: u8 = 4,
    margin: u8 = 8,

    pub fn target(self: Anchor) Target {
        return switch (self.kind) {
            .node => .{ .node = self.payload.node },
            .point => .{ .point = self.payload.point },
        };
    }

    pub fn options(self: Anchor) Options {
        return .{
            .side = self.side,
            .alignment = self.alignment,
            .match_anchor_width = self.match_anchor_width,
            .gap = self.gap,
            .margin = self.margin,
        };
    }
};

/// Maximum anchored roots (popups/tooltips) per frame.
pub const anchor_max = 4;

/// Per-region scroll state and visibility helpers owned by `Tree`.
pub const Scroll = struct {
    /// Maximum independent scrolling clipping boxes per `Tree`.
    pub const max = 8;

    /// Overlay scrollbar thumb and hit-strip geometry in logical pixels.
    pub const thumb_thickness: f32 = 4;
    pub const thumb_inset: f32 = 2;
    pub const thumb_track_pad: f32 = 4;
    pub const thumb_min_len: f32 = 24;
    /// Grab-strip thickness along the active scroll edge for pointer hit-testing.
    pub const hit_thickness: f32 = 12;

    /// Which part of a visible scrollbar the pointer hit.
    pub const Part = enum(u8) { thumb, track };

    /// Hit-test result for a visible overlay scrollbar at a pointer coordinate.
    pub const ScrollbarHit = struct {
        region: Region,
        track_start: f32,
        track_len: f32,
        thumb_start: f32,
        thumb_len: f32,
        /// `.column` for a vertical scrollbar, `.row` for a horizontal scrollbar.
        axis: Axis,
        part: Part,
    };

    /// Requested content shift in logical pixels (`x` left, `y` up).
    pub const Offset = struct {
        x: f32 = 0,
        y: f32 = 0,
    };

    /// Maximum scrollable extent in logical pixels reported by `layout`.
    pub const Max = struct {
        x: f32 = 0,
        y: f32 = 0,
    };

    /// Laid-out bounds and offsets for one registered `Tree.scrollRegion`.
    pub const Region = struct {
        id: Id = .none,
        node: Index = none,
        thumb: Index = none,
        offset: Offset = .{},
        max: Max = .{},
    };

    /// Adjusts a single-axis scroll `offset` minimally so `[item_pos, item_pos + item_size]`
    /// sits inside `[view_pos, view_pos + view_size]` with `margin` clearance.
    pub fn ensureVisibleAxis(
        offset: f32,
        limit: ?f32,
        view_pos: f32,
        view_size: f32,
        item_pos: f32,
        item_size: f32,
        margin: f32,
    ) f32 {
        const current = if (std.math.isNan(offset))
            0
        else if (limit) |m|
            std.math.clamp(offset, 0, @max(0, m))
        else
            @max(0, offset);
        const pad = @max(0, @min(margin, @max(0, (view_size - item_size) / 2)));
        var next = current;
        if (item_pos < view_pos + pad) {
            next = @max(0, current - (view_pos + pad - item_pos));
        } else if (item_pos + item_size > view_pos + view_size - pad) {
            const delta = @min(item_pos + item_size - (view_pos + view_size - pad), @max(0, item_pos - view_pos));
            next = current + delta;
        }
        if (std.math.isNan(next)) return 0;
        return if (limit) |m| std.math.clamp(next, 0, @max(0, m)) else @max(0, next);
    }

    /// Two-dimensional `ensureVisibleAxis` keeping `target` inside `viewport` with `margin`.
    pub fn ensureVisibleRect(
        viewport: Rect,
        target: Rect,
        margin: f32,
        offset: Offset,
        limit: ?Max,
    ) Offset {
        return .{
            .x = ensureVisibleAxis(offset.x, if (limit) |m| m.x else null, viewport.x, viewport.w, target.x, target.w, margin),
            .y = ensureVisibleAxis(offset.y, if (limit) |m| m.y else null, viewport.y, viewport.h, target.y, target.h, margin),
        };
    }
};

nodes: []Node,
len: Index = 0,
/// The innermost open box; new nodes become its children.
current: Index = none,
anchor_len: u8 = 0,
scroll_len: u8 = 0,
/// Descendant node (such as an active text input caret) kept horizontally
/// visible inside its enclosing `id == .none` scroll region during `layout`.
scroll_follow: Index = none,
lines: Lines,
anchors: [anchor_max]Anchor = undefined,
/// Registered scroll regions (`scrollRegion`), kept sorted by ascending `node`.
scrolls: [Scroll.max]Scroll.Region = undefined,

/// `nodes` and `lines` are the caller's and bound how much one view
/// can hold.
pub fn init(nodes: []Node, lines: []Line) Tree {
    assert(nodes.len < none);
    return .{ .nodes = nodes, .lines = .init(lines) };
}

/// Empties the tree for the next view.
pub fn reset(self: *Tree) void {
    self.len = 0;
    self.current = none;
    self.anchor_len = 0;
    self.scroll_len = 0;
    self.scroll_follow = none;
    self.lines.len = 0;
}

/// Makes the clipping box `index` scroll on `x` and `y`: content keeps its
/// intrinsic extent along open overflow and shifts by `offset` logical pixels,
/// clamped by `layout` to `[0, Region.max]`.
pub fn scrollRegion(self: *Tree, index: Index, offset: Scroll.Offset) Error!void {
    assert(index < self.len);
    assert(self.nodes[index].content == .box and self.nodes[index].box.overflow == .clip);
    assert(!self.hasScrollRegion(index));
    if (self.scroll_len == Scroll.max) return error.OutOfScrollRegions;
    var insert_at: usize = self.scroll_len;
    while (insert_at > 0 and self.scrolls[insert_at - 1].node > index) : (insert_at -= 1) {
        self.scrolls[insert_at] = self.scrolls[insert_at - 1];
    }
    self.scrolls[insert_at] = .{
        .id = self.nodes[index].box.id,
        .node = index,
        .offset = offset,
    };
    self.scroll_len += 1;
}

/// Attaches overlay node `thumb` as the scrollbar thumb for registered scroll region `index`.
pub fn scrollThumb(self: *Tree, index: Index, thumb: Index) void {
    assert(thumb < self.len);
    assert(self.nodes[thumb].parent == index);
    assert(self.nodes[thumb].box.overlay);
    for (self.scrolls[0..self.scroll_len]) |*region| {
        if (region.node == index) {
            region.thumb = thumb;
            return;
        }
    }
    unreachable;
}

/// Marks `index` (such as an active input caret) to be kept horizontally
/// visible inside its enclosing anonymous scroll region during `layout`.
pub fn scrollFollow(self: *Tree, index: Index) void {
    assert(index < self.len);
    self.scroll_follow = index;
}

/// Laid-out scroll bounds for the region with `id`, or zeros if not registered.
pub fn scrollMax(self: *const Tree, id: Id) Scroll.Max {
    for (self.scrolls[0..self.scroll_len]) |region| {
        if (region.id == id) return region.max;
    }
    return .{};
}

/// Registered scroll region record for node `index`, if any.
pub fn scrollOf(self: *const Tree, index: Index) ?Scroll.Region {
    for (self.scrolls[0..self.scroll_len]) |region| {
        if (region.node == index) return region;
    }
    return null;
}

/// Whether node `index` is registered as a scrolling region.
pub fn hasScrollRegion(self: *const Tree, index: Index) bool {
    return self.scrollOf(index) != null;
}

/// Topmost unoccluded scroll region containing `(x, y)` that can scroll along
/// the nonzero component(s) of `(dx, dy)`.
pub fn scrollTargetAt(self: *const Tree, x: f32, y: f32, dx: f32, dy: f32) ?Scroll.Region {
    const has_x = !std.math.isNan(dx) and dx != 0;
    const has_y = !std.math.isNan(dy) and dy != 0;
    if (!has_x and !has_y) return null;
    const top_hit = self.hitIndex(x, y, 0);
    var i: usize = self.scroll_len;
    while (i > 0) {
        i -= 1;
        const region = self.scrolls[i];
        if (region.id == .none) continue;
        const region_node = &self.nodes[region.node];
        if (!region_node.rect.contains(x, y)) continue;
        if (self.clippedAt(region.node, x, y)) continue;
        if (top_hit) |hit_index| {
            if (hit_index >= region_node.end) continue;
        }
        if ((has_x and region.max.x > 0) or (has_y and region.max.y > 0)) {
            return region;
        }
    }
    return null;
}

/// Topmost unoccluded visible overlay scrollbar whose edge grab strip contains `(x, y)`.
pub fn scrollbarAt(self: *const Tree, x: f32, y: f32) ?Scroll.ScrollbarHit {
    if (std.math.isNan(x) or std.math.isNan(y)) return null;
    const top_hit = self.hitIndex(x, y, 0);
    var i: usize = self.scroll_len;
    while (i > 0) {
        i -= 1;
        const region = self.scrolls[i];
        if (region.thumb == none) continue;
        const region_node = &self.nodes[region.node];
        const viewport = region_node.rect;
        if (!viewport.contains(x, y)) continue;
        if (self.clippedAt(region.node, x, y)) continue;
        if (top_hit) |hit_index| {
            if (hit_index >= region_node.end) continue;
        }
        const thumb_rect = self.nodes[region.thumb].rect;
        if (thumb_rect.w <= 0 or thumb_rect.h <= 0) continue;

        if (region.max.y > 0 and viewport.w > Scroll.thumb_thickness + Scroll.thumb_inset * 2 and viewport.h > Scroll.thumb_track_pad * 2) {
            const strip_w = @min(Scroll.hit_thickness, viewport.w);
            const track_start = viewport.y + Scroll.thumb_track_pad;
            const track_len = viewport.h - Scroll.thumb_track_pad * 2;
            const strip: Rect = .{
                .x = viewport.x + viewport.w - strip_w,
                .y = track_start,
                .w = strip_w,
                .h = track_len,
            };
            if (!strip.contains(x, y)) continue;
            const on_thumb = y >= thumb_rect.y and y < thumb_rect.y + thumb_rect.h;
            return .{
                .region = region,
                .axis = .column,
                .part = if (on_thumb) .thumb else .track,
                .track_start = track_start,
                .track_len = track_len,
                .thumb_start = thumb_rect.y,
                .thumb_len = thumb_rect.h,
            };
        }
        if (region.max.x > 0 and viewport.h > Scroll.thumb_thickness + Scroll.thumb_inset * 2 and viewport.w > Scroll.thumb_track_pad * 2) {
            const strip_h = @min(Scroll.hit_thickness, viewport.h);
            const track_start = viewport.x + Scroll.thumb_track_pad;
            const track_len = viewport.w - Scroll.thumb_track_pad * 2;
            const strip: Rect = .{
                .x = track_start,
                .y = viewport.y + viewport.h - strip_h,
                .w = track_len,
                .h = strip_h,
            };
            if (!strip.contains(x, y)) continue;
            const on_thumb = x >= thumb_rect.x and x < thumb_rect.x + thumb_rect.w;
            return .{
                .region = region,
                .axis = .row,
                .part = if (on_thumb) .thumb else .track,
                .track_start = track_start,
                .track_len = track_len,
                .thumb_start = thumb_rect.x,
                .thumb_len = thumb_rect.w,
            };
        }
    }
    return null;
}

/// Computes the clamped `Scroll.Offset` keeping `target_id` inside `region_id`
/// with `margin` clearance, or `null` if either node is absent in `self`.
pub fn ensureVisible(self: *const Tree, region_id: Id, target_id: Id, margin: f32) ?Scroll.Offset {
    const target = self.find(target_id) orelse return null;
    for (self.scrolls[0..self.scroll_len]) |region| {
        if (region.id != region_id) continue;
        return Scroll.ensureVisibleRect(self.nodes[region.node].rect, target.rect, margin, region.offset, region.max);
    }
    return null;
}

/// Places the root `index` against the node with id `target_id` using
/// default dropdown options (see `Anchor`).
pub fn anchorTo(self: *Tree, index: Index, target_id: Id) Error!void {
    return self.anchorToWith(index, target_id, .{});
}

/// Places the root `index` against the node with id `target_id` and custom
/// `options` (see `Anchor`).
pub fn anchorToWith(self: *Tree, index: Index, target_id: Id, options: Anchor.Options) Error!void {
    assert(index < self.len);
    assert(self.nodes[index].parent == none);
    assert(self.anchorOf(index) == null);
    if (self.anchor_len == anchor_max) return error.OutOfAnchors;
    self.anchors[self.anchor_len] = .{
        .payload = .{ .node = target_id },
        .node = index,
        .kind = .node,
        .side = options.side,
        .alignment = options.alignment,
        .match_anchor_width = options.match_anchor_width,
        .gap = options.gap,
        .margin = options.margin,
    };
    self.anchor_len += 1;
}

/// Places the root `index` near `(x, y)` in logical pixels.
pub fn anchorAt(self: *Tree, index: Index, x: f32, y: f32) Error!void {
    assert(index < self.len);
    assert(self.nodes[index].parent == none);
    assert(self.anchorOf(index) == null);
    if (self.anchor_len == anchor_max) return error.OutOfAnchors;
    self.anchors[self.anchor_len] = .{
        .payload = .{ .point = .{ .x = x, .y = y } },
        .node = index,
        .kind = .point,
    };
    self.anchor_len += 1;
}

/// The anchor of root `index`, if it has one.
pub fn anchorOf(self: *const Tree, index: Index) ?Anchor {
    for (self.anchors[0..self.anchor_len]) |anchor| {
        if (anchor.node == index) return anchor;
    }
    return null;
}

/// The first node with id `id`, or null (`Id.none` never matches).
pub fn find(self: *const Tree, id: Id) ?*const Node {
    if (id == .none) return null;
    for (self.items()) |*node| {
        if (node.box.id == id) return node;
    }
    return null;
}

pub fn items(self: *const Tree) []const Node {
    return self.nodes[0..self.len];
}

/// Starts a box; nodes added until the matching `close` are its
/// children.
pub fn open(self: *Tree, box: Box) Error!Index {
    const index = try self.push(.box, box);
    self.current = index;
    return index;
}

/// Ends the box `open` returned, which must be the innermost open one.
pub fn close(self: *Tree, index: Index) void {
    assert(index == self.current);
    self.nodes[index].end = self.len;
    self.current = self.nodes[index].parent;
}

/// A box without children.
pub fn leaf(self: *Tree, box: Box) Error!Index {
    return self.push(.box, box);
}

/// A text. `bytes` is borrowed until the view is rebuilt.
pub fn text(self: *Tree, bytes: []const u8, options: Text.Options) Error!Index {
    return self.push(
        .{ .text = .{
            .bytes = bytes,
            .color = options.color,
            .style = options.style,
            .figures = options.figures,
            .wrap = options.wrap,
            .alignment = options.alignment,
        } },
        .{ .width = options.width, .id = options.id, .shrink = options.shrink },
    );
}

pub fn icon(self: *Tree, value: Icon) Error!Index {
    return self.push(.{ .icon = value }, .{ .shrink = false });
}

/// A horizontal dashed rule. `box` sets its extent and placement (typically `.width = .fill, .height = .{ .fixed = 1 }`).
pub fn dash(self: *Tree, value: Dash, box: Box) Error!Index {
    return self.push(.{ .dash = value }, box);
}

/// A box whose border is stroked clockwise from top-center by `fraction` (`1..65535` mapped to `0..1`, `0` draws full border).
pub fn borderSweep(self: *Tree, fraction: u16, box: Box) Error!Index {
    return self.push(.{ .border_sweep = fraction }, box);
}

/// An arc. `box.overlay` lays it over its parent instead of in the flow.
pub fn arc(self: *Tree, value: Arc, box: Box) Error!Index {
    return self.push(.{ .arc = value }, box);
}

/// A serpentine progress ribbon filling its `box` bounds.
pub fn coil(self: *Tree, value: Coil, box: Box) Error!Index {
    return self.push(.{ .coil = value }, box);
}

fn push(self: *Tree, content: Node.Content, box: Box) Error!Index {
    assert(!(box.wrap and box.axis == .column));
    if (self.len == self.nodes.len) return error.OutOfNodes;
    const index = self.len;
    self.nodes[index] = .{ .content = content, .box = box, .parent = self.current, .end = index + 1 };
    self.len += 1;
    return index;
}

/// Lays out every root and anchored overlay in the tree against `(viewport_width, viewport_height)`.
///
/// Roots are placed in drawing order so anchored roots (`anchorTo`) find their target already placed.
pub fn layout(self: *Tree, measurer: Measurer, viewport_width: f32, viewport_height: f32) @import("layout.zig").Error!void {
    return @import("layout.zig").run(self, measurer, viewport_width, viewport_height);
}

/// Moves the laid-out node `index` and its descendants by `dx`, `dy`
/// logical pixels, for motion that layout knows nothing about.
pub fn translate(self: *Tree, index: Index, dx: f32, dy: f32) void {
    for (self.nodes[index..self.nodes[index].end]) |*node| {
        node.rect.x += dx;
        node.rect.y += dy;
    }
}

/// The topmost node with an id under the point, or `none`. Later nodes
/// are drawn over earlier ones. A node a clipping ancestor cuts away
/// at the point is not hit there.
pub fn hitTest(self: *const Tree, x: f32, y: f32) Id {
    return if (self.hit(x, y)) |node| node.box.id else .none;
}

/// The node `hitTest` finds, or null.
pub fn hit(self: *const Tree, x: f32, y: f32) ?*const Node {
    return if (self.hitIndex(x, y, 0)) |index| &self.nodes[index] else null;
}

fn hitIndex(self: *const Tree, x: f32, y: f32, stop: Index) ?Index {
    var i = self.len;
    while (i > stop) {
        i -= 1;
        const node = &self.nodes[i];
        if (node.box.id == .none or !node.rect.contains(x, y)) continue;
        if (node.content == .arc and !arcContains(node.content.arc, node.rect, x, y)) continue;
        if (!self.clippedAt(i, x, y)) return i;
    }
    return null;
}

fn arcContains(arc_val: Arc, rect: Rect, x: f32, y: f32) bool {
    if (!(arc_val.radius > 0 and arc_val.thickness > 0 and arc_val.sweep > 0)) return false;
    const center_x = rect.x + rect.w / 2;
    const center_y = rect.y + rect.h / 2;
    const dx = x - center_x;
    const dy = y - center_y;
    const dist2 = dx * dx + dy * dy;
    const outer = arc_val.radius;
    const inner = outer - @min(outer, arc_val.thickness);
    if (dist2 < inner * inner or dist2 > outer * outer) return false;
    if (arc_val.sweep >= std.math.tau) return true;
    var angle = std.math.atan2(dx, -dy);
    if (angle < 0) angle += std.math.tau;
    return @mod(angle - arc_val.start, std.math.tau) <= arc_val.sweep;
}

/// Whether an ancestor of node `index` clips the point away.
fn clippedAt(self: *const Tree, index: Index, x: f32, y: f32) bool {
    var parent = self.nodes[index].parent;
    while (parent != none) : (parent = self.nodes[parent].parent) {
        const ancestor = &self.nodes[parent];
        if (ancestor.box.overflow == .clip and !ancestor.rect.contains(x, y)) return true;
    }
    return false;
}
