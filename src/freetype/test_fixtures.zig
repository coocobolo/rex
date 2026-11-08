//! Shared fixtures for the freetype/ and renderer/ tests.

const Config = @import("Config.zig");

/// Noto faces from `testdata/font`, 16 device pixels tall: static regular,
/// bold, italic and bold italic, plus a color emoji face.
pub const test_font: Config = .{
    .faces = .{
        .regular = "testdata/font/NotoSansMono-Regular.ttf",
        .bold = "testdata/font/NotoSansMono-Bold.ttf",
        .italic = "testdata/font/NotoSans-Italic.ttf",
        .bold_italic = "testdata/font/NotoSans-BoldItalic.ttf",
        .emoji = .static("testdata/font/NotoColorEmoji.ttf"),
    },
    .height = 16,
};
