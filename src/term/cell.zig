//! Cell-level terminal types: attributes, underline styles, the packed
//! `Cell` stored in every screen row, and re-exports of decomposed modules
//! (Color, Charset, Cursor, Style).

const std = @import("std");

// Re-exports from decomposed pure modules
pub const Color = @import("../color/color.zig").Color;
pub const Rgb = @import("../color/Rgb.zig");

pub const charset = @import("charset.zig");
pub const Charset = charset.Charset;
pub const CharsetState = charset.CharsetState;

pub const Cursor = @import("Cursor.zig").Cursor;
pub const SavedCursor = Cursor.Saved;

pub const Style = @import("Style.zig");

/// Underline style, 3 bits of AttrFlags.
///
/// Matches the SGR 4 sub-parameter space:
///   SGR 4 or 4:1: single
///   SGR 4:2 or 21: double
///   SGR 4:3: curly (kitty and VTE extension)
///   SGR 4:4: dotted (kitty and VTE extension)
///   SGR 4:5: dashed (kitty and VTE extension)
///   SGR 4:0 or 24: none
pub const UnderlineStyle = enum(u3) {
    none = 0,
    single = 1,
    double = 2,
    curly = 3,
    // underline extension (widely adopted by VTE, WezTerm, foot, etc.)
    dotted = 4,
    dashed = 5,
    // 6, 7 reserved
};

comptime {
    std.debug.assert(1 == @sizeOf(UnderlineStyle));
    std.debug.assert(3 == @bitSizeOf(UnderlineStyle));
}

/// SGR text attribute flags, packed into 12 bits of the Cell.
pub const AttrFlags = packed struct(u12) {
    bold: bool = false, // SGR 1
    dim: bool = false, // SGR 2
    italic: bool = false, // SGR 3
    blink: bool = false, // SGR 5
    blink_rapid: bool = false, // SGR 6
    reverse: bool = false, // SGR 7
    invisible: bool = false, // SGR 8
    strikethrough: bool = false, // SGR 9
    overline: bool = false, // SGR 53
    underline: UnderlineStyle = .none, // SGR 4 / 4:[0-5] (3 bits)

    pub const default: AttrFlags = .{
        .bold = false,
        .dim = false,
        .italic = false,
        .blink = false,
        .blink_rapid = false,
        .reverse = false,
        .invisible = false,
        .strikethrough = false,
        .overline = false,
        .underline = .none,
    };
};

comptime {
    std.debug.assert(12 == @bitSizeOf(AttrFlags));
}

/// SGR (Select Graphic Rendition) attributes of the cursor pen.
///
/// `colors` is the source of truth (SGR, DECSC/DECRC). `id` and
/// `blank_id` cache it interned in the screen's `Style.Table`; the screen
/// refreshes them (`Screen.internPen`) whenever `colors` changes, and
/// nothing else may set them. A saved copy's IDs are stale: DECRC
/// re-interns.
pub const Attr = struct {
    flags: AttrFlags = .{},
    /// Foreground, background and underline color (SGR 58; `.default`
    /// draws the underline in the foreground color).
    colors: Style = .default,
    /// `colors` interned; written to printed cells.
    id: Style.Id = Style.Table.default_id,
    /// The background of `colors` alone, interned; written to blank cells
    /// (erase, background color erase), which keep the default foreground.
    blank_id: Style.Id = Style.Table.default_id,
};

comptime {
    std.debug.assert(20 == @sizeOf(Attr));
}

pub const Kind = enum(u3) {
    /// blank cell (codepoint == 0)
    empty = 0,
    /// 1-col codepoint
    narrow = 1,
    /// 1-col wide character left-half
    wide_left = 2,
    /// 2-col wide character right-half placeholder
    wide_right = 3,
    /// 1-col ZWJ/grapheme sequence ID, narrow
    grapheme = 4,
    /// 2-col ZWJ/grapheme sequence ID, wide
    grapheme_wide = 5,
    /// TODO reserved future HarfBuzz shaped run
    shaped = 6,

    // 7 = reserved

    pub fn columnSpan(self: Kind) u2 {
        return switch (self) {
            .empty => 1, // occupies 1 column (blank)
            .narrow => 1,
            .grapheme => 1,
            .wide_left, .grapheme_wide => 2,
            .wide_right => 0, // placeholder, caller must guard against infinite loop
            .shaped => unreachable, // shaped cells carry their own span
        };
    }

    /// Returns the kind is ZWJ/grapheme sequence ID (narrow/wide).
    pub inline fn isGrapheme(self: Kind) bool {
        return self == .grapheme or self == .grapheme_wide;
    }

    pub inline fn isWideLeft(self: Kind) bool {
        return self == .wide_left or self == .grapheme_wide;
    }
};

/// A single terminal grid cell.
pub const Cell = packed struct(u64) {
    /// Unicode scalar value (U+0000...U+10FFFF) or grapheme sequence ID.
    /// default: 0 (NUL) means the cell is empty.
    codepoint: u32 = 0,

    /// What the current cell kind codepoint
    kind: Kind = .empty,
    flags: AttrFlags = .default,

    /// Colors, as an ID into the screen's `Style.Table` (0 = default).
    /// The ID keeps its colors while any cell holds it (ADR 0005).
    style: Style.Id = Style.Table.default_id,

    /// Set on the last column of a row when printing continued onto the
    /// next row (a soft wrap, as xterm's LINEWRAPPED line flag). Reverse
    /// wraparound (DEC private mode 45) only crosses such rows. Erasing
    /// or overwriting the cell clears it, as any blank or new cell has it
    /// false.
    wrapped: bool = false,

    pub const empty: Cell = .{};
};

comptime {
    std.debug.assert(8 == @sizeOf(Cell));
    std.debug.assert(8 == @alignOf(Cell));
}

test "Cell: empty defaults and sizeOf/alignOf" {
    const c = Cell.empty;
    try std.testing.expectEqual(0, c.codepoint);
    try std.testing.expectEqual(Kind.empty, c.kind);
    try std.testing.expectEqual(false, c.wrapped);
    try std.testing.expectEqual(Style.Table.default_id, c.style);
    try std.testing.expectEqual(8, @sizeOf(Cell));
    try std.testing.expectEqual(8, @alignOf(Cell));
}

test "UnderlineStyle: variants and bit sizes" {
    try std.testing.expectEqual(0, @intFromEnum(UnderlineStyle.none));
    try std.testing.expectEqual(1, @intFromEnum(UnderlineStyle.single));
    try std.testing.expectEqual(2, @intFromEnum(UnderlineStyle.double));
    try std.testing.expectEqual(3, @intFromEnum(UnderlineStyle.curly));
    try std.testing.expectEqual(4, @intFromEnum(UnderlineStyle.dotted));
    try std.testing.expectEqual(5, @intFromEnum(UnderlineStyle.dashed));
    try std.testing.expectEqual(3, @bitSizeOf(UnderlineStyle));
    try std.testing.expectEqual(1, @sizeOf(UnderlineStyle));
}

test "AttrFlags: default values and bit size" {
    const f = AttrFlags.default;
    try std.testing.expect(!f.bold);
    try std.testing.expect(!f.dim);
    try std.testing.expect(!f.italic);
    try std.testing.expect(!f.blink);
    try std.testing.expect(!f.blink_rapid);
    try std.testing.expect(!f.reverse);
    try std.testing.expect(!f.invisible);
    try std.testing.expect(!f.strikethrough);
    try std.testing.expect(!f.overline);
    try std.testing.expectEqual(UnderlineStyle.none, f.underline);
    try std.testing.expectEqual(12, @bitSizeOf(AttrFlags));
}

test "Attr: defaults and size" {
    const a = Attr{};
    try std.testing.expect(a.colors.isDefault());
    try std.testing.expectEqual(Style.Table.default_id, a.id);
    try std.testing.expectEqual(Style.Table.default_id, a.blank_id);
    try std.testing.expectEqual(20, @sizeOf(Attr));
}

test "Kind: column spans and predicates" {
    try std.testing.expectEqual(1, Kind.empty.columnSpan());
    try std.testing.expectEqual(1, Kind.narrow.columnSpan());
    try std.testing.expectEqual(2, Kind.wide_left.columnSpan());
    try std.testing.expectEqual(0, Kind.wide_right.columnSpan());
    try std.testing.expectEqual(1, Kind.grapheme.columnSpan());
    try std.testing.expectEqual(2, Kind.grapheme_wide.columnSpan());

    try std.testing.expect(!Kind.empty.isGrapheme());
    try std.testing.expect(Kind.grapheme.isGrapheme());
    try std.testing.expect(Kind.grapheme_wide.isGrapheme());

    try std.testing.expect(Kind.wide_left.isWideLeft());
    try std.testing.expect(Kind.grapheme_wide.isWideLeft());
    try std.testing.expect(!Kind.narrow.isWideLeft());
}
