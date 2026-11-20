# 0014: Own visual settings in one place

- Status: accepted
- Date: 2026-11-20
- Deciders: Kbgjtn (maintainer)
- Tickets: #139

## Context

`src/renderer/Decoration.zig:154` describes its `Option` as "User settings for
decorations", but `src/App.zig:720-724` wires only three fields from config,
all under `[hyperlink]`: `link_underline`, `link_style` and `color.link`. The
remaining fields — ink skipping, drawing order, opacity, dim and blink
behaviour, line placement, style geometry and the strikethrough/overline
colors — are hard-wired to defaults.

Two copies of the option exist. `Frame.Builder` gets the configured value and
bakes resolved runs into the frame (`src/renderer/Frame.zig:910-923`); `Renderer`
gets `.decoration = .{}` (`src/App.zig:734`) and reads `order` and
`skip_ink.styleBits()` from its own copy (`src/renderer/renderer.zig:406,475`).
This is harmless today because the configured fields are link-only, but it
would make any newly exposed decoration setting disagree between run creation
and drawing.

Config is declared in `src/config/keys.zig`, documented in `default.conf`,
pinned by `keys_test.zig`, and surfaced in `src/tool/settings.zig`. A new
section is the established way to expose a coherent group of settings with
live reload.

## Decision

1. **Ownership.** A new `[decoration]` section owns general text-decoration
   settings. Link-specific activation and policy stay in `[hyperlink]`; the
   existing `hyperlink.underline`, `underline_style` and `link_color` keys keep
   their names so the recent config format does not break. Both sections feed
   one effective `Decoration.Option`.
2. **One value.** `App` builds that option once from config and passes the same
   value to both `Frame.Builder` and `Renderer`. There is no second default
   copy and no per-call mutation of config state.
3. **Defaults.** Every new key defaults to today's behaviour. An optional
   value of `none` means "keep the font-derived metric", resolved once in
   `Decoration.Metrics.resolve`. Changing a default is a separate, measured
   decision.
4. **Enums.** Shared enums such as `order` and skip-ink styles are declared
   once in `config/` and imported by the renderer, as
   `hyperlink.UnderlineVisibility` already is at
   `src/renderer/Decoration.zig:12`. No mirror enum or translation switch.
5. **Layout checks.** Changed shared structs get `comptime` checks in their
   implementation file using `if (...) @compileError("actionable message")`,
   not `std.debug.assert` and not runtime tests.

## Alternatives considered

- **Leave renderer defaults independent.** Fewer edits, but every exposed
  setting that affects drawing would silently diverge from the runs; rejected.
- **Move the existing link visual keys into `[decoration]`.** Cleaner grouping
  on paper, but a breaking config change immediately after #136; rejected.
- **Add option parameters to every draw call.** Avoids a stored copy but adds
  plumbing through the hot render path; rejected in favour of one owned value.
- **Expose every numeric metric at once.** More control, but a large config
  surface with no measured demand; the ticket stages behaviour opt-outs first.

## Consequences

- Adds a `[decoration]` config section, its Settings rows, round-trip tests and
  live reload. No existing key changes meaning, so no migration is needed.
- `Decoration.Option` gains fields; its size and alignment will be measured
  before and after, with a `comptime` check added.
- Unifying the option copies is a small refactor in `App.zig` and
  `renderer.zig`, covered by a test asserting both see the same value.
- Pixel-identical defaults must be confirmed under Xvfb before any stage that
  changes rendering behaviour is accepted.
