//! Comprehensive tests for the configuration tokenizer, parser, and keybinding engine.

const std = @import("std");
const testing = std.testing;

const types = @import("types.zig");
const FileConfig = types.FileConfig;
const Diagnostics = types.Diagnostics;
const lexer_mod = @import("lexer.zig");
const Lexer = lexer_mod.Lexer;
const parser_mod = @import("parser.zig");
const Parser = parser_mod.Parser;
const keymap_parser = @import("keymap_parser.zig");
const Theme = @import("../color/Theme.zig");
const Banner = @import("../ui/Banner.zig");
const Toast = @import("../ui/Toast.zig");

test "config: boolean parsing" {
    try testing.expectEqual(@as(?bool, true), parser_mod.parseBool("true"));
    try testing.expectEqual(@as(?bool, true), parser_mod.parseBool("yes"));
    try testing.expectEqual(@as(?bool, true), parser_mod.parseBool("on"));
    try testing.expectEqual(@as(?bool, true), parser_mod.parseBool("1"));

    try testing.expectEqual(@as(?bool, false), parser_mod.parseBool("false"));
    try testing.expectEqual(@as(?bool, false), parser_mod.parseBool("no"));
    try testing.expectEqual(@as(?bool, false), parser_mod.parseBool("off"));
    try testing.expectEqual(@as(?bool, false), parser_mod.parseBool("0"));

    try testing.expectEqual(@as(?bool, null), parser_mod.parseBool("invalid"));
}

test "config: duration parsing with units" {
    // Milliseconds
    try testing.expectEqual(@as(?u32, 500), parser_mod.parseDurationMs("500ms"));
    try testing.expectEqual(@as(?u32, 5000), parser_mod.parseDurationMs("5s"));
    try testing.expectEqual(@as(?u32, 25 * 60 * 1000), parser_mod.parseDurationMs("25m"));
    try testing.expectEqual(@as(?u32, 8 * 3600 * 1000), parser_mod.parseDurationMs("8h"));

    // Minutes
    try testing.expectEqual(@as(?u32, 480), parser_mod.parseDurationMinutes("8h"));
    try testing.expectEqual(@as(?u32, 25), parser_mod.parseDurationMinutes("25m"));

    // Seconds
    try testing.expectEqual(@as(?u32, 60), parser_mod.parseDurationSeconds("60s"));
    try testing.expectEqual(@as(?u32, 180), parser_mod.parseDurationSeconds("3m"));
}

test "config: keybinding string parsing" {
    const bind1 = keymap_parser.parseBinding("ctrl+shift+w", "wellbeing_dashboard");
    try testing.expect(bind1 != null);
    try testing.expectEqual(.w, bind1.?.key);
    try testing.expect(bind1.?.mods.ctrl);
    try testing.expect(bind1.?.mods.shift);
    try testing.expect(!bind1.?.mods.alt);
    try testing.expectEqual(.wellbeing_dashboard, bind1.?.action);

    const bind2 = keymap_parser.parseBinding("ctrl+0", "reset_font_size");
    try testing.expect(bind2 != null);
    try testing.expectEqual(.num_0, bind2.?.key);
    try testing.expect(bind2.?.mods.ctrl);
    try testing.expectEqual(.reset_font_size, bind2.?.action);

    const bind3 = keymap_parser.parseBinding("ctrl+shift+r", "reload_config");
    try testing.expect(bind3 != null);
    try testing.expectEqual(.r, bind3.?.key);
    try testing.expect(bind3.?.mods.ctrl);
    try testing.expect(bind3.?.mods.shift);
    try testing.expectEqual(.reload_config, bind3.?.action);
}

test "config: lexer tokenization of sections, assignments, and comments" {
    const sample =
        \\# Global config
        \\theme = graphite
        \\font-size = 14.5 # size in points
        \\
        \\[card]
        \\corner-radius = 10.0
        \\border-shape = sharp
        \\
        \\[keybinds]
        \\ctrl+shift+w = wellbeing_dashboard
        \\ctrl+shift+r = reload_config
    ;

    var lexer = Lexer.init(sample);

    const t1 = lexer.next();
    try testing.expectEqual(lexer_mod.TokenKind.key_value, t1.kind);
    try testing.expectEqualStrings("theme", t1.key);
    try testing.expectEqualStrings("graphite", t1.value);

    const t2 = lexer.next();
    try testing.expectEqual(lexer_mod.TokenKind.key_value, t2.kind);
    try testing.expectEqualStrings("font-size", t2.key);
    try testing.expectEqualStrings("14.5", t2.value);

    const t3 = lexer.next();
    try testing.expectEqual(lexer_mod.TokenKind.section, t3.kind);
    try testing.expectEqualStrings("card", t3.key);

    const t4 = lexer.next();
    try testing.expectEqual(lexer_mod.TokenKind.key_value, t4.kind);
    try testing.expectEqualStrings("corner-radius", t4.key);
    try testing.expectEqualStrings("10.0", t4.value);

    const t5 = lexer.next();
    try testing.expectEqual(lexer_mod.TokenKind.key_value, t5.kind);
    try testing.expectEqualStrings("border-shape", t5.key);
    try testing.expectEqualStrings("sharp", t5.value);

    const t6 = lexer.next();
    try testing.expectEqual(lexer_mod.TokenKind.section, t6.kind);
    try testing.expectEqualStrings("keybinds", t6.key);

    const t7 = lexer.next();
    try testing.expectEqual(lexer_mod.TokenKind.key_value, t7.kind);
    try testing.expectEqualStrings("ctrl+shift+w", t7.key);
    try testing.expectEqualStrings("wellbeing_dashboard", t7.value);

    const t8 = lexer.next();
    try testing.expectEqual(lexer_mod.TokenKind.key_value, t8.kind);
    try testing.expectEqualStrings("ctrl+shift+r", t8.key);
    try testing.expectEqualStrings("reload_config", t8.value);

    const t9 = lexer.next();
    try testing.expectEqual(lexer_mod.TokenKind.eof, t9.kind);
}

test "config: full declarative parser execution" {
    const config_text =
        \\# Rex test configuration
        \\theme = graphite
        \\font-family = "GoogleSansCode.ttf"
        \\font-size = 15.0
        \\
        \\[window]
        \\background-alpha = 0.92
        \\confirm-quit = true
        \\dim-alpha = 0.4
        \\
        \\[card]
        \\corner-radius = 12.0
        \\border-width = 1.5
        \\border-shape = rounded
        \\
        \\[toast]
        \\enabled = true
        \\position = top-right
        \\border-style = semantic
        \\duration = 4s
        \\
        \\[modal]
        \\width = 50
        \\dim-alpha = 200
        \\close-on-outside-click = false
        \\default-focus = cancel
        \\
        \\[wellbeing]
        \\enabled = true
        \\daily-limit = 8h
        \\focus-time = 30m
        \\short-break = 5m
        \\long-break = 20m
        \\tasks-before-long-break = 3
        \\lock-input-on-break = true
        \\
        \\[keybinds]
        \\ctrl+shift+w = wellbeing_dashboard
        \\ctrl+shift+r = reload_config
    ;

    var parser = Parser.init(config_text);
    var cfg = FileConfig{};
    var diags = Diagnostics{};

    parser.parseInto(&cfg, &diags);

    try testing.expect(!diags.hasErrors());

    // Verify root & font
    try testing.expect(cfg.theme != null);
    try testing.expectEqual(Theme.graphite.background, cfg.theme.?.background);
    try testing.expectEqualStrings("GoogleSansCode.ttf", cfg.getFontFamily().?);
    try testing.expectEqual(@as(f32, 15.0), cfg.font_size.?);

    // Verify window
    try testing.expectEqual(@as(f32, 0.92), cfg.window_background_alpha.?);
    try testing.expectEqual(true, cfg.window_confirm_quit.?);
    try testing.expectEqual(@as(f32, 0.4), cfg.window_dim_alpha.?);

    // Verify card
    try testing.expectEqual(@as(f32, 12.0), cfg.card_corner_radius.?);
    try testing.expectEqual(@as(f32, 1.5), cfg.card_border_width.?);
    try testing.expectEqual(.rounded, cfg.card_border_shape.?);

    // Verify toast
    try testing.expectEqual(true, cfg.toast_enabled.?);
    try testing.expectEqual(.top_right, cfg.toast_position.?);
    try testing.expectEqual(.semantic, cfg.toast_border_style.?);
    try testing.expectEqual(@as(u32, 4000), cfg.toast_duration_ms.?);

    // Verify modal
    try testing.expectEqual(@as(u16, 50), cfg.modal_width.?);
    try testing.expectEqual(@as(u8, 200), cfg.modal_dim_alpha.?);
    try testing.expectEqual(false, cfg.modal_close_on_outside_click.?);
    try testing.expectEqual(.cancel, cfg.modal_default_focus.?);

    // Verify wellbeing
    try testing.expectEqual(true, cfg.wellbeing_enabled.?);
    try testing.expectEqual(@as(u32, 480), cfg.wellbeing_daily_limit_minutes.?);
    try testing.expectEqual(@as(u32, 30 * 60 * 1000), cfg.wellbeing_focus_task_ms.?);
    try testing.expectEqual(@as(u32, 5 * 60 * 1000), cfg.wellbeing_focus_short_break_ms.?);
    try testing.expectEqual(@as(u32, 20 * 60 * 1000), cfg.wellbeing_focus_long_break_ms.?);
    try testing.expectEqual(@as(u32, 3), cfg.wellbeing_tasks_before_long_break.?);
    try testing.expectEqual(true, cfg.wellbeing_lock_input_on_break.?);

    // Verify keybinds
    try testing.expect(cfg.keybindings_specified);
    try testing.expectEqual(@as(usize, 2), cfg.keybindings_count);
    try testing.expectEqual(.w, cfg.keybindings[0].key);
    try testing.expectEqual(.wellbeing_dashboard, cfg.keybindings[0].action);
    try testing.expectEqual(.r, cfg.keybindings[1].key);
    try testing.expectEqual(.reload_config, cfg.keybindings[1].action);
}

test "config: merge and applyFileConfig overrides" {
    const merge_mod = @import("merge.zig");
    const App = @import("../App.zig");

    const cfg_text =
        \\[card]
        \\corner-radius = 16.0
        \\
        \\[toast]
        \\duration = 7s
        \\
        \\[modal]
        \\dim-alpha = 50
    ;

    var parser = Parser.init(cfg_text);
    var file_cfg = FileConfig{};
    var diags = Diagnostics{};
    parser.parseInto(&file_cfg, &diags);

    // Mock initial App.Config
    var app_cfg: App.Config = undefined;
    app_cfg.window.card.corner_radius = 8.0;
    app_cfg.window.toast.duration_ms = 5000;
    app_cfg.window.modal.dim_alpha = 180;
    app_cfg.keymap = &.{};
    app_cfg.font.font.family = .{
        .variable = .{
            .upright = "default.ttf",
        },
    };

    try merge_mod.applyFileConfig(&app_cfg, &file_cfg, testing.allocator);

    try testing.expectEqual(@as(f32, 16.0), app_cfg.window.card.corner_radius);
    try testing.expectEqual(@as(u32, 7000), app_cfg.window.toast.duration_ms);
    try testing.expectEqual(@as(u8, 50), app_cfg.window.modal.dim_alpha);
}

test "config: dumpDefaultConfig produces valid configuration template" {
    const merge_mod = @import("merge.zig");
    var buf: [16384]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try merge_mod.dumpDefaultConfig(&w);

    const dumped = buf[0..w.end];
    try testing.expect(dumped.len > 0);

    // Verify it parses cleanly without diagnostics errors
    var parser = Parser.init(dumped);
    var cfg = FileConfig{};
    var diags = Diagnostics{};
    parser.parseInto(&cfg, &diags);

    try testing.expect(!diags.hasErrors());
    try testing.expectEqual(@as(f32, 8.0), cfg.card_corner_radius.?);
    try testing.expectEqual(@as(u32, 5000), cfg.toast_duration_ms.?);
    try testing.expectEqual(Banner.Style.floating, cfg.banner_style.?);
    try testing.expectEqual(Banner.Position.top_center, cfg.banner_position.?);
}

test "config: dot notation with snake_case properties" {
    const text =
        \\window.background_alpha = 0.88
        \\window.confirm_quit = false
        \\window.dim_alpha = 0.45
        \\card.corner_radius = 12.0
        \\card.border_width = 1.5
        \\modal.dim_alpha = 140
        \\modal.blur = true
        \\modal.blur_radius = 16
        \\modal.close_on_outside_click = false
        \\toast.border_style = subtle
        \\toast.position = top_right
        \\toast.duration = 4s
        \\wellbeing.daily_limit = 6h
        \\wellbeing.focus_time = 30m
        \\wellbeing.short_break = 7m
        \\wellbeing.long_break = 20m
        \\wellbeing.tasks_before_long_break = 5
        \\wellbeing.lock_input_on_break = true
        \\banner.style = docked
        \\banner.position = top_right
    ;

    var parser = Parser.init(text);
    var cfg = FileConfig{};
    var diags = Diagnostics{};
    parser.parseInto(&cfg, &diags);

    try testing.expect(!diags.hasErrors());
    try testing.expectEqual(@as(f32, 0.88), cfg.window_background_alpha.?);
    try testing.expectEqual(false, cfg.window_confirm_quit.?);
    try testing.expectEqual(@as(f32, 0.45), cfg.window_dim_alpha.?);
    try testing.expectEqual(@as(f32, 12.0), cfg.card_corner_radius.?);
    try testing.expectEqual(@as(f32, 1.5), cfg.card_border_width.?);
    try testing.expectEqual(@as(u8, 140), cfg.modal_dim_alpha.?);
    try testing.expectEqual(true, cfg.modal_blur.?);
    try testing.expectEqual(@as(u8, 16), cfg.modal_blur_radius.?);
    try testing.expectEqual(false, cfg.modal_close_on_outside_click.?);
    try testing.expectEqual(.subtle, cfg.toast_border_style.?);
    try testing.expectEqual(.top_right, cfg.toast_position.?);
    try testing.expectEqual(@as(u32, 4000), cfg.toast_duration_ms.?);
    try testing.expectEqual(@as(u32, 6 * 60), cfg.wellbeing_daily_limit_minutes.?);
    try testing.expectEqual(@as(u32, 30 * 60 * 1000), cfg.wellbeing_focus_task_ms.?);
    try testing.expectEqual(@as(u32, 7 * 60 * 1000), cfg.wellbeing_focus_short_break_ms.?);
    try testing.expectEqual(@as(u32, 20 * 60 * 1000), cfg.wellbeing_focus_long_break_ms.?);
    try testing.expectEqual(@as(u32, 5), cfg.wellbeing_tasks_before_long_break.?);
    try testing.expectEqual(true, cfg.wellbeing_lock_input_on_break.?);
    try testing.expectEqual(Banner.Style.docked, cfg.banner_style.?);
    try testing.expectEqual(Banner.Position.top_right, cfg.banner_position.?);
}

test "config: banner section and options parsing" {
    const text =
        \\[banner]
        \\enabled = true
        \\style = floating
        \\position = top_center
        \\border_style = semantic
        \\corner_radius = 6.0
        \\border_width = 1.5
        \\min_width = 40
        \\max_width = 80
        \\margin_cols = 3
        \\margin_rows = 2
    ;

    var parser = Parser.init(text);
    var cfg = FileConfig{};
    var diags = Diagnostics{};
    parser.parseInto(&cfg, &diags);

    try testing.expect(!diags.hasErrors());
    try testing.expectEqual(true, cfg.banner_enabled.?);
    try testing.expectEqual(Banner.Style.floating, cfg.banner_style.?);
    try testing.expectEqual(Banner.Position.top_center, cfg.banner_position.?);
    try testing.expectEqual(Toast.BorderStyle.semantic, cfg.banner_border_style.?);
    try testing.expectEqual(@as(f32, 6.0), cfg.banner_corner_radius.?);
    try testing.expectEqual(@as(f32, 1.5), cfg.banner_border_width.?);
    try testing.expectEqual(@as(u16, 40), cfg.banner_min_width.?);
    try testing.expectEqual(@as(u16, 80), cfg.banner_max_width.?);
    try testing.expectEqual(@as(u16, 3), cfg.banner_margin_cols.?);
    try testing.expectEqual(@as(u16, 2), cfg.banner_margin_rows.?);

    const merge_mod = @import("merge.zig");
    const App = @import("../App.zig");
    var app_cfg: App.Config = undefined;
    app_cfg.window.banner = .{};
    app_cfg.keymap = &.{};
    app_cfg.font.font.family = .{
        .variable = .{ .upright = "default.ttf" },
    };

    try merge_mod.applyFileConfig(&app_cfg, &cfg, testing.allocator);
    try testing.expectEqual(true, app_cfg.window.banner.enabled);
    try testing.expectEqual(Banner.Style.floating, app_cfg.window.banner.style);
    try testing.expectEqual(Banner.Position.top_center, app_cfg.window.banner.position);
    try testing.expectEqual(@as(f32, 6.0), app_cfg.window.banner.corner_radius);
    try testing.expectEqual(@as(f32, 1.5), app_cfg.window.banner.border_width);
    try testing.expectEqual(@as(u16, 40), app_cfg.window.banner.min_width);
    try testing.expectEqual(@as(u16, 80), app_cfg.window.banner.max_width);
    try testing.expectEqual(@as(u16, 3), app_cfg.window.banner.margin_cols);
    try testing.expectEqual(@as(u16, 2), app_cfg.window.banner.margin_rows);
}

test "config: card border_style cascades and syncs across native UI elements" {
    const Card = @import("../renderer/Card.zig");
    const text =
        \\[card]
        \\border_style = subtle
        \\
        \\[toast]
        \\position = top_right
    ;

    var parser = Parser.init(text);
    var cfg = FileConfig{};
    var diags = Diagnostics{};
    parser.parseInto(&cfg, &diags);

    try testing.expect(!diags.hasErrors());
    try testing.expectEqual(Card.BorderStyle.subtle, cfg.card_border_style.?);

    const merge_mod = @import("merge.zig");
    const App = @import("../App.zig");
    var app_cfg: App.Config = undefined;
    app_cfg.window.card = .{};
    app_cfg.window.modal = .{};
    app_cfg.window.toast = .{};
    app_cfg.window.banner = .{};
    app_cfg.keymap = &.{};
    app_cfg.font.font.family = .{
        .variable = .{ .upright = "default.ttf" },
    };

    try merge_mod.applyFileConfig(&app_cfg, &cfg, testing.allocator);
    try testing.expectEqual(Card.BorderStyle.subtle, app_cfg.window.card.border_style);
    try testing.expectEqual(Card.BorderStyle.subtle, app_cfg.window.modal.border_style.?);
    try testing.expectEqual(Card.BorderStyle.subtle, app_cfg.window.toast.border_style);
    try testing.expectEqual(Card.BorderStyle.subtle, app_cfg.window.banner.border_style);

    // Verify token consistency between elements
    const tokens = @import("../color/Tokens.zig").Tokens.dark;
    try testing.expectEqual(tokens.border, Toast.variantAccent(.neutral, tokens));
    try testing.expectEqual(tokens.info, Toast.variantAccent(.info, tokens));
    try testing.expectEqual(tokens.warning, Toast.variantAccent(.warning, tokens));
    try testing.expectEqual(tokens.critical, Toast.variantAccent(.critical, tokens));
}
