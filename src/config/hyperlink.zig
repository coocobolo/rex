//! The `[hyperlink]` section: OSC 8 activation, visuals and URI policy (ADR 0012).

const std = @import("std");
const Rgb = @import("../color/Rgb.zig");

/// URI schemes a link may open. `file` is off by default; enable it in config.
pub const Scheme = enum {
    http,
    https,
    mailto,
    file,
};

pub const SchemeSet = std.EnumSet(Scheme);

/// When the underline Rex adds to linked text is visible (ADR 0013).
pub const UnderlineVisibility = enum {
    never,
    always,
    hover,
};

/// How a long target URI is shown in the hover tooltip (ADR 0013).
pub const TargetStyle = enum {
    /// Wrap into short lines, keeping the card narrow.
    multiline,
    /// One line: first 40 and last 24 UTF-8 bytes with an ellipsis between.
    head_tail,
    /// One wider line, truncated with an ellipsis at the edge.
    wide,
};

/// Underline style used for linked text with no explicit SGR underline.
/// Values match `term.cell.UnderlineStyle` so the renderer can convert
/// without a translation switch; `none` is expressed by `underline = never`.
pub const UnderlineStyle = enum(u3) {
    single = 1,
    double = 2,
    curly = 3,
    dotted = 4,
    dashed = 5,
};

/// When to show the target URI under the pointer (ADR 0013).
pub const ShowTarget = enum {
    never,
    ctrl,
    cmd,
    alt,
    shift,
    always,
};

/// The schemes allowed by default, built without a heap allocation.
pub const default_schemes: SchemeSet = blk: {
    var set: SchemeSet = .empty;
    set.insert(.http);
    set.insert(.https);
    set.insert(.mailto);
    break :blk set;
};

pub const Hyperlink = struct {
    /// Whether Ctrl+click opens OSC 8 links.
    enabled: bool = true,
    /// Underline Rex adds to linked text without SGR 4: never, always, or
    /// only on hover. An explicit SGR underline is always drawn.
    underline: UnderlineVisibility = .always,
    /// Style of the underline Rex adds to linked text. An explicit SGR
    /// underline keeps its own style.
    underline_style: UnderlineStyle = .single,
    /// When to show the target URI in a tooltip while hovering a link.
    show_targets: ShowTarget = .ctrl,
    /// How a long target URI is laid out in that tooltip.
    target_style: TargetStyle = .multiline,
    /// Underline color for OSC 8 links; null uses the decoration or text color.
    underline_color: ?Rgb = null,
    /// Command that opens a URI. Empty uses the platform default
    /// (`xdg-open`, `gio open` or `open`). It receives the URI as one argv element.
    open_command: [:0]const u8 = "",
    /// URI schemes allowed to be opened.
    schemes: SchemeSet = default_schemes,
};
