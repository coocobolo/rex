//! The font files Rex ships and the folder they are installed to.
//!
//! `zig build` installs `share/rex/fonts` to `<prefix>/share/rex/fonts`,
//! and the executable is `<prefix>/bin/rex`. This file imports only `std`,
//! so the tool windows can find their fonts without the config.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const regular_name = "GoogleSansCode[wght].ttf";
pub const italic_name = "GoogleSansCode-Italic[wght].ttf";
pub const emoji_name = "NotoColorEmoji.ttf";
/// The UI font's static faces, by weight (400, 500, 600).
pub const ui_regular_name = "Inter-Regular.ttf";
pub const ui_medium_name = "Inter-Medium.ttf";
pub const ui_semibold_name = "Inter-SemiBold.ttf";
/// The UI kit's icon font.
pub const ui_icons_name = "lucide.ttf";

/// Directory of the installed faces for an executable at `exe_path`.
/// `<prefix>/bin/rex` → `<prefix>/share/rex/fonts`.
pub fn fontDir(allocator: Allocator, exe_path: []const u8) error{ OutOfMemory, BadExePath }![]u8 {
    const bin = std.fs.path.dirname(exe_path) orelse return error.BadExePath;
    return std.fs.path.resolve(allocator, &.{ bin, "..", "share", "rex", "fonts" });
}

test "fontDir: installed faces sit beside the executable" {
    const dir = try fontDir(std.testing.allocator, "/opt/rex/bin/rex");
    defer std.testing.allocator.free(dir);
    try std.testing.expectEqualStrings("/opt/rex/share/rex/fonts", dir);
}
