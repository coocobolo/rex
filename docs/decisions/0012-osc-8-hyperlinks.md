# 0012: OSC 8 hyperlinks carried in interned styles

- Status: accepted
- Date: 2026-11-19
- Deciders: Kbgjtn (maintainer)
- Tickets: #136 (draft, not filed)

## Context

Rex has no OSC 8 support. The VT parser is already generic over OSC codes:
`Terminal.oscEnd` parses the numeric code and hands the raw payload to
`dispatcher.Osc.dispatch(code, data)` (`src/term/term.zig:1084`), and unknown
codes are silently ignored by the default arm (`src/term/dispatcher.zig:384`).
OSC 8 appears only in the fuzz seed list (`src/fuzz/strings.zig:25`). No parser
change is needed to receive `OSC 8 ; params ; URI ST` and the matching reset.

A cell is a fully packed `u64` — codepoint 32, kind 3, flags 12, style 16,
wrapped 1 (`src/term/cell.zig:121-148`, size asserted at `:150-163`). There is
no room for a link ID, and ADR 0005 rejected growing the cell to 16 bytes
because it would double the default 7.2 MB cell ring and the copy bandwidth in
snapshot, scroll and reflow (`docs/decisions/0005…:195-197`).

ADR 0005 accepted interned styles and explicitly reserved this decision:
"OSC 8 links would add `link: u16`, an index into a per-screen URL table; the
same mark pass then frees unused styles and unused URLs together… Links are
not part of this decision; OSC 8 gets its own ticket" (`:176-186`). The old
coordinate-keyed `ext_attrs`/`url_table` were removed because they drifted from
their text on scroll and reflow (`:47-51`). Bulk operations in `screen.zig`
move whole `Cell` values, so a link reached through the style ID rides along
automatically.

Mouse modifiers reach the click point: `event.mods` is passed to
`handleSelectionPress` (`src/App.zig:3311`). A press starts a selection drag
and a release without movement ends it as `.none` (`src/App.zig:3185`,
`:3207-3213`), so activation must be reconciled with selection. There is no
existing URL-opening mechanism; `spawnDetached` (`:2201-2212`) only launches
rex subcommands. `xdg-open`, `gio` and `open` are available on this host.

## Decision

1. **Storage.** Add `link: u16` to the interned style entry (12 → 16 bytes),
   indexing a per-screen URL table. The cell stays 8 bytes. The existing style
   mark-and-sweep frees unused URLs in the same pass; there is no second
   lifetime mechanism and no coordinates.
2. **Application.** Writing a cell interns the pen's `(fg, bg, underline,
   link)` tuple, so every link is its own style; blanks carry no link. RIS and
   explicit `OSC 8 ;; ST` clear the pen link. Following xterm, a newline does
   **not** clear it.
3. **Rendering.** Linked cells are underlined and use a configurable link
   color; both visual treatments can be switched off independently in config.
4. **Activation.** Ctrl+click opens the link under the cursor. On press with
   Ctrl held over a link, do not start a selection; on release over the same
   cell, open it. Otherwise selection behaves exactly as today.
5. **Opening.** `[hyperlink] open_command` is configurable; when unset, use
   the platform default (`xdg-open`, `gio open`, or `open`). The URI is passed
   as a single argv element, never through a shell.
6. **Security.** Allowed URI schemes default to `http`, `https` and `mailto`.
   The allowlist is configurable; `file` is not allowed by default. Unknown or
   disallowed schemes are ignored without spawning.
7. **Default.** Hyperlinks are enabled by default; config can opt out.
8. **Cost.** Accept the style-table growth (ADR 0005 estimates frame tables
   768 KiB → 1 MiB and screen tables 288 KiB → 352 KiB). Measure on a real
   workload later and revisit if the numbers justify it.

## Alternatives considered

- **A link field in `Cell`.** Impossible without growing the cell; rejected
  for the memory and bandwidth cost recorded in ADR 0005.
- **Coordinate-keyed side table.** The removed `ext_attrs` approach; drifts on
  scroll and reflow.
- **Terminal-global current URI only.** No per-cell underline and stale URI
  after a reset; rejected.
- **Plain click or Alt+click activation.** Plain click conflicts with
  selection; Alt is already block selection.
- **Fixed system command, no config.** Rejected: the maintainer wants the
  config to fall back to system defaults rather than hard-code one.
- **Deny-by-default feature flag.** Rejected: hyperlinks on by default, with
  an opt-out.

## Consequences

- Cell layout and all `@sizeOf(Cell)` invariants are unchanged; the 64-byte
  alignment and 8-cells-per-line rule still hold.
- More distinct styles: every link is its own style, so workloads with many
  links can approach the 16,384 style capacity faster; the existing sweep
  reclaims both styles and URLs.
- The renderer needs a link flag on decoration runs so underline runs coalesce
  only across identical link state; one reserved bit in `Decoration.Flags` is
  available.
- Opening a URI spawns an external process from pty-controlled data, hence the
  scheme allowlist and argv-only spawning.
- Config gains a `[hyperlink]` section; every new key must be documented and
  parse/serialize round-tripped like other config keys.
