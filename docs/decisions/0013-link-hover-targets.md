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
`src/kit/text.zig:120-127` cuts at UTF-8 boundaries for fixed buffers.
`KitOverlay` has fixed node and line buffers. `App` already resolves the link
under the pointer for the hand pointer (`src/App.zig`).

## Decision

1. **Hover target.** `[hyperlink] show_hyperlink_targets` is one of `never`,
   `ctrl`, `cmd`, `alt`, `shift`, `always`, default `ctrl`. When the configured
   modifier is held and a real OSC 8 link is under the pointer, draw its URI
   in a narrow tooltip near the pointer. A modal, scrollbar hover or the
   fullscreen ASCII overlay suppresses it. It requires `hyperlink.enabled`,
   but is otherwise independent of Ctrl+click activation. Modifier state is
   tracked from key events: a modifier's own press event reports `ctrl=false`
   (the state before that event), so the transition is folded in explicitly.
   The platform key query was found unreliable in a headless GLFW build and
   is not used for this decision.
2. **Tooltip.** Reuse `kit/tooltip.zig` in `KitOverlay`. `[hyperlink]
   tooltip_uri_style` selects `multiline` (default: a fixed buffer wrapped at
   codepoint boundaries into at most five short lines, 360 px wide),
   `head_tail` (one line with the first 40 and last 24 characters and `…`
   between), or `wide` (one line up to 520 px, ellipsized at the edge). The
   card has no id, so it never takes a click from the link underneath. The
   fixed node budget grows by five nodes and the line budget by five lines.
   Hover and modifier changes request a repaint.
3. **Underline.** `[hyperlink] underline` becomes the single mode enum
   `never|always|hover` (default `always`), replacing the earlier boolean and
   the proposed `underline_visibility` key. This is a config-format change:
   `underline = true` becomes `always`, `false` becomes `never`. An explicit
   SGR underline is always drawn, whatever the mode.
4. **Underline style.** `[hyperlink] underline_style` is one of `single`,
   `double`, `curly`, `dotted`, `dashed`, default `single`. It styles only the
   underline Rex adds and only when the cell has no SGR underline.
5. **Hover underline.** In `hover` mode the added underline is drawn only on
   the link under the pointer, using the same hover resolution as the tooltip
   and hand pointer (modals and scrollbar hover clear it). The builder gets
   the hovered link id before building the frame and treats a change as a
   dirty cell; without this, cached decoration runs kept the old underline
   until a click or pty output. Only links with a URI in the frame snapshot
   qualify, so links above the 16-URI cap cannot show a false affordance.
   No per-frame scan or allocation is added.
6. **Scope.** All keys added here live in the existing `[hyperlink]` section,
   are round-tripped by the config writer, pinned in `keys_test.zig` and
   exposed in Settings. This supersedes decision 3 of ADR 0012's visual
   treatment; the storage and security decisions there are unchanged.

## Alternatives considered

- **A terminal status line or permanent URL bar.** A reserved screen row would
  change the terminal image; a tooltip stays local to the pointer.
- **Always show the target.** Permanent tooltips clutter ordinary text;
  `ctrl` matches the activation modifier, so the target appears when the user
  intends to click. `always` remains available.
- **Reuse the cell's `UnderlineStyle` enum for the config key.** It includes
  `none`, which duplicates `underline = false`; a config-only enum keeps the
  two settings distinct.
- **Only one tooltip layout.** Head+tail is best for real URLs, multi-line
  shows more of a pathological one, and wide is simplest; since the maintainer
  wanted all three and the current layout as default, a single enum exposes
  them without new UI or allocation.
- **Scan the visible buffer for URLs to show their targets.** That is plain
  URL detection, not OSC 8; it remains a separate ticket with its own
  benchmark. Hover resolves one cell only, with no per-frame scan.

## Consequences

- Three new config keys (`show_hyperlink_targets`, `underline_style`,
  `tooltip_uri_style`) and one breaking change: `underline` is now
  `never|always|hover` instead of a boolean. `underline_visibility` is not
  shipped. Existing configs using `underline = true|false` must be updated.
- `Frame` grows by the bounded URI snapshot (`[16][1024]u8`, 32 bytes of
  lengths and a generation counter). Measured `@sizeOf(Frame)` is 36496 for
  the 12×24 test option and 36520 for the production 200×220 option, with
  `@alignOf(Frame) == 8`; regression tests pin both. The 64-byte alignment of
  the cell buffer itself is unchanged.
- `KitOverlay` carries five more nodes, five more text lines and a 207-byte
  URI buffer of fixed capacity, with no heap allocation. Its measured size
  grew 378304 → 379096 bytes; the wrapped text is borrowed by the tree from
  that buffer until the next build.
- Repaints happen when the hovered link or the configured modifier changes;
  a bare modifier press or release now requests a repaint. `hover` underline
  mode relies on that repaint, including when no tooltip is shown.
- In `hover` mode the decoration builder copies its option only for linked
  cells, to clear the added underline for non-hovered links. The renderer
  imports the config's `UnderlineVisibility` directly rather than mirroring
  it, so there is one source of truth and no translation switch.
- A link id above the frame's URL snapshot bound still renders but has no
  tooltip, hand pointer, hover underline or click target.
- Plain-text and pasted URLs remain undetected; that needs its own ticket.
