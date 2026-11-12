//! Renders the UI kit's toast stack, banner and dialog offscreen with the
//! real font and checks the pixels. With `-Dkit-shots=<dir>` the frames are
//! also saved there as PPM files, to judge the look by eye.

const std = @import("std");
const testing = std.testing;

const gl = @import("gl.zig");
const Atlas = @import("Atlas.zig");
const KitPainter = @import("KitPainter.zig");
const testGlContext = @import("Window.zig").testGlContext;
const KitFont = @import("../freetype/KitFont.zig");
const Theme = @import("../kit/Theme.zig");
const Color = Theme.Color;
const text = @import("../kit/text.zig");
const tree_zig = @import("../kit/tree.zig");
const Tree = tree_zig.Tree;
const layout = @import("../kit/layout.zig");

const inter: KitFont.Files = .{
    .regular = "assets/fonts/Inter-Regular.ttf",
    .medium = "assets/fonts/Inter-Medium.ttf",
    .semibold = "assets/fonts/Inter-SemiBold.ttf",
};

/// Logical size of the test window.
const view_width = 760;
const view_height = 440;

const terminal_dark: Color = .rgb(0x101014);
const terminal_light: Color = .rgb(0xfbfaf7);

const Scene = enum { overlay, dialog };

const Marks = struct {
    toast: tree_zig.Index = tree_zig.none,
    title: tree_zig.Index = tree_zig.none,
    dialog: tree_zig.Index = tree_zig.none,
    confirm: tree_zig.Index = tree_zig.none,
};

fn toast(tree: *Tree, theme: *const Theme, icon: Color, title: []const u8, description: []const u8, marks: ?*Marks) !void {
    const box = try tree.open(.{
        .axis = .row,
        .width = .{ .fixed = 356 },
        .padding = .symmetric(16, 14),
        .gap = 10,
        .fill = theme.popover,
        .border = theme.border,
        .border_width = Theme.border_width,
        .radius = Theme.radius,
    });
    const dot = try tree.open(.{ .padding = .{ .top = 2 } });
    _ = try tree.icon(.{ .codepoint = 0, .color = icon, .size = Theme.icon });
    tree.close(dot);
    const body = try tree.open(.{ .width = .fill });
    const title_node = try tree.text(title, .{ .color = theme.foreground, .style = .sm_medium });
    _ = try tree.text(description, .{ .color = theme.muted_foreground, .width = .fill });
    tree.close(body);
    tree.close(box);
    if (marks) |m| {
        m.toast = box;
        m.title = title_node;
    }
}

fn button(tree: *Tree, label: []const u8, fill: Color, border: Color, foreground: Color) !tree_zig.Index {
    const box = try tree.open(.{
        .axis = .row,
        .height = .{ .fixed = Theme.control },
        .padding = .symmetric(16, 0),
        .main = .center,
        .cross = .center,
        .fill = fill,
        .border = border,
        .border_width = Theme.border_width,
        .radius = Theme.radius_md,
    });
    _ = try tree.text(label, .{ .color = foreground, .style = .sm_medium });
    tree.close(box);
    return box;
}

fn build(tree: *Tree, scene: Scene, theme: *const Theme) !Marks {
    var marks: Marks = .{};
    switch (scene) {
        .overlay => {
            const banner = try tree.open(.{
                .axis = .row,
                .width = .fill,
                .padding = .symmetric(16, 10),
                .gap = 10,
                .cross = .center,
                .fill = theme.popover,
                .border = theme.border,
                .border_width = Theme.border_width,
            });
            _ = try tree.leaf(.{ .width = .{ .fixed = 8 }, .height = .{ .fixed = 8 }, .radius = 4, .fill = theme.destructive });
            _ = try tree.text("Config not reloaded.", .{ .color = theme.foreground, .style = .sm_medium });
            _ = try tree.text("Unknown key \u{201C}font.sizee\u{201D} on line 14.", .{ .color = theme.muted_foreground });
            tree.close(banner);

            const stack = try tree.open(.{ .width = .fill, .height = .fill, .main = .end, .cross = .end, .padding = .all(24), .gap = 14 });
            try toast(tree, theme, theme.info, "Focus session started", "25 minutes. Press Ctrl Shift P to pause, or keep typing to dismiss this.", null);
            try toast(tree, theme, theme.success, "Copied 3 lines", "Selection is on the clipboard.", &marks);
            tree.close(stack);
        },
        .dialog => {
            const scrim = try tree.open(.{ .width = .fill, .height = .fill, .main = .center, .cross = .center, .fill = theme.scrim });
            const dialog = try tree.open(.{
                .width = .{ .fixed = 420 },
                .padding = .all(24),
                .gap = 16,
                .fill = theme.popover,
                .border = theme.border,
                .border_width = Theme.border_width,
                .radius = Theme.radius,
            });
            const heading = try tree.open(.{ .width = .fill, .gap = 6 });
            _ = try tree.text("Close this window?", .{ .color = theme.foreground, .style = .lg_semibold });
            _ = try tree.text("A program is still running: nvim. Closing the window ends it.", .{ .color = theme.muted_foreground, .width = .fill });
            tree.close(heading);
            const actions = try tree.open(.{ .axis = .row, .width = .fill, .main = .end, .gap = 8 });
            _ = try button(tree, "Cancel", .transparent, theme.input, theme.foreground);
            marks.confirm = try button(tree, "Close window", theme.destructive, .transparent, theme.destructive_foreground);
            tree.close(actions);
            tree.close(dialog);
            tree.close(scrim);
            marks.dialog = dialog;
        },
    }
    return marks;
}

const Frame = struct {
    width: u32,
    height: u32,
    /// RGBA rows, top row first.
    pixels: []u8,
    scale: f32,

    fn deinit(self: *Frame) void {
        testing.allocator.free(self.pixels);
    }

    /// The pixel under a point given in logical pixels.
    fn at(self: *const Frame, x: f32, y: f32) [3]u8 {
        const px: u32 = @intFromFloat(@floor(x * self.scale));
        const py: u32 = @intFromFloat(@floor(y * self.scale));
        const offset = (py * self.width + px) * 4;
        return self.pixels[offset..][0..3].*;
    }

    /// How many pixels of a logical rectangle differ from `color`.
    fn countNot(self: *const Frame, rect: tree_zig.Rect, color: [3]u8) u32 {
        const area = layout.snap(rect, self.scale);
        var count: u32 = 0;
        var y = area.y;
        while (y < area.y + area.h) : (y += 1) {
            var x = area.x;
            while (x < area.x + area.w) : (x += 1) {
                const offset: usize = (@as(usize, @intCast(y)) * self.width + @as(usize, @intCast(x))) * 4;
                if (!std.mem.eql(u8, self.pixels[offset..][0..3], &color)) count += 1;
            }
        }
        return count;
    }

    fn save(self: *const Frame, name: []const u8) !void {
        const dir = @import("test_options").kit_shots;
        if (dir.len == 0) return;
        const gpa = testing.allocator;
        const path = try std.fmt.allocPrint(gpa, "{s}/{s}.ppm", .{ dir, name });
        defer gpa.free(path);
        var header_buffer: [32]u8 = undefined;
        const header = try std.fmt.bufPrint(&header_buffer, "P6\n{d} {d}\n255\n", .{ self.width, self.height });
        const data = try gpa.alloc(u8, header.len + @as(usize, self.width) * self.height * 3);
        defer gpa.free(data);
        @memcpy(data[0..header.len], header);
        var out: usize = header.len;
        var in: usize = 0;
        while (in < self.pixels.len) : (in += 4) {
            @memcpy(data[out..][0..3], self.pixels[in..][0..3]);
            out += 3;
        }
        try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = path, .data = data });
    }
};

const Rendered = struct {
    frame: Frame,
    tree_nodes: [128]tree_zig.Node,
    tree_len: tree_zig.Index,
    marks: Marks,
    instances: u32,

    fn rect(self: *const Rendered, index: tree_zig.Index) tree_zig.Rect {
        return self.tree_nodes[index].rect;
    }
};

fn rgb(color: Color) [3]u8 {
    return .{ color.r, color.g, color.b };
}

/// Lays `scene` out and draws it over `background` into an offscreen
/// framebuffer at `scale`.
fn render(scene: Scene, variant: Theme.Variant, background: Color, scale: f32, kerning: KitFont.Kerning) !Rendered {
    try testGlContext();
    const gpa = testing.allocator;

    var atlas = try Atlas.create(gpa, .{ .width = 1024, .height = 1024 });
    defer atlas.destroy();
    var font = try KitFont.create(inter, .{ .scale = scale, .kerning = kerning });
    defer font.destroy();
    var painter = try KitPainter.init();
    defer painter.deinit();

    var result: Rendered = undefined;
    var lines: [64]text.Line = undefined;
    var tree: Tree = .init(&result.tree_nodes, &lines);
    result.marks = try build(&tree, scene, variant.theme());
    try layout.layout(&tree, font.measurer(), view_width, view_height);
    result.tree_len = tree.len;

    const width: u32 = @intFromFloat(@round(view_width * scale));
    const height: u32 = @intFromFloat(@round(view_height * scale));

    var target: gl.GLuint = 0;
    gl.genTextures(1, &target);
    defer gl.deleteTextures(1, &target);
    gl.bindTexture(gl.TEXTURE_2D, target);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, @intCast(width), @intCast(height), 0, gl.RGBA, gl.UNSIGNED_BYTE, null);
    gl.bindTexture(gl.TEXTURE_2D, 0);
    var fbo: gl.GLuint = 0;
    gl.genFramebuffers(1, &fbo);
    defer gl.deleteFramebuffers(1, &fbo);
    gl.bindFramebuffer(gl.FRAMEBUFFER, fbo);
    defer gl.bindFramebuffer(gl.FRAMEBUFFER, 0);
    gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, target, 0);
    try testing.expectEqual(@as(gl.GLenum, gl.FRAMEBUFFER_COMPLETE), gl.checkFramebufferStatus(gl.FRAMEBUFFER));

    gl.viewport(0, 0, @intCast(width), @intCast(height));
    gl.clearColor(
        @as(f32, @floatFromInt(background.r)) / 255.0,
        @as(f32, @floatFromInt(background.g)) / 255.0,
        @as(f32, @floatFromInt(background.b)) / 255.0,
        1,
    );
    gl.clear(gl.COLOR_BUFFER_BIT);

    painter.begin();
    try painter.paint(&tree, &font, &atlas);
    painter.draw(&atlas, @floatFromInt(width), @floatFromInt(height));
    result.instances = painter.len;

    // GL rows run bottom-up; store them top-down.
    const row = @as(usize, width) * 4;
    const raw = try gpa.alloc(u8, row * height);
    defer gpa.free(raw);
    gl.pixelStorei(gl.PACK_ALIGNMENT, 1);
    gl.readPixels(0, 0, @intCast(width), @intCast(height), gl.RGBA, gl.UNSIGNED_BYTE, raw.ptr);
    gl.pixelStorei(gl.PACK_ALIGNMENT, 4);
    const pixels = try gpa.alloc(u8, raw.len);
    for (0..height) |y| @memcpy(pixels[y * row ..][0..row], raw[(height - 1 - y) * row ..][0..row]);

    result.frame = .{ .width = width, .height = height, .pixels = pixels, .scale = scale };
    return result;
}

test "KitPainter: a toast is a filled, bordered box with text, over an untouched background" {
    for ([_]f32{ 1, 1.25, 1.5 }) |scale| {
        var rendered = try render(.overlay, .dark, terminal_dark, scale, .pairs);
        defer rendered.frame.deinit();
        const frame = &rendered.frame;
        const theme = &Theme.dark;
        var name_buffer: [48]u8 = undefined;
        try frame.save(try std.fmt.bufPrint(&name_buffer, "overlay-dark-{d}", .{@as(u32, @intFromFloat(scale * 100))}));

        const box = rendered.rect(rendered.marks.toast);
        const middle = box.y + box.h / 2;
        // Inside the padding, clear of the border, the icon and the corners.
        try testing.expectEqual(rgb(theme.popover), frame.at(box.x + 6, middle));
        // The hairline: white at 10% over the popover color.
        const edge = frame.at(box.x, middle);
        try testing.expect(edge[0] > theme.popover.r + 8 and edge[0] < theme.popover.r + 40);
        // Just outside, and far away: the terminal background.
        try testing.expectEqual(rgb(terminal_dark), frame.at(box.x - 3, middle));
        try testing.expectEqual(rgb(terminal_dark), frame.at(40, 200));
        // The corner is rounded: the box's own corner pixel stays background.
        try testing.expectEqual(rgb(terminal_dark), frame.at(box.x + 0.5, box.y + 0.5));
        // The title drew ink.
        try testing.expect(frame.countNot(rendered.rect(rendered.marks.title), rgb(theme.popover)) > 200);
        try testing.expect(rendered.instances > 100);
    }
}

test "KitPainter: a dialog sits on a scrim that darkens the terminal behind it" {
    var rendered = try render(.dialog, .light, terminal_light, 1, .pairs);
    defer rendered.frame.deinit();
    const frame = &rendered.frame;
    const theme = &Theme.light;
    try frame.save("dialog-light-100");

    const box = rendered.rect(rendered.marks.dialog);
    try testing.expectEqual(rgb(theme.popover), frame.at(box.x + 12, box.y + box.h / 2));
    // Black at 50% over the terminal background, within rounding.
    const dimmed = frame.at(20, 20);
    try testing.expectApproxEqAbs(@as(f32, @floatFromInt(terminal_light.r)) / 2, @as(f32, @floatFromInt(dimmed[0])), 2);
    // The destructive button is filled with its token, behind its label.
    const confirm = rendered.rect(rendered.marks.confirm);
    try testing.expectEqual(rgb(theme.destructive), frame.at(confirm.x + 6, confirm.y + confirm.h / 2));
    try testing.expect(frame.countNot(confirm, rgb(theme.destructive)) > 100);
}

test "KitPainter: screenshots of the remaining variants" {
    if (@import("test_options").kit_shots.len == 0) return error.SkipZigTest;
    const shots = [_]struct { Scene, Theme.Variant, Color, f32, KitFont.Kerning, []const u8 }{
        .{ .overlay, .light, terminal_light, 1, .pairs, "overlay-light-100" },
        .{ .dialog, .dark, terminal_dark, 1, .pairs, "dialog-dark-100" },
        .{ .dialog, .dark, terminal_dark, 1.25, .pairs, "dialog-dark-125" },
        .{ .dialog, .dark, terminal_dark, 1.5, .pairs, "dialog-dark-150" },
        .{ .dialog, .dark, terminal_dark, 1, .off, "dialog-dark-100-no-kerning" },
        .{ .overlay, .dark, terminal_dark, 1, .off, "overlay-dark-100-no-kerning" },
    };
    for (shots) |shot| {
        var rendered = try render(shot[0], shot[1], shot[2], shot[3], shot[4]);
        defer rendered.frame.deinit();
        try rendered.frame.save(shot[5]);
    }
}

test "KitPainter: more instances than fit is an error" {
    try testGlContext();
    var atlas = try Atlas.create(testing.allocator, .{ .width = 512, .height = 512 });
    defer atlas.destroy();
    var font = try KitFont.create(inter, .{});
    defer font.destroy();
    var painter = try KitPainter.init();
    defer painter.deinit();

    var nodes: [4]tree_zig.Node = undefined;
    var lines: [4]text.Line = undefined;
    var tree: Tree = .init(&nodes, &lines);
    _ = try tree.text("x" ** (KitPainter.capacity + 1), .{ .color = Theme.dark.foreground });
    try layout.layout(&tree, font.measurer(), 100_000, 100);

    painter.begin();
    try testing.expectError(error.OutOfInstances, painter.paint(&tree, &font, &atlas));
    try testing.expectEqual(KitPainter.capacity, painter.len);
}
