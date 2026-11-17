# 0009: Build the UI as state, one update function and a flat view, laid out in pixels with its own theme and font

- Status: accepted
- Date: 2026-11-12
- Deciders: Kbgjtn (maintainer)
- Tickets: draft #87 (the trial this decision was accepted on). Depends on ADR 0008 (where UI lives).

## Context

ADR 0008 leaves the terminal window with a small kit of transient
components (Text, Icon, Button, Kbd, Toast, Banner, Dialog) and moves
settings and the wellbeing dashboard into their own processes. The same kit
has to serve both: an overlay that must cost nothing while hidden, and a
whole window of forms.

What the current `src/ui/` shows (read on 2026-11-12, `develop` at
`ddd30ad`):

- `App.zig` sets `needs_redraw` by hand in 73 places; forgetting one is a
  stale frame.
- Components build quads with `ArrayList.append(...) catch {}`: an
  allocation per frame, and quads dropped silently when it fails.
- Layout, hit-testing (`hotspot.Table`, 64 entries) and text are in
  terminal cells. The rounded-box shader exists (`renderer/Card.zig`,
  `card.frag`) but is positioned by column and row and carries
  wellbeing-only shapes (ring, pip, bars).
- The rasterizer opens a fixed set of faces at one size, the terminal's
  (`freetype/Rasterizer.zig`), and the atlas caches by code point.

Forces: input latency and frame consistency first; no allocation in
render; state machines explicit with one exhaustive switch;
HiDPI and fractional scaling in v1; keyboard access; GLFW and FreeType as
the only native dependencies, so no shaping library.

The visual reference is shadcn/ui (semantic tokens, 1px borders, one
radius, variants × sizes × states) and Sonner for toasts.

## Decision

1. **Model: state, update, view.** Each surface owns a plain state struct
   whose modes are an enum or tagged union. `update(state, event)` is the
   only code that changes it, one exhaustive switch, and it returns whether
   anything changed. `view(state)` writes a flat array of nodes (box, text,
   icon) into a fixed-capacity buffer; running out of room is an explicit
   error. A redraw happens exactly when `update` reports a change or an
   animation is running. Nothing else may request one. Surfaces are
   specific (a toast stack, a dialog that asks one question); what they
   share is view functions and small helpers (a modal frame, a button, a
   focus order), never a widget that owns state on a caller's behalf.
2. **Per-widget memory by stable id.** What a view cannot derive from its
   surface's state (where a node was last drawn, a scroll offset, a text
   cursor) lives in a small table keyed by an id the view assigns, so it
   survives a rebuild of the node array. Animation progress and focus are
   state, not memory.
3. **Layout in logical pixels**, one pass over the node array: rows and
   columns, padding, gap, and sizes that are fixed, fit-content or fill.
   Logical pixels are multiplied by the display scale once and snapped to
   physical pixels, so hairlines stay one physical pixel wide at 125% and
   150%. An "at most" size joins the three before a dialog carries longer
   texts.
4. **Two draw primitives**: a pixel-positioned rounded rectangle (fill,
   border, radius) and a glyph. Painting and hit-testing read the same
   node array.
5. **Its own theme, independent of the terminal's colors**: one `Theme`
   struct of named values after shadcn's set (background, foreground, card,
   popover, primary, secondary, muted, accent, destructive, border, input,
   ring, plus radius, spacing step and type sizes), with a dark and a light
   instance. The variant follows the brightness of the terminal background,
   with a config key to force one. Components name tokens, never colors.
6. **A proportional UI font from the start**, bundled as static faces,
   one per weight, separate from the terminal font, at the UI's own sizes. The atlas caches by face, size and
   glyph. Text is measured from glyph advances: Latin-first, left to right,
   no shaping. Text the font lacks falls back to the terminal font's faces.
7. **Motion** is short and fixed (150 to 200 ms, eased, no springs), runs
   only while a transient element is on screen, and can be turned off in
   config. An idle UI causes no wakeups.
8. **The kit depends on neither `term/` nor the driver**, so it runs in a
   process without a terminal (ADR 0008).

## Alternatives considered

- **Immediate mode.** Least code, but state ends up split between the app
  and a hidden per-widget store, layout needs two passes or lags a frame,
  and focus and text input need the id store anyway.
- **Retained widget tree.** Best fit for forms and focus traversal, but the
  most code, and the app's state is duplicated in the widgets, which is the
  failure the current code already has.
- **Cell-grid layout.** No new text path and it follows the cell size on
  HiDPI for free, but it cannot give real padding or hairline borders, so
  it cannot reach the reference look.
- **The terminal's monospaced font for UI text.** Avoids the second text
  path; rejected by the maintainer in favour of a proportional face from
  day one.
- **Tokens derived from the terminal theme.** UI always matches the
  terminal, but every terminal theme then has to yield a usable UI palette;
  rejected for an independent theme that only follows light or dark.

## Consequences

- **Renderer work:** a pixel-positioned rounded-rectangle batch; a glyph
  batch at pixel positions; atlas keys by face and size; a second set of
  faces in the rasterizer.
- **Font:** Geist and Inter were checked on 2026-11-12 (files from
  `google/fonts`, `ofl/`): both SIL Open Font License 1.1, both variable
  TrueType, kerning in GPOS only. Inter was chosen. FreeType 2.13.3 reads
  GPOS pair kerning when built with `TT_CONFIG_OPTION_GPOS_KERNING`, but
  only plain x-advance pairs: the variable face keeps its pairs with
  variation data and gets none (measured: A V 0 px variable, -1.36 px
  static at 18 px). Hence the static faces.
- **Limits:** no complex scripts, no bidirectional text and no ligature
  shaping in UI text. User-supplied strings in other scripts render through
  the fallback faces with their own metrics.
- **Tests:** `view` needs no GL, so a test can assert that a state yields
  given nodes, and layout can be tested on plain rectangles.
- **Memory:** fixed buffers per surface (nodes, id table, instances), sized
  at compile time and reported when the types exist. No allocation in
  update, view, layout or paint.
- **Trial:** a toast stack and a dialog were built on this model before
  it was accepted; see "Trial evidence".
- **Not decided here:** the token values (a design spec, not an ADR); the
  component list and each component's variants and states; text input
  editing behaviour for settings; scroll containers.

## Answered on 2026-11-12

1. The UI font is Inter (maintainer's choice; bundling approved). It goes
   under `assets/fonts/` with its OFL text, like Google Sans Code.
2. UI type sizes are fixed in logical pixels for now and do not follow the
   system font size.

## Trial evidence (ticket 87, 2026-11-12)

A toast stack and a dialog (the quit prompt) were built on this
model in `src/kit/`, drawn by `renderer/KitPainter.zig` with
`freetype/KitFont.zig`, and wired into the window behind `REX_UI_KIT=1`.
What follows was measured or seen unless it says otherwise.

By decision point:

1. **State, update, view: holds.** Both surfaces are a plain state struct,
   one `update` and a `view`, driven by tests without GL. `update`
   reports whether the view changed and the app redraws on that alone: the
   hook added no `needs_redraw` bookkeeping beyond acting on that answer.
   A toast at rest asks for one wakeup, when its time is up.
2. **Per-id memory: needed, but for less than expected.** Enter and leave
   progress turned out to be surface state (a phase with elapsed time).
   The table's one user is position memory: where a toast was drawn last
   frame, so the others glide when the stack changes. Focus and hover of
   the dialog also ended up in its state. Scroll offsets and text cursors
   (settings) are still expected to need it; the trial has no such widget.
3. **Pixel layout, one pass: holds for these surfaces.** Rows, columns,
   fit/fill/fixed and wrapping were enough. Missing and felt: an "at
   most" size (the dialog is a fixed 420 wide and would clip in a narrow
   window) and an offset for motion (added as `Tree.translate`).
   Hairlines stay one physical pixel at 125% and 150% (pixel tests).
4. **Two primitives: hold.** Boxes and glyphs in one instanced draw call
   covered everything, including the focus ring (a border) and icons
   (glyphs of an icon font). Shadows were left out by decision.
5. **Own theme: holds.** Dark and light render as approved; the variant
   follows the terminal background.
6. **Proportional font: holds with one change.** Inter's variable face
   cannot be kerned by FreeType 2.13.3 (measured), so three static faces
   ship instead. Pair kerning is kept: A V closes by 1.36 px at 18 px.
   Looking pairs up in FreeType every time was most of a frame's build
   cost until they were remembered (below). Glyphs Inter lacks come from
   the terminal's regular face; color emoji are not drawn.
7. **Motion: holds.** 200 ms ease-out for enter and leave; the glide is an
   exponential decay (40 ms time constant) because it needs one number
   per toast. No wakeups when nothing moves (measured below).
   `[ui] motion = none` makes every change instant.
8. **No dependency on `term/` or the driver: holds.** `src/kit/` imports
   neither.

Cost, ReleaseFast under Xvfb (software GL, so GPU draw time is not
representative and is left out), 10 s windows pinned to two cores, two
runs each:

| | Today's toast | Kit toast |
|---|---|---|
| Frames drawn, idle window (cursor blink only) | 21 | 21 |
| Loop wakeups, idle window | 95 to 108 | 106 to 108 |
| Extra frames for one toast (5 s) | 11 to 12 | 24 to 27 |
| Extra frames for three toasts | 19 | 44 to 61 |
| CPU time to build the UI part of a frame, one toast | 15 to 35 µs | 18.5 µs |
| The same, three toasts | 15 µs | 19.7 µs |
| Instances per frame, one / three toasts | 37 / 87 | 36 / 79 |

The kit draws about twice the frames per toast (the fades and the glide)
and none while a toast rests. Building a frame costs about what today's
toast costs. It took two fixes to get there, both found by measuring:
the hook asked the X server for the window size every frame (about
45 µs; it now uses the size the app caches), and layout measured the same
text several times with a FreeType kerning lookup per pair (63 to 94 µs
of a frame; pairs of printable ASCII and advances outside ASCII are now
remembered once looked up). Before them a frame cost 120 to 210 µs.

Memory: `KitOverlay` is 193,992 bytes, allocated once and only with the
switch on. Two tables make up nearly all of it: the font's kerning pairs
(five styles of 95 by 95 pairs, two bytes each) and the painter's 2048
instances of 36 bytes with its glyph position cache. `Node` is 104 bytes,
a toast entry 276, the dialog's state 446.
Nothing allocates in update, view, layout or paint.

Not checked: a real GPU, Wayland, fractional scales in a live window,
light theme in a live window.

**Accepted on this evidence** (maintainer, 2026-11-12), with four changes
to the draft, all in the text above: point 1 gained the sentence on
specific surfaces and shared parts, after the trial's dialog turned out to
be a confirm prompt and nothing more; point 2 no longer lists animation
progress and focus; point 3 names the missing "at most" size; point 6
says static faces. Decided with it: icons come from a bundled icon font
(Lucide), cards have no shadow, and `[ui] motion = none` turns motion off.

Open when this was accepted: nothing was measured on a real GPU, on
Wayland or at a fractional scale in a live window; color emoji are not
drawn in UI text; the theme's config key does not exist yet; the modal
frame, the button and the focus order are still inside the one dialog and
are pulled out when a second kind of dialog is built.
