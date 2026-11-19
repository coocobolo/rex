//! Shared textual `@import` scanner for the import-boundary checkers.
//!
//! Module imports are matched by their literal path; `.zig` paths are followed
//! by the caller. Line comments are ignored so commented-out imports do not
//! trigger a boundary failure.

const std = @import("std");

/// The string literals of the `@import`s in `source` that are not in a line
/// comment.
pub const Imports = struct {
    source: []const u8,
    index: usize = 0,

    const needle = "@import(\"";

    pub fn next(self: *Imports) ?[]const u8 {
        while (std.mem.indexOfPos(u8, self.source, self.index, needle)) |at| {
            const start = at + needle.len;
            const end = std.mem.indexOfScalarPos(u8, self.source, start, '"') orelse return null;
            self.index = end + 1;
            const line_start = if (std.mem.lastIndexOfScalar(u8, self.source[0..at], '\n')) |nl| nl + 1 else 0;
            if (std.mem.indexOf(u8, self.source[line_start..at], "//") != null) continue;
            return self.source[start..end];
        }
        return null;
    }
};

test Imports {
    var it: Imports = .{ .source =
        \\const a = @import("a.zig");
        \\// const b = @import("b.zig");
        \\const std = @import("std");
        \\    _ = @import("c.zig"); // @import("d.zig")
    };
    try std.testing.expectEqualStrings("a.zig", it.next().?);
    try std.testing.expectEqualStrings("std", it.next().?);
    try std.testing.expectEqualStrings("c.zig", it.next().?);
    try std.testing.expectEqual(null, it.next());
}
