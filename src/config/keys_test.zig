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
}

test "lookup: exact section and name only" {
    try std.testing.expect(keys.lookup(.toast, "enabled") != null);
    try std.testing.expect(keys.lookup(.@"modal.blur", "enabled") != null);
    try std.testing.expect(keys.lookup(.toast, "enabled").? != keys.lookup(.@"modal.blur", "enabled").?);
    try std.testing.expectEqual(null, keys.lookup(.window, "dim-text-opacity"));
    try std.testing.expectEqual(null, keys.lookup(.window, "Dim_Text_Opacity"));
    try std.testing.expectEqual(null, keys.lookup(.root, "dim_text_opacity"));
    try std.testing.expectEqual(null, keys.lookup(.modal, "blur"));
    try std.testing.expectEqual(null, keys.lookup(.window, "a_name_longer_than_every_qualified_key_in_the_table"));
}

test "apply: parses by field type and leaves the field on error" {
    var config = testConfig();
    try keys.apply(&config, keys.lookup(.window, "dim_text_opacity").?, "0.25");
    try std.testing.expectEqual(0.25, config.window.dim_alpha);
    try keys.apply(&config, keys.lookup(.window, "confirm_quit").?, "false");
    try std.testing.expectEqual(false, config.window.confirm_quit);
    try keys.apply(&config, keys.lookup(.toast, "position").?, "bottom_right");
    try std.testing.expectEqual(.bottom_right, config.window.toast.position);
    try keys.apply(&config, keys.lookup(.@"wellbeing.screen_time", "daily_limit").?, "60000");
    try std.testing.expectEqual(60000, config.wellbeing.screen_time.daily_limit_ms);
    try keys.apply(&config, keys.lookup(.font, "weight").?, "350");
    try std.testing.expectEqual(350, config.font.faces.family.variable.regular_weight);
    try keys.apply(&config, keys.lookup(.bell, "volume").?, "0.5");
    try std.testing.expectEqual(0.5, config.window.bell.volume);

    try std.testing.expectError(error.InvalidValue, keys.apply(&config, keys.lookup(.window, "dim_text_opacity").?, "inf"));
    try std.testing.expectError(error.InvalidValue, keys.apply(&config, keys.lookup(.toast, "position").?, "top-right"));
    try std.testing.expectEqual(0.25, config.window.dim_alpha);
    try std.testing.expectEqual(.bottom_right, config.window.toast.position);
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
