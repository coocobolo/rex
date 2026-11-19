//! Helpers for emitting Zig source from generator input data.

const std = @import("std");

/// Writes `text` as the contents of a Zig string literal. Generator inputs
/// come from vendored data files, so quotes, backslashes and control bytes
/// must not be interpolated raw into emitted source.
pub fn writeStringLiteral(w: *std.Io.Writer, text: []const u8) !void {
    for (text) |ch| switch (ch) {
        '\\' => try w.writeAll("\\\\"),
        '"' => try w.writeAll("\\\""),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        else => if (ch < 0x20 or ch == 0x7f) {
            try w.print("\\x{x:0>2}", .{ch});
        } else {
            try w.writeByte(ch);
        },
    };
}
