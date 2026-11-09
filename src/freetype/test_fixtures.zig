//! Shared fixtures for the freetype/ and renderer/ tests.

const Config = @import("Config.zig");
const font_paths = @import("font_paths");

/// Noto faces, 16 device pixels tall: static regular and bold from
/// `testdata/font`, italic and bold italic from the `noto_sans` package,
/// plus a color emoji face.
pub const test_font: Config = .{
    .faces = .{
        .regular = "testdata/font/NotoSansMono-Regular.ttf",
        .bold = "testdata/font/NotoSansMono-Bold.ttf",
        .italic = facePath(font_paths.noto_sans_italic),
        .bold_italic = facePath(font_paths.noto_sans_bold_italic),
        .emoji = .static("testdata/font/NotoColorEmoji.ttf"),
    },
    .height = 16,
};

/// Face paths are sentinel-terminated. The fetched paths arrive as slices.
fn facePath(comptime path: []const u8) [*:0]const u8 {
    return (path ++ "\x00").ptr;
}
