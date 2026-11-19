const std = @import("std");
const keys = @import("keys.zig");
const Config = @import("Config.zig");
const overlay = @import("overlay.zig");
const test_config = @import("test_fixtures.zig").test_config;

fn testConfig() Config {
    return test_config;
}

const defaults = testConfig();

/// Non-path kinds never allocate, so the default context's arena fails every
/// allocation: a test that allocates there fails loudly.
const no_alloc_ctx: keys.Context = .{
    .defaults = &defaults,
    .arena = std.testing.failing_allocator,
    .dir = "/etc/rex",
    .home = "/home/user",
};

fn applyText(config: *Config, section: keys.Section, name: []const u8, text: []const u8) keys.ApplyError!void {
    return keys.apply(config, no_alloc_ctx, keys.lookup(section, name).?, text);
}

test "FieldType: resolves nested struct paths" {
    try std.testing.expect(keys.FieldType(Config, "window.dim_alpha") == f32);
    try std.testing.expect(keys.FieldType(Config, "window.alert_dialog.default_focus") == overlay.AlertDialog.DefaultFocus);
    try std.testing.expect(keys.FieldType(Config, "font.faces.regular") == [*:0]const u8);
    try std.testing.expect(keys.FieldType(Config, "wellbeing.screen_time.daily_limit_ms") == ?u64);
}

test "fieldPtr: writes through nested structs" {
    var config = testConfig();
    keys.fieldPtr(Config, "window.toast.duration_ms", &config).* = 7000;
    try std.testing.expectEqual(7000, config.window.toast.duration_ms);
    keys.fieldPtr(Config, "font.faces.regular_weight", &config).* = 350;
    try std.testing.expectEqual(350, config.font.faces.regular_weight);
    try std.testing.expectEqual(350, keys.fieldValue(Config, "font.faces.regular_weight", &config));
}

test "lookup: exact section and name only" {
    try std.testing.expect(keys.lookup(.toast, "enabled") != null);
    try std.testing.expect(keys.lookup(.@"modal.blur", "enabled") != null);
    try std.testing.expect(keys.lookup(.toast, "enabled").? != keys.lookup(.@"modal.blur", "enabled").?);
    try std.testing.expect(keys.lookup(.root, "theme") != null);
    try std.testing.expectEqual(null, keys.lookup(.window, "dim-text-opacity"));
    try std.testing.expectEqual(null, keys.lookup(.window, "Dim_Text_Opacity"));
    try std.testing.expectEqual(null, keys.lookup(.root, "dim_text_opacity"));
    try std.testing.expectEqual(null, keys.lookup(.modal, "blur"));
    try std.testing.expectEqual(null, keys.lookup(.window, "a_name_longer_than_every_qualified_key_in_the_table"));
}

test "apply: bool is true or false only" {
    var config = testConfig();
    try applyText(&config, .bell, "enabled", "false");
    try std.testing.expectEqual(false, config.window.bell.enabled);
    for ([_][]const u8{ "yes", "on", "1", "True", "FALSE", "" }) |text| {
        try std.testing.expectError(error.InvalidValue, applyText(&config, .bell, "enabled", text));
    }
    try std.testing.expectEqual(false, config.window.bell.enabled);
}

test "apply: integers are decimal digits within bounds and type" {
    var config = testConfig();
    try applyText(&config, .scroll, "step_lines", "5");
    try std.testing.expectEqual(5, config.scroll.lines);
    for ([_][]const u8{ "+5", "-5", "5_0", "0x5", "5.0", "", "five" }) |text| {
        try std.testing.expectError(error.InvalidValue, applyText(&config, .scroll, "step_lines", text));
    }
    try std.testing.expectError(error.OutOfRange, applyText(&config, .scroll, "step_lines", "0"));
    try std.testing.expectError(error.OutOfRange, applyText(&config, .@"modal.blur", "radius", "256"));
    try std.testing.expectError(error.OutOfRange, applyText(&config, .scroll, "step_lines", "99999999999999999999999"));
    try std.testing.expectEqual(5, config.scroll.lines);
    try applyText(&config, .@"modal.blur", "radius", "1");
    try std.testing.expectEqual(1, config.window.modal.blur_radius);
    try std.testing.expectError(error.OutOfRange, applyText(&config, .@"modal.blur", "radius", "0"));
}

test "apply: floats are digits with an optional fraction" {
    var config = testConfig();
    try applyText(&config, .bell, "volume", "0");
    try std.testing.expectEqual(0, config.window.bell.volume);
    try applyText(&config, .bell, "volume", "0.5");
    try std.testing.expectEqual(0.5, config.window.bell.volume);
    for ([_][]const u8{ "0.", ".5", "1e-1", "inf", "nan", "-0.5", "+0.5", "0x1p-1", "0_5" }) |text| {
        try std.testing.expectError(error.InvalidValue, applyText(&config, .bell, "volume", text));
    }
    try std.testing.expectEqual(0.5, config.window.bell.volume);
}

test "apply: fractions are 0 to 1" {
    var config = testConfig();
    try applyText(&config, .window, "dim_text_opacity", "0.25");
    try std.testing.expectEqual(0.25, config.window.dim_alpha);
    try applyText(&config, .bell, "volume", "1");
    try std.testing.expectEqual(1, config.window.bell.volume);
    try applyText(&config, .modal, "backdrop_opacity", "0");
    try std.testing.expectEqual(0, config.window.modal.backdrop_opacity);
    try std.testing.expectError(error.OutOfRange, applyText(&config, .bell, "volume", "1.5"));
    try std.testing.expectEqual(1, config.window.bell.volume);
}

test "apply: enums are tag names exactly" {
    var config = testConfig();
    try applyText(&config, .alert_dialog, "default_focus", "cancel");
    try std.testing.expectEqual(.cancel, config.window.alert_dialog.default_focus);
    for ([_][]const u8{ "Cancel", "CONFIRM", "other", "" }) |text| {
        try std.testing.expectError(error.InvalidValue, applyText(&config, .alert_dialog, "default_focus", text));
    }
    try std.testing.expectEqual(.cancel, config.window.alert_dialog.default_focus);
}

test "apply: durations need a unit and fit the field" {
    var config = testConfig();
    try applyText(&config, .toast, "duration", "5s");
    try std.testing.expectEqual(5000, config.window.toast.duration_ms);
    try applyText(&config, .toast, "duration", "250ms");
    try std.testing.expectEqual(250, config.window.toast.duration_ms);
    try applyText(&config, .@"wellbeing.focus", "task", "25m");
    try std.testing.expectEqual(25 * std.time.ms_per_min, config.wellbeing.focus.task_ms);
    try applyText(&config, .@"wellbeing.focus", "long_break", "1h");
    try std.testing.expectEqual(std.time.ms_per_hour, config.wellbeing.focus.long_break_ms);
    for ([_][]const u8{ "5", "5S", "s", "ms", "5 s", "1d", "-5s", "1.5h" }) |text| {
        try std.testing.expectError(error.InvalidValue, applyText(&config, .toast, "duration", text));
    }
    // toast.duration_ms is a u32: 1193h fits, 1194h does not.
    try applyText(&config, .toast, "duration", "1193h");
    try std.testing.expectError(error.OutOfRange, applyText(&config, .toast, "duration", "1194h"));
    try std.testing.expectError(error.OutOfRange, applyText(&config, .@"wellbeing.screen_time", "daily_limit", "9999999999999999999h"));
    try std.testing.expectError(error.OutOfRange, applyText(&config, .@"wellbeing.focus", "task", "0s"));
    try std.testing.expectError(error.OutOfRange, applyText(&config, .toast, "duration", "0ms"));
}

test "apply: time of day is HH:MM from 00:00 to 23:59" {
    var config = testConfig();
    const winddown = &config.wellbeing.winddown;
    try applyText(&config, .@"wellbeing.winddown", "start", "21:30");
    try std.testing.expectEqual(21, winddown.start.hour);
    try std.testing.expectEqual(30, winddown.start.minute);
    try applyText(&config, .@"wellbeing.winddown", "end", "00:00");
    try std.testing.expectEqual(0, winddown.end.minutes());
    try applyText(&config, .@"wellbeing.winddown", "end", "23:59");
    try std.testing.expectEqual(23 * 60 + 59, winddown.end.minutes());
    for ([_][]const u8{ "9:00", "09:0", "0900", "09.00", "09:00:00", "+9:00", "-1:00", "aa:bb", "09 :00", "" }) |text| {
        errdefer std.debug.print("accepted {s}\n", .{text});
        try std.testing.expectError(error.InvalidValue, applyText(&config, .@"wellbeing.winddown", "start", text));
    }
    for ([_][]const u8{ "24:00", "23:60", "99:99" }) |text| {
        errdefer std.debug.print("accepted {s}\n", .{text});
        try std.testing.expectError(error.OutOfRange, applyText(&config, .@"wellbeing.winddown", "start", text));
    }
    // Rejected values leave the field as it was.
    try std.testing.expectEqual(21 * 60 + 30, winddown.start.minutes());
    try applyText(&config, .@"wellbeing.winddown", "start", "default");
    try std.testing.expectEqual(defaults.wellbeing.winddown.start, winddown.start);
}

test "apply: sets are tag names separated by commas, or none" {
    var config = testConfig();
    const on_limit = &config.wellbeing.screen_time.on_limit;
    const Set = @TypeOf(on_limit.*);
    try applyText(&config, .@"wellbeing.screen_time", "on_limit", "animation, grayscale");
    try std.testing.expect(on_limit.eql(Set.initMany(&.{ .grayscale, .animation })));
    try applyText(&config, .@"wellbeing.screen_time", "on_limit", "lock_input,\tgrayscale , animation");
    try std.testing.expect(on_limit.eql(.full));
    try applyText(&config, .@"wellbeing.screen_time", "on_limit", "none");
    try std.testing.expect(on_limit.eql(.empty));
    for ([_][]const u8{ "", ",", "grayscale,", ",grayscale", "grayscale,,animation", "grayscale grayscale", "grayscale, grayscale", "Grayscale", "none, grayscale", "default, grayscale" }) |text| {
        errdefer std.debug.print("accepted '{s}'\n", .{text});
        try std.testing.expectError(error.InvalidValue, applyText(&config, .@"wellbeing.screen_time", "on_limit", text));
    }
    // Rejected values leave the field as it was.
    try std.testing.expect(on_limit.eql(.empty));
    try applyText(&config, .@"wellbeing.screen_time", "on_limit", "default");
    try std.testing.expect(on_limit.eql(defaults.wellbeing.screen_time.on_limit));
}

test "apply: word characters are printable ASCII" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx = no_alloc_ctx;
    ctx.arena = arena.allocator();
    var config = testConfig();
    const index = keys.lookup(.selection, "extra_word_characters").?;
    try keys.apply(&config, ctx, index, "\"-./~@#\"");
    try std.testing.expectEqualStrings("-./~@#", config.selection.classifier.extra_word_chars);
    try keys.apply(&config, ctx, index, "\"\"");
    try std.testing.expectEqualStrings("", config.selection.classifier.extra_word_chars);
    for ([_][]const u8{ "\"a b\"", "\"\\t\"", "\"é\"", "\"\\x7f\"" }) |text| {
        errdefer std.debug.print("accepted {s}\n", .{text});
        try std.testing.expectError(error.InvalidValue, keys.apply(&config, ctx, index, text));
    }
    try std.testing.expectEqualStrings("", config.selection.classifier.extra_word_chars);
}

test "apply: text is UTF-8 without control characters, auto is null" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx = no_alloc_ctx;
    ctx.arena = arena.allocator();
    var config = testConfig();
    const index = keys.lookup(.window, "title").?;
    try std.testing.expectEqual(null, config.window.title);

    try keys.apply(&config, ctx, index, "\"Rex \u{2014} work\"");
    try std.testing.expectEqualStrings("Rex \u{2014} work", config.window.title.?);
    try keys.apply(&config, ctx, index, "\"auto\""); // quoted: the literal text
    try std.testing.expectEqualStrings("auto", config.window.title.?);
    try keys.apply(&config, ctx, index, "auto");
    try std.testing.expectEqual(null, config.window.title);

    for ([_][]const u8{ "\"a\\tb\"", "\"\\x00\"", "\"\\x7f\"", "\"\\xff\"" }) |text| {
        errdefer std.debug.print("accepted {s}\n", .{text});
        try std.testing.expectError(error.InvalidValue, keys.apply(&config, ctx, index, text));
    }
    try std.testing.expectEqual(null, config.window.title);
}

test "apply: an optional field's keyword sets null" {
    var config = testConfig();
    try applyText(&config, .@"wellbeing.screen_time", "daily_limit", "6h");
    try std.testing.expectEqual(6 * std.time.ms_per_hour, config.wellbeing.screen_time.daily_limit_ms);
    try applyText(&config, .@"wellbeing.screen_time", "daily_limit", "none");
    try std.testing.expectEqual(null, config.wellbeing.screen_time.daily_limit_ms);

    try std.testing.expectError(error.InvalidValue, applyText(&config, .@"wellbeing.screen_time", "daily_limit", "inherit"));
}

test "apply: default resets a key to the built-in value" {
    var config = testConfig();
    try applyText(&config, .window, "dim_text_opacity", "0.1");
    try applyText(&config, .window, "dim_text_opacity", "default");
    try std.testing.expectEqual(defaults.window.dim_alpha, config.window.dim_alpha);
    try applyText(&config, .@"wellbeing.screen_time", "daily_limit", "6h");
    try applyText(&config, .@"wellbeing.screen_time", "daily_limit", "default");
    try std.testing.expectEqual(defaults.wellbeing.screen_time.daily_limit_ms, config.wellbeing.screen_time.daily_limit_ms);
}

test "apply: font weights are whole numbers from 1 to 1000" {
    var config = testConfig();
    try applyText(&config, .font, "weight", "350");
    try std.testing.expectEqual(350, config.font.faces.regular_weight);
    try applyText(&config, .font, "bold_weight", "1000");
    try std.testing.expectEqual(1000, config.font.faces.bold_weight);
    try std.testing.expectError(error.OutOfRange, applyText(&config, .font, "bold_weight", "0"));
    try std.testing.expectError(error.OutOfRange, applyText(&config, .font, "bold_weight", "1001"));
    try std.testing.expectError(error.InvalidValue, applyText(&config, .font, "bold_weight", "700.5"));
    try applyText(&config, .font, "weight", "default");
    try std.testing.expectEqual(defaults.font.faces.regular_weight, config.font.faces.regular_weight);
}

test "apply: theme is a preset name" {
    var config = testConfig();
    try applyText(&config, .root, "theme", "default");
    try applyText(&config, .root, "theme", "nord");
    try std.testing.expectEqual(@import("../color/presets.zig").nord, config.theme);
    try applyText(&config, .root, "theme", "catppuccin_mocha");
    try std.testing.expectEqual(@import("../color/presets.zig").catppuccin_mocha, config.theme);
    try applyText(&config, .root, "theme", "tokyo_night_day");
    try std.testing.expectEqual(@import("../color/presets.zig").tokyo_night_day, config.theme);
    try std.testing.expectError(error.InvalidValue, applyText(&config, .root, "theme", "Default"));
    try std.testing.expectError(error.InvalidValue, applyText(&config, .root, "theme", "Nord"));
    try std.testing.expectError(error.InvalidValue, applyText(&config, .root, "theme", "dark"));
}

test "apply: [colors] parses specs, inherit, and layers over resolvedTheme" {
    const Rgb = @import("../color/Rgb.zig");
    var config = testConfig();
    try applyText(&config, .root, "theme", "nord");
    try applyText(&config, .colors, "background", "#112233");
    try applyText(&config, .colors, "foreground", "\"#abcdef\"");
    try applyText(&config, .colors, "selection_background", "#f0a");
    try applyText(&config, .colors, "selection_foreground", "rgb:10/20/30");
    try applyText(&config, .colors, "accent", "red");
    try applyText(&config, .colors, "color0", "\"light blue\"");
    try applyText(&config, .colors, "color15", "#ffffff");

    try std.testing.expectEqual(Rgb{ .r = 0x11, .g = 0x22, .b = 0x33 }, config.colors.background.?);
    try std.testing.expectEqual(Rgb{ .r = 0xAB, .g = 0xCD, .b = 0xEF }, config.colors.foreground.?);
    try std.testing.expectEqual(Rgb{ .r = 0xFF, .g = 0x00, .b = 0xAA }, config.colors.selection_background.?);
    try std.testing.expectEqual(Rgb{ .r = 0x10, .g = 0x20, .b = 0x30 }, config.colors.selection_foreground.?);
    try std.testing.expectEqual(Rgb{ .r = 0xFF, .g = 0x00, .b = 0x00 }, config.colors.accent.?);
    try std.testing.expectEqual(Rgb{ .r = 0xAD, .g = 0xD8, .b = 0xE6 }, config.colors.color0.?);
    try std.testing.expectEqual(Rgb{ .r = 0xFF, .g = 0xFF, .b = 0xFF }, config.colors.color15.?);

    const resolved = config.resolvedTheme();
    try std.testing.expectEqual(config.colors.background.?, resolved.background);
    try std.testing.expectEqual(config.colors.color0.?, resolved.ansi[0]);
    try std.testing.expectEqual(@import("../color/presets.zig").nord.ansi[1], resolved.ansi[1]);

    // Clearing back to inherit restores the active preset color.
    try applyText(&config, .colors, "background", "inherit");
    try std.testing.expectEqual(@as(?Rgb, null), config.colors.background);
    try std.testing.expectEqual(@import("../color/presets.zig").nord.background, config.resolvedTheme().background);
    try applyText(&config, .colors, "color0", "default");
    try std.testing.expectEqual(@as(?Rgb, null), config.colors.color0);

    for ([_][]const u8{ "", "#12345", "#zzzzzz", "notacolor", "none" }) |bad| {
        try std.testing.expectError(error.InvalidValue, applyText(&config, .colors, "background", bad));
    }
}

test "apply: font file resolves its path" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx = no_alloc_ctx;
    ctx.arena = arena.allocator();
    const file = keys.lookup(.font, "file").?;

    var config = testConfig();
    try keys.apply(&config, ctx, file, "/usr/share/fonts/a.ttf");
    try std.testing.expectEqualStrings("/usr/share/fonts/a.ttf", std.mem.span(config.font.faces.regular));
    try keys.apply(&config, ctx, file, "fonts/b.ttf");
    try std.testing.expectEqualStrings("/etc/rex/fonts/b.ttf", std.mem.span(config.font.faces.regular));
    try keys.apply(&config, ctx, file, "~/fonts/c.ttf");
    try std.testing.expectEqualStrings("/home/user/fonts/c.ttf", std.mem.span(config.font.faces.regular));
    try keys.apply(&config, ctx, file, "\"/my fonts/d,wght.ttf\"");
    try std.testing.expectEqualStrings("/my fonts/d,wght.ttf", std.mem.span(config.font.faces.regular));

    var no_home = ctx;
    no_home.home = null;
    try std.testing.expectError(error.NoHome, keys.apply(&config, no_home, file, "~/x.ttf"));
    try std.testing.expectError(error.InvalidValue, keys.apply(&config, ctx, file, "\"\""));
    try std.testing.expectEqualStrings("/my fonts/d,wght.ttf", std.mem.span(config.font.faces.regular));
}

test "apply: style and emoji files resolve their paths, none clears them" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx = no_alloc_ctx;
    ctx.arena = arena.allocator();

    var config = testConfig();
    const styles = .{ .{ "bold_file", "bold" }, .{ "italic_file", "italic" }, .{ "bold_italic_file", "bold_italic" } };
    inline for (styles) |style| {
        const key = keys.lookup(.font, style[0]).?;
        try keys.apply(&config, ctx, key, "fonts/s.ttf");
        try std.testing.expectEqualStrings("/etc/rex/fonts/s.ttf", std.mem.span(@field(config.font.faces, style[1]).?));
        try keys.apply(&config, ctx, key, "none");
        try std.testing.expectEqual(null, @field(config.font.faces, style[1]));
    }

    const emoji = keys.lookup(.font, "emoji_file").?;
    try keys.apply(&config, ctx, emoji, "~/e.ttf");
    const face = config.font.faces.emoji.?;
    try std.testing.expectEqualStrings("/home/user/e.ttf", std.mem.span(face.path));
    try std.testing.expectEqual(null, face.weight_axis);
    try std.testing.expectEqual(0, face.index);
    try keys.apply(&config, ctx, emoji, "none");
    try std.testing.expectEqual(null, config.font.faces.emoji);
    try std.testing.expectError(error.InvalidValue, keys.apply(&config, ctx, emoji, "\"\""));
}

test "unquote: bare values are raw, quoted values take escapes" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("a\\b", try keys.unquote(a, "a\\b"));
    try std.testing.expectEqualStrings("a b", try keys.unquote(a, "\"a b\""));
    try std.testing.expectEqualStrings("it's", try keys.unquote(a, "'it\\'s'"));
    try std.testing.expectEqualStrings("a\\b\"c\nd\te", try keys.unquote(a, "\"a\\\\b\\\"c\\nd\\te\""));
    try std.testing.expectEqualStrings("\x1b[0m", try keys.unquote(a, "\"\\x1b[0m\""));
    try std.testing.expectEqualStrings("\u{1F319}", try keys.unquote(a, "\"\\u{1F319}\""));
    for ([_][]const u8{ "\"\\q\"", "\"\\x1\"", "\"\\xg0\"", "\"\\u{}\"", "\"\\u{110000}\"", "\"\\u{D800}\"", "\"\\u1F\"", "\"\\x+1\"" }) |raw| {
        try std.testing.expectError(error.InvalidValue, keys.unquote(a, raw));
    }
}

test "writeExpected: describes each kind" {
    var buf: [128]u8 = undefined;
    const cases = [_]struct { keys.Section, []const u8, []const u8 }{
        .{ .bell, "enabled", "true or false" },
        .{ .window, "on_close", "one of: ask, ask_if_running, close" },
        .{ .window, "platform", "one of: auto, wayland, x11" },
        .{ .window, "title", "text, like \"rex\", or auto" },
        .{ .window, "width", "a whole number from 1 to 65535" },
        .{ .bell, "volume", "a number from 0 to 1" },
        .{ .toast, "duration", "a duration of at least 1ms, like 500ms, 30s, 25m or 1h" },
        .{ .@"wellbeing.screen_time", "daily_limit", "a duration of at least 1ms, like 500ms, 30s, 25m or 1h, or none" },
        .{ .alert_dialog, "default_focus", "one of: confirm, cancel" },
        .{ .font, "weight", "a whole number from 1 to 1000" },
        .{ .@"wellbeing.winddown", "start", "a time of day from 00:00 to 23:59, like 21:30" },
        .{ .shell, "program", "an absolute path to a program, ~/ allowed, or auto" },
        .{ .shell, "working_directory", "a path to a directory, or inherit" },
        .{ .shell, "argument", "a program argument, one per line, or none" },
        .{ .selection, "extra_word_characters", "printable ASCII characters, like \"-./~@\", or \"\"" },
        .{ .@"wellbeing.screen_time", "on_limit", "none, or any of grayscale, lock_input, animation separated by commas" },
        .{ .root, "theme", "a built-in theme name, like \"nord\"" },
    };
    for (cases) |case| {
        var w: std.Io.Writer = .fixed(&buf);
        try keys.writeExpected(keys.lookup(case[0], case[1]).?, &w);
        try std.testing.expectEqualStrings(case[2], w.buffered());
    }
}

test "availableOn: platform is Linux only, the rest everywhere" {
    const platform = keys.lookup(.window, "platform").?;
    try std.testing.expect(keys.availableOn(platform, .linux));
    try std.testing.expect(!keys.availableOn(platform, .macos));
    const size = keys.lookup(.font, "size").?;
    try std.testing.expect(keys.availableOn(size, .linux) and keys.availableOn(size, .macos));
    try std.testing.expectEqual(.restart, keys.table[platform].reload);
    try std.testing.expectEqual(.live, keys.table[size].reload);
}

/// The value names users write for every enum and set key (C9/F12). Renaming
/// a Zig tag changes what users must write, so it fails here until it is
/// decided.
const enum_names = [_]struct { []const u8, []const []const u8 }{
    .{ "window.platform", &.{ "auto", "wayland", "x11" } },
    .{ "toast.position", &.{ "top_left", "top_center", "top_right", "bottom_left", "bottom_center", "bottom_right" } },
    .{ "toast.layout", &.{ "expanded", "stacked" } },
    .{ "banner.placement", &.{ "floating", "docked" } },
    .{ "banner.position", &.{ "top_left", "top_center", "top_right", "bottom_left", "bottom_center", "bottom_right" } },
    .{ "modal.position", &.{ "center", "top_center", "bottom_center" } },
    .{ "modal.on_outside_click", &.{ "close", "ignore" } },
    .{ "alert_dialog.default_focus", &.{ "confirm", "cancel" } },
    .{ "alert_dialog.icon", &.{ "warning", "info", "error", "none" } },
    .{ "window.on_inactive", &.{ "opacity", "dim", "blur" } },
    .{ "window.mouse_auto_hide", &.{ "never", "on_typing" } },
    .{ "window.on_close", &.{ "ask", "ask_if_running", "close" } },
    .{ "window.decorations", &.{ "full", "none" } },
    .{ "ui.motion", &.{ "full", "none" } },
    .{ "ui.color_scheme", &.{ "auto", "dark", "light" } },
    .{ "clipboard.osc52_write", &.{ "allow", "deny", "ask" } },
    .{ "clipboard.osc52_read", &.{ "allow", "deny", "ask" } },
    .{ "selection.border_style", &.{ "split", "unified", "underline", "left_bar" } },
    .{ "wellbeing.screen_time.on_limit", &.{ "grayscale", "lock_input", "animation" } },
    .{ "wellbeing.focus.timer", &.{ "countdown", "countup" } },
    .{ "wellbeing.focus.on_phase_end", &.{ "wait", "start_next" } },
    .{ "wellbeing.dashboard.timer_chart", &.{ "bar", "ring" } },
    .{ "wellbeing.dashboard.program_chart", &.{ "bar", "donut" } },
    .{ "wellbeing.focus.during_task", &.{"mute_bell"} },
    .{ "wellbeing.focus.on_break", &.{ "prompt", "lock_input", "animation" } },
    .{ "wellbeing.focus.on_alert", &.{"pause"} },
    .{ "wellbeing.winddown.during_window", &.{ "warm_colors", "mute_bell" } },
    .{ "wellbeing.eyesight.during_reminder", &.{"lock_input"} },
    .{ "wellbeing.movement.during_reminder", &.{"lock_input"} },
    .{ "wellbeing.eyesight.animation", &.{ "none", "pulse_dim", "grayscale_wave", "warm_glow" } },
    .{ "wellbeing.movement.animation", &.{ "none", "pulse_dim", "grayscale_wave", "warm_glow" } },
};

test "table: enum and set value names are pinned" {
    @setEvalBranchQuota(keys.eval_branch_quota);
    var seen: usize = 0;
    inline for (keys.table) |key| {
        const T = keys.FieldType(Config, key.field);
        const Field = switch (@typeInfo(T)) {
            .optional => |optional| optional.child,
            else => T,
        };
        const Value = if (key.kind == .set) Field.Key else Field;
        if (@typeInfo(Value) == .@"enum") {
            const name = @tagName(key.section) ++ "." ++ key.name;
            const expected = for (enum_names) |entry| {
                if (std.mem.eql(u8, entry[0], name)) break entry[1];
            } else {
                std.debug.print("enum key {s} has no pinned names\n", .{name});
                return error.TestUnexpectedResult;
            };
            const fields = @typeInfo(Value).@"enum".fields;
            try std.testing.expectEqual(expected.len, fields.len);
            inline for (fields, 0..) |field, i| try std.testing.expectEqualStrings(expected[i], field.name);
            seen += 1;
        }
    }
    try std.testing.expectEqual(enum_names.len, seen);
}

test "leafPaths: walks Config, treating optionals and slices as leaves" {
    const paths = comptime keys.leafPaths(Config);
    var found_dim_alpha = false;
    var found_emoji = false;
    var found_keymap = false;
    for (paths) |path| {
        if (std.mem.eql(u8, path, "window.dim_alpha")) found_dim_alpha = true;
        if (std.mem.eql(u8, path, "font.faces.emoji")) found_emoji = true;
        if (std.mem.eql(u8, path, "keymap")) found_keymap = true;
        try std.testing.expect(!std.mem.startsWith(u8, path, "font.faces.emoji."));
    }
    try std.testing.expect(found_dim_alpha and found_emoji and found_keymap);
}

test "table: every row's field resolves and qualified names are unique" {
    @setEvalBranchQuota(keys.eval_branch_quota);
    inline for (keys.table, 0..) |key, i| {
        _ = keys.FieldType(Config, key.field);
        try std.testing.expectEqual(i, keys.lookup(key.section, key.name).?);
    }
}

test "exposure: every Config field is a key, a section or listed as internal" {
    @setEvalBranchQuota(200_000);
    const leaves = comptime keys.leafPaths(Config);
    var uncovered: usize = 0;
    for (leaves) |leaf| {
        const covered = for (keys.table) |key| {
            if (keys.covers(key.field, leaf)) break true;
        } else for (keys.section_fields) |entry| {
            if (keys.covers(entry[1], leaf)) break true;
        } else for (keys.internal) |prefix| {
            if (keys.covers(prefix, leaf)) break true;
        } else false;
        if (!covered) {
            std.debug.print("not a key, a section field or internal: {s}\n", .{leaf});
            uncovered += 1;
        }
    }
    try std.testing.expectEqual(0, uncovered);
}

test "exposure: every internal entry names a Config field" {
    @setEvalBranchQuota(200_000);
    const leaves = comptime keys.leafPaths(Config);
    for (keys.internal) |prefix| {
        const exists = for (leaves) |leaf| {
            if (keys.covers(prefix, leaf)) break true;
        } else false;
        errdefer std.debug.print("stale internal entry: {s}\n", .{prefix});
        try std.testing.expect(exists);
    }
}

test "apply: [selection] appearance keys parse, validate bounds, and reset to defaults" {
    const Rgb = @import("../color/Rgb.zig");
    var config = testConfig();
    try applyText(&config, .selection, "opacity", "0.6");
    try applyText(&config, .selection, "foreground_opacity", "0.4");
    try applyText(&config, .selection, "border_color", "#abcdef");
    try applyText(&config, .selection, "border_opacity", "0.5");
    try applyText(&config, .selection, "border_width", "2.5");
    try applyText(&config, .selection, "border_style", "split");
    try applyText(&config, .selection, "radius", "4.0");
    try applyText(&config, .selection, "blur_radius", "12");

    try std.testing.expectApproxEqAbs(@as(f32, 0.6), config.selection.opacity, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.4), config.selection.foreground_opacity, 1e-6);
    try std.testing.expectEqual(Rgb{ .r = 0xAB, .g = 0xCD, .b = 0xEF }, config.selection.border_color);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), config.selection.border_opacity, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 2.5), config.selection.border_width, 1e-6);
    try std.testing.expectEqual(@import("selection.zig").BorderStyle.split, config.selection.border_style);
    try std.testing.expectApproxEqAbs(@as(f32, 4.0), config.selection.radius, 1e-6);
    try std.testing.expectEqual(@as(u8, 12), config.selection.blur_radius);

    try std.testing.expectError(error.OutOfRange, applyText(&config, .selection, "opacity", "1.5"));
    try std.testing.expectError(error.OutOfRange, applyText(&config, .selection, "border_width", "25"));
    try std.testing.expectError(error.OutOfRange, applyText(&config, .selection, "radius", "21"));
    try std.testing.expectError(error.OutOfRange, applyText(&config, .selection, "blur_radius", "256"));
    try std.testing.expectError(error.InvalidValue, applyText(&config, .selection, "border_style", "rounded"));
    try std.testing.expectError(error.InvalidValue, applyText(&config, .selection, "border_color", "inherit"));

    try applyText(&config, .selection, "border_color", "default");
    try std.testing.expectEqual(Config.Selection.default.border_color, config.selection.border_color);

    try applyText(&config, .selection, "border_style", "underline");
    try std.testing.expectEqual(@import("selection.zig").BorderStyle.underline, config.selection.border_style);
    try applyText(&config, .selection, "border_style", "left_bar");
    try std.testing.expectEqual(@import("selection.zig").BorderStyle.left_bar, config.selection.border_style);
}

test "apply: [scrollbar] keys parse, validate bounds, and reset to defaults" {
    const Rgb = @import("../color/Rgb.zig");
    var config = testConfig();
    try applyText(&config, .scrollbar, "width", "6.0");
    try applyText(&config, .scrollbar, "hover_width", "10.0");
    try applyText(&config, .scrollbar, "gap", "4.0");
    try applyText(&config, .scrollbar, "min_thumb_height", "24.0");
    try applyText(&config, .scrollbar, "radius", "5.0");
    try applyText(&config, .scrollbar, "auto_hide", "false");
    try applyText(&config, .scrollbar, "auto_hide_opacity", "0.4");
    try applyText(&config, .scrollbar, "track_color", "#112233");
    try applyText(&config, .scrollbar, "track_opacity", "0.2");
    try applyText(&config, .scrollbar, "thumb_color", "#445566");
    try applyText(&config, .scrollbar, "thumb_opacity", "0.7");
    try applyText(&config, .scrollbar, "thumb_hover_color", "#778899");
    try applyText(&config, .scrollbar, "thumb_hover_opacity", "0.9");

    try std.testing.expectApproxEqAbs(@as(f32, 6.0), config.scrollbar.width, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 10.0), config.scrollbar.hover_width, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 4.0), config.scrollbar.gap, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 24.0), config.scrollbar.min_thumb_height, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 5.0), config.scrollbar.radius, 1e-6);
    try std.testing.expect(!config.scrollbar.auto_hide);
    try std.testing.expectApproxEqAbs(@as(f32, 0.4), config.scrollbar.auto_hide_opacity, 1e-6);
    try std.testing.expectEqual(Rgb{ .r = 0x11, .g = 0x22, .b = 0x33 }, config.scrollbar.track_color);
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), config.scrollbar.track_opacity, 1e-6);
    try std.testing.expectEqual(Rgb{ .r = 0x44, .g = 0x55, .b = 0x66 }, config.scrollbar.thumb_color);
    try std.testing.expectApproxEqAbs(@as(f32, 0.7), config.scrollbar.thumb_opacity, 1e-6);
    try std.testing.expectEqual(Rgb{ .r = 0x77, .g = 0x88, .b = 0x99 }, config.scrollbar.thumb_hover_color);
    try std.testing.expectApproxEqAbs(@as(f32, 0.9), config.scrollbar.thumb_hover_opacity, 1e-6);

    try std.testing.expectError(error.OutOfRange, applyText(&config, .scrollbar, "width", "41"));
    try std.testing.expectError(error.OutOfRange, applyText(&config, .scrollbar, "hover_width", "45"));
    try std.testing.expectError(error.OutOfRange, applyText(&config, .scrollbar, "gap", "41"));
    try std.testing.expectError(error.OutOfRange, applyText(&config, .scrollbar, "min_thumb_height", "0"));
    try std.testing.expectError(error.OutOfRange, applyText(&config, .scrollbar, "radius", "21"));
    try std.testing.expectError(error.OutOfRange, applyText(&config, .scrollbar, "auto_hide_opacity", "1.2"));
    try std.testing.expectError(error.InvalidValue, applyText(&config, .scrollbar, "auto_hide", "maybe"));
    try std.testing.expectError(error.InvalidValue, applyText(&config, .scrollbar, "thumb_color", "auto"));

    try applyText(&config, .scrollbar, "thumb_color", "default");
    try std.testing.expectEqual(Config.Scrollbar.default.thumb_color, config.scrollbar.thumb_color);
}

test "apply: [toast], [banner], [modal], and [alert_dialog] layout keys" {
    var config = testConfig();
    try std.testing.expectEqual(.stacked, config.window.toast.layout);
    try applyText(&config, .toast, "position", "top_left");
    try applyText(&config, .toast, "layout", "expanded");
    try applyText(&config, .toast, "width", "400");
    try applyText(&config, .toast, "margin", "12");
    try applyText(&config, .toast, "padding", "10");
    try applyText(&config, .toast, "gap", "8");
    try std.testing.expectEqual(overlay.Position.top_left, config.window.toast.position);
    try std.testing.expectEqual(.expanded, config.window.toast.layout);
    try std.testing.expectEqual(@as(f32, 400), config.window.toast.width);
    try std.testing.expectEqual(@as(u8, 12), config.window.toast.margin);
    try std.testing.expectEqual(@as(u8, 10), config.window.toast.padding);
    try std.testing.expectEqual(@as(u8, 8), config.window.toast.gap);

    try applyText(&config, .banner, "placement", "docked");
    try applyText(&config, .banner, "position", "bottom_center");
    try applyText(&config, .banner, "max_width", "720");
    try applyText(&config, .banner, "margin", "20");
    try applyText(&config, .banner, "padding", "18");
    try std.testing.expectEqual(overlay.Banner.Placement.docked, config.window.banner.placement);
    try std.testing.expectEqual(overlay.Position.bottom_center, config.window.banner.position);
    try std.testing.expectEqual(@as(f32, 720), config.window.banner.max_width);
    try std.testing.expectEqual(@as(u8, 20), config.window.banner.margin);
    try std.testing.expectEqual(@as(u8, 18), config.window.banner.padding);

    try applyText(&config, .modal, "position", "top_center");
    try applyText(&config, .modal, "margin", "24");
    try applyText(&config, .modal, "padding", "32");
    try applyText(&config, .modal, "gap", "20");
    try std.testing.expectEqual(overlay.Modal.Position.top_center, config.window.modal.position);
    try std.testing.expectEqual(@as(u8, 24), config.window.modal.margin);
    try std.testing.expectEqual(@as(u8, 32), config.window.modal.padding);
    try std.testing.expectEqual(@as(u8, 20), config.window.modal.gap);

    try applyText(&config, .alert_dialog, "width", "500");
    try applyText(&config, .alert_dialog, "default_focus", "cancel");
    try applyText(&config, .alert_dialog, "icon", "error");
    try std.testing.expectEqual(@as(f32, 500), config.window.alert_dialog.width);
    try std.testing.expectEqual(overlay.AlertDialog.DefaultFocus.cancel, config.window.alert_dialog.default_focus);
    try std.testing.expectEqual(overlay.AlertDialog.Icon.@"error", config.window.alert_dialog.icon);

    try std.testing.expectError(error.OutOfRange, applyText(&config, .toast, "width", "100"));
    try std.testing.expectError(error.OutOfRange, applyText(&config, .banner, "max_width", "100"));
    try std.testing.expectError(error.OutOfRange, applyText(&config, .modal, "padding", "65"));
    try std.testing.expectError(error.OutOfRange, applyText(&config, .alert_dialog, "width", "1201"));
    try std.testing.expectError(error.InvalidValue, applyText(&config, .modal, "position", "top_left"));
}

test "apply: [window] inactive effects and mouse auto-hide keys" {
    const window_types = @import("window.zig");
    var config = testConfig();
    try applyText(&config, .window, "background_opacity", "0.95");
    try applyText(&config, .window, "on_inactive", "opacity, dim, blur");
    try applyText(&config, .window, "inactive_background_opacity", "0.75");
    try applyText(&config, .window, "inactive_dim_opacity", "0.4");
    try applyText(&config, .window, "inactive_blur_radius", "16");
    try applyText(&config, .window, "mouse_auto_hide", "never");
    try applyText(&config, .window, "mouse_idle_timeout", "3s");

    try std.testing.expect(config.window.on_inactive.eql(.full));
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), config.window.inactive_background_alpha, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.4), config.window.inactive_dim_alpha, 1e-6);
    try std.testing.expectEqual(@as(u8, 16), config.window.inactive_blur_radius);
    try std.testing.expectEqual(window_types.MouseAutoHide.never, config.window.mouse_auto_hide);
    try std.testing.expectEqual(@as(?u64, 3000), config.window.mouse_idle_timeout_ms);

    try std.testing.expectApproxEqAbs(@as(f32, 0.95), config.window.effectiveBackgroundAlpha(true), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), config.window.effectiveBackgroundAlpha(false), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), config.window.effectiveInactiveDimAlpha(true), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.4), config.window.effectiveInactiveDimAlpha(false), 1e-6);
    try std.testing.expect(!config.window.effectiveInactiveBlur(true));
    try std.testing.expect(config.window.effectiveInactiveBlur(false));

    try applyText(&config, .window, "on_inactive", "none");
    try std.testing.expect(config.window.on_inactive.eql(.empty));
    try std.testing.expectApproxEqAbs(@as(f32, 0.95), config.window.effectiveBackgroundAlpha(false), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), config.window.effectiveInactiveDimAlpha(false), 1e-6);
    try std.testing.expect(!config.window.effectiveInactiveBlur(false));

    try applyText(&config, .window, "mouse_idle_timeout", "none");
    try std.testing.expectEqual(@as(?u64, null), config.window.mouse_idle_timeout_ms);
    try applyText(&config, .window, "mouse_auto_hide", "default");
    try std.testing.expectEqual(window_types.MouseAutoHide.on_typing, config.window.mouse_auto_hide);

    try std.testing.expectError(error.OutOfRange, applyText(&config, .window, "inactive_background_opacity", "1.1"));
    try std.testing.expectError(error.OutOfRange, applyText(&config, .window, "inactive_dim_opacity", "1.5"));
    try std.testing.expectError(error.InvalidValue, applyText(&config, .window, "inactive_dim_opacity", "-0.1"));
    try std.testing.expectError(error.OutOfRange, applyText(&config, .window, "inactive_blur_radius", "0"));
    try std.testing.expectError(error.OutOfRange, applyText(&config, .window, "inactive_blur_radius", "65"));
    try std.testing.expectError(error.OutOfRange, applyText(&config, .window, "mouse_idle_timeout", "0ms"));
    try std.testing.expectError(error.InvalidValue, applyText(&config, .window, "mouse_auto_hide", "always"));
}

test "apply: [cursor] keys and [selection] double_click_interval" {
    var config = testConfig();
    try applyText(&config, .cursor, "opacity", "0.8");
    try applyText(&config, .cursor, "radius", "3.5");
    try applyText(&config, .cursor, "underline_thickness", "0.25");
    try applyText(&config, .cursor, "underline_position", "0.95");
    try applyText(&config, .cursor, "beam_thickness", "0.2");
    try applyText(&config, .cursor, "hollow_border_width", "2.0");
    try applyText(&config, .cursor, "blink_interval", "350ms");
    try applyText(&config, .selection, "double_click_interval", "750ms");

    try std.testing.expectApproxEqAbs(@as(f32, 0.8), config.cursor.opacity, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 3.5), config.cursor.radius, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), config.cursor.underline_thickness, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.95), config.cursor.underline_position, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), config.cursor.beam_thickness, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), config.cursor.hollow_border_width, 1e-6);
    try std.testing.expectEqual(@as(u32, 350), config.cursor.blink_interval_ms);
    try std.testing.expectEqual(@as(u32, 750), config.selection.mouse_double_click_interval_ms);

    try std.testing.expectError(error.OutOfRange, applyText(&config, .cursor, "opacity", "1.1"));
    try std.testing.expectError(error.OutOfRange, applyText(&config, .cursor, "radius", "33"));
    try std.testing.expectError(error.OutOfRange, applyText(&config, .cursor, "underline_thickness", "1.5"));
    try std.testing.expectError(error.OutOfRange, applyText(&config, .cursor, "underline_position", "1.2"));
    try std.testing.expectError(error.OutOfRange, applyText(&config, .cursor, "beam_thickness", "2.0"));
    try std.testing.expectError(error.OutOfRange, applyText(&config, .cursor, "hollow_border_width", "17"));
    try std.testing.expectError(error.OutOfRange, applyText(&config, .cursor, "blink_interval", "49ms"));
    try std.testing.expectError(error.OutOfRange, applyText(&config, .cursor, "blink_interval", "6s"));
    try std.testing.expectError(error.OutOfRange, applyText(&config, .selection, "double_click_interval", "50ms"));
    try std.testing.expectError(error.OutOfRange, applyText(&config, .selection, "double_click_interval", "3s"));

    try applyText(&config, .cursor, "blink_interval", "default");
    try applyText(&config, .selection, "double_click_interval", "default");
    try std.testing.expectEqual(@as(u32, 500), config.cursor.blink_interval_ms);
    try std.testing.expectEqual(@as(u32, 500), config.selection.mouse_double_click_interval_ms);
}

test "apply: [window] decorations and padding keys" {
    var config = testConfig();
    try std.testing.expectEqual(Config.Window.Decorations.full, config.window.decorations);
    try std.testing.expectEqual(@as(u16, 0), config.window.padding_x);
    try std.testing.expectEqual(@as(u16, 0), config.window.padding_y);

    try applyText(&config, .window, "decorations", "none");
    try applyText(&config, .window, "padding_x", "12");
    try applyText(&config, .window, "padding_y", "8");
    try std.testing.expectEqual(Config.Window.Decorations.none, config.window.decorations);
    try std.testing.expectEqual(@as(u16, 12), config.window.padding_x);
    try std.testing.expectEqual(@as(u16, 8), config.window.padding_y);

    try std.testing.expectError(error.InvalidValue, applyText(&config, .window, "decorations", "transparent"));
    try std.testing.expectError(error.OutOfRange, applyText(&config, .window, "padding_x", "129"));
    try std.testing.expectError(error.OutOfRange, applyText(&config, .window, "padding_y", "200"));

    try applyText(&config, .window, "decorations", "default");
    try applyText(&config, .window, "padding_x", "default");
    try applyText(&config, .window, "padding_y", "default");
    try std.testing.expectEqual(Config.Window.Decorations.full, config.window.decorations);
    try std.testing.expectEqual(@as(u16, 0), config.window.padding_x);
    try std.testing.expectEqual(@as(u16, 0), config.window.padding_y);
}
