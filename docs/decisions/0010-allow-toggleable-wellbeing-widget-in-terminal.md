# 0010: Allow a toggleable wellbeing focus widget inside the terminal window

- Status: accepted
- Date: 2026-11-14
- Deciders: Kbgjtn (maintainer)
- Tickets: #115 (amends point 1 of ADR 0008; built on ADR 0009).

## Context

ADR 0008 (`docs/decisions/0008-keep-only-transient-ui-in-the-terminal-window.md`, lines 48–65) restricts the terminal window's UI kit overlay to transient surfaces (toasts, alert banner, modal dialogs, lock screen) and keeps the wellbeing dashboard in the separate `rex wellbeing` process (`src/tool/dashboard.zig`). That kept heavy chart code and form state out of `App.zig` while holding input latency and idle wakeups down.

Today the replacement UI kit (`src/KitOverlay.zig`, `src/renderer/KitPainter.zig`, `src/kit/`) is already in place with:

- Zero heap allocations after `KitOverlay.create` (static `nodes` and `lines` arrays in `src/KitOverlay.zig:38-48`).
- Three instanced primitives in `src/renderer/KitPainter.zig:32`: rounded rectangle (`box`), UI/icon glyph (`glyph`), and rounded-cap circular ring (`arc`, used by `src/kit/chart.zig:228-243`).
- Shared focus timer state and controls (`toggleFocus`, `skipFocus`, `resetFocus`, `msUntilTick`) already present in `App.wellbeing_state` (`src/App.zig:995, 1653-1666`).

A separate OS window (`rex wellbeing`) solves full analytics, but on Wayland a process cannot control its screen position or stay pinned inside the user's active workspace corner while typing in a terminal. The maintainer wants an optional, glanceable focus-timer snippet directly inside the terminal window that can be dragged and resized over the viewport without opening the full dashboard window.

## Decision

Amend point 1 of ADR 0008 to allow **one toggleable, user-pinned HUD surface** (`wellbeing_widget`) inside `KitOverlay` under the following hard bounds:

1. **Glance and controls only, no charts or forms.** The widget shows only live focus timer status (phase label, remaining `MM:SS`, progress ring) and direct action buttons (`Play`/`Pause`, `Skip`, `Reset`) driven by the existing `[wellbeing.focus]` configuration and `storage.Timer` state. Multi-day statistics, history, and screen-time breakdowns stay in `rex wellbeing`.
2. **Ephemeral per-window state in v1.** Visibility (hidden by default) and geometry (`x`, `y`, `width`, `height`) live per window in memory and toggle via a keybind (`wellbeing_widget`, default `ctrl+shift+t`) when `[wellbeing] enabled = true`. No config keys or persistent state fields are added yet.
3. **Zero heap allocations and existing primitives only.** The widget compiles into fixed node/line bounds in `KitOverlay`, paints with `box`, `glyph`, and `arc` only, and uses `Theme` tokens (`card`, `border`, `foreground`, `muted_foreground`, with `theme.info` for active focus progress).
4. **Bounded wakeup rate.** While hidden or paused, the widget requests zero extra loop wakeups. While visible and running, `waitForNextEvent` wakes at most once per second at whole-second boundaries (`1 Hz`), matching existing cursor blink (`~500 ms`) and `Wellbeing.sync` (`1 s`) cadence. Pointer drag/resize redraws only on pointer move events while held.
5. **Responsive size steps without text reflow overhead.** Resizing snaps/switches layout density across discrete size thresholds (compact pill vs. medium timer + ring card) and clamps coordinates and size within the current window bounds on resize.

## Alternatives considered

- **Compact mode in `rex wellbeing` only (`rex wellbeing --compact`).** Keeps ADR 0008 completely untouched and avoids terminal cell occlusion, but relies on the compositor for positioning and floating behavior (unavailable on Wayland) and has up to ~1 s file-sync lag unless extra file-watch IPC is added.
- **Fixed-corner non-draggable HUD pill.** Avoids drag/resize state in `KitOverlay`, but cannot be moved out of the way when text of interest sits in that corner (e.g. tmux status bars or editor splits).
- **Custom duration presets in the widget (`5m` / `10m` / `20m`).** Useful shortcut, but `focus.Timer` (`src/builtin/wellbeing/storage.zig:99-105`) and `focus.durationMs` (`src/builtin/wellbeing/focus.zig:74-81`) derive phase length from `[wellbeing.focus]`. Deferred to keep the shared state format and config unchanged.

## Consequences

- **Frame path:** `App` keeps zero allocations per frame and zero cost while the widget is toggled off; `KitOverlay.node_capacity` and `KitOverlay.line_capacity` grow by the static widget node count.
- **Kit interaction model:** `KitOverlay` gains pointer-drag tracking (extending `holdsPress` + `pointerMoved` for drag move and bottom-right corner resize), reusable if other draggable HUD overlays are ever needed, while preserving ADR 0009's `state / update / view` split.
- **Terminal interaction:** While visible, pointer presses on the widget card are consumed by `KitOverlay` before text selection or PTY mouse reporting; toggling the widget off restores full viewport coverage immediately.
- **Reversibility:** Contained to `src/kit/wellbeing_widget.zig`, `src/KitOverlay.zig`, `src/input/binding.zig`, and `src/App.zig`; removes cleanly if ever moved back out.
