const std = @import("std");
const testing = std.testing;

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

    for ([_][2]f32{ .{ 420, 500 }, .{ 960, 720 } }) |sz| {
        _ = settings.update(&state, .{ .size = .{ .width = sz[0], .height = sz[1] } });
        for (0..6) |page_idx| {
            state.frame.current = @intCast(page_idx);
            var tree = kit.tree.Tree.init(&nodes, &lines);
            try settings.view(&state, &tree, &kit.Theme.dark);
            try kit.layout.layout(&tree, measurer, sz[0], sz[1]);
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
