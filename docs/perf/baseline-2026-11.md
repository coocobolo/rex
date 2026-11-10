# Performance baseline before the architecture revamp (2026-11-06)

Reference numbers for judging the revamp. Everything below was measured on
commit `cc4c6b2` (`develop`, clean tree).

## Environment

| | |
|---|---|
| CPU | AMD Ryzen 3 3300X, 4 cores / 8 threads, governor `performance`, **boost enabled** |
| GPU | NVIDIA GeForce GTX 1650 SUPER, driver 595.99.02, OpenGL 4.6 |
| Display | 2560x1440 at 165 Hz, X11 session, Rex window 1920x1080 |
| OS | Ubuntu 24.04 (Mesa 25.2.8 also installed) |
| Zig | 0.16.0 |

CPU boost was on for all runs. It increases run-to-run variance, so small
deltas (under about 5%) should not be read as real differences.

## 1. Parser and terminal benchmarks (`scripts/perf-bench.sh`)

ReleaseFast, `-Dcpu=native`, pinned to CPU 2, 5 timing repeats. 91 cases:
63 in `vt` (parser) and 28 in `term` (reflow, scrolling). Blessed as
`perf-results/baselines/0002-cc4c6b2-pre-revamp.jsonl`; that file holds the
per-case numbers.

Compared with the previous baseline (`0001-234161b-init`, 2026-10-19, which
was recorded from a dirty tree and covers only `vt`):

- `term` has no earlier baseline; this is its first.
- `vt` deltas are mixed: `osc_title` is 4-15% faster; `htop` and `sgr_*` are
  4-16% slower; most other cases are within noise.
- **`vt.man_bash` and `vt.dcs_passthrough` changed checksum in every
  variant.** Investigated later (2026-11-07). Both change at `10f6aa1`
  (fix(vt): keep a dcs string hooked after esc), measured with each commit's
  own bench from `abbc3d6` on. Earlier commits can't be measured: at `234161b`
  the committed parser doesn't compile and the bench build step, `src/root.zig`
  and the term suite weren't in git, so baseline 0001's vt checksums can't be
  reproduced.
  - `dcs_passthrough`: intended. `ESC \` closing a DCS no longer also
    dispatches a separate ESC final, as in xterm.
  - `man_bash`: a flaw in the benchmark, not in Rex. It fed raw UTF-8 to
    `vt.Parser`, which needs decoded input and treats 0x80-0x9F as C1
    controls, so the 0x90 ending every `‐` (U+2010) opened a false DCS. Its
    timings measured input Rex never gives the parser. `htop` had one such
    character (`▽`).
  - Since then the vt suite takes ASCII-only corpora (`ls_color`) and refuses
    others, and all three captures run through Terminal as
    `term.corpus.{ls_color,htop,man_bash}`. Compared with this baseline,
    `vt.htop` and `vt.man_bash` are missing and the `term.corpus` cases are
    new.

Known issue: `perf-bench.sh` builds with `zig build`, which doesn't install
the benchmark binary. This run built it first with `zig build benchmark
-Doptimize=ReleaseFast -Dcpu=native`.

## 2. Running application (native GL driver)

Measured with `scripts/perf-gui.sh` at `cc4c6b2` (ReleaseSafe and
ReleaseFast, 2026-11-06 22:08-22:13). Each Rex runs in a sandbox: its own
temporary `HOME`, so **Rex uses its default config** and none of the user's
files are read or written, and its shell is replaced by `cat > /dev/null`.

At `cc4c6b2` the default config was compiled into `main.zig` and included
the maintainer's fonts: a variable family with its italic, an emoji face
and seven fallback fonts. The config rebuild (`57587ce`) left the defaults
with no font file. Since `6d13682` an omitted `font.file` uses the faces
installed next to the executable. `perf-gui.sh` accepts `FONT` and
`FONT_CONF` (for example fallback lines) and writes them into the sandbox
config. Omitted `FONT` leaves the installed faces. A set `FONT` names the
face that run measured. Startup time and
memory depend on the fonts loaded, so compare those numbers only with runs
that load the same fonts.

- **Idle:** `pidstat` over 60 s, window open, nothing changing.
- **Pastes:** 20 pastes of 1 MiB (`Ctrl+Shift+V`, clipboard set with
  `xclip`); RSS before and after; paste write errors counted in Rex's log.
- **Font changes:** 10 cycles of 5 steps up and 5 down (`Ctrl+=`, `Ctrl+-`),
  100 changes in all; RSS before and after.
- **Throughput:** a fresh instance; 100 MiB test files written to Rex's pty
  slave (`cat file > /dev/pts/N`), so the bytes arrive exactly like program
  output, and `cat` finishes once Rex has consumed all but the kernel's pty
  buffer: end-to-end parse plus render. `plain` is base64 text in
  76-column lines; `escapes` is the `vt` bench corpora (recorded `htop`,
  `ls --color`, `man bash` and others) repeated to 100 MiB. 3 runs each.

| Metric | ReleaseSafe | ReleaseFast |
|---|---|---|
| RSS at start | 168 MiB | 163 MiB |
| Idle CPU (60 s average) | 0.07% | 0.05% |
| Idle voluntary context switches | 10.9/s | 11.0/s |
| 20 pastes of 1 MiB | **20 of 20 truncated** (`WouldBlock`); RSS +1.1 MiB | **20 of 20 truncated**; RSS +3.0 MiB |
| 100 font changes | RSS +12.5 MiB (one-time, see notes) | RSS +13.4 MiB (one-time, see notes) |
| Throughput, plain | 86.4-87.5 MiB/s | 82.2-85.6 MiB/s |
| Throughput, escapes | 74.2-76.3 MiB/s | 73.2-75.5 MiB/s |

Notes:

- **Pastes larger than the pty buffer are cut off.** Every 1 MiB paste failed
  with `failed to write paste: error.WouldBlock`: the pty master is
  non-blocking, and the rest of the paste is dropped instead of queued.
- **Font changes raise RSS once, then not again.** Measured later
  (2026-11-07, `e81bdec`, ReleaseSafe): on the NVIDIA driver RSS rose
  about 17 MiB over the first 10 changes and 4 MiB more by 20, then stayed
  flat through 1,000 changes. With Mesa's software renderer (llvmpipe) it
  rose about 1 MiB in all. The first change's FreeType and glibc share is
  about 3 MiB of freed heap glibc keeps (a rasterizer-only probe levels
  off at that). It is neither the process arena nor a leak; the per-change
  figures this table first gave were extrapolated from one 100-change run.
- **Idle is not idle:** about 11 wakeups per second, consistent with the
  blink timers (500 ms and 250 ms) and the once-a-second title update found
  in code review.
- **Default vs personal config:** the same commit started at about 105 MiB
  with the maintainer's personal config (an earlier, non-sandboxed run), 60
  MiB less than with the default config. Not investigated.
- **Variance between sessions:** throughput for the same commit measured
  75-78 MiB/s (plain) in an earlier session and 86-87 MiB/s here. Compare
  throughput only within one session.
- GPU utilisation is not part of the baseline: the whole-GPU figure (33-35%
  while idle) includes the desktop on a 165 Hz display and can't be
  attributed to Rex.

## 3. Input latency inside Rex (added 2026-11-07)

Measured later than the rest of this page, at `6a16182` (`cc4c6b2` plus the
HiDPI, Wayland and tracing work), same machine, X11 session, ReleaseFast,
vsync on (`glfwSwapInterval(1)`, 165 Hz). `LATENCY_KEYS=1000
scripts/perf-gui.sh ReleaseFast` builds Rex with `-Dtrace-latency` and types
1,000 keys 50 ms apart through XTEST: batches of 15 `a` and a Return. Rex's
child is the `cat` sink with the tty in canonical mode and echo on, so the
kernel echoes each key and no shell is involved. `scripts/latency-report.sh`
summarizes the trace. Stages are defined in `src/driver/latency_trace.zig`.
All 1,000 keys matched in both scenarios. Times in microseconds.

| Step | Quiet median | Quiet p95 | Quiet p99 | Loaded median | Loaded p95 | Loaded p99 |
|---|---|---|---|---|---|---|
| key callback -> queued | 2.4 | 4.2 | 5.5 | 1.3 | 3.0 | 6.5 |
| queued -> written to the pty | 17.3 | 25.8 | 33.1 | 1,222 | 3,935 | 5,140 |
| written -> echo read | 15.0 | 22.0 | 32.0 | 26.4 | 40.0 | 71.7 |
| echo read -> frame published | 11.9 | 22.0 | 36.8 | 510 | 2,268 | 3,520 |
| published -> picked by the GUI | 10.9 | 15.7 | 22.7 | 4,151 | 5,732 | 7,145 |
| picked -> drawn (build + draw calls) | 166.5 | 288.6 | 2,407 | 301 | 6,252 | 6,654 |
| drawn -> `swapBuffers` returned | 46.9 | 106.1 | 1,911 | 5,514 | 5,852 | 7,683 |
| **key -> swapped** | **275.6** | **546.5** | **3,255** | **12,029** | **13,114** | **18,163** |

Quiet: an idle terminal. Loaded: a `yes` process streams 76-column lines
into the pty while the keys are typed.

Notes:

- **Loaded numbers are a lower bound.** With output streaming in, the first
  pty read after a key is almost always program output, not the echo, so
  from "echo read" on the loaded column follows the first output after the
  key. The frame that shows the key's own echo can only be the same or a
  later one.
- **Quiet:** the pty round trip (queued to echo read) is about 32 us at the
  median. Building and drawing the frame is the largest step (167 us
  median), and its p99 of 2.4 ms is the main source of the 3.3 ms p99.
  Not investigated yet.
- **Loaded:** about 12 ms at the median, two frames at 165 Hz. Where the
  time goes was not investigated: the worker writes a queued key only after
  it has handled the output it was busy with (about 1.2 ms), the GUI picks up
  a new frame about 4 ms after it was published, and `swapBuffers` blocks
  for about 5.5 ms, close to one 6.06 ms frame interval, which suggests it
  waits for vsync with frames already queued. These are hypotheses, not
  measurements of cause.
- **Not covered:** time before the key callback (input device, X server,
  GLFW dispatch, events waiting while the GUI thread is busy) and after
  `swapBuffers` returns (GPU work, compositing, scan-out). An end-to-end
  keystroke-to-pixel tool (#10) is needed for those and for comparing with
  other terminals.

## 4. Input latency under load (#21, measured 2026-11-10)

Same machine and harness as section 3, ReleaseFast, X11, NVIDIA,
`LATENCY_KEYS=1000`. Two differences. The trace stamps `echoed` on the pty
read that contains the key's first byte, and the load line rewrites `a` to
`b`, so the generator never emits `a` or CR. A key with no such byte stays
unmatched. Both runs below matched all 1,000 keys in both scenarios, so the
loaded column is the key's own echo.

The first table is that match on the old loop, which still reads the pty
before writing the key. The second flushes queued input before that read.
Replies produced by the read are flushed afterwards. Times in microseconds.

Read the pty, then write the key:

| Step | Quiet median | Quiet p99 | Loaded median | Loaded p99 |
|---|---|---|---|---|
| queued -> written to the pty | 13.9 | 20.6 | 1,165 | 6,365 |
| written -> echo read | 13.7 | 21.9 | 27.5 | 62.9 |
| echo read -> frame published | 10.7 | 20.8 | 449 | 3,732 |
| published -> picked by the GUI | 10.6 | 16.7 | 4,245 | 6,114 |
| picked -> drawn | 143.2 | 217.2 | 259 | 323 |
| drawn -> `swapBuffers` returned | 38.7 | 102.3 | 5,795 | 6,720 |
| **key -> swapped** | **234.6** | **716.6** | **12,061** | **18,161** |

Write the key, then read the pty:

| Step | Quiet median | Quiet p99 | Loaded median | Loaded p99 |
|---|---|---|---|---|
| queued -> written to the pty | 14.0 | 24.3 | 513 | 3,453 |
| written -> echo read | 13.5 | 20.8 | 18.2 | 49.1 |
| echo read -> frame published | 10.7 | 19.3 | 466 | 3,804 |
| published -> picked by the GUI | 10.5 | 17.1 | 4,790 | 6,062 |
| picked -> drawn | 149.0 | 218.8 | 264 | 320 |
| drawn -> `swapBuffers` returned | 38.9 | 480.9 | 5,791 | 6,956 |
| **key -> swapped** | **240.0** | **883.2** | **12,058** | **13,380** |

Once the byte is written, the echo is in the next read about 20 us later
under load. The loaded key-to-swap median stays about 12 ms. Most of that
is still the GUI picking up the frame and `swapBuffers` waiting, which is
#22.

Writing first cut queued-to-written from 1.2 ms to 0.5 ms at the median. A
key typed while the worker is inside a drain still waited there, because
the input queue was read only after that drain returned EAGAIN.

The third table bounds a turn: reads are 4 KiB, and the turn stops at
256 KiB or as soon as a key is queued, then writes that key before the
snapshot. The pty stays readable, so the next `poll` returns at once.
Loaded queued-to-written is 8 µs median, 22 µs p95, 164 µs p99. The p99 is
a key that arrived during a 4 KiB read. All 1,000 keys matched.

| Step | Quiet median | Quiet p99 | Loaded median | Loaded p99 |
|---|---|---|---|---|
| queued -> written to the pty | 14.1 | 21.0 | 8.4 | 164.4 |
| written -> echo read | 13.5 | 21.9 | 24.3 | 58.2 |
| echo read -> frame published | 10.2 | 21.8 | 434 | 2,750 |
| published -> picked by the GUI | 10.5 | 15.2 | 5,522 | 6,416 |
| picked -> drawn | 148.0 | 197.3 | 266 | 321 |
| drawn -> `swapBuffers` returned | 38.1 | 250.0 | 5,786 | 6,336 |
| **key -> swapped** | **237.7** | **1,147** | **12,059** | **12,647** |

Throughput in the same session, 100 MiB, ReleaseFast, three runs. Before
the bound: plain 83.9-86.7 MiB/s, escapes 73.9-75.3. After: plain
84.0-84.7, escapes 72.8-74.8. The low escapes run is about 1 MiB/s under
the previous low. That is inside the run-to-run spread of this harness.

Runs: `perf-results/runs/gui-20261110T005317_eba5d33-dirty_ReleaseFast`,
`gui-20261110T005622_eba5d33-dirty_ReleaseFast`,
`gui-20261110T010512_eba5d33-dirty_ReleaseFast`,
`gui-20261110T010655_eba5d33-dirty_ReleaseFast`,
`gui-20261110T010755_eba5d33-dirty_ReleaseFast`.

The fourth table splits picked -> drawn into building the frame and
submitting the draw calls. The same loop records whether it toggled a blink
phase or called `setWindowTitle`. All 1,000 keys matched again.

| Step | Quiet median | Quiet p99 | Loaded median | Loaded p99 |
|---|---|---|---|---|
| queued -> written to the pty | 14.5 | 21.6 | 8.5 | 191.1 |
| published -> picked by the GUI | 10.7 | 16.0 | 5,469 | 6,820 |
| picked -> frame built | 85.8 | 122.7 | 182 | 203 |
| frame built -> drawn | 63.2 | 97.7 | 86.5 | 132 |
| drawn -> `swapBuffers` returned | 39.5 | 64.8 | 5,785 | 6,699 |
| **key -> swapped** | **241.8** | **404.8** | **12,058** | **13,063** |

On the idle terminal `swapBuffers` returns in about 40 us, so the loop runs
far faster than the blink half-period (500 ms) and the one-second title
timer. Those iterations are not the ones that pick a key: blink and title
are both 0 on all 1,000 quiet keys. Frame build stays at or under 150 us.
Two draw calls took 1.1 ms and 1.7 ms. Four swaps took 2.9-4.2 ms. None of
those six keys had either flag. The 3.3 ms quiet p99 from section 3 does
not reappear; this run's quiet p99 is 405 us, and the max is one of those
swaps.

Under load the loop does wait in the swap, and 21 keys share a blink toggle
and 7 a title update. Blink frames built in 163 us median against 182 for
the rest. Title frames drew in 104 us median against 86, seven samples, max
138 us. No build or draw exceeded 500 us (build max 242, draw max 223).
Skipping an unchanged `setWindowTitle`, or special-casing blink, would not
move the tail. The loaded 12 ms is still the pickup wait and
`swapBuffers`, which is #22. Blink and the window title were left as they
are.

Run: `perf-results/runs/gui-20261110T011559_eba5d33-dirty_ReleaseFast`.

## 5. Why the loaded 12 ms is two refreshes (#22, 2026-11-10)

Same trace as the last table in section 4. 770 of 1,000 loaded keys were
published within 1 ms of the callback, and 993 were first picked 4.5-7.5 ms
after it (one 6.06 ms refresh). The pick then waited another refresh in
`swapBuffers`. The mailbox drops stale frames, so this is not a queued
frame inside the driver. The GUI loop polls events after `swapBuffers`, and
the echo is published after that turn has already latched a frame. ADR
0002 is the schedule for that, measured in section 6. No renderer change
in that investigation.

## 6. Late latch before vblank (#56, measured 2026-11-10)

`App.run` now waits, on a turn that is already going to draw, until shortly
before the next vblank, polling events while it waits, then builds and
draws the newest frame. The vblank estimate is the previous blocking
`swapBuffers` return plus one refresh, shifted by how long the next swap
blocked. An idle turn still uses `waitForNextEvent`. `glfwSwapInterval(1)`
is unchanged. The worker and the mailbox are unchanged.

Same harness as section 4, ReleaseFast, X11, NVIDIA, `LATENCY_KEYS=1000`,
from `feat/22-frame-pacing`. All 1,000 keys matched in both scenarios.
Times in microseconds. The section 4 run this is compared with is
`gui-20261110T011559_eba5d33-dirty_ReleaseFast` (loaded key -> swapped
median 12,058).

| Step | Quiet median | Quiet p99 | Loaded median | Loaded p99 |
|---|---|---|---|---|
| key -> queued | 1.3 | 3.0 | 971 | 2,665 |
| queued -> written to the pty | 11.8 | 28.4 | 7.6 | 27.5 |
| published -> picked by the GUI | 12.9 | 18.6 | 2,346 | 6,169 |
| picked -> frame built | 92.8 | 130.9 | 208 | 224 |
| frame built -> drawn | 46.5 | 94.3 | 84.0 | 109 |
| drawn -> `swapBuffers` returned | 33.0 | 68.5 | 1,603 | 2,236 |
| **key -> swapped** | **220.7** | **348.7** | **6,048** | **9,869** |

Loaded key -> swapped median is 6.05 ms, one 165 Hz refresh (6.06 ms).
512 keys were under 7 ms, 483 were between 7 and 10 ms, and 5 were at or
over 10 ms (max 12.1 ms). The late group is a key that arrived after the
frame was latched: it waits for the next refresh, whose swap blocks about
1.6 ms instead of a whole frame. `swapBuffers` blocked for 1.0-2.0 ms on
925 of 1,000 loaded keys (median 1.6 ms). Four keys saw a swap return in
under 0.4 ms, which is a draw that landed after the vblank; the latch
drops that deadline and the next frame blocks, so the present slips one
refresh. One loaded swap blocked 5.7 ms, a full refresh.

Quiet key -> swapped stays at 221 µs median (p99 349 µs). The deadline is
armed only when a frame is already due, so an idle key does not sleep
toward the next vblank.

Under load, key -> queued is 971 µs median. About half the keys are still
near 1 µs; the other half wait for the character callback on a later poll
during the pre-vblank sleep (p95 2.4 ms). That wait is inside the
one-refresh budget. Queued -> written stays at 7.6 µs. Blink toggled on 14
loaded keys and the title updated on 5. No build or draw exceeded 500 µs.

Run: `perf-results/runs/gui-20261110T021543_032a06a-dirty_ReleaseFast`.

## 7. Not measured yet

- **Font-change time.**

Shipped-font startup, measured later on this machine, is in
`font-startup-2026-11.md`.

## Reproducing

```sh
git worktree add --detach /path/to/rex-baseline cc4c6b2 && cd /path/to/rex-baseline
scripts/perf-bench.sh                 # section 1 (needs the perf-bench.sh fix, or
                                      # `zig build benchmark -Doptimize=ReleaseFast -Dcpu=native` first)
# section 2: copy scripts/perf-gui.sh from a newer checkout, then
scripts/perf-gui.sh ReleaseSafe       # X11 only; takes the keyboard focus for ~3 minutes
scripts/perf-gui.sh ReleaseFast
# section 3, at 6a16182 or later (also runs in a Wayland session, on XWayland):
LATENCY_KEYS=1000 scripts/perf-gui.sh ReleaseFast
```
