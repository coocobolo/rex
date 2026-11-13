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
const text_zig = @import("text.zig");

pub const Index = u16;
/// No node: the parent of a root.
pub const none: Index = std.math.maxInt(Index);

/// A rectangle in logical pixels, origin at the window's top left.
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

/// How a node's width or height is decided.
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
    /// As large as its content, but not smaller than this many logical
    /// pixels.
    at_least: f32,
};

/// The direction a box lays its children out in.
pub const Axis = enum(u1) { row, column };

/// Where children sit along an axis when there is room to spare.
pub const Align = enum(u2) { start, center, end };

/// What a box does with descendants that reach outside its rectangle.
pub const Overflow = enum(u1) {
    /// Draws them and lets them be hit anywhere.
    visible,
    /// Cuts them at its rectangle, for painting and for hit-testing. The
    /// cut is square: rounded corners do not round it.
    clip,
};

/// The pointer's shape over a node that hit-testing finds.
pub const PointerShape = enum(u2) {
    arrow,
    /// Something that acts when clicked: a button, an item.
    hand,
    /// Text that can be typed into or selected.
    text,
};

/// Padding in logical pixels.
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

/// What a box looks like and how it arranges its children.
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
};

pub const Text = struct {
    /// Borrowed: must stay valid until the view is rebuilt.
    bytes: []const u8,
    color: Color,
    style: text_zig.Style = .sm,
    /// Its lines in the tree's `Lines`, set by layout.
    first_line: u32 = 0,
    line_count: u32 = 0,
};

pub const Icon = struct {
    /// The glyph in the icon font: one of `icons.zig`.
    codepoint: u21,
    color: Color,
    /// Edge length in logical pixels.
    size: u8,
};

pub const Content = union(enum) {
    box,
    text: Text,
    icon: Icon,
};

pub const Node = struct {
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

/// A root placed against a node of an earlier root rather than the
/// window: a popup against the control that opened it. Layout puts it
/// below the node, or above when there is no room below, inside the
/// window, and at least as wide as the node.
pub const Anchor = struct {
    /// The anchored root.
    node: Index,
    /// The node it is placed against. When no earlier node has this id,
    /// the root stays at the window's top left.
    target: Id,
};

/// Popups one view can hold.
pub const anchor_max = 4;

pub const Tree = struct {
    nodes: []Node,
    len: Index = 0,
    /// The innermost open box; new nodes become its children.
    current: Index = none,
    anchor_len: u8 = 0,
    lines: text_zig.Lines,
    anchors: [anchor_max]Anchor = undefined,

    /// `nodes` and `lines` are the caller's and bound how much one view
    /// can hold.
    pub fn init(nodes: []Node, lines: []text_zig.Line) Tree {
        assert(nodes.len < none);
        return .{ .nodes = nodes, .lines = .init(lines) };
    }

    /// Empties the tree for the next view.
    pub fn reset(self: *Tree) void {
        self.len = 0;
        self.current = none;
        self.anchor_len = 0;
        self.lines.len = 0;
    }

    /// Places the root `index` against the node with id `target` (see
    /// `Anchor`). Call it right after opening the root.
    pub fn anchorTo(self: *Tree, index: Index, target: Id) Error!void {
        assert(self.nodes[index].parent == none);
        if (self.anchor_len == anchor_max) return error.OutOfAnchors;
        self.anchors[self.anchor_len] = .{ .node = index, .target = target };
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

    pub const TextOptions = struct {
        color: Color,
        style: text_zig.Style = .sm,
        /// `fit` keeps the text on one line where there is room; `fill`
        /// takes the width the parent has left and wraps to it.
        width: Size = .fit,
        id: Id = .none,
    };

    /// A text. `bytes` is borrowed until the view is rebuilt.
    pub fn text(self: *Tree, bytes: []const u8, options: TextOptions) Error!Index {
        return self.push(
            .{ .text = .{ .bytes = bytes, .color = options.color, .style = options.style } },
            .{ .width = options.width, .id = options.id },
        );
    }

    pub fn icon(self: *Tree, value: Icon) Error!Index {
        return self.push(.{ .icon = value }, .{});
    }

    fn push(self: *Tree, content: Content, box: Box) Error!Index {
        if (self.len == self.nodes.len) return error.OutOfNodes;
        const index = self.len;
        self.nodes[index] = .{ .content = content, .box = box, .parent = self.current, .end = index + 1 };
        self.len += 1;
        return index;
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
            if (node.box.id != .none and node.rect.contains(x, y) and !self.clippedAt(i, x, y)) return node;
        }
        return null;
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
};
