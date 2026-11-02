# Terminal Layer — Design v4

Status: plan, partly implemented. Supersedes TERMV3.md. Anything marked
**verify** is from memory of DEC/xterm behaviour; check xterm ctlseqs,
the DEC STD 070 / VT510 manual or esctest before you encode it.

Grounded in a review of `feat/term` at 5f0d886 plus the uncommitted
parser rewrite (2 Nov 2026).

## 1. Goal and non-goals

Goal: one xterm-compatible terminal core that runs shells, vim, tmux,
htop, less and fzf correctly, stays correct when the input is split at
any byte, never crashes on hostile input, and keeps the vt parser's
current throughput.

Non-goals for v4: a VT52 mode, a DECSCL level ladder, 8-bit C1 output,
sixel, kitty graphics, the kitty keyboard protocol, left/right margins
(DECSLRM), rectangular ops, and reuse as a standalone "ANSI events"
library. These go to section 7 (later/maybe).

## 2. Architecture

```
PTY bytes ─► Terminal.feed(bytes)            src/term/term.zig
               │  UTF-8 decode + grapheme hold (inside print path)
               ▼
             vt.Parser(Terminal, .{})         src/vt/parser.zig
               │  print / execute / csiDispatch / escDispatch
               │  oscStart|Put|End / hook|dcsPut|unhook
               ▼
             dispatcher (proto: decode)       src/term/dispatcher.zig, sgr.zig
               ▼
             Screen ops (mutate grid)         src/term/screen.zig
               │  ring buffer, cursor, margins, tabs, dirty rows
               ▼
             replies ──► App writes to PTY    term.zig Events.response
             dirty/generation ──► renderer    same thread today (app.zig)
```

Terminal is the parser's Handler (kept from v3). The parser decides
state transitions on raw bytes. Terminal owns UTF-8 decoding and hands
the parser only bytes that are safe to interpret as controls.

## 3. Key decisions (locked)

1. **One merged `Terminal(option)`, which is the parser Handler.** It
   avoids an extra call layer on the hot path, and term.zig already
   works this way.
2. **proto decodes, ops mutate, the screen knows only grids.**
   Sequence decoding (dispatcher, sgr) never touches cells directly.
   This keeps the screen testable without ANSI.
3. **Design the screen model first (M1).** Scrollback, resize and wide
   characters at the right edge dictate the cell and row layout. The
   current bugs cluster there.
4. **Single thread today, a snapshot boundary later.** App drains the
   PTY, feeds, writes replies and renders on one thread with no lock
   (app.zig main loop). v4 keeps that. If threads come (the plan noted
   in app.zig), the PTY thread owns Terminal and publishes a snapshot.
   The renderer never reads a live Screen.
5. **Comptime switches only compile features out.** `Option`
   (max_rows, max_cols, max_scrollback, tab_width) and feature removal
   such as `osc52` stay comptime. Everything an app or the user can
   change (modes, palette, encoding, cursor style, OSC 52 permission)
   is runtime state or a runtime `Config`.
6. **One xterm profile.** DA1 and DA2 answer as xterm-like. There's no
   `ConformanceLevel` ladder and no VT52. The `decscl` and `caps.zig`
   DECSCL machinery goes.
7. **UTF-8 decode lives in the print path. The parser sees raw bytes
   for the C1 decision.** In UTF-8 mode, 0x80–0x9F are never controls.
   In ground they go to the decoder; in string states they're payload
   (term.zig already bypasses this way: `inStringState` → `feedData`).
8. **Grapheme split rule.** Hold the last cluster until the next
   feed's first codepoint decides the break, a control or ESC arrives,
   or `end()` is called. A combining mark after an ASCII or other
   fast-path base attaches to the previous cell and is never dropped.
9. **Lossless `ParamCursor`.** It iterates `[]Parameter` and keeps `;`
   vs `:` separators. Omitted vs explicit 0 stays open (section 5)
   until a real sequence needs it.
10. **Bounded reply queue, in-order, drop-whole-reply when full.**
    Replies are appended in the order the queries were parsed. A
    reply that doesn't fit entirely is dropped (never truncated
    mid-sequence) and a `replies_dropped` counter increments. The
    host drains it after every `feed` call. The capacity is a
    comptime Option, defaulting to 1 KiB.
11. **Tests are golden: bytes in → screen snapshot + replies, split at
    every boundary.** Parser-level op recording stays (parser_test.zig
    Recorder). There's no RecordingTerm.

## 4. Milestones

Status values: done, partial or todo, judged on code at 5f0d886 plus
the working tree.

### M0 — Consolidate and make the suite honest (todo)

Scope:
- Land the parser rewrite (vt/parser.zig, parser_test.zig) and delete
  term/parser.zig.
- Delete the orphans of the deleted parser: term/osc.zig and
  term/csi_test.zig. Both import "parser.zig" and are compiled by
  nothing.
- Pick screen.zig as live. term.zig, dispatcher.zig and root.zig use
  it. screen_v2.zig is only used by its own tests and
  bench/cases/term. Either fold v2's `row_map_state` union and fill
  paths into screen.zig in M1, or delete v2. Don't keep both.
- Delete dead copies: src/.dump/, src/term_v1.bak/,
  src/renderer/renderer_v1.bak/, src/vt/dump.bak,
  src/term/nfc_table.zig.bak and scripts/perf-bench.sh.bak. Nothing
  imports them. They're untracked, so check that nothing in them is
  needed first.
- Track the real sources. Most of src/ (term.zig, screen.zig,
  dispatcher.zig, cell.zig, app.zig…) is untracked in git.
- Re-enable the disabled suites and fix their API drift:
  - screen_test.zig: 427 tests, 12 shadowing errors on `cell`.
  - dispatcher_test.zig: 274 tests. Errors include `testing.alloc`,
    removed `ConformanceLevel` names and `Kind` vs int.
  - term_test.zig: 38 tests. It compiles, and 1 fails.
  - parser_fuzzy_test.zig: stale `Parser(H)` / `feed` API.
- Fix the wrong expectation in screen_v2_test.zig:513. physRow masks,
  so the right value is `(ring_mask + 4) & ring_mask`.
- Remove the duplicated parser tests ("exactly max_params …" and
  "digits after dropped separator …" each appear twice).

Files: src/vt/parser.zig, src/vt/parser_test.zig,
src/vt/parser_fuzzy_test.zig, src/term/{osc.zig, csi_test.zig,
parser.zig, screen_v2*.zig, screen_test.zig, dispatcher_test.zig,
term_test.zig, screen.zig, term.zig, dispatcher.zig, root.zig}.

Done when:
- `zig build test` is green with the screen, dispatcher, term and
  fuzzy suites wired in.
- No file in src/ imports a missing file.
- Exactly one Screen implementation exists.

### M1 — Screen model (partial)

Today:
- A ring of `ring_rows = nextPow2(max_rows + max_scrollback)` rows ×
  `max_cols` cells, with 8-byte packed `Cell`s, allocated once.
- With the app's option (208×220, 3888 scrollback) that's
  4096×220×8 ≈ 6.9 MiB per screen.
- The alternate screen gets the same scrollback ring (term.zig:334
  FIXME), so ≈ 13.8 MiB total.
- Region scroll uses a row_map permutation.
- There's no reflow on resize.

Scope:
- Write down the memory budget and give the alternate screen
  `max_scrollback = 0`. That needs a second Screen type or a runtime
  ring size.
- Choose the resize behaviour: truncate or reflow. Recommendation:
  truncate in v4, with soft-wrap flags per row so reflow can come
  later.
- Define wide and grapheme behaviour at the right edge:
  - DECAWM on: a wide char at the last column blanks that cell and
    wraps.
  - DECAWM off: it must not wrap. Behaviour is **verify**; xterm
    overwrites in place.
- Attach combining marks to the previous cell, including after ASCII
  and fast-path bases. This needs grapheme storage on the previous
  cell, not only an NFC compose.
- Decide grapheme intern lifetime. Today the table is reset only by
  ED 2. Reset on RIS too and cap its size.
- Free `ext_attrs` and `url_table` in `destroy`.

Files: src/term/screen.zig, cell.zig, term.zig (feedCodepoint and
flushGrapheme), grapheme.zig, nfc_table.zig.

Done when, as golden tests:
- `e` + U+0301 → one cell holding é, in both split and unsplit feeds.
- `CSI ?7l` + 30 × `A` on 24 columns leaves the cursor on row 0, with
  the last cell `A`.
- A wide char at the last column with DECAWM off stays on the row.
- Resize keeps the cursor and margins valid.
- The alternate screen allocates no scrollback.

### M2 — Correctness and crash fixes found in review (todo)

Scope:
1. `Events.Response.len` is a `u8` over a 256-byte buffer.
   `append`, `appendHex` and `print` overflow it. 60 × `CSI 6 n` in
   one read panics (reproduced). Replace it with the bounded queue
   from decision 10.
2. `cursorUp` (screen.zig:2109) underflows when origin mode is on and
   the cursor row is above `scroll_top`. Reproduced with
   `CSI 2;10r CSI ?6h ESC 7 CSI 6;11r ESC 8 CSI A`. Clamp in
   `restoreCursor` and in `cursorUp`/`cursorDown`.
3. `putCharsFast` wraps even when DECAWM is off (screen.zig:830).
   Reproduced.
4. `writeChar`'s wide-at-end path wraps when DECAWM is off
   (screen.zig:955). Reproduced.
5. CAN/SUB inside OSC still runs `oscEnd`, so the title gets set
   (reproduced). The exit action fires on any exit from
   `osc_string`. xterm aborts there (**verify**). Add an abort path:
   the exit action fires only on BEL/ST/ESC-\\.
6. ESC inside OSC fires `oscEnd`; then `ESC \\` dispatches ESC `\\`
   (harmless), while `ESC BEL` rings the bell. **verify** against
   xterm.
7. DECSTR: screen.zig:2664 resets `cursor_blink` but term_test
   expects it to survive. Decide from the DEC STD 070 DECSTR table
   (**verify**: does DECSTR also clear DECAWM? does it touch
   DECSCNM?).
8. Pending-grapheme ordering: in `feedUtf8Byte`, an ASCII printable
   byte arriving after a rejected partial sequence doesn't flush the
   held cluster, so it lands before the cluster. Flush on every
   ASCII byte.

Files: src/term/term.zig, screen.zig, dispatcher.zig, vt/parser.zig
(table abort entries).

Done when each item has a golden test that failed before the fix.
Fuzz (parser_fuzzy_test via `std.testing.Smith`) runs feed on random
bytes with no panic in Debug.

### M3 — Proto layer: ParamCursor, CSI routing, replies (partial)

Today, `dispatcher.paramOr` skips sub-params, and the CSI key is
`intermediates[0] << 8 | final`, so a marker plus an intermediate
collapses into one key (for example DECRQM `CSI ? Ps $ p` falls to
`else`).

Scope:
- Add `ParamCursor`.
- Route on (marker, intermediate, final).
- Answer DECRQM for the modes in M4.
- Use the reply queue for DA1, DA2, CPR, DSR, XTVERSION and OSC
  10/11/12 queries.
- Add an unhandled-sequence counter and optional trace hook.

Files: src/term/dispatcher.zig, sgr.zig, term.zig. Add a new
`src/term/param.zig` only if dispatcher.zig grows past one screen of
routing.

Done when:
- SGR `38:2::r:g:b` and `38;2;r;g;b` both produce the same colour
  (golden).
- DECRQM `?2026` replies.
- The reply-order golden passes: 3 queries in one feed → 3 replies in
  order.

### M4 — App-essential modes (partial)

| mode | state today |
|---|---|
| 2004 bracketed paste | flag stored (term.zig `setDecMode`); paste wrapping unverified |
| 1000/1002/1003 mouse, 1006 SGR | stored; `sendMouse` exists |
| 1004 focus | flag stored; app sending focus events unverified |
| 2026 sync output | flag stored, **never read** by app/renderer |
| DECSCUSR `CSI Ps SP q` | done (`setCursorStyle`) |
| 1049 alt screen | done |
| OSC 0/2 title | done |
| OSC 8 hyperlinks | todo (`ext_attrs`/`url_table` exist, OSC 8 not dispatched) |
| OSC 52 clipboard | todo (`52 => {}`), must be runtime-gated, read denied by default |

Files: src/term/term.zig, dispatcher.zig, screen.zig (hyperlink attr),
src/app.zig (sync gating, paste and focus emit).

Done when:
- Each row has a golden test (bytes → state + reply).
- The renderer skips frames while 2026 is set, with a timeout. The
  xterm/contour convention is about 1 s (**verify**).
- vim, tmux and htop pass a manual smoke test.

### M5 — Golden harness (partial)

Today: parser_test.zig has split-offset parity tests. There's no
screen-snapshot golden yet.

Scope:
- Add a helper that takes `input`, `expected_rows` (text plus attr
  markers), `expected_cursor` and `expected_replies`.
- Feed the input whole, then split at every byte offset, then in
  random 1–256-byte chunks, and assert identical snapshots.
- Seed vectors from esctest and vttest cases.

Files: a new src/term/golden_test.zig (justified: no current home for
cross-module goldens), referenced from term.zig's test block.

Done when there are 50+ vectors covering M1–M4 and all splits are
green.

### M6 — Performance (measure first)

Vt baseline (BENCHMARKS.md, 234161b, Ryzen 3 3300X, feed_once): ls_color
488.56 µs, man_bash 242 µs, htop 29.02 µs, plain_ascii_64k 913 ns,
plain_lines_64k 8.62 µs, sgr_normal 30.58 µs, osc_title 12.79 µs,
dcs_passthrough 20.8 µs.

Target: no case regresses by more than 5% after the rewrite lands
(compare with `scripts/perf-compare.sh`).

Term: there is no term baseline. bench/cases/term/screen.zig
(physRow/*, fillRows/*, fillRowsFast/*) targets ScreenV2 and is
commented out in bench/cases/root.zig. Measure first:
- Wire the cases to the live Screen.
- Add end-to-end `Terminal.feed` cases on the existing corpus
  (ls_color, man_bash, htop) and plain_lines_64k.
- Record a baseline, then set targets.

Known hazards to measure:
- In string states, the residue loop goes byte-by-byte after the
  first ignored C0 or DEL until the state exits.
- In Latin-1 8-bit mode, 0xA0–0xFF print one byte per call.
- `repeatChar` calls `writeChar` once per repeat.

## 5. Open questions (genuinely open)

- **Omitted vs explicit 0** (`Parameter.present`): add it only if a
  supported sequence differs. Settle it by grepping xterm ctlseqs for
  sequences where Ps=0 ≠ default.
- **CAN/SUB in OSC/DCS: abort vs dispatch.** Settle it with an
  esctest-style vector run in xterm (`OSC 2;x CAN`, then query the
  title).
- **DECSTR reset set** (blink, DECAWM, DECSCNM). Settle it with the
  DEC STD 070 table and xterm `ReallyReset(soft)`.
- **Resize: truncate now, reflow later?** Settle it by whether tmux and
  vim misbehave on width shrink in manual tests. Soft-wrap flags land
  in M1 either way.
- **Grapheme intern cap and eviction.** Settle it with a scrollback
  stress test that measures table size after `cat` of an emoji corpus.

## 6. What changed vs v3

| v3 | v4 |
|---|---|
| Build order data-first (caps → skeleton → ops) | M0 cleanup, then screen model first |
| `Terminal(caps, cfg)` both comptime | comptime only for compiling out; Config and modes at runtime |
| Profiles (`vt52`…`xterm`) with level ladder, DECSCL | one xterm profile; ladder and VT52 moved to later/maybe |
| `ingest` decodes before the parser | decode inside the print path; parser keeps raw-byte C1 decision |
| Grapheme split across feeds "must be pinned" | rule fixed: hold last cluster until next codepoint/control/`end()` |
| Reply queue bounded, policy unstated | in-order, drop whole reply, counter, drain after each feed |
| Threading not covered | single-thread today (app.zig), snapshot boundary if threads land |
| RecordingTerm + corpus.zig | golden bytes → snapshot + replies at every split; parser Recorder kept |
| New tree `ops/`, `proto/`, `encoding/` up front | grow real files; new file only when one is justified |
| No app-mode list | explicit table (2004, mouse, 1004, 2026, DECSCUSR, OSC 8, 1049, OSC 0/2, OSC 52) |
| No perf targets | vt: ≤5% vs 234161b; term: measure first, cases named |

## 7. Later / maybe

VT52, DECSCL levels and 8-bit C1 output (S8C1T), DECSLRM margins,
rectangular ops, sixel and kitty graphics (APC is swallowed today),
kitty keyboard, reflow, a standalone proto library extraction, and
DECRQSS/XTGETTCAP (the dcs_buf stubs in term.zig `unhook`).

## M0 status (2026-11-02)

Done: dead copies removed, `screen_v2` dropped, term parser folded into
`vt/parser.zig`, screen/dispatcher/term/fuzz suites revived (skips mark
the M2 items below), struct files renamed to TitleCase.

### M2 additions found while reviving tests

9. `Screen.scrollDown` full-screen path calls
   `wrapAdd(scroll_offset, ring_rows - count)`, which violates
   `assert(b <= max_rows)` whenever scrollback is enabled. RI / SD at
   the top row panics in Debug/ReleaseSafe. 17 screen tests skipped.
10. DECXCPR reply (`CSI ? 6 n`) omits the `?`: must be `CSI ? r ; c R`.

### M1 note: ideas from the deleted screen_v2 worth porting

- `row_map_state` tagged union (identity / region_offset rotation /
  permutation) for cheap partial-region scrolling.
- vectorized `fillRows` / `fillRowsFast` / `fillPhysicalRows`.
Both are recoverable from commit m04 (`git show <m04>:src/term/screen_v2.zig`).
