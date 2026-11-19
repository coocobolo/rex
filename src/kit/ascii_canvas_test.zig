const std = @import("std");
const testing = std.testing;

const AsciiCanvas = @import("AsciiCanvas.zig");
const Theme = @import("Theme.zig");

const test_palette = AsciiCanvas.Palette.fromTheme(&Theme.dark, Theme.dark.success);

test "AsciiCanvas: Cell and buffer layout invariants" {
    try testing.expectEqual(@as(usize, 8), @sizeOf(AsciiCanvas.Cell));
    try testing.expectEqual(@as(usize, 4), @alignOf(AsciiCanvas.Cell));
    try testing.expectEqual(@as(usize, 64), @alignOf(AsciiCanvas));
    try testing.expectEqual(@as(usize, 64), std.meta.fieldInfo(AsciiCanvas, .cells).alignment);
    try testing.expectEqual(@as(usize, 0), @offsetOf(AsciiCanvas, "cells") % 64);
    try testing.expectEqual(@as(?AsciiCanvas.Procedural, .spin_3d), AsciiCanvas.Scene.spin_3d.toProcedural());
    try testing.expectEqual(@as(?AsciiCanvas.Procedural, null), AsciiCanvas.Scene.file.toProcedural());
}

test "AsciiCanvas: every built-in procedural scene renders visible cells and animates" {
    const canvas = try testing.allocator.create(AsciiCanvas);
    defer testing.allocator.destroy(canvas);
    canvas.* = .empty;

    inline for (std.meta.fields(AsciiCanvas.Procedural)) |field| {
        const scene: AsciiCanvas.Procedural = @enumFromInt(field.value);
        canvas.render(.{ .procedural = scene }, .{
            .cols = 60,
            .rows = 30,
            .time_s = 0.0,
            .progress = 0.25,
            .aspect = .square,
            .palette = test_palette,
        });
        try testing.expectEqual(@as(u16, 60), canvas.cols);
        try testing.expectEqual(@as(u16, 30), canvas.rows);
        try testing.expect(canvas.non_empty > 0);
        try testing.expect(canvas.non_empty <= 60 * 30);

        // Snapshot t=0 codepoints, then advance time and confirm animation changes output.
        var snap: [60 * 30]u21 = undefined;
        for (0..60 * 30) |i| snap[i] = canvas.cells[i].codepoint;

        canvas.render(.{ .procedural = scene }, .{
            .cols = 60,
            .rows = 30,
            .time_s = 1.7,
            .progress = 0.5,
            .aspect = .square,
            .palette = test_palette,
        });
        var changed: usize = 0;
        for (0..60 * 30) |i| {
            if (snap[i] != canvas.cells[i].codepoint) changed += 1;
        }
        try testing.expect(changed > 0);
    }
}

test "AsciiCanvas: spin_3d uses monochrome ramp glyphs and honors cell aspect" {
    const canvas = try testing.allocator.create(AsciiCanvas);
    defer testing.allocator.destroy(canvas);
    canvas.* = .empty;

    canvas.render(.{ .procedural = .spin_3d }, .{
        .cols = 64,
        .rows = 32,
        .time_s = 0.8,
        .aspect = .square,
        .palette = test_palette,
    });
    var saw_block = false;
    var saw_binary_or_star = false;
    for (0..@as(usize, canvas.cols) * @as(usize, canvas.rows)) |i| {
        const cp = canvas.cells[i].codepoint;
        switch (cp) {
            0 => {},
            '*', '0', '1' => saw_binary_or_star = true,
            0x25A0, 0x2588 => saw_block = true,
            else => return error.UnexpectedRampGlyph,
        }
    }
    try testing.expect(saw_block);
    try testing.expect(saw_binary_or_star);

    // Terminal aspect (0.5) should keep the shape centered without overflowing bounds.
    canvas.render(.{ .procedural = .spin_3d }, .{
        .cols = 80,
        .rows = 24,
        .time_s = 0.8,
        .aspect = .terminal,
        .palette = test_palette,
    });
    try testing.expect(canvas.non_empty > 0);
}

test "AsciiCanvas: clamps oversized viewports and handles zero/non-finite inputs" {
    const canvas = try testing.allocator.create(AsciiCanvas);
    defer testing.allocator.destroy(canvas);
    canvas.* = .empty;

    canvas.render(.{ .procedural = .wave }, .{
        .cols = AsciiCanvas.max_cols + 50,
        .rows = AsciiCanvas.max_rows + 20,
        .time_s = std.math.nan(f32),
        .progress = std.math.inf(f32),
        .palette = test_palette,
    });
    try testing.expectEqual(AsciiCanvas.max_cols, canvas.cols);
    try testing.expectEqual(AsciiCanvas.max_rows, canvas.rows);
    try testing.expect(canvas.non_empty > 0);

    canvas.render(.{ .procedural = .wave }, .{
        .cols = 0,
        .rows = 20,
        .time_s = 1.0,
        .palette = test_palette,
    });
    try testing.expectEqual(@as(u16, 0), canvas.cols);
    try testing.expectEqual(@as(u32, 0), canvas.non_empty);
}

test "AsciiCanvas.Frames: parses header fps, multi-frame separators, and renders centered" {
    const src =
        "# fps: 15\n" ++
        "  *  \n" ++
        " *** \n" ++
        "---\n" ++
        " █■█ \n" ++
        "  0  \n" ++
        "\x0c\n" ++
        "#art#\n";

    var frames = try AsciiCanvas.Frames.parse(testing.allocator, src);
    defer frames.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 15), frames.fps);
    try testing.expectEqual(@as(usize, 3), frames.frameCount());
    try testing.expectEqual(@as(usize, 0), frames.frameIndex(0.0));
    try testing.expectEqual(@as(usize, 1), frames.frameIndex(1.0 / 15.0));
    try testing.expectEqual(@as(usize, 2), frames.frameIndex(2.0 / 15.0));
    try testing.expectEqual(@as(usize, 0), frames.frameIndex(3.0 / 15.0));

    const canvas = try testing.allocator.create(AsciiCanvas);
    defer testing.allocator.destroy(canvas);
    canvas.* = .empty;

    // Render frame 1 (" █■█ \n  0  ") centered into a 9x6 viewport.
    canvas.render(.{ .frames = &frames }, .{
        .cols = 9,
        .rows = 6,
        .time_s = 1.0 / 15.0,
        .palette = test_palette,
    });
    try testing.expectEqual(@as(u32, 4), canvas.non_empty);
    // dst_x0 = (9 - 5) / 2 = 2, dst_y0 = (6 - 2) / 2 = 2
    try testing.expectEqual(@as(u21, 0), canvas.cellAt(2, 2).codepoint);
    try testing.expectEqual(@as(u21, 0x2588), canvas.cellAt(3, 2).codepoint);
    try testing.expectEqual(@as(u21, 0x25A0), canvas.cellAt(4, 2).codepoint);
    try testing.expectEqual(@as(u21, 0x2588), canvas.cellAt(5, 2).codepoint);
    try testing.expectEqual(@as(u21, '0'), canvas.cellAt(4, 3).codepoint);

    // Frame 2 starts with `#` art — verify `#` without `fps:` is preserved as art.
    canvas.render(.{ .frames = &frames }, .{
        .cols = 5,
        .rows = 1,
        .time_s = 2.0 / 15.0,
        .palette = test_palette,
    });
    try testing.expectEqual(@as(u21, '#'), canvas.cellAt(0, 0).codepoint);
    try testing.expectEqual(@as(u21, '#'), canvas.cellAt(4, 0).codepoint);
}

test "AsciiCanvas.Frames: clips oversized frame cleanly into smaller viewport" {
    var frames = try AsciiCanvas.Frames.parse(testing.allocator, "ABCDE\nFGHIJ\nKLMNO\n");
    defer frames.deinit(testing.allocator);

    const canvas = try testing.allocator.create(AsciiCanvas);
    defer testing.allocator.destroy(canvas);
    canvas.* = .empty;

    canvas.render(.{ .frames = &frames }, .{
        .cols = 3,
        .rows = 1,
        .time_s = 0,
        .palette = test_palette,
    });
    // Centered crop of 5x3 into 3x1 picks row 1 ("FGHIJ"), cols 1..4 ("GHI").
    try testing.expectEqual(@as(u21, 'G'), canvas.cellAt(0, 0).codepoint);
    try testing.expectEqual(@as(u21, 'H'), canvas.cellAt(1, 0).codepoint);
    try testing.expectEqual(@as(u21, 'I'), canvas.cellAt(2, 0).codepoint);
}

test "AsciiCanvas.Frames: rejects empty, invalid UTF-8, oversized, and too-many-frame inputs" {
    try testing.expectError(error.EmptyAnimation, AsciiCanvas.Frames.parse(testing.allocator, ""));
    try testing.expectError(error.EmptyAnimation, AsciiCanvas.Frames.parse(testing.allocator, "# fps: 10\n   \n---\n  \n"));
    try testing.expectError(error.InvalidUtf8, AsciiCanvas.Frames.parse(testing.allocator, &.{ 0xff, 0xfe }));

    // FileTooLarge
    const huge = try testing.allocator.alloc(u8, AsciiCanvas.Frames.max_file_bytes + 1);
    defer testing.allocator.free(huge);
    @memset(huge, 'x');
    try testing.expectError(error.FileTooLarge, AsciiCanvas.Frames.parse(testing.allocator, huge));

    // TooManyFrames
    var many: std.ArrayList(u8) = .empty;
    defer many.deinit(testing.allocator);
    for (0..AsciiCanvas.Frames.max_frames + 1) |_| {
        try many.appendSlice(testing.allocator, "*\n---\n");
    }
    try testing.expectError(error.TooManyFrames, AsciiCanvas.Frames.parse(testing.allocator, many.items));
}
