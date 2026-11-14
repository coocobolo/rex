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
