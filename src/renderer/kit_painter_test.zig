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
const button = @import("../kit/button.zig");
const kbd = @import("../kit/kbd.zig");
const alert_dialog = @import("../kit/alert_dialog.zig");
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
    /// The confirm dialog (`kit/alert_dialog.zig`), fully in.
    dialog,
    /// The same dialog after one Tab: the ring is on Cancel.
    dialog_cancel_focused,
    /// The same dialog with a media icon above its title.
    dialog_media,
    /// The app's toast stack (`kit/toast.zig`), its newest toast halfway in.
    toasts,
    /// Every shared component in every variant, size and state.
    specimen,
    /// A clipping box with a larger box and a long text inside it.
    clip,
};

const clip_text = "A line far longer than the box that holds it";

const Marks = struct {
    toast: tree_zig.Index = tree_zig.none,
    title: tree_zig.Index = tree_zig.none,
    dialog: tree_zig.Index = tree_zig.none,
    confirm: tree_zig.Index = tree_zig.none,
    cancel: tree_zig.Index = tree_zig.none,
    /// The clipping box of the `clip` scene.
    clip: tree_zig.Index = tree_zig.none,
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

fn build(tree: *Tree, scene: Scene, theme: *const Theme, toasts: *const toast_stack.State, dialog_state: *const alert_dialog.State) !Marks {
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
        .dialog, .dialog_cancel_focused, .dialog_media => {
            _ = try alert_dialog.view(dialog_state, tree, theme) orelse unreachable;
            marks.dialog = nodeWithId(tree, alert_dialog.card_id);
            // A button's id is on its ring slot; the face is the slot's
            // only child.
            marks.cancel = nodeWithId(tree, alert_dialog.actionId(0)) + 1;
            marks.confirm = nodeWithId(tree, alert_dialog.actionId(1)) + 1;
        },
        .toasts => _ = try toast_stack.view(toasts, tree, theme),
        .specimen => try specimen(tree, theme, &marks),
        .clip => {
            const page = try tree.open(.{ .width = .fill, .height = .fill, .padding = .all(40) });
            marks.clip = try tree.open(.{
                .width = .{ .fixed = 100 },
                .height = .{ .fixed = 60 },
                .overflow = .clip,
            });
            _ = try tree.leaf(.{ .width = .{ .fixed = 300 }, .height = .{ .fixed = 30 }, .fill = theme.destructive });
            _ = try tree.text(clip_text, .{ .color = theme.foreground });
            _ = try tree.leaf(.{ .width = .{ .fixed = 300 }, .height = .{ .fixed = 300 }, .fill = theme.info });
            tree.close(marks.clip);
            tree.close(page);
        },
    }
    return marks;
}

/// One row per button variant with its states left to right (normal,
/// hovered, pressed, focused, disabled), then the small size, then key
/// caps.
fn specimen(tree: *Tree, theme: *const Theme, marks: *Marks) !void {
    const Row = struct { name: []const u8, variant: button.Variant, label: []const u8 };
    const rows = [_]Row{
        .{ .name = "Primary", .variant = .primary, .label = "Save" },
        .{ .name = "Outline", .variant = .outline, .label = "Cancel" },
        .{ .name = "Ghost", .variant = .ghost, .label = "Skip" },
        .{ .name = "Destructive", .variant = .destructive, .label = "Delete" },
    };
    const name_width = 96;
    const sheet = try tree.open(.{ .width = .fill, .height = .fill, .padding = .all(20), .gap = 10, .fill = theme.background });
    for (rows, 0..) |row, at| {
        const line = try tree.open(.{ .axis = .row, .gap = button.gap, .cross = .center });
        _ = try tree.text(row.name, .{ .color = theme.muted_foreground, .style = .xs, .width = .{ .fixed = name_width } });
        const first = tree.len;
        const id = tree_zig.Id.of("specimen.button").item(@intCast(at));
        try button.view(tree, theme, .{ .id = id, .label = row.label, .variant = row.variant });
        try button.view(tree, theme, .{ .id = id, .label = row.label, .variant = row.variant, .state = .hovered });
        try button.view(tree, theme, .{ .id = id, .label = row.label, .variant = row.variant, .state = .pressed });
        try button.view(tree, theme, .{ .id = id, .label = row.label, .variant = row.variant, .focused = true });
        try button.view(tree, theme, .{ .id = id, .label = row.label, .variant = row.variant, .state = .disabled });
        tree.close(line);
        if (row.variant == .primary) {
            // Faces of the normal and the disabled button: a slot holds a
            // face and a label, three nodes a button.
            marks.confirm = first + 1;
            marks.cancel = first + 4 * 3 + 1;
        }
    }
    const small = try tree.open(.{ .axis = .row, .gap = button.gap, .cross = .center });
    _ = try tree.text("Small", .{ .color = theme.muted_foreground, .style = .xs, .width = .{ .fixed = name_width } });
    for (rows) |row| {
        try button.view(tree, theme, .{ .id = tree_zig.Id.of("specimen.small"), .label = row.label, .variant = row.variant, .size = .sm });
    }
    tree.close(small);
    const caps = try tree.open(.{ .axis = .row, .gap = 16, .cross = .center });
    _ = try tree.text("Kbd", .{ .color = theme.muted_foreground, .style = .xs, .width = .{ .fixed = name_width - 8 } });
    try kbd.view(tree, theme, "Esc", 1);
    try kbd.group(tree, theme, &.{ "Ctrl", "Shift", "P" }, 1);
    try button.view(tree, theme, .{ .id = tree_zig.Id.of("specimen.cap"), .label = "Cancel", .key_cap = "Esc" });
    tree.close(caps);
    tree.close(sheet);
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
    dialog: alert_dialog.State,

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
    if (scene == .dialog or scene == .dialog_cancel_focused or scene == .dialog_media) {
        _ = alert_dialog.update(&result.dialog, .{ .open = .{
            .media = if (scene == .dialog_media) icons.triangle_alert else 0,
            .title = "Close this window?",
            .body = "A program is still running: nvim. Closing the window ends it.",
            .actions = &.{
                .{ .label = "Cancel", .role = .dismiss, .key_cap = "Esc" },
                .{ .label = "Close window", .variant = .destructive },
            },
            .focus = 1,
        } });
        // Fully in, so the shot is the resting dialog rather than a fade.
        _ = alert_dialog.update(&result.dialog, .{ .tick = Theme.duration });
        if (scene == .dialog_cancel_focused) _ = alert_dialog.update(&result.dialog, .{ .focus = .next });
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

test "KitPainter: an arc instance is the square around its centre" {
    const arc: tree_zig.Arc = .{
        .radius = 10,
        .thickness = 4,
        .start = 1,
        .sweep = 2,
        .fill = .{ .r = 1, .g = 2, .b = 3, .a = 255 },
        .caps = .round,
    };
    const got = KitPainter.arcInstance(arc, 100, 50, 20, 2);
    try testing.expectEqual([4]f32{ 200, 100, 40, 40 }, got.rect);
    try testing.expectEqual([2]f32{ 20, -8 }, got.params);
    try testing.expectEqual([2]f32{ 1, 2 }, got.arc);
    try testing.expectEqual(KitPainter.Kind.arc, got.kind);
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

test "KitPainter: a clipping box cuts its descendants at its edges" {
    for ([_]f32{ 1, 1.25, 1.5 }) |scale| {
        var rendered = try render(.clip, .dark, terminal_dark, scale, .pairs);
        defer rendered.frame.deinit();
        const frame = &rendered.frame;
        const box = rendered.rect(rendered.marks.clip);
        const theme = &Theme.dark;
        try frame.save(if (scale == 1) "clip-dark-100" else if (scale == 1.25) "clip-dark-125" else "clip-dark-150");

        // Inside: the red bar, then the text wrapped to the box's width,
        // which pushes the blue box out of it entirely.
        try testing.expectEqual(rgb(theme.destructive), frame.at(box.x + 50, box.y + 15));
        const area = layout.snap(box, scale);
        try testing.expectEqual(@as(u32, @intCast(area.w * area.h)), frame.countNot(box, rgb(theme.info)));
        try testing.expect(frame.countNot(.{ .x = box.x, .y = box.y + 30, .w = box.w, .h = 30 }, rgb(terminal_dark)) > 0);
        // Right of the box and below it, nothing of either is drawn.
        try testing.expectEqual(0, frame.countNot(.{ .x = box.x + box.w, .y = box.y, .w = 300, .h = box.h }, rgb(terminal_dark)));
        try testing.expectEqual(0, frame.countNot(.{ .x = box.x, .y = box.y + box.h, .w = box.w, .h = 200 }, rgb(terminal_dark)));
        // Glyphs wholly outside are not even sent to the GPU: fewer
        // instances than the two visible boxes and every glyph.
        var glyphs: u32 = 0;
        for (clip_text) |byte| glyphs += @intFromBool(byte != ' ');
        try testing.expect(rendered.instances < 2 + glyphs);
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
        .{ .dialog_media, .dark, terminal_dark, 1, .pairs, "dialog-media-dark-100" },
        .{ .dialog_media, .light, terminal_light, 1, .pairs, "dialog-media-light-100" },
    };
    for (shots) |shot| {
        var rendered = try render(shot[0], shot[1], shot[2], shot[3], shot[4]);
        defer rendered.frame.deinit();
        try rendered.frame.save(shot[5]);
    }
}

test "KitPainter: the specimen sheet draws every component in both themes" {
    for ([_]Theme.Variant{ .dark, .light }) |variant| {
        var rendered = try render(.specimen, variant, terminal_dark, 1, .pairs);
        defer rendered.frame.deinit();
        const frame = &rendered.frame;
        const theme = variant.theme();
        try frame.save(if (variant == .dark) "specimen-dark-100" else "specimen-light-100");

        // The sheet covers the terminal.
        try testing.expectEqual(rgb(theme.background), frame.at(4, 4));
        // A disabled button is its normal self at half opacity over the
        // sheet, so its face is neither color.
        const normal = rendered.rect(rendered.marks.confirm);
        const disabled = rendered.rect(rendered.marks.cancel);
        try testing.expectEqual(rgb(theme.primary), frame.at(normal.x + 6, normal.y + normal.h / 2));
        const faded = frame.at(disabled.x + 6, disabled.y + disabled.h / 2);
        try testing.expect(!std.mem.eql(u8, &faded, &rgb(theme.primary)));
        try testing.expect(!std.mem.eql(u8, &faded, &rgb(theme.background)));
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
