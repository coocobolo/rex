//! Merging one process's wellbeing changes into the shared state file.
//!
//! A process keeps `base`, the file version it last read, and `view`, the
//! data its engines update (base plus its own changes). `rebase` replays
//! the difference between the two onto a newer file version, so several
//! processes can add to the same file without losing each other's work.
//! Every counter only grows between purges, so the difference is a
//! saturating subtraction; a purge bumps `generation`, and a view whose base
//! has an older generation is dropped. Reminder breaks are the exception:
//! they follow the reminders' due points (`mergeReminder`), so a reminder
//! that two processes fired counts once. The daily limit's state takes the
//! later value within a day. These functions do no I/O.

const std = @import("std");
const storage = @import("storage.zig");

const PersistentData = storage.PersistentData;
const DayRecord = storage.DayRecord;

/// The local day number for `local_s` (see `localtime.Clock`). A clock
/// before 1970 gives day 0, the "unset" day, instead of a negative day.
pub fn localDay(local_s: i64) u32 {
    return std.math.cast(u32, @divFloor(local_s, std.time.s_per_day)) orelse 0;
}

/// Starts `day` when it is later than `data.today`: today moves to history
/// (dropping the oldest day when full) and its time joins the totals. An
/// unset today just takes the day. Returns whether a day was pushed.
pub fn rollover(data: *PersistentData, day: u32) bool {
    if (data.today.day == 0) {
        data.today.day = day;
        return false;
    }
    if (day <= data.today.day) return false;

    if (data.history_count < storage.max_history_days) {
        data.history[data.history_count] = data.today;
        data.history_count += 1;
    } else {
        std.mem.copyForwards(DayRecord, data.history[0 .. storage.max_history_days - 1], data.history[1..]);
        data.history[storage.max_history_days - 1] = data.today;
    }
    data.total_active_screen_s +|= data.today.active_screen_s;
    data.total_focus_s +|= data.today.focus_s;
    data.today = .{ .day = day };
    data.limit_alerted_s = 0;
    data.limit_quiet_until_s = 0;
    return true;
}

/// Updates the streak for a task completed on `day`. A day not after the
/// last task's (same day, zone change westward, clock set back) changes
/// nothing, so applying the same day twice is harmless.
pub fn recordTaskDay(data: *PersistentData, day: u32) void {
    if (day <= data.last_task_day) return;
    data.current_streak = if (day == data.last_task_day + 1) data.current_streak + 1 else 1;
    data.best_streak = @max(data.best_streak, data.current_streak);
    data.last_task_day = day;
}

/// Returns `fresh` plus the changes `view` made on top of `base`. When a
/// purge happened since `base` (generation differs), the changes are
/// dropped and `fresh` is returned as is. The timer is not merged here.
pub fn rebase(view: *const PersistentData, base: *const PersistentData, fresh: *const PersistentData) PersistentData {
    var out = fresh.*;
    if (fresh.generation != base.generation) return out;

    _ = rollover(&out, view.today.day);

    // The day `base` was on, as `view` has it now (today, or in history if
    // `view` rolled over since), and any later days `view` started.
    if (findDay(view, base.today.day)) |record| addDayDelta(&out, record, &base.today);
    for (view.history[0..view.history_count]) |*record| {
        if (record.day > base.today.day) addDayDelta(&out, record, &.{});
    }
    if (view.today.day > base.today.day) addDayDelta(&out, &view.today, &.{});

    out.tasks_completed +|= view.tasks_completed -| base.tasks_completed;
    out.long_breaks_taken +|= view.long_breaks_taken -| base.long_breaks_taken;
    if (view.last_task_day > base.last_task_day) recordTaskDay(&out, view.last_task_day);
    mergeReminder(&out.eyesight_due_s, &out.today.eyesight_breaks, view.eyesight_due_s);
    mergeReminder(&out.movement_due_s, &out.today.movement_breaks, view.movement_due_s);
    // The limit's state belongs to `today` and only moves later within it.
    if (view.today.day == out.today.day) {
        out.limit_alerted_s = @max(out.limit_alerted_s, view.limit_alerted_s);
        out.limit_quiet_until_s = @max(out.limit_quiet_until_s, view.limit_quiet_until_s);
    }
    return out;
}

/// Takes `view_due` when it is later than the file's `due` and counts one
/// break on the file's current day. Due points lie on the interval grid of
/// the shared active clock, so processes that fired the same reminder
/// record the same value and the break counts once. Moving off 0 starts the
/// reminder and is not a break. Several fires between two merges count as
/// one, which only an interval shorter than a merge round trip can cause.
fn mergeReminder(due: *u64, breaks: *u16, view_due: u64) void {
    if (view_due <= due.*) return;
    if (due.* != 0) breaks.* +|= 1;
    due.* = view_due;
}

/// Adds `now - before` for one day to `out`'s record of that day. A day
/// already in history has been counted in the totals, so its time is added
/// there too. A day older than `out`'s history is dropped.
fn addDayDelta(out: *PersistentData, now: *const DayRecord, before: *const DayRecord) void {
    if (now.day == 0) return;
    const in_history = out.today.day != now.day;
    const target = findDayMut(out, now.day) orelse return;

    const active_s = now.active_screen_s -| before.active_screen_s;
    const focus_s = now.focus_s -| before.focus_s;
    target.active_screen_s +|= active_s;
    target.focus_s +|= focus_s;
    target.break_s +|= now.break_s -| before.break_s;
    target.tasks_completed +|= now.tasks_completed -| before.tasks_completed;
    for (&now.top_apps) |*app| {
        if (app.seconds == 0) continue;
        const delta_s = app.seconds -| appSeconds(before, app.getName());
        if (delta_s > 0) target.addAppTime(app.getName(), delta_s);
    }
    if (in_history) {
        out.total_active_screen_s +|= active_s;
        out.total_focus_s +|= focus_s;
    }
}

fn appSeconds(record: *const DayRecord, name: []const u8) u32 {
    for (&record.top_apps) |*app| {
        if (app.seconds > 0 and std.mem.eql(u8, app.getName(), name)) return app.seconds;
    }
    return 0;
}

fn findDay(data: *const PersistentData, day: u32) ?*const DayRecord {
    if (day == 0) return null;
    if (data.today.day == day) return &data.today;
    for (data.history[0..data.history_count]) |*record| {
        if (record.day == day) return record;
    }
    return null;
}

fn findDayMut(data: *PersistentData, day: u32) ?*DayRecord {
    if (data.today.day == day) return &data.today;
    for (data.history[0..data.history_count]) |*record| {
        if (record.day == day) return record;
    }
    return null;
}
