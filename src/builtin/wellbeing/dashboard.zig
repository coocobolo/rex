const std = @import("std");
const storage = @import("storage.zig");

pub fn fmtDuration(seconds: u32, buf: []u8) []const u8 {
    const h = seconds / 3600;
    const m = (seconds % 3600) / 60;
    if (h > 0) {
        return std.fmt.bufPrint(buf, "{d}h {d:0>2}m", .{ h, m }) catch "";
    } else {
        return std.fmt.bufPrint(buf, "{d}m", .{m}) catch "";
    }
}

pub fn fmtProgressBar(percent: u32, width: usize, buf: []u8) []const u8 {
    const clamped_pct: u32 = @min(percent, 100);
    const filled = (clamped_pct * @as(u32, @intCast(width))) / 100;
    var idx: usize = 0;
    for (0..width) |i| {
        if (i < filled) {
            const block = "█";
            @memcpy(buf[idx..][0..block.len], block);
            idx += block.len;
        } else {
            const empty = "░";
            @memcpy(buf[idx..][0..empty.len], empty);
            idx += empty.len;
        }
    }
    return buf[0..idx];
}

fn appendStr(buf: []u8, pos: *usize, str: []const u8) bool {
    if (pos.* + str.len > buf.len) return false;
    @memcpy(buf[pos.*..][0..str.len], str);
    pos.* += str.len;
    return true;
}

fn appendFmt(buf: []u8, pos: *usize, comptime fmt: []const u8, args: anytype) bool {
    const slice = std.fmt.bufPrint(buf[pos.*..], fmt, args) catch return false;
    pos.* += slice.len;
    return true;
}

pub fn render(
    data: *const storage.PersistentData,
    daily_limit_ms: ?u64,
    buf: []u8,
) []const u8 {
    var pos: usize = 0;

    if (!appendStr(buf, &pos, "\n  ┌────────────────────────────────────────────────────────┐\n")) return buf[0..0];
    if (!appendStr(buf, &pos, "  │                 REX DIGITAL WELLBEING                  │\n")) return buf[0..0];
    if (!appendStr(buf, &pos, "  ├────────────────────────────────────────────────────────┤\n")) return buf[0..0];

    // Screen Time Today
    var time_buf: [16]u8 = undefined;
    const active_str = fmtDuration(data.today.active_screen_s, &time_buf);

    if (daily_limit_ms) |limit_ms| {
        const limit_s: u32 = std.math.cast(u32, limit_ms / std.time.ms_per_s) orelse std.math.maxInt(u32);
        var limit_buf: [16]u8 = undefined;
        const limit_str = fmtDuration(limit_s, &limit_buf);
        const pct: u32 = if (limit_s > 0) @min((data.today.active_screen_s *| 100) / limit_s, 100) else 0;

        var bar_buf: [64]u8 = undefined;
        const bar = fmtProgressBar(pct, 10, &bar_buf);

        if (!appendFmt(buf, &pos, "  │ Today's Screen Time: {s} / {s} [{s}] {d:>3}% │\n", .{ active_str, limit_str, bar, pct })) return buf[0..0];
    } else {
        if (!appendFmt(buf, &pos, "  │ Today's Screen Time: {s:<34}│\n", .{active_str})) return buf[0..0];
    }

    if (!appendFmt(buf, &pos, "  │ Current Streak: {d:>2} days  |  Best Streak: {d:>2} days             │\n", .{ data.current_streak, data.best_streak })) return buf[0..0];
    if (!appendStr(buf, &pos, "  ├────────────────────────────────────────────────────────┤\n")) return buf[0..0];

    // Focus & Rest Stats
    var focus_buf: [16]u8 = undefined;
    var break_buf: [16]u8 = undefined;
    const focus_str = fmtDuration(data.today.focus_s, &focus_buf);
    const break_str = fmtDuration(data.today.break_s, &break_buf);

    if (!appendFmt(buf, &pos, "  │ Focus: {s:<8} Break: {s:<8} Completed Tasks: {d:<4} │\n", .{ focus_str, break_str, data.today.tasks_completed })) return buf[0..0];
    if (!appendFmt(buf, &pos, "  │ Eyesight Rests: {d:<4}  Movement Breaks: {d:<4} Hydration: {d:<3}  │\n", .{ data.today.eyesight_breaks, data.today.movement_breaks, data.today.hydration_count })) return buf[0..0];
    if (!appendStr(buf, &pos, "  ├────────────────────────────────────────────────────────┤\n")) return buf[0..0];

    // Top Apps Today
    if (!appendStr(buf, &pos, "  │ Top Terminal Tools Today:                              │\n")) return buf[0..0];

    var app_count: usize = 0;
    const total_app_s = @max(data.today.active_screen_s, 1);

    for (data.today.top_apps) |app| {
        const name = app.getName();
        if (name.len == 0 or app.seconds == 0) continue;
        app_count += 1;

        var app_tbuf: [16]u8 = undefined;
        const app_time = fmtDuration(app.seconds, &app_tbuf);
        const app_pct = (app.seconds * 100) / total_app_s;

        var bar_buf: [64]u8 = undefined;
        const bar = fmtProgressBar(app_pct, 8, &bar_buf);

        if (!appendFmt(buf, &pos, "  │   {d}. {s:<10} {s:>7}  [{s}] {d:>3}%               │\n", .{ app_count, name, app_time, bar, app_pct })) return buf[0..0];
        if (app_count >= 4) break;
    }

    if (app_count == 0) {
        if (!appendStr(buf, &pos, "  │   (No tool activity sampled yet)                       │\n")) return buf[0..0];
    }

    if (!appendStr(buf, &pos, "  └────────────────────────────────────────────────────────┘\n")) return buf[0..0];

    return buf[0..pos];
}
