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
    /// Whether linked text is underlined even without SGR 4.
    underline: bool = true,
    /// Underline color for links; null uses the configured underline or text color.
    link_color: ?Rgb = null,
    /// Command that opens a URI. Empty uses the platform default
    /// (`xdg-open`, `gio open` or `open`). It receives the URI as one argv element.
    open_command: [:0]const u8 = "",
    /// URI schemes allowed to be opened.
    schemes: SchemeSet = default_schemes,
};
