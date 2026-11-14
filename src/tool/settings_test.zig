const std = @import("std");
const testing = std.testing;

const Rgb = @import("../color/Rgb.zig");
const kit = @import("../kit/root.zig");
const config_defaults = @import("../config/default.zig");
const keys = @import("../config/keys.zig");
const host = @import("host.zig");
const settings = @import("settings.zig");

const Id = kit.tree.Id;

fn measure(_: *anyopaque, bytes: []const u8, _: kit.text.Style, _: kit.text.Figures) f32 {
    return @as(f32, @floatFromInt(bytes.len)) * 8.0;
}

var dummy: u8 = 0;
const measurer: kit.text.Measurer = .{ .context = &dummy, .widthFn = measure };

fn keyIndex(section: keys.Section, name: []const u8) u16 {
    return keys.lookup(section, name) orelse unreachable;
}

test "settings: every page fits node_max and line_max at narrow and wide sizes" {
    const gpa = testing.allocator;
    const cfg = config_defaults.default;
    var state = try settings.init(.{
        .gpa = gpa,
        .io = testing.io,
        .config = &cfg,
        .state_dir = "",
        .wake_loop = struct {
            fn wake() void {}
        }.wake,
    });
    defer settings.deinit(&state);

    var nodes: [settings.node_max]kit.tree.Node = undefined;
    var lines: [settings.line_max]kit.text.Line = undefined;

    for ([_]bool{ false, true }) |ansi_open| {
        state.ansi_colors_open = ansi_open;
        for ([_][2]f32{ .{ 420, 500 }, .{ 960, 720 } }) |sz| {
            _ = settings.update(&state, .{ .size = .{ .width = sz[0], .height = sz[1] } });
            for (0..@typeInfo(settings.Page).@"enum".fields.len) |page_idx| {
                state.frame.current = @intCast(page_idx);
                var tree = kit.tree.Tree.init(&nodes, &lines);
                try settings.view(&state, &tree, &kit.Theme.dark);
                try kit.layout.layout(&tree, measurer, sz[0], sz[1]);
            }
        }
    }
}

test "settings: switch, select, text input save and inline validation via temp config" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(dir_path);
    const cfg_path = try std.fs.path.join(gpa, &.{ dir_path, "config" });
    defer gpa.free(cfg_path);

    const cfg = config_defaults.default;
    var state = try settings.init(.{
        .gpa = gpa,
        .io = testing.io,
        .config = &cfg,
        .state_dir = dir_path,
        .config_path = cfg_path,
        .home_dir = dir_path,
        .wake_loop = struct {
            fn wake() void {}
        }.wake,
    });
    defer settings.deinit(&state);

    // 1. Toggle bell.enabled (starts true -> false).
    const bell_idx = keyIndex(.bell, "enabled");
    const bell_id = Id.of("settings.switch").item(bell_idx);
    try testing.expect(state.activeConfig().window.bell.enabled);
    _ = settings.update(&state, .{ .pointer = .{ .id = bell_id } });
    _ = settings.update(&state, .{ .press = bell_id });
    try testing.expect(settings.update(&state, .release));
    try testing.expect(!state.activeConfig().window.bell.enabled);
    try testing.expectEqual(@as(?u16, null), state.error_key);

    // 2. Select ui.motion -> none (index 1).
    const motion_idx = keyIndex(.ui, "motion");
    const motion_id = Id.of("settings.select").item(motion_idx);
    _ = settings.update(&state, .{ .pointer = .{ .id = motion_id } });
    _ = settings.update(&state, .{ .press = motion_id });
    try testing.expect(settings.update(&state, .release));
    try testing.expect(state.open_select != null);
    try testing.expect(settings.update(&state, .{ .key = .{ .key = .down } }));
    try testing.expect(settings.update(&state, .{ .key = .{ .key = .enter } }));
    try testing.expect(state.open_select == null);
    try testing.expectEqual(.none, state.activeConfig().ui.motion);

    // 3. Edit font.size: invalid value surfaces error_key, valid value saves.
    const size_idx = keyIndex(.font, "size");
    const size_id = Id.of("settings.input").item(size_idx);
    _ = settings.update(&state, .{ .pointer = .{ .id = size_id } });
    _ = settings.update(&state, .{ .press = size_id });
    _ = settings.update(&state, .release);
    try testing.expect(settings.update(&state, .{ .key = .{ .key = .a, .mods = .{ .ctrl = true } } }));
    try testing.expect(settings.update(&state, .{ .char = 'x' }));
    try testing.expect(settings.update(&state, .{ .key = .{ .key = .enter } }));
    try testing.expectEqual(@as(?u16, size_idx), state.error_key);
    try testing.expect(state.error_msg.items.len > 0);

    try testing.expect(settings.update(&state, .{ .key = .{ .key = .a, .mods = .{ .ctrl = true } } }));
    try testing.expect(settings.update(&state, .{ .char = '1' }));
    try testing.expect(settings.update(&state, .{ .char = '6' }));
    try testing.expect(settings.update(&state, .{ .key = .{ .key = .enter } }));
    try testing.expectEqual(@as(?u16, null), state.error_key);
    try testing.expectEqual(@as(u32, 16), state.activeConfig().font.size);
}

test "settings: clipboard copy, cut, and paste in focused text input" {
    const gpa = testing.allocator;
    const MockClip = struct {
        buf: [64]u8 = undefined,
        len: usize = 0,

        fn get(ptr: *anyopaque) ?[:0]const u8 {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            if (self.len == 0) return null;
            return self.buf[0..self.len :0];
        }

        fn set(ptr: *anyopaque, value: [:0]const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            const n = @min(value.len, self.buf.len - 1);
            @memcpy(self.buf[0..n], value[0..n]);
            self.buf[n] = 0;
            self.len = n;
        }
    };
    var clip: MockClip = .{};

    const cfg = config_defaults.default;
    var state = try settings.init(.{
        .gpa = gpa,
        .io = testing.io,
        .config = &cfg,
        .state_dir = "",
        .clipboard = .{ .ctx = &clip, .getFn = MockClip.get, .setFn = MockClip.set },
        .wake_loop = struct {
            fn wake() void {}
        }.wake,
    });
    defer settings.deinit(&state);

    const size_idx = keyIndex(.font, "size");
    const size_id = Id.of("settings.input").item(size_idx);
    _ = settings.update(&state, .{ .pointer = .{ .id = size_id } });
    _ = settings.update(&state, .{ .press = size_id });
    _ = settings.update(&state, .release);

    // Select all, cut, verify clipboard has previous text, paste it back.
    try testing.expect(settings.update(&state, .{ .key = .{ .key = .a, .mods = .{ .ctrl = true } } }));
    try testing.expect(settings.update(&state, .{ .key = .{ .key = .x, .mods = .{ .ctrl = true } } }));
    try testing.expectEqualStrings("", state.inputs[size_idx].text());
    try testing.expect(clip.len > 0);
    try testing.expect(settings.update(&state, .{ .key = .{ .key = .v, .mods = .{ .ctrl = true } } }));
    try testing.expectEqualStrings(clip.buf[0..clip.len], state.inputs[size_idx].text());
}

test "settings: list key add, reorder, remove, and reload" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const cfg_path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/config", .{tmp.sub_path});
    defer gpa.free(cfg_path);

    const cfg = config_defaults.default;
    var state = try settings.init(.{
        .gpa = gpa,
        .io = testing.io,
        .config = &cfg,
        .config_path = cfg_path,
        .state_dir = "",
        .wake_loop = struct {
            fn wake() void {}
        }.wake,
    });
    defer settings.deinit(&state);

    const arg_idx = keyIndex(.shell, "argument");
    const arg_input_id = Id.of("settings.input").item(arg_idx);
    _ = settings.update(&state, .{ .pointer = .{ .id = arg_input_id } });
    _ = settings.update(&state, .{ .press = arg_input_id });
    _ = settings.update(&state, .release);

    for ("--login") |ch| {
        try testing.expect(settings.update(&state, .{ .char = ch }));
    }
    try testing.expect(settings.update(&state, .{ .key = .{ .key = .enter } }));
    try testing.expectEqual(@as(usize, 1), state.activeConfig().shell.arguments.len);
    try testing.expectEqualStrings("--login", state.activeConfig().shell.arguments[0]);

    for ("none") |ch| {
        try testing.expect(settings.update(&state, .{ .char = ch }));
    }
    const add_id = Id.of("settings.list_add").item(arg_idx);
    _ = settings.update(&state, .{ .pointer = .{ .id = add_id } });
    _ = settings.update(&state, .{ .press = add_id });
    _ = settings.update(&state, .release);
    try testing.expectEqual(@as(usize, 2), state.activeConfig().shell.arguments.len);
    try testing.expectEqualStrings("none", state.activeConfig().shell.arguments[1]);

    // Move item 1 up -> ["none", "--login"].
    const up_id = Id.of("settings.list_up").item(@as(u32, arg_idx) * 256 + 1);
    _ = settings.update(&state, .{ .pointer = .{ .id = up_id } });
    _ = settings.update(&state, .{ .press = up_id });
    _ = settings.update(&state, .release);
    try testing.expectEqualStrings("none", state.activeConfig().shell.arguments[0]);
    try testing.expectEqualStrings("--login", state.activeConfig().shell.arguments[1]);

    // Remove item 0 -> ["--login"].
    const rm_id = Id.of("settings.list_rm").item(@as(u32, arg_idx) * 256 + 0);
    _ = settings.update(&state, .{ .pointer = .{ .id = rm_id } });
    _ = settings.update(&state, .{ .press = rm_id });
    _ = settings.update(&state, .release);
    try testing.expectEqual(@as(usize, 1), state.activeConfig().shell.arguments.len);
    try testing.expectEqualStrings("--login", state.activeConfig().shell.arguments[0]);
}

test "settings: Tab and Shift+Tab cycle focus across page controls" {
    const gpa = testing.allocator;
    const cfg = config_defaults.default;
    var state = try settings.init(.{
        .gpa = gpa,
        .io = testing.io,
        .config = &cfg,
        .state_dir = "",
        .wake_loop = struct {
            fn wake() void {}
        }.wake,
    });
    defer settings.deinit(&state);

    try testing.expectEqual(settings.Target.none, state.focused);
    try testing.expect(settings.update(&state, .{ .key = .{ .key = .tab } }));
    try testing.expectEqual(settings.Target.sidebar, state.focused);
    try testing.expect(state.frame.focused);

    try testing.expect(settings.update(&state, .{ .key = .{ .key = .tab } }));
    try testing.expect(state.focused == .key_select);
    try testing.expect(!state.frame.focused);
    const first_control = state.focused;

    try testing.expect(settings.update(&state, .{ .key = .{ .key = .tab, .mods = .{ .shift = true } } }));
    try testing.expectEqual(settings.Target.sidebar, state.focused);
    try testing.expect(state.frame.focused);

    try testing.expect(settings.update(&state, .{ .key = .{ .key = .tab } }));
    try testing.expectEqual(first_control, state.focused);

    // First control on Appearance is Color Theme select; Enter opens its popup.
    try testing.expect(settings.update(&state, .{ .key = .{ .key = .enter } }));
    try testing.expect(state.open_select != null);
    try testing.expect(settings.update(&state, .{ .key = .{ .key = .escape } }));
    try testing.expect(state.open_select == null);
}

test "settings: Tab scrolls viewport when moving to an offscreen control" {
    const gpa = testing.allocator;
    const cfg = config_defaults.default;
    const Helper = struct {
        var tree: kit.tree.Tree = undefined;
        fn getRect(_: *const anyopaque, id: Id) ?kit.tree.Rect {
            for (tree.nodes[0..tree.len]) |node| {
                if (node.box.id == id) return node.rect;
            }
            return null;
        }
    };
    var state = try settings.init(.{
        .gpa = gpa,
        .io = testing.io,
        .config = &cfg,
        .state_dir = "",
        .node_rect = .{ .ctx = &dummy, .getFn = Helper.getRect },
        .wake_loop = struct {
            fn wake() void {}
        }.wake,
    });
    defer settings.deinit(&state);

    // Narrow viewport height so bottom controls on Appearance are offscreen.
    _ = settings.update(&state, .{ .size = .{ .width = 1000, .height = 420 } });

    var nodes: [settings.node_max]kit.tree.Node = undefined;
    var lines: [settings.line_max]kit.text.Line = undefined;
    const theme = kit.Theme.dark;
    Helper.tree = .init(&nodes, &lines);
    try settings.view(&state, &Helper.tree, &theme);
    try kit.layout.layout(&Helper.tree, measurer, 1000, 420);

    // Tab several times until focus moves past the bottom of the 420px viewport.
    for (0..10) |_| {
        try testing.expect(settings.update(&state, .{ .key = .{ .key = .tab } }));
    }
    try testing.expect(state.scroll > 0);
}

test "settings: theme select popup windows long list and saves selection" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(dir_path);
    const cfg_path = try std.fs.path.join(gpa, &.{ dir_path, "config" });
    defer gpa.free(cfg_path);

    const cfg = config_defaults.default;
    const Helper = struct {
        var tree: kit.tree.Tree = undefined;
        fn getRect(_: *const anyopaque, id: Id) ?kit.tree.Rect {
            for (tree.nodes[0..tree.len]) |node| {
                if (node.box.id == id) return node.rect;
            }
            return null;
        }
    };

    var state = try settings.init(.{
        .gpa = gpa,
        .io = testing.io,
        .config = &cfg,
        .config_path = cfg_path,
        .state_dir = dir_path,
        .home_dir = dir_path,
        .node_rect = .{ .ctx = &dummy, .getFn = Helper.getRect },
        .wake_loop = struct {
            fn wake() void {}
        }.wake,
    });
    defer settings.deinit(&state);

    const theme_idx = keyIndex(.root, "theme");
    const theme_id = Id.of("settings.select").item(theme_idx);
    _ = settings.update(&state, .{ .pointer = .{ .id = theme_id } });
    _ = settings.update(&state, .{ .press = theme_id });
    try testing.expect(settings.update(&state, .release));
    try testing.expect(state.open_select != null);
    try testing.expectEqual(@as(usize, 0), state.open_select.?.top);

    // Move down past the 10-row visible window so `top` advances and the
    // laid-out popup stays comfortably inside the 600px window height.
    for (0..12) |_| {
        try testing.expect(settings.update(&state, .{ .key = .{ .key = .down } }));
    }
    try testing.expect(state.open_select.?.top > 0);

    var nodes: [settings.node_max]kit.tree.Node = undefined;
    var lines: [settings.line_max]kit.text.Line = undefined;
    const ui_theme = kit.Theme.dark;
    Helper.tree = .init(&nodes, &lines);
    try settings.view(&state, &Helper.tree, &ui_theme);
    try kit.layout.layout(&Helper.tree, measurer, 960, 600);

    const sel_rect = Helper.getRect(undefined, Id.of("settings.choice").item(12)).?;
    try testing.expect(sel_rect.y + sel_rect.h <= 600);

    try testing.expect(settings.update(&state, .{ .key = .{ .key = .enter } }));
    try testing.expect(state.open_select == null);
    try testing.expect(!std.meta.eql(state.activeConfig().theme, cfg.theme));
}

test "settings: colors page edits, validates, and resets slot overrides" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(dir_path);
    const cfg_path = try std.fs.path.join(gpa, &.{ dir_path, "config" });
    defer gpa.free(cfg_path);

    const cfg = config_defaults.default;
    var state = try settings.init(.{
        .gpa = gpa,
        .io = testing.io,
        .config = &cfg,
        .state_dir = dir_path,
        .config_path = cfg_path,
        .home_dir = dir_path,
        .wake_loop = struct {
            fn wake() void {}
        }.wake,
    });
    defer settings.deinit(&state);

    state.frame.current = @intFromEnum(settings.Page.appearance);

    const bg_idx = keyIndex(.colors, "background");
    const bg_input_id = Id.of("settings.input").item(bg_idx);
    const bg_reset_id = Id.of("settings.color_reset").item(bg_idx);

    // Valid hex override updates colors.background and resolvedTheme().
    _ = settings.update(&state, .{ .pointer = .{ .id = bg_input_id } });
    _ = settings.update(&state, .{ .press = bg_input_id });
    _ = settings.update(&state, .release);
    for ("#ff5500") |ch| {
        try testing.expect(settings.update(&state, .{ .char = ch }));
    }
    try testing.expect(settings.update(&state, .{ .key = .{ .key = .enter } }));
    try testing.expectEqual(@as(?u16, null), state.error_key);
    try testing.expectEqual(@as(?Rgb, .{ .r = 255, .g = 85, .b = 0 }), state.activeConfig().colors.background);
    try testing.expectEqual(Rgb{ .r = 255, .g = 85, .b = 0 }, state.activeConfig().resolvedTheme().background);
    try testing.expectEqualStrings("#ff5500", state.inputs[bg_idx].text());

    // Invalid color sets inline error_key and preserves previous config.
    try testing.expect(settings.update(&state, .{ .key = .{ .key = .a, .mods = .{ .ctrl = true } } }));
    for ("badcolor") |ch| {
        try testing.expect(settings.update(&state, .{ .char = ch }));
    }
    try testing.expect(settings.update(&state, .{ .key = .{ .key = .enter } }));
    try testing.expectEqual(@as(?u16, bg_idx), state.error_key);
    try testing.expect(state.error_msg.items.len > 0);
    try testing.expectEqual(@as(?Rgb, .{ .r = 255, .g = 85, .b = 0 }), state.activeConfig().colors.background);

    // Clicking Reset clears dirty invalid input, writes inherit, and restores null.
    _ = settings.update(&state, .{ .pointer = .{ .id = bg_reset_id } });
    _ = settings.update(&state, .{ .press = bg_reset_id });
    try testing.expect(settings.update(&state, .release));
    try testing.expectEqual(@as(?u16, null), state.error_key);
    try testing.expectEqual(@as(?Rgb, null), state.activeConfig().colors.background);
    try testing.expectEqual(cfg.theme.background, state.activeConfig().resolvedTheme().background);
    try testing.expectEqualStrings("", state.inputs[bg_idx].text());

    // Expand ANSI Palette collapsible, then set a named X11 color (red -> #ff0000).
    const toggle_id = Id.of("settings.ansi_toggle");
    const c1_idx = keyIndex(.colors, "color1");
    const c1_input_id = Id.of("settings.input").item(c1_idx);
    try testing.expect(!state.ansi_colors_open);
    _ = settings.update(&state, .{ .pointer = .{ .id = toggle_id } });
    _ = settings.update(&state, .{ .press = toggle_id });
    try testing.expect(settings.update(&state, .release));
    try testing.expect(state.ansi_colors_open);

    _ = settings.update(&state, .{ .pointer = .{ .id = c1_input_id } });
    _ = settings.update(&state, .{ .press = c1_input_id });
    _ = settings.update(&state, .release);
    for ("red") |ch| {
        try testing.expect(settings.update(&state, .{ .char = ch }));
    }
    try testing.expect(settings.update(&state, .{ .key = .{ .key = .enter } }));
    try testing.expectEqual(@as(?u16, null), state.error_key);
    try testing.expectEqual(@as(?Rgb, .{ .r = 255, .g = 0, .b = 0 }), state.activeConfig().colors.color1);
    try testing.expectEqual(Rgb{ .r = 255, .g = 0, .b = 0 }, state.activeConfig().resolvedTheme().ansi[1]);
    try testing.expectEqualStrings("#ff0000", state.inputs[c1_idx].text());
}

test "settings: ANSI palette collapsible hides color0..15 by default and updates Tab focus" {
    const gpa = testing.allocator;
    const cfg = config_defaults.default;
    var state = try settings.init(.{
        .gpa = gpa,
        .io = testing.io,
        .config = &cfg,
        .state_dir = "",
        .wake_loop = struct {
            fn wake() void {}
        }.wake,
    });
    defer settings.deinit(&state);

    state.frame.current = @intFromEnum(settings.Page.appearance);
    _ = settings.update(&state, .{ .size = .{ .width = 960, .height = 720 } });

    const toggle_id = Id.of("settings.ansi_toggle");
    const c0_idx = keyIndex(.colors, "color0");
    const c0_input_id = Id.of("settings.input").item(c0_idx);
    const font_file_idx = keyIndex(.font, "file");

    var nodes: [settings.node_max]kit.tree.Node = undefined;
    var lines: [settings.line_max]kit.text.Line = undefined;

    {
        var tree = kit.tree.Tree.init(&nodes, &lines);
        try settings.view(&state, &tree, &kit.Theme.dark);
        try testing.expect(tree.find(toggle_id) != null);
        try testing.expect(tree.find(c0_input_id) == null);
    }

    // Tab from accent lands on ansi_colors_toggle, then steps directly to Font when collapsed.
    const accent_idx = keyIndex(.colors, "accent");
    state.focused = .{ .key_input = accent_idx };
    try testing.expect(settings.update(&state, .{ .key = .{ .key = .tab } }));
    try testing.expectEqual(settings.Target.ansi_colors_toggle, state.focused);
    try testing.expect(settings.update(&state, .{ .key = .{ .key = .tab } }));
    try testing.expectEqual(settings.Target{ .key_input = font_file_idx }, state.focused);

    // Move back onto toggle and open via Enter; focus stays on the toggle and reveals color0.
    try testing.expect(settings.update(&state, .{ .key = .{ .key = .tab, .mods = .{ .shift = true } } }));
    try testing.expectEqual(settings.Target.ansi_colors_toggle, state.focused);
    try testing.expect(settings.update(&state, .{ .key = .{ .key = .enter } }));
    try testing.expect(state.ansi_colors_open);
    try testing.expectEqual(settings.Target.ansi_colors_toggle, state.focused);

    {
        var tree = kit.tree.Tree.init(&nodes, &lines);
        try settings.view(&state, &tree, &kit.Theme.dark);
        try testing.expect(tree.find(c0_input_id) != null);
    }

    // Next Tab steps into color0; Shift+Tab returns to toggle, and Space closes it again.
    try testing.expect(settings.update(&state, .{ .key = .{ .key = .tab } }));
    try testing.expectEqual(settings.Target{ .key_input = c0_idx }, state.focused);
    try testing.expect(settings.update(&state, .{ .key = .{ .key = .tab, .mods = .{ .shift = true } } }));
    try testing.expectEqual(settings.Target.ansi_colors_toggle, state.focused);
    try testing.expect(settings.update(&state, .{ .key = .{ .key = .space } }));
    try testing.expect(!state.ansi_colors_open);
}

test "settings: selection appearance keys edit and reset on Window & Shell" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(dir_path);
    const cfg_path = try std.fs.path.join(gpa, &.{ dir_path, "config" });
    defer gpa.free(cfg_path);

    const cfg = config_defaults.default;
    var state = try settings.init(.{
        .gpa = gpa,
        .io = testing.io,
        .config = &cfg,
        .state_dir = dir_path,
        .config_path = cfg_path,
        .home_dir = dir_path,
        .wake_loop = struct {
            fn wake() void {}
        }.wake,
    });
    defer settings.deinit(&state);

    state.frame.current = @intFromEnum(settings.Page.window_shell);

    const bc_idx = keyIndex(.selection, "border_color");
    const bc_input_id = Id.of("settings.input").item(bc_idx);
    const bc_reset_id = Id.of("settings.color_reset").item(bc_idx);
    try testing.expectEqualStrings("#666666", state.inputs[bc_idx].text());

    // Edit non-optional border_color, verify persisted value, then Reset back to default.
    _ = settings.update(&state, .{ .pointer = .{ .id = bc_input_id } });
    _ = settings.update(&state, .{ .press = bc_input_id });
    _ = settings.update(&state, .release);
    try testing.expect(settings.update(&state, .{ .key = .{ .key = .a, .mods = .{ .ctrl = true } } }));
    for ("#ff8800") |ch| {
        try testing.expect(settings.update(&state, .{ .char = ch }));
    }
    try testing.expect(settings.update(&state, .{ .key = .{ .key = .enter } }));
    try testing.expectEqual(@as(?u16, null), state.error_key);
    try testing.expectEqual(Rgb{ .r = 0xFF, .g = 0x88, .b = 0x00 }, state.activeConfig().selection.border_color);

    _ = settings.update(&state, .{ .pointer = .{ .id = bc_reset_id } });
    _ = settings.update(&state, .{ .press = bc_reset_id });
    try testing.expect(settings.update(&state, .release));
    try testing.expectEqual(cfg.selection.border_color, state.activeConfig().selection.border_color);
    try testing.expectEqualStrings("#666666", state.inputs[bc_idx].text());

    // Step border_width up (+1.0 from 1.5 -> 2.5) and select border_style = per_row.
    const bw_idx = keyIndex(.selection, "border_width");
    const inc_id = Id.of("settings.inc").item(bw_idx);
    _ = settings.update(&state, .{ .pointer = .{ .id = inc_id } });
    _ = settings.update(&state, .{ .press = inc_id });
    try testing.expect(settings.update(&state, .release));
    try testing.expectApproxEqAbs(@as(f32, 2.5), state.activeConfig().selection.border_width, 1e-6);

    const bs_idx = keyIndex(.selection, "border_style");
    const bs_select_id = Id.of("settings.select").item(bs_idx);
    _ = settings.update(&state, .{ .pointer = .{ .id = bs_select_id } });
    _ = settings.update(&state, .{ .press = bs_select_id });
    _ = settings.update(&state, .release);
    const per_row_id = Id.of("settings.choice").item(0);
    _ = settings.update(&state, .{ .pointer = .{ .id = per_row_id } });
    _ = settings.update(&state, .{ .press = per_row_id });
    try testing.expect(settings.update(&state, .release));
    const BorderStyle = @import("../config/selection.zig").BorderStyle;
    try testing.expectEqual(BorderStyle.unified, cfg.selection.border_style);
    try testing.expectEqual(BorderStyle.per_row, state.activeConfig().selection.border_style);
}
