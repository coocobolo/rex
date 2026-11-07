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

## 3. Not measured yet

- **Input latency.** Needs per-stage timestamps in the code (an optional
  build flag) for the internal breakdown, plus an end-to-end
  keystroke-to-pixel tool (e.g. Typometer) to compare with other terminals.
- **Font-change time.**

## Reproducing

```sh
git worktree add --detach /path/to/rex-baseline cc4c6b2 && cd /path/to/rex-baseline
scripts/perf-bench.sh                 # section 1 (needs the perf-bench.sh fix, or
                                      # `zig build benchmark -Doptimize=ReleaseFast -Dcpu=native` first)
# section 2: copy scripts/perf-gui.sh from a newer checkout, then
scripts/perf-gui.sh ReleaseSafe       # X11 only; takes the keyboard focus for ~3 minutes
scripts/perf-gui.sh ReleaseFast
```
