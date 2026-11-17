# 0008: Keep only transient UI in the terminal window; settings and the dashboard run as their own processes

- Status: accepted
- Date: 2026-11-12
- Deciders: Kbgjtn (maintainer)
- Tickets: draft #87 (the UI kit trial). Supersedes nothing. The UI model is ADR 0009; the design tokens are a spec, not an ADR.

## Context

The current `src/ui/` is provisional and will be replaced. Before choosing
how the new UI is built, this ADR decides where each piece of UI lives,
because that fixes how much the terminal window has to carry.

What exists today (read on 2026-11-12, `develop` at `ddd30ad`):

- Everything is drawn as an overlay in the terminal window, positioned by
  terminal row and column (`src/ui/Button.zig`, `Text.zig`).
- The wellbeing dashboard is such an overlay (`src/builtin/wellbeing/
  overlay.zig`, 1,281 lines). It is the only user of the chart-style
  components (`StatCard`, `BarChart`, `RingGauge`, `TabBar`,
  `StepIndicator`, `ProgressBar`).
- Rex runs one process per window. The wellbeing state is one fixed-size
  struct (`PersistentData`, `storage.zig`) saved by atomic rename, with
  `flock` locks for writers. Every process checks the file once a second
  and merges changes (`Wellbeing.msUntilSync`, `sync`); a revision counter
  makes exactly one process apply each timer transition.
- `rex wellbeing` already exists as a subcommand that prints a text card
  (`src/main.zig`).
- The config is a text file. The terminal watches its directory with
  inotify and reloads on change (`src/config/watcher.zig`, Linux only).
  The tokenizer records the byte span of every value and comment
  (`Tokenizer.Token.Span`), and `Loaded.set_by` records which layer and
  token last set each key. Nothing writes a config file today.

Forces:

- Input latency, frame-time consistency and rendering throughput come
  first. Code that runs in the terminal's frame path must earn its place.
- v1 requires a single window (v1 requirements, 2026-11-06), and ADR 0001
  keeps GLFW behind a platform interface that has no multi-window support.
- The visual direction is shadcn/ui's restraint (semantic tokens, 1px
  borders, one radius, variants × sizes × states) and Sonner for toasts.
  A settings window is wanted in v1 (maintainer, 2026-11-12).
- GLFW and FreeType are the only native dependencies.

## Decision

1. **The terminal window holds transient UI only**: toasts, the
   config-error banner, confirm dialogs (quit, paste confirmation), the
   scrollbar, the wellbeing prompt and lock screen, and later a search
   bar. Its component kit is small: Text, Icon, Button, Kbd, Toast, Banner,
   Dialog.
2. **Settings and the wellbeing dashboard are separate processes of the
   same binary**, one window each: `rex settings` and a window mode of
   `rex wellbeing`. The terminal starts them on a key binding by spawning
   itself; they can also be run from a shell.
3. **Processes share state through files, with no server and no
   database.** The dashboard joins the existing wellbeing sync protocol.
   Settings edits the user's config file, and the terminal's watcher
   reloads it.
4. **Wellbeing splits.** Tracking, the timer and reminder engines and the
   in-window effects (prompt, lock screen, tint, bell mute) stay in the
   terminal process, since they need its input, focus and pty. The
   dashboard overlay leaves it.
5. **One window per process stays the rule**, so the v1 single-window
   requirement and ADR 0001 are unchanged.
6. **Settings writes config through a new span-preserving writer**: it
   replaces the bytes of one value (or appends a key to its section) in
   the user file and leaves comments, order and spacing alone. It never
   writes the system file. The file is replaced atomically.

## Alternatives considered

- **Everything as an in-window overlay (today).** One window and one GL
  context, but the overlay covers the terminal, is sized by it, and puts
  dashboard and form code in the terminal's frame path.
- **A second window in the terminal process.** Proper size without a new
  process, but it breaks the single-window requirement, needs multi-window
  in the platform interface, and two vsynced swaps on one thread can stall
  terminal frames. Wayland gives no control over where the window goes.
- **No GUI: config stays a text file and the dashboard is a TUI program.**
  The leanest option and no UI kit needed for it, but a settings window is
  wanted for v1.
- **A background server holding the state.** Changes would arrive at once
  and there would be one writer, at the cost of a process to start, find,
  restart and stop, plus a socket protocol. The file protocol already
  solves this and is tested.
- **SQLite for the state.** A new native dependency for one bounded struct
  that is read whole.
- **Two executables.** A smaller terminal binary on disk, but the process
  boundary is what protects latency; code the terminal never runs costs it
  nothing at runtime. Can be split later without changing this decision.

## Consequences

- **Terminal frame path:** loses the dashboard and the chart components.
  Not measured; the claim is about code removed, not a latency number.
- **Dashboard actions:** a button (start, pause, skip) reaches the terminal
  at its next sync, within one second. If that feels slow, the terminal
  can watch the state file as it watches the config. Not built here.
- **New work:** a window mode for `rex wellbeing`; `rex settings`; the
  config writer with round-trip tests (parse, set, write, parse again,
  every other byte unchanged); spawning a child process from a binding.
- **Shared code:** the UI kit must work in a process with no terminal, so
  it cannot depend on `term/` or the driver. This constrains the UI-model
  ADR.
- **Failure behaviour:** a crash in settings or the dashboard cannot take
  the shell down. A settings write that fails leaves the old file (atomic
  replace). A config the terminal rejects on reload keeps the running
  config, as today, and settings should show the diagnostic.
- **Portability:** the config watcher is Linux-only (inotify); macOS needs
  its own before `rex settings` works live there.
- **Not decided here:** layout (pixel or cell), text and fonts, immediate
  or retained, tokens, motion; whether the settings window covers every
  key or a curated subset; sessions that outlive their window, which would
  need a long-lived process and are a separate decision.

## Answered on 2026-11-12

1. With wellbeing disabled, the dashboard binding does nothing.
2. `rex settings` opens when the user file has parse errors and shows
   them; it does not refuse to start.
3. One settings window at a time, enforced with a `flock` lock file like
   the wellbeing presence lock; a second start focuses nothing and exits
   with a message.
