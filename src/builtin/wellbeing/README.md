# Wellbeing

Digital wellbeing built into Rex: a focus timer (pomodoro), screen time with an optional daily limit, eyesight and movement reminders, an evening wind-down, and a dashboard. Everything stays on the machine; nothing is sent anywhere.

The module lives in `src/builtin/wellbeing/` and is reached as `rex.builtin.wellbeing`. `App.zig` owns one `Wellbeing` per process and drives it from the main loop. Rex runs **one process per window** (`new_window` starts the executable again), so several windows share one person's state through a file, described under [Shared state](#shared-state-across-windows).

## Features

| Feature | What it does | Config section |
| --- | --- | --- |
| Focus timer | Task, short break and long break phases; waits for the user or starts the next phase (`on_phase_end`); mutes the bell during a task; prompts, locks input or animates at a break. Shared by all windows. | `[wellbeing.focus]` |
| Screen time | Counts active time (input within `idle_threshold`) in the focused window; per-app time from the pty's foreground process; a daily limit (off by default) that fades to grayscale, locks input or animates. | `[wellbeing.screen_time]`, `[wellbeing.privacy]` |
| Reminders | Eyesight (20-20-20) and movement reminders on the shared active-time clock. The focused window fires each one once. Optional input lock and animation. | `[wellbeing.eyesight]`, `[wellbeing.movement]` |
| Wind-down | An evening window (local time) that warms the screen colors and can mute the bell. Off by default. | `[wellbeing.winddown]` |
| Dashboard | Overlay with overview, pomodoro and activity tabs; `rex wellbeing` prints a text card. | `[wellbeing]` |

`[wellbeing] enabled = false` turns everything off: `tick` returns neutral results and `sync` does nothing.

Default keys: `ctrl+shift+p` start, pause or resume the focus timer; `ctrl+shift+]` skip the phase; `ctrl+shift+backspace` reset; `ctrl+shift+a` switch `on_phase_end` until the next reload; `ctrl+shift+w` dashboard; `ctrl+shift+d` dismiss an alert. `wellbeing_clear` has no default key. From a shell: `rex wellbeing` prints the dashboard, `rex wellbeing clear` purges the history.

## Files

| File | Role |
| --- | --- |
| `root.zig` | `Wellbeing`: options, engines, the per-frame `tick`, focus actions, and the shared-state protocol (`open`, `sync`, `purgeHistory`, `close`). |
| `storage.zig` | The state file format (`PersistentData`, version 3), atomic save, `decode`, file stamps, and the `flock` side files. |
| `merge.zig` | Pure functions: `rebase` replays one process's changes onto a newer file version; `rollover`, `recordTaskDay`, `localDay`. |
| `focus.zig` | The focus timer: `Timer` (stored), pure transitions returning a `Tally`, and `State`, the read-only view the UI reads. |
| `tracker.zig` | Screen time, idle detection, foreground-app sampling (`tcgetpgrp`, `/proc/<pgrp>/comm`), the daily limit. |
| `reminders.zig` | Reminder engines and the `Alert` type. Due points live in the state file. |
| `winddown.zig` | The wind-down window and its color tint. |
| `localtime.zig` | UTC to local seconds via `localtime_r`, with a `tzset` once per minute so zone changes apply while Rex runs. |
| `dashboard.zig` | The text card (`rex wellbeing`, copy to clipboard). |
| `overlay.zig`, `icons.zig` | The dashboard overlay and lock screen. Not imported by `root.zig`: they reach `src/renderer/` and `src/ui/`, and the state module must not. |
| `wellbeing_test.zig` | All tests of the module. |

## Each frame

`App.run` calls, in this order:

1. `tick(dt_ms, pty_fd, local_s, utc_ms)`: day rollover, screen time (focused window only), reminders (focused window, on the shared active clock, and not over an alert already on screen), wind-down, the focus timer (phase end, `on_alert = pause`, break prompt), bell muting and input lock. It returns redraw, alert, grayscale and tint for the renderer.
2. `syncWellbeing` → `sync(.poll)`: exchanges changes with the state file, at most once per second unless a merge is due.
3. The event loop waits at most until `msUntilSync` (the next second), so a sleeping window still notices another window's timer.

Input callbacks call `recordActivity`; the GLFW focus callback calls `windowFocusChanged`; focus actions call `toggleFocus`, `skipFocus`, `resetFocus` with wall-clock milliseconds. After installing the focus callback, `App` reads GLFW's focus once, because a window can open unfocused and never receive a focus event. At exit `App` merges with `sync(.merge)` and then calls `close`.

Two clocks are in play: `dt_ms` from the monotonic clock drives screen time, and reminders follow that shared active time; wall-clock time (`utc_ms`, `local_s`) drives the focus timer, days and wind-down.

## Shared state across windows

### Files

All in the state directory (`privacy.state_dir`, default `$XDG_STATE_HOME/rex`), named after `privacy.state_filename` (default `wellbeing.bin`):

| File | Purpose |
| --- | --- |
| `wellbeing.bin` | The state. Every save writes a temporary file and renames it over the old one (`Dir.createFileAtomic` + `File.Atomic.replace`), so readers always see one complete version and need no lock. |
| `wellbeing.bin.lock` | Empty. Writers hold an exclusive `flock` on it while they read, modify and write. The lock cannot live on the data file, because the rename replaces that file. |
| `wellbeing.bin.alive` | Empty. Each process holds a shared `flock` on it from `open` to `close`; a starting process that gets an exclusive lock knows it is alone. |

`flock` locks are released by the kernel when a process exits, crashes included. They belong to an open file description, so two opens in one process conflict like two processes do, which is how the tests simulate windows.

### Merging changes

Each process keeps two copies of `PersistentData`:

- `base`: the file version it last read;
- `data`: what its engines read and update, that is `base` plus this process's own changes.

`merge.rebase(view, base, fresh)` returns `fresh` (the newest file) plus `data − base`. Every counter only grows between purges, so the difference is a saturating subtraction. Changes are matched to their day by day number, so midnight is exact in both directions, and changes to a day already in history also reach the totals. App times are added as differences per app.

`sync(.poll)` usually costs one `stat`: it compares the file's `Stamp` (inode and mtime; every save creates a new inode) and re-reads only when it changed, then replays the local changes on top. A merge is due:

- every 60 s (either direction, so a clock set back does not postpone it);
- on a local day change;
- when the focus timer changed here (`timerPending`);
- when a reminder due point moved, so another window sees it on its next poll;
- when this window lost focus with unmerged screen time, so only the focused window ever holds unmerged time.

A due poll uses `tryLockWrite` and never blocks the main thread; if another process holds the lock, it polls instead and stays due. `sync(.merge)` (exit, and the restart in `open`) and `purgeHistory` wait for the lock and flush their save to disk. A merge writes only when the result differs from the file, so an idle window never rewrites it.

### Focus timer

The timer (`focus.Timer`) is stored in the file as a phase, a `Run` state and one time value:

| `Run` | `ms` means |
| --- | --- |
| `paused` | the time left |
| `running` | the wall-clock time at which the phase ends |
| `waiting` | unused: the phase ended and waits for the user |

Every window derives the same time left from its own clock, and nothing is written while the timer runs. Transitions (`toggle`, `skip`, `reset`, `endIfDue`, `applyPhaseEnd`, `extend`) are pure functions that return the new timer and a `Tally` (tasks, long breaks, focus and break time).

A change is written, and its tally added, only if `timer_rev` in the file is still the one this process read; the write bumps it. Otherwise another window changed the timer first: the file's timer wins and the local change and its tally are dropped. So a phase end that several windows notice is counted once. Every window still shows the break prompt, because `tick` compares the timer with `seen_timer` and treats a running phase whose end time passed as ended, wherever it was recorded.

Focus and break time count when a phase is left (ended, skipped, reset), as its length minus the time left.

`on_alert = pause`: while a reminder blocks input during a running task, this window does not end the phase and its display holds; when the reminder closes, the end moves later by how long it was shown.

When `open` finds no other window alive and a phase still running, the phase was left behind by windows that closed: it comes back paused with the time it had left at the last save (`last_write_utc_s`), or waiting and uncounted if that had run out. This is written at once, so a window opening next does not join it. A second window joins a running timer.

### Purge

`purgeHistory` writes an empty file with `generation + 1`. A process whose `base` has an older generation drops its unmerged changes and its pending timer change on the next sync, so a purge in one window is not undone by another. Memory is cleared only once the file is written.

### Screen time and the limit

Only the focused window runs the tracker; the window manager focuses one window at a time, so adding the windows' times is exact. Gaining focus counts as activity. The limit compares `data.today`, the file's time plus this window's, so it covers every window that has merged. The limit's state is shared and belongs to the day (`limit_alerted_s`, `limit_quiet_until_s`; rollover clears both, a merge keeps the later value, and a change is merged within a poll):

- The focused window shows the limit alert and records the limit start it alerted for, so the other windows do not repeat it. A limit raised and reached again alerts again.
- The grayscale is computed from the shared data (`tracker.grayscale`) in every window, focused or not.
- Dismissing (`wellbeing_dismiss`, or closing any alert) once the limit is reached lifts the limit for the rest of the day in every window, also after the limit's alert has closed by itself.

### Reminders

`eyesight_due_s` and `movement_due_s` are the shared active clock (`total_active_screen_s + today.active_screen_s`) at which that reminder was last due. Rollover moves today's time into the total, so a new day does not move the clock. A value of 0 means not started: the first time the focused window sees it, the due point becomes the current clock and nothing fires. An upgraded file, a new file and a purge therefore do not burst.

Only the focused window evaluates them. A reminder is due when the clock reaches the due point plus the interval. The due point then snaps to the latest grid point at or before the clock, and several missed intervals fire once. It does not fire while any alert is on screen; it stays due and fires when that alert ends. Movement is checked first, so two reminders due together show one after the other.

The break is added in the merge, on the file's current day, when the due point moves forward from a non-zero value. The same due point from two windows counts once. Moving off 0 is not a break. Several fires between two merges count as one, which only an interval shorter than a merge round trip can cause. Idle time pauses reminders because the clock stops.

## State file format

`PersistentData` is an `extern struct` written as raw bytes in native byte order, 2,920 bytes, with no implicit padding (a test checks the field sizes add up). The header holds `magic` ("WELL"), `version` (3), `generation`, `timer_rev`, `last_write_utc_s` and the 16-byte `Timer`; then the totals and statistics, `history_count`, 14 days of `DayRecord` (184 bytes each), `today`, `eyesight_due_s`, `movement_due_s` (taken from the old `reserved`; 0 means not started) and 64 bytes of `reserved`.

`decode` accepts only the exact size, the magic and the current version, and rejects a `history_count` above 14, so a damaged file cannot index past `history`. Until the first release, a layout change bumps `version` and older files are rejected (`error.InvalidStateFile`), not migrated; the first merge then replaces the file.

`storage.save` takes a `Durability`. Saves during a session are `buffered`: measured on ext4, an fsync raises a save from about 0.05 ms to about 1 ms with spikes to 13.6 ms, too much for the frame path, and a power loss can lose at most the latest one (ext4's default `auto_da_alloc` flushes a file replaced by rename). The exit save, the restart in `open` and a purge are `synced`: the temporary file is fsynced before the rename and the directory after it (std 0.16.0 has no `Dir.sync`; the directory is opened without `O_PATH` and its handle synced as a `File`), so the last save and a purge's removal of the old data survive a power loss.

## Time

`localtime.Clock` turns UTC seconds into local seconds with `localtime_r`, caching per second and calling `tzset` once per wall-clock minute: glibc's `localtime_r` loads the zone only once per process, so this is how a changed system zone (`timedatectl`, travel) applies within a minute. A set `TZ` pins the zone. macOS re-checks the zone in every `localtime_r` call.

Days are local day numbers (`merge.localDay`). A clock before 1970 gives day 0, the "unset" day: day tracking waits for a real clock, and changes with no day are not merged. The streak never moves backwards: a task on an earlier local day (zone change westward, clock set back) counts as the same day.

The focus timer uses wall-clock time, so setting the clock moves a running phase; suspend counts as elapsed time.

## Invariants

Check every change against these:

- **One writer at a time, readers lock-free.** Every read-modify-write of `wellbeing.bin` holds the write lock; every save replaces the file atomically.
- **Never block a frame.** Polls use `tryLockWrite` and save `buffered`; only the exit save, the restart in `open` and a purge wait for the lock and fsync.
- **Counters only grow between purges.** `rebase` depends on it; a decrease must go through a purge (generation bump).
- **A timer change counts once.** Tallies are added only by the write that bumps `timer_rev`; never add timer statistics to `data` directly in a shared process.
- **Screen time is counted by the focused window only.**
- **A reminder fires in the focused window only, and its break is counted once.** The due point lives in the file. Moving off 0 starts the reminder and is not a break.
- **Wall clock for the timer and days, monotonic `dt` for durations.** Reminders follow the shared active clock, not their own timer.
- **No allocation** in the module's own code for `tick`, `sync` or the merge: file contents, names and stamps use fixed buffers. (Whether std's `Io` allocates inside file operations is not verified.)

## Ownership and lifetimes

- `App` owns the `Wellbeing` value for the life of the process.
- The presence lock (`Wellbeing.presence`) is held from `open` to `close`; `App` merges before `close`. `presence == null` marks a standalone `Wellbeing` that never joined the shared state (tests, `rex wellbeing`): it records timer statistics at once, since no other writer can race it.
- Strings in `Wellbeing.option` (prompts, display icons) are borrowed from `App.config_arena`. On reload `App` frees the old arena, takes the new one and calls `applyOption` with the new options; nothing reads the options in between.
- The overlay's instance buffers are allocated with `App`'s allocator and freed by `Overlay.deinit`.
- Lock and data files are opened per operation and closed before it returns, except the presence file.

## Errors

`open`, `sync` and `purgeHistory` return explicit error sets (`OpenError`, `SyncError`). `App` handles them like this:

- `open` failure: logged as a warning; Rex starts with empty data, and if the presence lock was taken, the first merge replaces an unreadable file.
- `sync` failure: `App.syncWellbeing` logs and shows a toast when a failure starts or its error changes, not on every retry, and reports the recovery.
- `purgeHistory` failure: a toast, and "Wellbeing history cleared." only on success.
- Exit save failure: logged only, since the window is closing.

An unreadable file found by a poll is logged once per file version and left for the next merge to replace.

## Testing

```sh
zig build test -Dtest-filter=storage -Dtest-filter=merge -Dtest-filter=sync -Dtest-filter=focus -Dtest-filter="screen time" -Dtest-filter=reminder
```

All tests are in `wellbeing_test.zig`. The shared-state tests run two `Wellbeing` values against one temporary directory (`StateTmp`, `openShared`, `openFocus`, `openReminders`) and drive time explicitly: `tick` and the focus actions take wall-clock milliseconds, and `sync` takes wall-clock seconds.

## Known limits and follow-ups

- **`on_alert = pause` holds the task only in the window showing the alert.** Another window can still end the phase. This needs `during_reminder = lock_input` as well, and that is off by default. Pushing the shared end later from the focused window does not close the race, and it would drop the hold for the screen-limit alert, so the hold stays local.
- A wind-down that starts in the same tick, or a focus phase that ends in the same tick, can replace a reminder after its due point has already moved. The reminder is counted and not shown again until the next interval. An alert already on screen does not have this hole: the reminder stays due.
- A window that picks up a running timer and passes its end time in the same loop iteration does not show the break prompt; the phase end is still counted once.
- A button press in one window that races a phase end recorded by another is dropped.
- Two windows that both count time within the same poll second can each show the screen-limit alert.
- Per-app time reads `/proc/<pgrp>/comm`, which exists only on Linux.
- The overlay builds on the provisional `src/ui/`, which allocates per frame and will be redesigned.
