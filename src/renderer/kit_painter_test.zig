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
const icons = @import("../kit/icons.zig");
const tree_zig = @import("../kit/tree.zig");
const Tree = tree_zig.Tree;
const layout = @import("../kit/layout.zig");
const memory = @import("../kit/memory.zig");
const dialog_ui = @import("../kit/dialog.zig");
const toast_stack = @import("../kit/toast.zig");

const inter: KitFont.Files = .{
    .regular = "assets/fonts/Inter-Regular.ttf",
    .medium = "assets/fonts/Inter-Medium.ttf",
    .semibold = "assets/fonts/Inter-SemiBold.ttf",
    .icons = "assets/fonts/lucide.ttf",
};

/// Logical size of the test window.
const view_width = 760;
const view_height = 440;

const terminal_dark: Color = .rgb(0x101014);
const terminal_light: Color = .rgb(0xfbfaf7);

const Scene = enum {
    /// Hand-built banner and toasts, as approved in the token preview.
    overlay,
    /// The confirm dialog (`kit/dialog.zig`), fully in.
    dialog,
    /// The same dialog after one Tab: the ring is on Cancel.
    dialog_cancel_focused,
    /// The app's toast stack (`kit/toast.zig`), its newest toast halfway in.
    toasts,
};

const Marks = struct {
    toast: tree_zig.Index = tree_zig.none,
    title: tree_zig.Index = tree_zig.none,
    dialog: tree_zig.Index = tree_zig.none,
    confirm: tree_zig.Index = tree_zig.none,
    cancel: tree_zig.Index = tree_zig.none,
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
    _ = try tree.icon(.{ .codepoint = icons.info, .color = icon, .size = Theme.icon });
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

fn build(tree: *Tree, scene: Scene, theme: *const Theme, toasts: *const toast_stack.State, dialog_state: *const dialog_ui.State) !Marks {
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
        .dialog, .dialog_cancel_focused => {
            _ = try dialog_ui.view(dialog_state, tree, theme) orelse unreachable;
            marks.dialog = nodeWithId(tree, dialog_ui.card_id);
            marks.confirm = nodeWithId(tree, dialog_ui.Action.confirm.id());
            marks.cancel = nodeWithId(tree, dialog_ui.Action.cancel.id());
        },
        .toasts => _ = try toast_stack.view(toasts, tree, theme),
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
    /// The texts of the `toasts` scene live here.
    toasts: toast_stack.State,
    /// The texts of the `dialog` scene live here.
    dialog: dialog_ui.State,

    fn card(self: *const Rendered, serial: u32) tree_zig.Rect {
        for (self.tree_nodes[0..self.tree_len]) |node| {
            if (node.box.id == toast_stack.cardId(serial)) return node.rect;
        }
        unreachable; // the scene shows every toast it pushed
    }

    fn rect(self: *const Rendered, index: tree_zig.Index) tree_zig.Rect {
        return self.tree_nodes[index].rect;
    }
};

fn nodeWithId(tree: *const Tree, id: tree_zig.Id) tree_zig.Index {
    for (tree.nodes[0..tree.len], 0..) |node, index| {
        if (node.box.id == id) return @intCast(index);
    }
    unreachable;
}

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
    result.toasts = .empty;
    result.dialog = .empty;
    if (scene == .dialog or scene == .dialog_cancel_focused) {
        _ = dialog_ui.update(&result.dialog, .{ .open = .{
            .title = "Close this window?",
            .body = "A program is still running: nvim. Closing the window ends it.",
            .confirm_label = "Close window",
            .cancel_label = "Cancel",
        } });
        // Fully in, so the shot is the resting dialog rather than a fade.
        _ = dialog_ui.update(&result.dialog, .{ .tick = Theme.duration });
        if (scene == .dialog_cancel_focused) _ = dialog_ui.update(&result.dialog, .{ .focus = .next });
    }
    const pushes = [_]toast_stack.Push{
        .{ .title = "Couldn\u{2019}t save wellbeing data", .description = "AccessDenied in /home/user/.local/state/rex/wellbeing", .kind = .err, .duration_ms = 5000 },
        .{ .title = "Configuration reloaded", .kind = .success, .duration_ms = 5000 },
        .{ .title = "Font: 14 (18 px at 125%, cell 11x22)", .duration_ms = 5000 },
    };
    for (pushes) |push| {
        // The earlier ones finish entering; the last is left halfway.
        _ = toast_stack.update(&result.toasts, .{ .tick = Theme.duration });
        _ = toast_stack.update(&result.toasts, .{ .push = push });
    }
    _ = toast_stack.update(&result.toasts, .{ .tick = Theme.duration / 2 });

    result.marks = try build(&tree, scene, variant.theme(), &result.toasts, &result.dialog);
    try layout.layout(&tree, font.measurer(), view_width, view_height);
    if (scene == .toasts) {
        var table: memory.Table = .empty;
        _ = try toast_stack.place(&result.toasts, &tree, 0, &table, 0);
    }
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

test "KitPainter: the toast stack, with its newest toast halfway in" {
    for ([_]f32{ 1, 1.25, 1.5 }) |scale| {
        var rendered = try render(.toasts, .dark, terminal_dark, scale, .pairs);
        defer rendered.frame.deinit();
        const frame = &rendered.frame;
        const theme = &Theme.dark;
        var name_buffer: [48]u8 = undefined;
        try frame.save(try std.fmt.bufPrint(&name_buffer, "toasts-dark-{d}", .{@as(u32, @intFromFloat(scale * 100))}));

        const entries = rendered.toasts.visible();
        try testing.expectEqual(3, entries.len);
        // At rest: the popover color inside the padding.
        const settled = rendered.card(entries[1].serial);
        try testing.expectEqual(rgb(theme.popover), frame.at(settled.x + 6, settled.y + settled.h / 2));
        // Halfway in time it is 87.5% present: between the terminal and the
        // popover color, nearer the popover.
        const entering = rendered.card(entries[2].serial);
        const blended = frame.at(entering.x + 6, entering.y + entering.h / 2);
        try testing.expect(blended[0] > terminal_dark.r + 3 and blended[0] < theme.popover.r);
        // The stack keeps its margin: 24 px from the right edge.
        try testing.expectEqual(view_width - 24, settled.x + settled.w);
        try testing.expectEqual(rgb(terminal_dark), frame.at(view_width - 12, settled.y + settled.h / 2));
    }
}

test "KitPainter: a toast's icon is a line drawing in its kind's color" {
    for ([_]f32{ 1, 1.25, 1.5 }) |scale| {
        var rendered = try render(.toasts, .dark, terminal_dark, scale, .pairs);
        defer rendered.frame.deinit();
        const frame = &rendered.frame;
        const theme = &Theme.dark;

        // The first toast is an error: its card, a slot, then the icon.
        var icon_rect: ?tree_zig.Rect = null;
        for (rendered.tree_nodes[0..rendered.tree_len]) |node| {
            switch (node.content) {
                .icon => |icon| if (icon.codepoint == icons.circle_x) {
                    icon_rect = node.rect;
                },
                else => {},
            }
        }
        const rect = icon_rect.?;
        try testing.expectEqual(@as(f32, Theme.icon), rect.w);
        const area: u32 = @intFromFloat(@round(rect.w * scale) * @round(rect.h * scale));
        const inked = frame.countNot(rect, rgb(theme.popover));
        // A circle with a cross: more than a few pixels, far less than the
        // filled disc that stood in for icons before.
        try testing.expect(inked * 100 > area * 15);
        try testing.expect(inked * 100 < area * 65);
        // Its ink is the destructive color, not the text's.
        var reddest: u8 = 0;
        var y = rect.y;
        while (y < rect.y + rect.h) : (y += 1 / scale) {
            var x = rect.x;
            while (x < rect.x + rect.w) : (x += 1 / scale) {
                const pixel = frame.at(x, y);
                if (pixel[0] > reddest and pixel[1] < pixel[0] / 2 + 40) reddest = pixel[0];
            }
        }
        try testing.expect(reddest > 200);
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
    // The confirm button is the destructive token, sampled in its padding.
    const confirm = rendered.rect(rendered.marks.confirm);
    try testing.expectEqual(rgb(theme.destructive), frame.at(confirm.x + 6, confirm.y + confirm.h / 2));
    try testing.expect(frame.countNot(confirm, rgb(theme.destructive)) > 100);
}

test "KitPainter: the focus ring is a band around a button, not a fill behind it" {
    for ([_]f32{ 1, 1.25, 1.5 }) |scale| {
        var rendered = try render(.dialog_cancel_focused, .dark, terminal_dark, scale, .pairs);
        defer rendered.frame.deinit();
        const frame = &rendered.frame;
        const theme = &Theme.dark;
        var name_buffer: [48]u8 = undefined;
        try frame.save(try std.fmt.bufPrint(&name_buffer, "dialog-dark-{d}-cancel-focused", .{@as(u32, @intFromFloat(scale * 100))}));

        const cancel = rendered.rect(rendered.marks.cancel);
        const middle = cancel.y + cancel.h / 2;
        // Cancel is an outline button: inside its padding the card shows.
        try testing.expectEqual(rgb(theme.popover), frame.at(cancel.x + 6, middle));
        // Two pixels outside its edge is the ring: lighter than the card.
        const ring = frame.at(cancel.x - 2, middle);
        try testing.expect(ring[0] > theme.popover.r + 20);
        // Past the ring's three pixels, the card again.
        try testing.expectEqual(rgb(theme.popover), frame.at(cancel.x - 5, middle));
        // Confirm lost the ring.
        const confirm = rendered.rect(rendered.marks.confirm);
        try testing.expectEqual(rgb(theme.popover), frame.at(confirm.x - 2, confirm.y + confirm.h / 2));
    }
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
        .{ .toasts, .light, terminal_light, 1, .pairs, "toasts-light-100" },
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
