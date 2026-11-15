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
    /// Cuts them at its rectangle, for painting and for hit-testing. The
    /// cut is square: rounded corners do not round it.
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

/// One flat entry in `Tree.nodes`: pairs input rules (`box`, `content`), computed `layout`
/// geometry (`rect`), and array slice bounds (`parent`, `end`).
pub const Node = struct {
    /// Payload variant of a `Node` (`box` container/leaf vs `text`, `icon`, `dash`, `border_sweep`, or `arc` primitive).
    pub const Content = union(enum) {
        box,
        text: Text,
        icon: Icon,
        dash: Dash,
        border_sweep: u16,
        arc: Arc,
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

pub const Error = error{ OutOfNodes, OutOfAnchors };

/// Attachment record binding a top-level root to an earlier node or point (`popup`, `tooltip`).
///
/// Use for popups/tooltips positioned against a trigger or cursor; use `ScreenAnchor` for screen corners.
pub const Anchor = struct {
    /// What a floating root anchors against: an earlier node's `Id` (`anchorTo`) or screen point (`anchorAt`).
    pub const Target = union(enum) {
        node: Id,
        point: struct { x: f32, y: f32 },
    };

    /// Root node index being positioned.
    node: Index,
    target: Target,
};

/// Maximum anchored roots (popups/tooltips) per frame.
pub const anchor_max = 4;

nodes: []Node,
len: Index = 0,
/// The innermost open box; new nodes become its children.
current: Index = none,
anchor_len: u8 = 0,
/// The one box whose content scrolls (`scrollRegion`), or `none`.
scroll_index: Index = none,
lines: Lines,
anchors: [anchor_max]Anchor = undefined,
/// How far the region's content moves up, as the surface asks; layout
/// caps it at `scroll_max`.
scroll_offset: f32 = 0,
/// Set by layout: how much taller the region's content is than the
/// region, so how far it can move up. 0 without a region.
scroll_max: f32 = 0,

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
    self.lines.len = 0;
    self.scroll_index = none;
    self.scroll_offset = 0;
    self.scroll_max = 0;
}

/// Makes the clipping box `index` scroll: its content keeps its own
/// height and moves up by `offset` logical pixels, which layout caps
/// at what the content has beyond the box (`scroll_max`). One region
/// per tree.
pub fn scrollRegion(self: *Tree, index: Index, offset: f32) void {
    assert(self.nodes[index].content == .box and self.nodes[index].box.overflow == .clip);
    assert(self.scroll_index == none);
    self.scroll_index = index;
    self.scroll_offset = offset;
}

/// Places the root `index` against the node with id `target` (see
/// `Anchor`). Call it right after opening the root.
pub fn anchorTo(self: *Tree, index: Index, target: Id) Error!void {
    assert(self.nodes[index].parent == none);
    if (self.anchor_len == anchor_max) return error.OutOfAnchors;
    self.anchors[self.anchor_len] = .{ .node = index, .target = .{ .node = target } };
    self.anchor_len += 1;
}

/// Places the root `index` near `(x, y)` in logical pixels. Call it
/// right after opening the root.
pub fn anchorAt(self: *Tree, index: Index, x: f32, y: f32) Error!void {
    assert(self.nodes[index].parent == none);
    if (self.anchor_len == anchor_max) return error.OutOfAnchors;
    self.anchors[self.anchor_len] = .{ .node = index, .target = .{ .point = .{ .x = x, .y = y } } };
    self.anchor_len += 1;
}

/// The anchor of root `index`, if it has one.
pub fn anchorOf(self: *const Tree, index: Index) ?Anchor {
    for (self.anchors[0..self.anchor_len]) |anchor| {
        if (anchor.node == index) return anchor;
    }
    return null;
}

/// The first node with id `id`, or null.
pub fn find(self: *const Tree, id: Id) ?*const Node {
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
        .{ .width = options.width, .id = options.id },
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
    var i = self.len;
    while (i > 0) {
        i -= 1;
        const node = &self.nodes[i];
        if (node.box.id == .none or !node.rect.contains(x, y)) continue;
        if (node.content == .arc and !arcContains(node.content.arc, node.rect, x, y)) continue;
        if (!self.clippedAt(i, x, y)) return node;
    }
    return null;
}

fn arcContains(arc_val: Arc, rect: Rect, x: f32, y: f32) bool {
    if (!(arc_val.radius > 0 and arc_val.thickness > 0 and arc_val.sweep > 0)) return false;
    const center_x = rect.x + rect.w / 2;
    const center_y = rect.y + rect.w / 2;
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
