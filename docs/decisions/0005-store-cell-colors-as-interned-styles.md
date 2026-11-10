# 0005: Store cell colors as interned styles that are never reused while referenced

- Status: accepted
- Date: 2026-11-10
- Deciders: Kbgjtn (maintainer)
- Tickets: #61

## Context

A cell is `packed struct(u64)` (`src/term/cell.zig:147`): codepoint 32
bits (grapheme IDs start at 0x110000 and use the whole field), kind 3,
flags 12, foreground 8, background 8, wrapped 1. All 64 bits are used.

`foreground` and `background` index a 256-entry `Palette` per screen
(`src/term/Palette.zig`): 0 is the default, 1-16 the ANSI colors, and
17-255 (239 slots) start as xterm colors 16-254 and are taken over by every
truecolor, and by an indexed color whose slot was taken. When all 239 are
used, `internDynamic` (`Palette.zig:161`) overwrites the oldest slot
round-robin. Every cell, pen (`cursor.attr`) and saved cursor holding that
index then shows the new color. The doc comment calls this acceptable
"until they are redrawn".

Measured on a real session (2026-11-10, capture of the Grok CLI, 130 s,
107x40): the program used 505 distinct truecolors and repaints only changed
cells. Replayed into a `Terminal` (throwaway test, not committed), no cell
was wrong until the palette wrapped. After that, 2,105 of 4,280 cells
showed a background the program never sent, and 4,253 of 4,280 at 80% of
the stream. The same happens in scrollback, and a cell drawn with
`38;5;16` changes color once an RGB color takes slot 17.

Other forces:

- Index holders per screen: `cells` (the primary screen's ring holds the
  active rows and the scrollback: by default 4,096 rows x 220 columns,
  901,120 cells, 7.2 MB), `cursor.attr`, `saved_cursor.attr`. The
  alternate screen has no scrollback.
- The worker publishes a `Frame` that copies `palette` and the visible
  cells (`src/term/Frame.zig:146`); graphemes are copied as a small table
  of only the IDs the viewport uses (`max_frame_graphemes = 256`).
- Graphemes already solve the same lifetime problem by mark-and-sweep over
  `cells`, with the next sweep at twice the live count
  (`compactGraphemes`, `src/term/screen.zig:661`).
- The underline color (SGR 58) lives only on the pen; a cell has no room
  for it (`cell.zig`, `Attr.underline_color`).
- `src/term/Style.zig` was an unused 16-byte placeholder (fg, bg,
  underline as `Color`, flags, link).
- `Screen` has `ext_attrs` (a map from `(row, col)` to an underline
  palette index and a URL ID) and `url_table`, declared, cleared and
  freed but never written or read (`screen.zig:368-369`). OSC 8 is not
  implemented. Keyed by coordinate, they would also drift from their text
  on scroll and reflow.
- Performance rules: flat 64-byte-aligned cell buffers, no allocation in
  resize, reflow, scroll or render.

## Decision

Replace the cell's two 8-bit palette indexes with one 16-bit style ID, and
keep the flags in the cell. The cell stays 64 bits: codepoint 32, kind 3,
flags 12, style 16, wrapped 1.

Each screen owns a style table (`Style.Table`; `Style.zig` is the 12-byte
value, with the table and `Style.Id` nested in it). An entry holds the
foreground, background and underline colors as encoded `Color` keys
(default, indexed 0-255, or RGB). Indexed colors still resolve through
`Palette.indexed` when drawn, so OSC 4/104 and theme changes keep
working. ID 0 is the default style and is never stored. The unused
`ExtAttr`, `ext_attrs` and `url_table` are removed: the underline color
lives in the style.

**The pen.** The cursor's pen keeps its colors as a `Style` (the source
of truth) plus two cached IDs into its screen's table: `id` for the full
style and `blank_id` for the background alone. SGR updates the colors
parameter by parameter and interns once at the end of the sequence, at
most twice (full and background-only), so the cell-write path has no
staleness check. Writing a character copies `id`. Writing a blank
(erase, background color erase on scroll and insert/delete, splitting a
wide character) uses `blank_id`, so blanks keep the default foreground
and no underline color as they do today; splitting a wide character
interns the background-only style of that cell. The saved cursor
(DECSC) stores colors, not IDs; DECRC re-interns them. RIS and entering
the alternate screen reset the pen to the default style.

**Invariant:** an ID referenced by any cell or the pen of its screen keeps
its colors. IDs are reclaimed only by mark-and-sweep over those holders
(as `compactGraphemes` does), run when the table is full. After the
screen drops content (erase display, clearing scrollback) the owner calls
`requestSweep`, so the next miss sweeps at once. RIS and entering the
alternate screen leave only default cells and call `reset` instead.
If a sweep leaves the table full, a new style gets the nearest live style
from a sample of at most 256 entries, and the next sweep waits for 2,048
more misses, so a flood of new styles (an image) costs one sweep per
2,048 styles. Text already on screen never changes color.

**Capacity: 16,384 styles per screen** (IDs 1-16,383; ID 0 is the
default). The frame copies the table by ID, so the screen table and the
frame table share this cap. At 12 bytes per entry (measured, stage 2)
that is 192 KiB per frame, 768 KiB for the worker's local frame and the
three triple-buffer slots. The 16-bit field leaves room to raise the cap later without a
layout change. Chosen by the maintainer on 2026-11-10 over 65,535
(4 MiB of frame tables), which only pays off for scrollback full of
photographs.

Because IDs are stable while referenced, the frame copies the screen's
style table (up to `high`) when the table's `generation` differs from the
one the frame holds, and copies cells unchanged, so the existing copy of
dirty rows only stays valid. Each triple-buffer slot records the
generation it holds, so `copyFrom` copies the table only for a slot that
is behind. The frame's table is preallocated at full capacity, so
publishing never allocates.

**Underline color starts working.** SGR 58 is stored on the pen today but
never reaches a cell or the renderer, so it has no visible effect. With
the color in the style, each cell carries it and `renderer/Decoration.zig`
draws it. This is a visible behavior change.

## Measurements (2026-11-10, stage 1)

Throwaway microbenchmarks with the proposed 64-bit cell layout (not in the
repo), ReleaseFast, pinned to one core of a Ryzen 3 3300X, boost on, best
of 30-50 runs, two runs agreed. Isolated loops, not the real terminal;
real costs will be checked again in stages 2-4.

| What | Result |
|---|---|
| Sweep (mark pass) over the default ring, 901,120 cells, 500 / 4,096 / 65,535 live styles | 0.50 / 0.48-0.51 / 0.48 ms |
| Plain copy of a full 200x220 viewport of cells (today's snapshot work) | 6 µs |
| (a) Copy and remap IDs to a frame-local table, 500 / 4,096 / 65,535 live | 42 / 69 / 209 µs |
| (b) Copy and resolve an RGB pair per cell | 190-236 µs, +343 KiB per frame |
| (d) Copy the style table, 500 / 4,096 / 32,768 / 65,535 entries | 0.08 / 0.9 / 9.3 / 19 µs |

Distinct styles in real use: the Grok capture printed text with 604
distinct (foreground, background) pairs from 505 colors over 130 s. A
truecolor half-block rendering of a mostly flat UI screenshot at 220x200
cells used 4,861 pairs; a photograph approaches one per cell (up to
44,000 on one full screen).

Findings:

1. **Frame transfer: (d), copy the table when it changed.** (a) and (b)
   cost 7 to 40 times today's whole snapshot copy on every full-screen
   snapshot, and (a) changes local IDs between snapshots, which breaks
   the copy of dirty rows only. (d) costs under 1 µs at realistic sizes
   and only when SGR added a style (about 9 µs at the full 16,384, by
   the 32,768-entry measurement halved; entries were 16 bytes there, 12
   now). Cost: a 192 KiB table per frame at the chosen cap, preallocated
   for the worker's local frame and the three triple-buffer slots
   (768 KiB), next to 352 KiB of cells per frame today. A 65,535 cap
   would need 3 MiB.
2. **Sweep: 0.5 ms**, run when the table is full, on the worker
   thread. The Grok session would never sweep (604 styles under any
   reasonable first threshold).
3. **Saturation:** at 16,384, programs like Grok (604 styles) stay far
   below the cap; one full screen of a photograph (up to 44,000) or
   scrollback holding images can reach it, and then new styles take the
   nearest live style. Old text never changes. Accepted as the limit.
4. **Storage and allocation (stage 2).** Fixed capacity, allocated once
   when the screen is created: entries (12-byte `Style`, 192 KiB), an
   open-addressing index at most half full (64 KiB) and a free list
   (32 KiB), 288 KiB per screen. `intern` never allocates, so SGR cannot
   fail on memory, and a sweep rebuilds the index, so it has no
   tombstones.
5. **Flags stay in the cell.** Moving the 12 flag bits into the style
   would not shrink the cell (the rest is 52 bits; 48 would need a
   smaller codepoint field, which grapheme IDs use in full). It would
   multiply distinct styles by every bold, italic, underline and blink
   combination, make SGR 1/22 intern a new style, and move 29 direct
   readers (`sgr.zig`, `renderer/Frame.zig`, `Decoration.zig`) and the
   blink scan behind a lookup. Revisit only when a feature needs those
   bits.
6. **SGR intern cost (stage 2).** Replaying the Grok session's 40,802
   pen changes (ReleaseFast, pinned, best of 20, two runs agreed): the
   current palette takes 39-40 ns per pen change (two interns, each a
   linear scan of 239 slots for an RGB color), the style table 2.8 ns
   (one hash lookup), with 605 styles at the end.

## Extending the style

Anything about how a cell's text looks or links can join the entry
without changing the cell layout. OSC 8 links would add `link: u16`, an
index into a per-screen URL table; the same mark pass then frees unused
styles and unused URLs together, with no second lifetime mechanism and
no coordinates. Each addition costs more distinct styles (every link is
its own style) and a larger entry (a link makes it 16 bytes: frame tables
768 KiB to 1 MiB, screen table 288 KiB to 352 KiB). The 16-bit ID allows
raising the cap to 65,535 by a constant. Links are not part of this
decision; OSC 8 gets its own ticket.

## Alternatives considered

**A. Sweep the existing 8-bit palette before reuse; nearest color when
full.** No layout change, small diff. Rejected as the long-term model: 239
live colors per screen is too few for truecolor programs and scrollback,
so heavy use degrades to nearest colors; it only moves the limit.

**C. RGB in the cell.** Cell grows to 16 bytes, doubling grid memory
(7.2 MB to 14.4 MB per primary screen by default) and copy bandwidth in
snapshot, scroll and reflow. Rejected under the performance rules.

**D. A bigger round-robin table.** Same bug, later. Rejected.

**E. Reference counts instead of mark-and-sweep.** Frees eagerly, but adds
two counter updates to every cell write and erase, the hottest path.
Mark-and-sweep costs nothing on writes and is already used for graphemes.
Not chosen: the measured sweep is 0.5 ms, run only when the table is full (see Measurements).

**Prior art** (research of nine terminals at pinned tags, 2026-11-10).
Only Ghostty (v1.4.0) keeps a 64-bit cell with truecolor and never
recolors: its `Cell` is `packed struct(u64)` with a `u16` `style_id` into
an interned style set per page, freed by reference counts. The
ref-counted set's doc comment was checked verbatim at commit
83fb956 ("Items with 0 references will be kept until another item is
written to their bucket"); the cell layout was checked from a summary of
the same file, not verbatim. Ghostty pays for refcounts with a release and
a use on every cell overwrite that changes style, page growth and splits
when a set fills, and a fall back to the default style; its tracker shows
crashes, runaway memory and degraded styles in this area before fixes in
early 2026 (PRs 8277, 10251, 10337, issue 10258). Every other terminal
stores colors in each cell: foot 12 bytes, st 16, VTE 20, Alacritty and
WezTerm 24, xterm about 28, kitty 32. No surveyed terminal reuses palette
slots round-robin, and none compacts a shared table by mark-and-sweep;
this decision's sweep is therefore new, and its cost is the measured
0.5 ms over the ring. Ghostty also stores the color of cells that hold no
text directly in the cell (content tags `bg_color_palette` and
`bg_color_rgb`), so runs of colored spaces need no style entry; here the
32-bit codepoint of an empty cell could hold a `Style.Key` the same way,
which would remove `blank_id`. Noted as a follow-up, not part of this
decision.

## Consequences

- Fixes recoloring of old text on screen and in scrollback: old text never
  changes color; up to 16,384 live styles per screen keep their exact
  colors, beyond that new text gets the nearest live style. Also fixes
  indexed colors changing when truecolors arrive.
- Gives each cell its own underline color (today pen-only).
- Breaking internal change: `Cell.foreground`/`background` become `style`;
  every reader changes (about 30 sites in `src/term/screen.zig`,
  `src/renderer/Frame.zig`, `src/renderer/Selection.zig`, tests).
  Background color erase (`eraseLine` and friends) writes the pen's style
  ID instead of its background index.
- `Palette` keeps defaults, the 16 ANSI and 256 indexed colors and OSC
  4/10/11; its dynamic slots and `next` go away.
- Memory: 288 KiB per screen, allocated once (entries, index, free
  list), 576 KiB for both screens; 768 KiB of preallocated frame tables.
  Typical sessions use a few hundred entries.
- Cost: one 0.5 ms sweep each time the table fills (at most one per
  2,048 new styles while it stays full); nothing extra on cell writes;
  SGR interning 14 times cheaper than the palette it replaces; a table
  copy (under 1 µs typically, about 9 µs at the cap) on snapshots after
  SGR added styles.
- Measured at acceptance (2026-11-10), rebased onto `develop` `dfe1bde`,
  whose own `memset` made the baseline faster: `bench-term` corpus
  `feed_once`, ReleaseFast, pinned, 8 runs each, median: htop +10.9%
  (64.8 to 71.8 µs), ls_color +4.4%, man_bash +6.3%, against +3-5% before
  that change. `Style.Table.intern` takes 5.3% of the htop run
  (`Palette.intern` took 1.5%); the rest of the gap is in the parser and
  CSI dispatch and may be code layout (#79). Accepted for the correctness
  fix; recovering the cost is #80.
- Follow-up: the reflow and resize paths must keep IDs as they move cells
  (they do today, since IDs are plain cell bits).

## Plan (stages, each approved separately)

1. Measurements (done above), prior-art notes, and this ADR accepted.
2. `Style` and `Style.Table` in `term/` with tests, not used yet
   (done: intern, sweep, nearest, `generation`, `reset`,
   `requestSweep`).
3. Switch over, in one stage since the cell field and its readers change
   together:
   - `Cell`: `style: Style.Id` replaces `foreground`/`background`.
   - Pen (`Attr`): colors as `Style` plus `id` and `blank_id`; SGR
     interns once per sequence, only when the colors changed;
     `Cursor.Saved` stores flags and colors, not IDs. Measured (3a):
     `Attr` 8 to 20 bytes (2 of padding), `Cursor` 20 to 32,
     `Cursor.Saved` 20 to 28, `Cell` stays 8.
   - Every writer (characters, erase, background color erase, wide
     splits, reflow) and reader (`renderer/Frame.zig`,
     `renderer/Selection.zig`, `Decoration.zig` for the underline color).
   - Sweep marking over the ring and the pen; `reset` on RIS and on
     entering the alternate screen; `requestSweep` after ED 2/3 and
     clearing scrollback.
   - Frame: a preallocated style table copied by `generation`.
   - `Palette`: dynamic slots and `next` removed; it keeps the defaults,
     the 256 indexed colors and OSC 4/10/11/104.
   - Remove `ExtAttr`, `ext_attrs`, `url_table`; the stale comments in
     `Cell` and `Palette`. The cursor shape type keeps its name
     `Cursor.Style` (DECSCUSR's own term; it already nests a `Shape`
     enum): the pen's colors live in `Attr.colors`, so no name clashes.

   3c is done: `Palette` slots and `ExtAttr` removed, the
   `cell.CursorStyle` alias removed, a fuzz invariant (every cell's and
   the pen's style ID is live; 208K `terminal` and a `strings` run, no
   crash), and two fixes found by `bench-term`. On a busy machine the
   first run showed htop +25%, ls_color +9-10%, man_bash +2% against the
   branch base; `perf` traced it to interning default colors out of line
   (now short-circuited in `internPen`) and to `Style.Table.reset`
   clearing its 64 KiB index on every alternate-screen entry (now it
   clears only live slots below 1/16 full). After: htop +3-4%, ls_color
   +3-6%, man_bash +1.6-2.5% best against best, with baseline runs
   varying up to 70%, so not settled. What remains is one hash per SGR
   that sets a non-default color. A two-entry cache of recent styles was
   tried and made htop slower (+6.5-9%), so it was dropped.

   Quiet machine (2026-11-10, maintainer away, three A/B pairs pinned to
   CPU 2, ReleaseFast, Tctl under 59 C; runs agree within 1-3%):
   `bench-term` against the branch base `abc31e2`: htop +4.4 to +5.6%,
   ls_color +3.0%, man_bash +0.1 to +0.8% (noise). That is the one hash
   per SGR that sets a non-default color; output dense in ANSI colors
   pays 3-5%, plain styled text nothing, truecolor-heavy output gains
   (interning is about 14 times cheaper than the palette's scan).
   `LATENCY_KEYS=1000 scripts/perf-gui.sh ReleaseFast`, base then branch,
   all keys matched: picked -> built median 92.9 to 88.8 us quiet and
   190.6 to 181.6 us loaded; built -> drawn and key -> swapped unchanged
   within noise (quiet 227 to 224 us, loaded 3.31 to 3.34 ms). Runs
   `gui-20261110T192557_abc31e2` and `gui-20261110T192823_2265a5e`.

   Split into checkpoints. 3a (term core, frame table copy by
   `generation`, the renderer's color reads) is done: the Grok capture
   replays with 0 of 4,280 cells showing a background it never sent at
   every tenth of the stream (up to 4,253 before). 3b: SGR 58 drawn by
   `Decoration.zig`; renderer frame-build time before and after. 3c:
   `Palette` slots and `ExtAttr` removed, stage 4 tests, benches.
   Known limit kept from graphemes: the sweep marks the whole ring, so
   scrollback cleared by ED 3 (hidden but not wiped) keeps its styles
   alive until scrolling overwrites it. Safe, never frees a used ID.
4. Regression tests: old text keeps its color after 70,000 new styles;
   indexed colors survive truecolors; blanks keep the default
   foreground; the saved cursor's colors survive a reset and a sweep;
   alternate-screen round trips keep primary styles; nearest-style when
   full changes no existing cell; a Grok-shaped synthetic replay; a
   fuzz invariant in the `terminal` target (every cell's style ID is live
   in its screen's table). Bench before and after (`bench-vt`, SGR-heavy
   corpus) and `perf-gui.sh`.

Candidates found in the audit, measured before any change and not part
of this decision: copying the palette only when it changed (today about
2.6 KB per snapshot, twice); skipping the snapshot's grapheme scan when a
screen has no graphemes; resolving each style to RGB once per table copy
instead of per cell per frame. Separate tickets: OSC 4/10/11/104 apply to
the active screen only (xterm applies them to the terminal); DECRQSS is
not implemented; `max_frame_graphemes = 256` drops clusters beyond it.
