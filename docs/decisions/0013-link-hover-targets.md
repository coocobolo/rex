# 0013: Show OSC 8 link targets on hover and style link underlines

- Status: accepted
- Date: 2026-11-20
- Deciders: Kbgjtn (maintainer)
- Tickets: #136

## Context

ADR 0012 added OSC 8 links with a forced underline and a configurable link
color, but decided that "rendering a hover popup or URL preview" was out of
scope. The maintainer has since asked for both: a kitty-style
`show_hyperlink_targets` affordance and a configurable underline style.

Read externally (not verified against running terminals): kitty's `kitty.conf(5)`
documents `show_hyperlink_targets`, `detect_urls`, `url_style` and
`underline_hyperlinks`, and notes that `underline_hyperlinks always` applies
only to real OSC 8 hyperlinks, not hover-detected plain URLs. The sources read
for xterm did not show OSC 8 or URL auto-detection support.

In the code: `src/term/cell.zig:25-34` already defines `single`, `double`,
`curly`, `dotted` and `dashed`, and `src/renderer/Decoration.zig` already
carries the shader options for all five. `src/kit/tooltip.zig` draws an
anchored card with no id, so a hit falls through to what is underneath;
`src/kit/layout.zig:69-72` clamps a point-anchored card into the viewport and
`src/kit/Tree.zig:218-225` can truncate text to one line with an ellipsis.
`KitOverlay` has fixed node and line buffers. `App` already resolves the link
under the pointer for the hand pointer (`src/App.zig`).

## Decision

1. **Hover target.** `[hyperlink] show_hyperlink_targets` is one of `never`,
   `ctrl`, `cmd`, `alt`, `shift`, `always`, default `ctrl`. When the configured
   modifier is held and a real OSC 8 link is under the pointer, draw its URI
   in a one-line tooltip near the pointer. A modal, scrollbar hover or the
   fullscreen ASCII overlay suppresses it. It requires `hyperlink.enabled`,
   but is otherwise independent of Ctrl+click activation. Modifier state is
   tracked from key events: a modifier's own press event reports `ctrl=false`
   (the state before that event), so the transition is folded in explicitly.
   The platform key query was found unreliable in a headless GLFW build and
   is not used for this decision.
2. **Tooltip.** Reuse `kit/tooltip.zig` in `KitOverlay`. The URI is borrowed
   from the current `Frame` for the one `buildFrame` call; long URIs are
   truncated with `…`. The card has no id, so it never takes a click from the
   link underneath. The fixed node and line budgets grow by five nodes and
   one line. Hover and modifier changes request a repaint.
3. **Underline style.** `[hyperlink] underline_style` is one of `single`,
   `double`, `curly`, `dotted`, `dashed`, default `single`. It styles only the
   underline Rex adds when `underline = true` and the cell has no SGR
   underline; an explicit SGR underline keeps its own style.
4. **Scope.** Both keys live in the existing `[hyperlink]` section, are
   round-tripped by the config writer, pinned in `keys_test.zig` and exposed
   in Settings. This supersedes decision 3 of ADR 0012's visual treatment;
   the storage and security decisions there are unchanged.

## Alternatives considered

- **A terminal status line or permanent URL bar.** A reserved screen row would
  change the terminal image; a tooltip stays local to the pointer.
- **Always show the target.** Permanent tooltips clutter ordinary text;
  `ctrl` matches the activation modifier, so the target appears when the user
  intends to click. `always` remains available.
- **Reuse the cell's `UnderlineStyle` enum for the config key.** It includes
  `none`, which duplicates `underline = false`; a config-only enum keeps the
  two settings distinct.
- **Scan the visible buffer for URLs to show their targets.** That is plain
  URL detection, not OSC 8; it remains a separate ticket with its own
  benchmark. Hover resolves one cell only, with no per-frame scan.

## Consequences

- Two new config keys and their Settings rows; no breaking config change.
- `KitOverlay` carries five more nodes and one more line of fixed capacity,
  with no heap allocation. The tooltip's URI slice is valid only for the
  frame that draws it and is never stored.
- Repaints happen when the hovered link or the configured modifier changes;
  a bare modifier press or release now requests a repaint.
- A link id above the frame's URL snapshot bound still renders but has no
  tooltip, matching its lack of a click target.
- Plain-text and pasted URLs remain undetected; that needs its own ticket.
