const std = @import("std");
const testing = std.testing;

const wellbeing = @import("root.zig");
const storage = wellbeing.storage;
const tracker = wellbeing.tracker;
const reminders = wellbeing.reminders;
const winddown = wellbeing.winddown;
const dashboard = wellbeing.dashboard;

test "storage: DayRecord addAppTime accumulates and sorts properly" {
    var record = storage.DayRecord{};

    record.addAppTime("nvim", 120);
    record.addAppTime("nvim", 60);
    record.addAppTime("zsh", 30);
    record.addAppTime("claude", 90);

    try testing.expectEqualStrings("nvim", record.top_apps[0].getName());
    try testing.expectEqual(@as(u32, 180), record.top_apps[0].seconds);

    try testing.expectEqualStrings("zsh", record.top_apps[1].getName());
    try testing.expectEqual(@as(u32, 30), record.top_apps[1].seconds);

    try testing.expectEqualStrings("claude", record.top_apps[2].getName());
    try testing.expectEqual(@as(u32, 90), record.top_apps[2].seconds);
}

test "tracker: idle detection pauses screen time" {
    var tr = tracker.Tracker.init(.{
        .idle_threshold_s = 60,
        .daily_limit_minutes = 60,
        .track_foreground_apps = false,
    });

    var today = storage.DayRecord{};

    // Active for 30s
    _ = tr.tick(30, -1, &today);
    try testing.expect(!tr.is_idle);
    try testing.expectEqual(@as(u32, 30), today.active_screen_s);

    // Another 30s passes without activity -> user becomes idle
    _ = tr.tick(30, -1, &today);
    try testing.expect(tr.is_idle);

    // While idle, active screen time must not increment
    _ = tr.tick(30, -1, &today);
    try testing.expect(tr.is_idle);
    try testing.expectEqual(@as(u32, 60), today.active_screen_s);

    // User activity resumes
    tr.recordActivity();
    try testing.expect(!tr.is_idle);
    _ = tr.tick(10, -1, &today);
    try testing.expectEqual(@as(u32, 70), today.active_screen_s);
}

test "tracker: daily limit triggers grayscale factor" {
    var tr = tracker.Tracker.init(.{
        .idle_threshold_s = 300,
        .daily_limit_minutes = 1, // 60 seconds
        .grayscale_on_limit = true,
        .grayscale_transition_s = 10,
        .track_foreground_apps = false,
    });

    var today = storage.DayRecord{};

    // 50s active: below limit
    const res1 = tr.tick(50, -1, &today);
    try testing.expect(!res1.limit_reached);
    try testing.expectEqual(@as(f32, 0.0), tr.grayscale_factor);

    // 15s active (total 65s): exceeds 60s limit
    const res2 = tr.tick(15, -1, &today);
    try testing.expect(res2.limit_reached);
    try testing.expect(tr.grayscale_factor > 0.0);

    // 10s more: fully transitions to 1.0 grayscale
    _ = tr.tick(10, -1, &today);
    try testing.expectEqual(@as(f32, 1.0), tr.grayscale_factor);
}

test "reminders: eyesight 20-20-20 and movement triggers" {
    var rem = reminders.RemindersEngine.init(
        .{ .interval_minutes = 1, .duration_s = 20 },
        .{ .interval_minutes = 2, .duration_s = 60 },
        .{ .hydration_interval_minutes = 3 },
    );

    var today = storage.DayRecord{};

    // Tick 50s (below 60s eyesight limit)
    const alert1 = rem.tick(50, false, &today);
    try testing.expect(alert1 == null);

    // Tick 10s (reaches 60s eyesight limit)
    const alert2 = rem.tick(10, false, &today);
    try testing.expect(alert2 != null);
    try testing.expectEqual(reminders.AlertKind.eyesight, alert2.?.kind);
    try testing.expectEqual(@as(u16, 1), today.eyesight_breaks);

    // Tick 60s more (reaches 120s movement limit)
    const alert3 = rem.tick(60, false, &today);
    try testing.expect(alert3 != null);
    try testing.expectEqual(reminders.AlertKind.movement, alert3.?.kind);
    try testing.expectEqual(@as(u16, 1), today.movement_breaks);
}

test "winddown: schedule window and color warmth tint" {
    var wd = winddown.WinddownEngine.init(.{
        .start_hour = 21,
        .start_minute = 0,
        .end_hour = 7,
        .end_minute = 0,
        .warmth_factor = 0.85,
    });

    // 12:00 PM (43200 seconds into day) -> Daytime, not active
    const day_res = wd.update(43200);
    try testing.expect(!day_res.active);
    try testing.expectEqual(@as(f32, 1.0), day_res.color_tint[0]);
    try testing.expectEqual(@as(f32, 1.0), day_res.color_tint[1]);
    try testing.expectEqual(@as(f32, 1.0), day_res.color_tint[2]);

    // 22:00 (79200 seconds into day) -> Nighttime, active
    const night_res = wd.update(79200);
    try testing.expect(night_res.active);
    try testing.expect(night_res.just_started);
    try testing.expectEqual(@as(f32, 1.0), night_res.color_tint[0]); // Red stays 1.0
    try testing.expect(night_res.color_tint[2] < 0.80); // Blue is attenuated
}

test "dashboard: renders card output cleanly" {
    var data = storage.PersistentData{};
    data.today.active_screen_s = 7200; // 2 hours
    data.today.focus_s = 3600; // 1 hour
    data.today.break_s = 600; // 10 min
    data.today.tasks_completed = 4;
    data.current_streak = 3;
    data.best_streak = 7;
    data.today.addAppTime("nvim", 4800);
    data.today.addAppTime("claude", 2400);

    var buf: [2048]u8 = undefined;
    const card = dashboard.render(&data, 240, &buf); // 4 hour limit
    try testing.expect(card.len > 0);
    try testing.expect(std.mem.indexOf(u8, card, "REX DIGITAL WELLBEING") != null);
    try testing.expect(std.mem.indexOf(u8, card, "nvim") != null);
    try testing.expect(std.mem.indexOf(u8, card, "claude") != null);
}

test "Wellbeing service: day rollover and streaks" {
    var wb = wellbeing.Wellbeing.init(.{});

    // Day 1000
    const day1_s: i64 = 1000 * std.time.s_per_day + 3600;
    _ = wb.tick(1000, -1, day1_s);
    try testing.expectEqual(@as(u32, 1000), wb.data.today.day);

    wb.data.today.tasks_completed = 2;
    wb.data.today.focus_s = 3000;

    // Day 1001 (rollover)
    const day2_s: i64 = 1001 * std.time.s_per_day + 3600;
    _ = wb.tick(1000, -1, day2_s);

    try testing.expectEqual(@as(u32, 1001), wb.data.today.day);
    try testing.expectEqual(@as(u32, 1), wb.data.history_count);
    try testing.expectEqual(@as(u32, 1000), wb.data.history[0].day);
    try testing.expectEqual(@as(u16, 2), wb.data.history[0].tasks_completed);
    try testing.expectEqual(@as(u32, 3000), wb.data.history[0].focus_s);
}

test "focus: session toggle, tick, and break prompt rotation" {
    var wb = wellbeing.Wellbeing.init(.{
        .focus = .{
            .task_ms = 2000,
            .short_break_ms = 1000,
            .long_break_ms = 3000,
            .tasks_before_long_break = 2,
            .transition_mode = .auto,
            .rotate_break_prompts = true,
        },
    });

    try testing.expectEqual(wellbeing.focus.Phase.idle, wb.focus_state.phase);
    wb.toggleFocus();
    try testing.expectEqual(wellbeing.focus.Phase.task, wb.focus_state.phase);
    try testing.expectEqual(@as(u32, 1), wb.data.sessions);

    const day1_s: i64 = 1000 * std.time.s_per_day + 3600;
    const res = wb.tick(2000, -1, day1_s);
    try testing.expect(res.phase_changed);
    try testing.expectEqual(wellbeing.focus.Phase.short_break, wb.focus_state.phase);
    try testing.expectEqual(@as(u16, 1), wb.data.today.tasks_completed);
    try testing.expectEqual(@as(u32, 1), wb.data.current_streak);
    try testing.expect(res.alert != null);
    try testing.expectEqual(reminders.AlertKind.healthy_break, res.alert.?.kind);
}

test "reminders: lock_input and show_animation wave modulation" {
    var wb = wellbeing.Wellbeing.init(.{
        .eyesight = .{
            .enabled = true,
            .interval_minutes = 1,
            .duration_s = 20,
            .lock_input = true,
            .show_animation = true,
            .animation = .pulse_dim,
        },
        .winddown = .{
            .enabled = false,
        },
        .routines = .{
            .hydration_interval_minutes = null,
            .posture_interval_minutes = null,
        },
    });

    const day1_s: i64 = 1000 * std.time.s_per_day + 3600;
    const res1 = wb.tick(60_000, -1, day1_s);
    try testing.expect(res1.alert != null);
    try testing.expect(res1.input_locked);

    // Tick 2000ms (peak of 4000ms cosine wave -> dim factor applied to tint)
    const res2 = wb.tick(2000, -1, day1_s);
    try testing.expect(res2.input_locked);
    try testing.expect(res2.tint[0] < 0.70);

    // Dismiss alert unlocks input and restores normal tint
    wb.dismissAlert();
    const res3 = wb.tick(100, -1, day1_s);
    try testing.expect(!res3.input_locked);
    try testing.expectEqual(@as(f32, 1.0), res3.tint[0]);
}

test "focus: auto_pause_on_alert freezes task timer during locked health reminder" {
    var wb = wellbeing.Wellbeing.init(.{
        .focus = .{
            .task_ms = 30_000,
            .short_break_ms = 10_000,
            .auto_pause_on_alert = true,
        },
        .eyesight = .{
            .enabled = true,
            .interval_minutes = 1, // 60s
            .duration_s = 10,
            .lock_input = true,
            .show_animation = false,
        },
        .routines = .{
            .hydration_interval_minutes = null,
            .posture_interval_minutes = null,
        },
        .winddown = .{ .enabled = false },
    });

    // Start focus session (30s task)
    wb.toggleFocus();
    try testing.expectEqual(wellbeing.focus.Phase.task, wb.focus_state.phase);
    try testing.expectEqual(@as(u64, 30_000), wb.focus_state.remaining_ms);

    const day1_s: i64 = 1000 * std.time.s_per_day + 3600;

    // Tick 10s of active work -> remaining_ms decrements to 20_000
    _ = wb.tick(10_000, -1, day1_s);
    try testing.expectEqual(@as(u64, 20_000), wb.focus_state.remaining_ms);

    // Tick another 50s -> total 60s active time triggers 1-min eyesight reminder with lock_input
    const res_alert = wb.tick(50_000, -1, day1_s);
    try testing.expect(res_alert.alert != null);
    try testing.expect(res_alert.input_locked);
    try testing.expect(wb.isFocusPausedByAlert());

    // While locked by the eyesight alert, tick 5 seconds: focus task must remain frozen at 20_000ms!
    _ = wb.tick(5_000, -1, day1_s);
    try testing.expect(wb.isFocusPausedByAlert());
    try testing.expectEqual(@as(u64, 20_000), wb.focus_state.remaining_ms);

    // Dismiss alert -> focus task unfreezes and resumes countdown
    wb.dismissAlert();
    try testing.expect(!wb.isFocusPausedByAlert());
    _ = wb.tick(5_000, -1, day1_s);
    try testing.expectEqual(@as(u64, 15_000), wb.focus_state.remaining_ms);
}

test "overlay: state flags and active detection" {
    var ov = wellbeing.overlay.Overlay.init();
    defer ov.deinit(testing.allocator);

    try testing.expect(!ov.isActive());

    ov.dashboard_open = true;
    try testing.expect(ov.isActive());
    ov.dashboard_open = false;
    try testing.expect(!ov.isActive());

    ov.toast_active = true;
    try testing.expect(ov.isActive());
    ov.toast_active = false;

    ov.lock_screen_active = true;
    try testing.expect(ov.isActive());
}

test "overlay: box and progress bar arithmetic" {
    var ov = wellbeing.overlay.Overlay.init();
    defer ov.deinit(testing.allocator);

    // drawBox creates 1 Background.Instance per row
    ov.drawBox(testing.allocator, 10, 5, 40, 6, .{ 20, 30, 40, 255 });
    try testing.expectEqual(@as(usize, 6), ov.bg_buffer.items.len);
    for (ov.bg_buffer.items, 0..) |inst, i| {
        try testing.expectEqual(@as(u16, 10), inst.col);
        try testing.expectEqual(@as(u16, @intCast(5 + i)), inst.row);
        try testing.expectEqual(@as(u16, 40), inst.span);
        try testing.expectEqual(@as(u8, 20), inst.r);
        try testing.expectEqual(@as(u8, 30), inst.g);
        try testing.expectEqual(@as(u8, 40), inst.b);
        try testing.expectEqual(@as(u8, 255), inst.a);
    }
}

test "icons: glyph lookup and styles" {
    const ic = wellbeing.icons;

    // Unicode glyphs
    try testing.expectEqualStrings("✓", ic.getGlyph(.check, .unicode));
    try testing.expectEqualStrings("✕", ic.getGlyph(.error_icon, .unicode));
    try testing.expectEqualStrings("▲", ic.getGlyph(.warning, .unicode));
    try testing.expectEqualStrings("ℹ", ic.getGlyph(.info, .unicode));
    try testing.expectEqualStrings("■", ic.getGlyph(.lock, .unicode));

    // ASCII glyphs
    try testing.expectEqualStrings("[v]", ic.getGlyph(.check, .ascii));
    try testing.expectEqualStrings("[x]", ic.getGlyph(.error_icon, .ascii));
    try testing.expectEqualStrings("[!]", ic.getGlyph(.warning, .ascii));
    try testing.expectEqualStrings("[i]", ic.getGlyph(.info, .ascii));
    try testing.expectEqualStrings("[#]", ic.getGlyph(.lock, .ascii));

    // Nerd Font glyphs
    try testing.expectEqualStrings("\u{eab2}", ic.getGlyph(.check, .nerd_font));
    try testing.expectEqualStrings("\u{ea87}", ic.getGlyph(.error_icon, .nerd_font));
    try testing.expectEqualStrings("\u{ea6c}", ic.getGlyph(.warning, .nerd_font));
    try testing.expectEqualStrings("\u{f023}", ic.getGlyph(.lock, .nerd_font));

    // Width
    try testing.expectEqual(@as(u16, 1), ic.glyphWidth("✓"));
    try testing.expectEqual(@as(u16, 3), ic.glyphWidth("[v]"));
}

test "overlay: stringWidth and description word wrap" {
    const ov = wellbeing.overlay;

    // Width of standard ASCII
    try testing.expectEqual(@as(u16, 5), ov.stringWidth("hello"));

    // Width with emojis
    const coffee_w = ov.stringWidth("☕");
    try testing.expect(coffee_w >= 1);

    // Word wrap: short string does not wrap
    const short_desc = "Short notice";
    const split_short = ov.splitDescription(short_desc, 30);
    try testing.expectEqualStrings("Short notice", split_short.line1);
    try testing.expectEqualStrings("", split_short.line2);

    // Word wrap: long string splits cleanly on word boundary
    const long_desc = "Look at an object 20 feet away for 20 seconds to relax your eyes";
    const split_long = ov.splitDescription(long_desc, 34);
    try testing.expect(split_long.line1.len > 0);
    try testing.expect(split_long.line2.len > 0);
    try testing.expect(ov.stringWidth(split_long.line1) <= 34);
}

test "overlay: cleanPromptText removes trailing emojis and symbols" {
    const ov = wellbeing.overlay;

    try testing.expectEqualStrings(
        "Look at an object 20 feet away for 20 seconds",
        ov.cleanPromptText("Look at an object 20 feet away for 20 seconds 👀"),
    );

    try testing.expectEqualStrings(
        "Time to stand up, stretch your back, and move",
        ov.cleanPromptText("Time to stand up, stretch your back, and move 🚶"),
    );

    try testing.expectEqualStrings(
        "Stay hydrated: drink some fresh water",
        ov.cleanPromptText("Stay hydrated: drink some fresh water 💧"),
    );

    try testing.expectEqualStrings(
        "Check posture: roll shoulders back, align neck",
        ov.cleanPromptText("Check posture: roll shoulders back, align neck 🪑"),
    );

    try testing.expectEqualStrings(
        "Daily screen-time limit reached",
        ov.cleanPromptText("Daily screen-time limit reached 🛑"),
    );

    try testing.expectEqualStrings(
        "Hydrate: drink a cool glass of fresh water",
        ov.cleanPromptText("Hydrate: drink a cool glass of fresh water 💧."),
    );

    try testing.expectEqualStrings(
        "Box breathing: Inhale 4s, Hold 4s, Exhale 4s, Hold 4s",
        ov.cleanPromptText("Box breathing: Inhale 4s, Hold 4s, Exhale 4s, Hold 4s 🧘."),
    );

    try testing.expectEqualStrings(
        "Roll your shoulders backward and release tension in your neck.",
        ov.cleanPromptText("Roll your shoulders backward and release tension in your neck."),
    );
}

test "overlay: panel rectangle geometry and bounds" {
    const PanelRect = wellbeing.overlay.PanelRect;
    const rect = PanelRect{ .col = 10, .row = 5, .width = 40, .height = 12 };

    try testing.expectEqual(@as(u16, 50), rect.maxCol());
    try testing.expectEqual(@as(u16, 17), rect.maxRow());
    try testing.expectEqual(@as(u16, 11), rect.innerCol());
    try testing.expectEqual(@as(u16, 6), rect.innerRow());
    try testing.expectEqual(@as(u16, 48), rect.innerMaxCol());
    try testing.expectEqual(@as(u16, 15), rect.innerMaxRow());
    try testing.expectEqual(@as(u16, 38), rect.innerWidth());
    try testing.expectEqual(@as(u16, 10), rect.innerHeight());
}

test "overlay: drawDimmingBackdropOutside leaves panel interior untouched" {
    var ov = wellbeing.overlay.Overlay.init();
    defer ov.deinit(testing.allocator);

    const total_cols: u16 = 80;
    const total_rows: u16 = 24;
    const rect = wellbeing.overlay.PanelRect{ .col = 20, .row = 6, .width = 40, .height = 12 };
    const dim_color: [4]u8 = .{ 13, 13, 13, 180 };

    ov.drawDimmingBackdropOutside(testing.allocator, total_cols, total_rows, rect, dim_color);

    // Verify all generated background quads are strictly OUTSIDE rect
    for (ov.bg_buffer.items) |bg| {
        if (bg.row >= rect.row and bg.row < rect.maxRow()) {
            const quad_start = bg.col;
            const quad_end = bg.col + bg.span;
            const inside_dialog = (quad_start < rect.maxCol() and quad_end > rect.col);
            try testing.expect(!inside_dialog);
        }
    }
}

test "overlay: dashboard layout geometry and symmetric padding" {
    // Verify symmetric padding: 3 columns margin on both left and right
    const rect = wellbeing.overlay.PanelRect{ .col = 7, .row = 2, .width = 66, .height = 15 };
    const content_col = rect.col + 3; // 10
    const max_content_col = rect.col + rect.width - 4; // 69

    try testing.expectEqual(@as(u16, 10), content_col);
    try testing.expectEqual(@as(u16, 69), max_content_col);
    // Left padding: content_col - rect.col = 3
    try testing.expectEqual(@as(u16, 3), content_col - rect.col);
    // Right padding: (rect.col + rect.width - 1) - max_content_col = 72 - 69 = 3
    try testing.expectEqual(@as(u16, 3), (rect.col + rect.width - 1) - max_content_col);
}

test "overlay: dashboard tab navigation and history day selection" {
    var ov = wellbeing.overlay.Overlay.init();
    defer ov.deinit(testing.allocator);

    try testing.expectEqual(wellbeing.overlay.DashboardTab.overview, ov.active_tab);
    ov.nextTab();
    try testing.expectEqual(wellbeing.overlay.DashboardTab.pomodoro, ov.active_tab);
    ov.nextTab();
    try testing.expectEqual(wellbeing.overlay.DashboardTab.activity, ov.active_tab);
    ov.nextTab();
    try testing.expectEqual(wellbeing.overlay.DashboardTab.overview, ov.active_tab);

    ov.selectTab(2);
    try testing.expectEqual(wellbeing.overlay.DashboardTab.activity, ov.active_tab);

    // 3 history days + 1 today = 4 total days (indices 0..3)
    ov.moveSelectedDay(-1, 3);
    try testing.expectEqual(@as(?u16, 2), ov.selected_day_idx);
    ov.moveSelectedDay(-5, 3);
    try testing.expectEqual(@as(?u16, 0), ov.selected_day_idx);
    ov.moveSelectedDay(10, 3);
    try testing.expectEqual(@as(?u16, 3), ov.selected_day_idx);
}
