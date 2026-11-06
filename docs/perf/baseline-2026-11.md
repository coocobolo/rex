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
- **`vt.man_bash` reports a checksum mismatch in all 7 variants.** Its input
  (`bench/cases/vt/testdata/corpus/man_bash.*`) hasn't changed since
  `234161b`, so the parser's event stream for that input differs. Not yet
  investigated: it could be an intended behaviour change or a regression.

Known issue: `perf-bench.sh` builds with `zig build`, which doesn't install
the benchmark binary. This run built it first with `zig build benchmark
-Doptimize=ReleaseFast -Dcpu=native`.

## 2. Running application (native GL driver)

Method: launch Rex, wait 2 s, measure while idle, then write 100 MiB test
files to Rex's pty slave (`cat file > /dev/pts/N`). The bytes arrive exactly
like program output, and `cat` finishes once Rex has consumed all but the
kernel's pty buffer, so the time is end-to-end throughput (parse plus
render). Data: `plain` is base64 text in 76-column lines; `escapes` is the
`vt` bench corpora (recorded `htop`, `ls --color`, `man bash` and others),
repeated to 100 MiB.

| Metric | ReleaseFast | ReleaseSafe |
|---|---|---|
| RSS at start | 103 MiB | 106 MiB |
| Idle CPU (60 s average) | 0.05% | 0.05% |
| Idle voluntary context switches | 11.2/s | 11.0/s |
| Throughput, plain (3 runs) | 75.3-78.0 MiB/s | 73.2-75.1 MiB/s |
| Throughput, escapes (3 runs) | 67.0-67.7 MiB/s | 64.8-65.9 MiB/s |
| RSS after 600 MiB of output | 142 MiB | 126 MiB |

Notes:

- Idle CPU is low, but at about 11 wakeups per second Rex is not idle. That
  is consistent with the blink timers (500 ms and 250 ms) and the
  once-a-second title update found during code review.
- ReleaseSafe costs only 2-3% throughput compared with ReleaseFast here.
- RSS rises during heavy output and stays up (scrollback, grapheme tables,
  and frees that never return memory, since the app allocates from the
  process arena). It is flat across repeat runs with the same data.
- GPU: whole-GPU utilisation was 33-35% during 30 s of idle. That includes
  the desktop and other windows on a 165 Hz display, and there was no
  control run without Rex, so the number **can't be attributed to Rex** and
  isn't a baseline.

## 3. Not measured yet

- **Memory growth from pastes and font changes.** These need keyboard and
  clipboard automation (`xdotool`, `xclip`); planned as a separate
  harness.
- **Input latency.** This needs per-stage timestamps in the code (an
  optional build flag) for the internal breakdown, plus an end-to-end
  keystroke-to-pixel tool (e.g. Typometer) to compare with other terminals.
- **Font-change time** (including the zero-tile atlas clear from the
  OpenGL 3.3 change).

## Reproducing

```sh
git worktree add /tmp/rex-baseline cc4c6b2 && cd /tmp/rex-baseline
zig build benchmark -Doptimize=ReleaseFast -Dcpu=native
scripts/perf-bench.sh
# GUI part: the measurement script used for section 2 is kept locally
# (perf-results/runs/gui-cc4c6b2/measure.sh) and still has to be added to
# scripts/ in a follow-up.
```
