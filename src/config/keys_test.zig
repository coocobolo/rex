const std = @import("std");
const keys = @import("keys.zig");
const Config = @import("Config.zig");
const Theme = @import("../color/Theme.zig");
const Toast = @import("../ui/Toast.zig");

/// A complete Config for tests; the fields without defaults get minimal values.
fn testConfig() Config {
    return .{
        .blink = .{},
        .font = .{
            .faces = .{ .family = .{ .variable = .{ .upright = "/base/upright.ttf" } } },
            .size = 20,
            .max_size = 96,
            .min_size = 6,
        },
        .keymap = &.{},
        .termio = .{},
        .theme = Theme.graphite,
        .window = .{ .background = .{}, .scrollbar = .{}, .cursor = .{}, .selection = .{} },
        .selection = .{ .classifier = .{} },
        .environments = &.{},
    };
}

const defaults = testConfig();

fn applyText(config: *Config, section: keys.Section, name: []const u8, text: []const u8) keys.Error!void {
    return keys.apply(config, &defaults, keys.lookup(section, name).?, text);
}

test "FieldType: resolves nested struct and union paths" {
    try std.testing.expect(keys.FieldType(Config, "window.dim_alpha") == f32);
    try std.testing.expect(keys.FieldType(Config, "window.toast.position") == Toast.Position);
    try std.testing.expect(keys.FieldType(Config, "font.faces.family.variable.upright") == [*:0]const u8);
    try std.testing.expect(keys.FieldType(Config, "wellbeing.screen_time.daily_limit_ms") == ?u64);
}

test "fieldPtr: writes through structs and the active union field" {
    var config = testConfig();
    keys.fieldPtr(Config, "window.toast.margin_rows", &config).* = 7;
    try std.testing.expectEqual(7, config.window.toast.margin_rows);
    keys.fieldPtr(Config, "font.faces.family.variable.regular_weight", &config).* = 350;
    try std.testing.expectEqual(350, config.font.faces.family.variable.regular_weight);
    try std.testing.expectEqual(350, keys.fieldValue(Config, "font.faces.family.variable.regular_weight", &config));
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
    try applyText(&config, .window, "confirm_quit", "false");
    try std.testing.expectEqual(false, config.window.confirm_quit);
    for ([_][]const u8{ "yes", "on", "1", "True", "FALSE", "" }) |text| {
        try std.testing.expectError(error.InvalidValue, applyText(&config, .window, "confirm_quit", text));
    }
    try std.testing.expectEqual(false, config.window.confirm_quit);
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
    try applyText(&config, .toast, "margin_cols", "0");
    try std.testing.expectEqual(0, config.window.toast.margin_cols);
}

test "apply: floats are digits with an optional fraction" {
    var config = testConfig();
    try applyText(&config, .card, "corner_radius", "4");
    try std.testing.expectEqual(4, config.window.card.corner_radius);
    try applyText(&config, .card, "corner_radius", "4.5");
    try std.testing.expectEqual(4.5, config.window.card.corner_radius);
    for ([_][]const u8{ "4.", ".5", "1e3", "inf", "nan", "-1", "+1", "0x1p3", "4_0" }) |text| {
        try std.testing.expectError(error.InvalidValue, applyText(&config, .card, "corner_radius", text));
    }
    try std.testing.expectEqual(4.5, config.window.card.corner_radius);
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
    try applyText(&config, .toast, "position", "bottom_right");
    try std.testing.expectEqual(.bottom_right, config.window.toast.position);
    for ([_][]const u8{ "top-right", "Bottom_Right", "bottom right", "" }) |text| {
        try std.testing.expectError(error.InvalidValue, applyText(&config, .toast, "position", text));
    }
    try std.testing.expectEqual(.bottom_right, config.window.toast.position);
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

test "apply: an optional field's keyword sets null" {
    var config = testConfig();
    try applyText(&config, .@"wellbeing.screen_time", "daily_limit", "none");
    try std.testing.expectEqual(null, config.wellbeing.screen_time.daily_limit_ms);
    try applyText(&config, .@"wellbeing.screen_time", "daily_limit", "6h");
    try std.testing.expectEqual(6 * std.time.ms_per_hour, config.wellbeing.screen_time.daily_limit_ms);

    try applyText(&config, .modal, "border_style", "subtle");
    try std.testing.expectEqual(.subtle, config.window.modal.border_style);
    try applyText(&config, .modal, "border_style", "inherit");
    try std.testing.expectEqual(null, config.window.modal.border_style);
    // Each optional field has exactly one keyword.
    try std.testing.expectError(error.InvalidValue, applyText(&config, .modal, "border_style", "none"));
    try std.testing.expectError(error.InvalidValue, applyText(&config, .@"wellbeing.screen_time", "daily_limit", "inherit"));
}

test "apply: default resets a key to the built-in value" {
    var config = testConfig();
    try applyText(&config, .window, "dim_text_opacity", "0.1");
    try applyText(&config, .window, "dim_text_opacity", "default");
    try std.testing.expectEqual(defaults.window.dim_alpha, config.window.dim_alpha);
    try applyText(&config, .@"wellbeing.screen_time", "daily_limit", "none");
    try applyText(&config, .@"wellbeing.screen_time", "daily_limit", "default");
    try std.testing.expectEqual(defaults.wellbeing.screen_time.daily_limit_ms, config.wellbeing.screen_time.daily_limit_ms);
}

test "apply: font weights apply only to a variable family" {
    var config = testConfig();
    try applyText(&config, .font, "weight", "350");
    try std.testing.expectEqual(350, config.font.faces.family.variable.regular_weight);
    try std.testing.expectError(error.OutOfRange, applyText(&config, .font, "bold_weight", "0"));
    try std.testing.expectError(error.OutOfRange, applyText(&config, .font, "bold_weight", "1001"));
    try std.testing.expectError(error.InvalidValue, applyText(&config, .font, "bold_weight", "700.5"));

    var static = testConfig();
    static.font.faces.family = .{ .static = .{ .regular = "r", .bold = "b", .italic = "i", .bold_italic = "bi" } };
    try std.testing.expectError(error.NotApplicable, applyText(&static, .font, "weight", "350"));
    try std.testing.expectError(error.NotApplicable, applyText(&static, .font, "weight", "default"));
    try std.testing.expect(static.font.faces.family == .static);
}

test "apply: theme is a preset name" {
    var config = testConfig();
    try applyText(&config, .root, "theme", "graphite");
    try std.testing.expectError(error.InvalidValue, applyText(&config, .root, "theme", "Graphite"));
    try std.testing.expectError(error.InvalidValue, applyText(&config, .root, "theme", "dark"));
}

/// The value names users write for every enum key (C9/F12). Renaming a Zig
/// tag changes what users must write, so it fails here until it is decided.
const enum_names = [_]struct { []const u8, []const []const u8 }{
    .{ "window.platform", &.{ "auto", "wayland", "x11" } },
    .{ "card.border_shape", &.{ "rounded", "sharp" } },
    .{ "card.border_style", &.{ "semantic", "subtle" } },
    .{ "toast.position", &.{ "top_right", "top_center", "bottom_right" } },
    .{ "toast.border_style", &.{ "semantic", "subtle" } },
    .{ "banner.placement", &.{ "floating", "docked" } },
    .{ "banner.position", &.{ "top_center", "top_right", "top_left" } },
    .{ "banner.border_style", &.{ "semantic", "subtle" } },
    .{ "modal.default_focus", &.{ "confirm", "cancel" } },
    .{ "modal.border_style", &.{ "semantic", "subtle" } },
};

test "table: enum value names are pinned" {
    @setEvalBranchQuota(keys.eval_branch_quota);
    var seen: usize = 0;
    inline for (keys.table) |key| {
        const T = keys.FieldType(Config, key.field);
        const Value = switch (@typeInfo(T)) {
            .optional => |optional| optional.child,
            else => T,
        };
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

test "leafPaths: walks Config, treating unions and slices as leaves" {
    const paths = comptime keys.leafPaths(Config);
    var found_dim_alpha = false;
    var found_family = false;
    var found_keymap = false;
    for (paths) |path| {
        if (std.mem.eql(u8, path, "window.dim_alpha")) found_dim_alpha = true;
        if (std.mem.eql(u8, path, "font.faces.family")) found_family = true;
        if (std.mem.eql(u8, path, "keymap")) found_keymap = true;
        try std.testing.expect(!std.mem.startsWith(u8, path, "font.faces.family."));
    }
    try std.testing.expect(found_dim_alpha and found_family and found_keymap);
}

test "table: every row's field resolves and qualified names are unique" {
    @setEvalBranchQuota(keys.eval_branch_quota);
    inline for (keys.table, 0..) |key, i| {
        _ = keys.FieldType(Config, key.field);
        try std.testing.expectEqual(i, keys.lookup(key.section, key.name).?);
    }
}
