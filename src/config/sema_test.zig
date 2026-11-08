const std = @import("std");
const Ast = @import("Ast.zig");
const Sema = @import("Sema.zig");
const keys = @import("keys.zig");
const Config = @import("Config.zig");
const Binding = @import("../input.zig").Binding;
const test_config = @import("test_fixtures.zig").test_config;

const gpa = std.testing.allocator;

const base_keymap = [_]Binding{
    .{ .key = .c, .mods = .{ .ctrl = true, .shift = true }, .action = .copy_selection },
    .{ .key = .v, .mods = .{ .ctrl = true, .shift = true }, .action = .paste_clipboard },
};

/// The shared test config with a two-binding keymap to override.
fn testConfig() Config {
    var config = test_config;
    config.keymap = &base_keymap;
    return config;
}

const defaults = testConfig();

/// A parsed and applied source. Owns the tree, the result and the arena.
const Applied = struct {
    tree: Ast,
    result: Sema.Result,
    config: Config,
    arena: std.heap.ArenaAllocator,

    fn init(source: []const u8) !Applied {
        var applied: Applied = .{ .tree = undefined, .result = undefined, .config = testConfig(), .arena = .init(gpa) };
        errdefer applied.arena.deinit();
        applied.tree = try Ast.parse(gpa, source);
        errdefer applied.tree.deinit(gpa);
        applied.result = try Sema.apply(gpa, &applied.tree, &applied.config, .{
            .defaults = &defaults,
            .arena = applied.arena.allocator(),
            .dir = "/etc/rex",
            .home = "/home/user",
        });
        return applied;
    }

    fn deinit(applied: *Applied) void {
        applied.result.deinit(gpa);
        applied.tree.deinit(gpa);
        applied.arena.deinit();
    }

    /// Checks the errors: tag, 0-based line and the rendered message.
    fn expectErrors(applied: *const Applied, expected: []const struct { Sema.Error.Tag, usize, []const u8 }) !void {
        errdefer for (applied.result.errors) |err| {
            var buf: [256]u8 = undefined;
            var w: std.Io.Writer = .fixed(&buf);
            Sema.renderError(&applied.tree, err, &w) catch {};
            std.debug.print("got {t} line {d}: {s}\n", .{ err.tag, applied.tree.tokenLocation(err.token).line, w.buffered() });
        };
        try std.testing.expectEqual(expected.len, applied.result.errors.len);
        for (expected, applied.result.errors) |e, err| {
            try std.testing.expectEqual(e[0], err.tag);
            try std.testing.expectEqual(e[1], applied.tree.tokenLocation(err.token).line);
            var buf: [256]u8 = undefined;
            var w: std.Io.Writer = .fixed(&buf);
            try Sema.renderError(&applied.tree, err, &w);
            try std.testing.expectEqualStrings(e[2], w.buffered());
        }
    }
};

test "apply: sets keys and records the entry that set them" {
    var a = try Applied.init(
        \\theme = graphite
        \\[font]
        \\size = 16
        \\[toast]
        \\position = bottom_right
        \\duration = 3s
        \\[modal.blur]
        \\enabled = true
    );
    defer a.deinit();
    try a.expectErrors(&.{});
    try std.testing.expectEqual(16, a.config.font.size);
    try std.testing.expectEqual(.bottom_right, a.config.window.toast.position);
    try std.testing.expectEqual(3000, a.config.window.toast.duration_ms);
    try std.testing.expectEqual(true, a.config.window.modal.blur);
    const size = keys.lookup(.font, "size").?;
    try std.testing.expectEqualStrings("size", a.tree.tokenSlice(a.result.set_by[size].?));
    try std.testing.expectEqual(null, a.result.set_by[keys.lookup(.font, "min_size").?]);
}

test "apply: unknown and reserved sections skip their keys" {
    var a = try Applied.init(
        \\[fonts]
        \\size = 99
        \\[terminal]
        \\scrollback = 100
        \\[profile.work]
        \\size = 99
        \\[root]
        \\theme = graphite
        \\[font]
        \\size = 15
    );
    defer a.deinit();
    try a.expectErrors(&.{
        .{ .unknown_section, 0, "unknown section '[fonts]'" },
        .{ .reserved_section, 2, "section '[terminal]' is reserved for a future version" },
        .{ .reserved_section, 4, "section '[profile.work]' is reserved for a future version" },
        .{ .unknown_section, 6, "unknown section '[root]'" },
    });
    try std.testing.expectEqual(15, a.config.font.size);
}

test "apply: unknown keys suggest a close name in the same section" {
    var a = try Applied.init(
        \\[font]
        \\sise = 12
        \\[toast]
        \\min_width = 10
        \\[window]
        \\completely_unrelated = 1
        \\[root]
    );
    defer a.deinit();
    try a.expectErrors(&.{
        .{ .unknown_key, 1, "unknown key 'sise' in [font]; did you mean 'size'?" },
        .{ .unknown_key, 3, "unknown key 'min_width' in [toast]" },
        .{ .unknown_key, 5, "unknown key 'completely_unrelated' in [window]" },
        .{ .unknown_section, 6, "unknown section '[root]'" },
    });
    try std.testing.expectEqual(20, a.config.font.size);
}

test "apply: retired, duplicate and missing values" {
    var a = try Applied.init(
        \\[window]
        \\title = rex
        \\width = 800
        \\width = 900
        \\height =
    );
    defer a.deinit();
    try a.expectErrors(&.{
        .{ .retired_key, 1, "'title' was removed: not implemented yet" },
        .{ .duplicate_key, 3, "'width' is set more than once; the last value is used" },
        .{ .missing_value, 4, "window.height has no value, expected a whole number from 1 to 65535" },
    });
    try std.testing.expectEqual(900, a.config.window.size.width);
    try std.testing.expectEqual(3, a.tree.tokenLocation(a.result.set_by[keys.lookup(.window, "width").?].?).line);
}

test "apply: font sizes are bounded to 1 to 1000" {
    var a = try Applied.init(
        \\[font]
        \\size = 1001
        \\max_size = 1000
    );
    defer a.deinit();
    try a.expectErrors(&.{
        .{ .value_out_of_range, 1, "font.size = 1001 is out of range, expected a whole number from 1 to 1000" },
    });
    try std.testing.expectEqual(defaults.font.size, a.config.font.size);
    try std.testing.expectEqual(1000, a.config.font.max_size);
}

test "apply: invalid, out of range and not applicable values keep the old value" {
    var a = try Applied.init(
        \\[bell]
        \\volume = loud
        \\[scroll]
        \\step_lines = 0
        \\[toast]
        \\duration = 5
        \\[modal]
        \\border_style = "subtle"
    );
    defer a.deinit();
    try a.expectErrors(&.{
        .{ .invalid_value, 1, "invalid value 'loud' for bell.volume, expected a number from 0 to 1" },
        .{ .value_out_of_range, 3, "scroll.step_lines = 0 is out of range, expected a whole number of at least 1" },
        .{ .invalid_value, 5, "invalid value '5' for toast.duration, expected a duration of at least 1ms, like 500ms, 30s, 25m or 1h" },
        .{ .invalid_value, 7, "invalid value '\"subtle\"' for modal.border_style, expected one of: semantic, subtle, or inherit" },
    });
    try std.testing.expectEqual(defaults.window.bell.volume, a.config.window.bell.volume);
    try std.testing.expectEqual(defaults.scroll.lines, a.config.scroll.lines);
}

test "apply: font min_size above max_size reverts both" {
    var a = try Applied.init(
        \\[font]
        \\max_size = 40
        \\min_size = 50
        \\size = 30
    );
    defer a.deinit();
    try a.expectErrors(&.{
        .{ .conflicting_font_sizes, 2, "font.min_size is above font.max_size; both keep their previous values" },
    });
    try std.testing.expectEqual(6, a.config.font.min_size);
    try std.testing.expectEqual(96, a.config.font.max_size);
    try std.testing.expectEqual(30, a.config.font.size);
    try std.testing.expectEqual(null, a.result.set_by[keys.lookup(.font, "min_size").?]);
}

test "apply: retired wellbeing intervals point to their new keys" {
    var a = try Applied.init(
        \\[wellbeing]
        \\eyesight_interval = 10m
        \\posture_interval = 10m
        \\[wellbeing.eyesight]
        \\interval = 10m
    );
    defer a.deinit();
    try a.expectErrors(&.{
        .{ .retired_key, 1, "'eyesight_interval' was renamed to 'wellbeing.eyesight.interval'" },
        .{ .retired_key, 2, "'posture_interval' was renamed to 'wellbeing.routines.posture_interval'" },
    });
    try std.testing.expectEqual(10 * std.time.ms_per_min, a.config.wellbeing.eyesight.interval_ms);
}

test "apply: reminder sections set their options" {
    var a = try Applied.init(
        \\[wellbeing.movement]
        \\enabled = false
        \\interval = 1h
        \\duration = 90s
        \\lock_input = true
        \\animation = warm_glow
        \\[wellbeing.routines]
        \\hydration_interval = none
        \\posture_interval = 15m
    );
    defer a.deinit();
    try a.expectErrors(&.{});
    const wb = a.config.wellbeing;
    try std.testing.expect(!wb.movement.enabled);
    try std.testing.expectEqual(std.time.ms_per_hour, wb.movement.interval_ms);
    try std.testing.expectEqual(90 * std.time.ms_per_s, wb.movement.duration_ms);
    try std.testing.expect(wb.movement.lock_input);
    try std.testing.expectEqual(.warm_glow, wb.movement.animation);
    try std.testing.expectEqual(null, wb.routines.hydration_interval_ms);
    try std.testing.expectEqual(15 * std.time.ms_per_min, wb.routines.posture_interval_ms);
}

test "apply: winddown start equal to end reverts both" {
    var a = try Applied.init(
        \\[wellbeing.winddown]
        \\end = 22:00
        \\enabled = true
        \\start = 22:00
    );
    defer a.deinit();
    try a.expectErrors(&.{
        .{ .conflicting_winddown_times, 3, "wellbeing.winddown.start equals end, so wind-down would never start; both keep their previous values" },
    });
    const winddown = a.config.wellbeing.winddown;
    try std.testing.expectEqual(21 * 60, winddown.start.minutes());
    try std.testing.expectEqual(7 * 60, winddown.end.minutes());
    try std.testing.expect(winddown.enabled);
    try std.testing.expectEqual(null, a.result.set_by[keys.lookup(.@"wellbeing.winddown", "end").?]);
}

test "apply: winddown times that differ apply" {
    var a = try Applied.init(
        \\[wellbeing.winddown]
        \\start = 07:00
        \\end = 21:00
    );
    defer a.deinit();
    try a.expectErrors(&.{});
    try std.testing.expectEqual(7 * 60, a.config.wellbeing.winddown.start.minutes());
    try std.testing.expectEqual(21 * 60, a.config.wellbeing.winddown.end.minutes());
}

test "apply: font file resolves against the file's directory" {
    var a = try Applied.init(
        \\[font]
        \\file = fonts/mono.ttf
    );
    defer a.deinit();
    try a.expectErrors(&.{});
    try std.testing.expectEqualStrings("/etc/rex/fonts/mono.ttf", std.mem.span(a.config.font.faces.regular));
}

test "apply: keybinds override the previous keymap by chord" {
    var a = try Applied.init(
        \\[keybinds]
        \\ctrl+shift+c = paste_clipboard
        \\ctrl+shift+n = new_window
        \\ctrl+shift+n = quit
        \\ctrl+shift+x = no_such_action
        \\ctrl+shift+z = none
        \\ctrl+a c = copy_selection
        \\ctrl+shift+y = goto:2
    );
    defer a.deinit();
    try a.expectErrors(&.{
        .{ .duplicate_key, 3, "'ctrl+shift+n' is set more than once; the last value is used" },
        .{ .invalid_action, 4, "unknown action 'no_such_action'" },
        .{ .reserved_keybinding, 5, "key binding 'none' uses syntax reserved for a future version" },
        .{ .reserved_keybinding, 6, "key binding 'ctrl+a c' uses syntax reserved for a future version" },
        .{ .reserved_keybinding, 7, "key binding 'goto:2' uses syntax reserved for a future version" },
    });
    // ctrl+shift+v stays, ctrl+shift+c is rebound, ctrl+shift+n is added once (last wins).
    try std.testing.expectEqual(3, a.config.keymap.len);
    try std.testing.expectEqual(.paste_clipboard, a.config.keymap[0].action);
    try std.testing.expectEqual(.v, a.config.keymap[0].key);
    try std.testing.expectEqual(.paste_clipboard, a.config.keymap[1].action);
    try std.testing.expectEqual(.c, a.config.keymap[1].key);
    try std.testing.expectEqual(.quit, a.config.keymap[2].action);
}

test "apply: lines with syntax errors are not applied" {
    var a = try Applied.init(
        \\[font]
        \\size = "16
        \\min_size = 8
    );
    defer a.deinit();
    try std.testing.expectEqual(1, a.tree.errors.len);
    try a.expectErrors(&.{});
    try std.testing.expectEqual(20, a.config.font.size);
    try std.testing.expectEqual(8, a.config.font.min_size);
}

fn applyAndFree(allocator: std.mem.Allocator, source: []const u8) !void {
    var tree = try Ast.parse(allocator, source);
    defer tree.deinit(allocator);
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    var config = testConfig();
    var result = try Sema.apply(allocator, &tree, &config, .{ .defaults = &defaults, .arena = arena.allocator(), .dir = "/etc/rex", .home = "/home/user" });
    result.deinit(allocator);
}

test "apply: frees everything on allocation failure" {
    const source =
        \\[fonts]
        \\x = 1
        \\[font]
        \\sise = 1
        \\file = ~/f.ttf
        \\min_size = 50
        \\max_size = 40
        \\[keybinds]
        \\ctrl+shift+c = paste_clipboard
        \\ctrl+shift+c = quit
        \\ctrl+shift+q = none
    ;
    try std.testing.checkAllAllocationFailures(gpa, applyAndFree, .{source});
}

fn expectFallbacks(config: Config, expected: []const []const u8) !void {
    const faces = config.font.faces.fallbacks;
    try std.testing.expectEqual(expected.len, faces.len);
    for (expected, faces) |path, face| {
        try std.testing.expectEqualStrings(path, std.mem.span(face.path));
        try std.testing.expectEqual(null, face.weight_axis);
    }
}

test "apply: fallback lines build the list in order, a bad line is skipped" {
    var a = try Applied.init(
        \\[font]
        \\fallback = /usr/share/fonts/a.ttf
        \\fallback = fonts/b.ttc
        \\fallback = ""
        \\fallback = ~/c.ttf
    );
    defer a.deinit();
    // Repeating the key is the list syntax: no duplicate warning.
    try a.expectErrors(&.{
        .{ .invalid_value, 3, "invalid value '\"\"' for font.fallback, expected a path to a font file, one per line, or none" },
    });
    try expectFallbacks(a.config, &.{ "/usr/share/fonts/a.ttf", "/etc/rex/fonts/b.ttc", "/home/user/c.ttf" });
    try std.testing.expect(a.result.set_by[keys.lookup(.font, "fallback").?] != null);
}

test "apply: fallback none empties the list, later lines add to it" {
    var a = try Applied.init(
        \\[font]
        \\fallback = /a.ttf
        \\fallback = none
        \\fallback = /b.ttf
    );
    defer a.deinit();
    try a.expectErrors(&.{});
    try expectFallbacks(a.config, &.{"/b.ttf"});

    var b = try Applied.init(
        \\[font]
        \\fallback = /a.ttf
        \\fallback = none
    );
    defer b.deinit();
    try expectFallbacks(b.config, &.{});
}
